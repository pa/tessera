import AppKit
import CoreGraphics
import ApplicationServices

/// Discovers the two kinds of things the palette can act on:
///   • installed applications (scanned from the standard Applications folders), and
///   • on-screen windows (via `CGWindowList`).
@MainActor
enum AppCatalog {
    /// Standard locations macOS keeps `.app` bundles in.
    private static let applicationDirectories: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Installed applications, de-duplicated by bundle id, sorted by name.
    static func installedApplications() -> [PaletteItem] {
        let workspace = NSWorkspace.shared
        let fm = FileManager.default
        var seen = Set<String>()
        var items: [PaletteItem] = []

        for dir in applicationDirectories {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = dir + "/" + entry
                guard let bundle = Bundle(path: path),
                      let bundleID = bundle.bundleIdentifier,
                      !seen.contains(bundleID) else { continue }
                seen.insert(bundleID)

                let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? (entry as NSString).deletingPathExtension

                let icon = workspace.icon(forFile: path)
                icon.size = NSSize(width: 20, height: 20)

                items.append(PaletteItem(
                    id: bundleID,
                    title: name,
                    subtitle: bundleID,
                    icon: icon,
                    bundleID: bundleID,
                    pid: nil,
                    kind: .application
                ))
            }
        }
        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// One row per on-screen application window.
    ///
    /// Prefers the Accessibility tree: reading `kAXTitle` off each window
    /// element gives real titles with only the Accessibility permission Tessera
    /// already requires — no Screen Recording needed. Falls back to
    /// `CGWindowList` when AX isn't trusted yet (titles then degrade to the
    /// owning app's name, per macOS's Screen Recording gate on `kCGWindowName`).
    static func runningWindows() -> [PaletteItem] {
        if AXIsProcessTrusted() {
            let axWindows = accessibilityWindows()
            if !axWindows.isEmpty { return axWindows }
        }
        return cgWindowListWindows()
    }

    /// AX-based window enumeration: walk regular (Dock-present) running apps and
    /// read each window's title and CGWindowID from the Accessibility tree.
    private static func accessibilityWindows() -> [PaletteItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var items: [PaletteItem] = []

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            let ownerName = app.localizedName ?? "App"
            let icon = app.icon
            icon?.size = NSSize(width: 20, height: 20)

            for (index, window) in AppTargeter.windows(of: appElement).enumerated() {
                let title = window.title ?? ""
                let windowID = window.windowID
                let displayTitle = title.isEmpty ? ownerName : title

                items.append(PaletteItem(
                    id: windowID.map { "\(pid):\($0)" } ?? "\(pid):ax\(index)",
                    title: displayTitle,
                    subtitle: ownerName,
                    icon: icon,
                    bundleID: app.bundleIdentifier,
                    pid: pid,
                    kind: .window(windowID: windowID ?? 0)
                ))
            }
        }
        return items
    }

    /// Fallback used before Accessibility is granted.
    private static func cgWindowListWindows() -> [PaletteItem] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var items: [PaletteItem] = []
        for info in raw {
            // Normal application windows sit on layer 0.
            let layer = (info[kCGWindowLayer as String] as? Int) ?? -1
            guard layer == 0 else { continue }

            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let windowNumber = info[kCGWindowNumber as String] as? Int else { continue }

            let owner = (info[kCGWindowOwnerName as String] as? String) ?? "Unknown"
            // kCGWindowName is only populated when Tessera has Screen Recording
            // permission; without it the title is empty. Fall back to the owner
            // app name so the window still lists (titles just get richer once
            // the permission is granted).
            let windowTitle = (info[kCGWindowName as String] as? String) ?? ""
            let displayTitle = windowTitle.isEmpty ? owner : windowTitle
            let subtitle = windowTitle.isEmpty ? "\(owner) · window" : owner

            let runningApp = NSRunningApplication(processIdentifier: pid)
            let icon = runningApp?.icon
            icon?.size = NSSize(width: 20, height: 20)

            items.append(PaletteItem(
                id: "\(pid):\(windowNumber)",
                title: displayTitle,
                subtitle: subtitle,
                icon: icon,
                bundleID: runningApp?.bundleIdentifier,
                pid: pid,
                kind: .window(windowID: CGWindowID(windowNumber))
            ))
        }
        return items
    }

    /// The full catalog the palette opens with: running windows first (most
    /// immediately actionable), then installed apps.
    static func allItems() -> [PaletteItem] {
        runningWindows() + installedApplications()
    }
}
