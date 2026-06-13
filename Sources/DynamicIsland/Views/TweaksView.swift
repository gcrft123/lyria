import SwiftUI

/// The Tweaks app: a Settings-style LIST of system tweaks, each opening to its own
/// detail page (with a back button).
struct TweaksView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var store: AppVolumeStore

    /// The available tweaks (add cases here to grow the app).
    enum Tweak: String, Identifiable, CaseIterable {
        case appVolume
        case equalizer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appVolume: return "App Volume"
            case .equalizer: return "EQ & Spatial"
            }
        }
        var subtitle: String {
            switch self {
            case .appVolume: return "Set volume & mute per app"
            case .equalizer: return "Per-app equalizer & stereo pan"
            }
        }
        var icon: String {
            switch self {
            case .appVolume: return "speaker.wave.2.fill"
            case .equalizer: return "slider.vertical.3"
            }
        }
        /// Value of `DI_TWEAKS_PAGE` that opens this page directly (for screenshots).
        static func fromEnv(_ v: String?) -> Tweak? {
            switch v {
            case "appvolume": return .appVolume
            case "eq", "equalizer": return .equalizer
            default: return nil
            }
        }
    }

    private var accent: Color { IslandApp.tweaks.tint }
    // `DI_TWEAKS_PAGE=appvolume|eq` opens a detail page directly (for screenshots,
    // since navigating via a tap isn't possible under test).
    @State private var selected: Tweak? =
        Tweak.fromEnv(ProcessInfo.processInfo.environment["DI_TWEAKS_PAGE"])

    var body: some View {
        ZStack {
            if let selected {
                detail(selected)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                listPage
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.transition, value: selected)
        .onAppear { store.eqPageActive = (selected == .equalizer) }
        .onDisappear { store.eqPageActive = false }
    }

    // MARK: List

    private var listPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tweaks")
                .font(Typography.title2)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xxl)
                .padding(.bottom, Spacing.lg)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Spacing.md) {
                    ForEach(Tweak.allCases) { tweak in
                        TweakRow(tweak: tweak, accent: accent) {
                            selected = tweak
                            store.eqPageActive = (tweak == .equalizer)
                        }
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.xxl)
            }
            .smoothScrollBounce()
        }
    }

    /// A list row with a hover animation: the background lifts, the icon swells and
    /// brightens, and the chevron slides right.
    private struct TweakRow: View {
        let tweak: Tweak
        let accent: Color
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Spacing.xl) {
                    Image(systemName: tweak.icon)
                        .font(.system(size: IconSize.md, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(accent.opacity(hovering ? 0.30 : 0.18)))
                        .scaleEffect(hovering ? 1.08 : 1)
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(tweak.title).font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
                        Text(tweak.subtitle).font(Typography.footnote)
                            .foregroundStyle(hovering ? Palette.textSecondary : Palette.textTertiary)
                    }
                    Spacer(minLength: Spacing.xs)
                    Image(systemName: "chevron.right")
                        .font(.system(size: IconSize.sm, weight: .bold))
                        .foregroundStyle(hovering ? Palette.textHigh : Palette.textFaint)
                        .offset(x: hovering ? Spacing.xs : 0)
                }
                .padding(.vertical, Spacing.lg)
                .padding(.horizontal, Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(hovering ? Palette.surfaceRaised : Palette.surfaceSubtle))
                .contentShape(Rectangle())
            }
            .buttonStyle(.islandFlat)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(_ tweak: Tweak) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(tweak.title).font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
                HStack {
                    Button { selected = nil; store.eqPageActive = false } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "chevron.left").font(.system(size: IconSize.sm, weight: .bold))
                            Text("Tweaks").font(Typography.callout)
                        }
                        .foregroundStyle(accent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.islandFlat)
                    Spacer()
                }
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.lg)

            switch tweak {
            case .appVolume: AppVolumePage(store: store, accent: accent)
            case .equalizer: EqSpatialPage(store: store, accent: accent)
            }
        }
    }
}

/// The per-app volume detail page: a row per app (sound-producing first, then MRU)
/// with a draggable volume slider and a mute toggle.
private struct AppVolumePage: View {
    @ObservedObject var store: AppVolumeStore
    let accent: Color

    var body: some View {
        if store.apps.isEmpty {
            VStack(spacing: Spacing.sm) {
                Image(systemName: "speaker.slash")
                    .font(.system(size: IconSize.xxl))
                    .foregroundStyle(Palette.textFaint)
                Text("No apps running")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Spacing.md) {
                    ForEach(store.apps) { app in
                        AppVolumeRow(app: app, store: store, accent: accent)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xxl)
            }
            .smoothScrollBounce()
        }
    }
}

/// One app's volume row, with a hover highlight (background lift + icon swell).
private struct AppVolumeRow: View {
    let app: AppVolumeItem
    @ObservedObject var store: AppVolumeStore
    let accent: Color
    @State private var hovering = false

    var body: some View {
        let muted = app.setting.muted
        return HStack(spacing: Spacing.xl) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                    .opacity(muted ? 0.5 : 1)
                    .scaleEffect(hovering ? 1.08 : 1)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(app.name)
                        .font(Typography.caption)
                        .foregroundStyle(muted ? Palette.textSecondary : Palette.textPrimary)
                        .lineLimit(1)
                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: IconSize.xs, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    Spacer(minLength: 0)
                }
                Slider(value: Binding(
                    get: { app.setting.volume },
                    set: { v in
                        if app.setting.muted { store.setMuted(false, for: app.bundleID) }
                        store.setVolume(v, for: app.bundleID)
                    }), in: 0...1)
                    .controlSize(.small)
                    .tint(muted ? Palette.textFaint : accent)
            }
            Button { store.toggleMuted(for: app.bundleID) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: IconSize.sm, weight: .semibold))
                    .foregroundStyle(muted ? accent : Palette.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Palette.surfaceSubtle))
                    .contentShape(Circle())
            }
            .buttonStyle(.island)
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(hovering ? Palette.surface : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// The compact Tweaks pill (only via `DI_FORCE_APP=tweaks` — Tweaks isn't
/// auto-active; it's reached from the sidebar).
struct TweaksCompactView: View {
    @ObservedObject var controller: DynamicIslandController
    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: IconSize.lg))
                .foregroundStyle(IslandApp.tweaks.tint)
            Text("Tweaks")
                .font(Typography.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: Spacing.sm)
            Image(systemName: "chevron.down")
                .font(.system(size: IconSize.sm, weight: .bold))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
