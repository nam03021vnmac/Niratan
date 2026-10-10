import Foundation
import CoreGraphics

nonisolated struct PDFLibraryItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var bookmark: Data
    var sourcePath: String
    var resourceIdentity: String? = nil
    var pageCount: Int
    var pageIndex: Int = 0
    var position: CGPoint = CGPoint(x: 0, y: 1)
    var continuous: Bool = true
    var fitWidth: Bool = false
    var zoomScale: Double? = nil
    var automaticOCR: Bool = true
    var lastOpened: Date = .distantPast

    var progress: Double { pageCount > 1 ? Double(pageIndex) / Double(pageCount - 1) : 0 }
}

nonisolated struct PDFLibraryCatalog: Codable, Sendable {
    var version = 1
    var items: [PDFLibraryItem] = []
}

/// Ranges are block-relative UTF-16; rectangles are unrotated PDF page points.
nonisolated struct PDFTextSpan: Codable, Sendable {
    var location: Int
    var length: Int
    var rect: CGRect
    var estimated: Bool = false
}

nonisolated struct PDFTextBlock: Codable, Sendable {
    var text: String
    var vertical: Bool
    var spans: [PDFTextSpan]

    func hit(at point: CGPoint) -> PDFTextSpan? {
        spans.filter { $0.rect.contains(point) }.min {
            $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height
        }
    }

    func rectangles(for range: NSRange) -> [CGRect] {
        spans.filter { NSIntersectionRange(NSRange(location: $0.location, length: $0.length), range).length > 0 }
            .map(\.rect)
    }

    var isValid: Bool {
        let count = text.utf16.count
        return count <= 200_000 && spans.count <= 200_000 && spans.allSatisfy {
            $0.location >= 0 && $0.length > 0 && $0.location <= count && $0.length <= count - $0.location
                && PDFTextGeometry.valid($0.rect)
        }
    }
}

nonisolated struct PDFPageText: Codable, Sendable {
    var native: [PDFTextBlock] = []
    var recognized: [PDFTextBlock] = []

    func hit(at point: CGPoint) -> (block: PDFTextBlock, span: PDFTextSpan)? {
        // A native glyph always wins over supplemental OCR.
        for block in native + recognized {
            if let span = block.hit(at: point) { return (block, span) }
        }
        return nil
    }
}

nonisolated enum PDFTextGeometry {
    /// Join geometrically adjacent soft-wrapped lines/columns, not whole page
    /// strings. Sentence endings, distinct columns and smaller ruby text stay
    /// separate. Search only a bounded set of active paragraph tails.
    static func joinWrappedLines(_ blocks: [PDFTextBlock]) -> [PDFTextBlock] {
        struct Line {
            var block: PDFTextBlock
            var bounds: CGRect
            var glyph: CGSize
        }
        let lines = blocks.filter { !$0.spans.isEmpty }.map { block in
            Line(block: block, bounds: block.spans.reduce(.null) { $0.union($1.rect) },
                 glyph: CGSize(width: block.spans.map { $0.rect.width }.max() ?? 0,
                               height: block.spans.map { $0.rect.height }.max() ?? 0))
        }.sorted {
            if $0.block.vertical != $1.block.vertical { return !$0.block.vertical }
            if $0.block.vertical { return $0.bounds.midX > $1.bounds.midX }
            if $0.bounds.maxY != $1.bounds.maxY { return $0.bounds.maxY > $1.bounds.maxY }
            return $0.bounds.minX < $1.bounds.minX
        }
        func joins(_ previous: Line, _ next: Line) -> Bool {
            guard previous.block.vertical == next.block.vertical,
                  !(previous.block.text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { "。！？.!?".contains($0) } ?? false),
                  min(previous.glyph.height, next.glyph.height) / max(previous.glyph.height, next.glyph.height) > 0.72 else { return false }
            if previous.block.vertical {
                let gap = previous.bounds.minX - next.bounds.maxX
                return min(previous.glyph.width, next.glyph.width) / max(previous.glyph.width, next.glyph.width) > 0.72
                    && gap >= -previous.glyph.width * 0.3 && gap <= previous.glyph.width
                    && Swift.abs(previous.bounds.maxY - next.bounds.maxY) <= previous.glyph.height * 2
            }
            let gap = previous.bounds.minY - next.bounds.maxY
            let overlap = max(0, min(previous.bounds.maxX, next.bounds.maxX) - max(previous.bounds.minX, next.bounds.minX))
            return gap >= -previous.glyph.height * 0.3 && gap <= previous.glyph.height
                && Swift.abs(previous.bounds.minX - next.bounds.minX) <= previous.glyph.width * 2
                && overlap >= min(previous.bounds.width, next.bounds.width) * 0.8
        }
        var groups: [[Line]] = []
        for line in lines {
            if let index = groups.indices.reversed().prefix(32).first(where: { joins(groups[$0].last!, line) }) {
                groups[index].append(line)
            } else { groups.append([line]) }
        }
        return groups.map { group in
            var result = PDFTextBlock(text: "", vertical: group[0].block.vertical, spans: [])
            var offset = 0
            for line in group {
                result.text += line.block.text
                result.spans += line.block.spans.map { var span = $0; span.location += offset; return span }
                offset += line.block.text.utf16.count
            }
            return result
        }
    }

    static func fittedScale(pageSize: CGSize, viewport: CGSize, fitWidth: Bool) -> Double? {
        guard pageSize.width.isFinite, pageSize.height.isFinite, viewport.width.isFinite, viewport.height.isFinite,
              pageSize.width > 0, pageSize.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        let width = viewport.width / pageSize.width
        let scale = fitWidth ? width : min(width, viewport.height / pageSize.height)
        return Double(max(0.1, min(8, scale)))
    }

    static func clipOrigin(target: CGPoint, viewport: CGSize, flipped: Bool, anchorInset: CGFloat) -> CGPoint {
        let inset = min(anchorInset, viewport.height / 2)
        return CGPoint(x: target.x - viewport.width / 2,
                       y: flipped ? target.y - inset : target.y - viewport.height + inset)
    }

    /// PDFKit can report each glyph in a vertical content stream as its own
    /// horizontal line. Join only adjacent, similarly sized fragments sharing
    /// a column; never concatenate spatially separated columns or ruby runs.
    static func joinVerticalFragments(_ blocks: [PDFTextBlock]) -> [PDFTextBlock] {
        let singles = blocks.filter { $0.spans.count == 1 }.sorted { $0.spans[0].rect.midX > $1.spans[0].rect.midX }
        var columns: [[PDFTextBlock]] = []
        for block in singles {
            let rect = block.spans[0].rect
            if let reference = columns.last?.first?.spans.first?.rect,
               Swift.abs(reference.midX - rect.midX) < min(reference.width, rect.width) * 0.4 {
                columns[columns.count - 1].append(block)
            } else { columns.append([block]) }
        }
        var result = blocks.filter { $0.spans.count != 1 }
        var column: PDFTextBlock?
        for single in columns.flatMap({ $0.sorted { $0.spans[0].rect.midY > $1.spans[0].rect.midY } }) {
            let rect = single.spans[0].rect
            if var previous = column, let last = previous.spans.last,
               Swift.abs(last.rect.midX - rect.midX) < min(last.rect.width, rect.width) * 0.4,
               last.rect.midY - rect.midY > min(last.rect.height, rect.height) * 0.5,
               last.rect.midY - rect.midY < max(last.rect.height, rect.height) * 2,
               min(last.rect.height, rect.height) / max(last.rect.height, rect.height) > 0.7 {
                let offset = previous.text.utf16.count
                previous.text += single.text
                previous.spans += single.spans.map { var span = $0; span.location += offset; return span }
                previous.vertical = true
                column = previous
            } else {
                if let column { result.append(column) }
                column = single
            }
        }
        if let column { result.append(column) }
        return result
    }

    static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0 && !rect.isNull
    }

    /// Vision and PDF both use bottom-left coordinates. The raster transform
    /// includes crop origin and intrinsic rotation; invert that exact transform.
    static func pageRect(normalized: CGRect, pixels: CGSize, transform: CGAffineTransform) -> CGRect {
        CGRect(x: normalized.minX * pixels.width, y: normalized.minY * pixels.height,
               width: normalized.width * pixels.width, height: normalized.height * pixels.height)
            .applying(transform.inverted())
    }

    static func needsOCR(_ blocks: [PDFTextBlock]) -> Bool {
        let text = blocks.map(\.text).joined()
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !scalars.isEmpty, blocks.contains(where: { !$0.spans.isEmpty }) else { return true }
        let invalid = scalars.filter {
            $0.value == 0xfffd || CharacterSet.controlCharacters.contains($0)
                || (0xe000...0xf8ff).contains($0.value)
        }.count
        return invalid * 2 > scalars.count
    }
}

/// Which engine reads scanned or image-only pages. Automatic uses PP-OCR once
/// its models are downloaded and Apple Vision until then.
nonisolated enum PDFOCREngineChoice: String, CaseIterable, Sendable {
    case automatic, paddle, vision

    static let defaultsKey = "pdfOCREngine"

    static func stored(_ defaults: UserDefaults = .standard) -> PDFOCREngineChoice {
        defaults.string(forKey: defaultsKey).flatMap(PDFOCREngineChoice.init(rawValue:)) ?? .automatic
    }
}

nonisolated enum PDFSupportError: LocalizedError {
    case unreadable, locked, permission, catalog, changed, geometry, modelsMissing
    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "Unable to read this PDF. Locate the file or import a valid PDF.")
        case .locked: String(localized: "This PDF is locked. Enter its password to read it.")
        case .permission: String(localized: "This PDF does not allow text extraction.")
        case .catalog: String(localized: "The PDF library could not be read. Its existing data has been preserved.")
        case .changed: String(localized: "The PDF changed during reading. Close it and open it again.")
        case .geometry: String(localized: "This PDF page is too large or has invalid dimensions.")
        case .modelsMissing: String(localized: "Download the PP-OCR models from the Japanese OCR menu, or choose another engine.")
        }
    }
}
