#if canImport(AppKit)
import AppKit
import SwiftUI

/// 听写状态 HUD 的控制器：管理一个 borderless、不抢焦点的悬浮面板，展示「聆听中 / 识别中 / 出错」。
///
/// 面板特性：
/// - `NSPanel(.borderless, .nonactivatingPanel)`，level `.floating`，透明背景、无阴影边框
///   （阴影由 SwiftUI 卡片自绘，透明外边距 `shadowPad` 留出渲染空间）。
/// - `.nonactivatingPanel` 不抢前台焦点，HUD 弹出时用户仍在原 app 里输入。
/// - 内容用 SwiftUI（`RecordingPanelView`）经 `NSHostingView` 包装。
///
/// 定位：默认屏幕中下方；调用方传入光标点时改为悬浮在光标上方。两者都经 `HUDPositioning.clamped`
/// 夹紧进可见区。
///
/// 生命周期 API：`show(state:near:)` / `update(state:)` / `update(level:)` / `hide()`。
/// 传入 `.idle` 等价于 `hide()`（不展示）。
@MainActor
public final class RecordingPanelController {
    /// 进程级共享实例（HUD 全局唯一）。
    public static let shared = RecordingPanelController()

    /// 面板布局常量。
    private enum Layout {
        /// 屏幕中下方锚点：底边距可见区底部的间距。
        static let bottomMargin: CGFloat = 80
        /// 光标上方锚点：HUD 底边与光标点的间距。
        static let cursorGap: CGFloat = 24
        /// 新建面板时的初始尺寸（建后即按内容 relayout）。
        static let initialSize = NSSize(width: 160, height: 56)
        /// 取不到屏 visibleFrame 时的兜底矩形。
        static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        /// 取不到主屏高度时的兜底（CG/AppKit 全局 y 翻转基准）。
        static let fallbackPrimaryHeight: CGFloat = 1000
    }

    private var panel: NSPanel?
    private let model = RecordingPanelModel()
    /// 本次展示采用的锚点：nil 表示屏幕中下方，非 nil 表示光标点（AppKit 全局坐标）。
    private var anchorCursor: CGPoint?

    public init() {}

    // MARK: - Public API

    /// 展示 HUD 并设置初始状态。
    /// - Parameters:
    ///   - state: 初始状态；`.idle` 等价于 `hide()`（不展示）。
    ///   - cursorPoint: 可选光标点（AppKit 全局坐标，左下原点）。非 nil 时 HUD 悬浮其上方，
    ///     否则定位到屏幕中下方。
    public func show(state: RecordingState, near cursorPoint: CGPoint? = nil) {
        guard state.isVisible else { hide(); return }
        anchorCursor = cursorPoint
        model.state = state
        if panel == nil {
            buildPanel()
        }
        relayout()
        panel?.orderFrontRegardless()
    }

    /// 更新 HUD 状态（面板未展示时自动以中下方锚点弹出；`.idle` 则隐藏）。
    public func update(state: RecordingState) {
        guard state.isVisible else { hide(); return }
        model.state = state
        if panel == nil {
            show(state: state)
        } else {
            // 状态变化可能改变文案宽度，重新测尺寸并保持锚点定位。
            relayout()
        }
    }

    /// 更新归一化输入电平（0...1），驱动聆听态波形指示。不触发重定位（仅刷新条高）。
    public func update(level: Double) {
        model.level = min(max(level, 0), 1)
    }

    /// 当前归一化输入电平（0...1）。供编排层测试断言「每会话电平已转发到 HUD」。
    public var currentLevel: Double { model.level }

    /// 隐藏并销毁面板。
    public func hide() {
        model.state = .idle
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // MARK: - Panel building / layout

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Layout.initialSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.ignoresMouseEvents = true          // HUD 仅展示，不拦截点击（用户照常操作下方 app）
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: RecordingPanelView(model: model))
        panel = p
    }

    /// 按当前内容测自然尺寸，设置面板尺寸并夹紧定位。
    private func relayout() {
        guard let panel else { return }

        // 测自然尺寸（含 2*shadowPad 外边距）。
        let measure = NSHostingView(rootView: RecordingPanelView(model: model))
        measure.layout()
        let natural = measure.fittingSize
        let size = NSSize(width: max(natural.width, Layout.initialSize.width),
                          height: max(natural.height, Layout.initialSize.height))

        let screen = screenForAnchor() ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? Layout.fallbackVisibleFrame

        let base: CGPoint
        if let cursor = anchorCursor {
            base = HUDPositioning.aboveCursorOrigin(cursor: cursor, size: size, gap: Layout.cursorGap)
        } else {
            base = HUDPositioning.bottomCenterOrigin(size: size, within: vf,
                                                     bottomMargin: Layout.bottomMargin)
        }
        let origin = HUDPositioning.clamped(origin: base, size: size, within: vf)

        panel.setContentSize(size)
        panel.setFrameOrigin(origin)
    }

    /// 锚点所在屏：有光标点时取包含该点的屏，否则取主屏。
    private func screenForAnchor() -> NSScreen? {
        guard let cursor = anchorCursor else { return NSScreen.main }
        return NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
    }
}
#endif
