import AppKit

/// A translucent, click-through placeholder shown over an empty pane while the
/// user picks what to put there — the equivalent of tmux's blank pane. Purely
/// visual; it never steals events (the palette on top handles input).
@MainActor
final class EmptyPaneOverlay {
    private var panel: NSPanel?

    /// Show the overlay covering `axRect` (AX top-left space).
    func show(inAXRect axRect: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(ScreenGeometry.appKitRect(fromAX: axRect), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.borderWidth = 2
        effect.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        effect.autoresizingMask = [.width, .height]

        let hint = NSTextField(labelWithString: "Pick a window…")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 15, weight: .medium)
        hint.textColor = .secondaryLabelColor
        effect.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])

        panel.contentView = effect
        return panel
    }
}
