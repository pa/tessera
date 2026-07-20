import ApplicationServices
import CoreGraphics

/// A thin, typed wrapper around a window-level `AXUIElement`.
///
/// The AX position/size attributes carry `CGPoint`/`CGSize` boxed inside an
/// `AXValue`, so callers never have to touch the C marshalling. Coordinates are
/// in the global display space used by AX and Core Graphics: origin at the
/// top-left of the main display, y growing downward. `CGDisplayBounds` returns
/// rects in that same space, so no AppKit bottom-left flip is required — see
/// `ScreenLayout`.
struct AXWindow {
    let element: AXUIElement

    /// The window's current frame, or nil if either attribute can't be read.
    var frame: CGRect? {
        guard let position = position, let size = size else { return nil }
        return CGRect(origin: position, size: size)
    }

    var position: CGPoint? {
        copyValue(kAXPositionAttribute, type: .cgPoint) { raw in
            var point = CGPoint.zero
            return AXValueGetValue(raw, .cgPoint, &point) ? point : nil
        }
    }

    var size: CGSize? {
        copyValue(kAXSizeAttribute, type: .cgSize) { raw in
            var size = CGSize.zero
            return AXValueGetValue(raw, .cgSize, &size) ? size : nil
        }
    }

    var title: String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// The window's `CGWindowID`, via the private AX bridge, for correlating
    /// with `CGWindowList`. Nil if the element isn't a real on-screen window.
    var windowID: CGWindowID? {
        var wid = CGWindowID(0)
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
    }

    /// False once the underlying window has been closed (the AX element goes
    /// invalid). Used to detect a pane whose window the user closed.
    var isAlive: Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    /// Bring this window to the front of its application's window stack.
    @discardableResult
    func raise() -> AXError {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    private func stringAttribute(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Whether auto-tiling should manage this window. Must be a real top-level
    /// **standard** window — not a dialog, sheet, popover, bubble, or utility
    /// panel. Browsers (Brave/Chrome) spawn lots of transient `AXWindow`s for
    /// autofill/menus/extension popups; those report a non-standard subrole
    /// (often `AXUnknown`), so we require `AXStandardWindow` rather than accepting
    /// any `AXWindow`.
    var isTileable: Bool {
        guard stringAttribute(kAXRoleAttribute) == (kAXWindowRole as String) else { return false }
        if let subrole = stringAttribute(kAXSubroleAttribute) {
            return subrole == (kAXStandardWindowSubrole as String)
        }
        // No subrole reported (rare — a few apps never set one). Fall back to a
        // real window's tell: title-bar controls. Popovers/bubbles have none.
        return hasAttribute(kAXCloseButtonAttribute)
    }

    /// True if the element exposes (can read) the given attribute.
    private func hasAttribute(_ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    }

    /// True when the window is in macOS **native fullscreen** (it has moved to
    /// its own Space and fills the display). Read via the undocumented
    /// `AXFullScreen` attribute that Safari/Chrome/most AppKit apps expose — the
    /// same signal yabai/AeroSpace use. A fullscreen window has left the tiling
    /// area, so Tessera must leave it alone (no re-snap, no float-out, don't
    /// disturb its pane) until it returns.
    var isFullscreen: Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &value) == .success
        else { return false }
        return (value as? Bool) ?? false
    }

    var isMinimized: Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success
        else { return false }
        return (value as? Bool) ?? false
    }

    /// Minimize/unminimize — the reliable fallback for hiding a window that
    /// refuses to move off-screen (e.g. browsers clamp their position on-screen).
    func setMinimized(_ minimized: Bool) {
        AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString,
            (minimized ? kCFBooleanTrue : kCFBooleanFalse)
        )
    }

    /// Move the window so its top-left corner sits at `point`. Returns the AX
    /// error so callers can detect apps that refuse to move.
    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    /// Resize the window. Some apps clamp to a minimum size and will report
    /// `.success` while ignoring part of the request — callers should re-read
    /// `size` if exactness matters.
    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    /// Set both position and size to the given frame. Position is set first so a
    /// window that's being grown doesn't briefly clip off-screen. Returns the
    /// resulting frame after the app has had its say (which may differ from the
    /// request if the app enforces a minimum size).
    ///
    /// Wrapped in an `AXEnhancedUserInterface` toggle: apps built on
    /// Chromium/Electron (Brave, Chrome, VS Code, Slack…) set that app-level
    /// attribute — especially once an accessibility client attaches — and while
    /// it's on, AX geometry writes are **animated/deferred and don't stick**, so
    /// the window resists tiling. Disabling it around the writes makes the frame
    /// apply synchronously, then we restore it. Same undocumented trick as
    /// yabai / Rectangle / AeroSpace; needs no SIP.
    @discardableResult
    func setFrame(_ rect: CGRect) -> CGRect? {
        let app = appElement()
        var restoreEnhancedUI = false
        if let app, boolAttribute(app, "AXEnhancedUserInterface") == true {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            restoreEnhancedUI = true
        }
        defer {
            if restoreEnhancedUI, let app {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }
        setPosition(rect.origin)
        setSize(rect.size)
        // Re-set position: growing a window can shift its origin, so a second
        // position write pins the top-left corner where we asked for it.
        setPosition(rect.origin)
        return frame
    }

    /// The owning application's AX element, for app-level attributes.
    private func appElement() -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    private func copyValue<T>(
        _ attribute: String,
        type: AXValueType,
        unbox: (AXValue) -> T?
    ) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        // AXValue is a CF type; bridge the copied ref back to it before unboxing.
        let axValue = value as! AXValue
        return unbox(axValue)
    }
}
