import SwiftUI

/// A shape filled with Apple's Liquid Glass material (macOS 26+), falling back to a
/// token surface on older systems. Used as a `.background` for the Music tab bar
/// (a full capsule) and the floating mini-player pill (a rounded rect, so its seek
/// bar can sit on a flat edge). See `GlassTrack` for the slider-groove variant.
struct GlassPill: View {
    /// `nil` → a full `Capsule`; otherwise a continuous rounded rectangle.
    var cornerRadius: CGFloat? = nil

    var body: some View {
        if let cornerRadius {
            glass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            glass(Capsule())
        }
    }

    @ViewBuilder
    private func glass<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *) {
            shape.fill(Color.clear).glassEffect(.regular, in: shape)
        } else {
            shape.fill(Palette.surfaceRaised)
        }
    }
}
