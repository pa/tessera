import AppKit

/// One selectable row in the command palette — either an installed application
/// to launch, or an on-screen window to focus.
struct PaletteItem: Identifiable {
    enum Kind {
        case application
        case window(windowID: CGWindowID)
    }

    let id: String            // stable per item (bundle id, or "pid:windowID")
    let title: String         // primary display text
    let subtitle: String?     // secondary text (path, bundle id, or app name)
    let icon: NSImage?
    let bundleID: String?
    let pid: pid_t?
    let kind: Kind

    /// The text fuzzy matching runs against. Title plus subtitle so a query can
    /// hit either the app name or its bundle id / owning app.
    var searchText: String {
        subtitle.map { "\(title) \($0)" } ?? title
    }
}
