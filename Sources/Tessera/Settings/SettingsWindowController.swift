import AppKit

/// Tessera's Settings window, opened from the menu bar or ⌘,. Two tabs:
/// **General** (padding, version) and **Hotkeys** (rebind any command, reset to
/// defaults). There are no presets — a single default binding set that the user
/// customizes. Every change persists immediately and is applied live via the
/// `onHotKeysChange` / `onPaddingChange` callbacks.
@MainActor
final class SettingsWindowController: NSObject {
    var onHotKeysChange: ((KeyBindingSet) -> Void)?
    var onPaddingChange: ((Double) -> Void)?

    private var bindingSet: KeyBindingSet
    private var settings: AppSettings
    private var window: NSWindow?
    private var recorders: [TilingCommand: KeyRecorderView] = [:]
    private var paddingSlider: NSSlider!
    private var paddingValueLabel: NSTextField!

    init(bindingSet: KeyBindingSet, settings: AppSettings) {
        self.bindingSet = bindingSet
        self.settings = settings
    }

    func show() {
        let window = self.window ?? buildWindow()
        self.window = window
        syncControls()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window

    private func buildWindow() -> NSWindow {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = buildGeneralTab()
        let hotkeys = NSTabViewItem(identifier: "hotkeys")
        hotkeys.label = "Hotkeys"
        hotkeys.view = buildHotkeysTab()
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(hotkeys)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tessera Settings"
        window.isReleasedWhenClosed = false
        let container = NSView()
        container.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        window.contentView = container
        window.center()
        return window
    }

    // MARK: - General tab

    private func buildGeneralTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Padding row.
        let paddingLabel = NSTextField(labelWithString: "Tile padding:")
        paddingSlider = NSSlider(value: settings.paddingPercent,
                                 minValue: AppSettings.paddingRange.lowerBound,
                                 maxValue: AppSettings.paddingRange.upperBound,
                                 target: self, action: #selector(paddingChanged))
        paddingSlider.translatesAutoresizingMaskIntoConstraints = false
        paddingSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        paddingValueLabel = NSTextField(labelWithString: paddingText(settings.paddingPercent))
        paddingValueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let paddingRow = NSStackView(views: [paddingLabel, paddingSlider, paddingValueLabel])
        paddingRow.orientation = .horizontal
        paddingRow.spacing = 12
        stack.addArrangedSubview(paddingRow)

        let paddingNote = NSTextField(wrappingLabelWithString:
            "Gap around and between tiles, as a percentage of screen width. Applies immediately.")
        paddingNote.font = .systemFont(ofSize: 11)
        paddingNote.textColor = .secondaryLabelColor
        paddingNote.translatesAutoresizingMaskIntoConstraints = false
        paddingNote.widthAnchor.constraint(equalToConstant: 380).isActive = true
        stack.addArrangedSubview(paddingNote)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalToConstant: 380).isActive = true

        // Version tag.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let versionLabel = NSTextField(labelWithString: "Tessera  v\(version)")
        versionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)

        return wrap(stack)
    }

    // MARK: - Hotkeys tab

    private func buildHotkeysTab() -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        rows.translatesAutoresizingMaskIntoConstraints = false

        for command in TilingCommand.ordered {
            let label = NSTextField(labelWithString: command.title)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let recorder = KeyRecorderView()
            recorder.binding = bindingSet.bindings[command]
            recorder.onCapture = { [weak self] captured in
                self?.updateBinding(command, to: captured)
            }
            recorders[command] = recorder

            let row = NSStackView(views: [label, recorder])
            row.orientation = .horizontal
            row.spacing = 12
            rows.addArrangedSubview(row)
        }

        // Scrollable list (many commands).
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = rows
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let note = NSTextField(wrappingLabelWithString:
            "Shortcuts fire from any app. At least one modifier is required. Press ⎋ while recording to cancel.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetHotkeys))
        resetButton.bezelStyle = .rounded

        let footer = NSStackView(views: [note, resetButton])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 12
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    /// Pin a leading-aligned stack into a fresh container view.
    private func wrap(_ content: NSView) -> NSView {
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        return container
    }

    // MARK: - Changes

    @objc private func paddingChanged() {
        let value = (paddingSlider.doubleValue * 10).rounded() / 10 // snap to 0.1%
        settings.paddingPercent = value
        paddingValueLabel.stringValue = paddingText(value)
        SettingsStore.save(settings)
        onPaddingChange?(value)
    }

    @objc private func resetHotkeys() {
        bindingSet = .defaults
        syncControls()
        commitHotkeys()
    }

    private func updateBinding(_ command: TilingCommand, to binding: KeyBinding) {
        bindingSet.bindings[command] = binding
        commitHotkeys()
    }

    private func syncControls() {
        for (command, recorder) in recorders {
            recorder.binding = bindingSet.bindings[command]
        }
        if paddingSlider != nil {
            paddingSlider.doubleValue = settings.paddingPercent
            paddingValueLabel.stringValue = paddingText(settings.paddingPercent)
        }
    }

    private func commitHotkeys() {
        HotKeyStore.save(bindingSet)
        onHotKeysChange?(bindingSet)
    }

    private func paddingText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}
