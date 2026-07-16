import Foundation
import TesseraCore

/// A window's durable identity for session restore. Window IDs and pids don't
/// survive a restart, so matching falls back to bundle id + title.
struct SavedWindow: Codable {
    var bundleID: String
    var title: String
    var windowID: UInt32?
}

struct SavedFloating: Codable {
    var window: SavedWindow
    var frame: CGRect
}

/// A tab's saved layout: the BSP tree plus the window occupying each pane and
/// any floating windows.
struct SavedTab: Codable {
    var tree: LayoutTree
    var occupants: [Int: SavedWindow]   // PaneID.value → window
    var floating: [SavedFloating]
    var stacked: Bool
}

struct SavedSession: Codable {
    var version: Int
    var activeTabIndex: Int
    var tabs: [SavedTab]
}

/// Loads/saves the workspace layout to Application Support so it can be restored
/// after a quit or reboot.
enum SessionStore {
    static let currentVersion = 1

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tessera/session.json")
    }

    static func load() -> SavedSession? {
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              session.version == currentVersion else { return nil }
        return session
    }

    static func save(_ session: SavedSession) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(session)
            // Atomic write so a crash mid-save can't corrupt the file.
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Tessera: failed to save session: \(error)")
        }
    }
}
