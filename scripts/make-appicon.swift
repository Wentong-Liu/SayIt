#!/usr/bin/env swift
//
// make-appicon.swift — 用 AppKit/CoreGraphics 绘制 SayIt 的 App 图标。
//
// 设计：macOS squircle 圆角方底 + 靛蓝→紫的柔和对角渐变；
// 中心一个简洁的白色麦克风字形（胶囊话筒 + 支架 + 底座），
// 两侧对称声波弧线，传达「语音听写」。无文字、高对比、留白克制。
//
// 用法：
//   swift scripts/make-appicon.swift <输出目录>
// 输出 icon_1024.png（1024×1024 主图）到该目录；各尺寸由 sips 降采样。
//
import AppKit
import CoreGraphics

// MARK: - 参数

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: make-appicon.swift <输出目录>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = args[1]
let size: CGFloat = 1024

// MARK: - 颜色（sRGB，靛蓝→紫的现代渐变）

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
let topColor    = srgb(99, 102, 241)   // indigo-500
let bottomColor = srgb(124, 58, 237)   // violet-600

// MARK: - 位图上下文

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("无法创建位图上下文\n".data(using: .utf8)!)
    exit(1)
}

ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// MARK: - 圆角方底（macOS 风格 squircle 近似：连续圆角）
// macOS 图标内容约占画布的 ~80%，四周留透明边距，符合系统模板比例。

let margin: CGFloat = size * 0.08          // 约 82px 边距
let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let corner: CGFloat = rect.width * 0.2237   // Apple squircle 圆角比例近似

let roundedPath = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

ctx.saveGState()
ctx.addPath(roundedPath)
ctx.clip()

// 对角渐变填充（左上偏亮 → 右下偏深）
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [topColor, bottomColor] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY),
    options: []
)

// 顶部柔光高光，增加质感、避免「平」
let highlight = CGGradient(
    colorsSpace: colorSpace,
    colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
             CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    highlight,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.midY),
    options: []
)
ctx.restoreGState()

// MARK: - 中心字形：麦克风 + 声波（全部白色）

let cx = rect.midX
let cy = rect.midY
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

ctx.setFillColor(white)
ctx.setStrokeColor(white)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// — 话筒胶囊体
let micW = rect.width * 0.26
let micH = micW * 1.55
let micRect = CGRect(x: cx - micW / 2,
                     y: cy - micH * 0.18,
                     width: micW,
                     height: micH)
let micPath = CGPath(roundedRect: micRect,
                     cornerWidth: micW / 2, cornerHeight: micW / 2,
                     transform: nil)
ctx.addPath(micPath)
ctx.fillPath()

// — 话筒支架（U 形弧线，环抱话筒底部）
let cradleLine = rect.width * 0.05
ctx.setLineWidth(cradleLine)
let cradleRadius = micW * 0.86
let cradleCenterY = micRect.minY + micW * 0.55
ctx.beginPath()
// 半圆从左到右（下半弧），π 到 2π
ctx.addArc(center: CGPoint(x: cx, y: cradleCenterY),
           radius: cradleRadius,
           startAngle: .pi, endAngle: 2 * .pi,
           clockwise: false)
ctx.strokePath()

// — 支杆 + 底座
let stemTop = cradleCenterY - cradleRadius
let stemBottom = stemTop - rect.height * 0.11
ctx.setLineWidth(cradleLine)
ctx.beginPath()
ctx.move(to: CGPoint(x: cx, y: stemTop))
ctx.addLine(to: CGPoint(x: cx, y: stemBottom))
ctx.strokePath()

// 底座短横
let baseHalf = micW * 0.42
ctx.setLineWidth(cradleLine)
ctx.beginPath()
ctx.move(to: CGPoint(x: cx - baseHalf, y: stemBottom))
ctx.addLine(to: CGPoint(x: cx + baseHalf, y: stemBottom))
ctx.strokePath()

// — 两侧对称声波弧（外扩两道，传达「发声/听写」）
func soundArc(radius: CGFloat, lineWidth: CGFloat, alpha: CGFloat) {
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
    ctx.setLineWidth(lineWidth)
    let center = CGPoint(x: cx, y: cy + micH * 0.06)
    // 右弧：-50° .. 50°
    ctx.beginPath()
    ctx.addArc(center: center, radius: radius,
               startAngle: -50 * .pi / 180, endAngle: 50 * .pi / 180,
               clockwise: false)
    ctx.strokePath()
    // 左弧：130° .. 230°
    ctx.beginPath()
    ctx.addArc(center: center, radius: radius,
               startAngle: 130 * .pi / 180, endAngle: 230 * .pi / 180,
               clockwise: false)
    ctx.strokePath()
}
soundArc(radius: micW * 1.18, lineWidth: rect.width * 0.040, alpha: 0.95)
soundArc(radius: micW * 1.62, lineWidth: rect.width * 0.034, alpha: 0.55)

// MARK: - 导出 PNG

guard let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write("无法生成图像\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("无法编码 PNG\n".data(using: .utf8)!)
    exit(1)
}
let outPath = (outDir as NSString).appendingPathComponent("icon_1024.png")
do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("已生成主图: \(outPath)")
} catch {
    FileHandle.standardError.write("写入失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}
