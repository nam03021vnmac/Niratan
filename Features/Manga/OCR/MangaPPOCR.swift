import Accelerate
import CoreGraphics
import Foundation

/// PP-OCRv6 small DB line detector + CTC line recognizer, ported from
/// Fushi's `ppocr_line_detector.dart` / `ppocr_line_recognizer.dart`.
/// Used only inside horizontal text blocks.
nonisolated struct MangaPPTextLine: Sendable {
    var rect: CGRect
    var score: Double

    /// Vertical when height ≥ 1.5 × width.
    var isVertical: Bool { rect.height >= rect.width * 1.5 }
    /// Line thickness: height for horizontal lines, width for vertical ones.
    var thickness: CGFloat { isVertical ? rect.width : rect.height }
}

nonisolated final class MangaPPLineDetector: @unchecked Sendable {
    static let threshold: Float = 0.2
    static let boxThreshold = 0.45
    static let unclipRatio = 1.4
    static let limitSideLength = 64
    static let mean: [Double] = [0.485, 0.456, 0.406]
    static let std: [Double] = [0.229, 0.224, 0.225]
    /// Normalized value of each 8-bit level per input plane (B, G, R), from
    /// the same Double expression the per-pixel loop used.
    private static let normalized: [[Float]] = (0..<3).map { channel in
        (0..<256).map { Float((Double($0) / 255.0 - mean[channel]) / std[channel]) }
    }

    private let session: MangaOCRSession
    private let staticSessions: MangaPPStaticDetectorSessions?

    /// `staticShapeCache` enables Core ML programs for recurring input sizes
    /// (whole document pages); manga blocks vary too much and leave it nil.
    init(modelURL: URL, staticShapeCache: URL? = nil) throws {
        session = try MangaOCRSession(modelURL: modelURL)
        staticSessions = staticShapeCache.map { MangaPPStaticDetectorSessions(modelURL: modelURL, directory: $0) }
    }

    /// `maxSide` caps the longer side (full document pages); manga blocks
    /// leave it nil and keep the original behavior.
    static func inputSize(width: Int, height: Int, maxSide: Int? = nil) -> (width: Int, height: Int) {
        let minSide = min(width, height)
        var ratio = minSide < limitSideLength ? Double(limitSideLength) / Double(minSide) : 1.0
        if let maxSide, max(width, height) > maxSide { ratio = Double(maxSide) / Double(max(width, height)) }
        func round32(_ side: Int) -> Int {
            max(32, Int((Double(Int(Double(side) * ratio)) / 32).rounded()) * 32)
        }
        return (round32(width), round32(height))
    }

    /// Lines in `crop` pixel space.
    func detect(_ crop: MangaOCRBitmap, maxSide: Int? = nil) throws -> [MangaPPTextLine] {
        let size = Self.inputSize(width: crop.width, height: crop.height, maxSide: maxSide)
        let resized = crop.resizedLinear(width: size.width, height: size.height)
        let plane = size.width * size.height
        var chw = [Float](repeating: 0, count: 3 * plane)
        resized.pixels.withUnsafeBufferPointer { pixels in
            chw.withUnsafeMutableBufferPointer { chw in
                // BGR channel order with ImageNet constants applied in that order.
                let blue = Self.normalized[0], green = Self.normalized[1], red = Self.normalized[2]
                for index in 0..<plane {
                    chw[index] = blue[Int(pixels[index * 3 + 2])]
                    chw[plane + index] = green[Int(pixels[index * 3 + 1])]
                    chw[2 * plane + index] = red[Int(pixels[index * 3])]
                }
            }
        }
        let input = try MangaOCRSession.floatValue(chw, shape: [1, 3, size.height, size.width])
        var outputs: [String: MangaOCRTensor]?
        if let accelerated = staticSessions?.session(width: size.width, height: size.height) {
            do {
                outputs = try accelerated.run([accelerated.resolvedInputName("x"): input])
            } catch {
                staticSessions?.discard(width: size.width, height: size.height)
            }
        }
        let result = try outputs ?? session.run([session.resolvedInputName("x"): input])
        guard result.count == 1, let probability = result.values.first, probability.shape.count >= 2 else {
            throw MangaOCREngineError.inferenceFailed("PP-OCR det output")
        }
        let outHeight = probability.shape[probability.shape.count - 2]
        let outWidth = probability.shape[probability.shape.count - 1]
        let raw = Self.postprocess(probability.floats, width: outWidth, height: outHeight)
        let sx = CGFloat(crop.width) / CGFloat(outWidth)
        let sy = CGFloat(crop.height) / CGFloat(outHeight)
        return raw.map { line in
            MangaPPTextLine(
                rect: CGRect.ocr(
                    left: line.rect.minX * sx,
                    top: line.rect.minY * sy,
                    right: line.rect.maxX * sx,
                    bottom: line.rect.maxY * sy
                ),
                score: line.score
            )
        }
    }

    /// Raw (unfiltered) lines of a page block, in page coordinates.
    func detectInBlock(_ page: MangaOCRBitmap, box: CGRect) throws -> [CGRect] {
        guard let crop = page.blockCrop(box) else { return [] }
        return try detect(crop.bitmap).map { $0.rect.offsetBy(dx: CGFloat(crop.x), dy: CGFloat(crop.y)) }
    }

    /// Strict vertical majority among the (furigana-filtered) lines.
    static func linesAreVerticalMajority(_ lines: [MangaPPTextLine]) -> Bool {
        lines.filter(\.isVertical).count * 2 > lines.count
    }

    /// DB post-processing: 4-connected components over `p > 0.2`, mean
    /// probability ≥ 0.45, axis-aligned unclip by `pixels * 1.4 / perimeter`.
    static func postprocess(_ probability: [Float], width: Int, height: Int) -> [MangaPPTextLine] {
        guard probability.count == width * height else { return [] }
        var label = [Int32](repeating: 0, count: width * height)
        var stack = [Int32](repeating: 0, count: width * height)
        var lines: [MangaPPTextLine] = []
        var nextLabel: Int32 = 0
        for start in 0..<probability.count {
            if label[start] != 0 || probability[start] <= threshold { continue }
            nextLabel += 1
            label[start] = nextLabel
            stack[0] = Int32(start)
            var stackPointer = 1
            var minX = width, minY = height, maxX = -1, maxY = -1
            var sum = 0.0
            var count = 0
            while stackPointer > 0 {
                stackPointer -= 1
                let point = Int(stack[stackPointer])
                let px = point % width
                let py = point / width
                sum += Double(probability[point])
                count += 1
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
                // Left, right, up, down; the push order fixes the sum order.
                func visit(_ neighbour: Int) {
                    guard label[neighbour] == 0, probability[neighbour] > threshold else { return }
                    label[neighbour] = nextLabel
                    stack[stackPointer] = Int32(neighbour)
                    stackPointer += 1
                }
                if px > 0 { visit(point - 1) }
                if px < width - 1 { visit(point + 1) }
                if py > 0 { visit(point - width) }
                if py < height - 1 { visit(point + width) }
            }
            let score = sum / Double(count)
            if score < boxThreshold { continue }
            let w = Double(maxX - minX + 1)
            let h = Double(maxY - minY + 1)
            if w < 2 || h < 2 { continue }
            let distance = Double(count) * unclipRatio / (2 * (w + h))
            let rect = CGRect.ocr(
                left: CGFloat(Double(minX) - distance),
                top: CGFloat(Double(minY) - distance),
                right: CGFloat(Double(maxX + 1) + distance),
                bottom: CGFloat(Double(maxY + 1) + distance)
            ).ocrClamped(width: CGFloat(width), height: CGFloat(height))
            lines.append(MangaPPTextLine(rect: rect, score: score))
        }
        return lines
    }

    /// Furigana filter: drop lines thinner than 0.6 × the 75th-percentile
    /// thickness of the block.
    static func filterThinLines(_ lines: [MangaPPTextLine], ratio: CGFloat = 0.6) -> [MangaPPTextLine] {
        guard !lines.isEmpty else { return lines }
        let thickness = lines.map(\.thickness).sorted()
        let p75 = thickness[min(thickness.count - 1, (3 * thickness.count) / 4)]
        return lines.filter { $0.thickness >= ratio * p75 }
    }

    static func orderForReading(_ lines: [MangaPPTextLine]) -> [MangaPPTextLine] {
        let verticalCount = lines.filter(\.isVertical).count
        if !lines.isEmpty && verticalCount * 2 >= lines.count {
            return lines.enumerated().sorted {
                let a = $0.element.rect.minX + $0.element.rect.maxX
                let b = $1.element.rect.minX + $1.element.rect.maxX
                return a != b ? a > b : $0.offset < $1.offset
            }.map(\.element)
        }
        return lines.enumerated().sorted {
            if $0.element.rect.minY != $1.element.rect.minY { return $0.element.rect.minY < $1.element.rect.minY }
            if $0.element.rect.minX != $1.element.rect.minX { return $0.element.rect.minX < $1.element.rect.minX }
            return $0.offset < $1.offset
        }.map(\.element)
    }
}

/// Core ML sessions of the line detector, one per input size. Core ML runs a
/// dynamic-shape program slower than the CPU, so each size gets its own copy
/// of the model with the input pinned, compiled once and cached on disk. A
/// size runs on the CPU until it recurs, so one-off page sizes never pay for
/// a compile; any failure leaves that size on the CPU. A loaded program
/// holds about 1 GB of GPU memory at 1088×1536, so only one stays resident.
nonisolated final class MangaPPStaticDetectorSessions: @unchecked Sendable {
    static let residentLimit = 1
    static let diskLimit = 3

    private let modelURL: URL
    private let directory: URL
    private var resident: [(key: String, session: MangaOCRSession)] = []
    private var requests: [String: Int] = [:]
    private var failed: Set<String> = []

    init(modelURL: URL, directory: URL) {
        self.modelURL = modelURL
        self.directory = directory
    }

    func session(width: Int, height: Int) -> MangaOCRSession? {
        let key = "\(width)x\(height)"
        if let index = resident.firstIndex(where: { $0.key == key }) {
            let entry = resident.remove(at: index)
            resident.append(entry)
            return entry.session
        }
        guard !failed.contains(key) else { return nil }
        requests[key, default: 0] += 1
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        let model = folder.appendingPathComponent("model.onnx")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: model.path) || requests[key, default: 0] >= 2 else { return nil }
        do {
            if !fileManager.fileExists(atPath: model.path) {
                let pinned = try MangaOCRModelShape.fixingInput(
                    "x", to: [1, 3, height, width], in: Data(contentsOf: modelURL, options: .mappedIfSafe)
                )
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                try pinned.write(to: model, options: .atomic)
            }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
            let session = try MangaOCRSession(
                modelURL: model,
                provider: .coreMLStatic(cacheDirectory: folder.appendingPathComponent("compiled", isDirectory: true))
            )
            resident.append((key, session))
            if resident.count > Self.residentLimit { resident.removeFirst() }
            prune(keeping: Set(resident.map(\.key)))
            return session
        } catch {
            failed.insert(key)
            try? fileManager.removeItem(at: folder)
            return nil
        }
    }

    /// Stop using a size whose Core ML run failed.
    func discard(width: Int, height: Int) {
        let key = "\(width)x\(height)"
        resident.removeAll { $0.key == key }
        failed.insert(key)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key, isDirectory: true))
    }

    /// Keep the most recently used sizes on disk (about 30 MB each).
    private func prune(keeping resident: Set<String>) {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let dated = folders.map { folder in
            (folder, (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (folder, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.diskLimit)
        where !resident.contains(folder.lastPathComponent) {
            try? fileManager.removeItem(at: folder)
        }
    }
}

nonisolated final class MangaPPLineRecognizer: @unchecked Sendable {
    static let height = 48
    static let minimumWidth = 320
    private static let normalized: [Float] = (0..<256).map { Float((Double($0) / 255.0 - 0.5) / 0.5) }

    private let session: MangaOCRSession
    private let vocabulary: [String]

    init(modelURL: URL, dictionaryURL: URL) throws {
        session = try MangaOCRSession(modelURL: modelURL)
        guard let yaml = try? String(contentsOf: dictionaryURL, encoding: .utf8) else {
            throw MangaOCREngineError.modelInvalid("PP-OCR dictionary")
        }
        vocabulary = [""] + (try Self.parseCharacterDictionary(yaml)) + [" "]
    }

    /// Parse `character_dict` from `inference.yml` (bare or single-quoted scalars only).
    static func parseCharacterDictionary(_ yaml: String) throws -> [String] {
        // Work on UTF-8 bytes: several dictionary entries are grapheme
        // extenders (e.g. U+FF9E) that would merge with the preceding space
        // under Swift's Character semantics and break prefix matching.
        let lines = yaml.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { line -> [UInt8] in
            var bytes = Array(line)
            if bytes.last == UInt8(ascii: "\r") { bytes.removeLast() }
            return bytes
        }
        guard let start = lines.firstIndex(where: {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespaces) == "character_dict:"
        }) else {
            throw MangaOCREngineError.modelInvalid("character_dict not found")
        }
        let itemPrefix = Array("  - ".utf8)
        var characters: [String] = []
        for line in lines[(start + 1)...] {
            guard line.count >= itemPrefix.count, Array(line.prefix(itemPrefix.count)) == itemPrefix else { break }
            let bytes = Array(line.dropFirst(itemPrefix.count))
            let quote = UInt8(ascii: "'")
            if bytes.first == quote {
                guard bytes.count >= 2, bytes.last == quote else {
                    throw MangaOCREngineError.modelInvalid("unterminated scalar")
                }
                let inner = String(decoding: bytes.dropFirst().dropLast(), as: UTF8.self)
                characters.append(inner.replacingOccurrences(of: "''", with: "'"))
            } else if let first = bytes.first, first == UInt8(ascii: "\"") || first == UInt8(ascii: "[") || first == UInt8(ascii: "{") {
                throw MangaOCREngineError.modelInvalid("unsupported scalar")
            } else {
                characters.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        guard !characters.isEmpty else { throw MangaOCREngineError.modelInvalid("character_dict empty") }
        return characters
    }

    func recognizeLine(_ line: MangaOCRBitmap) throws -> String {
        guard let output = try infer(line) else { return "" }
        return output.logits.data.withUnsafeBytes { raw in
            Self.ctcGreedyDecode(raw.bindMemory(to: Float.self), frames: output.frames, vocabSize: output.vocabSize, vocabulary: vocabulary)
        }
    }

    /// Greedy CTC tokens with the centre of each token's frame run, as a
    /// 0…1 fraction of the line's width. Used to place per-character boxes.
    func recognizeLineTokens(_ line: MangaOCRBitmap) throws -> [PDFOCRToken] {
        guard let output = try infer(line) else { return [] }
        return output.logits.data.withUnsafeBytes { raw in
            Self.ctcGreedyTokens(
                raw.bindMemory(to: Float.self), frames: output.frames, vocabSize: output.vocabSize,
                vocabulary: vocabulary, frameStride: Double(output.inputWidth) / Double(output.frames),
                contentWidth: Double(output.scaledWidth)
            )
        }
    }

    private func infer(_ line: MangaOCRBitmap) throws -> (logits: MangaOCRTensor, frames: Int, vocabSize: Int, inputWidth: Int, scaledWidth: Int)? {
        guard line.width > 0, line.height > 0 else { return nil }
        let scaledWidth = max(1, Int(ceil(Double(Self.height) * Double(line.width) / Double(line.height))))
        let inputWidth = max(Self.minimumWidth, scaledWidth)
        let resized = line.resizedLinear(width: scaledWidth, height: Self.height)
        let plane = Self.height * inputWidth
        var chw = [Float](repeating: 0, count: 3 * plane)
        resized.pixels.withUnsafeBufferPointer { pixels in
            chw.withUnsafeMutableBufferPointer { chw in
                let normalized = Self.normalized
                for y in 0..<Self.height {
                    for x in 0..<scaledWidth {
                        let source = (y * scaledWidth + x) * 3
                        let index = y * inputWidth + x
                        chw[index] = normalized[Int(pixels[source + 2])]
                        chw[plane + index] = normalized[Int(pixels[source + 1])]
                        chw[2 * plane + index] = normalized[Int(pixels[source])]
                    }
                }
            }
        }
        let outputs = try session.run([
            session.resolvedInputName("x"): try MangaOCRSession.floatValue(chw, shape: [1, 3, Self.height, inputWidth]),
        ])
        guard outputs.count == 1, let logits = outputs.values.first, logits.shape.count >= 2 else {
            throw MangaOCREngineError.inferenceFailed("PP-OCR rec output")
        }
        let vocabSize = logits.shape[logits.shape.count - 1]
        let frames = logits.shape[logits.shape.count - 2]
        guard vocabSize == vocabulary.count else {
            throw MangaOCREngineError.modelInvalid("PP-OCR vocabulary \(vocabSize) vs \(vocabulary.count)")
        }
        return (logits, frames, vocabSize, inputWidth, scaledWidth)
    }

    /// Same decode as `ctcGreedyDecode`, but each emitted token carries the
    /// middle of its run of identical frames mapped back onto the line.
    static func ctcGreedyTokens(
        _ logits: UnsafeBufferPointer<Float>,
        frames: Int,
        vocabSize: Int,
        vocabulary: [String],
        frameStride: Double,
        contentWidth: Double
    ) -> [PDFOCRToken] {
        var tokens: [PDFOCRToken] = []
        var runToken = 0
        var runStart = 0
        func flush(endExclusive: Int) {
            guard runToken != 0, contentWidth > 0 else { return }
            let center = (Double(runStart + endExclusive) / 2) * frameStride
            tokens.append(PDFOCRToken(text: vocabulary[runToken], center: min(1, max(0, center / contentWidth))))
        }
        for frame in 0..<frames {
            let best = argmax(logits, frame: frame, vocabSize: vocabSize)
            if best != runToken {
                flush(endExclusive: frame)
                runToken = best
                runStart = frame
            }
        }
        flush(endExclusive: frames)
        return tokens
    }

    /// Index of the first largest logit of `frame`; vDSP_maxvi keeps the
    /// lowest index on ties, like a strict `>` scan.
    static func argmax(_ logits: UnsafeBufferPointer<Float>, frame: Int, vocabSize: Int) -> Int {
        guard let base = logits.baseAddress, vocabSize > 0 else { return 0 }
        var value: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(base + frame * vocabSize, 1, &value, &index, vDSP_Length(vocabSize))
        return Int(index)
    }

    static func ctcGreedyDecode(
        _ logits: UnsafeBufferPointer<Float>,
        frames: Int,
        vocabSize: Int,
        vocabulary: [String]
    ) -> String {
        var output = ""
        var previous = -1
        for frame in 0..<frames {
            let best = argmax(logits, frame: frame, vocabSize: vocabSize)
            if best != previous && best != 0 { output += vocabulary[best] }
            previous = best
        }
        return output
    }
}
