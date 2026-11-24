import AppKit

/// A borderless, non-activating `NSPanel` that can NEVER become key or main.
///
/// On macOS 27+, `NSPopover` anchored to an `NSStatusBarButton` steals system keyboard focus
/// (`AXFocusedApplication`) away from the user's active window. Using this panel subclass
/// with `orderFrontRegardless()` displays floating alerts without ever disturbing keyboard
/// focus or active window state.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, hasShadow: Bool = true) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = hasShadow
        self.level = .popUpMenu
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        self.isMovableByWindowBackground = false
        self.ignoresMouseEvents = false
    }
}

/// Container view that accepts first mouse so clicks work immediately on a non-activating panel.
final class FirstMouseClickableView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
