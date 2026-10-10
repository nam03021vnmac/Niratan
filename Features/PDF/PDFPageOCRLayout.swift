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
    static func removeRuby(_ lines: [PDFOCRLine], thicknessRatio: CGFloat = 0.65) -> [PDFOCRLine] {
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
        return PDFTextGeometry.joinWrappedLines(result)
    }
}
