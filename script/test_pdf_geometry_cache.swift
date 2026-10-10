// test-sources: Models/PDF.swift Features/PDF/PDFTextCache.swift
import Foundation
import CoreGraphics

@main
private enum PDFGeometryCacheTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PDFTextCache(directory: root)
        let span = PDFTextSpan(location: 0, length: 2, rect: CGRect(x: 10, y: 20, width: 12, height: 18))
        let block = PDFTextBlock(text: "𠮷日本語", vertical: true, spans: [span])
        precondition(block.isValid)
        precondition(PDFTextGeometry.fittedScale(pageSize: CGSize(width: 500, height: 1000), viewport: CGSize(width: 1000, height: 700), fitWidth: false) == 0.7)
        precondition(PDFTextGeometry.fittedScale(pageSize: CGSize(width: 500, height: 1000), viewport: CGSize(width: 1000, height: 700), fitWidth: true) == 2)
        precondition(PDFTextGeometry.fittedScale(pageSize: .zero, viewport: CGSize(width: 1000, height: 700), fitWidth: true) == nil)
        precondition(PDFTextGeometry.clipOrigin(target: CGPoint(x: 200, y: 500), viewport: CGSize(width: 300, height: 200), flipped: true, anchorInset: 40) == CGPoint(x: 50, y: 460))
        precondition(PDFTextGeometry.clipOrigin(target: CGPoint(x: 200, y: 500), viewport: CGSize(width: 300, height: 200), flipped: false, anchorInset: 40) == CGPoint(x: 50, y: 340))
        precondition(block.hit(at: CGPoint(x: 15, y: 25))?.length == 2)
        precondition(block.hit(at: CGPoint(x: 25, y: 25)) == nil, "margin must not hit nearest glyph")
        precondition(block.rectangles(for: NSRange(location: 0, length: 2)).count == 1)
        precondition(PDFTextGeometry.needsOCR([]))
        precondition(!PDFTextGeometry.needsOCR([block]), "short valid text does not trigger OCR")
        let bad = PDFTextBlock(text: "��", vertical: false, spans: [span])
        precondition(PDFTextGeometry.needsOCR([bad]))
        let first = PDFTextBlock(text: "日本", vertical: false, spans: [
            .init(location: 0, length: 1, rect: CGRect(x: 10, y: 100, width: 20, height: 20)),
            .init(location: 1, length: 1, rect: CGRect(x: 30, y: 100, width: 20, height: 20)),
        ])
        let second = PDFTextBlock(text: "語", vertical: false, spans: [.init(location: 0, length: 1, rect: CGRect(x: 10, y: 74, width: 20, height: 20))])
        let wrapped = PDFTextGeometry.joinWrappedLines([second, first])
        precondition(wrapped.count == 1 && wrapped[0].text == "日本語")
        precondition(wrapped[0].spans.last?.location == 2, "soft-wrap range offsets remain source-correct")
        let otherColumn = PDFTextBlock(text: "別", vertical: false, spans: [.init(location: 0, length: 1, rect: CGRect(x: 200, y: 74, width: 20, height: 20))])
        precondition(PDFTextGeometry.joinWrappedLines([first, otherColumn]).count == 2)
        let ruby = PDFTextBlock(text: "にほん", vertical: false, spans: [.init(location: 0, length: 3, rect: CGRect(x: 10, y: 88, width: 20, height: 8))])
        precondition(PDFTextGeometry.joinWrappedLines([first, ruby]).count == 2, "smaller ruby text is not joined into base text")
        let native = PDFTextBlock(text: "日本", vertical: false, spans: [.init(location: 0, length: 1, rect: span.rect)])
        let page = PDFPageText(native: [native], recognized: [block])
        precondition(page.hit(at: CGPoint(x: 15, y: 25))?.block.text == "日本", "native takes precedence")
        for rotation in [0.0, .pi / 2, .pi, .pi * 1.5] {
            let transform = CGAffineTransform(translationX: 25, y: 40).rotated(by: rotation).scaledBy(x: 2, y: 2)
            let rect = CGRect(x: 30, y: 60, width: 10, height: 20)
            let raster = rect.applying(transform)
            let normalized = CGRect(x: raster.minX / 1000, y: raster.minY / 1000, width: raster.width / 1000, height: raster.height / 1000)
            let result = PDFTextGeometry.pageRect(normalized: normalized, pixels: CGSize(width: 1000, height: 1000), transform: transform)
            precondition(abs(result.minX - rect.minX) < 0.0001 && abs(result.minY - rect.minY) < 0.0001)
            precondition(abs(result.width - rect.width) < 0.0001 && abs(result.height - rect.height) < 0.0001)
        }
        try cache.save([block], identity: "revision1|page0")
        precondition(cache.load(identity: "revision1|page0")?.first?.text == block.text)
        precondition(cache.load(identity: "revision2|page0") == nil)
        try cache.save([], identity: "blank")
        precondition(cache.load(identity: "blank")?.isEmpty == true, "empty success is reusable")
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try Data("broken".utf8).write(to: file)
        }
        precondition(cache.load(identity: "revision1|page0") == nil)
        print("PDF geometry, UTF-16 ranges, fallback policy and cache tests passed")
    }
}
