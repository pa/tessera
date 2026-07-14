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
    private struct Tab {
        var tree = LayoutTree()
        var occupants: [PaneID: WindowRef] = [:]
        var focusedPane = PaneID(0)
        var floating: [FloatingWindow] = []
    }

    private var tabs: [Tab] = [Tab()]
    private var activeTabIndex = 0
    private var pendingPane: PaneID?
    /// Where to return if the new-tab window picker is cancelled.
    private var newTabReturnIndex: Int?
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

    /// A little breathing room between panes and around the workspace so tiled
    /// windows don't butt right up against each other or the screen edge.
    private let config = LayoutConfig(outerGap: 8, innerGap: 8)

    private var workspaceRect: CGRect { ScreenGeometry.mainUsableBounds }

    /// Periodically re-snaps drifted windows and drops closed ones.
    private var enforcementTimer: Timer?

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
            window.setPosition(offscreenPoint)
        }
    }

    private func restoreParkedExtras() {
        for (_, parked) in parkedExtras where parked.window.isAlive {
            parked.window.setFrame(parked.frame)
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
        enforceLayout()
    }

    /// Drop panes whose window was closed; the BSP tree collapses so the
    /// surviving neighbor expands to fill the freed space.
    private func removeClosedWindows() {
        let deadPanes = occupants.compactMap { pane, ref in ref.window.isAlive ? nil : pane }
        let hadDeadFloating = tabs[activeTabIndex].floating.contains { !$0.window.isAlive }
        guard !deadPanes.isEmpty || hadDeadFloating else { return }

        for pane in deadPanes {
            tree.remove(pane)
            occupants[pane] = nil
            if zoomedPane == pane { zoomedPane = nil }
        }
        tabs[activeTabIndex].floating.removeAll { !$0.window.isAlive }
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
                if let rect = frames[pane] { ref.window.setFrame(rect) }
            }
            for floater in tab.floating { floater.window.setFrame(floater.frame) }
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

        palette.onSelect = { [weak self] item in self?.fill(newPane, with: item) }
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
            floater.window.setFrame(floater.frame)
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
        palette.onSelect = { [weak self] item in self?.fill(pane, with: item) }
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
        }
        return ids
    }

    /// Tear down the tiling session: bring every tab's windows back on-screen
    /// (some are parked off-screen while their tab is inactive) and collapse to a
    /// single empty tab.
    func reset() {
        for tab in tabs {
            let frames = tab.tree.frames(in: workspaceRect, config: config)
            for (pane, ref) in tab.occupants {
                if let rect = frames[pane] { ref.window.setFrame(rect) }
            }
            for floater in tab.floating { floater.window.setFrame(floater.frame) }
        }
        tabs = [Tab()]
        activeTabIndex = 0
        pendingPane = nil
        newTabReturnIndex = nil
        zoomedPane = nil
        overlay.hide()
        restoreParkedExtras()
        unhideAllApps() // no tiles left → reveal everything
    }

    // MARK: - Tabs

    var tabSummary: (index: Int, count: Int) { (activeTabIndex, tabs.count) }

    /// Open a fresh tab: hide the current tab's apps, then pop the palette to
    /// pick the window that fills the new tab. Cancelling returns to the tab you
    /// came from (so you never get stranded on a blank workspace).
    func newTab() {
        guard pendingPane == nil else { return }
        let previousIndex = activeTabIndex
        hideTab(at: activeTabIndex)
        zoomedPane = nil
        tabs.append(Tab())
        activeTabIndex = tabs.count - 1

        let firstPane = PaneID(0)
        pendingPane = firstPane
        newTabReturnIndex = previousIndex
        guard let paneRect = frames()[firstPane] else { return }
        overlay.show(inAXRect: paneRect)
        palette.onSelect = { [weak self] item in self?.fill(firstPane, with: item) }
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
    }

    func nextTab() { switchTo((activeTabIndex + 1) % tabs.count) }
    func previousTab() { switchTo((activeTabIndex - 1 + tabs.count) % tabs.count) }

    /// Switch to `index`: stash the current tab's windows off-screen, reveal the
    /// target tab's (relayout snaps them back), and focus its active pane.
    func switchTo(_ index: Int) {
        guard pendingPane == nil, index != activeTabIndex, tabs.indices.contains(index) else { return }
        hideTab(at: activeTabIndex)
        zoomedPane = nil // zoom is per-tab; don't carry it across
        activeTabIndex = index
        relayout() // moves the incoming tab's windows from off-screen back to their panes
        restoreFloating()
        if let ref = occupants[focusedPane] { focus(ref) }
        applyWorkspaceVisibility()
    }

    /// A parking spot one full display-height below the screen. Hiding a tab
    /// moves its windows here — per-window, so it correctly hides one window of
    /// an app while another window of the *same* app stays visible in another
    /// tab (which `kAXHiddenAttribute`, being app-level, cannot do).
    private var offscreenPoint: CGPoint {
        let bounds = ScreenLayout.mainDisplayBounds
        return CGPoint(x: bounds.minX, y: bounds.maxY + bounds.height)
    }

    /// Park a tab's windows (tiled and floating) off-screen. Captures each
    /// floating window's current frame first, so a manual move survives a
    /// round-trip through another tab.
    private func hideTab(at index: Int) {
        for ref in tabs[index].occupants.values {
            ref.window.setPosition(offscreenPoint)
        }
        for i in tabs[index].floating.indices {
            if let current = tabs[index].floating[i].window.frame {
                tabs[index].floating[i].frame = current
            }
            tabs[index].floating[i].window.setPosition(offscreenPoint)
        }
    }

    // MARK: - Palette outcomes

    private func fill(_ pane: PaneID, with item: PaletteItem) {
        overlay.hide()
        pendingPane = nil
        newTabReturnIndex = nil

        guard let ref = resolve(item) else {
            cancelPending() // couldn't resolve a window — undo the split
            return
        }
        occupants[pane] = ref
        focusedPane = pane
        relayout()
        focus(ref)
        applyWorkspaceVisibility()
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
        if let zoomed = zoomedPane, occupants[zoomed] != nil {
            for (pane, ref) in occupants {
                if pane == zoomed { ref.window.setFrame(zoomFrame) }
                else { ref.window.setPosition(offscreenPoint) }
            }
            return
        }
        let frames = self.frames()
        for (pane, ref) in occupants {
            guard let rect = frames[pane] else { continue }
            ref.window.setFrame(rect)
        }
        // Keep floating windows above the tiled set (position left untouched —
        // they move freely).
        for floater in tabs[activeTabIndex].floating {
            floater.window.raise()
        }
    }

    /// Turn a palette selection into a concrete, tracked window — launching the
    /// app first if the item is an application rather than an open window.
    private func resolve(_ item: PaletteItem) -> WindowRef? {
        switch item.kind {
        case .window(let windowID):
            guard let pid = item.pid,
                  let window = AppTargeter.window(pid: pid, windowID: windowID) else { return nil }
            return WindowRef(pid: pid, window: window)
        case .application:
            guard let bundleID = item.bundleID,
                  let window = try? AppTargeter.mainWindow(bundleID: bundleID, launchIfNeeded: true),
                  let pid = AppTargeter.runningApp(bundleID: bundleID)?.processIdentifier else { return nil }
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
