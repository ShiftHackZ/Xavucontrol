#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count >= 4 else {
    fputs("usage: render-dmg-background.swift <output.png> <app-icon.png> <release-label>\n", stderr)
    exit(2)
}

let outputPath = CommandLine.arguments[1]
let iconPath = CommandLine.arguments[2]
let releaseLabel = CommandLine.arguments[3]
let canvasSize = NSSize(width: 720, height: 420)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color textColor: NSColor, alignment: NSTextAlignment = .center, width: CGFloat = 680) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph
    ]
    let rect = NSRect(x: point.x, y: point.y, width: width, height: size + 12)
    NSString(string: text).draw(in: rect, withAttributes: attributes)
}

func drawArrow(from start: NSPoint, to end: NSPoint) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    color(72, 78, 92, 0.82).setStroke()
    path.lineWidth = 4
    path.lineCapStyle = .round
    path.stroke()

    let angle = atan2(end.y - start.y, end.x - start.x)
    let headLength: CGFloat = 16
    let left = NSPoint(
        x: end.x - headLength * cos(angle - .pi / 7),
        y: end.y - headLength * sin(angle - .pi / 7)
    )
    let right = NSPoint(
        x: end.x - headLength * cos(angle + .pi / 7),
        y: end.y - headLength * sin(angle + .pi / 7)
    )
    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: left)
    head.move(to: end)
    head.line(to: right)
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.stroke()
}

let image = NSImage(size: canvasSize)
image.lockFocus()

color(246, 247, 250).setFill()
NSRect(origin: .zero, size: canvasSize).fill()

color(224, 229, 236, 0.82).setStroke()
for x in stride(from: CGFloat(0), through: canvasSize.width, by: 28) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: 0))
    path.line(to: NSPoint(x: x, y: canvasSize.height))
    path.lineWidth = 1
    path.stroke()
}
for y in stride(from: CGFloat(0), through: canvasSize.height, by: 28) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 0, y: y))
    path.line(to: NSPoint(x: canvasSize.width, y: y))
    path.lineWidth = 1
    path.stroke()
}

let panelRect = NSRect(x: 34, y: 34, width: canvasSize.width - 68, height: canvasSize.height - 68)
let panel = NSBezierPath(roundedRect: panelRect, xRadius: 18, yRadius: 18)
color(255, 255, 255, 0.88).setFill()
panel.fill()
color(210, 216, 225, 1).setStroke()
panel.lineWidth = 1
panel.stroke()

if let appIcon = NSImage(contentsOfFile: iconPath) {
    appIcon.draw(in: NSRect(x: 74, y: 242, width: 88, height: 88), from: .zero, operation: .sourceOver, fraction: 1)
}

drawText("Xavucontrol", at: NSPoint(x: 176, y: 291), size: 32, weight: .bold, color: color(26, 25, 29), alignment: .left, width: 440)
drawText(releaseLabel, at: NSPoint(x: 178, y: 266), size: 15, weight: .semibold, color: color(92, 88, 96), alignment: .left, width: 440)
drawText("Drag Xavucontrol to Applications", at: NSPoint(x: 20, y: 76), size: 20, weight: .semibold, color: color(26, 25, 29), width: 680)
drawText("A pavucontrol-inspired audio router for macOS", at: NSPoint(x: 20, y: 51), size: 14, weight: .medium, color: color(92, 88, 96), width: 680)
drawArrow(from: NSPoint(x: 268, y: 210), to: NSPoint(x: 452, y: 210))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("failed to render PNG background\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    fputs("failed to write background: \(error.localizedDescription)\n", stderr)
    exit(1)
}
