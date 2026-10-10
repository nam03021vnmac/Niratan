import AppKit

/// Observes PDFKit's native event sequence without delaying or consuming it.
/// A stationary single click ends the gesture at mouse-up; a following click
/// of a double/triple selection dismisses that popup on its mouse-down.
@MainActor
final class PDFLookupClickRecognizer: NSGestureRecognizer {
    var onPointerDown: (() -> Void)?
    var hasNativeSelection: (() -> Bool)?
    private var policy = PDFPointerSelectionPolicy()
    private(set) var clickLocationInWindow: CGPoint = .zero

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        policy.begin(at: event.locationInWindow, clickCount: event.clickCount, modified: modified(event))
    }

    override func mouseDragged(with event: NSEvent) { policy.move(to: event.locationInWindow) }
    override func rightMouseDown(with event: NSEvent) { onPointerDown?(); state = .failed }
    override func otherMouseDown(with event: NSEvent) { onPointerDown?(); state = .failed }

    override func mouseUp(with event: NSEvent) {
        clickLocationInWindow = event.locationInWindow
        state = policy.end(at: event.locationInWindow, clickCount: event.clickCount,
                           modified: modified(event), hasSelection: hasNativeSelection?() ?? false) ? .ended : .failed
    }

    override func reset() {
        super.reset()
        policy = PDFPointerSelectionPolicy()
    }

    private func modified(_ event: NSEvent) -> Bool {
        !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }
}
