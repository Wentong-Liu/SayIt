import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 听写 HUD 的纯定位逻辑（与 AppKit 解耦，便于单测）。
///
/// HUD 默认贴在屏幕中下方；当提供光标点时，改为悬浮在光标上方。两种锚点最终都会被
/// `clamped(_:within:)` 夹紧进可见区，保证面板完整可见、不溢出屏幕边缘。
///
/// 坐标系约定：全部使用 AppKit 全局坐标（原点在主屏左下、y 向上），与 `NSScreen.visibleFrame`
/// / `NSWindow.setFrameOrigin` 同源；调用方负责把 AX/CG 的左上原点坐标在传入前翻转好。
public enum HUDPositioning {
    /// 屏幕中下方锚点：水平居中，底边距可见区底部 `bottomMargin`。
    /// - Parameters:
    ///   - size: HUD 窗口尺寸（点）。
    ///   - vf: 目标屏可见区（AppKit 全局坐标，左下原点）。
    ///   - bottomMargin: HUD 底边与可见区底边的间距。
    /// - Returns: 未夹紧的 HUD 左下角原点（AppKit 全局坐标）。
    public static func bottomCenterOrigin(size: CGSize, within vf: CGRect,
                                          bottomMargin: CGFloat) -> CGPoint {
        let x = vf.minX + (vf.width - size.width) / 2
        let y = vf.minY + bottomMargin
        return CGPoint(x: x, y: y)
    }

    /// 光标上方锚点：水平以光标为中心，底边距光标点上方 `gap`。
    /// - Parameters:
    ///   - cursor: 光标点（AppKit 全局坐标，左下原点）。
    ///   - size: HUD 窗口尺寸（点）。
    ///   - gap: HUD 底边与光标点的垂直间距。
    /// - Returns: 未夹紧的 HUD 左下角原点（AppKit 全局坐标）。
    public static func aboveCursorOrigin(cursor: CGPoint, size: CGSize,
                                         gap: CGFloat) -> CGPoint {
        let x = cursor.x - size.width / 2
        let y = cursor.y + gap
        return CGPoint(x: x, y: y)
    }

    /// 把任意锚点夹紧进可见区 `vf`，保证 HUD 完整可见。
    /// 夹紧规则：x∈[vf.minX, vf.maxX - size.width]、y∈[vf.minY, vf.maxY - size.height]。
    /// 当 HUD 比可见区还大（极端情形）时，下界优先，至少左下角对齐可见区左下角。
    /// - Parameters:
    ///   - origin: 未夹紧的 HUD 左下角原点。
    ///   - size: HUD 窗口尺寸（点）。
    ///   - vf: 目标屏可见区（visibleFrame）。
    /// - Returns: 夹紧后的 HUD 左下角原点。
    public static func clamped(origin: CGPoint, size: CGSize, within vf: CGRect) -> CGPoint {
        let maxX = max(vf.minX, vf.maxX - size.width)
        let maxY = max(vf.minY, vf.maxY - size.height)
        let x = min(max(origin.x, vf.minX), maxX)
        let y = min(max(origin.y, vf.minY), maxY)
        return CGPoint(x: x, y: y)
    }
}
