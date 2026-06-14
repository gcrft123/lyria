import AppKit
import SwiftUI

/// Mirrors external display connect / disconnect onto the island.
///
/// `NSApplication.didChangeScreenParametersNotification` fires for any screen
/// reconfiguration — connect, disconnect, resolution or arrangement change. We
/// keep a snapshot of attached screens keyed by their CoreGraphics display id
/// (`NSScreenNumber`) and diff it on each event, so only an actual add or remove
/// produces a banner (resolution/arrangement tweaks reuse the same ids and stay
/// silent). The built-in panel is skipped so clamshell open/close on a laptop
/// doesn't masquerade as an external display event. No special permission is
/// required.
@MainActor
final class DisplayProvider: NSObject, IslandContentProvider {
    let id = "io.github.gcrft123.lyria.display"

    private weak var controller: DynamicIslandController?

    /// Attached external screens by display id → display name, so a change can
    /// be diffed into added / removed displays.
    private var known: [CGDirectDisplayID: String] = [:]

    private let accent = Color.teal
    private let bannerDuration: TimeInterval = 3.5
    private let mockMode = ProcessInfo.processInfo.environment["DI_MOCK_DISPLAY"] == "1"

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        if mockMode {
            present(name: "DELL S2721QS", connected: true)
            return
        }
        // Snapshot what's already attached so launch never replays current
        // displays — only changes from here surface.
        known = Self.currentExternalScreens()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screensChanged() {
        let current = Self.currentExternalScreens()

        // Newly attached.
        for (id, name) in current where known[id] == nil {
            present(name: name, connected: true)
        }
        // Newly removed.
        for (id, name) in known where current[id] == nil {
            present(name: name, connected: false)
        }
        known = current
    }

    /// External (non-built-in) screens keyed by display id. The built-in panel
    /// is excluded so a laptop's own display never registers as a connect/remove.
    private static func currentExternalScreens() -> [CGDirectDisplayID: String] {
        var map: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(id) != 0 { continue }
            map[id] = screen.localizedName
        }
        return map
    }

    private func present(name: String, connected: Bool) {
        let title = name.isEmpty ? "Display" : name
        controller?.presentPopup(IslandPopup(
            id: "display.\(name).\(connected ? "on" : "off")",
            title: title,
            message: connected ? "Connected" : "Disconnected",
            icon: .symbol(connected ? "display" : "display.trianglebadge.exclamationmark"),
            accent: accent,
            autoDismissAfter: bannerDuration))
    }
}
