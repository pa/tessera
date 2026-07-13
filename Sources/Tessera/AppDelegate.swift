import AppKit
import ApplicationServices
import TesseraCore

/// Milestone 1 prototype driver.
///
/// Presents a menu-bar item that (1) surfaces the Accessibility trust state and
/// a one-click path to grant it, (2) lets you pick a target app (Terminal or
/// Safari), and (3) snaps that app's main window to exact coordinates via the
/// AX engine — proving Tessera can puppet arbitrary GUI windows, the brief's
/// hardest technical hurdle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let commandPalette = CommandPaletteController()
    private lazy var tiling = TilingController(palette: commandPalette) { [weak self] in
        guard let pid = self?.lastActiveAppPID,
              let window = AppTargeter.focusedWindow(ofPID: pid) else { return nil }
        return (pid, window)
    }

    /// The most recently activated non-Tessera app. Tracked via workspace
    /// notifications so a split knows which window to act on even while our
    /// status-bar menu is open (when `frontmostApplication` is ambiguous).
    private var lastActiveAppPID: pid_t?

    /// The currently-selected target application.
    private struct Target {
        let name: String
        let bundleID: String
    }
    private let targets = [
        Target(name: "Terminal", bundleID: "com.apple.Terminal"),
        Target(name: "Safari", bundleID: "com.apple.Safari"),
    ]
    private var selectedTargetIndex = 0
    private var selectedTarget: Target { targets[selectedTargetIndex] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "▚"
        statusItem.button?.toolTip = "Tessera"

        // Nudge the system Accessibility prompt on first launch. The grant lands
        // asynchronously; the menu reflects the live state each time it opens.
        AccessibilityAuthorizer.requestIfNeeded()

        trackFrontmostApplication()

        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        statusItem.menu = menu
    }

    // MARK: - Menu

    /// Fill (or refill) the menu in place. Called on first build and again each
    /// time the menu is about to open, so the Accessibility row and target
    /// checkmarks always reflect live state.
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Accessibility status row.
        let trusted = AccessibilityAuthorizer.isTrusted
        let statusRow = NSMenuItem(
            title: trusted ? "Accessibility: granted" : "Accessibility: NOT granted — click to grant",
            action: trusted ? nil : #selector(grantAccessibility),
            keyEquivalent: ""
        )
        statusRow.target = self
        statusRow.isEnabled = !trusted
        menu.addItem(statusRow)
        menu.addItem(.separator())

        // Target picker.
        let targetHeader = NSMenuItem(title: "Target", action: nil, keyEquivalent: "")
        targetHeader.isEnabled = false
        menu.addItem(targetHeader)
        for (index, target) in targets.enumerated() {
            let item = NSMenuItem(title: target.name, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selectedTargetIndex ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Placement actions.
        let actionHeader = NSMenuItem(title: "Move \(selectedTarget.name) to…", action: nil, keyEquivalent: "")
        actionHeader.isEnabled = false
        menu.addItem(actionHeader)
        for placement in ScreenLayout.Placement.allCases {
            let item = NSMenuItem(title: placement.rawValue, action: #selector(applyPlacement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = placement.rawValue
            item.isEnabled = trusted
            menu.addItem(item)
        }

        // Exactness proof: a fixed off-grid rect, then read back the result.
        let exact = NSMenuItem(title: "Exact test (100, 100, 900×620)", action: #selector(applyExactTest), keyEquivalent: "")
        exact.target = self
        exact.isEnabled = trusted
        menu.addItem(exact)

        menu.addItem(.separator())
        let palette = NSMenuItem(title: "Command Palette…", action: #selector(openCommandPalette), keyEquivalent: " ")
        palette.keyEquivalentModifierMask = [.command]
        palette.target = self
        menu.addItem(palette)

        // Tiling / tmux split actions.
        let tileHeader = NSMenuItem(title: "Tiling", action: nil, keyEquivalent: "")
        tileHeader.isEnabled = false
        menu.addItem(tileHeader)
        let splitRight = NSMenuItem(title: "Split Focused → Right", action: #selector(splitRight), keyEquivalent: "d")
        splitRight.keyEquivalentModifierMask = [.command]
        splitRight.target = self
        splitRight.isEnabled = trusted
        menu.addItem(splitRight)
        let splitDown = NSMenuItem(title: "Split Focused → Down", action: #selector(splitDown), keyEquivalent: "D")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        splitDown.target = self
        splitDown.isEnabled = trusted
        menu.addItem(splitDown)
        let resetTiling = NSMenuItem(title: "Reset Tiling", action: #selector(resetTiling), keyEquivalent: "")
        resetTiling.target = self
        menu.addItem(resetTiling)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tessera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Actions

    @objc private func grantAccessibility() {
        AccessibilityAuthorizer.requestIfNeeded()
        AccessibilityAuthorizer.openSettingsPane()
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        selectedTargetIndex = sender.tag
    }

    @objc private func applyPlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let placement = ScreenLayout.Placement(rawValue: raw) else { return }
        let target = placement.frame(in: ScreenLayout.mainDisplayBounds)
        moveSelectedTarget(to: target)
    }

    @objc private func applyExactTest() {
        moveSelectedTarget(to: CGRect(x: 100, y: 100, width: 900, height: 620))
    }

    @objc private func openCommandPalette() {
        // Standalone palette: selecting just launches/focuses. Reset the
        // callbacks each time so a prior split's handlers don't linger.
        commandPalette.onSelect = { [weak self] item in self?.activate(item) }
        commandPalette.onCancel = nil
        commandPalette.present()
    }

    @objc private func splitRight() { tiling.split(.horizontal) }
    @objc private func splitDown() { tiling.split(.vertical) }
    @objc private func resetTiling() { tiling.reset() }

    /// Remember the most recent non-Tessera frontmost app, so a split acts on
    /// the window the user was actually using.
    private func trackFrontmostApplication() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastActiveAppPID = front.processIdentifier
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID else { return }
            MainActor.assumeIsolated { self?.lastActiveAppPID = app.processIdentifier }
        }
    }

    /// Default palette action: bring the chosen app/window to the front. Later
    /// milestones will replace this with "snap into the focused pane".
    private func activate(_ item: PaletteItem) {
        switch item.kind {
        case .window(let windowID):
            if let pid = item.pid {
                AppTargeter.focusWindow(pid: pid, windowID: windowID)
            }
        case .application:
            guard let bundleID = item.bundleID else { return }
            if let running = AppTargeter.runningApp(bundleID: bundleID) {
                running.activate(options: [.activateAllWindows])
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    private func moveSelectedTarget(to rect: CGRect) {
        guard AccessibilityAuthorizer.isTrusted else {
            AccessibilityAuthorizer.requestIfNeeded()
            return
        }
        let target = selectedTarget
        do {
            let window = try AppTargeter.mainWindow(bundleID: target.bundleID, launchIfNeeded: true)
            let resulting = window.setFrame(rect)
            report(target: target, requested: rect, resulting: resulting)
        } catch {
            presentAlert(title: "Couldn't move \(target.name)", message: "\(error)")
        }
    }

    // MARK: - Feedback

    private func report(target: Target, requested: CGRect, resulting: CGRect?) {
        guard let resulting else {
            presentAlert(title: "\(target.name) moved",
                         message: "Requested \(format(requested)) but couldn't read back the result.")
            return
        }
        // Prove exactness: an exact placement round-trips within a pixel; a
        // clamped app (min-size enforced) shows a visible delta here.
        let matches = abs(resulting.origin.x - requested.origin.x) < 1
            && abs(resulting.origin.y - requested.origin.y) < 1
            && abs(resulting.size.width - requested.size.width) < 1
            && abs(resulting.size.height - requested.size.height) < 1
        if matches { return } // silent success — the window moved exactly
        presentAlert(
            title: "\(target.name) resisted exact placement",
            message: "Requested \(format(requested))\nGot \(format(resulting))\n\nThe app likely enforces a minimum size — this is the fallback case the brief calls out."
        )
    }

    private func format(_ rect: CGRect) -> String {
        String(format: "(%.0f, %.0f) %.0f×%.0f",
               rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }
}
