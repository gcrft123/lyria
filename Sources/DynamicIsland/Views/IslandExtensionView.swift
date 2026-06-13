import SwiftUI

/// Renders an `IslandExtension` as a black blob that rides at the island's own
/// height, so it reads as a piece of the island rather than a floating widget.
///
/// A single symbol renders as a circle (width == height); several symbols widen
/// it into a pill. The glyphs and a soft outer glow take the extension's tint.
struct IslandExtensionView: View {
    var model: IslandExtension
    /// The island's current bar height — the extension matches it exactly.
    var height: CGFloat

    /// Glyph point size, scaled to the bar height so it stays proportional as
    /// the island morphs between idle and compact heights.
    private static let iconRatio: CGFloat = 0.32
    /// Spacing between adjacent glyphs in a multi-symbol pill.
    private static let symbolSpacing: CGFloat = 7

    private static func iconSize(for height: CGFloat) -> CGFloat {
        max(11, height * iconRatio)
    }

    /// Width an extension occupies at a given bar height. One symbol → a circle
    /// (width == height); several → a pill sized to fit the glyphs with equal
    /// inset on both ends. Shared with the layout so the island can place the
    /// blob exactly against its edge.
    static func width(for model: IslandExtension, height: CGFloat) -> CGFloat {
        let count = max(1, model.symbols.count)
        guard count > 1 else { return height }
        let icon = iconSize(for: height)
        // End inset mirrors a circle's: half the leftover space around one glyph.
        let endInset = (height - icon) / 2
        return endInset * 2 + CGFloat(count) * icon + CGFloat(count - 1) * symbolSpacing
    }

    var body: some View {
        let icon = Self.iconSize(for: height)
        HStack(spacing: Self.symbolSpacing) {
            ForEach(model.symbols, id: \.self) { symbol in
                Image(systemName: symbol)
            }
        }
        .font(.system(size: icon, weight: .bold))
        .foregroundStyle(model.tint)
        .frame(width: Self.width(for: model, height: height), height: height)
        .background(Capsule().fill(Palette.background))
        .overlay(Capsule().stroke(model.tint.opacity(0.35), lineWidth: 0.8))
        .shellShadow()
    }
}
