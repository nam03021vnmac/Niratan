// test-sources: Features/Manga/OCR/MangaOCRModelShape.swift
import Foundation

/// Hand-built protobuf so the ONNX shape rewrite is checked without models.
private struct Proto {
    var bytes: [UInt8] = []

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, out: [UInt8] = []
        while value >= 0x80 { out.append(UInt8(value & 0x7f) | 0x80); value >>= 7 }
        return out + [UInt8(value)]
    }
    mutating func int(_ field: Int, _ value: UInt64) { bytes += Self.varint(UInt64(field << 3)) + Self.varint(value) }
    mutating func fixed32(_ field: Int, _ value: UInt32) {
        bytes += Self.varint(UInt64(field << 3 | 5)) + withUnsafeBytes(of: value.littleEndian, Array.init)
    }
    mutating func message(_ field: Int, _ payload: [UInt8]) {
        bytes += Self.varint(UInt64(field << 3 | 2)) + Self.varint(UInt64(payload.count)) + payload
    }
    mutating func string(_ field: Int, _ value: String) { message(field, Array(value.utf8)) }

    /// Top-level fields as (number, wire type, payload).
    static func fields(_ bytes: [UInt8]) -> [(Int, Int, [UInt8])] {
        var result: [(Int, Int, [UInt8])] = [], cursor = 0
        func read() -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                let byte = bytes[cursor]; cursor += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }
        while cursor < bytes.count {
            let key = read(), wire = Int(key & 7)
            switch wire {
            case 0: let start = cursor; _ = read(); result.append((Int(key >> 3), 0, Array(bytes[start..<cursor])))
            case 5: result.append((Int(key >> 3), 5, Array(bytes[cursor..<cursor + 4]))); cursor += 4
            case 2: let length = Int(read()); result.append((Int(key >> 3), 2, Array(bytes[cursor..<cursor + length]))); cursor += length
            default: fatalError("unexpected wire type \(wire)")
            }
        }
        return result
    }
}

private func dimension(param: String? = nil, value: UInt64? = nil, denotation: String? = nil) -> [UInt8] {
    var d = Proto()
    if let value { d.int(1, value) }
    if let param { d.string(2, param) }
    if let denotation { d.string(3, denotation) }
    return d.bytes
}

private func valueInfo(_ name: String, dims: [[UInt8]]) -> [UInt8] {
    var shape = Proto()
    for dim in dims { shape.message(1, dim) }
    var tensor = Proto()
    tensor.int(1, 1)
    tensor.message(2, shape.bytes)
    var type = Proto()
    type.message(1, tensor.bytes)
    type.string(6, "IMAGE")
    var info = Proto()
    info.string(1, name)
    info.message(2, type.bytes)
    info.string(3, "doc")
    return info.bytes
}

private func dims(of info: [UInt8]) -> [[(Int, Int, [UInt8])]] {
    let type = Proto.fields(info).first { $0.0 == 2 }!.2
    let tensor = Proto.fields(type).first { $0.0 == 1 }!.2
    let shape = Proto.fields(tensor).first { $0.0 == 2 }!.2
    return Proto.fields(shape).filter { $0.0 == 1 }.map { Proto.fields($0.2) }
}

@main
private enum MangaOCRModelShapeTests {
    static func main() throws {
        let input = valueInfo("x", dims: [dimension(param: "N"), dimension(value: 3), dimension(param: "H", denotation: "DATA_FEATURE"), dimension(param: "W")])
        let other = valueInfo("mask", dims: [dimension(param: "N"), dimension(param: "H")])
        var graph = Proto()
        graph.message(1, Array("node-bytes".utf8))
        graph.message(11, other)
        graph.message(11, input)
        graph.message(12, valueInfo("y", dims: [dimension(param: "N"), dimension(value: 1)]))
        graph.fixed32(13, 0xdeadbeef)
        var model = Proto()
        model.int(1, 8)
        // A large initializer-sized field exercises multi-byte lengths.
        model.message(2, [UInt8](repeating: 7, count: 70_000))
        model.message(7, graph.bytes)
        model.int(5, 1)

        let pinned = [UInt8](try MangaOCRModelShape.fixingInput("x", to: [1, 3, 1536, 1088], in: Data(model.bytes)))
        let before = Proto.fields(model.bytes), after = Proto.fields(pinned)
        precondition(after.count == before.count, "top-level fields are preserved")
        for (old, new) in zip(before, after) where old.0 != 7 {
            precondition(old.0 == new.0 && old.1 == new.1 && old.2 == new.2, "field \(old.0) is copied verbatim")
        }
        let oldGraph = Proto.fields(before.first { $0.0 == 7 }!.2)
        let newGraph = Proto.fields(after.first { $0.0 == 7 }!.2)
        precondition(newGraph.count == oldGraph.count)
        for (old, new) in zip(oldGraph, newGraph) {
            precondition(old.0 == new.0 && old.1 == new.1)
            let isTarget = old.0 == 11 && old.2 == input
            precondition(isTarget ? old.2 != new.2 : old.2 == new.2, "only input x changes")
        }
        let newInput = newGraph.first { $0.0 == 11 && $0.2 != other }!.2
        let pinnedDims = dims(of: newInput)
        precondition(pinnedDims.count == 4)
        let values = pinnedDims.map { fields in fields.filter { $0.0 == 1 }.map { field -> UInt64 in
            var value: UInt64 = 0, shift: UInt64 = 0
            for byte in field.2 { value |= UInt64(byte & 0x7f) << shift; shift += 7 }
            return value
        } }
        precondition(values == [[1], [3], [1536], [1088]], "\(values)")
        precondition(pinnedDims.allSatisfy { !$0.contains { $0.0 == 2 } }, "symbolic names are dropped")
        precondition(pinnedDims[2].contains { $0.0 == 3 && $0.2 == Array("DATA_FEATURE".utf8) }, "denotation is kept")
        let infoFields = Proto.fields(newInput), oldInfoFields = Proto.fields(input)
        precondition(infoFields.map(\.0) == oldInfoFields.map(\.0) && infoFields[2].2 == oldInfoFields[2].2, "name and doc stay")
        let newType = Proto.fields(infoFields[1].2), oldType = Proto.fields(oldInfoFields[1].2)
        precondition(newType[1].2 == oldType[1].2, "type denotation stays")

        // Pinning is idempotent: a pinned model can be pinned again.
        let twice = [UInt8](try MangaOCRModelShape.fixingInput("x", to: [1, 3, 1536, 1088], in: Data(pinned)))
        precondition(twice == pinned)

        func failure(_ body: () throws -> Data) -> MangaOCRModelShape.Failure? {
            do { _ = try body(); return nil } catch let error as MangaOCRModelShape.Failure { return error } catch { return nil }
        }
        precondition(failure { try MangaOCRModelShape.fixingInput("z", to: [1, 3, 8, 8], in: Data(model.bytes)) } == .inputNotFound)
        precondition(failure { try MangaOCRModelShape.fixingInput("x", to: [1, 3, 8], in: Data(model.bytes)) } == .rankMismatch)
        precondition(failure { try MangaOCRModelShape.fixingInput("x", to: [1, 3, 8, 8, 1], in: Data(model.bytes)) } == .rankMismatch)
        precondition(failure { try MangaOCRModelShape.fixingInput("x", to: [1, 3, 0, 8], in: Data(model.bytes)) } == .rankMismatch)
        precondition(failure { try MangaOCRModelShape.fixingInput("x", to: [1, 3, 8, 8], in: Data(model.bytes.dropLast(3))) } == .malformed)
        precondition(failure { try MangaOCRModelShape.fixingInput("x", to: [1, 3, 8, 8], in: Data([0x08, 0x80])) } == .malformed)
        print("PASS manga OCR model shape")
    }
}
