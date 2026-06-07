import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure positioning logic for the dictation HUD (decoupled from AppKit, for easy unit testing).
///
/// The HUD defaults to the lower-center of the screen; when a cursor point is provided, it instead floats above the cursor. Both anchors are finally
/// clamped into the visible region by `clamped(_:within:)`, guaranteeing the panel is fully visible and does not overflow the screen edge.
///
/// Coordinate-system convention: everything uses AppKit global coordinates (origin at the main screen's bottom-left, y upward), consistent with `NSScreen.visibleFrame`
/// / `NSWindow.setFrameOrigin`; the caller is responsible for flipping AX/CG top-left-origin coordinates before passing them in.
public enum HUDPositioning {
    /// Lower-center screen anchor: horizontally centered, the bottom edge `bottomMargin` from the bottom of the visible region.
    /// - Parameters:
    ///   - size: the HUD window size (points).
    ///   - vf: the target screen's visible region (AppKit global coordinates, bottom-left origin).
    ///   - bottomMargin: the spacing of the HUD's bottom edge from the bottom edge of the visible region.
    /// - Returns: the unclamped bottom-left origin of the HUD (AppKit global coordinates).
    public static func bottomCenterOrigin(size: CGSize, within vf: CGRect,
                                          bottomMargin: CGFloat) -> CGPoint {
        let x = vf.minX + (vf.width - size.width) / 2
        let y = vf.minY + bottomMargin
        return CGPoint(x: x, y: y)
    }

    /// Above-cursor anchor: horizontally centered on the cursor, the bottom edge `gap` above the cursor point.
    /// - Parameters:
    ///   - cursor: the cursor point (AppKit global coordinates, bottom-left origin).
    ///   - size: the HUD window size (points).
    ///   - gap: the vertical spacing of the HUD's bottom edge from the cursor point.
    /// - Returns: the unclamped bottom-left origin of the HUD (AppKit global coordinates).
    public static func aboveCursorOrigin(cursor: CGPoint, size: CGSize,
                                         gap: CGFloat) -> CGPoint {
        let x = cursor.x - size.width / 2
        let y = cursor.y + gap
        return CGPoint(x: x, y: y)
    }

    /// Clamps an arbitrary anchor into the visible region `vf`, guaranteeing the HUD is fully visible.
    /// Clamping rule: x in [vf.minX, vf.maxX - size.width], y in [vf.minY, vf.maxY - size.height].
    /// When the HUD is larger than the visible region (extreme case), the lower bound takes priority, so at least the bottom-left corner aligns with the visible region's bottom-left.
    /// - Parameters:
    ///   - origin: the unclamped bottom-left origin of the HUD.
    ///   - size: the HUD window size (points).
    ///   - vf: the target screen's visible region (visibleFrame).
    /// - Returns: the clamped bottom-left origin of the HUD.
    public static func clamped(origin: CGPoint, size: CGSize, within vf: CGRect) -> CGPoint {
        let maxX = max(vf.minX, vf.maxX - size.width)
        let maxY = max(vf.minY, vf.maxY - size.height)
        let x = min(max(origin.x, vf.minX), maxX)
        let y = min(max(origin.y, vf.minY), maxY)
        return CGPoint(x: x, y: y)
    }
}
