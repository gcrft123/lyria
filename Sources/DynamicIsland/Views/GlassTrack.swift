import SwiftUI

/// A pill-shaped slider groove rendered with Apple's Liquid Glass material on
/// macOS 26+, falling back to a token fill on older systems. Used ONLY for the
/// custom Tweaks controls (the vertical EQ bands + the centre-origin pan slider),
/// which have no stock `Slider` equivalent to inherit Liquid Glass from. Standard
/// horizontal sliders/toggles/pickers use the stock controls instead.
struct GlassTrack: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Capsule().fill(Color.clear).glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(Palette.surfaceRaised)
        }
    }
}
