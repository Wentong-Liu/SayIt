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
//     Writes icon_1024.png plus icon_16/32/64/128/256/512.png into <outputDir>.
//   swift scripts/make-appicon.swift menubar <outputDir>
//     Writes menubar_18.png (@1x) and menubar_36.png (@2x): the SAME speech
//     mark in solid opaque black on a transparent canvas, for use as a
//     monochrome macOS menu-bar template image.
//
import AppKit
import CoreGraphics

// MARK: - Colors (sRGB — restrained monochrome: dark ink on off-white)

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let bgTop    = srgb(248, 246, 240)   // warm off-white (subtle top)
let bgBottom = srgb(238, 234, 226)   // warm off-white (subtle bottom)
let ink      = srgb(22, 24, 29)      // near-black mark

let colorSpace = CGColorSpaceCreateDeviceRGB()

// MARK: - Geometry

/// Build the combined "speech mark" path (the bold speech-blob with three
/// negative-space soundwave bars) ready for even-odd filling.
///
/// This is the single source of truth for the mark geometry shared by the
/// full app icon and the monochrome menu-bar template. Given a center and
/// the blob's box dimensions, it reproduces the exact blob + bars built by
/// the original inline code, so callers must fill it with `.evenOdd`.
func speechMarkPath(centerX cx: CGFloat,
                    centerY cy: CGFloat,
                    blobW: CGFloat,
                    blobH: CGFloat,
                    markYOffset: CGFloat) -> CGPath {
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
    return combined
}

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
    // The blob + bars path is built by the shared `speechMarkPath` helper and
    // filled with the even-odd rule so the bars read as crisp negative space.
    let cx = rect.midX
    let cy = rect.midY
    let markYOffset = rect.height * 0.045   // nudge the optical center down a touch

    let blobW = rect.width * 0.62
    let blobH = blobW * 0.86

    let combined = speechMarkPath(centerX: cx,
                                  centerY: cy,
                                  blobW: blobW,
                                  blobH: blobH,
                                  markYOffset: markYOffset)

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

/// Render JUST the speech mark in solid opaque black on a transparent canvas,
/// sized `pointSize * scale` square. This is a macOS menu-bar *template*
/// image: only the alpha channel matters, so AppKit recolors it to fit a
/// light or dark menu bar. No squircle, no gradient, no clip.
func renderMenuBarMark(pointSize: CGFloat, scale: CGFloat) -> CGImage {
    let size = pointSize * scale
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

    // Content rect with only a hairline breathing margin so the mark fills the
    // canvas like neighboring menu-bar icons (WeChat / Messages). The tail
    // extends down-left of the blob box, so the blob box is sized large (0.86)
    // within this inset content rect and re-centered so the overflowing tail
    // stays on-canvas without clipping. Enlarging the whole mark also
    // proportionally thickens the soundwave bars (barWidth = blobW * 0.115 in
    // the shared helper), keeping them legible at 18px @1x.
    //
    // CEILING: the mark's horizontal extent (blobW * 1.16, the tail reaches
    // tailTipX = minX - blobW * 0.16 on the left) is WIDER than its vertical
    // extent, so WIDTH is the binding constraint. With the tail aspect frozen
    // in the shared speechMarkPath helper (which must NOT change — the app icon
    // depends on it), the largest blobW that keeps a positive geometric margin
    // at 18px @1x is ~0.86 (smallest drawn margin ~0.29px; the rasterized
    // alpha-bbox then fills ~89% of the height and is edge-to-edge in width).
    // Pushing blobW past ~0.87-0.88 crowds the right/bottom edge to zero margin
    // and would clip ink, so do not raise it without also reshaping the tail.
    let margin = size * 0.015
    let content = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)

    let blobW = content.width * 0.86
    let blobH = blobW * 0.86
    // markYOffset mirrors the app icon's optical-center nudge, scaled to the
    // content rect rather than the full canvas.
    let markYOffset = content.height * 0.045

    // The mark's drawn extent runs from (cx - blobW/2 - blobW*0.16) on the
    // left (the tail reach) to (cx + blobW/2) on the right, so its midpoint is
    // (cx - blobW*0.08). Shift cx right by blobW*0.08 to center that extent in
    // the content rect, keeping a margin on both the tail and the right edge.
    let cx = content.midX + blobW * 0.08
    let cy = content.midY

    let mark = speechMarkPath(centerX: cx,
                              centerY: cy,
                              blobW: blobW,
                              blobH: blobH,
                              markYOffset: markYOffset)

    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.addPath(mark)
    ctx.fillPath(using: .evenOdd)

    guard let image = ctx.makeImage() else {
        FileHandle.standardError.write("Failed to render menu-bar mark at \(Int(size))px\n".data(using: .utf8)!)
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

// MARK: - Command dispatch

let args = CommandLine.arguments

if args.count >= 3 && args[1] == "menubar" {
    // Menu-bar template mode: write the monochrome glyph at @1x (18pt) and
    // @2x (36pt) into the given output directory.
    let outDir = args[2]
    let menuBarSizes: [(name: String, point: CGFloat, scale: CGFloat)] = [
        ("menubar_18.png", 18, 1),
        ("menubar_36.png", 18, 2),
    ]
    for spec in menuBarSizes {
        let image = renderMenuBarMark(pointSize: spec.point, scale: spec.scale)
        let outPath = (outDir as NSString).appendingPathComponent(spec.name)
        writePNG(image, to: outPath)
    }
} else if args.count >= 2 {
    // Default mode: render the full app icon at every appiconset size.
    let outDir = args[1]
    // All pixel sizes referenced by AppIcon.appiconset/Contents.json.
    let pixelSizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
    for px in pixelSizes {
        // Render each size natively (rather than downsampling one master) so
        // every PNG gets crisp, hinted antialiasing at its target resolution.
        let image = renderIcon(size: CGFloat(px))
        let outPath = (outDir as NSString).appendingPathComponent("icon_\(px).png")
        writePNG(image, to: outPath)
    }
} else {
    FileHandle.standardError.write(
        "Usage: make-appicon.swift <outputDir>\n       make-appicon.swift menubar <outputDir>\n"
            .data(using: .utf8)!)
    exit(2)
}
