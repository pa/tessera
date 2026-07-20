import AppKit
import TesseraCore

/// Ties the pieces together into a tmux-style tiling session:
///   BSP tree (M2) for the geometry, `AXWindow` (M1) to move real windows, and
///   the command palette (M3) to fill new panes.
///
/// A split resizes the focused window into one half of its pane, renders the
/// other half as an empty pane, pops the palette centered in it, and snaps the
/// chosen window into place. Cancelling the palette rolls the split back.
@MainActor
final class TilingController {
    /// Which real window occupies a pane. Holds the AX element directly so
    /// relayout moves *that* window with no re-matching (the pid is kept for
    /// raise/activate).
    private struct WindowRef {
        let pid: pid_t
        let window: AXWindow
    }

    /// A window that floats above the tiled layout at an explicit frame, moved
    /// freely by the user (not part of the BSP tree).
    private struct FloatingWindow {
        let pid: pid_t
        let window: AXWindow
        var frame: CGRect
    }

    /// A virtual tab: an independent BSP workspace plus any floating windows.
    /// When `stacked`, the tiled windows are shown one-at-a-time filling the
    /// workspace (a monocle/accordion layout) instead of BSP-tiled.
    private struct Tab {
        var tree = LayoutTree()
        var occupants: [PaneID: WindowRef] = [:]
        var focusedPane = PaneID(0)
        var floating: [FloatingWindow] = []
        var stacked = false
    }

    private var tabs: [Tab] = [Tab()]
    private var activeTabIndex = 0
    private var pendingPane: PaneID?
    /// Where to return if the new-tab window picker is cancelled.
    private var newTabReturnIndex: Int?
    /// The tab that was active before the current one (for back-and-forth).
    private var lastTabIndex: Int?
    /// When set, this pane's window fills the whole workspace (zoom); the other
    /// tiled windows are parked off-screen until it's un-zoomed.
    private var zoomedPane: PaneID?

    // The split/fill logic works against "the active tab" through these; making
    // them computed keeps that code unchanged while the state lives per-tab.
    private var tree: LayoutTree {
        get { tabs[activeTabIndex].tree }
        set { tabs[activeTabIndex].tree = newValue }
    }
    private var occupants: [PaneID: WindowRef] {
        get { tabs[activeTabIndex].occupants }
        set { tabs[activeTabIndex].occupants = newValue }
    }
    private var focusedPane: PaneID {
        get { tabs[activeTabIndex].focusedPane }
        set { tabs[activeTabIndex].focusedPane = newValue }
    }

    private let palette: CommandPaletteController
    private let overlay = EmptyPaneOverlay()

    /// Supplies the window a split should act on — the last-active app's focused
    /// window, tracked by the app (workspace notifications) so it's reliable
    /// even while a status-bar menu is open.
    private let focusedWindowProvider: () -> (pid: pid_t, window: AXWindow)?

    /// Fired when the active tab or tab count changes, so the menu-bar indicator
    /// can refresh.
    var onWorkspaceChange: (() -> Void)?

    /// Tile gap as a percentage of screen width (user-configurable in Settings).
    /// Drives both the outer margin and the inter-pane gaps.
    private var paddingPercent: Double = SettingsStore.load().paddingPercent

    /// A little breathing room between panes and around the workspace, derived
    /// from `paddingPercent` against the current screen width.
    private var config: LayoutConfig {
        let gap = (paddingPercent / 100.0) * workspaceRect.width
        return LayoutConfig(outerGap: gap, innerGap: gap)
    }

    /// Apply a new padding percentage from Settings and re-tile immediately.
    func updatePaddingPercent(_ percent: Double) {
        paddingPercent = percent
        relayout()
    }

    private var workspaceRect: CGRect { ScreenGeometry.mainUsableBounds }

    /// Periodically re-snaps drifted windows and drops closed ones.
    private var enforcementTimer: Timer?

    /// New standard windows are always auto-added to the active tab.
    private let autoTileEnabled = true
    /// Standard window ids seen so far, so auto-tile only grabs *new* windows.
    private var knownWindowIDs: Set<CGWindowID> = []

    /// Non-tiled windows of managed apps that we've parked off-screen (so only
    /// the tiled window of a multi-window app shows), keyed by CGWindowID with
    /// their original frame for restoration on reset/quit.
    private var parkedExtras: [CGWindowID: (window: AXWindow, frame: CGRect)] = [:]

    init(palette: CommandPaletteController,
         focusedWindowProvider: @escaping () -> (pid: pid_t, window: AXWindow)?) {
        self.palette = palette
        self.focusedWindowProvider = focusedWindowProvider
    }

    // MARK: - Workspace exclusivity (hide others)

    /// Make the active tab exclusive: hide every app with no tiled window; for an
    /// app that *does* have a tiled window, keep it visible but park its other
    /// (non-tiled) windows off-screen so only the tiled one shows. With no tiles,
    /// reveal everything.
    private func applyWorkspaceVisibility() {
        let floating = tabs[activeTabIndex].floating
        let managedPIDs = Set(occupants.values.map(\.pid)).union(floating.map(\.pid))
        let managedWindowIDs = Set(occupants.values.compactMap { $0.window.windowID })
            .union(floating.compactMap { $0.window.windowID })

        for app in AppTargeter.regularApps() {
            let pid = app.processIdentifier
            if managedPIDs.contains(pid) {
                AppTargeter.setHidden(false, pid: pid)
                parkExtraWindows(pid: pid, keeping: managedWindowIDs)
            } else if !managedPIDs.isEmpty {
                AppTargeter.setHidden(true, pid: pid)
            } else {
                AppTargeter.setHidden(false, pid: pid)
            }
        }
    }

    /// Park every window of `pid` whose id isn't in `keeping` off-screen,
    /// recording its frame once so it can be restored later. Already-parked
    /// windows are left alone (no re-move, so no flicker).
    private func parkExtraWindows(pid: pid_t, keeping managedWindowIDs: Set<CGWindowID>) {
        let appElement = AXUIElementCreateApplication(pid)
        for window in AppTargeter.windows(of: appElement) {
            guard let windowID = window.windowID,
                  !managedWindowIDs.contains(windowID),
                  parkedExtras[windowID] == nil,
                  let frame = window.frame else { continue }
            parkedExtras[windowID] = (window, frame)
            park(window)
        }
    }

    private func restoreParkedExtras() {
        for (_, parked) in parkedExtras where parked.window.isAlive {
            unpark(parked.window, to: parked.frame)
        }
        parkedExtras.removeAll()
    }

    private func unhideAllApps() {
        for app in AppTargeter.regularApps() {
            AppTargeter.setHidden(false, pid: app.processIdentifier)
        }
    }

    // MARK: - Layout enforcement

    private var idleTicks = 0
    private let activeInterval: TimeInterval = 0.5
    private let idleInterval: TimeInterval = 2.0

    /// Start the maintenance loop (drops closed windows, adopts new ones,
    /// re-snaps drifted ones). Self-reschedules at an adaptive interval: fast
    /// while things are changing, slow when idle — cutting CPU when the layout
    /// is quiet.
    func startEnforcing() {
        // Seed the known-window set so existing windows aren't grabbed all at
        // once; only windows opened after startup auto-tile.
        knownWindowIDs = allStandardWindowIDs()
        scheduleTick(after: activeInterval)
    }

    private func scheduleTick(after interval: TimeInterval) {
        enforcementTimer?.invalidate()
        enforcementTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let didWork = maintainLayout()
        idleTicks = didWork ? 0 : min(idleTicks + 1, 6)
        scheduleTick(after: idleTicks >= 3 ? idleInterval : activeInterval)
    }

    @discardableResult
    private func maintainLayout() -> Bool {
        guard pendingPane == nil else { return false } // don't disturb a split-in-progress
        var acted = removeClosedWindows()
        if autoTileEnabled { acted = autoTileNewWindows() || acted }
        acted = enforceLayout() || acted
        return acted
    }

    /// Adopt a just-created window into the active tab, if auto-tiling is on and
    /// the window is a new, tileable, unmanaged one. Driven by `WindowObserver`
    /// (`kAXWindowCreated`) so it happens the instant the window appears.
    func handleWindowCreated(pid: pid_t, window: AXWindow) {
        guard autoTileEnabled, pendingPane == nil,
              window.isTileable, let id = window.windowID,
              !knownWindowIDs.contains(id), !occupiedWindowIDs().contains(id) else { return }
        knownWindowIDs.insert(id)
        addToLayout(WindowRef(pid: pid, window: window))
        relayout()
        if let ref = occupants[focusedPane] { focus(ref) }
        applyWorkspaceVisibility()
        onWorkspaceChange?()
    }

    private func allStandardWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        for app in AppTargeter.regularApps() {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            for window in AppTargeter.windows(of: appElement) where window.isTileable {
                if let id = window.windowID { ids.insert(id) }
            }
        }
        return ids
    }

    /// Adopt any newly-opened standard window into the active tab (splitting the
    /// focused pane). Window-based, so different windows of one app can live in
    /// different tabs.
    @discardableResult
    private func autoTileNewWindows() -> Bool {
        let managed = occupiedWindowIDs()
        var current = Set<CGWindowID>()
        var addedAny = false

        for app in AppTargeter.regularApps() {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            for window in AppTargeter.windows(of: appElement) where window.isTileable {
                guard let id = window.windowID else { continue }
                current.insert(id)
                if !knownWindowIDs.contains(id) && !managed.contains(id) {
                    addToLayout(WindowRef(pid: app.processIdentifier, window: window))
                    addedAny = true
                }
            }
        }
        knownWindowIDs = current

        if addedAny {
            relayout()
            if let ref = occupants[focusedPane] { focus(ref) }
            applyWorkspaceVisibility()
            onWorkspaceChange?()
        }
        return addedAny
    }

    /// Drop panes whose window was closed; the BSP tree collapses so the
    /// surviving neighbor expands to fill the freed space.
    /// A window is dead if its owning app quit (process gone) or the window
    /// itself was closed (AX element invalid). Checking the app catches ⌘Q,
    /// where the element returns `cannotComplete` rather than `invalidUIElement`.
    private func windowIsDead(_ ref: WindowRef) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: ref.pid), !app.isTerminated else { return true }
        return !ref.window.isAlive
    }

    @discardableResult
    private func removeClosedWindows() -> Bool {
        var changed = false
        for i in tabs.indices {
            let deadPanes = tabs[i].occupants.compactMap { pane, ref in windowIsDead(ref) ? pane : nil }
            for pane in deadPanes {
                tabs[i].tree.remove(pane)
                tabs[i].occupants[pane] = nil
                if tabs[i].focusedPane == pane {
                    tabs[i].focusedPane = tabs[i].tree.paneIDs.first ?? PaneID(0)
                }
                if i == activeTabIndex && zoomedPane == pane { zoomedPane = nil }
                changed = true
            }
            let floatingBefore = tabs[i].floating.count
            tabs[i].floating.removeAll { windowIsDead(WindowRef(pid: $0.pid, window: $0.window)) }
            if tabs[i].floating.count != floatingBefore { changed = true }
        }
        guard changed else { return false }
        gcEmptyTabs()
        relayout()
        applyWorkspaceVisibility()
        return true
    }

    /// Re-snap any active-tab window that has drifted from its pane frame (the
    /// user resized/moved it outside Tessera). Windows already at their frame are
    /// left alone, so this never fights our own layout changes. Returns whether
    /// any window was re-snapped (so the loop knows something changed).
    @discardableResult
    private func enforceLayout() -> Bool {
        // Stacked windows all target the same full-screen rect; re-snapping every
        // tick fights apps that clamp their size (flicker). Positioning happens
        // on toggle/cycle instead.
        if tabs[activeTabIndex].stacked { return false }
        if let zoomed = zoomedPane, let ref = occupants[zoomed] {
            if let current = ref.window.frame, !current.approximatelyEqual(to: zoomFrame, tolerance: 8) {
                ref.window.setFrame(zoomFrame)
                return true
            }
            return false
        }
        let frames = self.frames()
        var snapped = false
        for (pane, ref) in occupants {
            guard let expected = frames[pane], let current = ref.window.frame else { continue }
            // Don't fight a fullscreen window (native or HTML5 video) back into its
            // pane. It re-snaps naturally on the first tick after it exits.
            if isFullscreenLike(ref.window, frame: current) { continue }
            if !current.approximatelyEqual(to: expected, tolerance: 8) {
                ref.window.setFrame(expected)
                snapped = true
            }
        }
        return snapped
    }

    /// Unhide every app and bring all managed windows back on-screen — for quit.
    func teardown() {
        enforcementTimer?.invalidate()
        enforcementTimer = nil
        for tab in tabs {
            let frames = tab.tree.frames(in: workspaceRect, config: config)
            for (pane, ref) in tab.occupants {
                if let rect = frames[pane] { unpark(ref.window, to: rect) }
            }
            for floater in tab.floating { unpark(floater.window, to: floater.frame) }
        }
        restoreParkedExtras()
        unhideAllApps()
    }

    // MARK: - Public actions (wired to menu / hotkeys)

    /// Split the pane the user is currently in. The active pane is resolved from
    /// the live focused window (not a stale pointer), so clicking into any pane
    /// and splitting divides *that* pane. On first use, adopts the frontmost
    /// window as the initial tile so there's something to split.
    func split(_ orientation: SplitOrientation) {
        guard pendingPane == nil else { return } // a split is already awaiting a pick

        let focused = focusedWindowProvider()

        if let focused, let windowID = focused.window.windowID,
           let pane = pane(containing: windowID) {
            // The focused window is already tiled — split its pane.
            focusedPane = pane
        } else if occupants[focusedPane] == nil {
            // Fresh layout: adopt the focused window as the first tile.
            guard let focused else { NSSound.beep(); return }
            occupants[focusedPane] = WindowRef(pid: focused.pid, window: focused.window)
        }
        // else: focused window isn't managed but a layout exists — best-effort
        // split of the last active pane.

        guard let newPane = tree.split(focusedPane, orientation: orientation) else { return }
        relayout() // focused window shrinks into its half now
        applyWorkspaceVisibility() // clean surface behind the palette

        pendingPane = newPane
        guard let paneRect = frames()[newPane] else { return }
        overlay.show(inAXRect: paneRect)

        palette.onSelect = { [weak self] item in
            if self?.fill(newPane, with: item) == false { self?.cancelPending() }
        }
        palette.onCancel = { [weak self] in self?.cancelPending() }
        palette.present(anchorRectAX: paneRect, excludingWindowIDs: [])
    }

    /// Zoom the focused pane to fill the whole workspace (other tiled windows
    /// park off-screen), or un-zoom back to the tiled layout. Toggles.
    func toggleFullscreen() {
        guard pendingPane == nil else { return }
        syncFocusFromLiveWindow()
        guard occupants[focusedPane] != nil else { return }
        zoomedPane = (zoomedPane == focusedPane) ? nil : focusedPane
        relayout()
        if let ref = occupants[focusedPane] { focus(ref) }
    }

    /// The whole workspace minus the outer gap — the frame a zoomed pane fills.
    private var zoomFrame: CGRect {
        workspaceRect.insetBy(dx: config.outerGap, dy: config.outerGap)
    }

    // MARK: - Navigator snapshot & focus

    /// A pane (or floating window) row for the workspace navigator.
    struct PaneEntry {
        let title: String
        let pid: pid_t                 // owning app, for the app icon
        let isFocused: Bool
        let isFloating: Bool
        let paneID: PaneID?            // set for tiled panes
        let floatingWindowID: CGWindowID? // set for floating windows
    }

    struct TabEntry {
        let index: Int
        let isActive: Bool
        let panes: [PaneEntry]
    }

    /// A tree view of every tab and its windows, for the navigator.
    func workspaceSnapshot() -> [TabEntry] {
        tabs.enumerated().map { index, tab in
            var entries: [PaneEntry] = []
            for pane in tab.tree.paneIDs {
                guard let ref = tab.occupants[pane] else { continue }
                entries.append(PaneEntry(
                    title: ref.window.title ?? "Window",
                    pid: ref.pid,
                    isFocused: index == activeTabIndex && pane == tab.focusedPane,
                    isFloating: false,
                    paneID: pane, floatingWindowID: nil))
            }
            for floater in tab.floating {
                entries.append(PaneEntry(
                    title: floater.window.title ?? "Floating window",
                    pid: floater.pid,
                    isFocused: false,
                    isFloating: true,
                    paneID: nil, floatingWindowID: floater.window.windowID))
            }
            return TabEntry(index: index, isActive: index == activeTabIndex, panes: entries)
        }
    }

    /// Switch to a tab (used by the navigator).
    func focusTab(_ index: Int) { switchTo(index) }

    /// Switch to `tabIndex` if needed and focus a specific tiled pane.
    func focusPane(tabIndex: Int, pane: PaneID) {
        if tabIndex != activeTabIndex { switchTo(tabIndex) }
        guard let ref = occupants[pane] else { return }
        focusedPane = pane
        focus(ref)
    }

    /// Where a managed window lives: which tab, and whether it's tiled or floating.
    private enum Location { case pane(PaneID), floating }

    /// Find the tab + slot holding `windowID`, scanning every tab (not just the
    /// active one).
    private func locate(_ windowID: CGWindowID) -> (tab: Int, kind: Location)? {
        for (i, tab) in tabs.enumerated() {
            if let pane = tab.occupants.first(where: { $0.value.window.windowID == windowID })?.key {
                return (i, .pane(pane))
            }
            if tab.floating.contains(where: { $0.window.windowID == windowID }) {
                return (i, .floating)
            }
        }
        return nil
    }

    /// The user switched to an app via Cmd-Tab or a third-party switcher. If its
    /// focused window is one we manage in *another* tab, switch to that tab so the
    /// window appears in its place — otherwise macOS un-hides it on top of the
    /// tab the user is currently looking at. No-op if the window is unmanaged or
    /// already in the active tab (that just tracks focus).
    func revealTab(forActivatedApp pid: pid_t) {
        guard pendingPane == nil else { return }
        // Activation notifications are delivered async, and hiding a tab's apps
        // during a switch briefly activates others. Only follow the app that is
        // *actually* frontmost now, so those transient activations don't thrash tabs.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        guard let window = AppTargeter.focusedWindow(ofPID: pid),
              let windowID = window.windowID,
              let location = locate(windowID) else { return }
        if location.tab == activeTabIndex {
            if case .pane(let pane) = location.kind { focusedPane = pane }
            return
        }
        // The app's reported focused window is unreliable during transitions
        // (notably exiting a browser's video fullscreen, where a private window's
        // focus briefly resolves to a *sibling* normal window). If this app
        // already has a window in the current tab, the user is already looking at
        // it here — don't jump to a same-app window in another tab on what may be
        // a spurious activation. Cross-tab follow still works for apps with no
        // window in the current tab (the common Cmd-Tab case).
        if appHasWindowInActiveTab(pid) { return }
        switch location.kind {
        case .pane(let pane): focusPane(tabIndex: location.tab, pane: pane)
        case .floating: focusFloating(tabIndex: location.tab, windowID: windowID)
        }
    }

    /// Whether the app `pid` owns any window (tiled or floating) in the active tab.
    private func appHasWindowInActiveTab(_ pid: pid_t) -> Bool {
        let tab = tabs[activeTabIndex]
        return tab.occupants.values.contains { $0.pid == pid }
            || tab.floating.contains { $0.pid == pid }
    }

    /// Switch to `tabIndex` if needed and raise a specific floating window.
    func focusFloating(tabIndex: Int, windowID: CGWindowID) {
        if tabIndex != activeTabIndex { switchTo(tabIndex) }
        guard let floater = tabs[activeTabIndex].floating.first(where: { $0.window.windowID == windowID }) else { return }
        floater.window.raise()
        NSRunningApplication(processIdentifier: floater.pid)?.activate()
    }

    // MARK: - Floating windows

    /// Toggle the focused window between floating and tiled. A tiled window
    /// leaves the BSP tree and floats (centered); a floating window is re-tiled
    /// into the layout.
    func toggleFloat() {
        guard pendingPane == nil else { return }

        // Unmanaged focused window → attach it into the active tab (tiled).
        if focusState() == .unmanaged, let f = focusedWindowProvider() {
            if let id = f.window.windowID {
                detachWindow(id)  // if it lives in another tab, move it — never duplicate
                knownWindowIDs.insert(id)
            }
            addToLayout(WindowRef(pid: f.pid, window: f.window))
            relayout()
            applyWorkspaceVisibility()
            if let ref = occupants[focusedPane] { focus(ref) }
            gcEmptyTabs()
            return
        }

        if let index = focusedFloatingIndex() {
            // Floating → tiled: pull it back into the BSP layout.
            let floater = tabs[activeTabIndex].floating.remove(at: index)
            addToLayout(WindowRef(pid: floater.pid, window: floater.window))
            relayout()
            applyWorkspaceVisibility()
            if let ref = occupants[focusedPane] { focus(ref) }
            return
        }

        // Tiled → floating: remove from the tree, float it centered.
        syncFocusFromLiveWindow()
        guard let ref = occupants[focusedPane] else { return }
        let pane = focusedPane
        tree.remove(pane)
        occupants[pane] = nil
        if zoomedPane == pane { zoomedPane = nil }
        if occupants[focusedPane] == nil { focusedPane = tree.paneIDs.first ?? PaneID(0) }

        let rect = centeredFloatRect()
        ref.window.setFrame(rect)
        ref.window.raise()
        tabs[activeTabIndex].floating.append(FloatingWindow(pid: ref.pid, window: ref.window, frame: rect))
        relayout()
        applyWorkspaceVisibility()
    }

    /// Move the focused floating window by a step in a direction.
    func moveFloating(_ direction: PaneNavigation.Direction, by step: CGFloat = 40) {
        guard let index = focusedFloatingIndex() else { return }
        var floater = tabs[activeTabIndex].floating[index]
        switch direction {
        case .left: floater.frame.origin.x -= step
        case .right: floater.frame.origin.x += step
        case .up: floater.frame.origin.y -= step
        case .down: floater.frame.origin.y += step
        }
        tabs[activeTabIndex].floating[index] = floater
        floater.window.setPosition(floater.frame.origin)
        floater.window.raise()
    }

    /// In pane mode, h/j/k/l moves the focused *floating* window; otherwise it
    /// moves focus (or, with shift, swaps the tiled window).
    func paneDirection(_ direction: PaneNavigation.Direction, shift: Bool) {
        if focusedFloatingIndex() != nil {
            moveFloating(direction)
        } else {
            moveOrFocus(direction, move: shift)
        }
    }

    /// Index of the floating window that currently has focus, if any.
    private func focusedFloatingIndex() -> Int? {
        guard let focused = focusedWindowProvider(), let windowID = focused.window.windowID else { return nil }
        return tabs[activeTabIndex].floating.firstIndex { $0.window.windowID == windowID }
    }

    /// Add a window to the tiled layout — as the first pane if empty, else by
    /// splitting the focused pane.
    private func addToLayout(_ ref: WindowRef) {
        if occupants.isEmpty {
            occupants[PaneID(0)] = ref
            focusedPane = PaneID(0)
        } else if let newPane = tree.split(focusedPane, orientation: dynamicSplitOrientation()) {
            occupants[newPane] = ref
            focusedPane = newPane
        }
    }

    /// Split along the focused pane's longer axis, so an auto-placed window snaps
    /// into the direction with more room: a wide pane splits side-by-side
    /// (horizontal), a tall pane splits stacked (vertical).
    private func dynamicSplitOrientation() -> SplitOrientation {
        guard let rect = frames()[focusedPane] else { return .horizontal }
        return rect.width >= rect.height ? .horizontal : .vertical
    }

    private func centeredFloatRect() -> CGRect {
        let w = workspaceRect
        let size = CGSize(width: w.width * 0.5, height: w.height * 0.6)
        return CGRect(x: w.midX - size.width / 2, y: w.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Raise the active tab's floating windows and restore them to their frames
    /// (used after a tab becomes active — they were parked off-screen).
    private func restoreFloating() {
        for floater in tabs[activeTabIndex].floating {
            unpark(floater.window, to: floater.frame)
            floater.window.raise()
        }
    }

    /// Re-pick the window occupying the focused pane (e.g. you chose the wrong
    /// one). Opens the palette over that pane; selecting replaces the occupant,
    /// cancelling keeps the current window.
    func changeFocusedPaneWindow() {
        guard pendingPane == nil else { return }
        syncFocusFromLiveWindow()
        let pane = focusedPane
        guard occupants[pane] != nil, let rect = frames()[pane] else { return }
        pendingPane = pane
        overlay.show(inAXRect: rect)
        palette.onSelect = { [weak self] item in
            // On failure keep the existing window (don't remove the pane).
            if self?.fill(pane, with: item) == false {
                self?.pendingPane = nil
                self?.overlay.hide()
                NSSound.beep()
            }
        }
        palette.onCancel = { [weak self] in
            self?.pendingPane = nil
            self?.overlay.hide()
        }
        palette.present(anchorRectAX: rect, excludingWindowIDs: [])
    }

    /// Convenience for modal keys: move the window when `move` is true, else
    /// just move focus.
    func moveOrFocus(_ direction: PaneNavigation.Direction, move: Bool) {
        if move { moveWindow(direction) } else { moveFocus(direction) }
    }

    /// Toggle the active tab between BSP tiling and stacked (monocle) layout,
    /// where all tiled windows fill the workspace and only the focused one shows.
    func toggleStacked() {
        guard pendingPane == nil else { return }
        syncFocusFromLiveWindow()
        tabs[activeTabIndex].stacked.toggle()
        zoomedPane = nil
        relayout()
        if let ref = occupants[focusedPane] { focus(ref) }
    }

    /// Equalize all pane sizes in the focused tab (AeroSpace "balance-sizes").
    func balanceSizes() {
        guard pendingPane == nil else { return }
        var tab = tabs[activeTabIndex]
        tab.tree.balance()
        tabs[activeTabIndex] = tab
        relayout()
    }

    /// Cycle focus to the next/previous window in tree order (AeroSpace DFS focus).
    func focusNextWindow() { cycleFocus(1) }
    func focusPreviousWindow() { cycleFocus(-1) }

    private func cycleFocus(_ delta: Int) {
        guard pendingPane == nil else { return }
        // Every managed window in the active tab, tiled then floating.
        var ids: [CGWindowID] = []
        for pane in tree.paneIDs {
            if let ref = occupants[pane], let id = ref.window.windowID { ids.append(id) }
        }
        for floater in tabs[activeTabIndex].floating {
            if let id = floater.window.windowID { ids.append(id) }
        }
        guard !ids.isEmpty else { return }
        let currentID = focusedWindowProvider()?.window.windowID
        let index = currentID.flatMap { ids.firstIndex(of: $0) } ?? 0
        focusWindow(id: ids[(index + delta + ids.count) % ids.count])
    }

    /// Focus a managed window (tiled or floating) by its CGWindowID.
    private func focusWindow(id: CGWindowID) {
        if let match = occupants.first(where: { $0.value.window.windowID == id }) {
            focusedPane = match.key
            focus(match.value)
        } else if let floater = tabs[activeTabIndex].floating.first(where: { $0.window.windowID == id }) {
            floater.window.raise()
            NSRunningApplication(processIdentifier: floater.pid)?.activate()
        }
    }

    /// Keep only the focused pane's window tiled; untile the rest (they become
    /// unmanaged and get hidden). A non-destructive "close-all-but-current".
    func soloFocusedPane() {
        guard pendingPane == nil else { return }
        syncFocusFromLiveWindow()
        guard let ref = occupants[focusedPane] else { return }
        var tab = tabs[activeTabIndex]
        tab.tree = LayoutTree()
        tab.occupants = [PaneID(0): ref]
        tab.focusedPane = PaneID(0)
        tabs[activeTabIndex] = tab
        zoomedPane = nil
        relayout()
        focus(ref)
        applyWorkspaceVisibility()
    }

    /// Toggle to the previously-active tab (AeroSpace workspace-back-and-forth).
    func toggleLastTab() {
        guard let last = lastTabIndex, tabs.indices.contains(last), last != activeTabIndex else { return }
        switchTo(last)
    }

    /// Grow or shrink the focused pane's width/height and re-snap the affected
    /// windows. Works regardless of which side of its split the pane is on.
    func resizeFocused(axis: SplitOrientation, grow: Bool, by delta: CGFloat = 0.05) {
        guard pendingPane == nil else { return }
        syncFocusFromLiveWindow()
        var tab = tabs[activeTabIndex]
        tab.tree.resize(focusedPane, axis: axis, grow: grow, by: delta)
        tabs[activeTabIndex] = tab
        relayout()
    }

    /// Move focus to the pane adjacent to the current one and activate its
    /// window. The current pane is resolved from the live focused window first,
    /// so navigation is relative to where the user actually is.
    func moveFocus(_ direction: PaneNavigation.Direction) {
        guard pendingPane == nil else { return }
        syncFocusFromLiveWindow()
        guard let target = PaneNavigation.adjacent(to: focusedPane, in: frames(), direction: direction),
              let ref = occupants[target] else { return }
        focusedPane = target
        focus(ref)
    }

    /// Swap the focused pane's window with the pane adjacent in `direction`,
    /// then follow the moved window to its new pane. Repositions both windows.
    func moveWindow(_ direction: PaneNavigation.Direction) {
        guard pendingPane == nil else { return }
        syncFocusFromLiveWindow()
        let source = focusedPane
        guard let target = PaneNavigation.adjacent(to: source, in: frames(), direction: direction),
              occupants[source] != nil else { return }

        let moved = occupants[source]
        occupants[source] = occupants[target]
        occupants[target] = moved
        focusedPane = target // follow the window we just moved
        relayout()
        if let ref = occupants[target] { focus(ref) }
    }

    /// If the live focused window is one we manage, make its pane the active one.
    private func syncFocusFromLiveWindow() {
        if let focused = focusedWindowProvider(),
           let windowID = focused.window.windowID,
           let pane = pane(containing: windowID) {
            focusedPane = pane
        }
    }

    /// Remove a window (by id) from wherever it's tiled/floating across all tabs,
    /// so it can be re-placed. Emptied panes collapse.
    private func detachWindow(_ id: CGWindowID) {
        for i in tabs.indices {
            if let pane = tabs[i].occupants.first(where: { $0.value.window.windowID == id })?.key {
                tabs[i].tree.remove(pane)
                tabs[i].occupants[pane] = nil
                if tabs[i].focusedPane == pane {
                    tabs[i].focusedPane = tabs[i].tree.paneIDs.first ?? PaneID(0)
                }
            }
            tabs[i].floating.removeAll { $0.window.windowID == id }
        }
    }

    /// Remove empty tabs (no tiled or floating windows), except the active one,
    /// so composing tabs by pulling windows around cleans up after itself.
    private func gcEmptyTabs() {
        guard tabs.count > 1 else { return }
        var kept: [Tab] = []
        var newActive = 0
        for (i, tab) in tabs.enumerated() {
            let isEmpty = tab.occupants.isEmpty && tab.floating.isEmpty
            if i == activeTabIndex || !isEmpty {
                if i == activeTabIndex { newActive = kept.count }
                kept.append(tab)
            }
        }
        if kept.count != tabs.count {
            tabs = kept
            activeTabIndex = newActive
            onWorkspaceChange?()
        }
    }

    func occupiedWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        for tab in tabs {
            for ref in tab.occupants.values {
                if let id = ref.window.windowID { ids.insert(id) }
            }
            for floater in tab.floating {
                if let id = floater.window.windowID { ids.insert(id) }
            }
        }
        return ids
    }

    // MARK: - Session persistence

    /// Snapshot the whole workspace (tabs → tree + windows by identity) for
    /// saving to disk.
    func captureSession() -> SavedSession {
        let savedTabs = tabs.map { tab -> SavedTab in
            var occ: [Int: SavedWindow] = [:]
            for (pane, ref) in tab.occupants {
                occ[pane.value] = savedWindow(pid: ref.pid, window: ref.window)
            }
            let floats = tab.floating.map {
                SavedFloating(window: savedWindow(pid: $0.pid, window: $0.window), frame: $0.frame)
            }
            return SavedTab(tree: tab.tree, occupants: occ, floating: floats, stacked: tab.stacked)
        }
        return SavedSession(version: SessionStore.currentVersion, activeTabIndex: activeTabIndex, tabs: savedTabs)
    }

    private func savedWindow(pid: pid_t, window: AXWindow) -> SavedWindow {
        SavedWindow(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "",
                    title: window.title ?? "",
                    windowID: window.windowID)
    }

    /// Rebuild the workspace from a saved session, matching *currently-open*
    /// windows into their saved slots (by window-id, then bundle+title, then
    /// bundle). Panes/tabs with no matching window are dropped. Returns false if
    /// nothing matched (caller falls back to the first-window prompt).
    @discardableResult
    func restoreSession(_ session: SavedSession) -> Bool {
        // Index of currently-open tileable windows.
        var available: [(bundleID: String, title: String, windowID: CGWindowID?, pid: pid_t, window: AXWindow)] = []
        for app in AppTargeter.regularApps() {
            let bundle = app.bundleIdentifier ?? ""
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            for window in AppTargeter.windows(of: appElement) where window.isTileable {
                available.append((bundle, window.title ?? "", window.windowID, app.processIdentifier, window))
            }
        }
        var used = Set<CGWindowID>()
        func isFree(_ id: CGWindowID?) -> Bool { id.map { !used.contains($0) } ?? true }
        func match(_ saved: SavedWindow) -> (pid_t, AXWindow)? {
            if let wid = saved.windowID, let hit = available.first(where: { $0.windowID == wid && isFree(wid) }) {
                return (hit.pid, hit.window)
            }
            if let hit = available.first(where: { $0.bundleID == saved.bundleID && $0.title == saved.title && isFree($0.windowID) }) {
                return (hit.pid, hit.window)
            }
            if let hit = available.first(where: { $0.bundleID == saved.bundleID && isFree($0.windowID) }) {
                return (hit.pid, hit.window)
            }
            return nil
        }

        var newTabs: [Tab] = []
        for savedTab in session.tabs {
            var tab = Tab()
            tab.tree = savedTab.tree
            tab.stacked = savedTab.stacked
            for (paneValue, savedWin) in savedTab.occupants {
                if let (pid, window) = match(savedWin) {
                    tab.occupants[PaneID(paneValue)] = WindowRef(pid: pid, window: window)
                    if let id = window.windowID { used.insert(id) }
                }
            }
            // Collapse panes whose window didn't come back.
            for pane in tab.tree.paneIDs where tab.occupants[pane] == nil {
                tab.tree.remove(pane)
            }
            tab.focusedPane = tab.tree.paneIDs.first { tab.occupants[$0] != nil } ?? (tab.tree.paneIDs.first ?? PaneID(0))
            for savedFloat in savedTab.floating {
                if let (pid, window) = match(savedFloat.window) {
                    tab.floating.append(FloatingWindow(pid: pid, window: window, frame: savedFloat.frame))
                    if let id = window.windowID { used.insert(id) }
                }
            }
            if !tab.occupants.isEmpty || !tab.floating.isEmpty { newTabs.append(tab) }
        }
        guard !newTabs.isEmpty else { return false }

        tabs = newTabs
        activeTabIndex = min(max(0, session.activeTabIndex), tabs.count - 1)
        knownWindowIDs = allStandardWindowIDs() // don't re-auto-tile restored windows
        relayout()
        if let ref = occupants[focusedPane] { focus(ref) }
        applyWorkspaceVisibility()
        onWorkspaceChange?()
        return true
    }

    /// If the active tab has no windows, pop the palette to pick the one that
    /// fills it — used on startup and to begin a fresh session. No-op if the tab
    /// already has content or a pick is already in progress.
    func promptFirstWindow() {
        guard pendingPane == nil,
              occupants.isEmpty,
              tabs[activeTabIndex].floating.isEmpty else { return }
        let firstPane = PaneID(0)
        pendingPane = firstPane
        guard let rect = frames()[firstPane] else { pendingPane = nil; return }
        overlay.show(inAXRect: rect)
        palette.onSelect = { [weak self] item in
            if self?.fill(firstPane, with: item) == false {
                self?.pendingPane = nil
                self?.overlay.hide()
            }
        }
        palette.onCancel = { [weak self] in
            self?.pendingPane = nil
            self?.overlay.hide()
        }
        palette.present(anchorRectAX: rect, excludingWindowIDs: [])
    }

    /// Every tileable, non-minimized, currently-open window (excluding Tessera),
    /// ordered front-to-back by global z-order (frontmost first). Uses
    /// `CGWindowList` for the ordering + definitive window set, then resolves each
    /// to its AX element.
    private func allTileableWindows() -> [WindowRef] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var result: [WindowRef] = []
        var seen = Set<CGWindowID>()
        var axCache: [pid_t: [AXWindow]] = [:]

        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID, !seen.contains(wid) else { continue }
            let windows = axCache[pid] ?? {
                let w = AppTargeter.windows(of: AXUIElementCreateApplication(pid))
                axCache[pid] = w
                return w
            }()
            guard let ax = windows.first(where: { $0.windowID == wid }),
                  ax.isTileable, !ax.isMinimized else { continue }
            seen.insert(wid)
            result.append(WindowRef(pid: pid, window: ax))
        }
        return result
    }

    /// Organize every open window into tabs — **one tab per app**, with a
    /// multi-window app's windows **stacked** (monocle) so `n/p` cycles them. The
    /// frontmost app's tab is active. This is the startup default (no saved
    /// session) and a re-runnable command. One-app-per-tab makes hiding exact:
    /// inactive apps are cleanly `kAXHidden` (no per-window parking).
    func adoptAllWindowsByApp() {
        guard pendingPane == nil else { return }
        let refs = allTileableWindows()
        guard !refs.isEmpty else { promptFirstWindow(); return }

        // Group by app, preserving frontmost-first order.
        var order: [pid_t] = []
        var byApp: [pid_t: [WindowRef]] = [:]
        for ref in refs {
            if byApp[ref.pid] == nil { order.append(ref.pid) }
            byApp[ref.pid, default: []].append(ref)
        }

        var built: [Tab] = []
        for pid in order {
            let windows = byApp[pid]!
            var tab = Tab()
            tab.occupants[PaneID(0)] = windows[0]
            tab.focusedPane = PaneID(0)
            for ref in windows.dropFirst() {
                if let newPane = tab.tree.split(tab.focusedPane, orientation: .horizontal) {
                    tab.occupants[newPane] = ref
                    tab.focusedPane = newPane
                }
            }
            tab.focusedPane = PaneID(0)
            tab.stacked = windows.count > 1   // stack multi-window apps
            built.append(tab)
        }

        tabs = built
        activeTabIndex = 0
        zoomedPane = nil
        lastTabIndex = nil
        knownWindowIDs = Set(refs.compactMap { $0.window.windowID })
        applyWorkspaceVisibility()
        relayout()
        if let ref = occupants[focusedPane] { focus(ref) }
        onWorkspaceChange?()
    }

    /// Tear down the tiling session: bring every tab's windows back on-screen
    /// (some are parked off-screen while their tab is inactive) and collapse to a
    /// single empty tab.
    func reset() {
        for tab in tabs {
            let frames = tab.tree.frames(in: workspaceRect, config: config)
            for (pane, ref) in tab.occupants {
                if let rect = frames[pane] { unpark(ref.window, to: rect) }
            }
            for floater in tab.floating { unpark(floater.window, to: floater.frame) }
        }
        tabs = [Tab()]
        activeTabIndex = 0
        pendingPane = nil
        newTabReturnIndex = nil
        zoomedPane = nil
        overlay.hide()
        restoreParkedExtras()
        unhideAllApps() // no tiles left → reveal everything
        onWorkspaceChange?()
    }

    // MARK: - Tabs

    var tabSummary: (index: Int, count: Int) { (activeTabIndex, tabs.count) }

    /// Number of tiled windows in the active tab (0 or 1 means nothing to resize).
    var activePaneCount: Int { occupants.count }

    /// Number of floating windows in the active tab.
    var activeFloatingCount: Int { tabs[activeTabIndex].floating.count }

    /// How the live focused window relates to the active tab — drives which
    /// context keys the HUD offers.
    enum FocusState { case tiled, floating, unmanaged, empty }

    func focusState() -> FocusState {
        guard let f = focusedWindowProvider(), let id = f.window.windowID else { return .empty }
        if occupants.values.contains(where: { $0.window.windowID == id }) { return .tiled }
        if tabs[activeTabIndex].floating.contains(where: { $0.window.windowID == id }) { return .floating }
        return .unmanaged
    }

    /// Open a fresh tab: hide the current tab's apps, then pop the palette to
    /// pick the window that fills the new tab. Cancelling returns to the tab you
    /// came from (so you never get stranded on a blank workspace).
    func newTab() {
        guard pendingPane == nil else { return }
        let previousIndex = activeTabIndex
        recordFloatingFrames(at: activeTabIndex)
        hideApps(of: activeTabIndex) // blank new tab → hide the previous tab's apps
        zoomedPane = nil
        tabs.append(Tab())
        activeTabIndex = tabs.count - 1
        onWorkspaceChange?()

        let firstPane = PaneID(0)
        pendingPane = firstPane
        newTabReturnIndex = previousIndex
        guard let paneRect = frames()[firstPane] else { return }
        overlay.show(inAXRect: paneRect)
        palette.onSelect = { [weak self] item in
            if self?.fill(firstPane, with: item) == false { self?.cancelNewTab() }
        }
        palette.onCancel = { [weak self] in self?.cancelNewTab() }
        palette.present(anchorRectAX: paneRect, excludingWindowIDs: [])
    }

    /// Roll back a new tab whose window picker was dismissed: drop the empty tab
    /// and return to (and reveal) the previous one.
    private func cancelNewTab() {
        overlay.hide()
        pendingPane = nil
        guard let returnIndex = newTabReturnIndex, tabs.count > 1 else {
            newTabReturnIndex = nil
            return
        }
        newTabReturnIndex = nil
        tabs.removeLast()
        activeTabIndex = min(returnIndex, tabs.count - 1)
        relayout() // brings the returned tab's windows back on-screen
        if let ref = occupants[focusedPane] { focus(ref) }
        applyWorkspaceVisibility()
        onWorkspaceChange?()
    }

    func nextTab() { switchTo((activeTabIndex + 1) % tabs.count) }
    func previousTab() { switchTo((activeTabIndex - 1 + tabs.count) % tabs.count) }

    func moveFocusedToNextTab() { moveFocusedToTab((activeTabIndex + 1) % tabs.count) }
    func moveFocusedToPreviousTab() { moveFocusedToTab((activeTabIndex - 1 + tabs.count) % tabs.count) }

    /// Move the focused window to 1-based tab `n`. Existing tab → move/split;
    /// beyond the current count → create a new tab and move there.
    func moveFocusedToTabNumber(_ n: Int) {
        guard pendingPane == nil, n >= 1 else { NSSound.beep(); return }
        let idx = n - 1
        if idx == activeTabIndex { return }            // already on that tab
        if tabs.indices.contains(idx) {
            moveFocusedToTab(idx)                       // existing tab (splits if occupied)
        } else {
            moveFocusedToNewTab()                        // next available → create + move
        }
    }

    /// Append a fresh tab and move the focused window into it. No-op (no empty
    /// tab left behind) if there's nothing focused to move.
    private func moveFocusedToNewTab() {
        syncFocusFromLiveWindow()
        guard occupants[focusedPane] != nil || focusedFloatingIndex() != nil else { NSSound.beep(); return }
        tabs.append(Tab())
        moveFocusedToTab(tabs.count - 1)
    }

    /// Move the focused window (tiled or floating) out of the current tab and
    /// into `targetIndex`. The current tab reflows; we stay put so the window
    /// "sends" to the other tab.
    func moveFocusedToTab(_ targetIndex: Int) {
        guard pendingPane == nil, targetIndex != activeTabIndex, tabs.indices.contains(targetIndex) else { return }
        syncFocusFromLiveWindow()

        // Floating window → keep it floating in the target tab.
        if let floatIndex = focusedFloatingIndex() {
            var floater = tabs[activeTabIndex].floating.remove(at: floatIndex)
            if let current = floater.window.frame { floater.frame = current }
            tabs[targetIndex].floating.append(floater)
            park(floater.window)
            finishMove(to: targetIndex)
            return
        }

        // Tiled window → remove from this tab's tree, add to the target's.
        guard let ref = occupants[focusedPane] else { return }
        let pane = focusedPane
        tree.remove(pane)
        occupants[pane] = nil
        if zoomedPane == pane { zoomedPane = nil }
        if occupants[focusedPane] == nil { focusedPane = tree.paneIDs.first ?? PaneID(0) }

        addToTab(targetIndex, ref: ref)
        park(ref.window) // target tab is inactive → stash off-screen
        finishMove(to: targetIndex)
    }

    /// After moving a window out: if the current tab is now empty, follow the
    /// window to the target tab (and GC the emptied source); otherwise reflow
    /// and stay put.
    private func finishMove(to targetIndex: Int) {
        if occupants.isEmpty && tabs[activeTabIndex].floating.isEmpty && tabs.count > 1 {
            switchTo(targetIndex)
            gcEmptyTabs() // drop the now-empty source tab
        } else {
            relayout()
            applyWorkspaceVisibility()
            onWorkspaceChange?()
        }
    }

    /// Add a window to another tab's tiled layout (first pane if empty, else a
    /// split of that tab's focused pane).
    private func addToTab(_ index: Int, ref: WindowRef) {
        if tabs[index].occupants.isEmpty {
            tabs[index].occupants[PaneID(0)] = ref
            tabs[index].focusedPane = PaneID(0)
        } else {
            let target = tabs[index].focusedPane
            let targetFrames = tabs[index].tree.frames(in: workspaceRect, config: config)
            let orientation: SplitOrientation = (targetFrames[target]?.width ?? 1) >= (targetFrames[target]?.height ?? 0) ? .horizontal : .vertical
            if let newPane = tabs[index].tree.split(target, orientation: orientation) {
                tabs[index].occupants[newPane] = ref
                tabs[index].focusedPane = newPane
            }
        }
    }

    /// Switch to `index`: stash the current tab's windows off-screen, reveal the
    /// target tab's (relayout snaps them back), and focus its active pane.
    func switchTo(_ index: Int) {
        guard pendingPane == nil, index != activeTabIndex, tabs.indices.contains(index) else { return }
        recordFloatingFrames(at: activeTabIndex)
        lastTabIndex = activeTabIndex // remember for back-and-forth
        zoomedPane = nil // zoom is per-tab; don't carry it across
        activeTabIndex = index
        // Hide the outgoing tab's apps (kAXHidden, no animation) and reveal the
        // incoming tab's, before positioning them.
        applyWorkspaceVisibility()
        relayout()        // position incoming tiled windows
        restoreFloating() // position incoming floating windows
        if let ref = occupants[focusedPane] { focus(ref) }
        onWorkspaceChange?()
    }

    /// A parking spot one full display-height below the screen. Hiding a tab
    /// moves its windows here — per-window, so it correctly hides one window of
    /// an app while another window of the *same* app stays visible in another
    /// tab (which `kAXHiddenAttribute`, being app-level, cannot do).
    private var offscreenPoint: CGPoint {
        let bounds = ScreenLayout.mainDisplayBounds
        return CGPoint(x: bounds.minX, y: bounds.maxY + bounds.height)
    }

    /// Hide a window by moving it off-screen (the AeroSpace approach — no
    /// minimize animation). Whole apps that have no window in the active tab are
    /// hidden app-level via `kAXHidden` instead (clean, no leak); this per-window
    /// park only handles the same-app-across-tabs case.
    private func park(_ window: AXWindow) {
        window.setPosition(offscreenPoint)
    }

    /// Bring a parked window back to its frame.
    private func unpark(_ window: AXWindow, to frame: CGRect) {
        if window.isMinimized { window.setMinimized(false) } // defensive
        window.setFrame(frame)
    }

    /// Park a tab's windows (tiled and floating) off-screen. Captures each
    /// floating window's current frame first, so a manual move survives a
    /// round-trip through another tab.
    /// Capture the outgoing tab's floating-window frames (so a manual move
    /// survives a round-trip) without moving anything — hiding is done by
    /// `applyWorkspaceVisibility` (app-level `kAXHidden`, no animation).
    private func recordFloatingFrames(at index: Int) {
        for i in tabs[index].floating.indices {
            if let current = tabs[index].floating[i].window.frame {
                tabs[index].floating[i].frame = current
            }
        }
    }

    /// Hide an entire tab's apps via `kAXHidden` (clean, no animation). Used when
    /// opening a blank new tab, where there's no incoming layout to drive
    /// `applyWorkspaceVisibility`.
    private func hideApps(of index: Int) {
        let pids = Set(tabs[index].occupants.values.map(\.pid))
            .union(tabs[index].floating.map(\.pid))
        for pid in pids { AppTargeter.setHidden(true, pid: pid) }
    }

    // MARK: - Palette outcomes

    /// Place the resolved window into `pane`. Returns false if no window could be
    /// resolved (e.g. every window of the picked app is already tiled) — the
    /// caller decides how to clean up (roll back a split vs. keep an existing
    /// pane).
    @discardableResult
    private func fill(_ pane: PaneID, with item: PaletteItem) -> Bool {
        guard let ref = resolve(item) else { return false }
        overlay.hide()
        pendingPane = nil
        newTabReturnIndex = nil
        // If this window is tiled/floating elsewhere, move it here (detach first),
        // then clean up any tab left empty by the move.
        if let id = ref.window.windowID { detachWindow(id) }
        occupants[pane] = ref
        focusedPane = pane
        relayout()
        focus(ref)
        gcEmptyTabs()
        applyWorkspaceVisibility()
        return true
    }

    /// Bring the tiled set forward as a group, then activate the focused pane's
    /// app. macOS z-orders per app, so among *different* apps only the focused
    /// one's windows end up topmost — harmless while panes don't overlap, and
    /// the group-raise keeps all managed windows above unmanaged clutter.
    private func focus(_ ref: WindowRef) {
        for occupant in occupants.values where occupant.pid != ref.pid {
            occupant.window.raise()
        }
        ref.window.raise()
        NSRunningApplication(processIdentifier: ref.pid)?.activate()
    }

    /// Undo a split whose palette was dismissed without a pick: remove the empty
    /// pane, collapse its sibling back to full size.
    private func cancelPending() {
        overlay.hide()
        guard let pane = pendingPane else { return }
        pendingPane = nil
        tree.remove(pane)
        occupants[pane] = nil
        relayout()
    }

    // MARK: - Internals

    /// True when a window is (or is acting) full-screen and must be left alone by
    /// layout enforcement/float-out. Covers both native fullscreen (its own
    /// Space, `AXFullScreen`) and browser **HTML5 video fullscreen**, which
    /// resizes the window to the whole display *without* setting `AXFullScreen`.
    /// A normally-tiled window never covers the full display — even a lone pane
    /// is inset below the menu bar — so this won't misfire on tiled windows.
    private func isFullscreenLike(_ window: AXWindow, frame: CGRect?) -> Bool {
        if window.isFullscreen { return true }
        guard let frame else { return false }
        let d = ScreenLayout.mainDisplayBounds
        return frame.width >= d.width * 0.98 && frame.height >= d.height * 0.98
    }

    private func frames() -> [PaneID: CGRect] {
        tree.frames(in: workspaceRect, config: config)
    }

    /// The pane whose window currently has the given CGWindowID, if any.
    private func pane(containing windowID: CGWindowID) -> PaneID? {
        occupants.first { $0.value.window.windowID == windowID }?.key
    }

    /// Snap every occupied pane's window to its computed frame — or, when a pane
    /// is zoomed, fill the workspace with it and park the rest off-screen.
    private func relayout() {
        if tabs[activeTabIndex].stacked {
            for (_, ref) in occupants { ref.window.setFrame(zoomFrame) }
            if let ref = occupants[focusedPane] { ref.window.raise() }
            for floater in tabs[activeTabIndex].floating { floater.window.raise() }
            return
        }
        if let zoomed = zoomedPane, occupants[zoomed] != nil {
            for (pane, ref) in occupants {
                if pane == zoomed { unpark(ref.window, to: zoomFrame) }
                else { park(ref.window) }
            }
            return
        }
        let frames = self.frames()
        for (pane, ref) in occupants {
            guard let rect = frames[pane] else { continue }
            unpark(ref.window, to: rect)
        }
        // Keep floating windows above the tiled set (position left untouched —
        // they move freely).
        for floater in tabs[activeTabIndex].floating {
            floater.window.raise()
        }
    }

    /// Turn a palette selection into a concrete, tracked window — never one
    /// that's already tiled/floating in any tab (so the same window can't land
    /// in two panes). Launches the app if the item is an application.
    private func resolve(_ item: PaletteItem) -> WindowRef? {
        let occupied = occupiedWindowIDs()
        switch item.kind {
        case .window(let windowID):
            // A window already tiled elsewhere is allowed — fill() detaches it
            // from its old spot and moves it here.
            guard let pid = item.pid,
                  let window = AppTargeter.window(pid: pid, windowID: windowID) else { return nil }
            return WindowRef(pid: pid, window: window)
        case .application:
            // Prefer an un-tiled window of the app; if all are tiled, move its
            // first window here.
            guard let bundleID = item.bundleID,
                  let appElement = try? AppTargeter.applicationElement(bundleID: bundleID, launchIfNeeded: true),
                  let pid = AppTargeter.runningApp(bundleID: bundleID)?.processIdentifier else { return nil }
            let windows = AppTargeter.windows(of: appElement)
            let free = windows.first { window in
                guard let id = window.windowID else { return false }
                return !occupied.contains(id)
            }
            guard let window = free ?? windows.first else { return nil }
            return WindowRef(pid: pid, window: window)
        }
    }
}

private extension CGRect {
    /// True if every edge is within `tolerance` points of `other` — used to tell
    /// a genuine external drift from the sub-pixel noise of our own placement.
    func approximatelyEqual(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
