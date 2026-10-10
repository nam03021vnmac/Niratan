// test-sources: Features/PDF/PDFPointerSelectionPolicy.swift Features/PDF/PDFLookupSelectionResolver.swift Features/PDF/PDFPageTextSchedulingPolicy.swift Models/PDF.swift Models/Profile.swift Core/SelectionLookup/TextSelectionResolver.swift
import Foundation
import CoreGraphics

@main
private enum PDFPointerSelectionTests {
    static func main() {
        var policy = PDFPointerSelectionPolicy()
        let point = CGPoint(x: 100, y: 100)
        policy.begin(at: point, clickCount: 1, modified: false)
        precondition(policy.end(at: point, clickCount: 1, modified: false, hasSelection: false))
        policy.begin(at: point, clickCount: 1, modified: false)
        policy.move(to: CGPoint(x: 150, y: 100))
        precondition(!policy.end(at: point, clickCount: 1, modified: false, hasSelection: false), "drag away and back remains selection")
        for count in [2, 3] {
            policy.begin(at: point, clickCount: count, modified: false)
            precondition(!policy.end(at: point, clickCount: count, modified: false, hasSelection: false))
        }
        policy.begin(at: point, clickCount: 1, modified: true)
        precondition(!policy.end(at: point, clickCount: 1, modified: false, hasSelection: false))
        policy.begin(at: point, clickCount: 1, modified: false)
        precondition(!policy.end(at: point, clickCount: 1, modified: false, hasSelection: true))
        precondition(!policy.end(at: point, clickCount: 1, modified: false, hasSelection: false), "mouse-up without down cannot look up")
        precondition(PDFPageTextSchedulingPolicy.plan(currentPage: 5, visiblePages: [4, 5, 6], pageCount: 10) == [5, 4, 6])
        precondition(PDFPageTextSchedulingPolicy.plan(currentPage: 8, visiblePages: [0, 1, 2, 3, 4, 5], pageCount: 10) == [8, 0, 1], "queue is bounded with clicked-page priority")
        precondition(PDFPageTextSchedulingPolicy.readAhead(currentPage: 2, plan: [2], pageCount: 10) == [3, 4, 5], "the next pages are read ahead")
        precondition(PDFPageTextSchedulingPolicy.readAhead(currentPage: 5, plan: [5, 4, 6], pageCount: 10) == [7, 8], "visible pages are not queued twice")
        precondition(PDFPageTextSchedulingPolicy.readAhead(currentPage: 8, plan: [8], pageCount: 10) == [9])
        precondition(PDFPageTextSchedulingPolicy.readAhead(currentPage: 9, plan: [9], pageCount: 10).isEmpty)
        precondition(PDFPageTextSchedulingPolicy.readAhead(currentPage: -1, plan: [], pageCount: 10).isEmpty)
        precondition(PDFPageTextSchedulingPolicy.readAhead(currentPage: 12, plan: [], pageCount: 10).isEmpty)
        precondition(PDFPageTextSchedulingPolicy.wholeDocument(currentPage: 3, pageCount: 5) == [3, 4, 0, 1, 2], "whole-document reads start at the reading position")
        precondition(PDFPageTextSchedulingPolicy.wholeDocument(currentPage: 9, pageCount: 2) == [1, 0])
        precondition(PDFPageTextSchedulingPolicy.wholeDocument(currentPage: 0, pageCount: 0).isEmpty)
        precondition(PDFPageTextSchedulingPolicy.plan(currentPage: -1, visiblePages: [-1, 0, 10], pageCount: 10) == [0])
        precondition(PDFPageTextSchedulingPolicy.plan(currentPage: 0, visiblePages: [0], pageCount: 0).isEmpty)

        let rect = CGRect(x: 10, y: 20, width: 12, height: 18)
        let span = PDFTextSpan(location: 2, length: 2, rect: rect)
        let block = PDFTextBlock(text: "😀𠮷が日本語", vertical: true, spans: [span])
        let candidate = PDFLookupSelectionResolver.candidate(block: block, span: span, scanLength: 1, language: .japanese)!
        precondition(candidate.text == "𠮷" && candidate.utf16Start == 2, "scan limit retains supplementary kanji")
        let range = PDFLookupSelectionResolver.matchRange(candidate: candidate, characterCount: 1)!
        precondition(range == NSRange(location: 2, length: 2), "highlight ranges use UTF-16, not grapheme counts")
        precondition(block.rectangles(for: range) == [rect])
        let combining = PDFTextBlock(text: "か\u{3099}く", vertical: false, spans: [.init(location: 0, length: 2, rect: rect)])
        precondition(PDFLookupSelectionResolver.candidate(block: combining, span: combining.spans[0], scanLength: 1, language: .japanese)?.text == "か\u{3099}")
        precondition(PDFLookupSelectionResolver.candidate(block: block, span: span, scanLength: 0, language: .japanese) == nil)
        print("PDF click/drag arbitration and Unicode lookup-selection tests passed")
    }
}
