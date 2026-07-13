import CoreGraphics

/// Screen-relative frames in the top-left-origin coordinate space that AX and
/// Core Graphics share.
///
/// This is deliberately minimal — the named half/quarter placements used by the
/// Milestone 1 prototype. General tiling is the job of `BSPLayout`.
public enum ScreenLayout {
    /// Bounds of the main display, top-left origin. Note this is the full
    /// display rect and does not subtract the menu bar; the prototype's
    /// half/quarter targets are computed against the whole display.
    public static var mainDisplayBounds: CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    /// Named placements the prototype offers, computed against the main display.
    public enum Placement: String, CaseIterable, Sendable {
        case leftHalf = "Left Half"
        case rightHalf = "Right Half"
        case topLeftQuarter = "Top-Left Quarter"
        case fullScreen = "Full Screen"

        public func frame(in bounds: CGRect) -> CGRect {
            let halfW = bounds.width / 2
            let halfH = bounds.height / 2
            switch self {
            case .leftHalf:
                return CGRect(x: bounds.minX, y: bounds.minY, width: halfW, height: bounds.height)
            case .rightHalf:
                return CGRect(x: bounds.minX + halfW, y: bounds.minY, width: halfW, height: bounds.height)
            case .topLeftQuarter:
                return CGRect(x: bounds.minX, y: bounds.minY, width: halfW, height: halfH)
            case .fullScreen:
                return bounds
            }
        }
    }
}
