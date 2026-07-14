import AppKit
import Carbon.HIToolbox

/// The tiling commands a hot key can be bound to.
enum TilingCommand: String, CaseIterable, Codable {
    case splitRight, splitDown
    case newTab, nextTab, previousTab
    case reset
    case palette

    var title: String {
        switch self {
        case .splitRight: return "Split → Right"
        case .splitDown: return "Split → Down"
        case .newTab: return "New Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .reset: return "Reset Tiling"
        case .palette: return "Command Palette"
        }
    }

    /// Stable display order for the preferences list.
    static var ordered: [TilingCommand] {
        [.splitRight, .splitDown, .newTab, .nextTab, .previousTab, .palette, .reset]
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

    /// Tessera default: ⌃⌥⌘ prefix on mnemonic keys.
    static let tessera = KeyBindingSet(preset: .tessera, bindings: build(
        modifiers: [.control, .option, .command],
        keys: [.splitRight: kVK_ANSI_D, .splitDown: kVK_ANSI_S,
               .newTab: kVK_ANSI_T, .nextTab: kVK_ANSI_RightBracket,
               .previousTab: kVK_ANSI_LeftBracket, .reset: kVK_ANSI_R,
               .palette: kVK_Space]
    ))

    /// tmux-inspired: ⌃⌥ prefix, tmux's letter mnemonics (c new, n/p next/prev).
    static let tmux = KeyBindingSet(preset: .tmux, bindings: build(
        modifiers: [.control, .option],
        keys: [.splitRight: kVK_ANSI_D, .splitDown: kVK_ANSI_S,
               .newTab: kVK_ANSI_C, .nextTab: kVK_ANSI_N,
               .previousTab: kVK_ANSI_P, .reset: kVK_ANSI_R,
               .palette: kVK_Space]
    ))

    /// zellij-inspired: ⌥⌘ prefix, zellij's n/h/l style navigation.
    static let zellij = KeyBindingSet(preset: .zellij, bindings: build(
        modifiers: [.option, .command],
        keys: [.splitRight: kVK_ANSI_L, .splitDown: kVK_ANSI_J,
               .newTab: kVK_ANSI_N, .nextTab: kVK_ANSI_RightBracket,
               .previousTab: kVK_ANSI_LeftBracket, .reset: kVK_ANSI_R,
               .palette: kVK_Space]
    ))

    static func preset(_ preset: Preset) -> KeyBindingSet {
        switch preset {
        case .tessera: return tessera
        case .tmux: return tmux
        case .zellij: return zellij
        case .custom: return tessera // custom starts from the Tessera set
        }
    }

    private static func build(modifiers: NSEvent.ModifierFlags, keys: [TilingCommand: Int]) -> [TilingCommand: KeyBinding] {
        let mods = KeySymbols.carbonModifiers(from: modifiers)
        return keys.mapValues { KeyBinding(keyCode: $0, modifiers: mods) }
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
              let set = try? JSONDecoder().decode(KeyBindingSet.self, from: data) else {
            return .tessera
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
