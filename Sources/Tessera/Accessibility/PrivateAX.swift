import ApplicationServices
import CoreGraphics

/// Private Core Accessibility bridge: map a window-level `AXUIElement` to its
/// `CGWindowID`. This is the same undocumented symbol AeroSpace / yabai / Reef
/// rely on to correlate the AX window tree with `CGWindowList`. It's stable in
/// practice but not part of the public SDK, so it's isolated here.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError
