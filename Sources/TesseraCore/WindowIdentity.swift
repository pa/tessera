import Foundation

/// A durable description of a window for persistence. A CG window ID is useful
/// while a WindowServer session lives, but bundle ID and title are retained as
/// restart-safe fallbacks.
public struct WindowIdentity: Codable, Sendable, Equatable {
    public var bundleID: String
    public var title: String
    public var windowID: UInt32?

    public init(bundleID: String, title: String, windowID: UInt32?) {
        self.bundleID = bundleID
        self.title = title
        self.windowID = windowID
    }
}

/// Selects a live window for a persisted identity without reusing candidates.
/// Callers remove the returned candidate before matching the next saved window.
public enum WindowMatcher {
    /// Matching deliberately requires the bundle ID even when CGWindowID agrees:
    /// WindowServer IDs can be recycled after a logout/restart, so an ID alone is
    /// not a durable cross-session identity.
    public static func bestMatchIndex(
        for saved: WindowIdentity,
        in candidates: [WindowIdentity]
    ) -> Int? {
        if let windowID = saved.windowID,
           let index = candidates.firstIndex(where: {
               $0.bundleID == saved.bundleID && $0.windowID == windowID
           }) {
            return index
        }
        guard !saved.bundleID.isEmpty else { return nil }
        if !saved.title.isEmpty,
           let index = candidates.firstIndex(where: {
               $0.bundleID == saved.bundleID && $0.title == saved.title
           }) {
            return index
        }
        return candidates.firstIndex { $0.bundleID == saved.bundleID }
    }
}
