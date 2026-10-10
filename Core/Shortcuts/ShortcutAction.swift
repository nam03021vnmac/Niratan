import Foundation

enum ShortcutScope: String, Codable, CaseIterable, Hashable {
    case global
    case reader
    case dictionary
    case popup
    case sasayaki
    case video
    case manga
    case pdf
}

enum ShortcutCategory: String, Codable, CaseIterable, Hashable, Identifiable {
    case global
    case reader
    case dictionaryPopup
    case sasayaki
    case video
    case manga
    case pdf

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .global: "Global"
        case .reader: "Reader"
        case .dictionaryPopup: "Dictionary / Popup"
        case .sasayaki: "Sasayaki"
        case .video: "Video"
        case .manga: "Manga"
        case .pdf: "PDF"
        }
    }
}

struct ShortcutAction: Identifiable, Hashable {
    let id: String
    let titleKey: String
    let category: ShortcutCategory
    let scopes: Set<ShortcutScope>
    let defaultBinding: KeyboardShortcutBinding
}
