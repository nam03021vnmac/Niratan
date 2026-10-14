import CoreGraphics
import Foundation

/// One CTC token with its centre along the line, as a 0…1 fraction, and,
/// once matched to a glyph found in the ink, that glyph's extent.
nonisolated struct PDFOCRToken: Sendable, Equatable {
    var text: String
    var center: Double
    var extent: ClosedRange<Double>? = nil
}

/// A detected text line in raster pixels (top-left origin).
nonisolated struct PDFOCRLine: Sendable, Equatable {
    var rect: CGRect
    var vertical: Bool

    /// Extent across the reading direction: the glyph size.
    var thickness: CGFloat { vertical ? rect.width : rect.height }
    var length: CGFloat { vertical ? rect.height : rect.width }
}

nonisolated struct PDFOCRRecognizedLine: Sendable, Equatable {
    var line: PDFOCRLine
    var tokens: [PDFOCRToken]
}

/// A line-based page recognizer (PP-OCR). Kept as a protocol so the document
/// worker does not depend on ONNX Runtime.
nonisolated protocol PDFLineRecognizing: Sendable {
    /// Changes whenever results for the same page may change.
    var identity: String { get }
    func recognize(image: CGImage) async throws -> [PDFOCRRecognizedLine]
}

/// Geometry for full-page, line-based OCR of dense books: orientation,
/// ruby removal, per-character boxes and conversion to PDF page space.
/// Pure and engine-agnostic so it can be tested without ONNX.
nonisolated enum PDFPageOCRLayout {
    /// Lines at least this much longer than they are thick have a clear axis.
    static let aspectThreshold: CGFloat = 1.5
    static let minimumThickness: CGFloat = 6

    /// Orient raw detector boxes. Boxes without a clear axis (a one- or
    /// two-glyph line) follow the page's majority direction; ties are
    /// horizontal.
    static func orient(_ rects: [CGRect]) -> [PDFOCRLine] {
        let usable = rects.filter { $0.width >= 2 && $0.height >= 2 && min($0.width, $0.height) >= minimumThickness }
        let vertical = usable.filter { $0.height >= $0.width * aspectThreshold }.count
        let horizontal = usable.filter { $0.width >= $0.height * aspectThreshold }.count
        let pageVertical = vertical > horizontal
        return usable.map { rect in
            if rect.height >= rect.width * aspectThreshold { return PDFOCRLine(rect: rect, vertical: true) }
            if rect.width >= rect.height * aspectThreshold { return PDFOCRLine(rect: rect, vertical: false) }
            return PDFOCRLine(rect: rect, vertical: pageVertical)
        }
    }

    /// Drop furigana: a clearly thinner line hugging the ruby side of a
    /// thicker line of the same orientation (above horizontal text, to the
    /// right of vertical text) and overlapping it along the reading axis.
    /// Small footnotes, captions and headings elsewhere on the page stay.
    static func removeRuby(_ lines: [PDFOCRLine], thicknessRatio: CGFloat = 0.75) -> [PDFOCRLine] {
        lines.enumerated().filter { index, line in
            !lines.enumerated().contains { otherIndex, base in
                guard otherIndex != index, base.vertical == line.vertical,
                      line.thickness < base.thickness * thicknessRatio else { return false }
                let overlap: CGFloat
                let gap: CGFloat
                if line.vertical {
                    overlap = min(line.rect.maxY, base.rect.maxY) - max(line.rect.minY, base.rect.minY)
                    gap = line.rect.minX - base.rect.maxX
                } else {
                    overlap = min(line.rect.maxX, base.rect.maxX) - max(line.rect.minX, base.rect.minX)
                    gap = base.rect.minY - line.rect.maxY
                }
                // Detector boxes are padded, so touching text overlaps a little.
                return overlap >= line.length * 0.5
                    && gap >= -line.thickness && gap <= base.thickness * 0.4
            }
        }.map(\.element)
    }

    /// Fractions `[start, end]` along the line for each token. Boundaries are
    /// midpoints between neighbouring token centres; the outer edges mirror
    /// the neighbouring gap. A glyph never extends further than `thickness`
    /// from its own centre (a full-width glyph is about square).
    static func characterRanges(centers: [Double], length: CGFloat, thickness: CGFloat) -> [ClosedRange<Double>] {
        guard !centers.isEmpty, length > 0 else { return [] }
        let reach = Double(thickness / length) * 0.75
        return centers.indices.map { index in
            let center = centers[index]
            let previous = index > 0 ? centers[index - 1] : nil
            let next = index + 1 < centers.count ? centers[index + 1] : nil
            let leftGap = previous.map { center - $0 } ?? next.map { $0 - center } ?? reach * 2
            let rightGap = next.map { $0 - center } ?? previous.map { center - $0 } ?? reach * 2
            let start = max(0, center - min(leftGap / 2, reach))
            let end = min(1, center + min(rightGap / 2, reach))
            return start...max(start + 1e-6, end)
        }
    }

    /// Convert recognised lines to PDF blocks. `pixels` is the raster size
    /// and `transform` the page-to-raster drawing transform; rectangles are
    /// intersected with `crop`.
    static func blocks(
        _ lines: [PDFOCRRecognizedLine],
        pixels: CGSize,
        transform: CGAffineTransform,
        crop: CGRect
    ) -> [PDFTextBlock] {
        guard pixels.width > 0, pixels.height > 0 else { return [] }
        var result: [PDFTextBlock] = []
        for recognized in lines {
            let line = recognized.line
            let tokens = recognized.tokens.filter { !$0.text.isEmpty }
            guard !tokens.isEmpty else { continue }
            let ranges = characterRanges(centers: tokens.map(\.center), length: line.length, thickness: line.thickness)
            var block = PDFTextBlock(text: "", vertical: line.vertical, spans: [])
            for (token, estimate) in zip(tokens, ranges) {
                let range = token.extent ?? estimate
                let location = block.text.utf16.count
                block.text += token.text
                guard !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let raster: CGRect
                if line.vertical {
                    raster = CGRect(x: line.rect.minX, y: line.rect.minY + range.lowerBound * line.rect.height,
                                    width: line.rect.width, height: (range.upperBound - range.lowerBound) * line.rect.height)
                } else {
                    raster = CGRect(x: line.rect.minX + range.lowerBound * line.rect.width, y: line.rect.minY,
                                    width: (range.upperBound - range.lowerBound) * line.rect.width, height: line.rect.height)
                }
                // Raster rows grow downwards; `pageRect` expects bottom-left.
                let normalized = CGRect(x: raster.minX / pixels.width, y: 1 - raster.maxY / pixels.height,
                                        width: raster.width / pixels.width, height: raster.height / pixels.height)
                let rect = PDFTextGeometry.pageRect(normalized: normalized, pixels: pixels, transform: transform).intersection(crop)
                if PDFTextGeometry.valid(rect) {
                    block.spans.append(.init(location: location, length: token.text.utf16.count, rect: rect))
                }
            }
            if !block.spans.isEmpty { result.append(block) }
        }
        return readingOrder(PDFTextGeometry.joinWrappedLines(result, maxGap: 1.6))
    }

    /// Order paragraphs by column: horizontal text in left-to-right column
    /// bands (top to bottom inside a band), then vertical text in
    /// top-to-bottom bands (right to left inside a band). Bands are unions of
    /// overlapping extents, so a full-width heading simply merges them.
    static func readingOrder(_ blocks: [PDFTextBlock]) -> [PDFTextBlock] {
        let items = blocks.map { (block: $0, bounds: $0.spans.reduce(CGRect.null) { $0.union($1.rect) }) }
        func ordered(_ group: [(block: PDFTextBlock, bounds: CGRect)], vertical: Bool) -> [PDFTextBlock] {
            // Band axis: x for horizontal text, y (top first) for vertical.
            func band(_ rect: CGRect) -> (CGFloat, CGFloat) { vertical ? (-rect.maxY, -rect.minY) : (rect.minX, rect.maxX) }
            var bands: [(lower: CGFloat, upper: CGFloat, members: [(block: PDFTextBlock, bounds: CGRect)])] = []
            for item in group.sorted(by: { band($0.bounds).0 < band($1.bounds).0 }) {
                let (lower, upper) = band(item.bounds)
                if let last = bands.indices.last, lower < bands[last].upper {
                    bands[last].upper = max(bands[last].upper, upper)
                    bands[last].members.append(item)
                } else {
                    bands.append((lower, upper, [item]))
                }
            }
            return bands.flatMap { band in
                band.members.sorted { vertical ? $0.bounds.maxX > $1.bounds.maxX : $0.bounds.maxY > $1.bounds.maxY }.map(\.block)
            }
        }
        return ordered(items.filter { !$0.block.vertical }, vertical: false) + ordered(items.filter(\.block.vertical), vertical: true)
    }

    /// Runs of a non-zero ink profile, merging runs separated by fewer than
    /// `minimumGap` blank positions.
    static func segments(profile: [Int], minimumGap: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in 0...profile.count {
            let inked = index < profile.count && profile[index] > 0
            if inked, start == nil { start = index }
            if !inked, let begin = start {
                if let last = runs.last, begin - last.upperBound < minimumGap {
                    runs[runs.count - 1] = last.lowerBound..<index
                } else {
                    runs.append(begin..<index)
                }
                start = nil
            }
        }
        return runs
    }

    /// Split a line into em-box cells from its ink runs along the line
    /// (`start..<end` in pixels, in reading order). Full-size glyphs anchor the
    /// grid, so pitch error never accumulates along a long column; strokes of
    /// one glyph separated by blank rows (二, 宀) share a cell, and small kana
    /// and punctuation keep their own cell.
    static func glyphCells(runs: [Range<Int>], glyphWidth: CGFloat, length: Int) -> (pitch: CGFloat, cells: [Range<Int>]) {
        guard !runs.isEmpty, glyphWidth > 0 else { return (glyphWidth, []) }
        let large = runs.filter { CGFloat($0.count) >= glyphWidth * 0.6 }
        let centers = large.map { CGFloat($0.lowerBound + $0.upperBound) / 2 }
        let steps = zip(centers, centers.dropFirst()).map { $1 - $0 }.filter { $0 >= glyphWidth * 0.8 && $0 <= glyphWidth * 1.6 }.sorted()
        let pitch = steps.isEmpty ? glyphWidth * 1.05 : steps[steps.count / 2]
        var cells: [(start: CGFloat, range: Range<Int>)] = []
        for run in runs {
            let center = CGFloat(run.lowerBound + run.upperBound) / 2
            let anchor = centers.min { Swift.abs($0 - center) < Swift.abs($1 - center) }
            let start: CGFloat
            if let anchor {
                let origin = anchor - pitch / 2
                start = origin + floor((center - origin) / pitch) * pitch
            } else {
                start = CGFloat(run.lowerBound) - (pitch - CGFloat(run.count)) / 2
            }
            if let last = cells.last, Swift.abs(last.start - start) < pitch * 0.3 {
                cells[cells.count - 1].range = last.range.lowerBound..<max(last.range.upperBound, run.upperBound)
            } else {
                cells.append((start, run))
            }
        }
        // Each cell spans its em box, clipped so neighbours never overlap.
        var result: [Range<Int>] = []
        for (index, cell) in cells.enumerated() {
            var lower = max(0, min(cell.range.lowerBound, Int(cell.start.rounded())))
            var upper = min(length, max(cell.range.upperBound, Int((cell.start + pitch).rounded())))
            if let previous = result.last { lower = max(lower, previous.upperBound) }
            if index + 1 < cells.count { upper = min(upper, max(cell.range.upperBound, cells[index + 1].range.lowerBound)) }
            if upper > lower { result.append(lower..<upper) }
        }
        return (pitch, result)
    }

    /// Ink of a line crop. `band` is the main ink band across the line: the
    /// padded detector box can clip ruby or a neighbouring line, and those
    /// fragments carry far less ink. `along` counts ink inside the band.
    static func lineInk(width: Int, height: Int, vertical: Bool, isInk: (Int, Int) -> Bool) -> (band: Range<Int>, along: [Int])? {
        var across = [Int](repeating: 0, count: vertical ? width : height)
        for y in 0..<height {
            for x in 0..<width where isInk(x, y) { across[vertical ? x : y] += 1 }
        }
        guard let band = mainBand(across) else { return nil }
        var along = [Int](repeating: 0, count: vertical ? height : width)
        for y in 0..<height {
            for x in 0..<width where band.contains(vertical ? x : y) && isInk(x, y) { along[vertical ? y : x] += 1 }
        }
        return (band, along)
    }

    /// The heaviest run of an across-the-line ink profile, joined with nearby
    /// runs of comparable weight (the separate strokes of 二 or 三 in a short
    /// line) but not with light fragments at the edge.
    static func mainBand(_ across: [Int]) -> Range<Int>? {
        let runs = segments(profile: across, minimumGap: max(2, across.count / 16))
        func weight(_ run: Range<Int>) -> Int { across[run].reduce(0, +) }
        guard let heaviest = runs.indices.max(by: { weight(runs[$0]) < weight(runs[$1]) }) else { return nil }
        let minimum = Double(weight(runs[heaviest])) * 0.3
        let reach = max(2, across.count / 6)
        var lower = heaviest, upper = heaviest
        while lower > 0, runs[lower].lowerBound - runs[lower - 1].upperBound <= reach,
              Double(weight(runs[lower - 1])) >= minimum { lower -= 1 }
        while upper + 1 < runs.count, runs[upper + 1].lowerBound - runs[upper].upperBound <= reach,
              Double(weight(runs[upper + 1])) >= minimum { upper += 1 }
        return runs[lower].lowerBound..<runs[upper].upperBound
    }

    /// Move recognised tokens onto the glyph cells found in the ink: each
    /// token takes its cell's centre and extent, and tokens sharing a cell
    /// (two half-width digits) split it evenly. CTC positions are only a
    /// frame-accurate estimate that drifts along a line; the ink is exact.
    /// Whitespace keeps its estimate. Tokens are returned unchanged when the
    /// cells do not explain them.
    static func snap(_ tokens: [PDFOCRToken], cells: [Range<Int>], pitch: CGFloat, length: Int) -> [PDFOCRToken] {
        let glyphs = tokens.indices.filter { !tokens[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !glyphs.isEmpty, !cells.isEmpty, length > 0, pitch > 0,
              let assignment = align(glyphs.map { tokens[$0].center * Double(length) }, cells: cells, pitch: Double(pitch))
        else { return tokens }
        var result = tokens
        var start = 0
        while start < glyphs.count {
            var end = start
            while end + 1 < glyphs.count, assignment[end + 1] == assignment[start] { end += 1 }
            let cell = cells[assignment[start]]
            let step = Double(cell.count) / Double(end - start + 1)
            for offset in 0...(end - start) {
                let lower = (Double(cell.lowerBound) + step * Double(offset)) / Double(length)
                let upper = (Double(cell.lowerBound) + step * Double(offset + 1)) / Double(length)
                result[glyphs[start + offset]].center = (lower + upper) / 2
                result[glyphs[start + offset]].extent = lower...upper
            }
            start = end + 1
        }
        return result
    }

    /// Order-preserving assignment of token centres (pixels) to cells that
    /// minimises the distance from each centre to its cell, in pitches, plus
    /// a cost for every cell left empty (specks, an unread glyph) and every
    /// extra token sharing a cell. Nil when the centres sit on average more
    /// than half a glyph from their cells.
    static func align(_ centers: [Double], cells: [Range<Int>], pitch: Double) -> [Int]? {
        let n = centers.count, m = cells.count
        guard n > 0, m > 0, pitch > 0 else { return nil }
        let skip = 0.6, share = 0.6
        let middles = cells.map { Double($0.lowerBound + $0.upperBound) / 2 }
        func distance(_ i: Int, _ j: Int) -> Double { Swift.abs(centers[i] - middles[j]) / pitch }
        var cost = (0..<m).map { distance(0, $0) + skip * Double($0) }
        var parent = [[Int]](repeating: [Int](repeating: -1, count: m), count: n)
        for i in 1..<n {
            var next = [Double](repeating: .infinity, count: m)
            // Best earlier cell k < j, with the empty cells between charged.
            var best = Double.infinity, bestCell = -1
            for j in 0..<m {
                if j > 0, cost[j - 1] - skip * Double(j - 1) < best {
                    best = cost[j - 1] - skip * Double(j - 1); bestCell = j - 1
                }
                let fromEarlier = best + skip * Double(j - 1)
                let fromSame = cost[j] + share
                if fromSame <= fromEarlier {
                    next[j] = fromSame + distance(i, j); parent[i][j] = j
                } else {
                    next[j] = fromEarlier + distance(i, j); parent[i][j] = bestCell
                }
            }
            cost = next
        }
        guard var cell = (0..<m).min(by: { cost[$0] + skip * Double(m - 1 - $0) < cost[$1] + skip * Double(m - 1 - $1) }) else { return nil }
        var assignment = [Int](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            assignment[i] = cell
            if i > 0 { cell = parent[i][cell] }
        }
        let offset = (0..<n).reduce(0) { $0 + distance($1, assignment[$1]) } / Double(n)
        return offset <= 0.5 ? assignment : nil
    }
}
