import SwiftUI

/// Shared padding so every act has consistent, generous breathing room (text
/// clear of the edges, action rows clear of the bottom).
extension View {
    func actPadding() -> some View {
        self.padding(.horizontal, Spacing.xxxl)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.xxxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Act 0 · Awakening

/// The seed pill: a single accent point of light, breathing.
struct AwakeningAct: View {
    let accent: Color
    let reduceMotion: Bool
    @State private var lit = false

    var body: some View {
        Circle()
            .fill(accent)
            .frame(width: 12, height: 12)
            .scaleEffect(lit ? 1.0 : 0.35)
            .opacity(lit ? 1 : 0.4)
            .shadow(color: accent.opacity(0.9), radius: 16) // design-lint:allow — onboarding spark (signature)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                guard !reduceMotion else { lit = true; return }
                withAnimation(Motion.gentle.repeatForever(autoreverses: true)) { lit = true }
            }
    }
}

// MARK: - Act 1 · Hello

struct HelloAct: View {
    let accent: Color
    let onBegin: () -> Void
    @State private var shown = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.zero)
            Image(systemName: "sparkles")
                .font(.system(size: IconSize.xl, weight: .semibold))
                .foregroundStyle(accent)
                .scaleEffect(shown ? 1 : 0.6)
            Text("Dynamic Island")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)
            Text("This is your island. Let me show you around.")
                .font(Typography.bodyRegular)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: Spacing.zero)
            OnboardingPill(title: "Take the tour", icon: "chevron.right", accent: accent, action: onBegin)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .actPadding()
        .onAppear { withAnimation(Motion.pop) { shown = true } }
    }
}

// MARK: - Act 2 · Trailer (user-advanced)

struct TrailerAct: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let accent: Color

    private var beat: TrailerBeat {
        TrailerBeat(rawValue: min(coordinator.trailerBeat, TrailerBeat.allCases.count - 1)) ?? .music
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                Text("A quick tour")
                    .font(Typography.caption).foregroundStyle(Palette.textTertiary)
                Spacer()
                Text("\(coordinator.trailerBeat + 1) / \(TrailerBeat.allCases.count)")
                    .font(Typography.captionMono).foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: Spacing.zero)
            VignetteTile(beat: beat, accent: accent)
                .id(beat)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            Spacer(minLength: Spacing.zero)
            HStack(spacing: Spacing.md) {
                Text(beat.caption)
                    .font(Typography.subheadline).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: Spacing.sm)
                OnboardingPill(title: coordinator.isLastTrailerBeat ? "Continue" : "Next",
                               icon: "chevron.right", accent: accent) {
                    coordinator.advanceTrailer()
                }
            }
        }
        .actPadding()
    }
}

/// A compact, LIVE mini of each app for the trailer (things actually move).
struct VignetteTile: View {
    let beat: TrailerBeat
    let accent: Color
    @State private var appeared = false

    var body: some View {
        Group {
            switch beat {
            case .music: music
            case .timer: timer
            case .calendar: calendar
            case .weather: weather
            case .dashboard: dashboard
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Layout.onboardingPreview)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Palette.surfaceSubtle))
        .onAppear { withAnimation(Motion.transition) { appeared = true } }
    }

    private var music: some View {
        HStack(spacing: Spacing.lg) {
            RoundedRectangle(cornerRadius: Radius.md).fill(accent.opacity(0.4)).frame(width: 48, height: 48)
                .overlay(Image(systemName: "music.note").foregroundStyle(Palette.textPrimary))
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Dreams").font(Typography.subheadline).foregroundStyle(Palette.textPrimary)
                Text("Fleetwood Mac").font(Typography.footnote).foregroundStyle(Palette.textSecondary)
                LiveProgress(accent: accent)
            }
            Spacer(minLength: Spacing.zero)
            LiveBars(accent: accent)
        }
        .padding(Spacing.xl)
    }

    private var timer: some View {
        VStack(spacing: Spacing.xs) {
            LiveCountdown(accent: accent)
            Text("Countdowns & stopwatches").font(Typography.footnote).foregroundStyle(Palette.textSecondary)
        }
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(["Design Review", "Lunch with Sam"].enumerated()), id: \.offset) { idx, title in
                HStack(spacing: Spacing.sm) {
                    RoundedRectangle(cornerRadius: Radius.xs).fill(accent).frame(width: 3, height: 22)
                    Text(title).font(Typography.caption).foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: Spacing.xs)
                    Text(idx == 0 ? "in 14 min" : "1:30 PM").font(Typography.captionMono).foregroundStyle(Palette.textSecondary)
                }
                .offset(x: appeared ? 0 : 16)
                .opacity(appeared ? 1 : 0)
                .animation(Motion.transition.delay(Double(idx) * 0.08), value: appeared)
            }
        }
        .padding(Spacing.xl)
    }

    private var weather: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: "cloud.sun.fill").symbolRenderingMode(.hierarchical)
                .font(.system(size: IconSize.xxxl)).foregroundStyle(accent)
                .scaleEffect(appeared ? 1 : 0.7)
            VStack(alignment: .leading, spacing: 0) {
                Text("72°").font(Typography.display).foregroundStyle(Palette.textPrimary)
                Text("Cupertino · Sunny").font(Typography.footnote).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: Spacing.zero)
        }
        .padding(Spacing.xl)
    }

    private var dashboard: some View {
        let apps = ["music.note", "timer", "calendar", "cloud.sun.fill"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 2), spacing: Spacing.sm) {
            ForEach(Array(apps.enumerated()), id: \.offset) { idx, glyph in
                RoundedRectangle(cornerRadius: Radius.md).fill(Palette.surface)
                    .frame(height: 34)
                    .overlay(Image(systemName: glyph).foregroundStyle(accent))
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                    .animation(Motion.pop.delay(Double(idx) * 0.06), value: appeared)
            }
        }
        .padding(Spacing.xl)
    }
}

// MARK: - Live mini-elements

private struct LiveProgress: View {
    let accent: Color
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { ctx in
                let p = CGFloat((ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6)) / 6)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceStrong)
                    Capsule().fill(accent).frame(width: geo.size.width * p)
                }
            }
        }
        .frame(height: 3)
    }
}

private struct LiveBars: View {
    let accent: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: Spacing.xxs) {
                ForEach(0..<3, id: \.self) { i in
                    let h = CGFloat(6 + 14 * abs(sin(t * 4 + Double(i))))
                    Capsule().fill(accent).frame(width: 3, height: h)
                }
            }
            .frame(height: 22, alignment: .center)
        }
        .frame(width: 18)
    }
}

private struct LiveCountdown: View {
    let accent: Color
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let m = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6)
            let remaining = max(0, 5 - m)
            Text(String(format: "00:%02d", Int(ceil(remaining))))
                .font(Typography.displayMono).foregroundStyle(accent)
                .contentTransition(.numericText())
        }
    }
}
