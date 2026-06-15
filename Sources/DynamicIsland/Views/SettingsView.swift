import SwiftUI

/// The settings page, opened from the gear icon at the bottom of the sidebar.
///
/// Settings-style architecture (matching the Tweaks app): a LIST of categories,
/// each opening its own detail page with a back button. Reading every value from
/// the shared `AppSettings` environment object means flipping a control updates
/// the live island immediately.
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
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .music: return "Music"
            case .calendar: return "Calendar"
            case .weather: return "Weather"
            case .timers: return "Timers"
            case .notifications: return "Notifications"
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
            }
        }
        static func fromEnv(_ v: String?) -> Category? {
            if v == "wave" { return .music }   // the wave sub-page lives under Music
            return Category(rawValue: v ?? "")
        }
    }

    /// `DI_SETTINGS_PAGE=music|notifications` opens a detail page directly (screenshots).
    @State private var selected: Category? =
        Category.fromEnv(ProcessInfo.processInfo.environment["DI_SETTINGS_PAGE"])
    /// Whether the Music → "Wave sensitivity" sub-page is open.
    @State private var showWave =
        ProcessInfo.processInfo.environment["DI_SETTINGS_PAGE"] == "wave"

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
        .onChange(of: selected) { _ in showWave = false }
        .tint(accent)
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
                        SettingsRow(category: category, accent: accent) { selected = category }
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.xxl)
            }
            .smoothScrollBounce()
        }
    }

    /// A category row with a hover animation (background lift, icon swell, chevron slide).
    private struct SettingsRow: View {
        let category: Category
        let accent: Color
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Spacing.xl) {
                    Image(systemName: category.icon)
                        .font(.system(size: IconSize.md, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(accent.opacity(hovering ? 0.30 : 0.18)))
                        .scaleEffect(hovering ? 1.08 : 1)
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(category.title).font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
                        Text(category.subtitle).font(Typography.footnote)
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
            ZStack {
                Text(category.title).font(Typography.bodyStrong).foregroundStyle(Palette.textPrimary)
                HStack {
                    Button { selected = nil } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "chevron.left").font(.system(size: IconSize.sm, weight: .bold))
                            Text("Settings").font(Typography.callout)
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

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    switch category {
                    case .general: generalControls
                    case .music: musicControls
                    case .calendar: calendarControls
                    case .weather: weatherControls
                    case .timers: timersControls
                    case .notifications: notificationControls
                    }
                }
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.xxl)
            }
            .smoothScrollBounce()
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
