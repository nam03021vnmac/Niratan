import Foundation

/// Adapt a geometry hit to the shared lookup boundary without cutting a
/// surrogate pair or combining Japanese character at the scan limit.
nonisolated enum PDFLookupSelectionResolver {
    static func candidate(block: PDFTextBlock, span: PDFTextSpan, scanLength: Int,
                          language: ContentLanguageProfile) -> TextLookupCandidate? {
        guard scanLength > 0, block.isValid,
              let candidate = TextSelectionResolver.lookupCandidate(in: block.text, utf16Offset: span.location,
                                                                    scanLength: block.text.utf16.count, contentLanguage: language) else { return nil }
        var end = candidate.text.startIndex
        var units = 0
        while end < candidate.text.endIndex, units < scanLength {
            let next = candidate.text.index(after: end)
            units += candidate.text[end..<next].utf16.count
            end = next
        }
        let text = String(candidate.text[..<end])
        guard !text.isEmpty else { return nil }
        return TextLookupCandidate(text: text, utf16Start: candidate.utf16Start)
    }

    static func matchRange(candidate: TextLookupCandidate, characterCount: Int) -> NSRange? {
        guard characterCount > 0 else { return nil }
        return TextSelectionResolver.highlightRange(for: candidate, matchedText: String(candidate.text.prefix(characterCount)))
    }
}
