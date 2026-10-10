import AppKit
import SwiftUI

@MainActor
final class PDFWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = PDFWindowPresenter()
    private var window: NSWindow?
    private var model: PDFReaderViewModel?
    private var shortcuts: ShortcutManager?
    func closeWindow() { window?.performClose(nil) }

    func open(_ item: PDFLibraryItem, userConfig: UserConfig) {
        if let window, model?.item.id == item.id, model?.item.sourcePath == item.sourcePath,
           model?.item.resourceIdentity == item.resourceIdentity, let sessionID = model?.sessionID,
           PDFLibraryStore.shared.owns(item.id, session: sessionID) {
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(); return
        }
        if let previous = self.window {
            // Do not replace a live hosting tree while its old reader closes;
            // AppKit/SwiftUI can collapse or hide that window during teardown.
            previous.performClose(nil)
            previous.delegate = nil
            self.window = nil
        }
        model?.close()
        let model = PDFReaderViewModel(item: item)
        self.model = model
        let manager = shortcuts ?? ShortcutManager(registry: .application)
        shortcuts = manager
        manager.configure(userConfig: userConfig); manager.install()
        let root = PDFReaderView(model: model).environment(userConfig).environment(manager)
        let window: NSWindow
        if let current = self.window { window = current }
        else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("pdf-reader")
            window.minSize = NSSize(width: 640, height: 480)
            window.isReleasedWhenClosed = false; window.isRestorable = false
            window.collectionBehavior.insert(.fullScreenPrimary)
            if !window.setFrameUsingName("Niratan.PDFReaderWindow") { window.center() }
            window.delegate = self
            self.window = window
        }
        let frame = window.frame
        window.contentViewController = NSHostingController(rootView: root)
        window.setFrame(frame, display: false)
        window.title = item.title
        manager.manageEvents(for: window)
        window.makeKeyAndOrderFront(nil); NSApp.activate()
    }

    func saveForTermination() { model?.flushAndSave() }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        if !closing.styleMask.contains(.fullScreen) { closing.saveFrame(usingName: "Niratan.PDFReaderWindow") }
        model?.close(); shortcuts?.uninstall(); model = nil; shortcuts = nil
        DispatchQueue.main.async { [weak self, weak closing] in
            guard self?.window === closing else { return }
            closing?.delegate = nil; self?.window = nil
        }
    }
}
