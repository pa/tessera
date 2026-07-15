import AppKit
import TesseraCore

/// A "go-to" panel: a search field over a tree of the workspace — tabs at the
/// top level, their panes/floating windows nested underneath. Type to fuzzy
/// filter by tab or window title; ↑/↓ to move, Return to jump, Esc to dismiss.
/// Rows are also clickable (double-click jumps).
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
    private var searchField: NSTextField!
    private var outline: NavOutlineView!
    private var allRoots: [Node] = []   // full tree
    private var roots: [Node] = []      // filtered tree shown

    private let panelSize = NSSize(width: 480, height: 440)

    /// Show the navigator populated with `roots`.
    func show(roots: [Node]) {
        allRoots = roots
        self.roots = roots
        let panel = self.panel ?? buildPanel()
        self.panel = panel

        searchField.stringValue = ""
        reload()

        NSApp.activate(ignoringOtherApps: true)
        panel.setFrame(centeredFrame(), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
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

        let field = NSTextField(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Go to tab or window…"
        field.font = .systemFont(ofSize: 18, weight: .light)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        container.addSubview(field)
        searchField = field

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        container.addSubview(divider)

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
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(commit)
        scroll.documentView = outline
        container.addSubview(scroll)
        self.outline = outline

        panel.contentView = container
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return panel
    }

    private func centeredFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.midX - panelSize.width / 2, y: visible.midY - panelSize.height / 2)
        return NSRect(origin: origin, size: panelSize)
    }

    // MARK: - Filtering

    private func applyFilter(_ query: String) {
        if query.isEmpty {
            roots = allRoots
        } else {
            roots = allRoots.compactMap { tab in
                if FuzzyMatcher.score(query: query, in: tab.title) != nil { return tab }
                let matches = tab.children.filter { FuzzyMatcher.score(query: query, in: $0.title) != nil }
                guard !matches.isEmpty else { return nil }
                return Node(title: tab.title, emphasized: tab.emphasized, children: matches, onSelect: tab.onSelect)
            }
        }
        reload()
    }

    private func reload() {
        outline.reloadData()
        for root in roots { outline.expandItem(root) }
        selectFirstSelectableRow()
    }

    private func selectFirstSelectableRow() {
        // Prefer the first leaf (pane/window); fall back to the first row.
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? Node, node.children.isEmpty {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                return
            }
        }
        if outline.numberOfRows > 0 {
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func move(by delta: Int) {
        guard outline.numberOfRows > 0 else { return }
        let next = min(max(0, outline.selectedRow + delta), outline.numberOfRows - 1)
        outline.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        outline.scrollRowToVisible(next)
    }

    @objc private func commit() {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        dismiss()
        node.onSelect()
    }
}

// MARK: - Search field delegate (typing + key routing to the outline)

extension WorkspaceNavigatorController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
        case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
        case #selector(NSResponder.insertNewline(_:)): commit(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
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
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}
