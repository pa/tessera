import ApplicationServices
import AppKit

/// Wraps the macOS Accessibility (AX) trust check.
///
/// Tessera can only puppet other apps' windows once the user has granted it
/// Accessibility access under System Settings → Privacy & Security →
/// Accessibility. The grant is keyed to the app's code signature + bundle path,
/// which is why Tessera must run as a signed `.app` bundle (see scripts/build-app.sh)
/// rather than a bare executable — a bare binary's trust is attributed to the
/// parent terminal instead.
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
