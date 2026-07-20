import AppKit
import ApplicationServices
import Carbon.HIToolbox
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
    private let navigator = WorkspaceNavigatorController()
    private lazy var tiling = TilingController(palette: commandPalette) { [weak self] in
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Prefer the true system-wide focused window; fall back to the last
        // active app only when the focused app is Tessera itself (e.g. its menu).
        if let focused = AppTargeter.systemFocusedWindow(excludingPID: ownPID) {
            return focused
        }
        if let pid = self?.lastActiveAppPID, let window = AppTargeter.focusedWindow(ofPID: pid) {
            return (pid, window)
        }
        return nil
    }

    /// The most recently activated non-Tessera app. Tracked via workspace
    /// notifications so a split knows which window to act on even while our
    /// status-bar menu is open (when `frontmostApplication` is ambiguous).
    private var lastActiveAppPID: pid_t?

    private let hotKeys = HotKeyManager()
    private let windowObserver = WindowObserver()
    private let modeHUD = ModeHUD()
    private lazy var modeEngine: ModeEngine = {
        let engine = ModeEngine(tiling: tiling)
        engine.onModeChange = { [weak self] mode in self?.applyMode(mode) }
        return engine
    }()
    private var bindingSet = HotKeyStore.load()
    private lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController(bindingSet: bindingSet, settings: SettingsStore.load())
        controller.onHotKeysChange = { [weak self] set in self?.applyBindings(set) }
        controller.onPaddingChange = { [weak self] percent in self?.tiling.updatePaddingPercent(percent) }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Tessera"
        tiling.onWorkspaceChange = { [weak self] in self?.refreshStatusIndicator() }
        statusItem.button?.title = statusTitle(for: .normal)

        // Nudge the system Accessibility prompt on first launch. The grant lands
        // asynchronously; the menu reflects the live state each time it opens.
        AccessibilityAuthorizer.requestIfNeeded()

        trackFrontmostApplication()
        applyBindings(bindingSet)
        modeEngine.start()
        tiling.startEnforcing()
        windowObserver.onWindowCreated = { [weak self] pid, window in
            self?.tiling.handleWindowCreated(pid: pid, window: window)
        }
        windowObserver.start()

        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        statusItem.menu = menu

        // On startup (once Accessibility is granted): restore the saved session
        // if any windows match; otherwise prompt for the first window.
        if AccessibilityAuthorizer.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                let restored = SessionStore.load().map { self.tiling.restoreSession($0) } ?? false
                if !restored { self.tiling.promptFirstWindow() }
                self.startSessionAutosave()
            }
        }
    }

    private var sessionSaveTimer: Timer?
    private func startSessionAutosave() {
        sessionSaveTimer?.invalidate()
        sessionSaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self.map { SessionStore.save($0.tiling.captureSession()) } }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.save(tiling.captureSession()) // persist layout for next launch
        // Restore any hidden apps and re-snap windows before exiting.
        tiling.teardown()
    }

    // MARK: - Menu

    /// Fill (or refill) the menu in place. Called on first build and again each
    /// time the menu is about to open, so the Accessibility row and live tab
    /// count reflect current state.
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
        // Deliberately minimal: the palette and navigator are the only actions
        // here (everything else lives on hotkeys / modes). The chord in each
        // title reflects the live binding set; the shortcut itself fires globally
        // via HotKeyManager, so the items carry no key-equivalent.
        let palette = NSMenuItem(title: "Command Palette…\(chordSuffix(.palette))", action: #selector(openCommandPalette), keyEquivalent: "")
        palette.target = self
        palette.isEnabled = trusted
        menu.addItem(palette)
        let navigatorItem = NSMenuItem(title: "Workspace Navigator…\(chordSuffix(.navigator))", action: #selector(openNavigator), keyEquivalent: "")
        navigatorItem.target = self
        navigatorItem.isEnabled = trusted
        menu.addItem(navigatorItem)

        menu.addItem(.separator())
        // ⌘, opens Settings when Tessera is active (e.g. this menu / a Tessera
        // window); the menu item works regardless.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit Tessera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Actions

    @objc private func grantAccessibility() {
        AccessibilityAuthorizer.requestIfNeeded()
        AccessibilityAuthorizer.openSettingsPane()
    }

    @objc private func openCommandPalette() {
        // Standalone palette: selecting just launches/focuses. Reset the
        // callbacks each time so a prior split's handlers don't linger.
        commandPalette.onSelect = { [weak self] item in self?.activate(item) }
        commandPalette.onCancel = nil
        commandPalette.present()
    }

    @objc private func openNavigator() {
        let roots = tiling.workspaceSnapshot().map { tab -> WorkspaceNavigatorController.Node in
            let children = tab.panes.map { pane -> WorkspaceNavigatorController.Node in
                let app = NSRunningApplication(processIdentifier: pane.pid)
                let subtitle = pane.isFloating ? "Floating · \(app?.localizedName ?? "")"
                                               : (app?.localizedName ?? "")
                return WorkspaceNavigatorController.Node(
                    title: pane.title,
                    subtitle: subtitle,
                    icon: app?.icon,
                    isGroup: false,
                    emphasized: pane.isFocused,
                    children: []
                ) { [weak self] in
                    if let paneID = pane.paneID {
                        self?.tiling.focusPane(tabIndex: tab.index, pane: paneID)
                    } else if let windowID = pane.floatingWindowID {
                        self?.tiling.focusFloating(tabIndex: tab.index, windowID: windowID)
                    }
                }
            }
            let count = tab.panes.count
            // A numbered circle doubles as the tab's number; filled when current.
            let n = tab.index + 1
            let symbol = n <= 50 ? "\(n).circle\(tab.isActive ? ".fill" : "")" : "rectangle.stack"
            return WorkspaceNavigatorController.Node(
                title: "Tab \(n)",
                subtitle: "\(count) window\(count == 1 ? "" : "s")",
                icon: NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                isGroup: true,
                emphasized: tab.isActive,
                children: children
            ) { [weak self] in self?.tiling.focusTab(tab.index) }
        }
        navigator.show(roots: roots)
    }

    @objc private func openSettings() { settingsWindow.show() }

    /// Reflect the active input mode in the menu-bar glyph and the HUD hint bar.
    /// In normal mode the glyph shows the current tab position (▚ 2/3); a mode
    /// temporarily overrides it with its own glyph (▚ P/T/R).
    private func applyMode(_ mode: ModeEngine.Mode) {
        statusItem.button?.title = statusTitle(for: mode)
        if let hint = hudHint(for: mode) {
            modeHUD.show(hint)
        } else {
            modeHUD.hide()
        }
    }

    /// Build the HUD hint for `mode`, showing only the keys that apply to the
    /// current layout — e.g. no focus/swap/stack keys with a single pane, no
    /// prev/next/move-to-tab with a single tab. Keeps the strip honest so the
    /// user isn't offered actions that would do nothing.
    private func hudHint(for mode: ModeEngine.Mode) -> String? {
        let panes = tiling.activePaneCount
        let floating = tiling.activeFloatingCount
        let tabCount = tiling.tabSummary.count
        let windows = panes + floating

        switch mode {
        case .normal:
            return nil
        case .pane:
            var seg = ["r/d split"]
            if panes > 1 { seg.append("hjkl focus"); seg.append("⇧hjkl swap") }
            else if floating > 0 { seg.append("hjkl move") }
            if windows > 1 { seg.append("n/p cycle") }
            if windows >= 1 { seg.append("f full"); seg.append("w float") }
            if panes > 1 { seg.append("s stack") }
            if windows >= 1 { seg.append("c change") }
            seg.append("⏎/esc done")
            return "PANE   " + seg.joined(separator: " · ")
        case .tab:
            var seg = ["n new"]
            if tabCount > 1 { seg.append("h/l prev/next"); seg.append("⇧h/⇧l move to tab") }
            seg.append("⏎/esc done")
            return "TAB   " + seg.joined(separator: " · ")
        case .resize:
            if panes <= 1 { return "RESIZE   single pane — nothing to resize · ⏎/esc done" }
            return "RESIZE   h narrower · l wider · k taller · j shorter · ⏎/esc done"
        }
    }

    /// Refresh the pill after a workspace change so a tab switch is reflected in
    /// any mode (the tab position is always shown). While in a mode, also refresh
    /// the HUD so its hints track layout changes made without leaving the mode.
    private func refreshStatusIndicator() {
        statusItem.button?.title = statusTitle(for: modeEngine.mode)
        if modeEngine.mode != .normal, let hint = hudHint(for: modeEngine.mode) {
            modeHUD.show(hint)
        }
    }

    /// The menu-bar pill text: the mode glyph plus the current tab position, so
    /// switching tabs is visible in the pill regardless of mode (▚ 2/3, ▚ T 2/3…).
    private func statusTitle(for mode: ModeEngine.Mode) -> String {
        let tabs = tiling.tabSummary
        return "\(mode.glyph) \(tabs.index + 1)/\(tabs.count)"
    }

    /// Register every global shortcut from the current binding set. Called at
    /// launch and whenever the user edits bindings in preferences.
    private func applyBindings(_ set: KeyBindingSet) {
        bindingSet = set
        hotKeys.unregisterAll()
        for (command, binding) in set.bindings where !TilingCommand.modeEntry.contains(command) {
            let modifiers = HotKeyManager.Modifiers(rawValue: binding.modifiers)
            hotKeys.register(keyCode: binding.keyCode, modifiers: modifiers, action: action(for: command))
        }
        // Mode-entry chords are interpreted by the event tap, not the hot-key
        // manager — hand them to the engine.
        modeEngine.updateEntryChords(pane: chord(set.bindings[.enterPaneMode]),
                                     tab: chord(set.bindings[.enterTabMode]),
                                     resize: chord(set.bindings[.enterResizeMode]))
    }

    /// Convert a stored binding into an event-tap chord.
    private func chord(_ binding: KeyBinding?) -> ModeEngine.Chord {
        guard let binding else { return ModeEngine.Chord(keyCode: -1, flags: []) }
        return ModeEngine.Chord(keyCode: Int64(binding.keyCode),
                                flags: KeySymbols.cgFlags(fromCarbon: binding.modifiers))
    }

    private func action(for command: TilingCommand) -> () -> Void {
        switch command {
        case .splitRight: return { [weak self] in self?.tiling.split(.horizontal) }
        case .splitDown: return { [weak self] in self?.tiling.split(.vertical) }
        case .focusLeft: return { [weak self] in self?.tiling.moveFocus(.left) }
        case .focusDown: return { [weak self] in self?.tiling.moveFocus(.down) }
        case .focusUp: return { [weak self] in self?.tiling.moveFocus(.up) }
        case .focusRight: return { [weak self] in self?.tiling.moveFocus(.right) }
        case .moveLeft: return { [weak self] in self?.tiling.moveWindow(.left) }
        case .moveDown: return { [weak self] in self?.tiling.moveWindow(.down) }
        case .moveUp: return { [weak self] in self?.tiling.moveWindow(.up) }
        case .moveRight: return { [weak self] in self?.tiling.moveWindow(.right) }
        case .newTab: return { [weak self] in self?.tiling.newTab() }
        case .nextTab: return { [weak self] in self?.tiling.nextTab() }
        case .previousTab: return { [weak self] in self?.tiling.previousTab() }
        case .reset: return { [weak self] in self?.tiling.reset() }
        case .palette: return { [weak self] in self?.openCommandPalette() }
        case .navigator: return { [weak self] in self?.openNavigator() }
        // Mode-entry is handled by the event tap, never registered here.
        case .enterPaneMode, .enterTabMode, .enterResizeMode: return {}
        }
    }

    /// The current chord for a command, formatted for a menu title suffix.
    private func chordSuffix(_ command: TilingCommand) -> String {
        bindingSet.bindings[command].map { "  (\($0.display))" } ?? ""
    }

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
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.lastActiveAppPID = pid
                // If the user switched (Cmd-Tab / third-party switcher) to a window
                // we manage in another tab, follow it there instead of letting it
                // render over the current tab.
                self?.tiling.revealTab(forActivatedApp: pid)
            }
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

}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Retry installing the event tap in case Accessibility was granted after
        // launch (start() is a no-op once installed).
        modeEngine.start()
        populate(menu)
    }
}
