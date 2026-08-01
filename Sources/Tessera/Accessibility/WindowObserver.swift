import AppKit
import ApplicationServices

/// Watches every regular app via `AXObserver` for window lifecycle and geometry
/// events. New windows are registered for later destroy/move/resize observation;
/// Tessera leaves them unmanaged until the user explicitly places them. One
/// observer per app; apps that launch/terminate are tracked via NSWorkspace
/// notifications.
@MainActor
final class WindowObserver {
    /// Called with the exact AX element that was destroyed, allowing the tiling
    /// controller to remove only that pane instead of probing every live window.
    var onWindowDestroyed: ((AXWindow) -> Void)?

    /// Called when an observed application terminates, so all of its managed
    /// windows can be removed even if individual destroy notifications are lost.
    var onApplicationTerminated: ((pid_t) -> Void)?

    /// Called when a window is moved or resized (by the user, outside Tessera),
    /// with that window — so the layout can re-snap it. Fires continuously during
    /// a drag; the controller debounces.
    var onWindowMovedOrResized: ((AXWindow) -> Void)?

    /// Called when an app's focused window changes (user clicked into a window),
    /// so the controller can keep "the focused pane" current — which is where the
    /// next new-window split originates.
    var onFocusedWindowChanged: ((pid_t, AXWindow) -> Void)?

    /// Called on every focused-window transition. Some apps do not send a
    /// window-destroyed notification for a red-close-button action, but do send
    /// this app-level notification after their AX window list has changed.
    var onApplicationWindowsChanged: ((pid_t) -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var isStarted = false

    /// Begin observing once. Keeping notification tokens lets `stop()` fully
    /// detach the observer when the agent terminates or is reconfigured.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        for app in AppTargeter.regularApps() { addObserver(pid: app.processIdentifier) }

        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.addObserver(pid: app.processIdentifier) }
        })
        workspaceObserverTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.onApplicationTerminated?(app.processIdentifier)
                self?.removeObserver(pid: app.processIdentifier)
            }
        })
        // Retry attaching on activation: some apps aren't AX-ready at launch, so
        // their observer may have failed to attach. addObserver is idempotent.
        workspaceObserverTokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.addObserver(pid: app.processIdentifier) }
        })
    }

    /// Detach AX and workspace observers. Safe to call repeatedly.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObserverTokens { center.removeObserver(token) }
        workspaceObserverTokens.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
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
                let window = AXWindow(element: element)
                MainActor.assumeIsolated { observer.onWindowDestroyed?(window) }
            } else if name == (kAXWindowMovedNotification as String)
                   || name == (kAXWindowResizedNotification as String) {
                let window = AXWindow(element: element)
                MainActor.assumeIsolated { observer.onWindowMovedOrResized?(window) }
            } else if name == (kAXFocusedWindowChangedNotification as String) {
                // The callback element is the *application*, not necessarily its
                // newly focused window. Re-query the app so focus and lifecycle
                // state are both accurate (Safari notably relies on this after
                // closing its last window with the red button).
                var elementPID: pid_t = 0
                AXUIElementGetPid(element, &elementPID)
                MainActor.assumeIsolated {
                    observer.onApplicationWindowsChanged?(elementPID)
                    if let window = AppTargeter.focusedWindow(ofPID: elementPID) {
                        observer.onFocusedWindowChanged?(elementPID, window)
                    }
                }
            } else { // kAXWindowCreatedNotification
                // Watch this new window for destruction + user move/resize. It
                // remains unmanaged unless the user explicitly attaches it.
                WindowObserver.watchWindow(observerRef, element, refcon)
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
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
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
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
