import AppKit
import Combine

/// Wires the app together at launch: builds the controller, registers the
/// (currently inert) integration providers, and shows the island.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = DynamicIslandController()
    private var windowController: IslandWindowController?

    private var hoverHandler: HoverInteractionHandler?
    private let musicProvider = MusicPlayerProvider()
    private let notificationProvider = NotificationProvider()
    private let bluetoothProvider = BluetoothProvider()
    private let airDropProvider = AirDropProvider()
    private let systemHUDProvider = SystemHUDProvider()
    private let eventKitProvider = EventKitProvider()
    private var privacyMonitor: PrivacyMonitor?

    // System-state mirrors: surface OS changes (appearance, displays, Wi-Fi,
    // Focus) as island popups.
    private let appearanceProvider = AppearanceProvider()
    private let displayProvider = DisplayProvider()
    private let wifiProvider = WiFiProvider()
    private let batteryProvider = BatteryProvider()
    private var focusProvider: FocusProvider?

    // Alt+Tab window switcher (OS-wide): a global hot-key tap drives a switcher
    // state machine, shown in its own full-screen overlay panel.
    private let windowSwitcher = WindowSwitcher()
    private var switcherWindow: SwitcherWindowController?
    private var switcherHotKey: SwitcherHotKey?

    /// Hides the system's own notification banners (via Do Not Disturb) while the
    /// island mirrors them, so only the island's popups appear.
    private let focusController = FocusController()
    private var sigtermSource: DispatchSourceSignal?

    /// True once the notification provider confirms it can read the store. DND is
    /// only ever turned on after this, so a missing Full Disk Access grant never
    /// silences the system with nothing to mirror in its place.
    private var notificationAccessConfirmed = false
    private var settingsObserver: AnyCancellable?

    /// Whether `startIntegrations()` has run — providers start once, deferred past
    /// first-run onboarding so permission prompts fire at their step, not at launch.
    private var integrationsStarted = false

    /// First-launch (or replayed) onboarding takeover; nil when not running.
    private var onboardingWindow: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Leave a local breadcrumb for uncaught exceptions (no SDK / network).
        CrashReporter.install()

        // TEST-ONLY: promote the agent to a regular (Dock-visible) app so automated
        // UI-control tooling can enumerate + drive it. No effect on shipping (env
        // unset by default); the onboarding takeover behaves identically either way.
        if ProcessInfo.processInfo.environment["DI_GRANTABLE"] == "1" {
            NSApp.setActivationPolicy(.regular)
        }

        // Start Sparkle's scheduled background update checks (manual check lives in
        // Settings ▸ General). Skippable for dev/screenshots via DI_DISABLE_UPDATES=1.
        if ProcessInfo.processInfo.environment["DI_DISABLE_UPDATES"] != "1" {
            _ = Updater.shared
        }

        // Hover → expand/collapse.
        let hoverHandler = HoverInteractionHandler(controller: controller)
        controller.interactionHandler = hoverHandler
        self.hoverHandler = hoverHandler

        // Left-clicking a mirrored system notification launches the sending app.
        controller.onPopupLaunchBundle = { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }

        // Left-clicking a status live activity opens its System Settings deep link
        // (e.g. a battery notification opens the Battery pane).
        controller.onPopupOpenURL = { urlString in
            guard let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        }

        // Restore system banners if we're asked to quit (logout, `kill`). Armed
        // immediately so a clean quit always turns Do Not Disturb back off.
        installTerminationGuard()

        let windowController = IslandWindowController(controller: controller)
        windowController.show()
        self.windowController = windowController

        // Alt+Tab window switcher: the overlay window observes the switcher state,
        // and the global hot-key tap (Option+Tab) drives it. Both need the same
        // Accessibility grant the HUD prompts for. `DI_DISABLE_SWITCHER=1` skips
        // the tap; `DI_MOCK_SWITCHER=1` seeds a sample grid at launch instead.
        // Track app-activation recency from launch so the switcher can order
        // windows most-recently-used first.
        WindowActivationTracker.shared.start()
        let switcherWindow = SwitcherWindowController(switcher: windowSwitcher)
        self.switcherWindow = switcherWindow
        // The hot-key tap needs Accessibility, so it's started in startIntegrations()
        // — immediately for a returning user, or after onboarding on first run.
        self.switcherHotKey = SwitcherHotKey(switcher: windowSwitcher)

        switch ProcessInfo.processInfo.environment["DI_MOCK_SWITCHER"] {
        case "1":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.windowSwitcher.beginMock()
            }
        case "real":
            // Exercise the REAL enumeration + overlay (no hot-key needed).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.windowSwitcher.begin()
            }
        case "count":
            // Log the enumeration result WITHOUT showing the overlay (so it
            // doesn't grab the mouse) — for verifying the window list.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let list = WindowEnumerator.currentWindows()
                FileHandle.standardError.write(Data(
                    "DI_SWITCHER count=\(list.count): \(list.map { "\($0.appName)/\($0.displayTitle)" })\n".utf8))
            }
        case "dump":
            // Dump raw CG + AX window properties (no overlay) to find what
            // distinguishes real windows from helper/non-windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                WindowEnumerator.debugDump()
            }
        case "time":
            // Measure where the open latency goes: synchronous enumeration vs the
            // (now-async) thumbnail capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let t0 = Date()
                let list = WindowEnumerator.currentWindows()
                let enumMs = Int(Date().timeIntervalSince(t0) * 1000)
                let t1 = Date()
                let thumbs = WindowEnumerator.thumbnails(for: list.map { $0.id })
                let thumbMs = Int(Date().timeIntervalSince(t1) * 1000)
                FileHandle.standardError.write(Data(
                    "DI_SWITCHER timing: enum=\(enumMs)ms thumbs=\(thumbMs)ms (count=\(list.count), thumbsGot=\(thumbs.count))\n".utf8))
            }
        default:
            break
        }

        // First-launch onboarding (or a replay from Settings). The island is
        // already set up behind it, so when the takeover finishes the island is
        // live underneath. `DI_FORCE_ONBOARDING=1` always runs it (dev/screenshots).
        NotificationCenter.default.addObserver(
            self, selector: #selector(replayOnboarding),
            name: .replayOnboarding, object: nil)
        let env = ProcessInfo.processInfo.environment
        let windowedPreview = env["DI_ONBOARD_PREVIEW"] == "1"
        let willOnboard = env["DI_FORCE_ONBOARDING"] == "1" || windowedPreview
            || !controller.settings.onboardingCompleted

        if willOnboard && !windowedPreview {
            // First-run takeover: DEFER all integration startup until onboarding
            // finishes, so each permission is requested at its own step rather than
            // racing in at launch. startIntegrations() runs from `onComplete`.
            presentOnboarding()
        } else {
            // Returning user (or the windowed debug preview): bring everything up now.
            startIntegrations()
            if windowedPreview {
                presentOnboarding()
            } else if env["DI_MOCK_HINT"] == "1" {
                // Seed the onboarding "open me" live activity (without the takeover)
                // so it can be inspected on the normal island.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.controller.presentOnboardingHint()
                }
            }
        }
    }

    /// Bring up everything that observes the system or needs a permission. Deferred
    /// past first-run onboarding so each prompt fires at its step, not at launch.
    /// Idempotent — called immediately for a returning user, or from the onboarding's
    /// completion on first run (a no-op if the intro was merely replayed).
    private func startIntegrations() {
        guard !integrationsStarted else { return }
        integrationsStarted = true

        // Notifications: mirror every macOS banner into the island.
        if ProcessInfo.processInfo.environment["DI_DISABLE_NOTIFICATIONS"] != "1" {
            controller.register(notificationProvider)
            // Once we confirm we can read the store, suppress the system's own
            // banners so only the island's mirror appears. Gated on access so a
            // missing Full Disk Access grant never hides notifications silently.
            notificationProvider.onAccessConfirmed = { [weak self] in
                self?.notificationAccessConfirmed = true
                self?.reconcileBannerSuppression()
            }
            notificationProvider.startObserving()
            // The "Replace system banners" toggle flips DND on/off live.
            settingsObserver = controller.settings.$suppressSystemBanners
                .sink { [weak self] _ in self?.reconcileBannerSuppression() }
        }

        // Bluetooth + AirDrop banners are DISABLED by default (false-firing); set
        // DI_ENABLE_BT_AIRDROP=1 to turn them back on.
        if ProcessInfo.processInfo.environment["DI_ENABLE_BT_AIRDROP"] == "1" {
            controller.register(bluetoothProvider); bluetoothProvider.startObserving()
            controller.register(airDropProvider); airDropProvider.startObserving()
        }

        // Music: live, mirroring Apple Music (Apple Events / Automation).
        controller.register(musicProvider)
        musicProvider.startObserving()

        // Volume/brightness keys → island HUD (needs Accessibility).
        controller.register(systemHUDProvider)
        systemHUDProvider.startObserving()

        // Calendar: upcoming events + a notch live activity (needs Calendar access).
        controller.register(eventKitProvider)
        eventKitProvider.startObserving()

        // Camera/mic usage → orange side extension riding at the island's edge.
        let privacyMonitor = PrivacyMonitor()
        controller.register(extensionProvider: privacyMonitor)
        self.privacyMonitor = privacyMonitor

        // Appearance / display / Wi-Fi banners.
        controller.register(appearanceProvider); appearanceProvider.startObserving()
        controller.register(displayProvider); displayProvider.startObserving()
        controller.register(wifiProvider); wifiProvider.startObserving()

        // Battery: charging / low-battery / Low Power Mode → status live activities.
        controller.register(batteryProvider); batteryProvider.startObserving()

        // Focus / Do Not Disturb changes → Focus banner (reads the DND store; FDA).
        let focusProvider = FocusProvider(focusController: focusController)
        controller.register(focusProvider)
        focusProvider.startObserving()
        self.focusProvider = focusProvider

        // Weather (requests Location).
        controller.weatherManager.start()

        // Alt+Tab window-switcher hot-key tap (needs Accessibility).
        switcherHotKey?.start()
    }

    @objc private func replayOnboarding() { presentOnboarding() }

    private func presentOnboarding() {
        guard onboardingWindow == nil else { return }
        // Hide the real island so it never peeks through behind the takeover
        // (the windowed preview keeps it visible — it doesn't cover the screen).
        let windowed = ProcessInfo.processInfo.environment["DI_ONBOARD_PREVIEW"] == "1"
        if !windowed { windowController?.setVisible(false) }
        let onboarding = OnboardingWindowController(settings: controller.settings)
        onboarding.onComplete = { [weak self] in
            guard let self else { return }
            self.windowController?.setVisible(true)
            // Now that the user has been through (and granted) permissions, bring the
            // integrations up. Idempotent — a no-op for a returning user who merely
            // replayed the intro (their providers are already running).
            self.startIntegrations()
            // The card has just morphed into the notch — greet with a live-activity
            // hint teaching the gesture that opens the island.
            self.controller.presentOnboardingHint()
            self.onboardingWindow = nil
        }
        onboarding.show()
        onboardingWindow = onboarding
    }

    /// Turn Do Not Disturb on or off to match the user's preference, but only
    /// once we've confirmed we can actually read the notification store. Both
    /// `FocusController` calls are idempotent, so this is safe to call whenever
    /// the toggle or the access state changes.
    private func reconcileBannerSuppression() {
        if notificationAccessConfirmed && controller.settings.suppressSystemBanners {
            focusController.enable()
        } else {
            focusController.disable()
        }
    }

    /// Clean quits (logout, Quit menu) flow through here — turn Do Not Disturb
    /// back off so we never leave the system silenced after the island is gone.
    func applicationWillTerminate(_ notification: Notification) {
        focusController.disable(wait: true)
    }

    /// `applicationWillTerminate` doesn't fire for a bare `kill` (SIGTERM), so
    /// catch that too and restore banners before exiting. (SIGKILL / `kill -9`
    /// can't be caught — a force-kill will leave DND on until it's toggled off.)
    private func installTerminationGuard() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.focusController.disable(wait: true)
            exit(0)
        }
        source.resume()
        sigtermSource = source
    }
}
