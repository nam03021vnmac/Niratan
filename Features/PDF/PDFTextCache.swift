import Foundation
import CryptoKit

nonisolated struct PDFTextCache {
    private struct Record: Codable { var identity: String; var blocks: [PDFTextBlock] }
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NiratanPDFText", isDirectory: true)
    }
    private func url(_ identity: String) -> URL {
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func load(identity: String) -> [PDFTextBlock]? {
        let file = url(identity)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_000_000,
              let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data),
              record.identity == identity, record.blocks.count <= 10_000, record.blocks.allSatisfy(\.isValid) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return record.blocks
    }
    func save(_ blocks: [PDFTextBlock], identity: String) throws {
        try Task.checkCancellation()
        guard blocks.count <= 10_000, blocks.allSatisfy(\.isValid) else { return }
        let data = try JSONEncoder().encode(Record(identity: identity, blocks: blocks))
        guard data.count <= 16_000_000 else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: url(identity), options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter { $0.pathExtension == "json" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries where total > 256_000_000 {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}
