#!/usr/bin/env swift
//
// render-icon.swift — draws linkC's app icon programmatically with CoreGraphics and writes
// the standard macOS iconset PNGs (16…1024 px) into an .iconset folder. `make-icon.sh` then
// wraps the folder with `iconutil -c icns`. No dependencies, no running NSApplication — it
// renders straight into bitmap contexts, so it works headless.
//
// Usage:  swift scripts/render-icon.swift <output.iconset>
//
// Design: a dark "glass" macOS rounded-rect tile with the coral stacked-layers mark, matching
// the app's identity (near-black #1B1B1E, Claude coral #D97757, flat and modern).
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

// Background: near-black #1B1B1E with a subtle vertical gradient (lighter top, darker bottom).
let bgTop = (r: 0.145, g: 0.145, b: 0.161)   // ~#252529
let bgBottom = (r: 0.086, g: 0.086, b: 0.098) // ~#161619
// Glyph: Claude coral #D97757.
let coral = (r: 0.851, g: 0.467, b: 0.341)

// MARK: - Geometry helpers

func unit(from a: CGPoint, to b: CGPoint) -> CGVector {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = max(0.0001, (dx * dx + dy * dy).squareRoot())
    return CGVector(dx: dx / len, dy: dy / len)
}

/// A closed path through `points` with each corner rounded by `radius`, using quad curves that
/// pull toward the original vertex. Used for the soft rounded diamonds of the stack.
func roundedPath(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n = points.count
    for i in 0..<n {
        let curr = points[i]
        let prev = points[(i - 1 + n) % n]
        let next = points[(i + 1) % n]
        let toPrev = unit(from: curr, to: prev)
        let toNext = unit(from: curr, to: next)
        let p1 = CGPoint(x: curr.x + toPrev.dx * radius, y: curr.y + toPrev.dy * radius)
        let p2 = CGPoint(x: curr.x + toNext.dx * radius, y: curr.y + toNext.dy * radius)
        if i == 0 { path.move(to: p1) } else { path.addLine(to: p1) }
        path.addQuadCurve(to: p2, control: curr)
    }
    path.closeSubpath()
    return path
}

// MARK: - Render

func makeIcon(pixels: Int) -> CGImage {
    let s = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create bitmap context at \(pixels)px") }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Background tile: macOS-style rounded rect (continuous ~22.4% corner radius).
    let tile = CGRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.2237
    let bgPath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // Vertical gradient fill (lighter top → darker bottom).
    let grad = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: bgTop.r, green: bgTop.g, blue: bgTop.b, alpha: 1),
            CGColor(red: bgBottom.r, green: bgBottom.g, blue: bgBottom.b, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // Faint inner rim for glass edge, plus a stronger highlight along the top edge only.
    let rimWidth = max(1, s * 0.006)
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.04))
    ctx.setLineWidth(rimWidth)
    ctx.strokePath()

    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: s * 0.55, width: s, height: s * 0.45))
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    ctx.setLineWidth(rimWidth)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState() // drop the tile clip; the glyph sits well inside the tile

    // Stacked-layers glyph: three rounded diamonds, centered, coral. Front (lowest) is opaque
    // with a soft shadow; two dimmer plates recede upward behind it.
    let cx = s / 2, cy = s / 2
    let plateW = s * 0.55        // glyph occupies ~55% of the canvas width
    let plateH = s * 0.30
    let step = s * 0.11          // vertical offset between plates
    let corner = s * 0.05

    func diamond(centerY: CGFloat) -> CGPath {
        roundedPath([
            CGPoint(x: cx, y: centerY + plateH / 2),      // top
            CGPoint(x: cx + plateW / 2, y: centerY),      // right
            CGPoint(x: cx, y: centerY - plateH / 2),      // bottom
            CGPoint(x: cx - plateW / 2, y: centerY),      // left
        ], radius: corner)
    }

    func fill(_ path: CGPath, alpha: CGFloat, shadow: Bool) {
        ctx.saveGState()
        if shadow {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -s * 0.010),
                blur: s * 0.028,
                color: CGColor(gray: 0, alpha: 0.35)
            )
        }
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: coral.r, green: coral.g, blue: coral.b, alpha: alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }

    fill(diamond(centerY: cy + step), alpha: 0.55, shadow: false) // back
    fill(diamond(centerY: cy), alpha: 0.75, shadow: false)        // middle
    fill(diamond(centerY: cy - step), alpha: 1.00, shadow: true)  // front

    guard let image = ctx.makeImage() else { fatalError("could not render image at \(pixels)px") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG for \(url.lastPathComponent)")
    }
    do {
        try data.write(to: url)
    } catch {
        fatalError("could not write \(url.path): \(error)")
    }
}

// MARK: - Main

let args = CommandLine.arguments
let outputDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "linkC.iconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// The standard iconset entries → pixel size for each. Distinct sizes: 16/32/64/128/256/512/1024.
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

var cache: [Int: CGImage] = [:]
for entry in entries {
    let image = cache[entry.pixels] ?? makeIcon(pixels: entry.pixels)
    cache[entry.pixels] = image
    writePNG(image, to: outputDir.appendingPathComponent(entry.name))
}

print("==> Rendered \(entries.count) PNGs into \(outputDir.path)")
