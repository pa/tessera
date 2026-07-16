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
    private lazy var hotKeyPrefs: HotKeyPreferencesController = {
        let controller = HotKeyPreferencesController(bindingSet: bindingSet)
        controller.onChange = { [weak self] set in self?.applyBindings(set) }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Tessera"
        tiling.onWorkspaceChange = { [weak self] in self?.refreshStatusIndicator() }
        statusItem.button?.title = tabIndicator()

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
        // Tiling actions. The chord in each title reflects the live binding set;
        // the actual shortcut is handled globally by HotKeyManager, so menu
        // items carry no key-equivalent (which would only fire when active).
        let palette = NSMenuItem(title: "Command Palette…\(chordSuffix(.palette))", action: #selector(openCommandPalette), keyEquivalent: "")
        palette.target = self
        menu.addItem(palette)
        let navigatorItem = NSMenuItem(title: "Workspace Navigator…\(chordSuffix(.navigator))", action: #selector(openNavigator), keyEquivalent: "")
        navigatorItem.target = self
        menu.addItem(navigatorItem)
        let firstWindow = NSMenuItem(title: "Pick First Window…", action: #selector(pickFirstWindow), keyEquivalent: "")
        firstWindow.target = self
        firstWindow.isEnabled = trusted
        menu.addItem(firstWindow)

        let tileHeader = NSMenuItem(title: "Tiling", action: nil, keyEquivalent: "")
        tileHeader.isEnabled = false
        menu.addItem(tileHeader)
        let splitRight = NSMenuItem(title: "Split Focused → Right\(chordSuffix(.splitRight))", action: #selector(splitRight), keyEquivalent: "")
        splitRight.target = self
        splitRight.isEnabled = trusted
        menu.addItem(splitRight)
        let splitDown = NSMenuItem(title: "Split Focused → Down\(chordSuffix(.splitDown))", action: #selector(splitDown), keyEquivalent: "")
        splitDown.target = self
        splitDown.isEnabled = trusted
        menu.addItem(splitDown)
        let fullscreen = NSMenuItem(title: "Toggle Fullscreen Pane", action: #selector(toggleFullscreen), keyEquivalent: "")
        fullscreen.target = self
        fullscreen.isEnabled = trusted
        menu.addItem(fullscreen)
        let floatPane = NSMenuItem(title: "Toggle Float Pane", action: #selector(toggleFloat), keyEquivalent: "")
        floatPane.target = self
        floatPane.isEnabled = trusted
        menu.addItem(floatPane)
        let changeWindow = NSMenuItem(title: "Change Pane Window…", action: #selector(changePaneWindow), keyEquivalent: "")
        changeWindow.target = self
        changeWindow.isEnabled = trusted
        menu.addItem(changeWindow)
        let stacked = NSMenuItem(title: "Toggle Stacked Layout", action: #selector(toggleStacked), keyEquivalent: "")
        stacked.target = self
        stacked.isEnabled = trusted
        menu.addItem(stacked)
        let balance = NSMenuItem(title: "Balance Sizes", action: #selector(balanceSizes), keyEquivalent: "")
        balance.target = self
        balance.isEnabled = trusted
        menu.addItem(balance)
        let solo = NSMenuItem(title: "Keep Only Focused Pane", action: #selector(soloPane), keyEquivalent: "")
        solo.target = self
        solo.isEnabled = trusted
        menu.addItem(solo)
        let resetTiling = NSMenuItem(title: "Reset Tiling\(chordSuffix(.reset))", action: #selector(resetTiling), keyEquivalent: "")
        resetTiling.target = self
        menu.addItem(resetTiling)

        // Virtual tabs.
        let tabs = tiling.tabSummary
        let tabHeader = NSMenuItem(title: "Tabs  (tab \(tabs.index + 1) of \(tabs.count))", action: nil, keyEquivalent: "")
        tabHeader.isEnabled = false
        menu.addItem(tabHeader)
        let newTab = NSMenuItem(title: "New Tab\(chordSuffix(.newTab))", action: #selector(newTab), keyEquivalent: "")
        newTab.target = self
        newTab.isEnabled = trusted
        menu.addItem(newTab)
        let nextTab = NSMenuItem(title: "Next Tab\(chordSuffix(.nextTab))", action: #selector(nextTab), keyEquivalent: "")
        nextTab.target = self
        nextTab.isEnabled = trusted && tabs.count > 1
        menu.addItem(nextTab)
        let prevTab = NSMenuItem(title: "Previous Tab\(chordSuffix(.previousTab))", action: #selector(previousTab), keyEquivalent: "")
        prevTab.target = self
        prevTab.isEnabled = trusted && tabs.count > 1
        menu.addItem(prevTab)
        let moveToNext = NSMenuItem(title: "Move Window → Next Tab", action: #selector(moveWindowToNextTab), keyEquivalent: "")
        moveToNext.target = self
        moveToNext.isEnabled = trusted && tabs.count > 1
        menu.addItem(moveToNext)
        let moveToPrev = NSMenuItem(title: "Move Window → Previous Tab", action: #selector(moveWindowToPrevTab), keyEquivalent: "")
        moveToPrev.target = self
        moveToPrev.isEnabled = trusted && tabs.count > 1
        menu.addItem(moveToPrev)
        let lastTab = NSMenuItem(title: "Toggle Last Tab", action: #selector(toggleLastTab), keyEquivalent: "")
        lastTab.target = self
        lastTab.isEnabled = trusted && tabs.count > 1
        menu.addItem(lastTab)

        menu.addItem(.separator())
        let hotkeySettings = NSMenuItem(title: "Hotkey Settings…", action: #selector(openHotKeyPreferences), keyEquivalent: "")
        hotkeySettings.target = self
        menu.addItem(hotkeySettings)
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

    @objc private func splitRight() { tiling.split(.horizontal) }
    @objc private func splitDown() { tiling.split(.vertical) }
    @objc private func resetTiling() { tiling.reset() }
    @objc private func changePaneWindow() { tiling.changeFocusedPaneWindow() }
    @objc private func toggleFullscreen() { tiling.toggleFullscreen() }
    @objc private func toggleFloat() { tiling.toggleFloat() }
    @objc private func pickFirstWindow() { tiling.promptFirstWindow() }

    @objc private func openNavigator() {
        let roots = tiling.workspaceSnapshot().map { tab -> WorkspaceNavigatorController.Node in
            let children = tab.panes.map { pane in
                WorkspaceNavigatorController.Node(
                    title: (pane.isFocused ? "▸ " : "") + pane.title,
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
            return WorkspaceNavigatorController.Node(
                title: "Tab \(tab.index + 1)" + (tab.isActive ? "  (current)" : ""),
                emphasized: tab.isActive,
                children: children
            ) { [weak self] in self?.tiling.focusTab(tab.index) }
        }
        navigator.show(roots: roots)
    }
    @objc private func newTab() { tiling.newTab() }
    @objc private func nextTab() { tiling.nextTab() }
    @objc private func previousTab() { tiling.previousTab() }
    @objc private func moveWindowToNextTab() { tiling.moveFocusedToNextTab() }
    @objc private func moveWindowToPrevTab() { tiling.moveFocusedToPreviousTab() }
    @objc private func toggleLastTab() { tiling.toggleLastTab() }
    @objc private func balanceSizes() { tiling.balanceSizes() }
    @objc private func soloPane() { tiling.soloFocusedPane() }
    @objc private func toggleStacked() { tiling.toggleStacked() }

    @objc private func openHotKeyPreferences() { hotKeyPrefs.show() }

    /// Reflect the active input mode in the menu-bar glyph and the HUD hint bar.
    /// In normal mode the glyph shows the current tab position (▚ 2/3); a mode
    /// temporarily overrides it with its own glyph (▚ P/T/R).
    private func applyMode(_ mode: ModeEngine.Mode) {
        statusItem.button?.title = (mode == .normal) ? tabIndicator() : mode.glyph
        if let hint = mode.hudText {
            modeHUD.show(hint)
        } else {
            modeHUD.hide()
        }
    }

    /// Refresh the menu-bar glyph after a tab change (only while in normal mode;
    /// a mode's own glyph takes precedence).
    private func refreshStatusIndicator() {
        if modeEngine.mode == .normal {
            statusItem.button?.title = tabIndicator()
        }
    }

    private func tabIndicator() -> String {
        let tabs = tiling.tabSummary
        return "▚ \(tabs.index + 1)/\(tabs.count)"
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

}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Retry installing the event tap in case Accessibility was granted after
        // launch (start() is a no-op once installed).
        modeEngine.start()
        populate(menu)
    }
}
