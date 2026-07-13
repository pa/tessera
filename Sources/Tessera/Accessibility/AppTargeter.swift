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
