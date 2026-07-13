import AppKit
import CoreGraphics
import TesseraCore

/// Bridges the two coordinate spaces Tessera has to live between:
///   • AX / Core Graphics — top-left origin, y-down (where window moves happen).
///   • AppKit `NSWindow`  — bottom-left origin, y-up (where overlay/palette
///     panels get placed).
///
/// The BSP engine and `AXWindow` work in the AX space; whenever we position an
/// `NSWindow` (empty-pane overlay, palette) at one of those rects, it must be
/// flipped through here first.
enum ScreenGeometry {
    /// Height of the primary display in the top-left CG space — the pivot for
    /// flipping between the two y-axes.
    static var primaryHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    /// The main display's usable area (menu bar and Dock excluded) in AX
    /// top-left space, ready to hand to the BSP engine as the workspace rect.
    static var mainUsableBounds: CGRect {
        guard let screen = NSScreen.main else { return ScreenLayout.mainDisplayBounds }
        let visible = screen.visibleFrame // AppKit bottom-left
        return CGRect(
            x: visible.minX,
            y: primaryHeight - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }

    /// Convert an AX top-left rect into an AppKit bottom-left global rect for
    /// `NSWindow.setFrame(_:display:)`.
    static func appKitRect(fromAX rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
