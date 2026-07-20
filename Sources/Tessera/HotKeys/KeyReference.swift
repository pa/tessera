import Foundation

/// Single source of truth for the **keyboard-reference documentation**. Emits
/// the HTML injected into `docs/index.html` by `scripts/gen-docs.sh` (run
/// `Tessera --dump-keybindings`). Global shortcuts render from the live
/// `KeyBindingSet` (so rebinding/adding a command reflects automatically); the
/// modal keys are listed here alongside `ModeEngine.performModeKey` — add a key
/// there and a row here, then regenerate.
enum KeyReference {
    struct Row { let keys: String; let desc: String }

    /// Pane mode (`⌃P`). Mirror `ModeEngine.performModeKey`'s `.pane` branch.
    static let paneRows: [Row] = [
        Row(keys: "r / d", desc: "Split right / down"),
        Row(keys: "h j k l", desc: "Focus pane (or move a floating window)"),
        Row(keys: "⇧ + hjkl", desc: "Swap window with neighbour"),
        Row(keys: "n / p", desc: "Cycle focus through all windows"),
        Row(keys: "f", desc: "Full-screen (zoom) the pane"),
        Row(keys: "w", desc: "Attach / float / re-tile the focused window"),
        Row(keys: "s", desc: "Toggle stacked (monocle) layout"),
        Row(keys: "c", desc: "Change the pane's window (palette)"),
    ]

    /// Tab mode (`⌃T`).
    static let tabRows: [Row] = [
        Row(keys: "n", desc: "New tab"),
        Row(keys: "h / l", desc: "Previous / next tab"),
        Row(keys: "⇧h / ⇧l", desc: "Move window to previous / next tab"),
        Row(keys: "m … ⏎", desc: "Move window to tab # (a number past the end creates it)"),
    ]

    /// Resize mode (`⌃R`).
    static let resizeRows: [Row] = [
        Row(keys: "h / l", desc: "Narrower / wider"),
        Row(keys: "k / j", desc: "Taller / shorter"),
    ]

    /// Global shortcuts, grouped for display. Chords render from the live set, so
    /// this only needs editing when a *new command* is added.
    static let globalGroups: [(label: String, commands: [TilingCommand])] = [
        ("Split focused window right / down", [.splitRight, .splitDown]),
        ("Focus left / down / up / right", [.focusLeft, .focusDown, .focusUp, .focusRight]),
        ("Move window between panes", [.moveLeft, .moveDown, .moveUp, .moveRight]),
        ("New tab · next / previous tab", [.newTab, .nextTab, .previousTab]),
        ("Command palette", [.palette]),
        ("Workspace navigator", [.navigator]),
        ("Reset tiling (un-manage everything)", [.reset]),
    ]

    /// Render the full keyboard-reference section as HTML.
    static func html(_ set: KeyBindingSet = .defaults) -> String {
        var out = "<h3>Global shortcuts</h3>\n<div class=\"tablewrap\"><table>\n"
        out += "<tr><th>Shortcut</th><th>Action</th></tr>\n"
        for group in globalGroups {
            let chords = group.commands
                .compactMap { set.bindings[$0]?.display }
                .map { "<kbd>\($0)</kbd>" }
                .joined(separator: " / ")
            out += "<tr><td>\(chords)</td><td>\(group.label)</td></tr>\n"
        }
        out += "</table></div>\n"

        out += modeTable("Pane mode", entry: .enterPaneMode, rows: paneRows, set: set)
        out += modeTable("Tab mode", entry: .enterTabMode, rows: tabRows, set: set)
        out += modeTable("Resize mode", entry: .enterResizeMode, rows: resizeRows, set: set)
        out += "<p class=\"muted\">In any mode the menu-bar hint bar shows only the keys that "
        out += "apply right now. <kbd>⏎</kbd> / <kbd>esc</kbd> exits a mode.</p>\n"
        return out
    }

    private static func modeTable(_ name: String, entry: TilingCommand, rows: [Row], set: KeyBindingSet) -> String {
        let chord = set.bindings[entry]?.display ?? ""
        var out = "<h3>\(name) — <kbd>\(chord)</kbd></h3>\n<div class=\"tablewrap\"><table>\n"
        out += "<tr><th>Key</th><th>Action</th></tr>\n"
        for row in rows {
            out += "<tr><td>\(kbds(row.keys))</td><td>\(row.desc)</td></tr>\n"
        }
        out += "</table></div>\n"
        return out
    }

    /// Wrap whitespace-separated key tokens in <kbd>, leaving separators (/, +, …) bare.
    private static func kbds(_ s: String) -> String {
        s.split(separator: " ").map { token -> String in
            ["/", "+", "…"].contains(String(token)) ? String(token) : "<kbd>\(token)</kbd>"
        }.joined(separator: " ")
    }
}
