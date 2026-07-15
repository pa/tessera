import AppKit

/// A small, non-interactive hint bar shown near the bottom of the screen while
/// a mode is active — the zellij-style "here are the keys for this mode" strip.
@MainActor
final class ModeHUD {
    private var panel: NSPanel?
    private var label: NSTextField?

    /// Show the bar with `text`; sizes to fit and re-centers.
    func show(_ text: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label?.stringValue = text

        panel.layoutIfNeeded()
        let fitting = label?.intrinsicContentSize.width ?? 400
        let height: CGFloat = 44

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            // Fit the text, but never wider than the screen (minus a margin).
            let maxWidth = max(320, visible.width - 40)
            let width = min(max(fitting + 40, 320), maxWidth)
            let origin = NSPoint(x: visible.midX - width / 2, y: visible.minY + 60)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        }
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        self.label = label

        panel.contentView = effect
        return panel
    }
}
