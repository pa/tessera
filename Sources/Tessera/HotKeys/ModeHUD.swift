import AppKit
import QuartzCore

/// A small, non-interactive hint bar shown near the bottom of the screen while a
/// mode is active — the zellij-style "here are the keys for this mode" strip.
///
/// Key glyphs in the hint are wrapped in markers (`\u{01}…\u{02}`) and rendered as
/// real rounded **key-chips** (keycap style). `flash(_:shift:)` animates the
/// pressed chip's layer — a background fill + a spring "pop" — so the highlight is
/// native-feeling and cheap (only one layer animates; no text re-layout).
@MainActor
final class ModeHUD {
    static let keyStart: Character = "\u{01}"
    static let keyEnd: Character = "\u{02}"

    private var panel: NSPanel?
    private var stack: NSStackView?
    private var chips: [(view: KeyChip, token: String)] = []
    private var current = ""

    /// Show the bar with `text` (may contain key markers). Rebuilds the chips only
    /// when the text actually changes, so repeated calls (e.g. per keypress) are
    /// cheap.
    func show(_ text: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if text != current { current = text; rebuild(text); resize() }
        panel.orderFront(nil)
    }

    /// Flash the pressed key's chip — a quick fill + spring pop, then revert.
    func flash(_ char: String, shift: Bool) {
        guard panel != nil else { return }
        for chip in chips where Self.keyMatches(token: chip.token, char: char, shift: shift) {
            chip.view.pop()
        }
    }

    func hide() { panel?.orderOut(nil) }

    // MARK: - Build

    private func rebuild(_ text: String) {
        guard let stack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips.removeAll()

        var inKey = false, buf = ""
        func flush() {
            guard !buf.isEmpty else { return }
            if inKey {
                let chip = KeyChip(text: buf)
                stack.addArrangedSubview(chip)
                chips.append((chip, buf))
            } else {
                let l = NSTextField(labelWithString: buf)
                l.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
                l.textColor = .labelColor
                stack.addArrangedSubview(l)
            }
            buf = ""
        }
        for ch in text {
            if ch == ModeHUD.keyStart { flush(); inKey = true }
            else if ch == ModeHUD.keyEnd { flush(); inKey = false }
            else { buf.append(ch) }
        }
        flush()
    }

    /// Match a chip token to the pressed key: exact for single-key tokens (r, f,
    /// m…), membership for hjkl clusters ("hjkl" lights on `h`), ⇧ prefix matching
    /// shift. Word tokens (esc) never match a letter.
    private static func keyMatches(token: String, char: String, shift: Bool) -> Bool {
        guard token.hasPrefix("⇧") == shift else { return false }
        let stripped = (token.hasPrefix("⇧") ? String(token.dropFirst()) : token).lowercased()
        let c = char.lowercased()
        if stripped == c { return true }
        if stripped.count > 1 && stripped.allSatisfy({ "hjkl".contains($0) }) && stripped.contains(c) { return true }
        return false
    }

    private func resize() {
        guard let panel, let stack else { return }
        panel.layoutIfNeeded()
        let fitting = stack.fittingSize.width
        let height: CGFloat = 46
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let maxWidth = max(320, visible.width - 40)
            let width = min(max(fitting + 44, 320), maxWidth)
            let origin = NSPoint(x: visible.midX - width / 2, y: visible.minY + 60)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 46),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        self.stack = stack

        panel.contentView = effect
        return panel
    }
}

/// A rounded keycap-style chip for a key glyph in the hint bar.
private final class KeyChip: NSView {
    private let field = NSTextField(labelWithString: "")
    private static let accent = NSColor(red: 0, green: 0.68, blue: 0.71, alpha: 1)

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5.5
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor

        field.stringValue = text
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        field.textColor = Self.accent
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let idleBG = NSColor.white.withAlphaComponent(0.10).cgColor

    /// Light the chip: snap to an accent fill, then ease back — a keycastr-style
    /// key highlight. Only this chip's layer changes (GPU-composited, no
    /// text re-layout), so it stays cheap even on rapid presses.
    func pop() {
        layer?.removeAnimation(forKey: "fade")
        layer?.backgroundColor = Self.accent.cgColor
        field.textColor = .black
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self else { return }
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = Self.accent.cgColor
            fade.toValue = Self.idleBG
            fade.duration = 0.28
            self.layer?.add(fade, forKey: "fade")
            self.layer?.backgroundColor = Self.idleBG
            self.field.textColor = Self.accent
        }
    }
}
