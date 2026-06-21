import SwiftUI

/// The "Equalizer & Spatial" tweak detail page: a shared app drawer on top, an
/// EQ / Spatial sub-tab switch, and either a per-app 5-band graphic EQ (with
/// presets + pan) or a spatial stage where apps are dragged to pan L/R.
/// Everything edits the app currently selected in the store (shared across tabs).
struct EqSpatialPage: View {
    @ObservedObject var store: AppVolumeStore
    let accent: Color

    enum Tab { case eq, spatial }
    @State private var tab: Tab =
        ProcessInfo.processInfo.environment["DI_TWEAKS_TAB"] == "spatial" ? .spatial : .eq

    var body: some View {
        VStack(spacing: Spacing.lg) {
            if store.apps.isEmpty {
                emptyState
            } else {
                DrawerStrip(store: store, accent: accent)
                Picker("", selection: $tab) {
                    Text("Equalizer").tag(Tab.eq)
                    Text("Spatial").tag(Tab.spatial)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .tint(accent)
                if let app = store.selectedApp {
                    // The active tab fills the remaining height so nothing compresses.
                    Group {
                        switch tab {
                        case .eq: EQTab(store: store, app: app, accent: accent)
                        case .spatial: SpatialTab(store: store, accent: accent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.bottom, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: IconSize.xxl))
                .foregroundStyle(Palette.textFaint)
            Text("No apps running").font(Typography.footnote).foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared app drawer

/// Horizontal strip of running apps. Tap an icon to select it for editing; selected
/// gets an accent ring, apps placed on the stage get a small dot.
private struct DrawerStrip: View {
    @ObservedObject var store: AppVolumeStore
    let accent: Color

    var body: some View {
        // Plain SwiftUI ScrollView (not HWheelScroll): a nested NSScrollView throws an
        // Auto Layout exception when the island/settings card resizes. See WeatherExpandedView.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.lg) {
                ForEach(store.apps) { app in
                    let selected = app.bundleID == store.selectedApp?.bundleID
                    Button { store.select(app.bundleID) } label: {
                        VStack(spacing: Spacing.xxs) {
                            ZStack {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                                } else {
                                    RoundedRectangle(cornerRadius: Radius.md).fill(Palette.surface).frame(width: 30, height: 30)
                                }
                            }
                            .padding(Spacing.xs)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .stroke(selected ? accent : .clear, lineWidth: 2))
                            Circle().fill(app.setting.onStage ? accent : .clear).frame(width: 4, height: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    // Brightness-only hover (NOT a scale swell): the tray lives in a
                    // horizontal scroll clip butted against the header bar, so a
                    // scaled-up icon overflowed the clip and read as ducking behind
                    // the header. The selection ring is the "which app" cue instead.
                    .buttonStyle(.islandFlat)
                }
            }
            .padding(.horizontal, Spacing.xxs)
            .padding(.vertical, Spacing.hairline)
        }
        .frame(height: 50)
        .smoothScrollBounce()
    }
}

// MARK: - EQ tab

private struct EQTab: View {
    @ObservedObject var store: AppVolumeStore
    let app: AppVolumeItem
    let accent: Color

    var body: some View {
        let activePreset = EQPreset.matching(app.setting.eq.bands)
        return VStack(spacing: Spacing.xl) {
            HStack(spacing: Spacing.md) {
                if app.isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: IconSize.sm, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Text(app.name).font(Typography.callout).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Spacer(minLength: Spacing.sm)
                IconButton(system: "arrow.counterclockwise") {
                    store.resetEQ(for: app.bundleID)
                }
            }

            // Presets — tap to apply a curve to the bands (highlighted when active).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.md) {
                    ForEach(EQPreset.all) { preset in
                        PresetChip(title: preset.name,
                                   active: activePreset?.id == preset.id,
                                   accent: accent) {
                            store.applyPreset(preset, for: app.bundleID)
                        }
                    }
                }
                .padding(.horizontal, Spacing.hairline).padding(.vertical, Spacing.hairline)
            }
            .frame(height: 30)
            .smoothScrollBounce()

            HStack(spacing: 0) {
                ForEach(0..<AppAudioEngine.bandCount, id: \.self) { i in
                    VStack(spacing: Spacing.md) {
                        VerticalEQSlider(
                            db: app.setting.eq.bands.indices.contains(i) ? app.setting.eq.bands[i] : 0,
                            accent: accent
                        ) { store.setBand($0, index: i, for: app.bundleID) }
                        Text(Self.freqLabel(AppAudioEngine.bandFreqs[i]))
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PanRow(pan: app.setting.pan, accent: accent) { store.setPan($0, for: app.bundleID) }
        }
    }

    static func freqLabel(_ hz: Float) -> String {
        guard hz >= 1000 else { return "\(Int(hz))" }
        let k = hz / 1000
        return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
}

private struct PresetChip: View {
    let title: String
    let active: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(active ? Palette.onAccent : (hovering ? Palette.textPrimary : Palette.textHigh))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.sm)
                .background(Capsule().fill(active ? accent : (hovering ? Palette.surfaceRaised : Palette.surface)))
                .contentShape(Capsule())
        }
        .buttonStyle(.islandSubtle)   // gentle swell on hover
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// A vertical EQ band slider. dB in -12…+12 (0 = flat at the center line). The fill
/// runs from the center toward the knob to show boost (up) / cut (down).
private struct VerticalEQSlider: View {
    let db: Double
    let accent: Color
    let onChange: (Double) -> Void

    private let range = AppEQ.gainRange   // -12...12
    private let knobSize: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w / 2
            let r = knobSize / 2
            let travel = max(1, h - knobSize)        // inset so the knob never clips
            let frac = (db - range.lowerBound) / (range.upperBound - range.lowerBound)  // 0…1 bottom→top
            let knobY = r + travel * (1 - frac)
            let centerY = r + travel * 0.5           // the 0 dB line
            ZStack {
                GlassTrack()
                    .frame(width: 4, height: h)
                    .position(x: cx, y: h / 2)
                Rectangle().fill(Palette.strokeStrong)
                    .frame(width: 11, height: 1)
                    .position(x: cx, y: centerY)
                Capsule().fill(accent)
                    .frame(width: 4, height: max(0, abs(knobY - centerY)))
                    .position(x: cx, y: (knobY + centerY) / 2)
                Circle().fill(Palette.textPrimary)
                    .frame(width: knobSize, height: knobSize)
                    .raisedShadow()
                    .position(x: cx, y: knobY)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = max(0, min(1, 1 - (g.location.y - r) / travel))
                        onChange(range.lowerBound + f * (range.upperBound - range.lowerBound))
                    }
            )
        }
        .frame(width: 28)
    }
}

/// "PAN" label + a center-detented horizontal slider with L/R ends.
private struct PanRow: View {
    let pan: Double
    let accent: Color
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Text("PAN").font(Typography.caption).foregroundStyle(Palette.textSecondary)
            Text("L").font(Typography.footnote).foregroundStyle(Palette.textTertiary)
            CenterSlider(value: pan, accent: accent, onChange: onChange)
            Text("R").font(Typography.footnote).foregroundStyle(Palette.textTertiary)
        }
    }
}

/// A horizontal slider whose value runs -1…+1 with a fill that grows from the
/// center toward the knob (so center = balanced).
private struct CenterSlider: View {
    let value: Double      // -1…+1
    let accent: Color
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = (value + 1) / 2                 // 0…1
            let knobX = w * frac
            let centerX = w * 0.5
            ZStack(alignment: .leading) {
                GlassTrack().frame(height: 4)
                Capsule().fill(accent)
                    .frame(width: max(0, abs(knobX - centerX)), height: 4)
                    .offset(x: min(knobX, centerX))
                Circle().fill(Palette.textPrimary).frame(width: 13, height: 13)
                    .raisedShadow()
                    .offset(x: knobX - 6.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = max(0, min(1, g.location.x / max(1, w)))
                        onChange(Double(f) * 2 - 1)
                    }
            )
        }
        .frame(height: 16)
    }
}

// MARK: - Spatial tab

private struct SpatialTab: View {
    @ObservedObject var store: AppVolumeStore
    let accent: Color

    var body: some View {
        VStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Text("Drag an app left/right to pan it")
                    .font(Typography.footnote).foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
            }
            StageBox(store: store, accent: accent)
        }
    }
}

/// The spatial stage: a box with the listener at the bottom-center and each staged
/// app as a draggable icon. Horizontal position = pan (L/R); vertical is cosmetic.
private struct StageBox: View {
    @ObservedObject var store: AppVolumeStore
    let accent: Color

    private let margin: CGFloat = 24
    private let iconSize: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                    .fill(Palette.surfaceSubtle)
                    .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).stroke(Palette.hairlineStroke))
                // center guide line
                Rectangle().fill(Palette.surfaceSubtle).frame(width: 1).position(x: w / 2, y: h / 2)

                // listener
                VStack(spacing: Spacing.xxs) {
                    Image(systemName: "person.fill")
                        .font(.system(size: IconSize.lg, weight: .semibold))
                        .foregroundStyle(accent)
                    Text("You").font(Typography.footnote).foregroundStyle(Palette.textSecondary)
                }
                .position(x: w / 2, y: h - 26)

                // staged apps
                ForEach(store.stagedApps) { app in
                    stageIcon(app, w: w, h: h)
                }

                // controls (top-right)
                HStack(spacing: Spacing.sm) {
                    IconButton(system: "arrow.counterclockwise") { store.clearStage() }
                    IconButton(system: "plus") {
                        if let id = store.selectedApp?.bundleID { store.placeOnStage(id) }
                    }
                }
                .position(x: w - 34, y: 22)
            }
            .coordinateSpace(name: "stage")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stageIcon(_ app: AppVolumeItem, w: CGFloat, h: CGFloat) -> some View {
        let selected = app.bundleID == store.selectedApp?.bundleID
        let x = panToX(app.setting.pan, w: w)
        let y = max(margin, min(h - 56, app.setting.stageY * h))
        return StageAppIcon(app: app, accent: accent, selected: selected, iconSize: iconSize)
            .position(x: x, y: y)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
                    .onChanged { g in
                        // Select once at the start of the drag, not every tick — a
                        // redundant re-publish per frame added to the drag lag.
                        if app.bundleID != store.selectedApp?.bundleID {
                            store.select(app.bundleID)
                        }
                        store.setPan(xToPan(g.location.x, w: w),
                                     y: Double(max(margin, min(h - 56, g.location.y)) / max(1, h)),
                                     for: app.bundleID)
                    }
            )
    }

    private func panToX(_ pan: Double, w: CGFloat) -> CGFloat {
        let usable = w - 2 * margin
        return margin + CGFloat((pan + 1) / 2) * usable
    }
    private func xToPan(_ x: CGFloat, w: CGFloat) -> Double {
        let usable = max(1, w - 2 * margin)
        return Double(max(0, min(1, (x - margin) / usable))) * 2 - 1
    }
}

/// A staged app icon that swells and brightens its ring on hover.
private struct StageAppIcon: View {
    let app: AppVolumeItem
    let accent: Color
    let selected: Bool
    let iconSize: CGFloat
    @State private var hovering = false

    var body: some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: iconSize, height: iconSize)
            } else {
                RoundedRectangle(cornerRadius: Radius.md).fill(Palette.surfaceRaised).frame(width: iconSize, height: iconSize)
            }
        }
        .padding(Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(selected ? accent : (hovering ? Palette.strokeStrong : Palette.stroke),
                    lineWidth: selected ? 2 : 1))
        .scaleEffect(hovering ? 1.12 : 1)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }
}
