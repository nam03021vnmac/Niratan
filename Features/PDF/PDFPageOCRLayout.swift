import CoreGraphics
import Foundation

/// One CTC token with its centre along the line, as a 0…1 fraction.
nonisolated struct PDFOCRToken: Sendable, Equatable {
    var text: String
    var center: Double
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
            for (token, range) in zip(tokens, ranges) {
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

    /// Split a vertical column into em-box cells from its row ink runs
    /// (`start..<end` in pixels, top to bottom). Full-size glyphs anchor the
    /// grid, so pitch error never accumulates along a long column; strokes of
    /// one glyph separated by blank rows (二, 宀) share a cell, and small kana
    /// and punctuation keep their own cell.
    static func verticalCells(runs: [Range<Int>], glyphWidth: CGFloat, length: Int) -> (pitch: CGFloat, cells: [Range<Int>]) {
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
}
