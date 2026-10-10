import Foundation

nonisolated enum PDFPageTextSchedulingPolicy {
    /// A viewport can include many tiny pages. Bound recognition to the
    /// current/clicked page and two visible neighbors; never OCR a whole book
    /// merely because PDFKit reports it in a very zoomed-out viewport.
    static func plan(currentPage: Int, visiblePages: [Int], pageCount: Int) -> [Int] {
        var result: [Int] = []
        for page in [currentPage] + visiblePages where page >= 0 && page < pageCount && !result.contains(page) {
            result.append(page)
            if result.count == 3 { break }
        }
        return result
    }

    /// Pages after the current one, read quietly once the visible pages are
    /// done so page turns usually find their text ready. Recognition is
    /// serial, so a short window keeps a jump elsewhere responsive.
    static func readAhead(currentPage: Int, plan: [Int], pageCount: Int, count: Int = 3) -> [Int] {
        guard currentPage >= 0, currentPage + 1 < pageCount else { return [] }
        return (currentPage + 1..<min(pageCount, currentPage + 1 + count)).filter { !plan.contains($0) }
    }

    /// Every page for an explicit whole-document read: from the reading
    /// position to the end, then the pages before it.
    static func wholeDocument(currentPage: Int, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        let start = max(0, min(currentPage, pageCount - 1))
        return Array(start..<pageCount) + Array(0..<start)
    }
}
