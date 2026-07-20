import AppKit
import TesseraCore

/// A "go-to" panel: a search field over a tree of the workspace — tabs at the
/// top level, their panes/floating windows nested underneath. Type to fuzzy
/// filter by tab or window title; ↑/↓ to move, Return to jump, Esc to dismiss.
/// Rows are also clickable (double-click jumps).
@MainActor
final class WorkspaceNavigatorController: NSObject {
    /// One tree row. Tabs (groups) and windows (leaves) are both selectable;
    /// `onSelect` performs the jump.
    final class Node {
        let title: String
        let subtitle: String?
        let icon: NSImage?
        let isGroup: Bool             // tab header vs window row
        let emphasized: Bool          // active tab / focused window
        let children: [Node]
        let onSelect: () -> Void
        init(title: String, subtitle: String? = nil, icon: NSImage? = nil,
             isGroup: Bool = false, emphasized: Bool, children: [Node],
             onSelect: @escaping () -> Void) {
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.isGroup = isGroup
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
        panel.hidesOnDeactivate = false
        panel.delegate = self   // dismiss when focus leaves the panel

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
        outline.style = .sourceList        // rounded, inset accent selection
        outline.rowHeight = 38
        outline.indentationPerLevel = 14
        outline.floatsGroupRows = false
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
            func matches(_ node: Node) -> Bool {
                FuzzyMatcher.score(query: query, in: node.title) != nil
                    || (node.subtitle.map { FuzzyMatcher.score(query: query, in: $0) != nil } ?? false)
            }
            roots = allRoots.compactMap { tab in
                if matches(tab) { return tab }
                let hits = tab.children.filter(matches)
                guard !hits.isEmpty else { return nil }
                return Node(title: tab.title, subtitle: tab.subtitle, icon: tab.icon,
                            isGroup: tab.isGroup, emphasized: tab.emphasized,
                            children: hits, onSelect: tab.onSelect)
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

// MARK: - Dismiss on losing focus (click outside / app switch)

extension WorkspaceNavigatorController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
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
        let cell = (outlineView.makeView(withIdentifier: NavCell.id, owner: self) as? NavCell) ?? NavCell()
        cell.configure(with: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? Node)?.isGroup == true ? 30 : 40
    }
}

// MARK: - Row cell

/// Icon + title (+ subtitle) row. Tabs render as a compact header with an SF
/// Symbol; windows render with their app icon and app-name subtitle. Text color
/// follows the selection so it stays legible on the accent highlight.
private final class NavCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("NavCell")

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var isGroup = false
    private var emphasized = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NavCell.id
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(text)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with node: WorkspaceNavigatorController.Node) {
        isGroup = node.isGroup
        emphasized = node.emphasized
        titleLabel.stringValue = node.title
        titleLabel.font = .systemFont(ofSize: isGroup ? 12 : 13,
                                      weight: isGroup ? .bold : (node.emphasized ? .semibold : .regular))
        subtitleLabel.stringValue = node.subtitle ?? ""
        subtitleLabel.isHidden = (node.subtitle ?? "").isEmpty

        iconView.image = node.icon
        iconView.contentTintColor = node.isGroup
            ? (node.emphasized ? .controlAccentColor : .secondaryLabelColor)
            : nil   // app icons render in full color
        applyTextColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColors() }
    }

    private func applyTextColors() {
        let selected = backgroundStyle == .emphasized
        titleLabel.textColor = selected ? .white : .labelColor
        subtitleLabel.textColor = selected ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        if isGroup {
            iconView.contentTintColor = selected ? .white : (emphasized ? .controlAccentColor : .secondaryLabelColor)
        }
    }
}

// MARK: - Key-handling panel & outline

private final class NavPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class NavOutlineView: NSOutlineView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}
