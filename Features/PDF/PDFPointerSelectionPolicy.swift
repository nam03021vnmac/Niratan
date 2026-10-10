import Foundation
import CoreGraphics

/// A stationary primary click is a lookup; a drag, multi-click or modified
/// selection remains PDFKit input. Track the entire gesture, not only its end,
/// so dragging away and back cannot accidentally open the dictionary.
nonisolated struct PDFPointerSelectionPolicy {
    private var origin: CGPoint?
    private var moved = false
    private var eligible = false
    static let dragThreshold: CGFloat = 4

    mutating func begin(at point: CGPoint, clickCount: Int, modified: Bool) {
        origin = point
        moved = false
        eligible = clickCount == 1 && !modified
    }

    mutating func move(to point: CGPoint) {
        guard let origin else { return }
        if hypot(point.x - origin.x, point.y - origin.y) > Self.dragThreshold { moved = true }
    }

    mutating func end(at point: CGPoint, clickCount: Int, modified: Bool, hasSelection: Bool) -> Bool {
        move(to: point)
        defer { origin = nil; eligible = false }
        return origin != nil && eligible && !moved && clickCount == 1 && !modified && !hasSelection
    }
}
