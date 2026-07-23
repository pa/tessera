import AppKit

/// Reads whether macOS **Stage Manager** is enabled. Stage Manager hides
/// non-active apps' windows, which fights every tiling WM — so Tessera warns the
/// user to turn it off. State lives in the `com.apple.WindowManager` domain under
/// `GloballyEnabled` (the same key the system toggle writes).
enum StageManager {
    static var isEnabled: Bool {
        let domain = "com.apple.WindowManager" as CFString
        // Sync first so we read the current value, not a stale cached one.
        CFPreferencesAppSynchronize(domain)
        if let value = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) as? Bool {
            return value
        }
        return false
    }

    /// Open the Settings pane that hosts the Stage Manager toggle (Desktop & Dock).
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
