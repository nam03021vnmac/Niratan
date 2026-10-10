import CoreGraphics
import Foundation
import os

/// PP-OCR for dense document pages: DB line detection over the whole page
/// (no speech-bubble stage), then CTC recognition per line with token
/// positions. Vertical columns are rotated upright first.
actor PDFPaddleOCREngine: PDFLineRecognizing {
    private static let revision = "pdf-ppocr-lines-v1"
    /// Longer detector side in pixels; text on a 240 dpi page stays well above
    /// the detector's minimum glyph size at this scale.
    private static let detectorMaxSide = 2048
    private static let loaded = OSAllocatedUnfairLock<PDFPaddleOCREngine?>(initialState: nil)

    nonisolated let identity: String
    private let detector: MangaPPLineDetector
    private let recognizer: MangaPPLineRecognizer

    private init(store: MangaOCRModelStore) throws {
        let url = { store.url(for: $0) }
        detector = try MangaPPLineDetector(modelURL: url(MangaOCRModelSet.lineDetectorFile))
        recognizer = try MangaPPLineRecognizer(
            modelURL: url(MangaOCRModelSet.lineRecognizerFile),
            dictionaryURL: url(MangaOCRModelSet.lineDictionaryFile)
        )
        identity = "\(Self.revision)-\(store.fingerprint(for: .pdfOCR))|\(Self.detectorMaxSide)"
    }

    /// The loaded engine, or nil while the model set is not downloaded.
    static func current(store: MangaOCRModelStore = .shared) async throws -> PDFPaddleOCREngine? {
        guard await store.isReady(.pdfOCR) else { return nil }
        return try loaded.withLock { engine in
            if let engine { return engine }
            let created = try PDFPaddleOCREngine(store: store)
            engine = created
            return created
        }
    }

    /// Release the ONNX sessions, e.g. after the models are deleted.
    static func unload() { loaded.withLock { $0 = nil } }

    func recognize(image: CGImage) throws -> [PDFOCRRecognizedLine] {
        try Task.checkCancellation()
        guard let page = MangaOCRBitmap(image: image) else { throw PDFSupportError.geometry }
        let detected = try detector.detect(page, maxSide: Self.detectorMaxSide).map(\.rect)
        let lines = PDFPageOCRLayout.removeRuby(PDFPageOCRLayout.orient(detected))
        var result: [PDFOCRRecognizedLine] = []
        for line in lines {
            try Task.checkCancellation()
            let box = line.rect.ocrClamped(width: CGFloat(page.width), height: CGFloat(page.height))
            guard box.width >= 1, box.height >= 1, let crop = page.blockCrop(box) else { continue }
            let tokens = try recognizer.recognizeLineTokens(line.vertical ? crop.bitmap.rotatedCounterClockwise() : crop.bitmap)
            if !tokens.isEmpty {
                // The crop is the clamped box; keep geometry consistent with it.
                result.append(.init(line: .init(rect: box, vertical: line.vertical), tokens: tokens))
            }
        }
        return result
    }
}
