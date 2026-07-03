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
    /// When set, the pill is its own mini-notch: flush to the top with a square
    /// top and this bottom-corner radius, instead of a floating capsule.
    var notchBottomRadius: CGFloat? = nil

    private var config: IslandConfiguration { controller.configuration }

    /// The pill outline — a capsule normally, a notch silhouette in notch mode.
    private var shellShape: AnyShape {
        if let r = notchBottomRadius { return AnyShape(NotchShape(bottomRadius: r)) }
        return AnyShape(Capsule())
    }

    /// Music is a circle (bar height); a timer chip adds room for its readout.
    static func width(for island: DynamicIslandController.SecondaryIsland,
                      height: CGFloat) -> CGFloat {
        switch island.kind {
        case .music: return height
        case .timer: return height + IslandConfiguration.default.notchTimerChipReadout
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
        .background(shellShape.fill(Palette.background))
        .overlay(shellShape.stroke(strokeTint.opacity(config.notchStrokeOpacity),
                                   lineWidth: config.notchStrokeWidth))
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
            RingingGlowOverlay(shape: shellShape)
        }
    }

    /// Green dot flagging that more timers exist than are currently shown.
    @ViewBuilder
    private var moreDot: some View {
        if case .timer(_, let showsMore) = island.kind, showsMore {
            Circle()
                .fill(Palette.green)
                .frame(width: config.notchMoreDotSize, height: config.notchMoreDotSize)
                .overlay(Circle().stroke(Palette.background, lineWidth: config.notchMoreDotStroke))
                .offset(x: -Spacing.xxs, y: Spacing.xxs)
        }
    }

    private func timerChip(_ timer: IslandTimer) -> some View {
        // In notch mode, match the main timer lobe exactly (glyph + headline value)
        // so text/icons line up across islands; floating keeps its bar-relative size.
        let isNotch = notchBottomRadius != nil
        let iconSize = isNotch ? IconSize.lg : max(IconSize.sm, height * config.notchGlyphRatio)
        return HStack(spacing: Spacing.sm) {
            Image(systemName: timer.kind == .stopwatch ? "stopwatch" : "timer")
                .font(.system(size: iconSize, weight: isNotch ? .semibold : .bold))
                .foregroundStyle(strokeTint)
            TimelineView(.periodic(from: .now, by: 0.2)) { context in
                let clock = Text(formatClock(timer.displayValue(at: context.date)))
                    .foregroundStyle(Palette.textPrimary)
                if isNotch {
                    clock.font(Typography.headlineMono)
                } else {
                    clock.font(.system(size: iconSize, weight: .bold).monospacedDigit())
                }
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
                    .font(.system(size: max(IconSize.sm, height * config.notchBubbleGlyphRatio), weight: .bold))
                    .foregroundStyle(strokeTint)
            }
        }
        .frame(width: height - 2 * Spacing.xs, height: height - 2 * Spacing.xs)
        .clipShape(Circle())
    }
}
