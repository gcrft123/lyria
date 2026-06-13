import SwiftUI

/// THE standard icon button: a single SF Symbol glyph in a circular surface
/// chip, using the shared `.island` press/hover feel. Every circular icon
/// affordance in the app — reset, navigation chevrons, quick-add, steppers,
/// stage controls — MUST use this so they share one size, color, and feel
/// instead of each view rolling its own (see DESIGN_GUIDELINES.md §8).
///
/// Two sizes from `Layout`: `.standard` (a comfortable 30pt tap target with a
/// 13pt glyph) and `.compact` (24pt / 11pt) for dense rows and minor controls.
struct IconButton: View {
    enum Size { case standard, compact }

    let system: String
    var size: Size = .standard
    /// SF Symbol weight (a few glyphs read better bold, e.g. chevrons).
    var weight: Font.Weight = .semibold
    /// `true` = a FLOATING/detached affordance (solid backing + drop shadow) that
    /// may overlap or sit off an edge; `false` = an inline chip on the island
    /// surface. Use `raised` for things like the pin button straddling a corner.
    var raised: Bool = false
    /// Lit state for a stateful control (brighter glyph).
    var active: Bool = false
    let action: () -> Void

    private var dim: CGFloat { size == .standard ? Layout.iconButton : Layout.iconButtonCompact }
    private var glyph: CGFloat { size == .standard ? IconSize.md : IconSize.sm }

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: glyph, weight: weight))
                .foregroundStyle(active ? Palette.textPrimary : Palette.textHigh)
                .frame(width: dim, height: dim)
                .background(chipBackground)
                .contentShape(Circle())
        }
        .buttonStyle(.island)
    }

    @ViewBuilder private var chipBackground: some View {
        if raised {
            // Solid so it reads as a floating chip even where it hangs off the
            // island onto the desktop behind.
            Circle()
                .fill(Palette.background)
                .overlay(Circle().fill(Palette.surfaceRaised))
                .overlay(Circle().strokeBorder(Palette.stroke, lineWidth: 0.8))
                .raisedShadow()
        } else {
            Circle().fill(Palette.surface)
        }
    }
}
