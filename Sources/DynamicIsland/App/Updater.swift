import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater.
///
/// Created once at launch (`Updater.shared` is referenced from `AppDelegate`) so
/// the app performs Sparkle's scheduled background update checks per the user's
/// preference, reading the appcast at `SUFeedURL` and verifying each update
/// against `SUPublicEDKey` (both in Info.plist). The standard user driver shows
/// Sparkle's own windows for the "update available" prompt, release notes, and
/// download progress — no UI of our own to maintain.
///
/// `SPUStandardUpdaterController` is the Sparkle-recommended entry point; it owns
/// the `SPUUpdater` and a standard `SPUUserDriver`. We keep a single shared
/// instance because Sparkle requires exactly one updater per app.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    /// Owns the update path only while this build predates the Developer ID
    /// change — see `SigningMigrator`. `nil` on a migrated build, where Sparkle
    /// handles everything as usual.
    private var migrator: SigningMigrator?

    private init() {
        // startingUpdater: true begins the scheduled background checks immediately
        // (Sparkle asks the user once whether to enable automatic checks).
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Hand the migrator the controller it needs for its island popups, and take
    /// Sparkle off automatic checks for the one transitional build: Sparkle can
    /// see the Developer ID update but cannot install it, and its failure dialog
    /// is exactly the dead end the migrator exists to avoid.
    func start(controller islandController: DynamicIslandController) {
        guard SigningMigrator.isTransitionalBuild else { return }
        migrator = SigningMigrator(controller: islandController)
        controller.updater.automaticallyChecksForUpdates = false
        Task { await migrator?.migrateIfNeeded() }
        // Lyria is a menu-bar agent that can stay up for days, so a launch-only
        // check would strand whoever never quits it. Re-check on Sparkle's own
        // default cadence until the migration lands.
        migrationTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.migrator?.migrateIfNeeded() }
        }
    }

    private var migrationTimer: Timer?

    /// True while a manual check is permitted (false mid-check). Exposed so the UI
    /// could disable the control, though we currently always show it.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Check for updates now, in response to the Settings "Check for Updates"
    /// button. Brings the app forward first so Sparkle's window appears in front —
    /// Lyria is an `LSUIElement` agent and is normally inactive.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        // On the transitional build, give the migrator first refusal: it installs
        // the Developer ID update Sparkle would reject. It declines (returns false)
        // for anything else, and Sparkle takes over as normal.
        guard let migrator else {
            controller.checkForUpdates(nil)
            return
        }
        Task {
            if await migrator.migrateIfNeeded() { return }
            controller.checkForUpdates(nil)
        }
    }
}
