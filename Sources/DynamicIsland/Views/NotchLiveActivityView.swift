import SwiftUI

/// Natural width of the left content lobe (measured, not equalised).
private struct NotchLeftWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Natural width of the right content lobe.
private struct NotchRightWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The notch silhouette's total content width and the horizontal offset needed to
/// keep the physical-notch gap centred (so each side only extends as far as its
/// own content — the emptier side stays clear rather than padding out to match).
struct NotchShellMetrics: Equatable {
    var width: CGFloat = 0
    var offset: CGFloat = 0
}

struct NotchShellMetricsKey: PreferenceKey {
    static var defaultValue = NotchShellMetrics()
    static func reduce(value: inout NotchShellMetrics, nextValue: () -> NotchShellMetrics) {
        let n = nextValue()
        if n.width > 0 { value = n }
    }
}

/// Live-activity content laid out inside the morphed notch silhouette.
///
/// The physical notch divides one black shape into two content lobes — NOT two
/// pills. Each lobe hugs the notch, has an outer gutter off the shell's rounded
/// edge, and only extends as far as its own content. Every leading element shares
/// one band-relative `primaryGlyph` size so text starts at a consistent x, and
/// music/timer progress runs along the bottom lip.
struct NotchLiveActivityView: View {
    @ObservedObject var controller: DynamicIslandController
    @EnvironmentObject var settings: AppSettings
    let notch: NotchGeometry
    let mode: IslandMode

    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0

    private var config: IslandConfiguration { controller.configuration }

    /// One size for every leading element (artwork, status chip, calendar ring,
    /// and the fixed column around the weather/timer glyphs), so they are identical
    /// and the following text always starts at the same x. The band is sized to fit
    /// it with symmetric padding.
    private var primaryGlyph: CGFloat { IconSize.xxxl }

    /// The app whose content the lobes should render (nil → a status event).
    private var resolvedApp: IslandApp? {
        switch mode {
        case .compact(let a): return a
        case .popup(let p): return p.app
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            leftLobe
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: NotchLeftWidthKey.self, value: g.size.width)
                })
            Color.clear.frame(width: notch.width)          // the physical-notch gap
            rightLobe
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: NotchRightWidthKey.self, value: g.size.width)
                })
        }
        // Fill the shell frame (set by the parent) and CENTRE the content, so the
        // top and bottom breathing padding are equal.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Content-type swaps (music↔weather↔calendar↔timer↔status) cross-fade.
        .animation(Motion.contentMorph, value: mode)
        .overlay(alignment: .bottom) { bottomLip }
        .onPreferenceChange(NotchLeftWidthKey.self) { leftWidth = $0 }
        .onPreferenceChange(NotchRightWidthKey.self) { rightWidth = $0 }
        .preference(key: NotchShellMetricsKey.self,
                    value: NotchShellMetrics(width: leftWidth + notch.width + rightWidth,
                                             offset: (rightWidth - leftWidth) / 2))
    }

    // MARK: Lobes (notch-facing inset + outer gutter per non-empty side)

    @ViewBuilder private var leftLobe: some View {
        let inner = config.notchLobeInset
        let outer = config.notchLobeOuterInset
        switch resolvedApp {
        case .some(.music):    musicLeft.padding(.leading, outer).padding(.trailing, inner)
        case .some(.weather):  weatherLeft.padding(.leading, outer).padding(.trailing, inner)
        case .some(.calendar): calendarLeft.padding(.leading, outer).padding(.trailing, inner)
        case .some(.timers):   timerLeft.padding(.leading, outer).padding(.trailing, inner)
        case .some(.dashboard), .some(.calculator): EmptyView()
        case .none:            statusLeft.padding(.leading, outer).padding(.trailing, inner)
        }
    }

    @ViewBuilder private var rightLobe: some View {
        let inner = config.notchLobeInset
        let outer = config.notchLobeOuterInset
        switch resolvedApp {
        case .some(.music):    musicRight.padding(.leading, inner).padding(.trailing, outer)
        case .some(.weather):  weatherRight.padding(.leading, inner).padding(.trailing, outer)
        case .some(.calendar): calendarRight.padding(.leading, inner).padding(.trailing, outer)
        case .some(.timers):   timerRight.padding(.leading, inner).padding(.trailing, outer)
        case .some(.dashboard), .some(.calculator): EmptyView()
        case .none:            statusRight.padding(.leading, inner).padding(.trailing, outer)
        }
    }

    // MARK: Music (artwork left of the notch, wave on the right)

    @ViewBuilder private var musicLeft: some View {
        if let np = controller.nowPlaying {
            ArtworkView(image: np.artwork, size: primaryGlyph, cornerRadius: Radius.sm)
        }
    }

    @ViewBuilder private var musicRight: some View {
        if let np = controller.nowPlaying, settings.showEqualizerBars {
            NowPlayingBars(color: settings.accent(for: np), isPlaying: np.isPlaying)
                .frame(width: config.notchBarsWidth, height: primaryGlyph)
        }
    }

    // MARK: Weather

    @ViewBuilder private var weatherLeft: some View {
        if let snap = controller.weatherManager.snapshot {
            let alert = snap.alert
            HStack(spacing: Spacing.sm) {
                Image(systemName: alert != nil ? "exclamationmark.triangle.fill" : snap.condition.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: IconSize.lg))
                    .foregroundStyle(alert != nil ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(Palette.textHigh))
                    .frame(width: primaryGlyph)
                Text(snap.condition.short)
                    .font(Typography.bodyStrong)
                    .foregroundStyle(alert != nil ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(Palette.textSecondary))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var weatherRight: some View {
        if let snap = controller.weatherManager.snapshot {
            Text(WeatherFormat.temp(snap.temperature))
                .font(Typography.title2Mono)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: Calendar

    @ViewBuilder private var calendarLeft: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let ev = controller.calendarManager.imminentEvent(at: ctx.date) {
                let remaining = max(0, ev.timeUntilStart(at: ctx.date))
                let fraction = min(1, max(0, remaining / controller.calendarManager.imminentWindow))
                HStack(spacing: Spacing.sm) {
                    ring(fraction: fraction, accent: ev.color)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(ev.title)
                            .font(Typography.bodyStrong)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Text(countdownText(remaining))
                            .font(Typography.captionMono)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var calendarRight: some View {
        if let ev = controller.calendarManager.imminentEvent() {
            Text(ev.startTimeText)
                .font(Typography.calloutMono)
                .foregroundStyle(ev.color)
                .lineLimit(1)
        }
    }

    private func ring(fraction: Double, accent: Color) -> some View {
        ZStack {
            Circle().stroke(Palette.surfaceStrong, lineWidth: config.notchRingStroke)
            Circle()
                .trim(from: 0, to: CGFloat(fraction))
                .stroke(accent, style: StrokeStyle(lineWidth: config.notchRingStroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "calendar")
                .font(.system(size: IconSize.sm, weight: .bold))
                .foregroundStyle(accent)
        }
        .frame(width: primaryGlyph, height: primaryGlyph)
        .animation(Motion.gentle, value: fraction)
    }

    private func countdownText(_ remaining: TimeInterval) -> String {
        let mins = Int((remaining / 60).rounded(.up))
        if remaining <= 30 { return "now" }
        if mins <= 1 { return "in 1 min" }
        return "in \(mins) min"
    }

    // MARK: Timers

    @ViewBuilder private var timerLeft: some View {
        let headline = controller.timerManager.headline()
        HStack(spacing: Spacing.sm) {
            Image(systemName: headline?.kind == .stopwatch ? "stopwatch" : "timer")
                .font(.system(size: IconSize.lg, weight: .semibold))
                .foregroundStyle(headline?.hasFired == true ? .timerRing : IslandApp.timers.tint)
                .frame(width: primaryGlyph)
            Text(headline?.name ?? "Timers")
                .font(Typography.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var timerRight: some View {
        if let headline = controller.timerManager.headline() {
            TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                Text(formatClock(headline.displayValue(at: ctx.date)))
                    .font(Typography.headlineMono)
                    .foregroundStyle(headline.hasFired ? .timerRing : Palette.textHigh)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Status events (battery / Wi-Fi / Bluetooth / Focus)

    @ViewBuilder private var statusLeft: some View {
        if let popup = controller.activePopup {
            ZStack {
                Circle().fill((popup.accent ?? Palette.neutralAccent).opacity(0.22))
                Image(systemName: statusSymbol(popup.icon))
                    .font(.system(size: IconSize.lg, weight: .semibold))
                    .foregroundStyle(popup.accent ?? Palette.textHigh)
            }
            .frame(width: primaryGlyph, height: primaryGlyph)
        }
    }

    @ViewBuilder private var statusRight: some View {
        if let popup = controller.activePopup {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(popup.title)
                    .font(Typography.calloutStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if !popup.message.isEmpty {
                    Text(popup.message)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func statusSymbol(_ icon: IslandPopup.Icon) -> String {
        switch icon {
        case .symbol(let s): return s
        default: return "bell.fill"
        }
    }

    // MARK: Bottom-lip progress (music / countdown timer)

    @ViewBuilder private var bottomLip: some View {
        switch resolvedApp {
        case .some(.music):
            if settings.showCompactGlow, let np = controller.nowPlaying {
                progressBar(accent: settings.accent(for: np)) { date in
                    np.duration > 0 ? min(1, max(0, np.currentElapsed(at: date) / np.duration)) : 0
                }
            }
        case .some(.timers):
            if let t = controller.timerManager.headline(), t.kind == .countdown {
                // Turns alarm-red the moment the countdown fires / rings.
                progressBar(accent: t.hasFired ? .timerRing : IslandApp.timers.tint) { date in
                    t.fraction(at: date)
                }
            }
        default:
            EmptyView()
        }
    }

    /// A thin accent line along the bottom edge that fills across the whole shape
    /// (both lobes and the notch gap), mirroring the compact pill's progress glow.
    /// Clipped to the notch silhouette by the parent, so it follows the rounded bottom.
    private func progressBar(accent: Color, fraction: @escaping (Date) -> Double) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            GeometryReader { geo in
                let width = geo.size.width * fraction(context.date)
                ZStack(alignment: .bottomLeading) {
                    Capsule().fill(accent)
                        .frame(width: width, height: config.notchProgressGlowHeight)
                        .blur(radius: config.notchProgressBlur)
                        .opacity(0.55) // design-lint:allow — progress glow (signature)
                    Capsule().fill(accent.opacity(0.85)) // design-lint:allow — progress glow (signature)
                        .frame(width: width, height: config.notchProgressLineHeight)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: config.notchExtensionActive)
        }
        .frame(height: config.notchExtensionActive)
        .allowsHitTesting(false)
    }
}
