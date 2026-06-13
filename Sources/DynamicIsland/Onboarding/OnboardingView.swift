import AppKit
import SwiftUI

/// The first-launch onboarding takeover. A blurred-desktop backdrop with a
/// drifting accent aurora; the island floats in the upper third, breathing and
/// morphing fluidly through the seven acts, then shrinks up into the notch to
/// "become" the real island. It IS the island, introducing itself.
struct OnboardingView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    @EnvironmentObject var settings: AppSettings

    /// The onboarding brand accent (matches the app icon's indigo).
    private let accent = Palette.indigo
    private var phase: OnboardingPhase { coordinator.phase }
    private var reduceMotion: Bool { coordinator.reduceMotion }

    private var morphing: Bool { coordinator.morphingOut }

    var body: some View {
        GeometryReader { geo in
            // While morphing out, the card flies up to the notch and shrinks to a
            // pill, so it lands exactly where the real island appears.
            let topPad = morphing ? Spacing.lg : geo.size.height * 0.16
            ZStack {
                AuroraBackdrop(accent: accent, reduceMotion: reduceMotion)
                    .opacity(morphing ? 0 : 1)
                VStack(spacing: Spacing.xxxl) {
                    LivingIsland(size: cardSize, cornerRadius: cardRadius, accent: accent,
                                 glow: glow, reduceMotion: reduceMotion) {
                        cardContent.opacity(morphing ? 0 : 1)
                    }
                    if phase != .awakening && !morphing {
                        bottomChrome.transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, topPad)
            }
            .animation(reduceMotion ? Motion.reduced : Motion.morph, value: morphing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { coordinator.start() }
    }

    /// The card's size/corner — collapses to a notch pill while morphing out.
    private var cardSize: CGSize {
        morphing ? CGSize(width: Layout.onboardingSeedWidth, height: Layout.onboardingSeedHeight) : size
    }
    private var cardRadius: CGFloat { morphing ? Layout.onboardingSeedHeight / 2 : cornerRadius }

    // MARK: Card sizing (morphs between acts)

    private var size: CGSize {
        switch phase {
        case .awakening: return CGSize(width: Layout.onboardingSeedWidth, height: Layout.onboardingSeedHeight)
        case .trailer, .personalize, .tryMe:
            return CGSize(width: Layout.onboardingWidth, height: Layout.onboardingTallHeight)
        default:
            return CGSize(width: Layout.onboardingWidth, height: Layout.onboardingHeight)
        }
    }
    private var cornerRadius: CGFloat { phase == .awakening ? size.height / 2 : Radius.shell }
    private var glow: Double { phase == .awakening ? 0.55 : 0.34 }

    @ViewBuilder
    private var cardContent: some View {
        Group {
            switch phase {
            case .awakening:   AwakeningAct(accent: accent, reduceMotion: reduceMotion)
            case .hello:       HelloAct(accent: accent, onBegin: { coordinator.advancePhase() })
            case .trailer:     TrailerAct(coordinator: coordinator, accent: accent)
            case .permissions: PermissionsAct(coordinator: coordinator, accent: accent)
            case .personalize: PersonalizeAct(coordinator: coordinator, accent: accent)
            case .tryMe:       TryMeAct(coordinator: coordinator, accent: accent)
            case .finale:      FinaleAct(accent: accent, reduceMotion: reduceMotion) { coordinator.finish() }
            }
        }
        .id(phase)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .center)),
            removal: .opacity))
        .animation(reduceMotion ? Motion.reduced : Motion.contentMorph, value: phase)
    }

    // MARK: Bottom chrome (progress + skip)

    private var bottomChrome: some View {
        VStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                ForEach(0..<OnboardingPhase.railCount, id: \.self) { i in
                    Capsule()
                        .fill(i <= phase.railIndex ? accent : Palette.surfaceStrong)
                        .frame(width: i == phase.railIndex ? 20 : 6, height: 6)
                        .animation(Motion.hover, value: phase)
                }
            }
            if phase != .finale {
                let intro = phase == .hello || phase == .trailer
                Button { intro ? coordinator.skipIntro() : coordinator.finish() } label: {
                    Text(intro ? "Skip intro" : "Skip the rest")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.islandFlat)
            }
        }
    }
}

// MARK: - Atmosphere

/// A gently drifting aurora over the BLURRED desktop — the real screen shows
/// through, softly frosted, with a slight darken for card contrast and a few
/// large accent pools that slowly orbit, so it feels alive rather than a flat
/// black modal. System UI (Settings, TCC prompts) can still surface above it.
struct AuroraBackdrop: View {
    let accent: Color
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            VisualEffectBlur().ignoresSafeArea()  // the blurred desktop behind the window
            Palette.background.opacity(0.24)      // slight darken so the card reads
            if reduceMotion {
                staticAurora
            } else {
                TimelineView(.animation) { ctx in
                    aurora(at: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
            // A soft darkening vignette toward the edges keeps focus on the island.
            RadialGradient(colors: [.clear, Palette.background.opacity(0.45)],
                           center: .center, startRadius: 220, endRadius: 760)
        }
        .ignoresSafeArea()
    }

    private func aurora(at t: TimeInterval) -> some View {
        ZStack {
            blob(color: accent, x: 0.30 + 0.10 * sin(t * 0.18), y: 0.22 + 0.06 * cos(t * 0.15), r: 360, o: 0.22)
            blob(color: Palette.purple, x: 0.72 + 0.08 * cos(t * 0.13), y: 0.30 + 0.07 * sin(t * 0.20), r: 320, o: 0.16)
            blob(color: Palette.blue, x: 0.55 + 0.12 * sin(t * 0.10), y: 0.74 + 0.05 * cos(t * 0.12), r: 420, o: 0.12)
        }
        .blur(radius: 80)
    }

    private var staticAurora: some View {
        ZStack {
            blob(color: accent, x: 0.32, y: 0.22, r: 360, o: 0.2)
            blob(color: Palette.blue, x: 0.62, y: 0.7, r: 420, o: 0.1)
        }
        .blur(radius: 80)
    }

    private func blob(color: Color, x: CGFloat, y: CGFloat, r: CGFloat, o: Double) -> some View {
        GeometryReader { geo in
            Circle().fill(color.opacity(o))
                .frame(width: r, height: r)
                .position(x: geo.size.width * x, y: geo.size.height * y)
        }
    }
}

/// A behind-window blur of whatever is on the desktop, so the onboarding sits on
/// a frosted-glass version of the real screen instead of solid black.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - The living island card

/// The island silhouette that holds each act — it morphs size fluidly and its
/// accent halo gently breathes, so it always feels alive (not a static slide).
struct LivingIsland<Content: View>: View {
    let size: CGSize
    let cornerRadius: CGFloat
    let accent: Color
    let glow: Double
    let reduceMotion: Bool
    @ViewBuilder var content: Content

    var body: some View {
        let shape = IslandShape(cornerRadius: cornerRadius)
        return shape.fill(Palette.background)
            .frame(width: size.width, height: size.height)
            .overlay { content.clipShape(shape) }
            .overlay(shape.stroke(accent.opacity(0.18), lineWidth: 0.8))
            .background { breathingHalo(shape: shape) }
            .shellShadow()
            .animation(reduceMotion ? Motion.reduced : Motion.morph, value: size)
    }

    @ViewBuilder
    private func breathingHalo(shape: IslandShape) -> some View {
        if reduceMotion {
            shape.fill(Palette.background)
                .frame(width: size.width, height: size.height)
                .shadow(color: accent.opacity(glow), radius: 22) // design-lint:allow — onboarding accent glow (signature)
        } else {
            TimelineView(.animation) { ctx in
                let breath = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 1.1)
                shape.fill(Palette.background)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: accent.opacity(glow * (0.6 + 0.5 * breath)), // design-lint:allow — onboarding accent glow (signature)
                            radius: 18 + 12 * breath)
            }
        }
    }
}

// MARK: - Shared CTAs

/// The primary call-to-action pill (Begin / Continue / Grant).
struct OnboardingPill: View {
    let title: String
    var icon: String? = nil
    var filled: Bool = true
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Text(title).font(Typography.calloutStrong)
                if let icon { Image(systemName: icon).font(.system(size: IconSize.sm, weight: .bold)) }
            }
            .foregroundStyle(filled ? Palette.onAccent : accent)
            .padding(.horizontal, Spacing.xxl)
            .frame(height: Layout.hitTargetMin)
            .background(Capsule().fill(filled ? AnyShapeStyle(accent) : AnyShapeStyle(accent.opacity(0.16))))
            .contentShape(Capsule())
        }
        .buttonStyle(.islandSubtle)
    }
}

/// A quiet secondary text action (Maybe later / Skip this).
struct OnboardingLink: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Typography.footnote).foregroundStyle(Palette.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.islandFlat)
    }
}
