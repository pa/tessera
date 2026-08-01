import ApplicationServices
import AppKit

/// Locates a target application's windows through the Accessibility tree.
///
/// Given a bundle identifier, it finds the running process (launching it if
/// asked), builds the application-level `AXUIElement`, and hands back the
/// window elements Tessera will move and resize.
@MainActor
enum AppTargeter {
    /// The running application for a bundle id, or nil if it isn't running.
    static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    /// Launch an app if necessary, then wait asynchronously for its first
    /// tileable window. This never blocks AppKit's main thread: app launch
    /// completions and AX window creation can both depend on that run loop.
    static func launchApplication(
        bundleID: String,
        completion: @escaping @MainActor (pid_t, AXWindow?) -> Void
    ) {
        if let app = runningApp(bundleID: bundleID) {
            waitForTileableWindow(pid: app.processIdentifier, attemptsRemaining: 50, completion: completion)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion(0, nil)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            let pid = app?.processIdentifier ?? 0
            Task { @MainActor in
                guard pid != 0 else { completion(0, nil); return }
                waitForTileableWindow(pid: pid, attemptsRemaining: 50, completion: completion)
            }
        }
    }

    private static func waitForTileableWindow(
        pid: pid_t,
        attemptsRemaining: Int,
        completion: @escaping @MainActor (pid_t, AXWindow?) -> Void
    ) {
        let appElement = AXUIElementCreateApplication(pid)
        if let window = windows(of: appElement).first(where: { $0.isTileable && !$0.isMinimized }) {
            completion(pid, window)
            return
        }
        guard attemptsRemaining > 0 else {
            completion(pid, nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitForTileableWindow(pid: pid, attemptsRemaining: attemptsRemaining - 1, completion: completion)
        }
    }

    /// All window elements owned by an application element.
    static func windows(of appElement: AXUIElement) -> [AXWindow] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let raw = value as? [AXUIElement] else { return [] }
        return raw.map(AXWindow.init(element:))
    }

    /// Raise a specific window (by CGWindowID) within its app and bring the app
    /// forward. Falls back to plain app activation if the window can't be found.
    static func focusWindow(pid: pid_t, windowID: CGWindowID) {
        window(pid: pid, windowID: windowID)?.raise()
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    /// Hide or show an entire application via `kAXHiddenAttribute` (the AX
    /// equivalent of ⌘H / "Hide Others"). Application-level, so it's used to
    /// make a tiling tab exclusive: hide every app with no window in the tab.
    static func setHidden(_ hidden: Bool, pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(
            appElement,
            kAXHiddenAttribute as CFString,
            (hidden ? kCFBooleanTrue : kCFBooleanFalse)
        )
    }

    /// All regular (Dock-present) running apps except Tessera itself.
    static func regularApps() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
    }

    /// Resolve a specific window element by its owning pid + CGWindowID, so a
    /// window tracked by id can be re-fetched later to move/resize it.
    static func window(pid: pid_t, windowID: CGWindowID) -> AXWindow? {
        let appElement = AXUIElementCreateApplication(pid)
        return windows(of: appElement).first { $0.windowID == windowID }
    }

    /// The window that currently has keyboard focus system-wide, with its pid.
    /// Read straight from the system-wide AX element, so it reflects the *actual*
    /// focused window regardless of app-activation tracking — the reliable way
    /// to know "what is the user in right now". Returns nil if the focused app is
    /// `excludingPID` (i.e. Tessera itself, e.g. while its menu is open).
    static func systemFocusedWindow(excludingPID: pid_t) -> (pid: pid_t, window: AXWindow)? {
        let system = AXUIElementCreateSystemWide()
        var appValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appValue) == .success,
              let appValue else { return nil }
        guard CFGetTypeID(appValue) == AXUIElementGetTypeID() else { return nil }
        let appElement = appValue as! AXUIElement

        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success, pid != excludingPID else { return nil }

        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
           let windowValue {
            guard CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
            return (pid, AXWindow(element: windowValue as! AXUIElement))
        }
        if let first = windows(of: appElement).first {
            return (pid, first)
        }
        return nil
    }

    /// The focused window (or first window) of a specific application. Used as a
    /// fallback when the system-wide focused app is Tessera itself.
    static func focusedWindow(ofPID pid: pid_t) -> AXWindow? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused {
            guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return windows(of: appElement).first }
            return AXWindow(element: focused as! AXUIElement)
        }
        return windows(of: appElement).first
    }

}
