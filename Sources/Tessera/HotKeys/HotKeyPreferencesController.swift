import AppKit

/// A small preferences window for rebinding the global hot keys: pick a preset
/// (Tessera / tmux-inspired / zellij-inspired) or record a custom chord per
/// command. Every change is persisted and applied live via `onChange`.
@MainActor
final class HotKeyPreferencesController: NSObject {
    /// Called whenever the binding set changes so the app can persist and
    /// re-register the hot keys.
    var onChange: ((KeyBindingSet) -> Void)?

    private var bindingSet: KeyBindingSet
    private var window: NSWindow?
    private var presetPopup: NSPopUpButton!
    private var recorders: [TilingCommand: KeyRecorderView] = [:]

    init(bindingSet: KeyBindingSet) {
        self.bindingSet = bindingSet
    }

    func show() {
        let window = self.window ?? buildWindow()
        self.window = window
        syncControls()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Build

    private func buildWindow() -> NSWindow {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        // Preset row.
        let presetLabel = NSTextField(labelWithString: "Preset:")
        presetPopup = NSPopUpButton()
        for preset in KeyBindingSet.Preset.allCases {
            presetPopup.addItem(withTitle: preset.title)
        }
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        let presetRow = NSStackView(views: [presetLabel, presetPopup])
        presetRow.orientation = .horizontal
        presetRow.spacing = 12
        content.addArrangedSubview(presetRow)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true

        // One row per command.
        for command in TilingCommand.ordered {
            let label = NSTextField(labelWithString: command.title)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 140).isActive = true

            let recorder = KeyRecorderView()
            recorder.binding = bindingSet.bindings[command]
            recorder.onCapture = { [weak self] captured in
                self?.updateBinding(command, to: captured)
            }
            recorders[command] = recorder

            let row = NSStackView(views: [label, recorder])
            row.orientation = .horizontal
            row.spacing = 12
            content.addArrangedSubview(row)
        }

        let note = NSTextField(wrappingLabelWithString:
            "Shortcuts fire from any app. At least one modifier is required. " +
            "Press ⎋ while recording to cancel. Editing a key switches the preset to Custom.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 380).isActive = true
        content.addArrangedSubview(note)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tessera Hotkeys"
        window.isReleasedWhenClosed = false
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.center()
        return window
    }

    // MARK: - Changes

    @objc private func presetChanged() {
        let selected = KeyBindingSet.Preset.allCases[presetPopup.indexOfSelectedItem]
        if selected == .custom {
            bindingSet.preset = .custom
        } else {
            bindingSet = .preset(selected)
        }
        syncControls()
        commit()
    }

    private func updateBinding(_ command: TilingCommand, to binding: KeyBinding) {
        bindingSet.bindings[command] = binding
        bindingSet.preset = .custom
        selectPresetInPopup()
        commit()
    }

    /// Reflect `bindingSet` in the controls.
    private func syncControls() {
        selectPresetInPopup()
        for (command, recorder) in recorders {
            recorder.binding = bindingSet.bindings[command]
        }
    }

    private func selectPresetInPopup() {
        if let index = KeyBindingSet.Preset.allCases.firstIndex(of: bindingSet.preset) {
            presetPopup.selectItem(at: index)
        }
    }

    private func commit() {
        HotKeyStore.save(bindingSet)
        onChange?(bindingSet)
    }
}
