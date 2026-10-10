import Foundation
import Observation

@Observable @MainActor
final class PDFLibraryStore {
    static let shared = PDFLibraryStore()
    private(set) var catalog = PDFLibraryCatalog()
    private(set) var loadError: String?
    let directory: URL
    private var owners: [UUID: UUID] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let file = self.directory.appendingPathComponent("pdf_library.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 32_000_000 else { throw PDFSupportError.catalog }
                let data = try Data(contentsOf: file)
                guard data.count <= 32_000_000 else { throw PDFSupportError.catalog }
                let saved = try JSONDecoder().decode(PDFLibraryCatalog.self, from: data)
                guard saved.version == 1, Set(saved.items.map(\.id)).count == saved.items.count,
                      saved.items.allSatisfy({ item in
                          item.pageCount >= 0 && item.pageIndex >= 0 && item.position.x.isFinite && item.position.y.isFinite
                              && (item.zoomScale.map { $0.isFinite && $0 > 0 } ?? true)
                      }) else { throw PDFSupportError.catalog }
                catalog = saved
            } catch { loadError = PDFSupportError.catalog.localizedDescription }
        }
    }

    var items: [PDFLibraryItem] { catalog.items.sorted { $0.lastOpened > $1.lastOpened } }
    func coverURL(_ id: UUID) -> URL { directory.appendingPathComponent("PDFCovers/\(id.uuidString).tiff") }

    func importFile(_ url: URL) async throws -> PDFLibraryItem {
        guard url.isFileURL else { throw PDFSupportError.unreadable }
        guard loadError == nil else { throw PDFSupportError.catalog }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let identity = try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier.map { String(describing: $0) }
        if let existing = catalog.items.first(where: {
            $0.sourcePath == url.standardizedFileURL.path || (identity != nil && $0.resourceIdentity == identity)
        }) { return existing }
        let worker = PDFDocumentWorker(url: url)
        // Locked PDFs remain indexed so the reader can request a session password.
        let metadata: (title: String?, count: Int)
        do { metadata = try await worker.prepare() }
        catch PDFSupportError.locked { metadata = (nil, 0) }
        // Another importer may have completed while PDFKit was preparing.
        if let existing = catalog.items.first(where: {
            $0.sourcePath == url.standardizedFileURL.path || (identity != nil && $0.resourceIdentity == identity)
        }) { return existing }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let item = PDFLibraryItem(id: UUID(), title: metadata.title.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent,
                                  bookmark: bookmark, sourcePath: url.standardizedFileURL.path,
                                  resourceIdentity: identity, pageCount: metadata.count)
        var next = catalog
        next.items.append(item)
        try persist(next)
        if let image = try? await worker.cover() {
            let file = coverURL(item.id)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? image.write(to: file, options: .atomic)
        }
        return item
    }

    func resolve(_ item: PDFLibraryItem) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: item.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            try update(item.id) { $0.bookmark = bookmark; $0.sourcePath = url.standardizedFileURL.path }
        }
        return url
    }

    func relink(_ item: PDFLibraryItem, to url: URL) async throws {
        let worker = PDFDocumentWorker(url: url)
        let metadata: (title: String?, count: Int)
        do { metadata = try await worker.prepare() }
        catch PDFSupportError.locked { metadata = (nil, item.pageCount) }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        try update(item.id) {
            $0.bookmark = bookmark; $0.sourcePath = url.standardizedFileURL.path; $0.pageCount = metadata.count
            $0.resourceIdentity = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier.map { String(describing: $0) }
            $0.pageIndex = min($0.pageIndex, max(0, metadata.count - 1))
        }
        // The old reader still owns a different source lease/document. Its
        // delayed progress/metadata writes must not overwrite the relink.
        owners[item.id] = nil
    }

    func claim(_ id: UUID, session: UUID) { owners[id] = session }
    func owns(_ id: UUID, session: UUID) -> Bool { owners[id] == session }
    func save(_ item: PDFLibraryItem, session: UUID) throws {
        guard owners[item.id] == session else { return }
        try update(item.id) {
            // Reader saves cannot undo a concurrent source relink.
            $0.pageCount = item.pageCount; $0.pageIndex = item.pageIndex; $0.position = item.position
            $0.continuous = item.continuous; $0.fitWidth = item.fitWidth; $0.automaticOCR = item.automaticOCR
            $0.zoomScale = item.zoomScale
            $0.lastOpened = item.lastOpened
        }
    }
    func remove(_ id: UUID) throws {
        var next = catalog
        next.items.removeAll { $0.id == id }
        try persist(next)
        owners[id] = nil
    }
    private func update(_ id: UUID, change: (inout PDFLibraryItem) -> Void) throws {
        var next = catalog
        guard let index = next.items.firstIndex(where: { $0.id == id }) else { return }
        change(&next.items[index])
        try persist(next)
    }
    private func persist(_ next: PDFLibraryCatalog) throws {
        guard loadError == nil else { throw PDFSupportError.catalog }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("pdf_library.json"), options: .atomic)
        catalog = next
    }
}
