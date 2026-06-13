import Foundation
import SwiftUI

extension Color {
    /// Alarm red used for a fired / ringing countdown timer — its readouts, its
    /// island stroke, and its flashing glow. Backed by the `Palette.alarm` token.
    static let timerRing = Palette.alarm
}

/// A pulsing red ring + outer glow drawn around a shape while a timer is
/// ringing. The pulse is driven by a `TimelineView` (deterministic and
/// screenshot-friendly) rather than `withAnimation(...repeatForever())`, which
/// is unreliable inside the non-activating panel. Purely decorative.
struct RingingGlowOverlay<S: Shape>: View {
    let shape: S

    /// Seconds per pulse cycle.
    private let period: Double = 0.85

    /// One-shot "announce" scale that pops the ring the instant it appears
    /// (i.e. the moment a timer fires), then springs to rest.
    @State private var popScale: CGFloat = 0.82

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 2 * .pi / period) // 0…1
            let opacity = 0.35 + 0.65 * pulse
            // Subtle "breathing" — the ring swells a hair in sync with the glow,
            // so it reads as alive rather than a static stroke.
            let breathe = 1.0 + 0.022 * pulse
            shape
                .stroke(Color.timerRing, lineWidth: 1.6)
                .shadow(color: Color.timerRing.opacity(0.9), radius: 7)   // design-lint:allow — pulsing alarm glow (signature effect)
                .shadow(color: Color.timerRing.opacity(0.55), radius: 15) // design-lint:allow — pulsing alarm glow (signature effect)
                .opacity(opacity)
                .scaleEffect(breathe)
                .scaleEffect(popScale)
        }
        .allowsHitTesting(false)
        .onAppear {
            // Overshoots past 1.0 — a quick alarm "pop".
            withAnimation(Motion.pop) {
                popScale = 1.0
            }
        }
    }
}
