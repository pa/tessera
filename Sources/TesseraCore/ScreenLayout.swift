import CoreGraphics

/// Main-display bounds in the top-left-origin coordinate space that AX and Core
/// Graphics share. `ScreenGeometry` (app side) builds on this to compute the
/// usable workspace rect; general tiling geometry is the job of `BSPLayout`.
public enum ScreenLayout {
    /// Bounds of the main display, top-left origin. The full display rect — it
    /// does not subtract the menu bar or Dock.
    public static var mainDisplayBounds: CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }
}
