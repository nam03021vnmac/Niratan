import CoreGraphics
import Foundation
import os

nonisolated extension PDFLineOCRModel {
    var modelSet: MangaOCRModelSet {
        switch self {
        case .document: .pdfOCR
        case .manga: .pdfMangaOCR
        }
    }

    var recognizerFile: MangaOCRModelFile {
        switch self {
        case .document: MangaOCRModelSet.lineRecognizerFile
        case .manga: MangaOCRModelSet.mangaCTCRecognizerFile
        }
    }
}

/// One recognizer of the shared engine, as the PDF worker sees it.
nonisolated struct PDFPaddleOCRReader: PDFLineRecognizing {
    let engine: PDFPaddleOCREngine
    let model: PDFLineOCRModel
    let identity: String

    func recognize(image: CGImage) async throws -> [PDFOCRRecognizedLine] {
        try await engine.recognize(image: image, model: model)
    }
}

/// PP-OCR for dense document pages: DB line detection over the whole page
/// (no speech-bubble stage), then CTC recognition per line with token
/// positions. Vertical columns are re-laid out as upright glyph cells.
/// One detector serves both recognizers: its Core ML programs are large and
/// not safe to share between concurrent callers.
actor PDFPaddleOCREngine {
    private static let revision = "pdf-ppocr-lines-v5"
    /// Longer detector side in pixels. 8.5–10 pt text at 240 dpi detects as
    /// well here as at 2048, at about half the cost on A4.
    private static let detectorMaxSide = 1536
    private static let loaded = OSAllocatedUnfairLock<PDFPaddleOCREngine?>(initialState: nil)

    private let store: MangaOCRModelStore
    private let detector: MangaPPLineDetector
    private var recognizers: [PDFLineOCRModel: MangaPPLineRecognizer] = [:]

    private init(store: MangaOCRModelStore) throws {
        self.store = store
        detector = try MangaPPLineDetector(
            modelURL: store.url(for: MangaOCRModelSet.lineDetectorFile),
            staticShapeCache: Self.compiledDetectorDirectory()
        )
    }

    private static var compiledDetectorRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NiratanPDFOCRCoreML", isDirectory: true)
    }

    /// Core ML detector programs for this detector model and runtime;
    /// programs for other models or runtimes are stale and removed.
    private static func compiledDetectorDirectory() -> URL? {
        guard let root = compiledDetectorRoot else { return nil }
        let name = "\(MangaOCRModelSet.lineDetectorFile.sha256.prefix(12))-ort\(MangaOCRSession.runtimeVersion)"
        for stale in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where stale.lastPathComponent != name {
            try? FileManager.default.removeItem(at: stale)
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// The loaded engine reading with `model`, or nil while that model set
    /// is not downloaded.
    static func current(_ model: PDFLineOCRModel, store: MangaOCRModelStore = .shared) async throws -> PDFPaddleOCRReader? {
        guard await store.isReady(model.modelSet) else { return nil }
        let engine = try loaded.withLock { engine in
            if let engine { return engine }
            let created = try PDFPaddleOCREngine(store: store)
            engine = created
            return created
        }
        return PDFPaddleOCRReader(
            engine: engine, model: model,
            identity: "\(revision)-\(store.fingerprint(for: model.modelSet))|\(detectorMaxSide)"
        )
    }

    /// Release the ONNX sessions and their compiled Core ML programs, e.g.
    /// after the models are deleted.
    static func unload() {
        loaded.withLock { $0 = nil }
        if let root = compiledDetectorRoot { try? FileManager.default.removeItem(at: root) }
    }

    private func recognizer(for model: PDFLineOCRModel) throws -> MangaPPLineRecognizer {
        if let recognizer = recognizers[model] { return recognizer }
        let recognizer = try MangaPPLineRecognizer(
            modelURL: store.url(for: model.recognizerFile),
            dictionaryURL: store.url(for: MangaOCRModelSet.lineDictionaryFile)
        )
        recognizers[model] = recognizer
        return recognizer
    }

    func recognize(image: CGImage, model: PDFLineOCRModel) throws -> [PDFOCRRecognizedLine] {
        try Task.checkCancellation()
        let recognizer = try self.recognizer(for: model)
        guard let page = MangaOCRBitmap(image: image) else { throw PDFSupportError.geometry }
        let detected = try detector.detect(page, maxSide: Self.detectorMaxSide).map(\.rect)
        let oriented = PDFPageOCRLayout.orient(detected)
        let lines = PDFPageOCRLayout.removeRuby(oriented)
        // Read every line first: where a line's glyphs sit is judged against
        // the glyph size of the whole page.
        var read: [(line: PDFOCRLine, crop: (x: Int, y: Int), part: Range<Int>, tokens: [PDFOCRToken],
                    text: PDFOCRInk?, size: (width: Int, height: Int))] = []
        for line in lines {
            let box = line.rect.ocrClamped(width: CGFloat(page.width), height: CGFloat(page.height))
            guard box.width >= 1, box.height >= 1, let crop = page.blockCrop(box) else { continue }
            for part in Self.splitAtGaps(crop.bitmap, vertical: line.vertical) {
                try Task.checkCancellation()
                let bitmap: MangaOCRBitmap
                if line.vertical {
                    bitmap = crop.bitmap.cropped(x: 0, y: part.lowerBound, width: crop.bitmap.width, height: part.count)
                } else {
                    // A little margin above and below the detector box: same
                    // accuracy, and smaller glyphs give the recognizer a
                    // narrower, faster input. More margin starts to pull in ruby.
                    let extra = crop.bitmap.height / 10
                    let top = max(0, crop.y - extra), bottom = min(page.height, crop.y + crop.bitmap.height + extra)
                    bitmap = page.cropped(x: crop.x + part.lowerBound, y: top, width: part.count, height: bottom - top)
                }
                let glyphs = line.vertical ? bitmap : crop.bitmap.cropped(x: part.lowerBound, y: 0, width: part.count, height: crop.bitmap.height)
                let mask = PDFOCRInk(glyphs)
                let tokens: [PDFOCRToken]
                if line.vertical {
                    guard let mask, let reading = PDFPageOCRLayout.lineInk(width: glyphs.width, height: glyphs.height, vertical: true,
                                                                           isInk: mask.isInk, cleaned: false) else { continue }
                    tokens = try Self.recognizeColumn(bitmap, ink: mask, band: reading.band, along: reading.along, recognizer: recognizer)
                } else {
                    tokens = try recognizer.recognizeLineTokens(bitmap)
                }
                guard !tokens.isEmpty else { continue }
                // Boxes come from the ink alone. Ink nearer another line's
                // centre (the next column, ruby), relative to each line's
                // thickness, is that line's, even inside this line's padded box.
                let origin = CGFloat(line.vertical ? crop.x : crop.y)
                let start = CGFloat((line.vertical ? crop.y : crop.x) + part.lowerBound)
                let own = (line.vertical ? line.rect.midX : line.rect.midY) - origin
                let neighbours = PDFPageOCRLayout.neighbours(of: line, among: oriented, along: start..<(start + CGFloat(part.count)))
                let text = neighbours.isEmpty ? mask : mask?.filter { x, y in
                    let position = CGFloat(line.vertical ? x : y) + 0.5
                    return neighbours.allSatisfy {
                        Swift.abs(position - own) / line.thickness <= Swift.abs(position - ($0.centre - origin)) / $0.thickness
                    }
                }
                read.append((line, (crop.x, crop.y), part, tokens, text, (glyphs.width, glyphs.height)))
            }
        }
        let inks = read.map { entry in
            entry.text.flatMap { PDFPageOCRLayout.lineInk(width: entry.size.width, height: entry.size.height, vertical: entry.line.vertical,
                                                          isInk: $0.isInk) }
        }
        // The detector box is centred on its text and scales with it, so the
        // page's typical band-to-box ratio predicts each line's glyph size.
        func ratio(vertical: Bool) -> Double? {
            let ratios = zip(read, inks).compactMap { entry, ink in
                entry.line.vertical == vertical ? ink.map { Double($0.band.count) / Double(entry.line.thickness) } : nil
            }.sorted()
            return ratios.count >= 3 ? ratios[ratios.count / 2] : nil
        }
        let ratios = (vertical: ratio(vertical: true), horizontal: ratio(vertical: false))
        var result: [PDFOCRRecognizedLine] = []
        for (entry, ink) in zip(read, inks) {
            let line = entry.line, part = entry.part
            var tokens = entry.tokens
            var across = 0..<(line.vertical ? entry.size.width : entry.size.height)
            if let text = entry.text, let ink {
                let expected = (line.vertical ? ratios.vertical : ratios.horizontal).map { Int(($0 * Double(line.thickness)).rounded()) }
                (tokens, across) = PDFPageOCRLayout.place(tokens, ink: (ink.band, ink.across), width: entry.size.width, height: entry.size.height,
                                                          vertical: line.vertical, glyph: expected, isInk: text.isInk)
            }
            let rect = line.vertical
                ? CGRect(x: entry.crop.x + across.lowerBound, y: entry.crop.y + part.lowerBound, width: across.count, height: part.count)
                : CGRect(x: entry.crop.x + part.lowerBound, y: entry.crop.y + across.lowerBound, width: part.count, height: across.count)
            result.append(.init(line: .init(rect: rect, vertical: line.vertical), tokens: tokens))
        }
        return result
    }

    /// The detector can bridge a narrow gutter or a gap between tiers of
    /// vertical text. Split a line wherever its ink pauses for more than
    /// about two glyphs; ordinary spacing inside a line never does.
    private static func splitAtGaps(_ bitmap: MangaOCRBitmap, vertical: Bool) -> [Range<Int>] {
        let length = vertical ? bitmap.height : bitmap.width
        guard let ink = PDFOCRInk(bitmap) else { return [0..<length] }
        var profile = [Int](repeating: 0, count: length)
        var across = [Int](repeating: 0, count: vertical ? bitmap.width : bitmap.height)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where ink.isInk(x, y) {
                profile[vertical ? y : x] += 1
                across[vertical ? x : y] += 1
            }
        }
        guard let first = across.firstIndex(where: { $0 > 0 }), let last = across.lastIndex(where: { $0 > 0 }) else { return [] }
        return PDFPageOCRLayout.segments(profile: profile, minimumGap: Int((CGFloat(last - first + 1) * 1.8).rounded()))
    }

    /// Read a vertical column as a horizontal line of upright glyphs: cut it
    /// into em-box cells and lay them out left to right. Rotating the whole
    /// column instead turns every glyph sideways, and the recognizer then
    /// drops small kana, punctuation, brackets and ー. Token centres map back
    /// to their cell, so each character gets its exact em box.
    /// `band` is the column's ink across and `along` its ink per row.
    private static func recognizeColumn(
        _ column: MangaOCRBitmap, ink: PDFOCRInk, band: Range<Int>, along: [Int], recognizer: MangaPPLineRecognizer
    ) throws -> [PDFOCRToken] {
        let width = column.width, height = column.height
        let runs = PDFPageOCRLayout.segments(profile: along, minimumGap: 1)
        let (pitch, cells) = PDFPageOCRLayout.glyphCells(runs: runs, glyphWidth: CGFloat(band.count), length: height)
        guard !cells.isEmpty, pitch >= 4 else { return [] }

        let slot = max(width, Int(pitch.rounded()))
        let gap = max(1, slot / 8)
        let stripWidth = cells.count * (slot + gap) + gap
        var strip = [UInt8](repeating: 0, count: stripWidth * slot * 3)
        for index in 0..<(stripWidth * slot) {
            strip[index * 3] = ink.paper.0; strip[index * 3 + 1] = ink.paper.1; strip[index * 3 + 2] = ink.paper.2
        }
        func copy(fromX sx: Int, y sy: Int, toX dx: Int, y dy: Int) {
            guard dx >= 0, dx < stripWidth, dy >= 0, dy < slot else { return }
            let source = (sy * width + sx) * 3, destination = (dy * stripWidth + dx) * 3
            strip[destination] = column.pixels[source]
            strip[destination + 1] = column.pixels[source + 1]
            strip[destination + 2] = column.pixels[source + 2]
        }
        for (index, cell) in cells.enumerated() {
            var minX = width, maxX = -1, minY = cell.upperBound, maxY = cell.lowerBound - 1
            for y in cell {
                for x in band where ink.isInk(x, y) {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { continue }
            let inkWidth = maxX - minX + 1, inkHeight = maxY - minY + 1
            let origin = gap + index * (slot + gap)
            let em = CGFloat(slot)
            if CGFloat(inkWidth) < em * 0.55 && CGFloat(inkHeight) < em * 0.55 {
                // Small kana and 、。 sit top-right in vertical text and
                // bottom-left in horizontal text.
                let left = origin + Int(em * 0.12), top = slot - inkHeight - Int(em * 0.12)
                for y in 0..<inkHeight { for x in 0..<inkWidth { copy(fromX: minX + x, y: minY + y, toX: left + x, y: top + y) } }
            } else if CGFloat(inkWidth) < em * 0.3 && CGFloat(inkHeight) >= em * 0.5 {
                // Vertical-form bars (ー, ︙, ―) turn back into horizontal ones.
                let left = origin + (slot - inkHeight) / 2, top = (slot - inkWidth) / 2
                for y in 0..<inkHeight { for x in 0..<inkWidth { copy(fromX: minX + x, y: minY + y, toX: left + y, y: top + (inkWidth - 1 - x)) } }
            } else {
                let left = origin + (slot - inkWidth) / 2, top = (slot - inkHeight) / 2
                for y in 0..<inkHeight { for x in 0..<inkWidth { copy(fromX: minX + x, y: minY + y, toX: left + x, y: top + y) } }
            }
        }
        let tokens = try recognizer.recognizeLineTokens(MangaOCRBitmap(width: stripWidth, height: slot, pixels: strip))
        // Assign tokens to cells; several tokens in one cell share it evenly.
        var perCell = [[PDFOCRToken]](repeating: [], count: cells.count)
        for token in tokens {
            let x = token.center * Double(stripWidth)
            let index = min(cells.count - 1, max(0, Int((x - Double(gap) / 2) / Double(slot + gap))))
            perCell[index].append(token)
        }
        var result: [PDFOCRToken] = []
        for (cell, members) in zip(cells, perCell) where !members.isEmpty {
            let step = Double(cell.count) / Double(members.count)
            for (offset, token) in members.enumerated() {
                let lower = (Double(cell.lowerBound) + step * Double(offset)) / Double(height)
                let upper = (Double(cell.lowerBound) + step * Double(offset + 1)) / Double(height)
                result.append(PDFOCRToken(text: token.text, center: (lower + upper) / 2, extent: lower...upper))
            }
        }
        return result
    }
}

/// Ink mask of a crop: pixels darker than the midpoint between its darkest
/// and lightest luminance, plus the mean paper colour.
nonisolated struct PDFOCRInk {
    let width: Int
    private var mask: [Bool]
    let paper: (UInt8, UInt8, UInt8)

    init?(_ bitmap: MangaOCRBitmap) {
        let count = bitmap.width * bitmap.height
        guard count > 0 else { return nil }
        var luminance = [UInt8](repeating: 255, count: count)
        var darkest: UInt8 = 255, lightest: UInt8 = 0
        bitmap.pixels.withUnsafeBufferPointer { pixels in
            for index in 0..<count {
                let red = Int(pixels[index * 3]) * 77
                let green = Int(pixels[index * 3 + 1]) * 150
                let blue = Int(pixels[index * 3 + 2]) * 29
                let value = UInt8((red + green + blue) >> 8)
                luminance[index] = value
                darkest = min(darkest, value); lightest = max(lightest, value)
            }
        }
        guard Int(lightest) - Int(darkest) >= 48 else { return nil }
        let threshold = UInt8((Int(darkest) + Int(lightest)) / 2)
        var mask = [Bool](repeating: false, count: count)
        var sums = (0, 0, 0), papers = 0
        for index in 0..<count {
            if luminance[index] < threshold {
                mask[index] = true
            } else {
                sums.0 += Int(bitmap.pixels[index * 3]); sums.1 += Int(bitmap.pixels[index * 3 + 1]); sums.2 += Int(bitmap.pixels[index * 3 + 2])
                papers += 1
            }
        }
        width = bitmap.width
        self.mask = mask
        paper = papers > 0 ? (UInt8(sums.0 / papers), UInt8(sums.1 / papers), UInt8(sums.2 / papers)) : (255, 255, 255)
    }

    func isInk(_ x: Int, _ y: Int) -> Bool { mask[y * width + x] }

    /// The same mask without the ink pixels `keep` rejects.
    func filter(_ keep: (Int, Int) -> Bool) -> PDFOCRInk {
        var copy = self
        for index in mask.indices where mask[index] && !keep(index % width, index / width) { copy.mask[index] = false }
        return copy
    }
}
