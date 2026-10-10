import SwiftUI

enum PDFShortcutActions {
    static let previous = action("previous", "Previous Page", "leftArrow", 123)
    static let next = action("next", "Next Page", "rightArrow", 124)
    static let zoomIn = action("zoomIn", "Zoom In", "=", nil, .command)
    static let zoomOut = action("zoomOut", "Zoom Out", "-", nil, .command)
    static let back = action("back", "Back", "escape", 53)
    static let all = [previous, next, zoomIn, zoomOut, back]
    private static func action(_ id: String, _ title: String, _ key: String, _ code: UInt16?, _ modifiers: EventModifiers = []) -> ShortcutAction {
        ShortcutAction(id: "pdf." + id, titleKey: title, category: .pdf, scopes: [.pdf],
                       defaultBinding: KeyboardShortcutBinding(key: key, modifiers: modifiers.rawValue, keyCode: code))
    }
}
