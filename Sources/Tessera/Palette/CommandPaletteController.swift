import AppKit
import TesseraCore

/// A borderless `NSPanel` can't become key (and thus can't receive typing)
/// unless it says so explicitly.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The command palette: a floating, borderless search bar over a results list.
///
/// Opens with the full catalog (running windows + installed apps), filters live
/// as you type via `FuzzyMatcher`, and reports the chosen row through
/// `onSelect`. Keyboard-driven: ↑/↓ to move, Return to pick, Esc to dismiss;
/// clicking outside dismisses too.
@MainActor
final class CommandPaletteController: NSObject {
    /// Invoked with the chosen item when the user commits a selection. The
    /// palette dismisses itself first. Callers wire this to launch/focus (M3)
    /// or, later, snap the selection into a pane (M4).
    var onSelect: ((PaletteItem) -> Void)?

    private var panel: KeyablePanel?
    private var searchField: NSTextField!
    private var tableView: NSTableView!

    private var allItems: [PaletteItem] = []
    private var filtered: [PaletteItem] = []

    private let panelSize = NSSize(width: 560, height: 360)
    private let rowHeight: CGFloat = 44

    // MARK: - Presentation

    /// Load the catalog and show the palette centered on the main screen.
    func present() {
        allItems = AppCatalog.allItems()
        filtered = allItems

        let panel = self.panel ?? buildPanel()
        self.panel = panel

        searchField.stringValue = ""
        tableView.reloadData()
        selectRow(0)
        centerOnMainScreen(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    // MARK: - Building the UI

    private func buildPanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        // Rounded, blurred container for a native look.
        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        container.material = .menu
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        panel.contentView = container

        // Search field along the top.
        let field = NSTextField(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Search apps and windows…"
        field.font = .systemFont(ofSize: 20, weight: .light)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        container.addSubview(field)
        searchField = field

        // Divider.
        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        container.addSubview(divider)

        // Results table inside a scroll view.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = rowHeight
        table.selectionHighlightStyle = .regular
        table.style = .fullWidth
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(commitSelection)
        table.target = self
        scroll.documentView = table
        container.addSubview(scroll)
        tableView = table

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return panel
    }

    private func centerOnMainScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panelSize.width / 2,
            y: visible.midY - panelSize.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    // MARK: - Filtering & selection

    private func applyFilter(_ query: String) {
        filtered = FuzzyMatcher.rank(allItems, query: query, key: { $0.searchText })
        tableView.reloadData()
        selectRow(0)
    }

    private func selectRow(_ row: Int) {
        guard row >= 0, row < filtered.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(0, current + delta), filtered.count - 1)
        selectRow(next)
    }

    @objc private func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let item = filtered[row]
        dismiss()
        onSelect?(item)
    }
}

// MARK: - Search field delegate (typing + key handling)

extension CommandPaletteController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }
}

// MARK: - Table data source & delegate

extension CommandPaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let item = filtered[row]

        let cell = NSView()

        let imageView = NSImageView(image: item.icon ?? NSImage())
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        cell.addSubview(imageView)

        let title = NSTextField(labelWithString: item.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        cell.addSubview(title)

        let subtitle = NSTextField(labelWithString: item.subtitle ?? "")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        cell.addSubview(subtitle)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 24),
            imageView.heightAnchor.constraint(equalToConstant: 24),

            title.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])

        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }
}

// MARK: - Dismiss on losing focus

extension CommandPaletteController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}
