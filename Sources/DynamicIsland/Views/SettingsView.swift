import SwiftUI

/// The settings page, opened from the gear icon at the bottom of the sidebar.
///
/// A LIST of categories, each opening its own detail page with a back button.
/// Reading every value from the shared `AppSettings` environment object means
/// flipping a control updates the live island immediately. "Tweaks" is a category
/// here (the former standalone Tweaks app) whose detail is itself a small list —
/// App Volume and EQ & Spatial — each pushing to its own page.
struct SettingsView: View {
    @ObservedObject var controller: DynamicIslandController
    @EnvironmentObject var settings: AppSettings

    /// A settings category (add cases here to grow the page).
    enum Category: String, Identifiable, CaseIterable {
        case general
        case music
        case calendar
        case weather
        case timers
        case notifications
        case tweaks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .music: return "Music"
            case .calendar: return "Calendar"
            case .weather: return "Weather"
            case .timers: return "Timers"
            case .notifications: return "Notifications"
            case .tweaks: return "Tweaks"
            }
        }
        var subtitle: String {
            switch self {
            case .general: return "How the island expands"
            case .music: return "Player look, glow & effects"
            case .calendar: return "Event alert timing"
            case .weather: return "Units & condition alerts"
            case .timers: return "Finish chime"
            case .notifications: return "How banners appear on the island"
            case .tweaks: return "Per-app volume, EQ & spatial pan"
            }
        }
        var icon: String {
            switch self {
            case .general: return "hand.tap"
            case .music: return "music.note"
            case .calendar: return "calendar"
            case .weather: return "cloud.sun.fill"
            case .timers: return "timer"
            case .notifications: return "bell.badge"
            case .tweaks: return "slider.horizontal.3"
            }
        }
        static func fromEnv(_ v: String?) -> Category? {
            if v == "wave" { return .music }   // the wave sub-page lives under Music
            return Category(rawValue: v ?? "")
        }
    }

    /// A page within the Tweaks category — each pushes to its own detail.
    enum TweakPage: String, Identifiable, CaseIterable {
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
        static func fromEnv(_ v: String?) -> TweakPage? {
            switch v {
            case "appvolume": return .appVolume
            case "eq", "equalizer": return .equalizer
            default: return nil
            }
        }
    }

    /// `DI_SETTINGS_PAGE=music|notifications` (or `DI_TWEAKS_PAGE=…`) opens a detail
    /// page directly (screenshots).
    @State private var selected: Category? = {
        let env = ProcessInfo.processInfo.environment
        if env["DI_TWEAKS_PAGE"] != nil { return .tweaks }
        return Category.fromEnv(env["DI_SETTINGS_PAGE"])
    }()
    /// Whether the Music → "Wave sensitivity" sub-page is open.
    @State private var showWave =
        ProcessInfo.processInfo.environment["DI_SETTINGS_PAGE"] == "wave"
    /// The open Tweaks sub-page (App Volume / EQ & Spatial), if any.
    @State private var selectedTweak: TweakPage? =
        TweakPage.fromEnv(ProcessInfo.processInfo.environment["DI_TWEAKS_PAGE"])

    /// Accent for the controls — follows the artwork tint preference, falling back
    /// to neutral so the page still looks right with tinting off.
    private var accent: Color {
        controller.nowPlaying.map { settings.accent(for: $0) } ?? Palette.neutralAccent
    }

    var body: some View {
        ZStack {
            if selected == .music, showWave {
                waveSensitivityPage
                    .transition(Transitions.detailPush)
            } else if selected == .tweaks, let tweak = selectedTweak {
                tweakDetail(tweak)
                    .transition(Transitions.detailPush)
            } else if let selected {
                detail(selected)
                    .transition(Transitions.detailPush)
            } else {
                listPage
                    .transition(Transitions.listReturn)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.transition, value: selected)
        .animation(Motion.transition, value: showWave)
        .animation(Motion.transition, value: selectedTweak)
        .onChange(of: selected) { _ in
            showWave = false
            if selected != .tweaks { selectedTweak = nil }
            syncEQHeight()
        }
        .onChange(of: selectedTweak) { _ in syncEQHeight() }
        .onAppear { syncEQHeight() }
        // The EQ page grows the settings card; make sure leaving the page (or
        // closing settings) returns the card to the standard height.
        .onDisappear { controller.appVolumeStore.eqPageActive = false }
        .tint(accent)
    }

    /// The Tweaks → "EQ & Spatial" page is the one settings page taller than the
    /// 324 standard; flag it on the store so the controller sizes the card to match.
    private func syncEQHeight() {
        controller.appVolumeStore.eqPageActive = (selected == .tweaks && selectedTweak == .equalizer)
    }

    // MARK: List

    private var listPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(Typography.title2)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xxl)
                .padding(.bottom, Spacing.lg)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Spacing.md) {
                    ForEach(Category.allCases) { category in
                        NavCard(icon: category.icon, title: category.title,
                                subtitle: category.subtitle, accent: accent) { selected = category }
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.xxl)
            }
            .smoothScrollBounce()
        }
    }

    /// A tappable list row with a hover animation (background lift, icon swell,
    /// chevron slide). Shared by the Settings category list and the Tweaks sub-list.
    private struct NavCard: View {
        let icon: String
        let title: String
        let subtitle: String
        let accent: Color
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Spacing.xl) {
                    Image(systemName: icon)
                        .font(.system(size: IconSize.md, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(accent.opacity(hovering ? 0.30 : 0.18)))
                        .scaleEffect(hovering ? 1.08 : 1)
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(title).font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
                        Text(subtitle).font(Typography.footnote)
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
    private func detail(_ category: Category) -> some View {
        VStack(spacing: 0) {
            headerBar(category.title, back: "Settings") { selected = nil }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    switch category {
                    case .general: generalControls
                    case .music: musicControls
                    case .calendar: calendarControls
                    case .weather: weatherControls
                    case .timers: timersControls
                    case .notifications: notificationControls
                    case .tweaks: tweaksControls
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.xxl)
            }
            .smoothScrollBounce()
        }
    }

    /// A detail-page title bar: centred title with a leading "‹ <back>" button.
    /// Shared by every detail and sub-page so they all step back identically.
    private func headerBar(_ title: String, back backTitle: String,
                           action: @escaping () -> Void) -> some View {
        ZStack {
            Text(title).font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
            HStack {
                Button(action: action) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.left").font(.system(size: IconSize.sm, weight: .bold))
                        Text(backTitle).font(Typography.callout)
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
    }

    // MARK: Tweaks (Settings → Tweaks → App Volume / EQ & Spatial)

    /// The Tweaks category detail: a small list pushing to each tweak's own page.
    private var tweaksControls: some View {
        VStack(spacing: Spacing.md) {
            ForEach(TweakPage.allCases) { tweak in
                NavCard(icon: tweak.icon, title: tweak.title,
                        subtitle: tweak.subtitle, accent: accent) { selectedTweak = tweak }
            }
        }
    }

    /// A Tweaks sub-page (App Volume or EQ & Spatial), reached from `tweaksControls`.
    @ViewBuilder
    private func tweakDetail(_ tweak: TweakPage) -> some View {
        VStack(spacing: 0) {
            headerBar(tweak.title, back: "Tweaks") { selectedTweak = nil }
            switch tweak {
            case .appVolume: AppVolumePage(store: controller.appVolumeStore, accent: accent)
            case .equalizer: EqSpatialPage(store: controller.appVolumeStore, accent: accent)
            }
        }
    }

    private var generalControls: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                rowLabel("Expand the island on", systemImage: "hand.tap")
                Picker("", selection: $settings.expandTrigger) {
                    ForEach(AppSettings.ExpandTrigger.allCases) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(settings.expandTrigger.hint)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textTertiary)
            }

            Rectangle().fill(Palette.hairlineStroke).frame(height: 1)

            Button {
                NotificationCenter.default.post(name: .replayOnboarding, object: nil)
            } label: {
                HStack(spacing: 0) {
                    rowLabel("Replay the intro", systemImage: "sparkles")
                    Spacer(minLength: Spacing.md)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: IconSize.lg))
                        .foregroundStyle(accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.islandFlat)

            Rectangle().fill(Palette.hairlineStroke).frame(height: 1)

            Button {
                Updater.shared.checkForUpdates()
            } label: {
                HStack(spacing: 0) {
                    rowLabel("Check for Updates", systemImage: "arrow.down.circle")
                    Spacer(minLength: Spacing.md)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: IconSize.md))
                        .foregroundStyle(accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.islandFlat)

            Rectangle().fill(Palette.hairlineStroke).frame(height: 1)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 0) {
                    rowLabel("Quit Lyria", systemImage: "power")
                    Spacer(minLength: Spacing.md)
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: IconSize.md))
                        .foregroundStyle(Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.islandFlat)

            Text(appVersionLine)
                .font(Typography.footnote)
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Lyria 0.1.0 (1)" from the bundle, for the General page footer.
    private var appVersionLine: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? "Lyria"
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(name) \(version) (\(build))"
    }

    private var musicControls: some View {
        Group {
            toggleRow("Album art tint", systemImage: "paintpalette", isOn: $settings.tintWithArtwork)
            toggleRow("Compact progress glow", systemImage: "rectangle.bottomhalf.filled", isOn: $settings.showCompactGlow)
            toggleRow("Equalizer bars", systemImage: "waveform", isOn: $settings.showEqualizerBars)
            toggleRow("Pulse to the beat", systemImage: "dot.radiowaves.left.and.right", isOn: $settings.pulseToBeat)
            sliderRow("Glow intensity", systemImage: "sparkles", value: $settings.glowIntensity)
            navRow("Wave sensitivity", systemImage: "waveform.path.ecg") { showWave = true }
        }
    }

    // MARK: Wave sensitivity sub-page (Music → Wave sensitivity)

    private var waveSensitivityPage: some View {
        VStack(spacing: Spacing.lg) {
            ZStack {
                Text("Wave Sensitivity").font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
                HStack {
                    Button { showWave = false } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "chevron.left").font(.system(size: IconSize.sm, weight: .bold))
                            Text("Music").font(Typography.callout)
                        }
                        .foregroundStyle(accent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.islandFlat)
                    Spacer()
                }
            }
            graphBlock("Sensitivity · Pitch", hint: "low → high",
                       values: $settings.waveSensitivityPitch, defaults: AppSettings.defaultPitchCurve)
            graphBlock("Sensitivity · Volume", hint: "quiet → loud",
                       values: $settings.waveSensitivityVolume, defaults: AppSettings.defaultVolumeCurve)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xxl)
        .padding(.bottom, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func graphBlock(_ title: String, hint: String,
                            values: Binding<[Double]>, defaults: [Double]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(title).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                Spacer()
                Text(hint).font(Typography.footnote).foregroundStyle(Palette.textTertiary)
                IconButton(system: "arrow.counterclockwise", size: .compact, weight: .bold) {
                    values.wrappedValue = defaults
                }
            }
            CurveEditor(values: values, accent: accent)
                .frame(height: 104) // design-lint:allow — curve-editor canvas drawing height
        }
    }

    private var calendarControls: some View {
        pickerRow("Alert lead time", systemImage: "clock",
                  selection: $settings.calendarLeadMinutes,
                  options: AppSettings.calendarLeadChoices) { "\($0) min" }
    }

    private var weatherControls: some View {
        Group {
            toggleRow("Use Fahrenheit", systemImage: "thermometer.medium", isOn: $settings.weatherUseFahrenheit)
            toggleRow("Flash on condition change", systemImage: "bolt.horizontal", isOn: $settings.weatherFlashOnChange)
        }
    }

    private var timersControls: some View {
        Group {
            toggleRow("Chime when finished", systemImage: "bell", isOn: $settings.timerChimeEnabled)
            toggleRow("Repeat until dismissed", systemImage: "repeat", isOn: $settings.timerChimeRepeat)
        }
    }

    private var notificationControls: some View {
        toggleRow("Replace system banners", systemImage: "bell.badge", isOn: $settings.suppressSystemBanners)
    }

    // MARK: Pieces

    /// A tappable row that pushes to a sub-page (icon · title · chevron).
    private func navRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                rowLabel(title, systemImage: systemImage)
                Spacer(minLength: Spacing.md)
                Image(systemName: "chevron.right")
                    .font(.system(size: IconSize.sm, weight: .bold))
                    .foregroundStyle(Palette.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.islandFlat)
    }

    private func toggleRow(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 0) {
            rowLabel(title, systemImage: systemImage)
            Spacer(minLength: Spacing.md)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accent)
        }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .font(Typography.bodyRegular)
                .foregroundStyle(Palette.textPrimary)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: IconSize.sm))
                .foregroundStyle(accent)
                .frame(width: 18)
        }
    }

    private func sliderRow(_ title: String, systemImage: String, value: Binding<Double>) -> some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: 0) {
                rowLabel(title, systemImage: systemImage)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(Typography.footnoteMono)
                    .foregroundStyle(Palette.textSecondary)
            }
            Slider(value: value, in: 0...1).tint(accent)
        }
    }

    private func pickerRow(_ title: String, systemImage: String,
                           selection: Binding<Int>, options: [Int],
                           label: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            rowLabel(title, systemImage: systemImage)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { opt in
                    Text(label(opt)).tag(opt)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}

/// The per-app volume detail page: a row per app (sound-producing first, then MRU)
/// with a draggable volume slider and a mute toggle. (Settings → Tweaks → App Volume.)
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
