import AppKit
import Combine

/// One app's 5-band graphic-EQ preference: per-band gain in dB. Band order matches
/// `AppAudioEngine.bandFreqs` (60 / 230 / 910 / 3.6k / 14k). Presets just set `bands`.
struct AppEQ: Codable, Equatable {
    var bands: [Double]      // dB, -12…+12, count == AppAudioEngine.bandCount

    static let gainRange: ClosedRange<Double> = -12...12
    static var flatBands: [Double] { Array(repeating: 0, count: AppAudioEngine.bandCount) }
    static let `default` = AppEQ(bands: flatBands)

    var isFlat: Bool { bands.allSatisfy { abs($0) < 0.05 } }

    /// Per-band gain in dB as floats for the audio engine.
    func effectiveDB() -> [Float] {
        (0..<AppAudioEngine.bandCount).map { i in
            Float(max(-15, min(15, i < bands.count ? bands[i] : 0)))
        }
    }

    init(bands: [Double]) {
        self.bands = Self.normalized(bands)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode just `bands`; older saved data may also carry now-removed boost flags.
        bands = Self.normalized((try? c.decode([Double].self, forKey: .bands)) ?? Self.flatBands)
    }

    private static func normalized(_ b: [Double]) -> [Double] {
        let n = AppAudioEngine.bandCount
        if b.count < n { return b + Array(repeating: 0, count: n - b.count) }
        if b.count > n { return Array(b.prefix(n)) }
        return b
    }
}

/// A named EQ preset — a fixed 5-band curve the user can apply to an app in one tap.
struct EQPreset: Identifiable, Equatable {
    let name: String
    let bands: [Double]      // dB per band (60 / 230 / 910 / 3.6k / 14k)
    var id: String { name }

    static let all: [EQPreset] = [
        EQPreset(name: "Flat",         bands: [0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Boost",   bands: [9, 6, 1, 0, 0]),
        EQPreset(name: "Bass Reducer", bands: [-8, -4, 0, 0, 1]),
        EQPreset(name: "Treble Boost", bands: [0, 0, 1, 6, 9]),
        EQPreset(name: "Vocal",        bands: [-2, -1, 5, 4, 0]),
        EQPreset(name: "Acoustic",     bands: [4, 2, 0, 2, 4]),
        EQPreset(name: "Rock",         bands: [5, 3, -1, 3, 5]),
        EQPreset(name: "Electronic",   bands: [7, 4, -2, 3, 6]),
        EQPreset(name: "Loudness",     bands: [8, 3, 0, 3, 8]),
        EQPreset(name: "Podcast",      bands: [-3, 0, 5, 4, -2]),
    ]

    /// The preset whose curve matches these bands (within tolerance), or nil (custom).
    static func matching(_ bands: [Double]) -> EQPreset? {
        all.first { preset in
            preset.bands.indices.allSatisfy { i in
                i < bands.count && abs(preset.bands[i] - bands[i]) < 0.5
            }
        }
    }
}

/// One app's persisted audio preferences — volume/mute, EQ, and stereo pan/position.
/// (Named `AppVolumeSetting` for history; it now backs the whole per-app audio tweak.)
struct AppVolumeSetting: Codable, Equatable {
    var volume: Double      // 0…1
    var muted: Bool
    var pan: Double         // -1 (left) … +1 (right), 0 = center
    var eq: AppEQ
    var onStage: Bool       // placed in the spatial box
    var stageY: Double      // 0…1 cosmetic vertical position in the stage

    static let `default` = AppVolumeSetting(
        volume: 1, muted: false, pan: 0, eq: .default, onStage: false, stageY: 0.5)

    /// True when the app is left untouched (so we don't tap it at all → dormant).
    var isDefault: Bool {
        volume >= 0.999 && !muted && abs(pan) < 0.001 && eq.isFlat
    }
    /// The volume gain to apply in the mixer (0 when muted).
    var effectiveGain: Float { muted ? 0 : Float(max(0, min(1, volume))) }

    init(volume: Double, muted: Bool, pan: Double = 0,
         eq: AppEQ = .default, onStage: Bool = false, stageY: Double = 0.5) {
        self.volume = volume; self.muted = muted; self.pan = pan
        self.eq = eq; self.onStage = onStage; self.stageY = stageY
    }
    // Migration-friendly decode: older saved settings only had volume/muted.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = (try? c.decode(Double.self, forKey: .volume)) ?? 1
        muted = (try? c.decode(Bool.self, forKey: .muted)) ?? false
        pan = (try? c.decode(Double.self, forKey: .pan)) ?? 0
        eq = (try? c.decode(AppEQ.self, forKey: .eq)) ?? .default
        onStage = (try? c.decode(Bool.self, forKey: .onStage)) ?? false
        stageY = (try? c.decode(Double.self, forKey: .stageY)) ?? 0.5
    }
}

/// One row / icon in the per-app audio tweaks.
struct AppVolumeItem: Identifiable, Equatable {
    let bundleID: String
    let pid: pid_t
    let name: String
    let icon: NSImage?
    let isPlaying: Bool          // currently producing audio
    var setting: AppVolumeSetting
    var id: String { bundleID }
}

/// Backs the per-app audio tweaks ("App Volume" and "Equalizer & Spatial"): keeps the
/// live list of apps (sound-producing first, then most-recently-used), owns the
/// per-app settings (persisted FOREVER by bundle id, so a closed app's volume/EQ/pan
/// is restored when it reopens), tracks the app currently selected for editing, and
/// drives the `AppAudioEngine` that applies volume + EQ + pan. The system/master
/// volume is untouched — it stays the output device's own volume and still scales
/// everything; per-app processing layers on top.
@MainActor
final class AppVolumeStore: ObservableObject {
    @Published private(set) var apps: [AppVolumeItem] = []
    /// The app currently selected for EQ/spatial editing (shared by both tabs).
    @Published var selectedBundleID: String?
    /// True while the EQ & Spatial detail page is open — the controller grows the card
    /// (that page needs more height than the 324 standard).
    @Published var eqPageActive: Bool = false

    /// bundleID → setting, persisted to UserDefaults.
    private var settings: [String: AppVolumeSetting] = [:]
    private let defaultsKey = "DITweaksAppVolumes"

    private let engine = AppAudioEngine()
    private var timer: Timer?
    private let mock = ProcessInfo.processInfo.environment["DI_MOCK_TWEAKS"] == "1"

    init() { load() }

    func start() {
        if mock { loadMock(); return }
        // Diagnostic: DI_DEBUG_TAP_PID=<pid> taps exactly that pid (panned) so the
        // audio engine's buffer layout can be logged against a known sound source.
        if ProcessInfo.processInfo.environment["DI_DEBUG_AUDIO"] == "1",
           let s = ProcessInfo.processInfo.environment["DI_DEBUG_TAP_PID"], let pid = pid_t(s) {
            let pan = Float(ProcessInfo.processInfo.environment["DI_DEBUG_TAP_PAN"] ?? "0") ?? 0
            engine.apply([AppAudioEngine.Controlled(
                pid: pid, gain: 1, pan: pan,
                eqBandsDB: Array(repeating: 0, count: AppAudioEngine.bandCount))])
            return
        }
        refresh()
        applyEngine()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: Selection

    var selectedApp: AppVolumeItem? {
        if let id = selectedBundleID, let app = apps.first(where: { $0.bundleID == id }) { return app }
        return apps.first
    }

    func select(_ bundleID: String) { selectedBundleID = bundleID }

    /// Apps placed in the spatial stage, in display order.
    var stagedApps: [AppVolumeItem] { apps.filter { $0.setting.onStage } }

    // MARK: Volume mutations

    func setVolume(_ volume: Double, for bundleID: String) {
        var s = settings[bundleID] ?? .default
        s.volume = max(0, min(1, volume))
        commit(s, for: bundleID)
    }

    func setMuted(_ muted: Bool, for bundleID: String) {
        var s = settings[bundleID] ?? .default
        s.muted = muted
        commit(s, for: bundleID)
    }

    func toggleMuted(for bundleID: String) {
        setMuted(!(settings[bundleID]?.muted ?? false), for: bundleID)
    }

    // MARK: EQ mutations

    func setBand(_ db: Double, index: Int, for bundleID: String) {
        var s = settings[bundleID] ?? .default
        guard index >= 0, index < AppAudioEngine.bandCount else { return }
        if s.eq.bands.count < AppAudioEngine.bandCount {
            s.eq.bands += Array(repeating: 0, count: AppAudioEngine.bandCount - s.eq.bands.count)
        }
        s.eq.bands[index] = max(AppEQ.gainRange.lowerBound, min(AppEQ.gainRange.upperBound, db))
        commit(s, for: bundleID)
    }

    /// Apply a named EQ preset's curve to the app's bands (visibly moves the sliders).
    func applyPreset(_ preset: EQPreset, for bundleID: String) {
        var s = settings[bundleID] ?? .default
        s.eq.bands = preset.bands
        commit(s, for: bundleID)
    }

    /// EQ-section reset: clear the selected app's EQ bands and pan (the icon stays on
    /// the stage, now centered).
    func resetEQ(for bundleID: String) {
        var s = settings[bundleID] ?? .default
        s.eq = .default
        s.pan = 0
        commit(s, for: bundleID)
    }

    // MARK: Spatial mutations

    /// Set the pan (and optionally the cosmetic vertical), placing the app on the
    /// stage if it isn't already (per spec: the pan slider "adds it in").
    func setPan(_ pan: Double, y: Double? = nil, for bundleID: String) {
        var s = settings[bundleID] ?? .default
        s.pan = max(-1, min(1, pan))
        if let y { s.stageY = max(0, min(1, y)) }
        s.onStage = true
        commit(s, for: bundleID)
    }

    /// Place an app on the stage (used by the "+" / drawer). Centers it if new.
    func placeOnStage(_ bundleID: String, atY y: Double = 0.5) {
        var s = settings[bundleID] ?? .default
        if !s.onStage { s.onStage = true; s.stageY = max(0, min(1, y)) }
        commit(s, for: bundleID)
        select(bundleID)
    }

    func removeFromStage(_ bundleID: String) {
        var s = settings[bundleID] ?? .default
        s.onStage = false; s.pan = 0
        commit(s, for: bundleID)
    }

    /// Stage reset: remove every app from the stage and reset every app's pan
    /// (EQ is left untouched).
    func clearStage() {
        for (id, var s) in settings where s.onStage || abs(s.pan) > 0.001 {
            s.onStage = false; s.pan = 0
            settings[id] = s
        }
        persist()
        apps = apps.map { item in
            var copy = item
            copy.setting = settings[item.bundleID] ?? .default
            return copy
        }
        applyEngine()
    }

    func setting(for bundleID: String) -> AppVolumeSetting { settings[bundleID] ?? .default }

    private func commit(_ s: AppVolumeSetting, for bundleID: String) {
        settings[bundleID] = s
        persist()
        // Reflect in the visible rows without a full re-enumeration.
        apps = apps.map { item in
            guard item.bundleID == bundleID else { return item }
            var copy = item; copy.setting = s; return copy
        }
        applyEngine()
    }

    // MARK: Enumeration

    private func refresh() {
        let producing = AppAudioEngine.soundProducingPIDs()
        let mine = Bundle.main.bundleIdentifier
        let tracker = WindowActivationTracker.shared

        var items: [AppVolumeItem] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated {
            guard let bundleID = app.bundleIdentifier, bundleID != mine else { continue }
            items.append(AppVolumeItem(
                bundleID: bundleID,
                pid: app.processIdentifier,
                name: app.localizedName ?? bundleID,
                icon: app.icon,
                isPlaying: producing.contains(app.processIdentifier),
                setting: settings[bundleID] ?? .default))
        }

        // Sound-producing first, then most-recently-used (app activation), then name.
        items.sort { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            let ra = tracker.rank(for: a.pid), rb = tracker.rank(for: b.pid)
            if ra != rb { return ra > rb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        if apps != items { apps = items }
        applyEngine()
    }

    /// Push the non-default apps (with their current pids) to the audio engine.
    private func applyEngine() {
        let controlled: [AppAudioEngine.Controlled] = apps.compactMap { item in
            let s = settings[item.bundleID] ?? .default
            guard !s.isDefault else { return nil }
            return AppAudioEngine.Controlled(
                pid: item.pid, gain: s.effectiveGain, pan: Float(s.pan), eqBandsDB: s.eq.effectiveDB())
        }
        engine.apply(controlled)
    }

    // MARK: Persistence

    /// Coalesces writes so a continuous gesture (dragging an EQ band, panning an app
    /// on the stage) doesn't JSON-encode + hit UserDefaults on every pointer tick —
    /// that per-frame disk write is what made dragging feel jagged/laggy. Only the
    /// last change in a burst is written, a short delay after the gesture settles.
    private var persistWork: DispatchWorkItem?
    private func persist() {
        persistWork?.cancel()
        let key = defaultsKey
        let snapshot = settings
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: AppVolumeSetting].self, from: data)
        else { return }
        settings = decoded
    }

    // MARK: Mock (DI_MOCK_TWEAKS=1) — seeds a sample list for screenshots.

    private func loadMock() {
        func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        func setting(_ id: String, _ fallback: AppVolumeSetting) -> AppVolumeSetting { settings[id] ?? fallback }
        apps = [
            AppVolumeItem(bundleID: "com.spotify.client", pid: 1, name: "Spotify", icon: icon("music.note"),
                          isPlaying: true, setting: setting("com.spotify.client",
                          AppVolumeSetting(volume: 1, muted: false, pan: -0.6,
                                           eq: AppEQ(bands: [9, 6, 1, 0, 0]),   // Bass Boost preset
                                           onStage: true, stageY: 0.32))),
            AppVolumeItem(bundleID: "com.google.Chrome", pid: 2, name: "Google Chrome", icon: icon("globe"),
                          isPlaying: true, setting: setting("com.google.Chrome",
                          AppVolumeSetting(volume: 0.4, muted: false, pan: 0.5, onStage: true, stageY: 0.55))),
            AppVolumeItem(bundleID: "com.apple.Music", pid: 3, name: "Music", icon: icon("music.note.house.fill"),
                          isPlaying: false, setting: setting("com.apple.Music",
                          AppVolumeSetting(volume: 1, muted: false, pan: 0.05,
                                           eq: AppEQ(bands: [0, 0, 1, 6, 9]),   // Treble Boost preset
                                           onStage: true, stageY: 0.42))),
            AppVolumeItem(bundleID: "com.tinyspeck.slackmacgap", pid: 4, name: "Slack", icon: icon("number"),
                          isPlaying: false, setting: setting("com.tinyspeck.slackmacgap",
                          AppVolumeSetting(volume: 1, muted: true))),
            AppVolumeItem(bundleID: "com.hnc.Discord", pid: 5, name: "Discord", icon: icon("bubble.left.fill"),
                          isPlaying: false, setting: setting("com.hnc.Discord", .default)),
        ]
        if selectedBundleID == nil { selectedBundleID = "com.apple.Music" }
    }
}
