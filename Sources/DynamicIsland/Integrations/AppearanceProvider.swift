import AppKit
import SwiftUI

/// Mirrors macOS light / dark appearance switches onto the island.
///
/// The system broadcasts `AppleInterfaceThemeChangedNotification` over the
/// *distributed* notification center whenever the interface style flips (manual
/// toggle, or the Auto schedule at sunrise/sunset). We read the resulting
/// `AppleInterfaceStyle` default ("Dark", or absent for Light) and present a
/// sun/moon banner. This needs no special permission — the distributed
/// notification and the global default are both readable by any app.
@MainActor
final class AppearanceProvider: NSObject, IslandContentProvider {
    let id = "com.dynamicisland.appearance"

    private weak var controller: DynamicIslandController?

    /// Last appearance we presented, so the (sometimes repeated, sometimes
    /// slightly-early) theme notification only produces one banner per change.
    private var lastIsDark: Bool?

    private let bannerDuration: TimeInterval = 2.8
    private let mockMode = ProcessInfo.processInfo.environment["DI_MOCK_APPEARANCE"] == "1"

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        if mockMode {
            present(isDark: true)
            return
        }
        // Record the current appearance silently so launch itself is never
        // announced — only an actual switch afterwards is.
        lastIsDark = Self.isDarkNow()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil)
    }

    func stopObserving() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func themeChanged() {
        // The notification can fire several times for one switch and occasionally
        // a touch before the default settles — re-read on the next runloop tick
        // and dedupe against the last value so only real changes surface.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let dark = Self.isDarkNow()
            guard dark != self.lastIsDark else { return }
            self.lastIsDark = dark
            self.present(isDark: dark)
        }
    }

    /// True when the system is currently in Dark mode. The `AppleInterfaceStyle`
    /// global default is "Dark" in dark mode and absent in light mode.
    private static func isDarkNow() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    private func present(isDark: Bool) {
        controller?.presentPopup(IslandPopup(
            id: "appearance.\(isDark ? "dark" : "light")",
            title: "Appearance",
            message: isDark ? "Dark Mode" : "Light Mode",
            icon: .symbol(isDark ? "moon.fill" : "sun.max.fill"),
            accent: isDark ? Color.indigo : Color.orange,
            autoDismissAfter: bannerDuration))
    }
}
