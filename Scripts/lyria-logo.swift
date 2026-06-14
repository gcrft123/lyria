// Renders a transparent PNG: the Dynamic Island pill with "Lyria" wordmark in a
// pink→purple SF Bold gradient.
//
//   swift Scripts/lyria-logo.swift <output.png> [widthPx]
import AppKit
import CoreText
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: swift Scripts/lyria-logo.swift <output.png> [widthPx]\n", stderr)
    exit(1)
}
let outPath = args[1]
let widthPx = args.count >= 3 ? (Int(args[2]) ?? 1600) : 1600

let aspect: CGFloat = 3.0 / 1.0
let W = CGFloat(widthPx)
let H = (W / aspect).rounded()
let pxW = Int(W), pxH = Int(H)

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("failed to create context\n", stderr); exit(1)
}
ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// 1) The island — a true pill (corner radius = height/2), pure black.
let pill = CGRect(x: 0, y: 0, width: W, height: H)
let radius = H / 2
let pillPath = CGPath(roundedRect: pill, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(pillPath)
ctx.setFillColor(col(0, 0, 0, 1))
ctx.fillPath()
ctx.restoreGState()

// 2) Encode PNG.
guard let image = ctx.makeImage() else { fputs("makeImage failed\n", stderr); exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr); exit(1)
}
let url = URL(fileURLWithPath: outPath)
do {
    try data.write(to: url)
    FileHandle.standardError.write("wrote \(pxW)×\(pxH) → \(outPath)\n".data(using: .utf8)!)
} catch {
    fputs("write failed: \(error)\n", stderr); exit(1)
}
