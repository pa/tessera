import Foundation

/// User-configurable general settings (everything that isn't a hot key).
/// Persisted to Application Support alongside hotkeys.json / session.json.
struct AppSettings: Codable, Equatable {
    /// Tile gap as a percentage of the screen width, applied to both the outer
    /// margin and the gaps between panes. 0 = flush tiles.
    var paddingPercent: Double

    static let `default` = AppSettings(paddingPercent: 1.0)

    /// Clamp to a sane range so a bad value can't produce absurd gaps.
    static let paddingRange: ClosedRange<Double> = 0...5
}

/// Loads/saves `AppSettings` to `~/Library/Application Support/Tessera/settings.json`.
enum SettingsStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tessera/settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        settings.paddingPercent = min(max(settings.paddingPercent, AppSettings.paddingRange.lowerBound),
                                      AppSettings.paddingRange.upperBound)
        return settings
    }

    static func save(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: url, options: .atomic)
        } catch {
            NSLog("Tessera: failed to save settings: \(error)")
        }
    }
}
