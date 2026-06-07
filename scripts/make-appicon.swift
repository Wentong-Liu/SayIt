#!/usr/bin/env swift
//
// make-appicon.swift — Draw SayIt's app icon with AppKit/CoreGraphics.
//
// Design (T25 redesign — abstract & minimal):
//   A single bold, abstract monochrome speech mark on a rounded-square
//   off-white field. The mark is a chunky rounded speech-blob (evoking a
//   voice / speech bubble) with three negative-space soundwave bars carved
//   out of it — reading as "voice / dictation" without any literal
//   microphone. Flat, high-contrast, no text, legible at 16px. Near-black
//   ink (#16181D) on warm off-white (#F8F6F0). This is our own distinct
//   mark, not a copy of any other product's icon.
//
// The whole mark is rendered at high resolution and downsampled to every
// macOS appiconset size, so the script is self-contained (no external
// sips step required).
//
// Usage:
//   swift scripts/make-appicon.swift <outputDir>
// Writes icon_1024.png plus icon_16/32/64/128/256/512.png into <outputDir>.
//
import AppKit
import CoreGraphics

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("Usage: make-appicon.swift <outputDir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = args[1]

// MARK: - Colors (sRGB — restrained monochrome: dark ink on off-white)

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let bgTop    = srgb(248, 246, 240)   // warm off-white (subtle top)
let bgBottom = srgb(238, 234, 226)   // warm off-white (subtle bottom)
let ink      = srgb(22, 24, 29)      // near-black mark

let colorSpace = CGColorSpaceCreateDeviceRGB()

// MARK: - Drawing

/// Render the full icon at the given pixel size into a fresh bitmap and
/// return the resulting CGImage. Everything is expressed as a ratio of
/// `size` so it scales crisply to any resolution.
func renderIcon(size: CGFloat) -> CGImage {
    guard let ctx = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write("Failed to create bitmap context\n".data(using: .utf8)!)
        exit(1)
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Rounded-square field (macOS-style squircle approximation). Content
    // occupies ~84% of the canvas with a transparent margin, matching the
    // system icon template proportions.
    let margin = size * 0.08
    let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let corner = rect.width * 0.2237   // Apple squircle corner ratio approximation
    let roundedPath = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(roundedPath)
    ctx.clip()

    // Soft vertical gradient on the off-white field for a non-flat feel.
    let bgGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [bgTop, bgBottom] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )
    ctx.restoreGState()

    // The mark: a bold abstract speech-blob with carved soundwave bars.
    // We build the solid blob path, then SUBTRACT three rounded bars using
    // the even-odd fill rule so the bars read as crisp negative space.
    let cx = rect.midX
    let cy = rect.midY
    let markYOffset = rect.height * 0.045   // nudge the optical center down a touch

    let blobW = rect.width * 0.62
    let blobH = blobW * 0.86
    let blobRect = CGRect(x: cx - blobW / 2,
                          y: cy - blobH / 2 + markYOffset,
                          width: blobW,
                          height: blobH)
    let r = blobW * 0.30   // generous corner radius for a soft, bold form

    let minX = blobRect.minX, maxX = blobRect.maxX
    let minY = blobRect.minY, maxY = blobRect.maxY

    // Tail tip extends down-left from the bottom-left corner — a speech tail.
    let tailTipX = minX - blobW * 0.16
    let tailTipY = minY - blobH * 0.20

    let blob = CGMutablePath()
    blob.move(to: CGPoint(x: minX, y: maxY - r))
    // top-left corner
    blob.addArc(tangent1End: CGPoint(x: minX, y: maxY),
                tangent2End: CGPoint(x: minX + r, y: maxY),
                radius: r)
    // top edge -> top-right corner
    blob.addLine(to: CGPoint(x: maxX - r, y: maxY))
    blob.addArc(tangent1End: CGPoint(x: maxX, y: maxY),
                tangent2End: CGPoint(x: maxX, y: maxY - r),
                radius: r)
    // right edge -> bottom-right corner
    blob.addLine(to: CGPoint(x: maxX, y: minY + r))
    blob.addArc(tangent1End: CGPoint(x: maxX, y: minY),
                tangent2End: CGPoint(x: maxX - r, y: minY),
                radius: r)
    // bottom edge toward the tail
    blob.addLine(to: CGPoint(x: minX + blobW * 0.30, y: minY))
    // sweep down into the tail tip, then back up the left edge — a soft swoosh
    blob.addQuadCurve(to: CGPoint(x: tailTipX, y: tailTipY),
                      control: CGPoint(x: minX + blobW * 0.02, y: minY - blobH * 0.04))
    blob.addQuadCurve(to: CGPoint(x: minX, y: minY + blobH * 0.34),
                      control: CGPoint(x: minX + blobW * 0.02, y: minY + blobH * 0.06))
    // left edge -> back to start (close)
    blob.addLine(to: CGPoint(x: minX, y: maxY - r))
    blob.closeSubpath()

    // Negative-space soundwave bars: three vertical rounded bars centered in
    // the blob, tall in the middle and short on the sides (a waveform).
    func barPath(centerX: CGFloat, halfHeight: CGFloat, width: CGFloat) -> CGPath {
        let bar = CGRect(x: centerX - width / 2,
                         y: (cy + markYOffset) - halfHeight,
                         width: width,
                         height: halfHeight * 2)
        return CGPath(roundedRect: bar, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
    }

    let barWidth = blobW * 0.115
    let gap = blobW * 0.205
    let h1 = blobH * 0.16   // short
    let h2 = blobH * 0.30   // tall (center)
    let h3 = blobH * 0.16   // short

    let bars = CGMutablePath()
    bars.addPath(barPath(centerX: cx - gap, halfHeight: h1, width: barWidth))
    bars.addPath(barPath(centerX: cx,       halfHeight: h2, width: barWidth))
    bars.addPath(barPath(centerX: cx + gap, halfHeight: h3, width: barWidth))

    let combined = CGMutablePath()
    combined.addPath(blob)
    combined.addPath(bars)

    ctx.saveGState()
    ctx.setFillColor(ink)
    ctx.addPath(combined)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else {
        FileHandle.standardError.write("Failed to render image at \(Int(size))px\n".data(using: .utf8)!)
        exit(1)
    }
    return image
}

// MARK: - Export

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode PNG: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    } catch {
        FileHandle.standardError.write("Write failed (\(path)): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// All pixel sizes referenced by AppIcon.appiconset/Contents.json.
let pixelSizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
for px in pixelSizes {
    // Render each size natively (rather than downsampling one master) so
    // every PNG gets crisp, hinted antialiasing at its target resolution.
    let image = renderIcon(size: CGFloat(px))
    let outPath = (outDir as NSString).appendingPathComponent("icon_\(px).png")
    writePNG(image, to: outPath)
}
