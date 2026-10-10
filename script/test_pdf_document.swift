// test-sources: Models/PDF.swift Features/PDF/PDFTextCache.swift Features/PDF/PDFDocumentWorker.swift Features/PDF/PDFLibraryStore.swift
import AppKit
import CoreText
import PDFKit

@main
private enum PDFDocumentTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fixture" {
            try fixture(at: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("Disposable horizontal/vertical text and scan PDF created")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-document-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Japanese.pdf")
        try fixture(at: file)
        let original = try Data(contentsOf: file)
        let worker = PDFDocumentWorker(url: file, cacheDirectory: root.appendingPathComponent("ocr"))
        let metadata = try await worker.prepare()
        precondition(metadata.count == 4)
        let horizontal = try await worker.embeddedText(page: 0)
        precondition(horizontal.map(\.text).joined().contains("日本語"), "horizontal native extraction")
        assertHit(native: horizontal, recognized: [], point: CGPoint(x: 55, y: 492), expected: "日")
        let vertical = try await worker.embeddedText(page: 1)
        if !vertical.map(\.text).joined().contains("日本語") || !vertical.contains(where: \.vertical) {
            FileHandle.standardError.write(Data("Vertical native blocks: \(vertical)\nPage string: \(String(describing: PDFDocument(url: file)?.page(at: 1)?.string))\n".utf8))
        }
        precondition(vertical.map(\.text).joined().contains("日本語"), "vertical native extraction")
        precondition(vertical.contains(where: \.vertical), "vertical geometry")
        assertHit(native: vertical, recognized: [], point: CGPoint(x: 365, y: 562), expected: "日")
        let scan = try await worker.embeddedText(page: 2)
        precondition(scan.isEmpty)
        let recognized = try await worker.recognize(page: 2)
        precondition(recognized.map(\.text).joined().contains("日本語"), "Japanese scanned recognition")
        precondition(recognized.flatMap(\.spans).count >= 3, "range-level OCR geometry")
        assertHit(native: [], recognized: recognized, point: CGPoint(x: 55, y: 492), expected: "日")
        let cacheFile = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("ocr"), includingPropertiesForKeys: nil).first!
        var cacheRecord = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as! [String: Any]
        var cachedBlocks = cacheRecord["blocks"] as! [[String: Any]]
        cachedBlocks[0]["text"] = (cachedBlocks[0]["text"] as! String).replacingOccurrences(of: "日本語", with: "架空語")
        cacheRecord["blocks"] = cachedBlocks
        try JSONSerialization.data(withJSONObject: cacheRecord).write(to: cacheFile)
        let reused = try await worker.recognize(page: 2)
        precondition(reused.map(\.text).joined().contains("架空語"), "ordinary reopen reuses a validated cache")
        let retried = try await worker.recognize(page: 2, useCache: false)
        precondition(retried.map(\.text).joined().contains("日本語"), "manual recognition can replace an inaccurate cached result")
        let verticalScan = try await worker.recognize(page: 3)
        precondition(verticalScan.map(\.text).joined().contains("日本語"), "vertical Japanese OCR")
        precondition(verticalScan.contains(where: \.vertical))
        assertHit(native: [], recognized: verticalScan, point: CGPoint(x: 365, y: 562), expected: "日")
        let cancellationCache = root.appendingPathComponent("cancelled-ocr")
        let cancelledWorker = PDFDocumentWorker(url: file, cacheDirectory: cancellationCache)
        _ = try await cancelledWorker.prepare()
        let task = Task { try await cancelledWorker.recognize(page: 2) }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("cancelled OCR must not succeed") }
        catch is CancellationError { }
        precondition(!FileManager.default.fileExists(atPath: cancellationCache.path), "cancelled OCR must not write a cache")
        let store = PDFLibraryStore(directory: root.appendingPathComponent("library"))
        let item = try await store.importFile(file)
        let duplicate = try await store.importFile(file)
        precondition(item.id == duplicate.id && store.items.count == 1)
        var saved = item; saved.pageIndex = 2; saved.zoomScale = 1.75
        let firstSession = UUID(), secondSession = UUID()
        store.claim(item.id, session: firstSession)
        try store.save(saved, session: firstSession)
        store.claim(item.id, session: secondSession)
        try store.save(item, session: firstSession)
        precondition(store.items[0].pageIndex == 2, "obsolete session save rejected")
        let reopened = PDFLibraryStore(directory: store.directory)
        precondition(reopened.items[0].pageIndex == 2)
        precondition(reopened.items[0].zoomScale == 1.75, "explicit zoom survives catalog round-trip")
        let resolved = try reopened.resolve(reopened.items[0])
        precondition(resolved.standardizedFileURL == file.standardizedFileURL)
        let sibling = root.appendingPathComponent("sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let sameName = sibling.appendingPathComponent(file.lastPathComponent)
        try original.write(to: sameName)
        let other = try await store.importFile(sameName)
        precondition(other.id != item.id && store.items.count == 2, "same basename is not an identity")
        try await store.relink(item, to: sameName)
        try store.save(saved, session: secondSession)
        let relinked = store.items.first(where: { $0.id == item.id })!
        precondition(relinked.sourcePath == sameName.standardizedFileURL.path, "obsolete reader cannot undo a relink")
        precondition(!store.owns(item.id, session: secondSession), "relink invalidates the old reader's write ownership")
        try await testEncryptedDocuments(source: file, root: root)
        try await testNativeUnicode(root: root)
        try store.remove(item.id)
        let afterReading = try Data(contentsOf: file)
        precondition(afterReading == original, "source bytes preserved")
        let catalog = store.directory.appendingPathComponent("pdf_library.json")
        let invalid = Data("{\"version\":999,\"items\":[]}".utf8)
        try invalid.write(to: catalog)
        let newer = PDFLibraryStore(directory: store.directory)
        precondition(newer.loadError != nil)
        do { _ = try await newer.importFile(file); preconditionFailure("must not overwrite unsupported catalog") }
        catch { }
        let afterFailure = try Data(contentsOf: catalog)
        precondition(afterFailure == invalid)
        print("PDF native horizontal/vertical, scanned horizontal/vertical OCR, library persistence and source preservation passed")
    }

    static func assertHit(native: [PDFTextBlock], recognized: [PDFTextBlock], point: CGPoint, expected: String) {
        let hit = PDFPageText(native: native, recognized: recognized).hit(at: point)
        precondition(hit != nil, "known rendered glyph must have a hit region")
        let character = (hit!.block.text as NSString).substring(with: NSRange(location: hit!.span.location, length: hit!.span.length))
        precondition(character == expected, "geometry points to the intended Japanese character, not merely some recognized text")
    }

    static func testEncryptedDocuments(source: URL, root: URL) async throws {
        let pdf = PDFDocument(url: source)!
        let encrypted = root.appendingPathComponent("locked.pdf")
        precondition(pdf.write(to: encrypted, withOptions: [.ownerPasswordOption: "fixture-owner", .userPasswordOption: "fixture-reader"]))
        let bytes = try Data(contentsOf: encrypted)
        let worker = PDFDocumentWorker(url: encrypted, cacheDirectory: root.appendingPathComponent("locked-cache"))
        do { _ = try await worker.prepare(); preconditionFailure("password required") } catch PDFSupportError.locked { }
        do { _ = try await worker.prepare(password: "wrong"); preconditionFailure("wrong password rejected") } catch PDFSupportError.locked { }
        _ = try await worker.prepare(password: "fixture-reader")
        let text = try await worker.embeddedText(page: 0)
        precondition(text.map(\.text).joined().contains("日本語"))
        let encryptedOCR = try await worker.recognize(page: 2)
        precondition(encryptedOCR.map(\.text).joined().contains("日本語"))
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("locked-cache").path), "encrypted PDF OCR stays memory-only")
        let after = try Data(contentsOf: encrypted)
        precondition(after == bytes, "unlock never rewrites the encrypted source")

        let restricted = root.appendingPathComponent("restricted.pdf")
        precondition(pdf.write(to: restricted, withOptions: [.ownerPasswordOption: "fixture-owner", .userPasswordOption: "fixture-reader", .accessPermissionsOption: NSNumber(value: 0)]))
        let restrictedCache = root.appendingPathComponent("restricted-cache")
        let denied = PDFDocumentWorker(url: restricted, cacheDirectory: restrictedCache)
        _ = try await denied.prepare(password: "fixture-reader")
        do { _ = try await denied.embeddedText(page: 0); preconditionFailure("extraction permissions enforced") } catch PDFSupportError.permission { }
        do { _ = try await denied.recognize(page: 2); preconditionFailure("OCR must not bypass extraction restrictions") } catch PDFSupportError.permission { }
        precondition(!FileManager.default.fileExists(atPath: restrictedCache.path))
    }

    static func testNativeUnicode(root: URL) async throws {
        let file = root.appendingPathComponent("unicode.pdf")
        var box = CGRect(x: 0, y: 0, width: 480, height: 640)
        let pdf = CGContext(file as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.textMatrix = .identity
        pdf.textPosition = CGPoint(x: 40, y: 480)
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 32, nil)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "𠮷か\u{3099}日本語", attributes: [.font: font])), pdf)
        pdf.endPDFPage(); pdf.closePDF()
        let worker = PDFDocumentWorker(url: file, cacheDirectory: root.appendingPathComponent("unicode-cache"))
        _ = try await worker.prepare()
        let text = try await worker.embeddedText(page: 0)
        precondition(text.map(\.text).joined().contains("𠮷"), "selectable supplementary kanji keeps its native text layer")
        assertHit(native: text, recognized: [], point: CGPoint(x: 55, y: 492), expected: "𠮷")
    }

    static func fixture(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 480, height: 640)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { fatalError("PDF context") }
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 32, nil)
        func text(_ context: CGContext, vertical: Bool) {
            let phrase = "日本語を勉強します。"
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            if vertical {
                for (index, char) in phrase.enumerated() {
                    context.textMatrix = .identity
                    context.textPosition = CGPoint(x: 350, y: 550 - CGFloat(index) * 38)
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(char), attributes: [.font: font]))
                    CTLineDraw(line, context)
                }
            } else {
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 40, y: 480)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: phrase, attributes: [.font: font])), context)
            }
        }
        for vertical in [false, true] { pdf.beginPDFPage(nil); text(pdf, vertical: vertical); pdf.endPDFPage() }
        for vertical in [false, true] {
            let image = CGContext(data: nil, width: 960, height: 1280, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            image.setFillColor(CGColor(gray: 1, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 960, height: 1280))
            image.scaleBy(x: 2, y: 2); text(image, vertical: vertical)
            pdf.beginPDFPage(nil); pdf.draw(image.makeImage()!, in: box); pdf.endPDFPage()
        }
        pdf.closePDF()
    }
}
