import SwiftUI

/// A secondary "additional island" for an app/timer that isn't filling the main
/// island. Kept as compact as possible: a live readout chip for a timer, a small
/// artwork bubble for Music. Rides at the island's bar height alongside it.
///
/// A timer chip can carry a green "more timers exist" dot (upper-right) and, when
/// its countdown has fired, a flashing red ring matching the main island's.
struct SecondaryAppIslandView: View {
    @ObservedObject var controller: DynamicIslandController
    let island: DynamicIslandController.SecondaryIsland
    let height: CGFloat

    /// Music is a circle (bar height); a timer chip adds room for its readout.
    static func width(for island: DynamicIslandController.SecondaryIsland,
                      height: CGFloat) -> CGFloat {
        switch island.kind {
        case .music: return height
        case .timer: return height + 54
        }
    }

    var body: some View {
        Group {
            switch island.kind {
            case .music: musicBubble
            case .timer(let timer, _): timerChip(timer)
            }
        }
        .frame(width: Self.width(for: island, height: height), height: height)
        .background(Capsule().fill(Palette.background))
        .overlay(Capsule().stroke(strokeTint.opacity(0.32), lineWidth: 0.8))
        .overlay { ringingOverlay }
        .overlay(alignment: .topTrailing) { moreDot }
        .shellShadow()
    }

    /// Stroke / glyph accent — alarm red for a fired countdown, else the app tint.
    private var strokeTint: Color {
        switch island.kind {
        case .music:
            return controller.nowPlaying.map { controller.settings.accent(for: $0) }
                ?? AppSettings.neutralAccent
        case .timer(let timer, _):
            return timer.hasFired ? .timerRing : IslandApp.timers.tint
        }
    }

    /// Flashing red ring while this chip's countdown is ringing.
    @ViewBuilder
    private var ringingOverlay: some View {
        if case .timer(let timer, _) = island.kind, timer.hasFired {
            RingingGlowOverlay(shape: Capsule())
        }
    }

    /// Green dot flagging that more timers exist than are currently shown.
    @ViewBuilder
    private var moreDot: some View {
        if case .timer(_, let showsMore) = island.kind, showsMore {
            Circle()
                .fill(Palette.green)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Palette.background, lineWidth: 1.5))
                .offset(x: -3, y: 3)
        }
    }

    private func timerChip(_ timer: IslandTimer) -> some View {
        let iconSize = max(11, height * 0.32)
        return HStack(spacing: Spacing.sm) {
            Image(systemName: timer.kind == .stopwatch ? "stopwatch" : "timer")
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(strokeTint)
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                Text(formatClock(timer.displayValue(at: context.date)))
                    .font(.system(size: iconSize, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.textPrimary)
            }
        }
    }

    private var musicBubble: some View {
        Group {
            if let artwork = controller.nowPlaying?.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: max(11, height * 0.4), weight: .bold))
                    .foregroundStyle(strokeTint)
            }
        }
        .frame(width: height - 8, height: height - 8)
        .clipShape(Circle())
    }
}
