import AppKit
import ApplicationServices

/// Watches every regular app for `kAXWindowCreated` via `AXObserver`, so a newly
/// opened window is reported the instant it appears (rather than waiting for the
/// 0.6s maintenance poll). This is what makes auto-tiling adopt launched-app
/// windows reliably. One observer per app; apps that launch/terminate are
/// tracked via NSWorkspace notifications.
@MainActor
final class WindowObserver {
    /// Called shortly after a window is created (after a small settle delay so
    /// its CGWindowID and subrole are populated).
    var onWindowCreated: ((pid_t, AXWindow) -> Void)?

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
    }

    private func addObserver(pid: pid_t) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard pid != ownPID, observers[pid] == nil else { return }

        // Non-capturing C callback: the created window is the `element` argument.
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            let window = AXWindow(element: element)
            var elementPID: pid_t = 0
            AXUIElementGetPid(element, &elementPID)
            // Let the window finish initializing (id/subrole) before reporting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { observer.onWindowCreated?(elementPID, window) }
            }
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, appElement,
                                  kAXWindowCreatedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func removeObserver(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
