import SwiftUI

/// The volume / brightness overlay shown when a `SystemHUD` takes over the
/// island (`IslandMode.hud`), replacing the system's own on-screen HUD: a
/// leading glyph and a filled bar, laid out inside the fully-rounded pill.
///
/// Purely visual — it's driven entirely by the `SystemHUDProvider`, which
/// intercepts the hardware keys and applies the change. The bar animates so a
/// run of key-presses reads as one smooth slide rather than discrete jumps.
struct HUDView: View {
    let hud: SystemHUD

    var body: some View {
        HStack(spacing: Spacing.xl) {
            Image(systemName: hud.symbol)
                .font(.system(size: IconSize.lg, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                // Fixed width so the bar doesn't shift as the glyph swaps
                // between the 1/2/3-wave speakers.
                .frame(width: 24, alignment: .center)

            bar
        }
        .padding(.horizontal, Layout.insetH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bar: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.surfaceStrong)
                Capsule()
                    .fill(Palette.textPrimary)
                    // Floor at the bar height so a near-zero level still reads as
                    // a rounded nub rather than vanishing.
                    .frame(width: max(h, w * hud.fill))
            }
            .animation(Motion.transition, value: hud.fill)
        }
        .frame(height: 6)
    }
}
