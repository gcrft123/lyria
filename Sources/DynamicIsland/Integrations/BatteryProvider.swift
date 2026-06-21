import AppKit
import IOKit.ps
import SwiftUI

/// Mirrors power events onto the island as live-activity status pills: started /
/// stopped charging, low battery, and Low Power Mode turning on. Each left-click
/// opens the Battery pane in System Settings.
///
/// Charging + capacity come from the IOKit power-sources API (a run-loop source
/// fires on any change); Low Power Mode comes from `ProcessInfo` +
/// `NSProcessInfoPowerStateDidChange`. On a desktop Mac (no internal battery) the
/// charging/low-battery events simply never fire; Low Power Mode still does.
@MainActor
final class BatteryProvider: NSObject, IslandContentProvider {
    let id = "io.github.gcrft123.lyria.battery"

    private weak var controller: DynamicIslandController?

    private var runLoopSource: CFRunLoopSource?

    /// Last seen state, so only genuine transitions announce.
    private var lastCharging: Bool?
    private var lastLowPower: Bool?
    /// Whether the current low-battery dip has already been announced (re-arms
    /// once the battery recovers above the threshold or starts charging).
    private var lowNotified = false

    private let lowThreshold = 20
    private let bannerDuration: TimeInterval = 4.0
    private let mockMode = ProcessInfo.processInfo.environment["DI_MOCK_BATTERY"] == "1"

    /// System Settings → Battery (Ventura+). Harmless on a battery-less Mac; the
    /// events that link here don't fire there anyway.
    private static let batterySettingsURL = "x-apple.systempreferences:com.apple.Battery-Settings.extension"

    func didRegister(with controller: DynamicIslandController) { self.controller = controller }

    func startObserving() {
        if mockMode {
            notify(title: "Charging", message: "80%", symbol: "battery.100.bolt", accent: Palette.green)
            return
        }

        // Prime current state so launch isn't announced.
        if let snap = Self.read() {
            lastCharging = snap.charging
            lowNotified = !snap.charging && snap.percent <= lowThreshold
        }
        lastLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        // Power-source changes (charging / capacity). The run-loop source is added
        // to the main run loop, so the C callback fires on the main thread; it hops
        // through the main queue to reach this main-actor instance.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let provider = Unmanaged<BatteryProvider>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { provider.evaluatePowerSource() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // Low Power Mode toggles (delivered off-main → hop to main, like the others).
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    func stopObserving() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        runLoopSource = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc nonisolated private func powerStateChanged() {
        DispatchQueue.main.async { [weak self] in self?.evaluateLowPower() }
    }

    // MARK: Evaluation

    private func evaluatePowerSource() {
        guard let snap = Self.read() else { return }   // no internal battery → nothing to announce
        let previous = lastCharging
        lastCharging = snap.charging

        if let previous, previous != snap.charging {
            if snap.charging {
                notify(title: "Charging", message: "\(snap.percent)%", symbol: "battery.100.bolt", accent: Palette.green)
                lowNotified = false
            } else {
                notify(title: "Not Charging", message: "\(snap.percent)%", symbol: "battery.50", accent: AppSettings.neutralAccent)
            }
        }

        // Low battery: dipped to/below the threshold while unplugged — announced once.
        if !snap.charging, snap.percent <= lowThreshold {
            if !lowNotified {
                lowNotified = true
                notify(title: "Low Battery", message: "\(snap.percent)% remaining", symbol: "battery.25", accent: Palette.orange)
            }
        } else {
            lowNotified = false   // recovered above the threshold (or charging) → re-arm
        }
    }

    private func evaluateLowPower() {
        let on = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard on != lastLowPower else { return }
        lastLowPower = on
        if on {   // the request is "low power mode on" — turning it off isn't announced
            notify(title: "Low Power Mode", message: "On", symbol: "bolt.fill", accent: Palette.orange)
        }
    }

    private func notify(title: String, message: String, symbol: String, accent: Color) {
        controller?.presentPopup(IslandPopup(
            id: "battery.\(title)",
            style: .liveActivity,
            title: title,
            message: message,
            icon: .symbol(symbol),
            openURL: Self.batterySettingsURL,
            accent: accent,
            autoDismissAfter: bannerDuration))
    }

    // MARK: Power-source read

    private struct Snapshot { let charging: Bool; let percent: Int }

    /// The internal battery's charging state + percentage, or nil on a Mac without
    /// one (desktop). MUST be cheap — it runs on every power-source change.
    private static func read() -> Snapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let current = (desc[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let maximum = (desc[kIOPSMaxCapacityKey] as? Int) ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            return Snapshot(charging: charging, percent: percent)
        }
        return nil
    }
}
