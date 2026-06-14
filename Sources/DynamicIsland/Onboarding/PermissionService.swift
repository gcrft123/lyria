import AppKit
import ApplicationServices
import CoreBluetooth
import CoreLocation
import EventKit

/// The permissions onboarding asks for, in presentation order (low-friction →
/// high-value → advanced). Each lights up a feature when granted.
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
        case .audio:         key = "Privacy_Microphone"
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

    /// Begin the grant: an in-app system prompt where one exists, otherwise open
    /// the relevant System Settings privacy pane.
    func request(_ permission: OnboardingPermission) {
        switch permission {
        case .accessibility:
            // Deep-link straight to the Accessibility pane. We deliberately skip
            // the system "would like to control…" alert (AXIsProcessTrustedWith-
            // Options prompt) — it's redundant with opening the exact pane, and
            // its own "Open System Settings" button just lands in the same place.
            openSettings(permission)
        case .calendar:
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { _, _ in }
            } else {
                store.requestAccess(to: .event) { _, _ in }
            }
        case .location:
            locationManager.requestWhenInUseAuthorization()
        case .bluetooth, .music, .audio, .fullDisk:
            openSettings(permission)
        }
    }

    func openSettings(_ permission: OnboardingPermission) {
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }
}
