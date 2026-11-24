import AppKit
import ApplicationServices

/// Detects whether the current frontmost window is genuinely in macOS full-screen mode
/// (without falsely matching maximized desktop windows on auto-hiding menu bar displays).
@MainActor
enum FullScreenDetector {
    static func isActiveWindowFullScreen() -> Bool {
        guard AXIsProcessTrusted(),
              let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var focusedWindowObj: AnyObject?
        let focusErr = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowObj
        )

        guard focusErr == .success, let windowObj = focusedWindowObj else {
            return false
        }

        // swiftlint:disable:next force_cast
        let windowElement = windowObj as! AXUIElement

        // Primary check: macOS exposes `AXFullScreen` directly on native full-screen windows.
        var fullScreenObj: AnyObject?
        let fsErr = AXUIElementCopyAttributeValue(
            windowElement,
            "AXFullScreen" as CFString,
            &fullScreenObj
        )
        if fsErr == .success, let isFullScreen = fullScreenObj as? Bool {
            return isFullScreen
        }

        // Secondary fallback: check if the window covers the full screen frame (including menu bar area).
        guard let screen = screenContainingMouse() ?? NSScreen.main else {
            return false
        }

        var sizeObj: AnyObject?
        var posObj: AnyObject?
        let sizeErr = AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeObj)
        let posErr = AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &posObj)

        if sizeErr == .success, posErr == .success,
           let sizeVal = sizeObj, let posVal = posObj,
           CFGetTypeID(sizeVal) == AXValueGetTypeID(),
           CFGetTypeID(posVal) == AXValueGetTypeID() {
            var size = CGSize.zero
            var position = CGPoint.zero
            // swiftlint:disable:next force_cast
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
            // swiftlint:disable:next force_cast
            AXValueGetValue(posVal as! AXValue, .cgPoint, &position)

            let matchesFullWidth = abs(size.width - screen.frame.width) <= 2.0
            let matchesFullHeight = abs(size.height - screen.frame.height) <= 2.0
            if matchesFullWidth && matchesFullHeight {
                return true
            }
        }

        return false
    }

    static func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
