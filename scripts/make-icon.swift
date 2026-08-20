#!/usr/bin/env swift
// Generates the JBar app icon as a 1024×1024 PNG (rounded-square gradient, bold "J", magnifier ring).
// Usage: swift scripts/make-icon.swift Resources/icon.png
// The .icns is then produced by scripts/build-app.sh (sips + iconutil). Pure AppKit, no dependencies.
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/icon.png"
let size: CGFloat = 1024
// Draw into an explicit 1024-px bitmap (lockFocus on an NSImage would use the screen's 2× scale).
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("could not create bitmap") }
rep.size = NSSize(width: size, height: size)
guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no graphics context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// macOS icon grid: 824 pt rounded square centred in the 1024 canvas, ~22.4 % corner radius.
let inset: CGFloat = 100
let squircle = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
                            xRadius: 185, yRadius: 185)
// Soft shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.55, alpha: 1).setFill()
squircle.fill()
ctx.restoreGState()
// Gradient fill.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.62, alpha: 1),
])!
gradient.draw(in: squircle, angle: -70)
// Subtle top highlight.
let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.0), NSColor.white.withAlphaComponent(0.22)])!
squircle.addClip()
highlight.draw(in: NSRect(x: inset, y: size / 2, width: size - 2 * inset, height: size / 2 - inset), angle: 90)
ctx.resetClip()

// Magnifier ring (bottom-right) behind the glyph.
ctx.saveGState()
squircle.addClip()
let ring = NSBezierPath(ovalIn: NSRect(x: 430, y: 250, width: 330, height: 330))
ring.lineWidth = 48
NSColor.white.withAlphaComponent(0.28).setStroke()
ring.stroke()
let handle = NSBezierPath()
handle.move(to: NSPoint(x: 720, y: 290))
handle.line(to: NSPoint(x: 860, y: 150))
handle.lineWidth = 64
handle.lineCapStyle = .round
handle.stroke()
ctx.restoreGState()

// Bold "J".
let font = NSFont.systemFont(ofSize: 620, weight: .heavy)
let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: para]
let text = NSAttributedString(string: "J", attributes: attrs)
let textSize = text.size()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
text.draw(in: NSRect(x: 0, y: (size - textSize.height) / 2 + 30, width: size, height: textSize.height))
ctx.restoreGState()
gctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("could not encode PNG") }
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
} catch {
    fatalError("write failed: \(error)")
}
