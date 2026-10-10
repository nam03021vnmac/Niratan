import AppKit
import CryptoKit
import PDFKit
import Vision

/// Each worker owns a separate PDFDocument, never the one attached to PDFView.
/// PDFKit operations are synchronous actor-isolated sections; Vision receives
/// only an immutable raster and may suspend without sharing the PDFDocument.
actor PDFDocumentWorker {
    private let url: URL
    private let scoped: Bool
    private var document: PDFDocument?
    private var revision: String?
    private var stamp: String?
    private let cacheDirectory: URL?

    init(url: URL, cacheDirectory: URL? = nil) {
        self.url = url
        self.cacheDirectory = cacheDirectory
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

    func prepare(password: String? = nil) throws -> (title: String?, count: Int) {
        try Task.checkCancellation()
        guard let pdf = PDFDocument(url: url) else { throw PDFSupportError.unreadable }
        if pdf.isLocked {
            guard let password, pdf.unlock(withPassword: password) else { throw PDFSupportError.locked }
        }
        guard pdf.pageCount > 0 else { throw PDFSupportError.unreadable }
        document = pdf
        revision = nil
        stamp = try sourceStamp()
        return (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, pdf.pageCount)
    }

    func embeddedText(page index: Int) throws -> [PDFTextBlock] {
        try validateSource()
        guard let document, document.allowsCopying else { throw PDFSupportError.permission }
        guard let page = document.page(at: index), let text = page.string else { return [] }
        let value = text as NSString
        guard value.length <= 200_000, page.numberOfCharacters == value.length else { return [] }
        let crop = page.bounds(for: .cropBox)
        guard let selection = page.selection(for: NSRange(location: 0, length: value.length)) else { return [] }
        var blocks: [PDFTextBlock] = []
        for line in selection.selectionsByLine() {
            try Task.checkCancellation()
            var block = PDFTextBlock(text: "", vertical: false, spans: [])
            for part in 0..<line.numberOfTextRanges(on: page) {
                let range = line.range(at: part, on: page)
                guard range.location != NSNotFound, NSMaxRange(range) <= value.length else { continue }
                var cursor = range.location
                while cursor < NSMaxRange(range) {
                    let glyph = value.rangeOfComposedCharacterSequence(at: cursor)
                    let string = value.substring(with: glyph)
                    // PDFKit inserts line breaks between vertical glyphs; keep
                    // source indices for geometry, not those synthetic breaks
                    // in the lookup text.
                    if string == "\n" || string == "\r" {
                        cursor = NSMaxRange(glyph)
                        continue
                    }
                    let offset = block.text.utf16.count
                    block.text += string
                    // Selection ranges include synthetic line feeds; characterBounds
                    // indices do not consistently do so on vertical PDFs. Derive
                    // text and geometry from the same range-selection boundary.
                    let glyphSelection = page.selection(for: glyph)
                    let rect = (glyphSelection?.bounds(for: page) ?? .null).intersection(crop)
                    // Check PDFKit's index-to-string mapping before trusting a hit.
                    if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !string.unicodeScalars.contains(where: { $0.value == 0xfffd || (0xe000...0xf8ff).contains($0.value) }),
                       glyphSelection?.string == string, PDFTextGeometry.valid(rect) {
                        block.spans.append(.init(location: offset, length: glyph.length, rect: rect))
                    }
                    cursor = NSMaxRange(glyph)
                }
            }
            guard !block.spans.isEmpty else { continue }
            if let first = block.spans.first, let last = block.spans.last, block.spans.count > 1 {
                block.vertical = Swift.abs(first.rect.midY - last.rect.midY) > Swift.abs(first.rect.midX - last.rect.midX)
            }
            blocks.append(block)
        }
        return PDFTextGeometry.joinWrappedLines(PDFTextGeometry.joinVerticalFragments(blocks))
    }

    func recognize(page index: Int, useCache: Bool = true) async throws -> [PDFTextBlock] {
        try Task.checkCancellation()
        try validateSource()
        guard let document, document.allowsCopying else { throw PDFSupportError.permission }
        guard let page = document.page(at: index) else { throw PDFSupportError.unreadable }
        let digest = try contentRevision()
        let crop = page.bounds(for: .cropBox)
        let identity = "\(digest)|\(index)|\(crop)|\(page.rotation)|ja-JP|vision-documents-ranges-v1|240dpi-4096-12mp|\(ProcessInfo.processInfo.operatingSystemVersionString)"
        let cache = PDFTextCache(directory: cacheDirectory)
        if useCache, !document.isEncrypted, let result = cache.load(identity: identity) { return result }
        let raster = try rasterize(page: page)
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "ja-JP")]
        request.textRecognitionOptions.automaticallyDetectLanguage = false
        request.textRecognitionOptions.useLanguageCorrection = true
        let observations = try await request.perform(on: raster.image, orientation: .up)
        try Task.checkCancellation()
        try validateSource()
        var blocks: [PDFTextBlock] = []
        for observation in observations {
            for paragraph in observation.document.paragraphs {
                var block = PDFTextBlock(text: "", vertical: false, spans: [])
                for line in paragraph.lines {
                    guard let candidate = line.topCandidates(1).first else { continue }
                    let string = candidate.string
                    let vertical = line.textDirection == .topToBottom
                    block.vertical = block.vertical || vertical
                    for position in string.indices {
                        let end = string.index(after: position)
                        let character = String(string[position..<end])
                        let location = block.text.utf16.count
                        block.text += character
                        guard !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        guard let region = candidate.boundingBox(for: position..<end) else { continue }
                        let rect = PDFTextGeometry.pageRect(normalized: region.boundingBox.cgRect,
                                                           pixels: raster.size, transform: raster.transform).intersection(crop)
                        if PDFTextGeometry.valid(rect) {
                            block.spans.append(.init(location: location, length: character.utf16.count, rect: rect))
                        }
                    }
                }
                if !block.spans.isEmpty { blocks.append(block) }
            }
        }
        try Task.checkCancellation()
        // Do not turn password-protected documents into plaintext disk caches.
        if !document.isEncrypted { try cache.save(blocks, identity: identity) }
        return blocks
    }

    func cover() throws -> Data? {
        guard let document, !document.isEncrypted, let page = document.page(at: 0) else { return nil }
        return page.thumbnail(of: CGSize(width: 360, height: 510), for: .cropBox).tiffRepresentation
    }

    private func sourceStamp() throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        return "\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: values.fileResourceIdentifier))"
    }

    private func validateSource() throws {
        try Task.checkCancellation()
        guard stamp == (try sourceStamp()) else { throw PDFSupportError.changed }
    }

    private func contentRevision() throws -> String {
        if let revision { return revision }
        try validateSource()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        try validateSource()
        let result = hash.finalize().map { String(format: "%02x", $0) }.joined()
        revision = result
        return result
    }

    private func rasterize(page: PDFPage) throws -> (image: CGImage, size: CGSize, transform: CGAffineTransform) {
        let crop = page.bounds(for: .cropBox)
        guard PDFTextGeometry.valid(crop), crop.width < 1_000_000, crop.height < 1_000_000,
              let ref = page.pageRef else { throw PDFSupportError.geometry }
        let rotated = abs(page.rotation % 180) == 90
        let width = rotated ? crop.height : crop.width
        let height = rotated ? crop.width : crop.height
        let scale = min(240.0 / 72, 4096 / max(width, height), sqrt(12_000_000 / (width * height)))
        let pixels = CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
        guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFSupportError.geometry }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixels))
        let transform = ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pixels), rotate: 0, preserveAspectRatio: true)
        context.concatenate(transform)
        context.drawPDFPage(ref)
        guard let image = context.makeImage() else { throw PDFSupportError.geometry }
        return (image, pixels, transform)
    }
}
