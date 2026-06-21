import SwiftUI

/// Root SwiftUI view hosted inside the floating panel.
///
/// Draws the black island and morphs its size/corner radius between idle,
/// compact, and expanded app layouts with a spring, cross-fading the content.
/// Expanded apps gain a left icon sidebar (to switch apps) and a soft accent
/// glow. Active apps that aren't filling the main island — plus the camera/mic
/// indicator — ride alongside as secondary side islands.
struct DynamicIslandView: View {
    @ObservedObject var controller: DynamicIslandController
    @EnvironmentObject var settings: AppSettings

    /// Transient "nudge" applied on each volume/brightness keypress: the bubble
    /// pops a touch bigger and kicks horizontally in the direction of the change
    /// (right = louder/brighter, left = quieter/dimmer), then springs back.
    /// Driven by `controller.hudNudge`.
    @State private var nudgeScale: CGFloat = 1
    @State private var nudgeX: CGFloat = 0

    /// Real-time audio analyzer powering the "to the beat" glow. Owned here for
    /// the view's lifetime; only actually taps system audio while the beat pulse
    /// is live (`beatPulseActive`). Falls back to a synthetic tempo internally
    /// when the tap can't be created.
    @State private var rhythm = AudioRhythmMonitor()

    /// Drives the island's *shape* — its size and corner radius. A touch
    /// underdamped (0.72) so the resize settles with a small, lively overshoot,
    /// the way the real Dynamic Island does.
    private var morph: Animation { Motion.morph }

    /// Drives the *content* swap. Deliberately lags the shape with a small delay
    /// and a higher damping: the shell springs to its new size first, then the
    /// fresh content fades and scales in once there's room for it — instead of
    /// content reflowing while the frame is still moving.
    private var contentMorph: Animation { Motion.contentMorph }

    /// Drives the side islands/indicators as they slide out from behind the main
    /// island and re-flow when it morphs.
    private var sideSpring: Animation { Motion.side }

    var body: some View {
        let geometry = controller.geometry
        let shape = IslandShape(cornerRadius: geometry.cornerRadius)
        let accent = mainAccent
        let glowing = controller.mode.isExpanded
        let intensity = settings.glowIntensity

        // The black shell sizes and morphs in ISOLATION from its content. The
        // content rides as an `.overlay`, which — unlike a ZStack sibling — can
        // never feed its own intrinsic width back into the shell's layout. That
        // matters because the compact pill (360pt) and the expanded card (468pt)
        // have different widths: as a ZStack child, the wider content tugged the
        // mid-animation shell off-centre, so the shell visibly lurched sideways
        // by ~half the width delta and sprang back before growing. As an overlay,
        // the shell's size comes purely from `geometry`, so it always grows
        // symmetrically about the canvas centre.
        shape.fill(Palette.background)
            .frame(width: geometry.size.width, height: geometry.size.height)
            // Content lags the shell on its own (slightly delayed) spring: the
            // shape morphs to size first, then the new content fades in once
            // there's room — never reflowing mid-resize, never nudging the shell.
            .overlay {
                content
                    .animation(contentMorph, value: controller.mode)
            }
            .clipShape(shape)
            .overlay(
                shape.stroke(accent.opacity(glowing ? 0.14 * intensity : 0), lineWidth: 0.8)
            )
            // When Timers fills the main island and a countdown is ringing, wrap
            // the whole island in a flashing red ring (only visible un-hovered —
            // hovering dismisses the alarm).
            .overlay {
                if mainIslandRinging {
                    RingingGlowOverlay(shape: shape)
                }
            }
            .shellShadow()
            .shadow(color: accent.opacity(glowing ? 0.15 * intensity : 0), radius: 11, y: 0) // design-lint:allow — accent glow (signature), not elevation
            // The pin / unpin affordance straddling the card's top-right corner.
            // Added AFTER the clip + shadows so it can overlap the corner and float.
            .overlay(alignment: .topTrailing) { pinControl }
            // The directional keypress nudge: a quick scale pop + horizontal kick
            // that springs back, layered on top of the shape morph for a fluid feel.
            .scaleEffect(nudgeScale)
            .offset(x: nudgeX)
            .onChange(of: controller.hudNudge) { nudge in
                applyNudge(direction: nudge.direction)
            }
            // Float the island a little below the top edge, then pin it top-centre.
            .padding(.top, controller.configuration.topInset)
            .frame(width: controller.configuration.canvasWidth,
                   height: controller.configuration.canvasHeight,
                   alignment: .top)
            // Morph the shell AFTER it's been centred in the canvas, so the
            // centring is part of the SAME animated transaction as the resize.
            // (When the animation sat inside the chain — below the centring frame
            // — the parent re-centred against the new/target width while the shell
            // still rendered the old width, so it visibly lurched sideways by half
            // the width delta and sprang back. Wrapping the centring frame keeps
            // size and position in lock-step, so the shell grows symmetrically
            // about the centre.) `mode` is intentionally not a trigger — geometry
            // already changes on every mode change.
            .animation(morph, value: geometry)
            // Secondary islands (music bubble, extra timer) and the camera/mic
            // indicator ride BESIDE the main island, tucked BEHIND it (a
            // `.background`, so the island's black shape always draws on top).
            // They slide out sideways from behind its left/right edges and
            // re-flow as it morphs.
            .background(alignment: .top) {
                sideIslandsLayer(islandWidth: geometry.size.width)
                    .animation(sideSpring, value: controller.islandExtensions)
                    .animation(sideSpring, value: controller.secondaryIslands)
                    .animation(sideSpring, value: geometry.size)
                    .animation(sideSpring, value: controller.extensionBarHeight)
            }
            // Furthest back: accent glow ripples shedding from the island's sides
            // in time with the music. Behind everything, so the black shell (and
            // the side islands) occlude all but the bands bleeding past the edges.
            .background(alignment: .top) {
                beatGlowLayer(cornerRadius: geometry.cornerRadius, size: geometry.size)
            }
            // Only tap system audio while the beat glow is actually on screen —
            // bring the analyzer up when it goes live, tear it down otherwise.
            .onChange(of: beatPulseActive) { active in
                if active { rhythm.start() } else { rhythm.stop() }
            }
            .onAppear {
                rhythm.setSensitivity(pitch: settings.waveSensitivityPitch, volume: settings.waveSensitivityVolume)
                if beatPulseActive { rhythm.start() }
            }
            .onChange(of: settings.waveSensitivityPitch) { _ in
                rhythm.setSensitivity(pitch: settings.waveSensitivityPitch, volume: settings.waveSensitivityVolume)
            }
            .onChange(of: settings.waveSensitivityVolume) { _ in
                rhythm.setSensitivity(pitch: settings.waveSensitivityPitch, volume: settings.waveSensitivityVolume)
            }
            .onDisappear { rhythm.stop() }
    }

    /// How far the pin button straddles past the card's top-right corner. Kept
    /// under the window controller's hover padding (8pt) so the whole button stays
    /// inside the click-capture region and is reliably tappable.
    private static let pinOverhang: CGFloat = 7

    /// The pin / unpin affordance straddling the expanded card's top-right corner.
    /// While unpinned it appears only on corner-hover (a thumbtack) and locks the
    /// island open; once pinned it shows persistently as a ✕ that unlocks it. It's
    /// `raised` (solid + shadow) so it reads as detached where it overlaps the edge.
    @ViewBuilder
    private var pinControl: some View {
        if controller.mode.isExpanded {
            let show = controller.pinned || controller.pinCornerHovered
            IconButton(system: controller.pinned ? "xmark" : "pin.fill",
                       size: .compact, weight: .bold,
                       raised: true, active: controller.pinned) {
                controller.togglePin()
            }
            .opacity(show ? 1 : 0)
            .scaleEffect(show ? 1 : 0.5)
            .allowsHitTesting(show)
            .offset(x: Self.pinOverhang, y: -Self.pinOverhang)
            .animation(Motion.popup, value: show)
        }
    }

    /// True only when the music-beat ripple should be live: the user enabled it,
    /// the main island is the music app, a track is actually playing, and the
    /// island is in its compact pill — the shed-from-the-sides glow is a
    /// glanceable accent, so it's hidden while the card is expanded (or in
    /// settings, where `mode.app` is already nil).
    private var beatPulseActive: Bool {
        guard settings.pulseToBeat,
              controller.mode.app == .music,
              !controller.mode.isExpanded else { return false }
        return controller.nowPlaying?.isPlaying == true
    }

    /// The beat ripple, positioned to align with the live island (top-centred,
    /// `topInset` down, sized to the current geometry). Empty when inactive.
    @ViewBuilder
    private func beatGlowLayer(cornerRadius: CGFloat, size: CGSize) -> some View {
        if beatPulseActive {
            BeatGlowOverlay(cornerRadius: cornerRadius,
                            size: size,
                            accent: mainAccent,
                            // Keep it visible even at a low glow setting, but let
                            // the slider still scale it.
                            intensity: 0.5 + 0.5 * settings.glowIntensity,
                            monitor: rhythm)
                .padding(.top, controller.configuration.topInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Kick the bubble in the direction of a volume/brightness change, then let
    /// it spring back. `direction` is +1 (up), -1 (down), or 0 (settle only).
    ///
    /// The settle must happen on a LATER run-loop turn: if both the pop and the
    /// reset are mutated in the same synchronous call, SwiftUI coalesces them
    /// (scale 1 → 1.05 → 1 nets to no change) and nothing animates. So we pop
    /// now and schedule the settle, giving SwiftUI a frame to render the peak.
    private func applyNudge(direction: Int) {
        // Pop bigger and kick left/right (up/louder = positive x = right).
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { // design-lint:allow — signature volume-nudge bounce
            nudgeScale = 1.06
            nudgeX = CGFloat(direction) * 6
        }
        // Settle back to rest with a softer spring, on the next tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { // design-lint:allow — signature volume-nudge bounce
                nudgeScale = 1
                nudgeX = 0
            }
        }
    }

    /// True when the main island is the Timers app and one of its countdowns is
    /// ringing — drives the flashing red ring around the whole island.
    private var mainIslandRinging: Bool {
        controller.mode.app == .timers && controller.timerManager.isRinging
    }

    /// Accent for the glow, following whichever app fills the main island.
    private var mainAccent: Color {
        switch controller.mode.app {
        case .calendar:
            return IslandApp.calendar.tint
        case .music:
            return controller.nowPlaying.map { settings.accent(for: $0) } ?? .clear
        case .timers:
            return IslandApp.timers.tint
        case .weather:
            return IslandApp.weather.tint
        case .dashboard:
            return IslandApp.dashboard.tint
        case .calculator:
            return IslandApp.calculator.tint
        case nil:
            // Settings / idle: fall back to the music accent if any.
            return controller.nowPlaying.map { settings.accent(for: $0) } ?? .clear
        }
    }

    // MARK: Main content

    @ViewBuilder
    private var content: some View {
        switch controller.mode {
        case .idle:
            EmptyView()
        case .compact(let app):
            compactView(app)
                .transition(Self.contentTransition)
        case .expanded, .settings:
            // Settings and the apps share ONE structural branch so the shell +
            // icon sidebar stay mounted across the switch — only the inner pane
            // cross-fades, and the card height morphs via geometry. Rendering
            // them as separate switch arms would remove/insert the whole
            // container and make settings "flash" in instead of morphing.
            expandedContainer(selected: controller.displayedApp) { expandedPane }
                .transition(Self.contentTransition)
        case .popup(let popup):
            // A live-activity popup wears the compact center-island pill (with the
            // popup's hover-grow / left-click-opens / right-click-dismisses
            // interaction): an island app shows its own compact view; a system
            // status event (battery / Wi-Fi / Bluetooth / Focus) shows a status
            // pill. A banner popup is the modal notification card.
            if popup.style == .liveActivity {
                Group {
                    if let app = popup.app {
                        compactView(app)
                    } else {
                        StatusActivityView(popup: popup, hovered: controller.popupHovered)
                    }
                }
                .transition(Self.contentTransition)
            } else {
                PopupView(popup: popup, hovered: controller.popupHovered)
                    .transition(Self.contentTransition)
            }
        case .hud(let hud):
            HUDView(hud: hud)
                .transition(Self.contentTransition)
        case .liveActivity(let activity):
            LiveActivityView(activity: activity)
                .transition(Self.contentTransition)
        }
    }

    /// Content grows in from the top edge (where the island hangs off the notch)
    /// with a gentle scale + fade, but leaves with a quick fade only — so the
    /// outgoing layout never lingers or stretches while the shell is resizing.
    private static let contentTransition: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
        removal: .opacity)

    @ViewBuilder
    private func compactView(_ app: IslandApp) -> some View {
        switch app {
        case .calendar:
            CalendarCompactView(controller: controller, calendar: controller.calendarManager)
        case .music:
            CompactPlayerView(controller: controller)
        case .timers:
            TimerCompactView(controller: controller, timers: controller.timerManager)
        case .weather:
            WeatherCompactView(controller: controller, weather: controller.weatherManager)
        case .dashboard:
            DashboardCompactView(controller: controller)
        case .calculator:
            CalculatorCompactView(controller: controller, calculator: controller.calculator)
        }
    }

    /// The pane to the right of the icon sidebar in the unified expanded/settings
    /// branch. Settings rides as a sibling of the app content, so switching to it
    /// keeps the shell + sidebar mounted and only cross-fades this inner view.
    @ViewBuilder
    private var expandedPane: some View {
        ZStack {
            if controller.isShowingSettings {
                SettingsView(controller: controller)
                    .transition(.opacity)
            } else {
                appContent(controller.displayedApp)
                    .transition(.opacity)
            }
        }
        .animation(contentMorph, value: controller.isShowingSettings)
        .animation(contentMorph, value: controller.displayedApp)
    }

    @ViewBuilder
    private func appContent(_ app: IslandApp) -> some View {
        switch app {
        case .calendar:
            CalendarExpandedView(controller: controller, calendar: controller.calendarManager)
        case .music:
            MusicView(controller: controller)
        case .timers:
            TimerExpandedView(controller: controller, timers: controller.timerManager)
        case .weather:
            WeatherExpandedView(controller: controller, weather: controller.weatherManager)
        case .dashboard:
            DashboardView(controller: controller,
                          timers: controller.timerManager,
                          calendar: controller.calendarManager,
                          weather: controller.weatherManager)
        case .calculator:
            CalculatorView(controller: controller, calculator: controller.calculator)
        }
    }

    /// Wraps an expanded app's content with the left icon sidebar.
    private func expandedContainer<C: View>(selected: IslandApp,
                                            @ViewBuilder content: () -> C) -> some View {
        // Settings always uses the standard card width; otherwise the displayed
        // app picks its own content width (Calendar is wider). Keeping this in
        // lock-step with the shell geometry avoids the inner pane over/underflowing
        // mid-morph.
        let contentWidth = controller.isShowingSettings
            ? controller.configuration.expandedWidth
            : controller.expandedContentWidth(for: selected)
        return HStack(spacing: 0) {
            AppSidebarView(controller: controller, selected: selected)
            content()
                .frame(width: contentWidth)
        }
    }

    // MARK: Secondary islands & side indicators

    private enum SideContent {
        case secondary(DynamicIslandController.SecondaryIsland)
        case indicator(IslandExtension)
    }

    /// Which edge of the main island a side item rides off.
    private enum SidePlacement {
        case leading   // off the island's left edge
        case trailing  // off the island's right edge
    }

    private struct SideItem {
        let id: String
        let width: CGFloat
        let content: SideContent
        let placement: SidePlacement
    }

    private struct LaidSideItem: Identifiable {
        let item: SideItem
        /// Horizontal offset of the item's centre from the canvas top-centre.
        let x: CGFloat
        /// Vertical offset of the item's top edge below the canvas top.
        let y: CGFloat
        var id: String { item.id }
    }

    @ViewBuilder
    private func sideIslandsLayer(islandWidth: CGFloat) -> some View {
        let height = controller.extensionBarHeight
        let laid = laidOutSideItems(islandWidth: islandWidth, height: height)
        ZStack {
            ForEach(laid) { entry in
                sideItemView(entry.item, height: height)
                    // Emerge from behind the main island: the transition starts it
                    // tucked at centre (x = 0, fully occluded) and slides it out to
                    // the resting x.
                    .transition(slideOutTransition(toRestingX: entry.x))
                    .allowsHitTesting(false)
                    // Offset OUTSIDE the transition so its slide anchors at the
                    // blob's own centre (see the anchor-bug note in memory).
                    .offset(x: entry.x, y: entry.y)
            }
        }
    }

    /// A side blob slides out sideways from behind the main island. The insertion
    /// offset (`-restingX`) returns it to centre — hidden behind the island — then
    /// it animates to its resting offset, emerging past the edge. Symmetric, so it
    /// tucks back behind on removal.
    private func slideOutTransition(toRestingX restingX: CGFloat) -> AnyTransition {
        .offset(x: -restingX).combined(with: .opacity)
    }

    @ViewBuilder
    private func sideItemView(_ item: SideItem, height: CGFloat) -> some View {
        switch item.content {
        case .secondary(let island):
            SecondaryAppIslandView(controller: controller, island: island, height: height)
        case .indicator(let ext):
            IslandExtensionView(model: ext, height: height)
        }
    }

    /// The secondary app islands (music bubble, extra timer) ride off the trailing
    /// edge, sliding out from behind the island.
    private func secondaryItems(height: CGFloat) -> [SideItem] {
        controller.secondaryIslands.map { island in
            SideItem(id: "sec." + island.id,
                     width: SecondaryAppIslandView.width(for: island, height: height),
                     content: .secondary(island),
                     placement: .trailing)
        }
    }

    /// Indicator extensions (the camera/mic blob) for a given edge.
    private func indicatorItems(height: CGFloat, edge: IslandExtensionEdge) -> [SideItem] {
        controller.islandExtensions
            .filter { $0.edge == edge }
            .map { ext in
                SideItem(id: "ext." + ext.id,
                         width: IslandExtensionView.width(for: ext, height: height),
                         content: .indicator(ext),
                         placement: edge == .leading ? .leading : .trailing)
            }
    }

    /// Lays out every side item beside the main island, all aligned with its top
    /// (`y = topInset`). Offsets are relative to the canvas's top-centre.
    ///
    /// Trailing items (camera/mic on the trailing edge, then the secondary app
    /// islands beyond them) march out to the right of `+islandWidth/2`; leading
    /// items (camera/mic on the leading edge) march out to the left of
    /// `-islandWidth/2`. Each starts flush with the island's edge, so it slides
    /// cleanly out from behind it.
    private func laidOutSideItems(islandWidth: CGFloat, height: CGFloat) -> [LaidSideItem] {
        let gap = controller.configuration.extensionDetachedGap
        let topInset = controller.configuration.topInset
        var result: [LaidSideItem] = []

        // Trailing edge (right): trailing indicators hug the island, then the
        // secondary app islands beyond them.
        var right = islandWidth / 2
        for item in indicatorItems(height: height, edge: .trailing) + secondaryItems(height: height) {
            right += gap
            result.append(LaidSideItem(item: item, x: right + item.width / 2, y: topInset))
            right += item.width
        }

        // Leading edge (left, negative x): leading indicators.
        var left = -islandWidth / 2
        for item in indicatorItems(height: height, edge: .leading) {
            left -= gap
            result.append(LaidSideItem(item: item, x: left - item.width / 2, y: topInset))
            left -= item.width
        }
        return result
    }
}
