import AppKit
import ApplicationServices
import CoreBluetooth
import CoreLocation
import CoreServices
import EventKit
import ScriptingBridge

/// The permissions onboarding asks for, in presentation order (low-friction →
/// high-value → advanced). Each lights up a feature when granted.
/// How a grant surfaces its UI — which decides how the full-screen onboarding
/// takeover must get out of the way.
///   • `.dialog` — the grant pops a centered system TCC alert (Allow / Don't Allow).
///     The takeover, sitting at `.screenSaver`, would cover that alert, so we lower
///     it to `.normal` (which the alert sits above) while keeping the app frontmost
///     — macOS only shows these alerts for the frontmost app, so fully hiding the
///     takeover used to drop this agent out of frontmost and suppress the prompt.
///     The reactivation observer restores the takeover once the user returns.
///   • `.pane`   — the grant only flips a switch in System Settings (no alert). We
///     keep the takeover visible (just lowered) so the user can click it to return,
///     since this is an LSUIElement agent with no Dock icon or menu-bar item.
///   • `.none`   — not in a grant; takeover at full strength.
enum PermissionFocus { case none, dialog, pane }

enum OnboardingPermission: String, CaseIterable, Identifiable {
    case accessibility
    case music
    case audio
    case calendar
    case location
    case fullDisk
    case bluetooth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .music: return "Apple Music"
        case .audio: return "System Audio"
        case .calendar: return "Calendar"
        case .location: return "Location"
        case .fullDisk: return "Full Disk Access"
        case .bluetooth: return "Bluetooth"
        }
    }

    /// What the feature does — shown as the reason for the ask.
    var reason: String {
        switch self {
        case .accessibility: return "Fan out every open window with ⌥Tab, and replace the volume HUD."
        case .music: return "Mirror what's playing and let you control it from the notch."
        case .audio: return "Pulse the glow to the beat, and tune any app's EQ."
        case .calendar: return "Surface your next event and a live countdown before it starts."
        case .location: return "Show the local weather for where you are."
        case .fullDisk: return "Optional — replace system notification banners with the island's."
        case .bluetooth: return "Show a banner when your devices connect."
        }
    }

    var glyph: String {
        switch self {
        case .accessibility: return "macwindow.on.rectangle"
        case .music: return "music.note"
        case .audio: return "waveform"
        case .calendar: return "calendar"
        case .location: return "location.fill"
        case .fullDisk: return "bell.badge"
        case .bluetooth: return "dot.radiowaves.right"
        }
    }

    /// Marked as optional/advanced (rendered more quietly).
    var isOptional: Bool { self == .fullDisk }

    /// Whether granting pops a centered system alert (`.dialog`) or only toggles a
    /// switch in System Settings (`.pane`). Drives how the takeover steps aside —
    /// see `PermissionFocus`.
    var grantFocus: PermissionFocus {
        switch self {
        case .calendar, .location, .bluetooth, .music: return .dialog
        case .accessibility, .audio, .fullDisk: return .pane
        }
    }

    /// Whether we can read the grant state programmatically (so the card ignites
    /// on its own when the user returns), vs. asking them to confirm.
    var autoDetects: Bool {
        switch self {
        case .accessibility, .calendar, .location, .bluetooth: return true
        case .music, .audio, .fullDisk: return false
        }
    }

    /// Deep link to the System Settings pane (for grants that only toggle there).
    var settingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        let key: String
        switch self {
        case .accessibility: key = "Privacy_Accessibility"
        case .music:         key = "Privacy_Automation"
        // System-audio capture (Core Audio process tap) registers under
        // "Screen & System Audio Recording" on macOS 15+, NOT Microphone.
        case .audio:         key = "Privacy_ScreenCapture"
        case .calendar:      key = "Privacy_Calendars"
        case .location:      key = "Privacy_LocationServices"
        case .fullDisk:      key = "Privacy_AllFiles"
        case .bluetooth:     key = "Privacy_Bluetooth"
        }
        return URL(string: base + key)
    }
}

/// Reads permission state and kicks off the grant flow. Read-only checks never
/// prompt, so the onboarding can poll them to detect a grant made while the user
/// is over in System Settings.
@MainActor
final class PermissionService: ObservableObject {
    private let locationManager = CLLocationManager()

    /// `true` once the permission is granted (best-effort; non-auto-detect kinds
    /// always report `false` and rely on user confirmation instead).
    func isGranted(_ permission: OnboardingPermission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .calendar:
            let status = EKEventStore.authorizationStatus(for: .event)
            if #available(macOS 14.0, *) { return status == .fullAccess || status == .authorized }
            return status == .authorized
        case .location:
            let status = locationManager.authorizationStatus
            return status == .authorizedAlways || status == .authorized
        case .bluetooth:
            return CBCentralManager.authorization == .allowedAlways
        case .music, .audio, .fullDisk:
            return false // not cleanly readable — user confirms instead
        }
    }

    // Bluetooth: a central manager whose first scan trips the Bluetooth TCC prompt.
    // We don't otherwise use BLE here — onboarding only needs the grant.
    private var btCentral: CBCentralManager?
    private lazy var btProbe = BluetoothProbe()

    // Location: the manager needs a retained delegate or `requestWhenInUse…` is a
    // no-op on recent macOS. We don't consume fixes here — onboarding only needs
    // the grant; WeatherManager reads location once authorized.
    private lazy var locationProbe = LocationProbe()

    /// Begin the grant: fire the real system prompt where one exists (Automation,
    /// Audio Capture, Calendar, Location, Bluetooth), otherwise deep-link to the
    /// relevant System Settings pane (Accessibility, Full Disk Access).
    func request(_ permission: OnboardingPermission) {
        switch permission {
        case .accessibility:
            // Deep-link straight to the Accessibility pane. We deliberately skip
            // the system "would like to control…" alert (AXIsProcessTrustedWith-
            // Options prompt) — it's redundant with opening the exact pane.
            openSettings(permission)
        case .music:
            // Automation ("control Music") only registers + prompts when the target
            // is running, so launch Music in the background (no activation, no
            // playback) and THEN ask. The takeover stays frontmost (.dialog) so the
            // alert surfaces above it.
            Self.requestAutomation(bundleID: "com.apple.Music")
            openSettingsFallback(permission)   // Automation pane, as a fallback
        case .audio:
            // Per-app audio uses the macOS Audio-Capture TCC; trip it by briefly
            // creating a process tap, then open the pane (it registers under
            // "Screen & System Audio Recording", which never prompts on its own).
            AppAudioEngine.requestCapturePermission()
            openSettings(permission)
        case .calendar:
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { _, _ in }
            } else {
                store.requestAccess(to: .event) { _, _ in }
            }
            openSettingsFallback(permission)
        case .location:
            // A retained delegate is required for the prompt to fire on recent macOS.
            locationManager.delegate = locationProbe
            locationManager.requestWhenInUseAuthorization()
            openSettingsFallback(permission)
        case .bluetooth:
            // Instantiating + scanning a central manager trips the Bluetooth prompt.
            // If one already exists and is powered on, re-kick the scan so a repeat
            // Grant still nudges the prompt.
            if let btCentral {
                btProbe.centralManagerDidUpdateState(btCentral)
            } else {
                btCentral = CBCentralManager(delegate: btProbe, queue: nil)
            }
            openSettingsFallback(permission)
        case .fullDisk:
            openSettings(permission)
        }
    }

    /// Reliable fallback for the grants that surface a centered TCC alert
    /// (Calendar, Location, Bluetooth, Music/Automation): a beat after firing the
    /// request, open the matching System Settings pane so the user always has a
    /// path even if the alert never appears.
    ///
    /// Crucially this opens the pane WITHOUT activating System Settings: activating
    /// another app steals focus and macOS dismisses the still-open TCC alert as if
    /// cancelled (confirmed via tccd logs — the Automation prompt fired, then the
    /// activating pane-open killed it before it could be answered). Opening in the
    /// background lets the alert stay on top and answerable, with the pane waiting
    /// behind it. Skipped entirely once we can see the grant already landed.
    private func openSettingsFallback(_ permission: OnboardingPermission) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            if permission.autoDetects && self.isGranted(permission) { return }
            self.openSettings(permission, activate: false)
        }
    }

    /// Ask for Automation ("control Music") consent. `AEDeterminePermissionTo-
    /// AutomateTarget` only registers the app + shows the prompt when the target is
    /// already running — against a quit app it returns `procNotFound` and registers
    /// nothing (the exact symptom: Music never appears under Automation). So if Music
    /// isn't running, launch it in the background first (no activation, no playback),
    /// then ask. The determine call itself sends no Apple Event, so it never starts
    /// playback.
    private static func requestAutomation(bundleID: String) {
        func ask() {
            DispatchQueue.global(qos: .userInitiated).async {
                // Send a real, read-only Apple Event first. Reading `playerState`
                // (never writes, never starts playback) makes macOS register the app
                // under Automation and surface the "control Music" prompt — which
                // AEDeterminePermissionToAutomateTarget on its own was failing to do
                // here (it would return without ever registering Lyria). SBApplication
                // adopts MusicApplication via the bridging header, so the property is
                // available directly.
                let music = SBApplication(bundleIdentifier: bundleID)
                _ = music?.playerState

                var target = AEAddressDesc()
                let created = Array(bundleID.utf8).withUnsafeBytes { raw in
                    AECreateDesc(typeApplicationBundleID, raw.baseAddress, raw.count, &target) == noErr
                }
                guard created else { return }
                defer { AEDisposeDesc(&target) }
                _ = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
            }
        }

        let alreadyRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).isEmpty
        guard !alreadyRunning,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            ask(); return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false        // stay in the background — don't steal focus
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            // Give Music a beat to install its Apple Event handler, then ask.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ask() }
        }
    }

    /// Open a System Settings privacy pane. `activate` controls whether System
    /// Settings is brought to the front: `true` for the user-driven "Open Settings
    /// again" affordance (they want to see it), `false` for the automatic fallback
    /// after a TCC alert (bringing Settings forward would dismiss the live alert).
    func openSettings(_ permission: OnboardingPermission, activate: Bool = true) {
        guard let url = permission.settingsURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
    }
}

/// Minimal Bluetooth central whose first scan trips the Bluetooth TCC prompt;
/// onboarding only needs the grant, not the scan results.
private final class BluetoothProbe: NSObject, CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { central.stopScan() }
    }
}

/// Minimal location delegate. `CLLocationManager.requestWhenInUseAuthorization()`
/// needs a retained delegate to reliably fire its prompt; we don't consume fixes.
private final class LocationProbe: NSObject, CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
}
