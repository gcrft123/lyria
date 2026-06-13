import AppKit
import SwiftUI

/// Derives a vivid accent colour from album artwork for the island's glow.
enum ArtworkColor {

    /// Average the artwork down to a single pixel, then push saturation and
    /// brightness so the resulting glow reads as colourful rather than muddy.
    static func accent(from image: NSImage, fallback: Color = Color(red: 0.95, green: 0.2, blue: 0.45)) -> Color {
        guard let average = averageColor(of: image)?.usingColorSpace(.sRGB) else { return fallback }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let boosted = NSColor(hue: h,
                              saturation: min(1.0, s * 1.5 + 0.15),
                              brightness: min(1.0, max(b, 0.65)),
                              alpha: 1.0)
        return Color(boosted)
    }

    private static func averageColor(of image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixel,
                                  width: 1, height: 1,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return NSColor(red: CGFloat(pixel[0]) / 255.0,
                       green: CGFloat(pixel[1]) / 255.0,
                       blue: CGFloat(pixel[2]) / 255.0,
                       alpha: 1.0)
    }
}
