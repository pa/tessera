import AppKit
import Carbon.HIToolbox

/// The tiling commands a hot key can be bound to.
enum TilingCommand: String, CaseIterable, Codable {
    case splitRight, splitDown
    case focusLeft, focusDown, focusUp, focusRight
    case moveLeft, moveDown, moveUp, moveRight
    case newTab, nextTab, previousTab
    case reset
    case palette
    case navigator
    case enterPaneMode, enterTabMode, enterResizeMode

    var title: String {
        switch self {
        case .splitRight: return "Split → Right"
        case .splitDown: return "Split → Down"
        case .focusLeft: return "Focus Left"
        case .focusDown: return "Focus Down"
        case .focusUp: return "Focus Up"
        case .focusRight: return "Focus Right"
        case .moveLeft: return "Move Window Left"
        case .moveDown: return "Move Window Down"
        case .moveUp: return "Move Window Up"
        case .moveRight: return "Move Window Right"
        case .newTab: return "New Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .reset: return "Reset Tiling"
        case .palette: return "Command Palette"
        case .navigator: return "Workspace Navigator"
        case .enterPaneMode: return "Enter Pane Mode"
        case .enterTabMode: return "Enter Tab Mode"
        case .enterResizeMode: return "Enter Resize Mode"
        }
    }

    /// Commands that enter a modal layer (handled by the event tap, not the
    /// global hot-key manager).
    static let modeEntry: Set<TilingCommand> = [.enterPaneMode, .enterTabMode, .enterResizeMode]

    /// Stable display order for the preferences list.
    static var ordered: [TilingCommand] {
        [.enterPaneMode, .enterTabMode, .enterResizeMode,
         .splitRight, .splitDown,
         .focusLeft, .focusDown, .focusUp, .focusRight,
         .moveLeft, .moveDown, .moveUp, .moveRight,
         .newTab, .nextTab, .previousTab,
         .palette, .navigator, .reset]
    }
}

/// A single chord: a Carbon virtual key code + Carbon modifier mask.
struct KeyBinding: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt32

    /// Human-readable form, e.g. "⌃⌥⌘D".
    var display: String {
        KeySymbols.modifierString(modifiers) + KeySymbols.keyName(keyCode)
    }
}

/// A full set of bindings plus which preset produced it.
struct KeyBindingSet: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable {
        case tessera, tmux, zellij, custom
        var title: String {
            switch self {
            case .tessera: return "Tessera"
            case .tmux: return "tmux-inspired"
            case .zellij: return "zellij-inspired"
            case .custom: return "Custom"
            }
        }
    }

    var preset: Preset
    var bindings: [TilingCommand: KeyBinding]

    // MARK: - Presets

    /// Focus movement is hjkl in every preset; window-move is ⇧ + hjkl.
    private static let focusKeys: [TilingCommand: Int] = [
        .focusLeft: kVK_ANSI_H, .focusDown: kVK_ANSI_J,
        .focusUp: kVK_ANSI_K, .focusRight: kVK_ANSI_L,
    ]
    private static let moveKeys: [TilingCommand: Int] = [
        .moveLeft: kVK_ANSI_H, .moveDown: kVK_ANSI_J,
        .moveUp: kVK_ANSI_K, .moveRight: kVK_ANSI_L,
    ]

    /// Tessera default: ⌃⌥⌘ prefix, vim hjkl focus, ⇧+hjkl to move windows.
    static let tessera = KeyBindingSet(preset: .tessera, bindings: assemble(
        base: [.control, .option, .command],
        baseKeys: [.splitRight: kVK_ANSI_D, .splitDown: kVK_ANSI_S,
                   .newTab: kVK_ANSI_T, .nextTab: kVK_ANSI_RightBracket,
                   .previousTab: kVK_ANSI_LeftBracket, .reset: kVK_ANSI_R,
                   .palette: kVK_Space, .navigator: kVK_ANSI_O].merging(focusKeys) { a, _ in a }
    ))

    /// tmux-inspired: ⌃⌥ prefix, tmux's letter mnemonics (c new, n/p next/prev),
    /// hjkl focus, ⇧+hjkl move.
    static let tmux = KeyBindingSet(preset: .tmux, bindings: assemble(
        base: [.control, .option],
        baseKeys: [.splitRight: kVK_ANSI_D, .splitDown: kVK_ANSI_S,
                   .newTab: kVK_ANSI_C, .nextTab: kVK_ANSI_N,
                   .previousTab: kVK_ANSI_P, .reset: kVK_ANSI_R,
                   .palette: kVK_Space, .navigator: kVK_ANSI_O].merging(focusKeys) { a, _ in a }
    ))

    /// zellij-inspired: ⌥⌘ prefix, hjkl focus, =/- splits, ⇧+hjkl move.
    static let zellij = KeyBindingSet(preset: .zellij, bindings: assemble(
        base: [.option, .command],
        baseKeys: [.splitRight: kVK_ANSI_Equal, .splitDown: kVK_ANSI_Minus,
                   .newTab: kVK_ANSI_N, .nextTab: kVK_ANSI_RightBracket,
                   .previousTab: kVK_ANSI_LeftBracket, .reset: kVK_ANSI_R,
                   .palette: kVK_Space, .navigator: kVK_ANSI_O].merging(focusKeys) { a, _ in a }
    ))

    static func preset(_ preset: Preset) -> KeyBindingSet {
        switch preset {
        case .tessera: return tessera
        case .tmux: return tmux
        case .zellij: return zellij
        case .custom: return tessera // custom starts from the Tessera set
        }
    }

    /// Bind `baseKeys` at `base` modifiers and the shared move keys at
    /// `base + ⇧` (so window-move mirrors focus with an added Shift). Mode-entry
    /// keys are fixed at ⌃P / ⌃T across presets (zellij-style), rebindable in
    /// preferences.
    private static func assemble(base: NSEvent.ModifierFlags, baseKeys: [TilingCommand: Int]) -> [TilingCommand: KeyBinding] {
        let baseMods = KeySymbols.carbonModifiers(from: base)
        let moveMods = KeySymbols.carbonModifiers(from: base.union(.shift))
        var result = baseKeys.mapValues { KeyBinding(keyCode: $0, modifiers: baseMods) }
        for (command, keyCode) in moveKeys {
            result[command] = KeyBinding(keyCode: keyCode, modifiers: moveMods)
        }
        let control = UInt32(controlKey)
        result[.enterPaneMode] = KeyBinding(keyCode: kVK_ANSI_P, modifiers: control)
        result[.enterTabMode] = KeyBinding(keyCode: kVK_ANSI_T, modifiers: control)
        result[.enterResizeMode] = KeyBinding(keyCode: kVK_ANSI_R, modifiers: control)
        return result
    }
}

// MARK: - Persistence

/// Loads/saves the binding set to Application Support so it survives restarts.
enum HotKeyStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tessera/hotkeys.json")
    }

    static func load() -> KeyBindingSet {
        guard let data = try? Data(contentsOf: url),
              var set = try? JSONDecoder().decode(KeyBindingSet.self, from: data) else {
            return .tessera
        }
        // Backfill commands added since the file was written (custom falls back
        // to the Tessera defaults) so new features aren't left unbound.
        let defaults = KeyBindingSet.preset(set.preset).bindings
        for command in TilingCommand.allCases where set.bindings[command] == nil {
            set.bindings[command] = defaults[command]
        }
        return set
    }

    static func save(_ set: KeyBindingSet) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(set)
            try data.write(to: url)
        } catch {
            NSLog("Tessera: failed to save hot keys: \(error)")
        }
    }
}

// MARK: - Key symbol formatting & modifier conversion

enum KeySymbols {
    /// Convert a Carbon modifier mask to the `CGEventFlags` an event tap reports.
    static func cgFlags(fromCarbon mods: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if mods & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if mods & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if mods & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        return flags
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    static func modifierString(_ mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    /// Display name for a Carbon virtual key code.
    static func keyName(_ keyCode: Int) -> String {
        if let name = special[keyCode] { return name }
        return letters[keyCode] ?? "key\(keyCode)"
    }

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
    ]

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]
}
