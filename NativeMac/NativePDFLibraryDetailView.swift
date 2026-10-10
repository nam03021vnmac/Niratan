import SwiftUI

struct NativePDFLibraryDetailView: View {
    @Environment(UserConfig.self) private var userConfig
    @State private var store = PDFLibraryStore.shared
    var body: some View {
        PDFLibraryView(store: store) { item in PDFWindowPresenter.shared.open(item, userConfig: userConfig) }
    }
}
