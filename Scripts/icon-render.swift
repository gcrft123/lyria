// Renders the DynamicIsland app icon (1024×1024 PNG) — an on-brand squircle: a
// dark gradient tile with the black "island" pill floating near the centre, lit
// by a soft indigo glow and a small accent camera dot. Run via Scripts/make-icon.sh.
//
//   swift Scripts/icon-render.swift <output.png>
import AppKit
import CoreGraphics

let px = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("failed to create context\n", stderr); exit(1)
}
let W = CGFloat(px)
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}
let indigo = (r: CGFloat(0.62), g: CGFloat(0.55), b: CGFloat(0.98))

ctx.clear(CGRect(x: 0, y: 0, width: W, height: W))

// Rounded-rect "squircle" tile, inset so it has the standard transparent margin.
let margin: CGFloat = 96
let tile = CGRect(x: margin, y: margin, width: W - 2 * margin, height: W - 2 * margin)
let radius = tile.width * 0.2237
let squircle = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Background: vertical charcoal gradient + a soft top highlight.
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: cs,
                    colors: [col(0.17, 0.17, 0.20), col(0.04, 0.04, 0.05)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
let hi = CGGradient(colorsSpace: cs,
                    colors: [col(1, 1, 1, 0.07), col(1, 1, 1, 0)] as CFArray,
                    locations: [0, 1])!
ctx.drawRadialGradient(hi, startCenter: CGPoint(x: W / 2, y: W * 0.70), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: W * 0.70), endRadius: W * 0.52, options: [])
ctx.restoreGState()

// The island pill, centred a touch above the middle.
let pillW = tile.width * 0.50
let pillH = pillW * 0.34
let pillRect = CGRect(x: W / 2 - pillW / 2, y: W / 2 - pillH / 2 + tile.height * 0.03,
                      width: pillW, height: pillH)
let pill = CGPath(roundedRect: pillRect, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)

// Soft indigo glow halo behind the pill.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 80, color: col(indigo.r, indigo.g, indigo.b, 0.9))
ctx.addPath(pill); ctx.setFillColor(col(0, 0, 0, 1)); ctx.fillPath()
ctx.restoreGState()

// Black pill + thin top highlight stroke.
ctx.addPath(pill); ctx.setFillColor(col(0, 0, 0, 1)); ctx.fillPath()
ctx.addPath(pill); ctx.setStrokeColor(col(1, 1, 1, 0.10)); ctx.setLineWidth(3); ctx.strokePath()

// Accent "camera" dot near the right end of the pill.
let dotR = pillH * 0.13
let dot = CGRect(x: pillRect.maxX - pillH * 0.70, y: pillRect.midY - dotR, width: dotR * 2, height: dotR * 2)
ctx.setFillColor(col(indigo.r, indigo.g, indigo.b, 1)); ctx.fillEllipse(in: dot)

guard let image = ctx.makeImage() else { fputs("failed to render\n", stderr); exit(1) }
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: outPath))
