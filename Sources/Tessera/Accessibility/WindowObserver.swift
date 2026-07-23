import AppKit
import ApplicationServices

/// Watches every regular app via `AXObserver` for window **created** and
/// **destroyed** events, so new windows are adopted and closed windows collapse
/// the instant they happen — rather than waiting for the maintenance poll. One
/// observer per app; apps that launch/terminate are tracked via NSWorkspace
/// notifications.
@MainActor
final class WindowObserver {
    /// Called shortly after a window is created (after a small settle delay so
    /// its CGWindowID and subrole are populated).
    var onWindowCreated: ((pid_t, AXWindow) -> Void)?

    /// Called the instant a window is destroyed (closed), so a pane can collapse
    /// without waiting for the poll. It's just a "recheck now" signal — the
    /// destroyed element is already invalid.
    var onWindowDestroyed: (() -> Void)?

    /// Called when a window is moved or resized (by the user, outside Tessera),
    /// with that window — so the layout can re-snap it. Fires continuously during
    /// a drag; the controller debounces.
    var onWindowMovedOrResized: ((AXWindow) -> Void)?

    /// Called when an app's focused window changes (user clicked into a window),
    /// so the controller can keep "the focused pane" current — which is where the
    /// next new-window split originates.
    var onFocusedWindowChanged: ((pid_t, AXWindow) -> Void)?

    private var observers: [pid_t: AXObserver] = [:]

    func start() {
        for app in AppTargeter.regularApps() { addObserver(pid: app.processIdentifier) }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.addObserver(pid: pid) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.removeObserver(pid: pid) }
        }
        // Retry attaching on activation: some apps aren't AX-ready at launch, so
        // their observer may have failed to attach. addObserver is idempotent.
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.addObserver(pid: pid) }
        }
    }

    private func addObserver(pid: pid_t) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard pid != ownPID, observers[pid] == nil else { return }

        // Non-capturing C callback: dispatches by notification name. `element` is
        // the created window (for created) or the dying element (for destroyed).
        let callback: AXObserverCallback = { observerRef, element, notification, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            if name == (kAXUIElementDestroyedNotification as String) {
                MainActor.assumeIsolated { observer.onWindowDestroyed?() }
            } else if name == (kAXWindowMovedNotification as String)
                   || name == (kAXWindowResizedNotification as String) {
                let window = AXWindow(element: element)
                MainActor.assumeIsolated { observer.onWindowMovedOrResized?(window) }
            } else if name == (kAXFocusedWindowChangedNotification as String) {
                let window = AXWindow(element: element)
                var elementPID: pid_t = 0
                AXUIElementGetPid(element, &elementPID)
                MainActor.assumeIsolated { observer.onFocusedWindowChanged?(elementPID, window) }
            } else { // kAXWindowCreatedNotification
                // Watch this new window for destruction + user move/resize.
                WindowObserver.watchWindow(observerRef, element, refcon)
                let window = AXWindow(element: element)
                var elementPID: pid_t = 0
                AXUIElementGetPid(element, &elementPID)
                // Report quickly, with a fallback: a just-created window's
                // CGWindowID / subrole may not be populated on the first tick, so
                // try at 60ms (snappy for the common case) and again at 220ms as a
                // safety net. The controller dedups (knownWindowIDs), so the second
                // fire is a no-op once adopted.
                for delay in [0.06, 0.22] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        MainActor.assumeIsolated { observer.onWindowCreated?(elementPID, window) }
                    }
                }
            }
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        // Watch each already-open window for destroy/move/resize (the created
        // notification only covers windows opened from now on).
        for window in AppTargeter.windows(of: appElement) {
            WindowObserver.watchWindow(observer, window.element, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// Register destroy + move + resize notifications on a window element. Adding
    /// a notification that's already registered is a harmless no-op, so this is
    /// safe to call again (e.g. on an activation re-attach).
    private static func watchWindow(_ observer: AXObserver, _ element: AXUIElement, _ refcon: UnsafeMutableRawPointer) {
        AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXWindowResizedNotification as CFString, refcon)
    }

    private func removeObserver(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
