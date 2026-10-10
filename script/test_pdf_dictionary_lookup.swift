// test-skip: Run through test_pdf_dictionary_lookup.sh (needs hoshidicts and a generated dictionary).
import Foundation
import CHoshiDicts
import CxxStdlib

@main
private enum PDFDictionaryLookupTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let imported = dictionary_importer.import(std.string(root.appendingPathComponent("dictionary.zip").path), std.string(root.path), false)
        precondition(imported.success && imported.term_count == 2, "generated Japanese dictionary must import")
        var query = DictionaryQuery()
        query.add_term_dict(std.string(root.appendingPathComponent("PDF Lookup Fixture").path))
        let lookup = "ja".withCString { hoshiMakeLookup(&query, $0) }

        for vertical in [false, true] {
            let sentence = "今日は日本語を勉強します。"
            let start = (sentence as NSString).range(of: "日本語").location
            let rect = CGRect(x: 100, y: 120, width: vertical ? 20 : 18, height: vertical ? 18 : 20)
            let spans = (0..<3).map { index in
                PDFTextSpan(location: start + index, length: 1,
                            rect: rect.offsetBy(dx: vertical ? 0 : CGFloat(index) * 20,
                                                dy: vertical ? -CGFloat(index) * 20 : 0))
            }
            let block = PDFTextBlock(text: sentence, vertical: vertical, spans: spans)
            for recognized in [false, true] {
                let page = PDFPageText(native: recognized ? [] : [block], recognized: recognized ? [block] : [])
                let hit = page.hit(at: CGPoint(x: rect.midX, y: rect.midY))!
                let candidate = PDFLookupSelectionResolver.candidate(block: hit.block, span: hit.span, scanLength: 16, language: .japanese)!
                let results = Array(lookup.lookup(std.string(candidate.text), 16, 16))
                precondition(!results.isEmpty && String(results[0].term.expression) == "日本語", "clicked text resolves through the actual shared Japanese dictionary backend")
                let matched = String(results[0].matched)
                let range = PDFLookupSelectionResolver.matchRange(candidate: candidate, characterCount: matched.count)!
                precondition(range == NSRange(location: start, length: 3))
                precondition(block.rectangles(for: range) == spans.map(\.rect), "every character in the matched word is highlighted")
                precondition(page.hit(at: CGPoint(x: 300, y: 300)) == nil, "blank area cannot pick the nearest term")
            }
        }
        let wrap = PDFTextGeometry.joinWrappedLines([
            PDFTextBlock(text: "日本", vertical: false, spans: [
                .init(location: 0, length: 1, rect: CGRect(x: 10, y: 100, width: 20, height: 20)),
                .init(location: 1, length: 1, rect: CGRect(x: 30, y: 100, width: 20, height: 20)),
            ]),
            PDFTextBlock(text: "語", vertical: false, spans: [.init(location: 0, length: 1, rect: CGRect(x: 10, y: 74, width: 20, height: 20))]),
        ])[0]
        let candidate = PDFLookupSelectionResolver.candidate(block: wrap, span: wrap.spans[0], scanLength: 16, language: .japanese)!
        let wrappedResults = Array(lookup.lookup(std.string(candidate.text), 16, 16))
        precondition(String(wrappedResults[0].term.expression) == "日本語", "native lookup crosses a soft wrap within a paragraph")
        let range = PDFLookupSelectionResolver.matchRange(candidate: candidate, characterCount: 3)!
        precondition(wrap.rectangles(for: range).count == 3, "wrapped matches keep separate source-line highlights")
        print("PDF native/OCR horizontal/vertical hit → shared Japanese dictionary → source highlight integration passed")
    }
}
