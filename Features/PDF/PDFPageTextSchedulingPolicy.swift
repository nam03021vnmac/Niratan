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
}
