import AppKit
import Foundation

/// Suppresses the system's own notification banners while the island is
/// mirroring them, so that only the island's popups appear.
///
/// macOS gives third-party apps no way to intercept or hide another app's
/// banner, so the one available lever is **Do Not Disturb**: with DND on, the
/// system shows no banners but notifications still land in Notification Center's
/// store — which `NotificationProvider` reads and re-presents on the island. The
/// only reliable way to set a Focus from code on current macOS is to run a
/// user-made Shortcut through the `shortcuts` CLI, so this expects two one-action
/// shortcuts to exist (created once by the user):
///
///   • "Dynamic Island DND On"  — a single "Turn Do Not Disturb On"  action
///   • "Dynamic Island DND Off" — a single "Turn Do Not Disturb Off" action
///
/// DND is turned on only once the provider confirms it can actually read the
/// store (wired in `AppDelegate`); if Full Disk Access is missing we leave the
/// system banners alone rather than hiding notifications with nothing to show in
/// their place. Set `DI_DISABLE_DND=1` to keep the app from touching Focus at all
/// (used when testing the UI without altering the real system state).
@MainActor
final class FocusController {
    static let onShortcutName = "Dynamic Island DND On"
    static let offShortcutName = "Dynamic Island DND Off"

    private let disabled = ProcessInfo.processInfo.environment["DI_DISABLE_DND"] == "1"
    private var isOn = false

    /// True while *this app* is holding Do Not Disturb on to suppress system
    /// banners. The focus mirror reads this to avoid announcing the DND that the
    /// app itself turned on (which isn't a user-driven Focus change).
    var isAssertingDND: Bool { isOn }

    /// Turn Do Not Disturb on (idempotent). No-op if already on or disabled.
    func enable() {
        guard !disabled, !isOn else { return }
        isOn = true
        run(Self.onShortcutName, wait: false)
    }

    /// Restore the system's banners. Pass `wait: true` on app termination so the
    /// shortcut has a chance to finish before the process exits.
    func disable(wait: Bool = false) {
        guard !disabled, isOn else { return }
        isOn = false
        run(Self.offShortcutName, wait: wait)
    }

    private func run(_ shortcutName: String, wait: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["run", shortcutName]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            if wait { task.waitUntilExit() }
        } catch {
            FileHandle.standardError.write(Data(
                "DynamicIsland: couldn't run Shortcut \"\(shortcutName)\" — create it in the Shortcuts app so the island can hide the system's own banners. (\(error.localizedDescription))\n".utf8))
        }
    }
}
