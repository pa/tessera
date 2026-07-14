import ApplicationServices
import AppKit

/// Locates a target application's windows through the Accessibility tree.
///
/// Given a bundle identifier, it finds the running process (launching it if
/// asked), builds the application-level `AXUIElement`, and hands back the
/// window elements Tessera will move and resize.
enum AppTargeter {
    enum TargetError: Error, CustomStringConvertible {
        case notRunning(String)
        case launchFailed(String)
        case noWindows(String)

        var description: String {
            switch self {
            case .notRunning(let id): return "\(id) is not running."
            case .launchFailed(let id): return "Could not launch \(id)."
            case .noWindows(let id): return "\(id) has no accessible windows."
            }
        }
    }

    /// The running application for a bundle id, or nil if it isn't running.
    static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    /// The application-level AX element for a bundle id, launching the app and
    /// waiting briefly if it isn't already running.
    static func applicationElement(bundleID: String, launchIfNeeded: Bool) throws -> AXUIElement {
        if let app = runningApp(bundleID: bundleID) {
            return AXUIElementCreateApplication(app.processIdentifier)
        }
        guard launchIfNeeded else { throw TargetError.notRunning(bundleID) }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw TargetError.launchFailed(bundleID)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        // Launch synchronously enough for a prototype: kick it off, wait for the
        // completion handler, then look the process up via the workspace (which
        // avoids capturing a mutable var across the concurrent callback).
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)

        guard let app = runningApp(bundleID: bundleID) else {
            throw TargetError.launchFailed(bundleID)
        }
        // Give the app a beat to create its first window before we query.
        for _ in 0..<20 where windows(of: AXUIElementCreateApplication(app.processIdentifier)).isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return AXUIElementCreateApplication(app.processIdentifier)
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
        let appElement = appValue as! AXUIElement

        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success, pid != excludingPID else { return nil }

        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
           let windowValue {
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
            return AXWindow(element: focused as! AXUIElement)
        }
        return windows(of: appElement).first
    }

    /// The app's primary window — the one the user would expect a "move this
    /// app" command to act on. Prefers the AX main window, falling back to the
    /// first window in the list.
    static func mainWindow(bundleID: String, launchIfNeeded: Bool) throws -> AXWindow {
        let appElement = try applicationElement(bundleID: bundleID, launchIfNeeded: launchIfNeeded)

        var mainValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainValue) == .success,
           let mainValue {
            return AXWindow(element: mainValue as! AXUIElement)
        }

        guard let first = windows(of: appElement).first else {
            throw TargetError.noWindows(bundleID)
        }
        return first
    }
}
