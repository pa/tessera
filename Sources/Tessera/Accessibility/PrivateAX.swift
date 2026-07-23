import ApplicationServices
import CoreGraphics
import Foundation

/// Bridges a window-level `AXUIElement` to its `CGWindowID` — needed to correlate
/// the AX window tree with `CGWindowList` (stable window identity). This uses the
/// undocumented `_AXUIElementGetWindow` symbol that AeroSpace / yabai / Reef also
/// rely on; it's been stable since ~10.10, but it isn't public SDK.
///
/// **Resilience:** the symbol is resolved at **runtime via `dlsym`**, not bound
/// at link time. If a future macOS drops it, `dlsym` returns nil and we fall back
/// to a public-API heuristic (match the window's frame + owner pid against
/// `CGWindowList`) — so Tessera keeps working (degraded but functional) instead
/// of failing to launch on an unresolved symbol.
enum PrivateAX {
    private typealias GetWindowFn = @convention(c)
        (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Resolved once. `RTLD_DEFAULT` ((void*)-2 on macOS) searches every loaded
    /// image — the symbol lives in an already-linked framework.
    private static let getWindow: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            NSLog("Tessera: _AXUIElementGetWindow is unavailable on this macOS; " +
                  "using CGWindowList frame-matching fallback for window identity.")
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    /// The window's `CGWindowID`, or nil if neither path can resolve it.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        if let fn = getWindow {
            var wid = CGWindowID(0)
            if fn(element, &wid) == .success, wid != 0 { return wid }
        }
        return fallbackWindowID(of: element)
    }

    // MARK: - Public-API fallback

    /// Recover a `CGWindowID` without the private symbol: match this AX window's
    /// owner pid + frame against the on-screen window list. Imperfect when one app
    /// has two identically-placed windows, but a reasonable degraded path (only
    /// reached if the private symbol is gone).
    private static func fallbackWindowID(of element: AXUIElement) -> CGWindowID? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0,
              let frame = axFrame(of: element),
              let infos = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if abs(bounds.minX - frame.minX) < 2, abs(bounds.minY - frame.minY) < 2,
               abs(bounds.width - frame.width) < 2, abs(bounds.height - frame.height) < 2 {
                return wid
            }
        }
        return nil
    }

    /// Read an AX element's frame (top-left origin, matching CGWindowList space).
    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
