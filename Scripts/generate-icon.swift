#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output.iconset-dir>\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func renderIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    // Background macOS squircle with deep slate-indigo gradient
    let inset = s * 0.08
    let bgRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = bgRect.width * 0.225
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)

    ctx.saveGState()
    bgPath.addClip()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.28, alpha: 1.0),
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.17, alpha: 1.0)
    ])!
    gradient.draw(in: bgRect, angle: -90)

    // Subtle top menubar strip inside the squircle
    let barHeight = bgRect.height * 0.24
    let barRect = CGRect(x: bgRect.minX, y: bgRect.maxY - barHeight, width: bgRect.width, height: barHeight)
    NSColor.white.withAlphaComponent(0.11).setFill()
    NSBezierPath(rect: barRect).fill()

    // Subtle hairline under the menu bar strip
    NSColor.white.withAlphaComponent(0.18).setFill()
    NSBezierPath(rect: CGRect(x: bgRect.minX, y: barRect.minY, width: bgRect.width, height: max(1, s * 0.008))).fill()

    // Three tiny menubar status dots on the right of the strip
    let smallDotSize = s * 0.045
    let smallDotY = barRect.midY - smallDotSize / 2
    for i in 0..<3 {
        let x = bgRect.maxX - s * 0.12 - CGFloat(i) * (smallDotSize * 1.7)
        let color = i == 0 ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.55)
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: x, y: smallDotY, width: smallDotSize, height: smallDotSize)).fill()
    }
    ctx.restoreGState()

    // Crisp outer rim stroke
    NSColor.white.withAlphaComponent(0.18).setStroke()
    bgPath.lineWidth = max(1, s * 0.012)
    bgPath.stroke()

    // Center white rounded app-tile glyph
    let tileSize = s * 0.42
    let tileRect = CGRect(
        x: (s - tileSize) / 2 - s * 0.03,
        y: bgRect.minY + (bgRect.height - barHeight - tileSize) / 2,
        width: tileSize,
        height: tileSize
    )
    let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: tileSize * 0.24, yRadius: tileSize * 0.24)
    let tileGradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.98, alpha: 1.0),
        NSColor(calibratedWhite: 0.86, alpha: 1.0)
    ])!
    tileGradient.draw(in: tilePath, angle: -90)

    // Subtle bell/envelope lines inside tile
    let lineW = tileRect.width * 0.54
    let lineH = max(1.5, tileRect.height * 0.085)
    NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.38, alpha: 0.85).setFill()
    NSBezierPath(
        roundedRect: CGRect(x: tileRect.midX - lineW / 2, y: tileRect.midY + lineH * 0.6, width: lineW, height: lineH),
        xRadius: lineH / 2,
        yRadius: lineH / 2
    ).fill()
    NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.38, alpha: 0.45).setFill()
    NSBezierPath(
        roundedRect: CGRect(x: tileRect.midX - lineW / 2, y: tileRect.midY - lineH * 1.4, width: lineW * 0.72, height: lineH),
        xRadius: lineH / 2,
        yRadius: lineH / 2
    ).fill()

    // Glowing macOS red badge circle at top-right of the tile
    let badgeSize = s * 0.28
    let badgeRect = CGRect(
        x: tileRect.maxX - badgeSize * 0.46,
        y: tileRect.maxY - badgeSize * 0.46,
        width: badgeSize,
        height: badgeSize
    )

    // Shadow behind badge
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    let badgeGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.28, blue: 0.26, alpha: 1.0),
        NSColor(calibratedRed: 0.88, green: 0.12, blue: 0.15, alpha: 1.0)
    ])!
    badgeGradient.draw(in: NSBezierPath(ovalIn: badgeRect), angle: -90)
    ctx.restoreGState()

    // Crisp "1" inside the badge
    if pixelSize >= 32 {
        let fontSize = badgeSize * 0.64
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let text = "1" as NSString
        let textSize = text.size(withAttributes: attrs)
        let textOrigin = CGPoint(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2 - fontSize * 0.04
        )
        text.draw(at: textOrigin, withAttributes: attrs)
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in entries {
    guard let data = renderIcon(pixelSize: size) else {
        fputs("Failed to render \(filename)\n", stderr)
        exit(1)
    }
    try data.write(to: outputDir.appendingPathComponent(filename))
}
print("Generated iconset at \(outputDir.path)")
