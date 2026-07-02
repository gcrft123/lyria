import SwiftUI

/// User-tweakable preferences, persisted in `UserDefaults`.
///
/// This is the single home for everything the user can adjust from the
/// settings page (the gear in the sidebar). It's intentionally an
/// `ObservableObject` injected
/// into the SwiftUI environment, so any view can read a setting and re-render
/// the moment it changes. As the app grows, add new groups here (notifications,
/// appearance, …); for now it covers the music player.
@MainActor
final class AppSettings: ObservableObject {

    // MARK: General / behaviour

    /// What gesture expands the island from its compact pill into the full card.
    enum ExpandTrigger: String, CaseIterable, Identifiable {
        case hover, click, scroll
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hover: return "Hover"
            case .click: return "Click"
            case .scroll: return "Scroll"
            }
        }
        /// One-line description shown under the picker.
        var hint: String {
            switch self {
            case .hover: return "Opens as soon as the pointer is over the island."
            case .click: return "Opens when you click the island; move away to close."
            case .scroll: return "Opens when you scroll down on the island."
            }
        }
    }

    /// How the island expands. `hover` is the default; `click`/`scroll` require a
    /// deliberate gesture so the island never opens just from passing the pointer.
    @Published var expandTrigger: ExpandTrigger {
        didSet { defaults.set(expandTrigger.rawValue, forKey: Key.expandTrigger) }
    }

    /// Set once the first-launch onboarding has been completed (or skipped), so it
    /// never auto-runs again. "Replay intro" in Settings flips this back to false.
    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    // MARK: Music

    /// Tint the island's glow / accents with the album artwork's colour.
    /// When off, a neutral accent is used instead.
    @Published var tintWithArtwork: Bool {
        didSet { defaults.set(tintWithArtwork, forKey: Key.tintWithArtwork) }
    }

    /// Show the thin progress glow along the bottom of the compact pill.
    @Published var showCompactGlow: Bool {
        didSet { defaults.set(showCompactGlow, forKey: Key.showCompactGlow) }
    }

    /// Show the animated equalizer bars (the now-playing glyph).
    @Published var showEqualizerBars: Bool {
        didSet { defaults.set(showEqualizerBars, forKey: Key.showEqualizerBars) }
    }

    /// Strength of the accent glow, 0 (none) … 1 (full). Scales the expanded
    /// card halo and the compact progress glow.
    @Published var glowIntensity: Double {
        didSet { defaults.set(glowIntensity, forKey: Key.glowIntensity) }
    }

    /// Shed accent-tinted glow ripples out from the island's left/right edges,
    /// pulsing in time with the music (a synthetic musical tempo — Music doesn't
    /// expose real beat data). Only animates while a track is actively playing.
    @Published var pulseToBeat: Bool {
        didSet { defaults.set(pulseToBeat, forKey: Key.pulseToBeat) }
    }

    /// Beat-glow ("wave") sensitivity vs PITCH — `wavePointCount` points, low→high
    /// frequency, each 0…1. Shapes how much different parts of the spectrum drive
    /// the glow (default favours bass).
    @Published var waveSensitivityPitch: [Double] {
        didSet { defaults.set(waveSensitivityPitch, forKey: Key.waveSensitivityPitch) }
    }

    /// Beat-glow sensitivity vs VOLUME — `wavePointCount` points, quiet→loud, each
    /// 0…1. Remaps loudness to glow response (default expands toward loud).
    @Published var waveSensitivityVolume: [Double] {
        didSet { defaults.set(waveSensitivityVolume, forKey: Key.waveSensitivityVolume) }
    }

    /// Number of draggable control points in each wave-sensitivity curve.
    static let wavePointCount = 5
    static let defaultPitchCurve: [Double] = [1.0, 0.72, 0.5, 0.34, 0.26]
    static let defaultVolumeCurve: [Double] = [0.0, 0.16, 0.4, 0.68, 1.0]

    /// Force a stored curve to exactly `wavePointCount` values in 0…1.
    static func sanitizedCurve(_ raw: [Double]?, fallback: [Double]) -> [Double] {
        guard let raw, raw.count == wavePointCount else { return fallback }
        return raw.map { max(0, min(1, $0)) }
    }

    // MARK: Notifications

    /// Replace the system's own notification banners with the island's mirror.
    /// When on (and Full Disk Access is granted), the app turns on Do Not
    /// Disturb so only the island's popups appear; off restores system banners.
    @Published var suppressSystemBanners: Bool {
        didSet { defaults.set(suppressSystemBanners, forKey: Key.suppressSystemBanners) }
    }

    // MARK: Calendar

    /// How many minutes before an event starts it becomes the notch live activity.
    @Published var calendarLeadMinutes: Int {
        didSet { defaults.set(calendarLeadMinutes, forKey: Key.calendarLeadMinutes) }
    }

    // MARK: Weather

    /// Show temperatures in Fahrenheit (off = Celsius). Changing this re-fetches.
    @Published var weatherUseFahrenheit: Bool {
        didSet { defaults.set(weatherUseFahrenheit, forKey: Key.weatherUseFahrenheit) }
    }

    /// Briefly promote Weather to the notch on a severe alert or a condition change.
    @Published var weatherFlashOnChange: Bool {
        didSet { defaults.set(weatherFlashOnChange, forKey: Key.weatherFlashOnChange) }
    }

    // MARK: Timers

    /// Play a chime when a countdown finishes.
    @Published var timerChimeEnabled: Bool {
        didSet { defaults.set(timerChimeEnabled, forKey: Key.timerChimeEnabled) }
    }

    /// Keep chiming until the ringing timer is dismissed (off = chime once).
    @Published var timerChimeRepeat: Bool {
        didSet { defaults.set(timerChimeRepeat, forKey: Key.timerChimeRepeat) }
    }

    // MARK: Displays

    /// Persistent UUIDs of displays the user has turned the island OFF for. Stored as
    /// opt-outs (not the enabled set) so a newly-connected display shows the island by
    /// default. Empty = the island may appear on every display.
    @Published var islandDisplayOptOut: Set<String> {
        didSet { defaults.set(Array(islandDisplayOptOut), forKey: Key.islandDisplayOptOut) }
    }

    /// Whether the island may appear on the display with this persistent id.
    func showsIsland(onDisplay persistentID: String) -> Bool {
        !islandDisplayOptOut.contains(persistentID)
    }

    /// Allowed lead-time choices (minutes) for the calendar live activity.
    static let calendarLeadChoices = [5, 10, 15, 30]

    // MARK: Storage

    private let defaults: UserDefaults

    private enum Key {
        static let expandTrigger = "general.expandTrigger"
        static let onboardingCompleted = "general.onboardingCompleted"
        static let tintWithArtwork = "music.tintWithArtwork"
        static let showCompactGlow = "music.showCompactGlow"
        static let showEqualizerBars = "music.showEqualizerBars"
        static let glowIntensity = "music.glowIntensity"
        static let pulseToBeat = "music.pulseToBeat"
        static let suppressSystemBanners = "notifications.suppressSystemBanners"
        static let calendarLeadMinutes = "calendar.leadMinutes"
        static let weatherUseFahrenheit = "weather.useFahrenheit"
        static let weatherFlashOnChange = "weather.flashOnChange"
        static let timerChimeEnabled = "timers.chimeEnabled"
        static let timerChimeRepeat = "timers.chimeRepeat"
        static let waveSensitivityPitch = "music.waveSensitivityPitch"
        static let waveSensitivityVolume = "music.waveSensitivityVolume"
        static let islandDisplayOptOut = "displays.islandOptOut"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Sensible defaults so a fresh install matches today's look.
        defaults.register(defaults: [
            Key.expandTrigger: ExpandTrigger.hover.rawValue,
            Key.tintWithArtwork: true,
            Key.showCompactGlow: true,
            Key.showEqualizerBars: true,
            Key.glowIntensity: 1.0,
            Key.pulseToBeat: true,
            Key.suppressSystemBanners: true,
            Key.calendarLeadMinutes: 15,
            Key.weatherUseFahrenheit: (Locale.current.usesMetricSystem == false),
            Key.weatherFlashOnChange: true,
            Key.timerChimeEnabled: true,
            Key.timerChimeRepeat: true,
            Key.waveSensitivityPitch: Self.defaultPitchCurve,
            Key.waveSensitivityVolume: Self.defaultVolumeCurve,
        ])
        // These initial assignments don't fire `didSet` (we're still in init).
        expandTrigger = ExpandTrigger(rawValue: defaults.string(forKey: Key.expandTrigger) ?? "") ?? .hover
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        tintWithArtwork = defaults.bool(forKey: Key.tintWithArtwork)
        showCompactGlow = defaults.bool(forKey: Key.showCompactGlow)
        showEqualizerBars = defaults.bool(forKey: Key.showEqualizerBars)
        glowIntensity = defaults.double(forKey: Key.glowIntensity)
        pulseToBeat = defaults.bool(forKey: Key.pulseToBeat)
        suppressSystemBanners = defaults.bool(forKey: Key.suppressSystemBanners)
        calendarLeadMinutes = defaults.integer(forKey: Key.calendarLeadMinutes)
        weatherUseFahrenheit = defaults.bool(forKey: Key.weatherUseFahrenheit)
        weatherFlashOnChange = defaults.bool(forKey: Key.weatherFlashOnChange)
        timerChimeEnabled = defaults.bool(forKey: Key.timerChimeEnabled)
        timerChimeRepeat = defaults.bool(forKey: Key.timerChimeRepeat)
        waveSensitivityPitch = Self.sanitizedCurve(
            defaults.array(forKey: Key.waveSensitivityPitch) as? [Double], fallback: Self.defaultPitchCurve)
        waveSensitivityVolume = Self.sanitizedCurve(
            defaults.array(forKey: Key.waveSensitivityVolume) as? [Double], fallback: Self.defaultVolumeCurve)
        islandDisplayOptOut = Set((defaults.array(forKey: Key.islandDisplayOptOut) as? [String]) ?? [])
    }

    // MARK: Derived

    /// Neutral accent used when artwork tinting is disabled. `nonisolated` so
    /// non-actor types (e.g. `IslandApp.tint`) can reference it; it's an
    /// immutable constant, so there's no actor state to protect.
    nonisolated static let neutralAccent = Palette.neutralAccent

    /// The accent colour to actually paint with, honouring `tintWithArtwork`.
    func accent(for nowPlaying: NowPlaying) -> Color {
        tintWithArtwork ? nowPlaying.accent : Self.neutralAccent
    }
}
