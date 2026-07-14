import AppKit
import Carbon.HIToolbox

/// A button that records a keyboard shortcut: click it, then press the desired
/// chord. Reports the captured `KeyBinding` via `onCapture`. Requires at least
/// one modifier (a bare key makes a poor global hot key).
@MainActor
final class KeyRecorderView: NSButton {
    var onCapture: ((KeyBinding) -> Void)?

    var binding: KeyBinding? {
        didSet { refreshTitle() }
    }

    private var isRecording = false {
        didSet { refreshTitle() }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func beginRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels the recording without changing the binding.
        if event.keyCode == kVK_Escape {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = KeySymbols.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep() // demand at least one modifier
            return
        }

        let captured = KeyBinding(keyCode: Int(event.keyCode), modifiers: modifiers)
        binding = captured
        isRecording = false
        window?.makeFirstResponder(nil)
        onCapture?(captured)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While recording, swallow would-be equivalents so ⌘-combos are captured
        // rather than triggering menu items.
        if isRecording {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func refreshTitle() {
        if isRecording {
            title = "Type shortcut…"
        } else {
            title = binding?.display ?? "Unset"
        }
    }
}
