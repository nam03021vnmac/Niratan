import Foundation

/// Just enough ONNX protobuf editing to pin a model input's free dimensions,
/// so Core ML compiles a static program. ORT's free-dimension override is not
/// exposed by the Objective-C bindings. Every other byte is copied verbatim.
nonisolated enum MangaOCRModelShape {
    enum Failure: Error, Equatable {
        case malformed
        case inputNotFound
        case rankMismatch
    }

    private struct Field {
        let number: Int
        let wireType: Int
        /// The whole field, tag included.
        let bytes: Range<Int>
        let payload: Range<Int>
    }

    /// `model` with the dimensions of input `name` replaced by `dimensions`.
    static func fixingInput(_ name: String, to dimensions: [Int], in model: Data) throws -> Data {
        let bytes = [UInt8](model)
        var found = false
        // ModelProto.graph = 7, GraphProto.input = 11, ValueInfoProto.type = 2,
        // TypeProto.tensor_type = 1, Tensor.shape = 2, TensorShapeProto.dim = 1.
        let result = try rewrite(bytes, 0..<bytes.count, field: 7) { graph in
            try rewrite(bytes, graph, field: 11) { input in
                let fields = try Self.fields(bytes, input)
                guard let nameField = fields.first(where: { $0.number == 1 && $0.wireType == 2 }),
                      String(decoding: bytes[nameField.payload], as: UTF8.self) == name else {
                    return Array(bytes[input])
                }
                found = true
                return try rewrite(bytes, input, field: 2) { type in
                    try rewrite(bytes, type, field: 1) { tensor in
                        try rewrite(bytes, tensor, field: 2) { shape in
                            try pinned(bytes, shape: shape, to: dimensions)
                        }
                    }
                }
            }
        }
        guard found else { throw Failure.inputNotFound }
        return Data(result)
    }

    private static func pinned(_ bytes: [UInt8], shape: Range<Int>, to dimensions: [Int]) throws -> [UInt8] {
        var output: [UInt8] = []
        var index = 0
        for field in try fields(bytes, shape) {
            guard field.number == 1, field.wireType == 2 else {
                output += bytes[field.bytes]
                continue
            }
            guard index < dimensions.count, dimensions[index] > 0 else { throw Failure.rankMismatch }
            // Dimension.dim_value = 1; drop dim_param = 2, keep anything else.
            var dimension: [UInt8] = [0x08]
            appendVarint(UInt64(dimensions[index]), to: &dimension)
            for inner in try fields(bytes, field.payload) where inner.number != 1 && inner.number != 2 {
                dimension += bytes[inner.bytes]
            }
            appendLengthDelimited(1, dimension, to: &output)
            index += 1
        }
        guard index == dimensions.count else { throw Failure.rankMismatch }
        return output
    }

    /// Copy `range`, replacing the payload of each length-delimited `field`.
    private static func rewrite(_ bytes: [UInt8], _ range: Range<Int>, field number: Int, _ transform: (Range<Int>) throws -> [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(range.count + 64)
        for field in try fields(bytes, range) {
            if field.number == number, field.wireType == 2 {
                appendLengthDelimited(number, try transform(field.payload), to: &output)
            } else {
                output += bytes[field.bytes]
            }
        }
        return output
    }

    private static func fields(_ bytes: [UInt8], _ range: Range<Int>) throws -> [Field] {
        var result: [Field] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let start = cursor
            let key = try varint(bytes, &cursor, limit: range.upperBound)
            let wireType = Int(key & 7)
            let payloadStart: Int
            switch wireType {
            case 0:
                payloadStart = cursor
                _ = try varint(bytes, &cursor, limit: range.upperBound)
            case 1, 5:
                payloadStart = cursor
                cursor += wireType == 1 ? 8 : 4
            case 2:
                let length = try varint(bytes, &cursor, limit: range.upperBound)
                guard length <= UInt64(range.upperBound - cursor) else { throw Failure.malformed }
                payloadStart = cursor
                cursor += Int(length)
            default:
                throw Failure.malformed
            }
            guard cursor <= range.upperBound, key >> 3 > 0 else { throw Failure.malformed }
            result.append(Field(number: Int(key >> 3), wireType: wireType, bytes: start..<cursor, payload: payloadStart..<cursor))
        }
        return result
    }

    private static func varint(_ bytes: [UInt8], _ cursor: inout Int, limit: Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < limit, shift < 64 {
            let byte = bytes[cursor]
            cursor += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw Failure.malformed
    }

    private static func appendVarint(_ value: UInt64, to output: inout [UInt8]) {
        var value = value
        while value >= 0x80 {
            output.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        output.append(UInt8(value))
    }

    private static func appendLengthDelimited(_ number: Int, _ payload: [UInt8], to output: inout [UInt8]) {
        appendVarint(UInt64(number << 3 | 2), to: &output)
        appendVarint(UInt64(payload.count), to: &output)
        output += payload
    }
}
