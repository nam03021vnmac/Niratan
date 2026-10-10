import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFLibraryView: View {
    @Bindable var store: PDFLibraryStore
    let onOpen: (PDFLibraryItem) -> Void
    @State private var error: String?
    @State private var importing = false

    var body: some View {
        Group {
            if let loadError = store.loadError {
                ContentUnavailableView("Unable to Open PDF Library", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if store.items.isEmpty {
                ContentUnavailableView {
                    Label("No PDFs", systemImage: "doc.richtext")
                } description: { Text("Import a PDF to read and look up Japanese words.") } actions: {
                    Button("Import PDF", systemImage: "plus", action: pickFiles).buttonStyle(.glassProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 24)], spacing: 24) {
                        ForEach(store.items) { item in
                            Button { onOpen(item) } label: {
                                ShelfBookCard(title: item.title, progress: item.progress) {
                                    CoverImage(url: store.coverURL(item.id), maxPixelSize: 512) { image in
                                        image.resizable().scaledToFit()
                                    } placeholder: {
                                        Image(systemName: "doc.richtext").font(.system(size: 60)).frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Locate File") { locate(item) }
                                    Button("Remove from Library", role: .destructive) {
                                        do { try store.remove(item.id) } catch { self.error = error.localizedDescription }
                                    }
                                }
                        }
                    }.padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem { Button("Import PDF", systemImage: "plus", action: pickFiles).disabled(importing || store.loadError != nil) }
        }
        .overlay { if importing { ProgressView("Importing PDF…").padding(20).glassEffect(.regular, in: .rect(cornerRadius: 16)) } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
            guard !files.isEmpty else { return false }
            importFiles(files); return true
        }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }
    private func importFiles(_ urls: [URL]) {
        importing = true
        Task {
            var errors: [String] = []
            for url in urls {
                do { _ = try await store.importFile(url) } catch { errors.append(error.localizedDescription) }
            }
            importing = false
            if !errors.isEmpty { error = errors.joined(separator: "\n") }
        }
    }
    private func locate(_ item: PDFLibraryItem) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await store.relink(item, to: url)
                    if let updated = store.items.first(where: { $0.id == item.id }) { onOpen(updated) }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
