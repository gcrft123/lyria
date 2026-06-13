import SwiftUI

/// A subtle, springy button style shared by every tappable control in the
/// island. It keeps the flat look of `.plain` (no system button chrome — it
/// only ever draws `configuration.label`) but adds the little life a Dynamic
/// Island wants:
///
///   - **hover** gently swells the control and lifts its opacity, so the
///     pointer feels like it's "picking up" the glyph;
///   - **press** dips it back down with a snappier spring, giving a tactile
///     squish-and-release.
///
/// Both reactions are springs (no linear easing) so quick double-taps and
/// hover flicks overlap and settle naturally instead of queueing.
///
/// `.onHover` only fires while the panel is capturing mouse events, which is
/// exactly when buttons are on screen (the expanded card), so no extra plumbing
/// is needed — the panel already flips `ignoresMouseEvents` off while hovered.
struct IslandButtonStyle: ButtonStyle { // design-lint:allow — THE sanctioned base button style; do not add others
    /// Scale at rest while the pointer is over the control.
    var hoverScale: CGFloat = 1.10
    /// Scale while the control is held down.
    var pressScale: CGFloat = 0.90
    /// Extra opacity added on hover (the label's own opacity is the floor).
    var hoverOpacityBoost: Double = 0.0

    func makeBody(configuration: Configuration) -> some View {
        IslandButton(configuration: configuration,
                     hoverScale: hoverScale,
                     pressScale: pressScale,
                     hoverOpacityBoost: hoverOpacityBoost)
    }

    /// The inner view exists so we can own a `@State` hover flag per button —
    /// `ButtonStyle.makeBody` runs once per button, so each gets its own.
    private struct IslandButton: View {
        let configuration: Configuration
        let hoverScale: CGFloat
        let pressScale: CGFloat
        let hoverOpacityBoost: Double

        @State private var hovering = false

        private var scale: CGFloat {
            if configuration.isPressed { return pressScale }
            return hovering ? hoverScale : 1
        }

        var body: some View {
            configuration.label
                .opacity(hovering ? min(1, 1 + hoverOpacityBoost) : 1)
                .brightness(hovering && !configuration.isPressed ? 0.06 : 0)
                .scaleEffect(scale)
                .animation(Motion.hover, value: hovering)
                .animation(Motion.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == IslandButtonStyle {
    /// `.buttonStyle(.island)` — the default island control feel.
    static var island: IslandButtonStyle { IslandButtonStyle() }

    /// A gentler variant for large/primary controls (e.g. the transport
    /// play button) where a big swell would feel heavy.
    static var islandSubtle: IslandButtonStyle {
        IslandButtonStyle(hoverScale: 1.06, pressScale: 0.93)
    }

    /// No swell at all — just the faint brightness lift on hover (and a tiny
    /// press dip). For WIDE/TEXT rows like the dashboard card headers, where
    /// scaling the whole row reads as too much.
    static var islandFlat: IslandButtonStyle {
        IslandButtonStyle(hoverScale: 1.0, pressScale: 0.98)
    }
}
