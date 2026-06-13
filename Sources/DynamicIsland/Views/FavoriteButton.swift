import SwiftUI

/// A heart "favorite" toggle for the current song, with a celebratory animation
/// when it's turned ON: the heart springs up with a pop, swaps to a filled red
/// glyph, and a ring of little particles bursts outward and fades. Turning it off
/// just settles back. Used in both the full player and the dashboard mini player.
///
/// `isFavorited` is the source of truth (driven by the now-playing state); the
/// animation fires whenever it flips to `true`, so it celebrates both a tap here
/// and a favorite made elsewhere.
struct FavoriteButton: View {
    let isFavorited: Bool
    /// Glyph point size.
    var size: CGFloat = 16
    let action: () -> Void

    private let heartColor = Palette.favorite
    private let particleCount = 8

    @State private var pop: CGFloat = 1
    @State private var burst = false
    @State private var burstProgress: CGFloat = 0

    var body: some View {
        Button(action: action) {
            ZStack {
                if burst {
                    ForEach(0..<particleCount, id: \.self) { index in
                        let angle = Double(index) / Double(particleCount) * 2 * .pi
                        Circle()
                            .fill(heartColor)
                            .frame(width: 3.5, height: 3.5)
                            .scaleEffect(max(0.001, 1 - burstProgress))
                            .opacity(Double(1 - burstProgress))
                            .offset(x: cos(angle) * Double(burstProgress) * Double(size + 4),
                                    y: sin(angle) * Double(burstProgress) * Double(size + 4))
                    }
                }
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(isFavorited ? AnyShapeStyle(heartColor) : AnyShapeStyle(Palette.textSecondary))
                    .scaleEffect(pop)
            }
            .frame(width: size + 18, height: size + 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.island)
        .onChange(of: isFavorited) { nowFavorited in
            if nowFavorited { celebrate() }
        }
    }

    private func celebrate() {
        // Heart pop: a snappy spring up, then settle back on the next tick.
        pop = 1
        withAnimation(.spring(response: 0.16, dampingFraction: 0.42)) { pop = 1.45 } // design-lint:allow — favorite-heart burst (signature effect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) { pop = 1 } // design-lint:allow — favorite-heart burst (signature effect)
        }
        // Particle ring: emit, fly out + fade, then clear.
        burst = true
        burstProgress = 0
        withAnimation(.easeOut(duration: 0.5)) { burstProgress = 1 } // design-lint:allow — favorite-heart burst (signature effect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            burst = false
            burstProgress = 0
        }
    }
}
