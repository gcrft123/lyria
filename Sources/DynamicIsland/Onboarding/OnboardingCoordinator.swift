import AppKit
import SwiftUI

/// The seven acts of onboarding.
enum OnboardingPhase: Int, CaseIterable {
    case awakening, hello, trailer, permissions, personalize, tryMe, finale

    /// Position in the progress rail (awakening is pre-roll, not counted).
    var railIndex: Int { max(0, rawValue - 1) }
    static var railCount: Int { allCases.count - 1 }
}

/// One vignette in the trailer (Act 2), advanced by the user.
enum TrailerBeat: Int, CaseIterable, Identifiable {
    case music, timer, calendar, weather, dashboard
    var id: Int { rawValue }
    var caption: String {
        switch self {
        case .music: return "Now playing, mirrored"
        case .timer: return "Timers & stopwatches"
        case .calendar: return "What's coming up"
        case .weather: return "Local weather"
        case .dashboard: return "Everything at a glance"
        }
    }
}

/// One tip on the Act 5 list (display only).
enum TryStep: Int, CaseIterable, Identifiable {
    case open, switchApps, pin, switcher
    var id: Int { rawValue }
    var prompt: String {
        switch self {
        case .open: return "Hover, click, or scroll the island to open it"
        case .switchApps: return "Scroll to flip through your apps"
        case .pin: return "Grab the corner pin to keep it open"
        case .switcher: return "Press ⌥Tab to fan out your windows"
        }
    }
    var glyph: String {
        switch self {
        case .open: return "hand.point.up.left"
        case .switchApps: return "arrow.up.arrow.down"
        case .pin: return "pin"
        case .switcher: return "macwindow.on.rectangle"
        }
    }
}

/// Drives the onboarding sequence. Only the opening reveal auto-advances
/// (Awakening → Hello); every other act waits for the user (Continue / Grant /
/// Done), so progression is fully under their control. Owns the ambient audio +
/// permission service.
@MainActor
final class OnboardingCoordinator: ObservableObject {
    @Published private(set) var phase: OnboardingPhase = .awakening
    @Published private(set) var trailerBeat = 0
    @Published private(set) var permissionIndex = 0
    /// True during the closing beat, while the card shrinks toward the notch to
    /// "become" the real island.
    @Published private(set) var morphingOut = false

    let permissions = OnboardingPermission.allCases
    let audio = OnboardingAudio()
    let permissionService = PermissionService()
    let settings: AppSettings

    /// Called when onboarding finishes — tears down + starts the real island.
    var onFinish: (() -> Void)?

    /// While a grant flow needs the system UI (System Settings / a TCC prompt),
    /// the host lowers the takeover so those can surface above it; raised back
    /// once the user moves on.
    var onPermissionFocus: ((Bool) -> Void)?

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var timer: DispatchWorkItem?

    /// Debug "hold on one act" mode (windowed preview); set via `DI_ONBOARD_PHASE`.
    private var previewMode = false
    private var previewBeat = 0

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// `DI_ONBOARD_PHASE=hello|trailer|permissions|personalize|tryMe|finale`
    static func previewPhaseFromEnv() -> OnboardingPhase? {
        switch ProcessInfo.processInfo.environment["DI_ONBOARD_PHASE"]?.lowercased() {
        case "hello": return .hello
        case "trailer": return .trailer
        case "permissions", "perms": return .permissions
        case "personalize": return .personalize
        case "tryme", "try": return .tryMe
        case "finale": return .finale
        default: return nil
        }
    }

    var currentPermission: OnboardingPermission? {
        permissionIndex < permissions.count ? permissions[permissionIndex] : nil
    }

    // MARK: Lifecycle

    func start() {
        audio.start()   // ambient pad only (no chimes)
        if let phase = Self.previewPhaseFromEnv() {
            previewMode = true
            previewBeat = Int(ProcessInfo.processInfo.environment["DI_ONBOARD_BEAT"] ?? "") ?? 0
            enter(phase)
        } else {
            enter(.awakening)
        }
    }

    func skipIntro() {
        cancelTimer()
        enter(.permissions)
    }

    /// Finish: the card morphs toward the notch (becoming the island), then the
    /// host tears down and reveals the real island with a first-use hint.
    func finish() {
        guard !morphingOut else { return }
        cancelTimer()
        onPermissionFocus?(false)
        withAnimation(reduceMotion ? Motion.reduced : Motion.morph) { morphingOut = true }
        schedule(after: reduceMotion ? 0.25 : 0.6) { [weak self] in self?.tearDown() }
    }

    private func tearDown() {
        audio.stop()
        settings.onboardingCompleted = true
        onFinish?()
    }

    // MARK: Phase machine

    private func enter(_ next: OnboardingPhase) {
        cancelTimer()
        onPermissionFocus?(false)
        withAnimation(reduceMotion ? Motion.reduced : Motion.morph) {
            phase = next
        }
        switch next {
        case .awakening:
            // The only auto-advance: the birth reveal flows into Hello.
            if !previewMode { schedule(after: reduceMotion ? 1.2 : 2.4) { [weak self] in self?.enter(.hello) } }
        case .trailer:
            trailerBeat = previewMode ? previewBeat : 0
        case .permissions:
            permissionIndex = 0
        case .hello, .personalize, .tryMe, .finale:
            break   // user-paced
        }
    }

    /// Manual "Continue" from the user-paced acts.
    func advancePhase() {
        switch phase {
        case .hello: enter(.trailer)
        case .trailer: enter(.permissions)
        case .permissions: enter(.personalize)
        case .personalize: enter(.tryMe)
        case .tryMe: enter(.finale)
        default: break
        }
    }

    // MARK: Trailer (user-advanced)

    /// Step the trailer forward one vignette, or into permissions after the last.
    func advanceTrailer() {
        if trailerBeat + 1 >= TrailerBeat.allCases.count {
            enter(.permissions)
        } else {
            withAnimation(reduceMotion ? Motion.reduced : Motion.contentMorph) { trailerBeat += 1 }
        }
    }

    var isLastTrailerBeat: Bool { trailerBeat + 1 >= TrailerBeat.allCases.count }

    // MARK: Permissions (fully user-paced — Grant fires the request, Continue moves on)

    /// Lower the takeover so the system UI can surface, then fire the request /
    /// open the relevant System Settings pane.
    func grantCurrent() {
        guard let permission = currentPermission else { return }
        onPermissionFocus?(true)
        permissionService.request(permission)
    }

    /// Re-open the System Settings pane (the "Open Settings again" affordance).
    func openSettingsForCurrent() {
        guard let permission = currentPermission else { return }
        onPermissionFocus?(true)
        permissionService.openSettings(permission)
    }

    /// Advance to the next permission (Continue / Skip), or on to personalize.
    func nextPermission() {
        onPermissionFocus?(false)
        if permissionIndex + 1 >= permissions.count {
            enter(.personalize); return
        }
        withAnimation(reduceMotion ? Motion.reduced : Motion.transition) {
            permissionIndex += 1
        }
    }

    var isLastPermission: Bool { permissionIndex + 1 >= permissions.count }

    // MARK: Timer plumbing

    private func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        cancelTimer()
        let work = DispatchWorkItem(block: block)
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelTimer() { timer?.cancel(); timer = nil }
}
