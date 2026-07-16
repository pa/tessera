import ApplicationServices
import AppKit

/// Wraps the macOS Accessibility (AX) trust check.
///
/// Tessera can only puppet other apps' windows once the user has granted it
/// Accessibility access under System Settings → Privacy & Security →
/// Accessibility. TCC keys the grant to the code-signing **Designated
/// Requirement** (`identifier + certificate leaf`), which is path-independent.
/// Both the dev `.app` (scripts/build-app.sh) and the bare Homebrew binary sign
/// with the same per-user cert and bundle id, so they share one DR — a single
/// grant covers both. The bare binary makes this work by (a) self-signing with
/// that cert on launch and (b) disclaiming the launching terminal's
/// responsibility (see SelfSign), so the grant is attributed to Tessera itself
/// rather than the parent terminal.
///
/// Note: `AXIsProcessTrusted()` reflects the live TCC state, but macOS often
/// caches a *false* result for the lifetime of a process that was denied at
/// launch — so a first-time grant usually only takes effect after relaunch.
enum AccessibilityAuthorizer {
    /// True if this process is currently trusted for Accessibility. Does not prompt.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Check trust and, if not yet granted, ask macOS to surface the system
    /// prompt that deep-links the user to the Accessibility pane. Returns the
    /// current trust state (which will be `false` on the first call — the grant
    /// happens asynchronously after the user toggles it in System Settings).
    @discardableResult
    static func requestIfNeeded() -> Bool {
        // The `kAXTrustedCheckOptionPrompt` global is a non-Sendable mutable
        // CFStringRef under Swift 6 strict concurrency; its documented value is
        // the literal below, so we use that directly to sidestep the global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Open the Accessibility settings pane directly, for the "click to grant"
    /// affordance in the menu.
    static func openSettingsPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
