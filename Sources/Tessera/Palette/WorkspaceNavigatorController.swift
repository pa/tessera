import AppKit

/// A borderless panel showing the workspace as a tree — tabs at the top level,
/// their panes (and floating windows) nested underneath — so you can jump to any
/// tab or pane by selecting it. ↑/↓ to move, Return to jump, Esc to dismiss.
@MainActor
final class WorkspaceNavigatorController: NSObject {
    /// One tree row. Tabs and panes are both selectable; `onSelect` performs the
    /// jump. `children` is empty for pane rows.
    final class Node {
        let title: String
        let emphasized: Bool          // active tab / focused pane
        let children: [Node]
        let onSelect: () -> Void
        init(title: String, emphasized: Bool, children: [Node], onSelect: @escaping () -> Void) {
            self.title = title
            self.emphasized = emphasized
            self.children = children
            self.onSelect = onSelect
        }
    }

    private var panel: NavPanel?
    private var outline: NavOutlineView!
    private var roots: [Node] = []

    private let panelSize = NSSize(width: 460, height: 420)

    /// Show the navigator populated with `roots`.
    func show(roots: [Node]) {
        self.roots = roots
        let panel = self.panel ?? buildPanel()
        self.panel = panel

        outline.reloadData()
        for root in roots { outline.expandItem(root) }
        selectFirstEmphasizedRow()
        center(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(outline)
    }

    func dismiss() { panel?.orderOut(nil) }

    // MARK: - Build

    private func buildPanel() -> NavPanel {
        let panel = NavPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        container.material = .menu
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Workspace")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        container.addSubview(title)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let outline = NavOutlineView()
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 26
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = false
        outline.floatsGroupRows = false
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(commit)
        outline.onCommit = { [weak self] in self?.commit() }
        outline.onCancel = { [weak self] in self?.dismiss() }
        scroll.documentView = outline
        self.outline = outline

        container.addSubview(scroll)
        panel.contentView = container

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return panel
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - panelSize.width / 2,
                             y: visible.midY - panelSize.height / 2)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    private func selectFirstEmphasizedRow() {
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node, node.emphasized {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                return
            }
        }
        if outline.numberOfRows > 0 {
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func commit() {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        dismiss()
        node.onSelect()
    }
}

// MARK: - Data source & delegate

extension WorkspaceNavigatorController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let label = NSTextField(labelWithString: node.title)
        label.font = .systemFont(ofSize: 13, weight: node.emphasized ? .semibold : .regular)
        label.textColor = node.emphasized ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

// MARK: - Key-handling panel & outline

private final class NavPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class NavOutlineView: NSOutlineView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onCommit?()  // return / keypad enter
        case 53: onCancel?()      // escape
        default: super.keyDown(with: event)
        }
    }
}
