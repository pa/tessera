import AppKit
import Carbon.HIToolbox

/// A zellij-style modal input layer driven by a single `CGEventTap`.
///
/// The tap is installed once and lives for the app's lifetime. In **normal**
/// mode it passes every key through, except the configurable mode-entry chords
/// (⌃P → pane, ⌃T → tab by default). Inside a mode it captures **all** keydowns
/// (strict, zellij-style): mapped keys drive tiling, Esc/Enter returns to
/// normal, the other prefix switches modes, and everything else is swallowed.
///
/// Because entering a mode is only a state change (not a re-registration of
/// hot keys), re-entry is always reliable — the flaw the previous
/// register/unregister approach had.
@MainActor
final class ModeEngine {
    enum Mode: Equatable {
        case normal, pane, tab, resize

        var glyph: String {
            switch self {
            case .normal: return "▚"
            case .pane: return "▚ P"
            case .tab: return "▚ T"
            case .resize: return "▚ R"
            }
        }

        /// Hint text for the HUD, or nil in normal mode.
        var hudText: String? {
            switch self {
            case .normal: return nil
            case .pane: return "PANE   r/d → split    hjkl → focus / move float    ⇧hjkl → swap    f → fullscreen    w → float    c → change    ⏎/esc → done"
            case .tab: return "TAB   n → new tab    ] / l → next    [ / h → previous    ⏎/esc → done"
            case .resize: return "RESIZE   h → narrower    l → wider    k → taller    j → shorter    ⏎/esc → done"
            }
        }
    }

    /// A key + relevant modifiers, comparable against a tap event.
    struct Chord: Equatable {
        let keyCode: Int64
        let flags: CGEventFlags
        private static let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

        init(keyCode: Int64, flags: CGEventFlags) {
            self.keyCode = keyCode
            self.flags = flags.intersection(Chord.relevant)
        }
        init(event: CGEvent) {
            self.init(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        }
        static func == (a: Chord, b: Chord) -> Bool {
            a.keyCode == b.keyCode && a.flags == b.flags
        }
    }

    private(set) var mode: Mode = .normal {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }
    var onModeChange: ((Mode) -> Void)?

    private let tiling: TilingController
    private var paneEntry = Chord(keyCode: Int64(kVK_ANSI_P), flags: .maskControl)
    private var tabEntry = Chord(keyCode: Int64(kVK_ANSI_T), flags: .maskControl)
    private var resizeEntry = Chord(keyCode: Int64(kVK_ANSI_R), flags: .maskControl)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timeout: DispatchWorkItem?
    private let timeoutSeconds: TimeInterval = 5

    init(tiling: TilingController) {
        self.tiling = tiling
    }

    /// Update the configurable mode-entry chords (from the binding set).
    func updateEntryChords(pane: Chord, tab: Chord, resize: Chord) {
        paneEntry = pane
        tabEntry = tab
        resizeEntry = resize
    }

    // MARK: - Tap lifecycle

    /// Install the event tap. No-op if already installed. Returns false if the
    /// tap couldn't be created (e.g. Accessibility not yet granted) so the
    /// caller can retry later.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<ModeEngine>.fromOpaque(refcon).takeUnretainedValue()
            // `handle` returns whether to swallow the event; build the
            // passthrough here (Unmanaged<CGEvent> isn't Sendable, so it can't
            // cross the assumeIsolated boundary as a return value).
            let consume = MainActor.assumeIsolated { engine.handle(type: type, event: event) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Tessera: could not create event tap (Accessibility not granted yet?)")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: - Event handling

    /// Returns true if the event should be swallowed (consumed), false to pass
    /// it through to the focused app.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables a tap that blocks too long or on user input; just
        // re-enable and pass the event on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .keyDown else { return false }

        let chord = Chord(event: event)

        if mode == .normal {
            if chord == paneEntry { setMode(.pane); return true }
            if chord == tabEntry { setMode(.tab); return true }
            if chord == resizeEntry { setMode(.resize); return true }
            return false // normal typing passes through
        }

        // Inside a mode: strict capture — consume every keydown.
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_Escape || keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            setMode(.normal)
            return true
        }
        if chord == paneEntry { setMode(.pane); return true }
        if chord == tabEntry { setMode(.tab); return true }
        if chord == resizeEntry { setMode(.resize); return true }

        performModeKey(keyCode: keyCode, shift: event.flags.contains(.maskShift))
        refreshTimeout()
        return true
    }

    private func performModeKey(keyCode: Int, shift: Bool) {
        switch mode {
        case .normal:
            break
        case .pane:
            switch keyCode {
            case kVK_ANSI_R: exitAndRun { $0.split(.horizontal) }
            case kVK_ANSI_D: exitAndRun { $0.split(.vertical) }
            case kVK_ANSI_C: exitAndRun { $0.changeFocusedPaneWindow() } // opens palette
            case kVK_ANSI_F: tiling.toggleFullscreen()
            case kVK_ANSI_W: tiling.toggleFloat()
            // hjkl: moves the window if it's floating, else moves focus (⇧ swaps).
            case kVK_ANSI_H: tiling.paneDirection(.left, shift: shift)
            case kVK_ANSI_J: tiling.paneDirection(.down, shift: shift)
            case kVK_ANSI_K: tiling.paneDirection(.up, shift: shift)
            case kVK_ANSI_L: tiling.paneDirection(.right, shift: shift)
            default: break // swallowed
            }
        case .tab:
            switch keyCode {
            case kVK_ANSI_N: exitAndRun { $0.newTab() } // opens the palette → leave the mode
            case kVK_ANSI_RightBracket, kVK_ANSI_L: tiling.nextTab()
            case kVK_ANSI_LeftBracket, kVK_ANSI_H: tiling.previousTab()
            default: break // swallowed
            }
        case .resize:
            switch keyCode {
            case kVK_ANSI_H: tiling.resizeFocused(axis: .horizontal, grow: false) // narrower
            case kVK_ANSI_L: tiling.resizeFocused(axis: .horizontal, grow: true)  // wider
            case kVK_ANSI_K: tiling.resizeFocused(axis: .vertical, grow: true)    // taller
            case kVK_ANSI_J: tiling.resizeFocused(axis: .vertical, grow: false)   // shorter
            default: break // swallowed
            }
        }
    }

    /// Split opens the palette, which needs clean typing — leave the mode first.
    private func exitAndRun(_ action: (TilingController) -> Void) {
        setMode(.normal)
        action(tiling)
    }

    // MARK: - Mode state

    private func setMode(_ newMode: Mode) {
        mode = newMode
        if newMode == .normal {
            timeout?.cancel()
            timeout = nil
        } else {
            refreshTimeout()
        }
    }

    private func refreshTimeout() {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setMode(.normal) }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
    }
}
