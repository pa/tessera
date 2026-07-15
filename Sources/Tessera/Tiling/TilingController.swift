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

    /// A little breathing room between panes and around the workspace so tiled
    /// windows don't butt right up against each other or the screen edge.
    private let config = LayoutConfig(outerGap: 8, innerGap: 8)

    private var workspaceRect: CGRect { ScreenGeometry.mainUsableBounds }

    /// Periodically re-snaps drifted windows and drops closed ones.
    private var enforcementTimer: Timer?

    /// When true, new standard windows are auto-added to the active tab.
    private(set) var autoTileEnabled = false
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

    /// Start the timer that drops closed windows and re-snaps drifted ones.
    func startEnforcing() {
        enforcementTimer?.invalidate()
        enforcementTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintainLayout() }
        }
    }

    private func maintainLayout() {
        guard pendingPane == nil else { return } // don't disturb a split-in-progress
        removeClosedWindows()
        if autoTileEnabled { autoTileNewWindows() }
        floatOversizedWindows()
        enforceLayout()
    }

    /// A window that refuses to shrink to its pane (min-size apps) spills over its
    /// neighbors. Pop such windows out to floating so the pane collapses and the
    /// remaining tiles reclaim the space.
    private func floatOversizedWindows() {
        guard !tabs[activeTabIndex].stacked, zoomedPane == nil else { return }
        let frames = self.frames()
        let oversized = occupants.compactMap { pane, ref -> (PaneID, WindowRef, CGRect)? in
            guard let rect = frames[pane], let actual = ref.window.frame else { return nil }
            let overflows = actual.width > rect.width + 24 || actual.height > rect.height + 24
            return overflows ? (pane, ref, actual) : nil
        }
        guard !oversized.isEmpty else { return }

        for (pane, ref, actual) in oversized {
            tree.remove(pane)
            occupants[pane] = nil
            if focusedPane == pane { focusedPane = tree.paneIDs.first ?? PaneID(0) }
            tabs[activeTabIndex].floating.append(FloatingWindow(pid: ref.pid, window: ref.window, frame: actual))
        }
        relayout()
        applyWorkspaceVisibility()
    }

    /// Turn window auto-tiling on/off. Enabling seeds the "known" set with every
    /// current standard window, so only windows opened *after* this get grabbed.
    func setAutoTile(_ enabled: Bool) {
        autoTileEnabled = enabled
        if enabled { knownWindowIDs = allStandardWindowIDs() }
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
    private func autoTileNewWindows() {
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

    private func removeClosedWindows() {
        let deadPanes = occupants.compactMap { pane, ref in windowIsDead(ref) ? pane : nil }
        let hadDeadFloating = tabs[activeTabIndex].floating.contains { windowIsDead(WindowRef(pid: $0.pid, window: $0.window)) }
        guard !deadPanes.isEmpty || hadDeadFloating else { return }

        for pane in deadPanes {
            tree.remove(pane)
            occupants[pane] = nil
            if zoomedPane == pane { zoomedPane = nil }
        }
        tabs[activeTabIndex].floating.removeAll { windowIsDead(WindowRef(pid: $0.pid, window: $0.window)) }
        if occupants[focusedPane] == nil {
            focusedPane = tree.paneIDs.first ?? PaneID(0)
        }
        relayout()
        applyWorkspaceVisibility()
    }

    /// Re-snap any active-tab window that has drifted from its pane frame (the
    /// user resized/moved it outside Tessera). Windows already at their frame are
    /// left alone, so this never fights our own layout changes.
    private func enforceLayout() {
        // Stacked windows all target the same full-screen rect; re-snapping every
        // tick fights apps that clamp their size (flicker). Positioning happens
        // on toggle/cycle instead.
        if tabs[activeTabIndex].stacked { return }
        if let zoomed = zoomedPane, let ref = occupants[zoomed] {
            if let current = ref.window.frame, !current.approximatelyEqual(to: zoomFrame, tolerance: 8) {
                ref.window.setFrame(zoomFrame)
            }
            return
        }
        let frames = self.frames()
        for (pane, ref) in occupants {
            guard let expected = frames[pane], let current = ref.window.frame else { continue }
            if !current.approximatelyEqual(to: expected, tolerance: 8) {
                ref.window.setFrame(expected)
            }
        }
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
        palette.present(anchorRectAX: paneRect, excludingWindowIDs: occupiedWindowIDs())
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
        let isFocused: Bool
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
                    isFocused: index == activeTabIndex && pane == tab.focusedPane,
                    paneID: pane, floatingWindowID: nil))
            }
            for floater in tab.floating {
                entries.append(PaneEntry(
                    title: floater.window.title ?? "Floating window",
                    isFocused: false,
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
        } else if let newPane = tree.split(focusedPane, orientation: .horizontal) {
            occupants[newPane] = ref
            focusedPane = newPane
        }
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
        palette.present(anchorRectAX: rect, excludingWindowIDs: occupiedWindowIDs())
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

    /// CGWindowIDs already occupying a pane in any tab — the palette excludes
    /// these so a window can't be placed into two panes.
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
        palette.present(anchorRectAX: rect, excludingWindowIDs: occupiedWindowIDs())
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
        palette.present(anchorRectAX: paneRect, excludingWindowIDs: occupiedWindowIDs())
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
            relayout()
            applyWorkspaceVisibility()
            onWorkspaceChange?()
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
        relayout()
        park(ref.window) // target tab is inactive → stash off-screen
        applyWorkspaceVisibility()
        onWorkspaceChange?()
    }

    /// Add a window to another tab's tiled layout (first pane if empty, else a
    /// split of that tab's focused pane).
    private func addToTab(_ index: Int, ref: WindowRef) {
        if tabs[index].occupants.isEmpty {
            tabs[index].occupants[PaneID(0)] = ref
            tabs[index].focusedPane = PaneID(0)
        } else {
            let target = tabs[index].focusedPane
            if let newPane = tabs[index].tree.split(target, orientation: .horizontal) {
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
        occupants[pane] = ref
        focusedPane = pane
        relayout()
        focus(ref)
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
            // Already-tiled windows are filtered from the palette, but guard here
            // too in case the list was stale.
            guard let pid = item.pid, !occupied.contains(windowID),
                  let window = AppTargeter.window(pid: pid, windowID: windowID) else { return nil }
            return WindowRef(pid: pid, window: window)
        case .application:
            // Pick the app's first window that isn't already occupied — picking
            // the app shouldn't re-home a window that's tiled elsewhere.
            guard let bundleID = item.bundleID,
                  let appElement = try? AppTargeter.applicationElement(bundleID: bundleID, launchIfNeeded: true),
                  let pid = AppTargeter.runningApp(bundleID: bundleID)?.processIdentifier else { return nil }
            let free = AppTargeter.windows(of: appElement).first { window in
                guard let id = window.windowID else { return false }
                return !occupied.contains(id)
            }
            guard let window = free else { return nil } // no un-tiled window available
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
