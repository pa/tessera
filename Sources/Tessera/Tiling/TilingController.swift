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

    /// A virtual tab: an independent BSP workspace. Switching tabs hides one
    /// tab's apps and unhides the next's (`kAXHiddenAttribute`).
    private struct Tab {
        var tree = LayoutTree()
        var occupants: [PaneID: WindowRef] = [:]
        var focusedPane = PaneID(0)
    }

    private var tabs: [Tab] = [Tab()]
    private var activeTabIndex = 0
    private var pendingPane: PaneID?

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

    init(palette: CommandPaletteController,
         focusedWindowProvider: @escaping () -> (pid: pid_t, window: AXWindow)?) {
        self.palette = palette
        self.focusedWindowProvider = focusedWindowProvider
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

        pendingPane = newPane
        guard let paneRect = frames()[newPane] else { return }
        overlay.show(inAXRect: paneRect)

        palette.onSelect = { [weak self] item in self?.fill(newPane, with: item) }
        palette.onCancel = { [weak self] in self?.cancelPending() }
        palette.present(anchorRectAX: paneRect)
    }

    /// Tear down the tiling session: unhide every managed app across all tabs
    /// and collapse back to a single empty tab. Windows stay where they are.
    func reset() {
        for tab in tabs {
            for pid in pids(of: tab) { AppTargeter.setHidden(false, pid: pid) }
        }
        tabs = [Tab()]
        activeTabIndex = 0
        pendingPane = nil
        overlay.hide()
    }

    // MARK: - Tabs

    var tabSummary: (index: Int, count: Int) { (activeTabIndex, tabs.count) }

    /// Open a fresh, empty tab: hide the current tab's apps and switch to the
    /// new one. Splitting in the new tab adopts whatever window is frontmost.
    func newTab() {
        guard pendingPane == nil else { return }
        hide(tabs[activeTabIndex])
        tabs.append(Tab())
        activeTabIndex = tabs.count - 1
        overlay.hide()
    }

    func nextTab() { switchTo((activeTabIndex + 1) % tabs.count) }
    func previousTab() { switchTo((activeTabIndex - 1 + tabs.count) % tabs.count) }

    /// Switch to `index`: stash the current tab's apps, reveal the target tab's,
    /// re-snap its layout, and focus its active pane.
    func switchTo(_ index: Int) {
        guard pendingPane == nil, index != activeTabIndex, tabs.indices.contains(index) else { return }
        hide(tabs[activeTabIndex])
        activeTabIndex = index
        show(tabs[activeTabIndex])
        relayout()
        if let ref = occupants[focusedPane] { focus(ref) }
    }

    private func pids(of tab: Tab) -> Set<pid_t> {
        Set(tab.occupants.values.map(\.pid))
    }

    private func hide(_ tab: Tab) {
        for pid in pids(of: tab) { AppTargeter.setHidden(true, pid: pid) }
    }

    private func show(_ tab: Tab) {
        for pid in pids(of: tab) { AppTargeter.setHidden(false, pid: pid) }
    }

    // MARK: - Palette outcomes

    private func fill(_ pane: PaneID, with item: PaletteItem) {
        overlay.hide()
        pendingPane = nil

        guard let ref = resolve(item) else {
            cancelPending() // couldn't resolve a window — undo the split
            return
        }
        occupants[pane] = ref
        focusedPane = pane
        relayout()
        focus(ref)
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

    /// Snap every occupied pane's window to its computed frame.
    private func relayout() {
        let frames = self.frames()
        for (pane, ref) in occupants {
            guard let rect = frames[pane] else { continue }
            ref.window.setFrame(rect)
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
