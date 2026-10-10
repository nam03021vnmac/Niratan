// test-sources: Models/PDF.swift Features/PDF/PDFPageOCRLayout.swift
import Foundation
import CoreGraphics

@main
private enum PDFPageOCRLayoutTests {
    static func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.01) -> Bool { abs(a - b) < eps }

    static func main() {
        // Orientation: unambiguous lines keep their axis, short boxes follow the page.
        let verticalPage = [CGRect(x: 300, y: 50, width: 30, height: 400), CGRect(x: 250, y: 50, width: 30, height: 380),
                            CGRect(x: 200, y: 50, width: 30, height: 40), CGRect(x: 10, y: 10, width: 3, height: 3)]
        let oriented = PDFPageOCRLayout.orient(verticalPage)
        precondition(oriented.count == 3, "noise below the minimum thickness is dropped")
        precondition(oriented.allSatisfy(\.vertical), "a one-glyph box follows the vertical page")
        let horizontalPage = [CGRect(x: 20, y: 50, width: 400, height: 30), CGRect(x: 20, y: 100, width: 30, height: 30)]
        precondition(PDFPageOCRLayout.orient(horizontalPage).allSatisfy { !$0.vertical }, "ties and majority are horizontal")

        // Ruby: thin line hugging the ruby side is removed; other thin text stays.
        let body = PDFOCRLine(rect: CGRect(x: 40, y: 100, width: 400, height: 30), vertical: false)
        let ruby = PDFOCRLine(rect: CGRect(x: 80, y: 90, width: 120, height: 14), vertical: false)
        let footnoteBelow = PDFOCRLine(rect: CGRect(x: 40, y: 140, width: 300, height: 16), vertical: false)
        let farCaption = PDFOCRLine(rect: CGRect(x: 40, y: 20, width: 200, height: 14), vertical: false)
        let kept = PDFPageOCRLayout.removeRuby([body, ruby, footnoteBelow, farCaption])
        precondition(kept == [body, footnoteBelow, farCaption], "only the attached ruby is removed")
        let verticalLine = PDFOCRLine(rect: CGRect(x: 300, y: 50, width: 30, height: 400), vertical: true)
        let rightRuby = PDFOCRLine(rect: CGRect(x: 328, y: 80, width: 14, height: 150), vertical: true)
        let leftThin = PDFOCRLine(rect: CGRect(x: 280, y: 80, width: 14, height: 150), vertical: true)
        let verticalKept = PDFPageOCRLayout.removeRuby([verticalLine, rightRuby, leftThin])
        precondition(verticalKept == [verticalLine, leftThin], "vertical ruby is on the right of the column")

        // Character ranges tile a uniform line and cap lone glyphs.
        let centers = [0.1, 0.3, 0.5, 0.7, 0.9]
        let ranges = PDFPageOCRLayout.characterRanges(centers: centers, length: 200, thickness: 40)
        precondition(ranges.count == 5)
        precondition(zip(ranges, ranges.dropFirst()).allSatisfy { near(CGFloat($0.upperBound), CGFloat($1.lowerBound), 1e-9) },
                     "adjacent glyph boxes meet without overlap")
        precondition(near(CGFloat(ranges[0].lowerBound), 0, 1e-9) && near(CGFloat(ranges[4].upperBound), 1, 1e-9))
        let lone = PDFPageOCRLayout.characterRanges(centers: [0.5], length: 400, thickness: 40)[0]
        precondition(lone.upperBound - lone.lowerBound <= 0.151, "a lone glyph is not stretched over the whole line")
        precondition(PDFPageOCRLayout.characterRanges(centers: [], length: 100, thickness: 10).isEmpty)

        // Raster → PDF page: 2x scale, raster rows grow downwards.
        let transform = CGAffineTransform(scaleX: 2, y: 2)
        let pixels = CGSize(width: 400, height: 600)
        let crop = CGRect(x: 0, y: 0, width: 200, height: 300)
        let horizontal = PDFOCRRecognizedLine(
            line: .init(rect: CGRect(x: 40, y: 100, width: 200, height: 40), vertical: false),
            tokens: zip("日本語です", centers).map { PDFOCRToken(text: String($0), center: $1) })
        let blocks = PDFPageOCRLayout.blocks([horizontal], pixels: pixels, transform: transform, crop: crop)
        precondition(blocks.count == 1 && blocks[0].text == "日本語です" && blocks[0].spans.count == 5)
        precondition(blocks[0].isValid)
        let first = blocks[0].spans[0].rect
        precondition(near(first.minX, 20) && near(first.width, 20) && near(first.minY, 230) && near(first.height, 20), "\(first)")
        precondition(blocks[0].hit(at: CGPoint(x: 51, y: 240))?.location == 1, "a click lands on the second glyph")

        // Vertical columns: reading axis is top to bottom; neighbouring columns of one paragraph join.
        func column(x: CGFloat, text: String) -> PDFOCRRecognizedLine {
            let count = text.count
            return .init(line: .init(rect: CGRect(x: x, y: 60, width: 40, height: 400), vertical: true),
                         tokens: text.enumerated().map { PDFOCRToken(text: String($0.element), center: (Double($0.offset) + 0.5) / Double(count)) })
        }
        let right = column(x: 300, text: "あいうえおかきくけこ")
        let left = column(x: 252, text: "さしすせそたちつてと")
        let joined = PDFPageOCRLayout.blocks([left, right], pixels: pixels, transform: transform, crop: crop)
        precondition(joined.count == 1 && joined[0].vertical, "adjacent columns form one paragraph")
        precondition(joined[0].text == "あいうえおかきくけこさしすせそたちつてと", "right-to-left reading order")
        let top = joined[0].spans[0].rect
        precondition(near(top.minY, 250) && near(top.height, 20) && near(top.minX, 150) && near(top.width, 20), "\(top)")
        let ending = column(x: 300, text: "終わりです。")
        let following = column(x: 252, text: "次の段落")
        precondition(PDFPageOCRLayout.blocks([ending, following], pixels: pixels, transform: transform, crop: crop).count == 2,
                     "a sentence end keeps paragraphs separate")
        // Out-of-crop and empty tokens never produce invalid spans.
        let outside = PDFOCRRecognizedLine(line: .init(rect: CGRect(x: 900, y: 900, width: 40, height: 40), vertical: false),
                                           tokens: [PDFOCRToken(text: "外", center: 0.5)])
        precondition(PDFPageOCRLayout.blocks([outside], pixels: pixels, transform: transform, crop: crop).isEmpty)
        print("PDF page OCR layout tests passed")
    }
}
