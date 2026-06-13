import Combine
import CoreGraphics
import Foundation

/// The central coordinator for the island.
///
/// Owns the now-playing state, the timers, and hover/selection state; derives
/// the presentation `mode` and `geometry` from them; holds the integration
/// registries; and forwards transport intents from the view to the music
/// provider.
///
/// The island hosts multiple "apps" (Music, Timers, …) ranked by a fixed
/// hierarchy (see `IslandApp.priority`). The top active app fills the main
/// island; the rest ride alongside as secondary side islands. While expanded a
/// sidebar lets the user pick which app fills the main island.
@MainActor
final class DynamicIslandController: ObservableObject {

    /// Current Apple Music state, or `nil` when nothing is playing.
    @Published private(set) var nowPlaying: NowPlaying?

    /// The user's timers and stopwatches.
    let timerManager: TimerManager

    /// Upcoming calendar events and the imminent-event live activity.
    let calendarManager: CalendarManager

    /// Current weather reading, refreshed periodically.
    let weatherManager: WeatherManager

    /// Per-app volume tweak: app list + persisted settings + the audio engine.
    let appVolumeStore: AppVolumeStore

    /// Whether the pointer is currently over the island.
    @Published private(set) var isHovered: Bool = false

    /// Whether the volume bar is revealed (pointer over the volume zone).
    @Published private(set) var volumeRevealed: Bool = false

    /// Which slider the pointer is currently over (drives hover thickening).
    enum HoverableControl { case none, progress, volume }
    @Published private(set) var hoveredControl: HoverableControl = .none

    /// Whether the settings page is showing (gear selected in the sidebar).
    /// Reset when the pointer leaves.
    @Published private(set) var showingSettings: Bool = false

    /// The app the user has pinned into the main island via the sidebar; `nil`
    /// means "follow the hierarchy" (show the top active app). Reset on exit.
    @Published private(set) var selectedApp: IslandApp?

    /// Whether the countdown creator is open in the timers app (affects height).
    @Published var isCreatingTimer: Bool =
        ProcessInfo.processInfo.environment["DI_FORCE_CREATOR"] == "1"

    /// Whether a text field (timer rename / name entry) is being edited. While
    /// true the island stays open and the panel takes keyboard focus.
    @Published private(set) var isEditing: Bool = false

    /// Whether the island is "pinned" open: it stays expanded regardless of hover
    /// (like a runtime `forceExpanded`), while the desktop stays interactive — the
    /// window controller passes clicks through whenever the pointer isn't actually
    /// over the card. Toggled by the thumbtack/✕ affordance in the card's
    /// top-right corner.
    @Published private(set) var pinned: Bool =
        ProcessInfo.processInfo.environment["DI_FORCE_PIN"] == "1"

    /// Whether the pointer is over the top-right corner zone where the pin
    /// affordance lives. Set by the window controller's hover poll; reveals the
    /// thumbtack button while unpinned (the ✕ shows persistently once pinned).
    @Published private(set) var pinCornerHovered: Bool = false

    /// Side accessories riding at the island's edges (camera/mic indicator, …).
    /// Pushed by `IslandExtensionProvider`s.
    @Published private(set) var islandExtensions: [IslandExtension] = []

    /// A popup (notification / live activity) currently taking over the island,
    /// or `nil`. Popups sit at the very top of the hierarchy — see `mode`.
    @Published private(set) var activePopup: IslandPopup?

    /// A transient compact live activity (e.g. the onboarding "open me" hint), or
    /// `nil`. UNLIKE a popup it does not block hover — it sits in the compact slot
    /// and yields to hover/click/scroll, auto-clearing after its duration.
    @Published private(set) var liveActivity: LiveActivity?
    private var liveActivityWork: DispatchWorkItem?

    /// A transient volume/brightness HUD taking over the island, or `nil`. Sits
    /// ABOVE popups in the hierarchy and auto-dismisses after `hudDuration`.
    @Published private(set) var activeHUD: SystemHUD?
    private var hudDismissWork: DispatchWorkItem?
    /// How long the HUD lingers after the last adjustment, matching the feel of
    /// the system overlay it replaces. Each new adjustment refreshes the timer.
    private let hudDuration: TimeInterval = 1.4

    /// A directional kick the view springs on each volume/brightness keypress so
    /// the island visibly "nudges" up/down with the change. `token` changes every
    /// press (even repeats at the same level) so the view's `onChange` always
    /// fires; `direction` is +1 (up), -1 (down), or 0 (e.g. mute).
    struct HUDNudge: Equatable {
        var token: Int = 0
        var direction: Int = 0
    }
    @Published private(set) var hudNudge = HUDNudge()

    /// Whether the pointer is over the active popup (grows it a little to signal
    /// it's clickable). Only meaningful while `activePopup != nil`.
    @Published private(set) var popupHovered: Bool = false

    /// While a popup is up — and for `popupImmunityTail` after it clears — the
    /// island ignores hover-to-expand, so the pointer can't shove the popup
    /// aside and the island doesn't snap open the instant the popup goes away.
    private(set) var popupImmuneUntil: Date = .distantPast
    private let popupImmunityTail: TimeInterval = 1.5

    /// True while hover-to-expand should be ignored (a popup is present, or it
    /// dismissed less than `popupImmunityTail` ago). The window controller
    /// consults this in its hover poll.
    var blocksHoverActivation: Bool {
        activePopup != nil || activeHUD != nil || Date() < popupImmuneUntil
    }

    /// While in the future, Weather briefly takes over the compact notch: a
    /// severe-weather alert or a condition change just landed (see
    /// `WeatherManager.significantChange`). It's a glanceable, compact-only
    /// takeover — it sits below popups/HUD and yields to hover (hovering during
    /// the flash expands Weather, since that's what the pill is showing).
    private var weatherFlashUntil: Date = .distantPast
    private var weatherFlashWork: DispatchWorkItem?
    /// How long the weather flash lingers in the notch.
    private let weatherFlashDuration: TimeInterval = 10

    /// True while the weather flash owns the compact notch.
    var weatherFlashActive: Bool { Date() < weatherFlashUntil }

    /// Static layout/behaviour settings.
    let configuration: IslandConfiguration

    /// User-tweakable preferences (persisted), shared with the SwiftUI views.
    let settings: AppSettings

    /// Hook the window controller sets to focus/unfocus the panel for text edits.
    var onEditingChange: ((Bool) -> Void)?

    /// Hook for "open the popup's app" on left-click. Wired by the host to do
    /// whatever opening means for that app (launch/focus it, force-expand the
    /// island to it, …). Optional — `nil` just selects the app + dismisses.
    var onPopupOpenApp: ((IslandApp) -> Void)?

    /// Hook for "launch the external app behind this notification" on left-click
    /// — used by mirrored system notifications, which carry a `launchBundleID`
    /// rather than an internal `IslandApp`. Wired by the host to NSWorkspace.
    var onPopupLaunchBundle: ((String) -> Void)?

    /// Debug: DI_FORCE_EXPANDED=1 pins the expanded layout; DI_FORCE_VOLUME=1
    /// also reveals the volume bar; DI_FORCE_SETTINGS=1 pins the settings page.
    private let forceExpanded = ProcessInfo.processInfo.environment["DI_FORCE_EXPANDED"] == "1"
    private let forceVolume = ProcessInfo.processInfo.environment["DI_FORCE_VOLUME"] == "1"
    private let forceSettings = ProcessInfo.processInfo.environment["DI_FORCE_SETTINGS"] == "1"
    /// DI_FORCE_NOMUSIC=1 suppresses now-playing (to exercise the music
    /// "Nothing Playing" placeholder without disturbing real playback).
    private let forceNoMusic = ProcessInfo.processInfo.environment["DI_FORCE_NOMUSIC"] == "1"
    /// DI_FORCE_POPUP=1 seeds a sample popup at launch (to exercise the popup
    /// takeover / hover-grow visuals).
    private let forcePopup = ProcessInfo.processInfo.environment["DI_FORCE_POPUP"] == "1"
    /// DI_MOCK_HUD=volume|brightness|keyboard seeds a sample HUD at launch (to
    /// exercise the overlay visuals without the event tap / a keypress).
    private let mockHUD: SystemHUD? = {
        switch ProcessInfo.processInfo.environment["DI_MOCK_HUD"]?.lowercased() {
        case "volume", "vol": return SystemHUD(kind: .volume, level: 0.6)
        case "brightness", "bright": return SystemHUD(kind: .brightness, level: 0.75)
        case "keyboard", "kbd", "kb": return SystemHUD(kind: .keyboardBacklight, level: 0.5)
        case "mute", "muted": return SystemHUD(kind: .volume, level: 0.6, muted: true)
        default: return nil
        }
    }()
    /// DI_FORCE_APP=timers|music pins which app fills the main island.
    private let forcedApp: IslandApp? = {
        switch ProcessInfo.processInfo.environment["DI_FORCE_APP"]?.lowercased() {
        case "timers", "timer": return .timers
        case "music": return .music
        case "calendar", "cal": return .calendar
        case "weather": return .weather
        case "dashboard", "dash", "home": return .dashboard
        case "tweaks": return .tweaks
        default: return nil
        }
    }()

    private var cancellables: Set<AnyCancellable> = []

    init(configuration: IslandConfiguration = .default,
         settings: AppSettings? = nil) {
        self.configuration = configuration
        self.settings = settings ?? AppSettings()
        self.timerManager = TimerManager(settings: self.settings)
        self.calendarManager = CalendarManager(settings: self.settings)
        self.weatherManager = WeatherManager(settings: self.settings)
        self.appVolumeStore = AppVolumeStore()
        // Timer add/remove/pause changes the island's size and hierarchy, so
        // re-publish when the timer store does.
        timerManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Calendar events (and an event becoming / ceasing to be imminent) change
        // the hierarchy and the live activity, so re-publish with the manager.
        calendarManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // A new weather reading re-renders the weather views.
        weatherManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // A severe alert / condition change briefly promotes Weather to the notch.
        weatherManager.significantChange
            .sink { [weak self] in self?.flashWeather() }
            .store(in: &cancellables)
        // The app-volume list / settings re-render the Tweaks page.
        appVolumeStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        appVolumeStore.start()

        if forcePopup {
            presentPopup(IslandPopup(id: "demo",
                                     title: "John Bob",
                                     message: "Do you want to get pizza?",
                                     icon: .symbol("message.fill"),
                                     accent: .blue))
        }
        // Seed a persistent mock HUD for screenshots (set directly so it doesn't
        // auto-dismiss the way a real keypress-driven one does).
        if let mockHUD { activeHUD = mockHUD }
    }

    // MARK: App hierarchy

    /// Apps with something live right now, highest-priority first.
    var activeApps: [IslandApp] {
        var apps: [IslandApp] = []
        // Calendar is only "active" (in the hierarchy / filling the main island)
        // while an event is imminent — its live activity. Otherwise it's still
        // reachable any time via the sidebar, just not vying for the notch.
        if calendarManager.hasImminentEvent { apps.append(.calendar) }
        if nowPlaying != nil { apps.append(.music) }
        if timerManager.hasActive { apps.append(.timers) }
        return apps.sorted { $0.priority < $1.priority }
    }

    /// The highest-priority active app (fills the main island by default).
    var topApp: IslandApp? { activeApps.first }

    /// The app that fills the main island while expanded. Resolution order:
    /// a debug force, then the user's explicit sidebar pick, then (while a weather
    /// flash is active) Weather so hovering the flashing pill expands what you're
    /// looking at, else the DASHBOARD — the aggregate "home" that sits above Music
    /// and embeds a mini player, calendar, and weather. (The compact/not-hovered
    /// notch still follows `activeApps` via `topApp`, so a glance shows the live
    /// app; hovering opens the dashboard, from which the sidebar reaches each full
    /// app.)
    var displayedApp: IslandApp {
        forcedApp ?? selectedApp ?? (weatherFlashActive ? .weather : nil) ?? .dashboard
    }

    /// The app filling the main island, for the purpose of deciding what spills
    /// over into secondary islands (idle spills nothing).
    private var mainAppForSecondaries: IslandApp? {
        switch mode {
        case .idle: return nil
        case .compact(let app), .expanded(let app): return app
        // Settings doesn't itself show a player, so it shouldn't swallow the music
        // side island the way the Music app does — nowPlaying should ride alongside
        // Settings exactly as it does alongside Calendar / Weather / Timers.
        case .settings: return nil
        case .popup, .hud, .liveActivity: return nil // these suppress secondaries entirely (below)
        }
    }

    /// A compact island shown alongside the main one for an app or timer that
    /// isn't filling the main island.
    struct SecondaryIsland: Identifiable, Equatable {
        enum Kind: Equatable {
            case music
            /// A timers chip for a specific timer; `showsMore` flags that more
            /// timers exist than are currently shown (renders a green dot).
            case timer(IslandTimer, showsMore: Bool)
        }
        let id: String
        let kind: Kind
    }

    /// Compact islands to show alongside the main one, ordered closest-first:
    ///   - Music, when it's active but not filling the main island.
    ///   - A timers chip: when Timers *fills* the main island the chip surfaces
    ///     the SECOND timer (so a second running timer/stopwatch gets its own
    ///     island); otherwise it surfaces the headline timer. A green dot flags
    ///     that still more timers exist than are shown.
    var secondaryIslands: [SecondaryIsland] {
        // A popup or HUD is a focused takeover — nothing rides alongside it.
        if activePopup != nil || activeHUD != nil { return [] }
        let main = mainAppForSecondaries
        // The Dashboard already embeds mini Music + Timers, so nothing spills out
        // alongside it — that would just duplicate what the card is showing.
        if main == .dashboard { return [] }
        var result: [SecondaryIsland] = []

        if nowPlaying != nil, main != .music {
            result.append(SecondaryIsland(id: "music", kind: .music))
        }

        if timerManager.hasActive {
            let ordered = timerManager.ordered()
            if main == .timers {
                if ordered.count >= 2 {
                    let t = ordered[1]
                    result.append(SecondaryIsland(
                        id: "timer." + t.id.uuidString,
                        kind: .timer(t, showsMore: ordered.count > 2)))
                }
            } else if let t = ordered.first {
                result.append(SecondaryIsland(
                    id: "timer." + t.id.uuidString,
                    kind: .timer(t, showsMore: ordered.count > 1)))
            }
        }
        return result
    }

    // MARK: Derived presentation

    /// Derived presentation mode.
    var mode: IslandMode {
        // The HUD sits above everything: a hardware key-press is an immediate
        // intent that briefly owns the island, then auto-dismisses.
        if let hud = activeHUD { return .hud(hud) }
        // Popups sit just below: while one is present it owns the main island
        // regardless of hover, app priority, or selection.
        if let popup = activePopup { return .popup(popup) }
        let hovered = isHovered || pinned || forceExpanded || forceSettings || isEditing
        if !hovered {
            // A debug-forced app pins the compact pill too (so DI_FORCE_APP can
            // exercise an app that isn't otherwise in the active hierarchy, e.g.
            // Weather). In production `forcedApp` is nil and this is a no-op.
            if let forced = forcedApp { return .compact(forced) }
            // A transient live activity (e.g. the onboarding hint) owns the compact
            // slot while it's up — but only when NOT hovered, so hovering still
            // opens the island (it's already in the `!hovered` branch).
            if let activity = liveActivity { return .liveActivity(activity) }
            // A severe alert / condition change briefly takes over the notch even
            // when nothing else is active (so it can interrupt the idle pill too).
            if weatherFlashActive { return .compact(.weather) }
            guard let top = topApp else { return .idle }
            return .compact(top)
        }
        if showingSettings || forceSettings { return .settings }
        return .expanded(displayedApp)
    }

    /// Whether the music volume bar should be shown (real reveal or forced).
    var volumeBarVisible: Bool { volumeRevealed || forceVolume }

    /// Geometry for the current mode.
    var geometry: IslandGeometry {
        let c = configuration
        switch mode {
        case .idle:
            let s = CGSize(width: c.collapsedWidth, height: c.collapsedHeight)
            return IslandGeometry(size: s, cornerRadius: s.height / 2)
        case .compact(let app):
            let s = compactSize(app)
            return IslandGeometry(size: s, cornerRadius: s.height / 2)
        case .expanded(let app):
            return IslandGeometry(size: expandedSize(app), cornerRadius: c.expandedCornerRadius)
        case .settings:
            let s = CGSize(width: c.expandedTotalWidth, height: c.settingsHeight)
            return IslandGeometry(size: s, cornerRadius: c.expandedCornerRadius)
        case .popup:
            // Grows a little on hover to signal it's clickable.
            let s = CGSize(width: popupHovered ? c.popupHoveredWidth : c.popupWidth,
                           height: popupHovered ? c.popupHoveredHeight : c.popupHeight)
            return IslandGeometry(size: s, cornerRadius: c.popupCornerRadius)
        case .hud:
            // A fully-rounded pill, like the iPhone's volume readout.
            let s = CGSize(width: c.hudWidth, height: c.hudHeight)
            return IslandGeometry(size: s, cornerRadius: s.height / 2)
        case .liveActivity:
            // A compact pill, like the weather flash.
            let s = CGSize(width: c.liveActivityWidth, height: c.compactHeight)
            return IslandGeometry(size: s, cornerRadius: s.height / 2)
        }
    }

    private func compactSize(_ app: IslandApp) -> CGSize {
        switch app {
        case .calendar: return CGSize(width: configuration.calendarCompactWidth, height: configuration.compactHeight)
        case .music: return CGSize(width: configuration.compactWidth, height: configuration.compactHeight)
        case .timers: return CGSize(width: configuration.timerCompactWidth, height: configuration.compactHeight)
        case .weather: return CGSize(width: configuration.weatherCompactWidth, height: configuration.compactHeight)
        case .dashboard: return CGSize(width: configuration.dashboardCompactWidth, height: configuration.compactHeight)
        case .tweaks: return CGSize(width: configuration.tweaksCompactWidth, height: configuration.compactHeight)
        }
    }

    private func expandedSize(_ app: IslandApp) -> CGSize {
        let c = configuration
        switch app {
        case .calendar:
            return CGSize(width: c.expandedTotalWidth, height: c.calendarExpandedHeight)
        case .music:
            let h = volumeBarVisible ? c.expandedVolumeHeight : c.expandedHeight
            return CGSize(width: c.expandedTotalWidth, height: h)
        case .timers:
            return CGSize(width: c.expandedTotalWidth, height: timersExpandedHeight)
        case .weather:
            return CGSize(width: c.expandedTotalWidth, height: c.weatherExpandedHeight)
        case .dashboard:
            return CGSize(width: c.expandedTotalWidth, height: c.dashboardExpandedHeight)
        case .tweaks:
            // The EQ & Spatial detail page grows the card; everything else stays 324.
            let height = appVolumeStore.eqPageActive ? c.tweaksEQHeight : c.tweaksExpandedHeight
            return CGSize(width: c.expandedTotalWidth, height: height)
        }
    }

    /// Width of the app-content area (right of the sidebar) while expanded. Every
    /// app now shares the single standardized `expandedWidth`, so this is the same
    /// for all of them (including Settings).
    func expandedContentWidth(for app: IslandApp) -> CGFloat {
        // Every app shares the standard width; Music fits its queue sidebar WITHIN
        // this width by compressing the player.
        configuration.expandedWidth
    }

    /// Height of the expanded timers card: base chrome + a row per visible timer
    /// (the list scrolls past `timersMaxRows`) + the creator when open.
    var timersExpandedHeight: CGFloat {
        let c = configuration
        let count = min(timerManager.timers.count, c.timersMaxRows)
        let rowsHeight: CGFloat
        if count == 0 {
            rowsHeight = 26 // "no timers yet" line
        } else {
            rowsHeight = CGFloat(count) * c.timerRowHeight
                + CGFloat(count - 1) * c.timersRowSpacing
        }
        let creator = isCreatingTimer ? c.timerCreatorHeight : 0
        let content = c.timersBaseHeight + rowsHeight + creator
        // Never let the timers card look "compressed": keep at least the standard
        // expanded page height (same as the music card) so the empty / few-timer
        // state reads as a real page, growing only once the list needs more room.
        // The empty placeholder is centered, so this reads as a roomy page, not a
        // void.
        return max(content, c.expandedHeight)
    }

    /// The height side extensions should match — the island's current bar
    /// height. Idle has no pill, so extensions ride at the collapsed height;
    /// once an app shows they grow to the compact bar height.
    var extensionBarHeight: CGFloat {
        mode == .idle ? configuration.collapsedHeight : configuration.compactHeight
    }

    // MARK: Integration registries (framework seams)

    private(set) var contentProviders: [any IslandContentProvider] = []

    /// The registered music provider, if any. Transport intents route here.
    private(set) weak var musicProvider: (any MusicIslandProvider)?

    /// Live extension providers (camera/mic, …), retained so they keep polling.
    private var extensionProviders: [any IslandExtensionProvider] = []

    /// Handles pointer interaction (hover → expand/collapse).
    var interactionHandler: (any IslandInteractionHandler)?

    // MARK: Registration

    func register(_ provider: any IslandContentProvider) {
        guard !contentProviders.contains(where: { $0.id == provider.id }) else { return }
        contentProviders.append(provider)
        if let music = provider as? any MusicIslandProvider {
            musicProvider = music
        }
        provider.didRegister(with: self)
    }

    /// Register a side-extension provider and start it.
    func register(extensionProvider provider: any IslandExtensionProvider) {
        guard !extensionProviders.contains(where: { $0.extensionID == provider.extensionID }) else { return }
        extensionProviders.append(provider)
        provider.startProviding(into: self)
    }

    // MARK: State updates (called by providers / interaction)

    func updateNowPlaying(_ nowPlaying: NowPlaying?) {
        self.nowPlaying = forceNoMusic ? nil : nowPlaying
    }

    /// Insert or update a side extension (keyed by its `id`), kept sorted by
    /// edge/order so layout is stable.
    func setExtension(_ ext: IslandExtension) {
        if let idx = islandExtensions.firstIndex(where: { $0.id == ext.id }) {
            guard islandExtensions[idx] != ext else { return }
            islandExtensions[idx] = ext
        } else {
            islandExtensions.append(ext)
        }
        islandExtensions.sort { $0.order < $1.order }
    }

    func removeExtension(id: String) {
        guard let idx = islandExtensions.firstIndex(where: { $0.id == id }) else { return }
        islandExtensions.remove(at: idx)
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        if hovered {
            // A glance is enough to acknowledge a ringing timer: silence and
            // clear any that have fired the moment the pointer arrives.
            timerManager.dismissRinging()
            // Opening the island consumes a transient hint (e.g. onboarding).
            clearLiveActivity()
        } else if isEditing {
            // Mid-edit the pointer often slips out while the text field still has
            // focus — keep everything as-is.
        } else if pinned {
            // Pinned open: keep the displayed app/page, but drop the hover-only
            // transient bits (a revealed volume bar, slider hover) so nothing
            // looks "stuck on" once the pointer leaves.
            if volumeRevealed { volumeRevealed = false }
            if hoveredControl != .none { hoveredControl = .none }
            if pinCornerHovered { pinCornerHovered = false }
        } else {
            // Leaving the island tucks everything away.
            resetTransientState()
        }
    }

    /// Toggle the pinned-open state. Pinning freezes the currently displayed app
    /// so a change in the active hierarchy can't swap it out; unpinning while the
    /// pointer is away collapses the island back to normal.
    func togglePin() {
        pinned.toggle()
        if pinned {
            if selectedApp == nil { selectedApp = displayedApp }
        } else if !isHovered {
            resetTransientState()
        }
    }

    func setPinCornerHovered(_ hovered: Bool) {
        guard pinCornerHovered != hovered else { return }
        pinCornerHovered = hovered
    }

    /// Clears the volume bar, slider hover, settings page, sidebar pick, and the
    /// timer creator so the next hover starts from the hierarchy default.
    private func resetTransientState() {
        if volumeRevealed { volumeRevealed = false }
        if hoveredControl != .none { hoveredControl = .none }
        if showingSettings { showingSettings = false }
        if selectedApp != nil { selectedApp = nil }
        if isCreatingTimer { isCreatingTimer = false }
    }

    // MARK: App selection (sidebar)

    func selectApp(_ app: IslandApp) {
        // Leaving settings counts as a real change even when the tapped app is
        // already `selectedApp` — that's how the user returns to the page they
        // were on. So close settings BEFORE the no-op guard.
        let leavingSettings = showingSettings
        if showingSettings { showingSettings = false }
        guard selectedApp != app || leavingSettings else { return }
        selectedApp = app
        // Switching apps closes app-specific transient UI.
        if app != .music, volumeRevealed { volumeRevealed = false }
        if app != .timers, isCreatingTimer { isCreatingTimer = false }
    }

    /// Cycle the main-island app by `steps` (e.g. +1/-1 from a scroll), wrapping
    /// around `IslandApp` in priority order. Settings is NOT part of the rotation
    /// (it's reached only via its sidebar icon). The window controller calls this
    /// off the scroll wheel while expanded.
    func cycleApp(by steps: Int) {
        // Cycle in SIDEBAR order so a scroll moves sequentially through the visible
        // sidebar (cycling in priority order made the highlight jump — e.g. Calendar,
        // which is priority 0 but sits 4th in the sidebar, looked skipped).
        let apps = IslandApp.allCases.sorted { $0.sidebarOrder < $1.sidebarOrder }
        guard apps.count > 1, let idx = apps.firstIndex(of: displayedApp) else { return }
        let next = apps[((idx + steps) % apps.count + apps.count) % apps.count]
        selectApp(next)
    }

    /// Whether the expanded timers list has more rows than fit (so it scrolls).
    /// Used to let the scroll wheel scroll that list instead of switching apps.
    var timersListOverflows: Bool {
        timerManager.timers.count > configuration.timersMaxRows
    }

    // MARK: Text editing focus

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        onEditingChange?(true)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        onEditingChange?(false)
        // The pointer may have left while editing; collapse now if so.
        if !isHovered { resetTransientState() }
    }

    // MARK: Settings page

    /// Whether the settings pane is the one displayed in the expanded card —
    /// either the user opened it or it's forced on for debugging. The view layer
    /// keys the expanded/settings cross-fade off this (not the raw
    /// `showingSettings`) so the debug flag renders correctly too.
    var isShowingSettings: Bool { showingSettings || forceSettings }

    func toggleSettings() {
        showingSettings.toggle()
        if showingSettings, volumeRevealed { volumeRevealed = false }
    }

    func setShowingSettings(_ showing: Bool) {
        guard showingSettings != showing else { return }
        showingSettings = showing
        if showing, volumeRevealed { volumeRevealed = false }
    }

    // MARK: Popups (notifications / live activities)

    /// Show a transient compact live activity (NOT a takeover popup): it occupies
    /// the compact slot while up but yields to hover/click/scroll, and auto-clears
    /// after `duration` (or the moment the user opens the island).
    func presentLiveActivity(_ activity: LiveActivity, duration: TimeInterval) {
        liveActivity = activity
        liveActivityWork?.cancel()
        let id = activity.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.liveActivity?.id == id else { return }
            self.liveActivity = nil
        }
        liveActivityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func clearLiveActivity() {
        guard liveActivity != nil else { return }
        liveActivityWork?.cancel()
        liveActivity = nil
    }

    /// First-use nudge shown the moment onboarding hands off to the real island:
    /// a transient live activity teaching the gesture the user picked to open it.
    func presentOnboardingHint() {
        let line: String
        let symbol: String
        switch settings.expandTrigger {
        case .hover:  line = "Hover me to open";   symbol = "hand.point.up.left.fill"
        case .click:  line = "Click me to open";   symbol = "hand.tap.fill"
        case .scroll: line = "Scroll down on me";  symbol = "arrow.down"
        }
        presentLiveActivity(
            LiveActivity(id: "onboarding-hint", symbol: symbol, title: line, accent: Palette.indigo),
            duration: 6)
    }

    /// Present a popup, taking over the island immediately. Replaces any popup
    /// already showing (last-in wins). Arms auto-dismiss if the popup requests
    /// it, and marks the island immune to hover while it's up.
    func presentPopup(_ popup: IslandPopup) {
        activePopup = popup
        popupHovered = false
        popupImmuneUntil = .distantFuture // immune for as long as it's up
        if let delay = popup.autoDismissAfter {
            let id = popup.id
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.activePopup?.id == id else { return }
                self.dismissPopup()
            }
        }
    }

    /// Dismiss the active popup (right-click, or auto-dismiss), starting the
    /// brief hover-immunity tail so the island doesn't expand under the pointer.
    func dismissPopup() {
        guard activePopup != nil else { return }
        activePopup = nil
        popupHovered = false
        popupImmuneUntil = Date().addingTimeInterval(popupImmunityTail)
    }

    /// Left-click action: open whatever the popup points at, then dismiss. An
    /// internal `app` selects + opens it; otherwise a `launchBundleID` launches
    /// the external app (mirrored system notifications). With neither, it just
    /// dismisses.
    func activatePopup() {
        guard let popup = activePopup else { return }
        if let app = popup.app {
            selectApp(app)
            onPopupOpenApp?(app)
        } else if let bundleID = popup.launchBundleID {
            onPopupLaunchBundle?(bundleID)
        }
        dismissPopup()
    }

    func setPopupHovered(_ hovered: Bool) {
        guard popupHovered != hovered else { return }
        popupHovered = hovered
    }

    // MARK: Weather flash (severe alert / condition change)

    /// Briefly promote Weather to the compact notch for `weatherFlashDuration`.
    /// Driven by `WeatherManager.significantChange`. Re-arming refreshes the
    /// window; a trailing nudge re-renders so the pill collapses when it lapses.
    func flashWeather() {
        guard settings.weatherFlashOnChange else { return }
        weatherFlashUntil = Date().addingTimeInterval(weatherFlashDuration)
        weatherFlashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.objectWillChange.send() }
        weatherFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + weatherFlashDuration, execute: work)
        objectWillChange.send()
    }

    // MARK: System HUD (volume / brightness)

    /// Present (or refresh) the volume/brightness HUD, taking over the island.
    /// Each call resets the auto-dismiss timer so holding a key keeps it up; it
    /// fades out `hudDuration` after the last adjustment.
    func presentHUD(_ hud: SystemHUD, direction: Int = 0) {
        activeHUD = hud
        // Kick the bubble in the direction of the change for a fluid feel.
        hudNudge = HUDNudge(token: hudNudge.token &+ 1, direction: direction)
        hudDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.activeHUD = nil }
        hudDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hudDuration, execute: work)
    }

    func setVolumeRevealed(_ revealed: Bool) {
        guard volumeRevealed != revealed else { return }
        volumeRevealed = revealed
    }

    func setHoveredControl(_ control: HoverableControl) {
        guard hoveredControl != control else { return }
        hoveredControl = control
    }

    // MARK: Transport intents (called by the view)

    func playPause() { musicProvider?.togglePlayPause() }
    func nextTrack() { musicProvider?.nextTrack() }
    func previousTrack() { musicProvider?.previousTrack() }
    func seek(to time: TimeInterval) { musicProvider?.seek(to: time) }
    func setVolume(to volume: Double) { musicProvider?.setVolume(volume) }
    func toggleShuffle() { musicProvider?.toggleShuffle() }
    func cycleRepeat() { musicProvider?.cycleRepeat() }
    func toggleFavorite() { musicProvider?.toggleFavorite() }

    // MARK: Deep links

    func openSongPage() {
        guard let nowPlaying else { return }
        AppleMusicLinks.openSong(title: nowPlaying.title, artist: nowPlaying.artist)
    }

    func openArtistPage() {
        guard let nowPlaying, !nowPlaying.artist.isEmpty else { return }
        AppleMusicLinks.openArtist(nowPlaying.artist)
    }
}
