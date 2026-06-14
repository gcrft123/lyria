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

    private init() {
        // startingUpdater: true begins the scheduled background checks immediately
        // (Sparkle asks the user once whether to enable automatic checks).
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// True while a manual check is permitted (false mid-check). Exposed so the UI
    /// could disable the control, though we currently always show it.
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Check for updates now, in response to the Settings "Check for Updates"
    /// button. Brings the app forward first so Sparkle's window appears in front —
    /// Lyria is an `LSUIElement` agent and is normally inactive.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
