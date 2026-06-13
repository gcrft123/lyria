import AppKit
import IOBluetooth
import SwiftUI

/// Surfaces Bluetooth connect / disconnect events on the island as popups,
/// iPhone-style ("AirPods Pro · Connected") with a glyph chosen for the device
/// type.
///
/// Uses classic-Bluetooth notifications from `IOBluetooth`: a single global
/// connect notification fires whenever a paired device connects; we then arm a
/// per-device disconnect notification so the matching "Disconnected" banner can
/// fire too. Devices already connected at launch do NOT replay (the connect
/// notification only fires on a *new* connection), so the island stays quiet
/// until something actually changes. No TCC prompt is involved — this is the
/// classic-BT device API, not CoreBluetooth scanning.
@MainActor
final class BluetoothProvider: NSObject, IslandContentProvider {
    let id = "com.dynamicisland.bluetooth"

    private weak var controller: DynamicIslandController?

    private var connectNotification: IOBluetoothUserNotification?
    /// Live disconnect notifications, keyed by device address, so each is armed
    /// once and torn down when it fires.
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    /// Throttle: some devices bounce their connection (AirPods open multiple
    /// audio channels); suppress repeat banners for the same device within a
    /// short window.
    private var lastEventAt: [String: Date] = [:]

    private let accent = Color.blue
    private let bannerDuration: TimeInterval = 3.5
    private let repeatWindow: TimeInterval = 6.0

    private let mockMode = ProcessInfo.processInfo.environment["DI_MOCK_BLUETOOTH"] == "1"

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        if mockMode {
            controller?.presentPopup(IslandPopup(
                id: "mock-bluetooth",
                title: "AirPods Pro",
                message: "Connected",
                icon: .symbol("airpodspro"),
                accent: accent,
                autoDismissAfter: bannerDuration))
            return
        }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:)))
    }

    func stopObserving() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    // MARK: IOBluetooth callbacks (delivered on the main run loop we registered on)

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification,
                                       device: IOBluetoothDevice) {
        let key = device.addressString ?? device.name ?? UUID().uuidString
        present(device: device, message: "Connected", key: key)

        // Arm a disconnect notification for this device if we don't already have
        // one (re-connects reuse the existing arm).
        if disconnectNotifications[key] == nil {
            disconnectNotifications[key] = device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDisconnected(_:device:)))
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification,
                                          device: IOBluetoothDevice) {
        let key = device.addressString ?? device.name ?? ""
        present(device: device, message: "Disconnected", key: key)
        notification.unregister()
        disconnectNotifications[key] = nil
    }

    // MARK: Presentation

    private func present(device: IOBluetoothDevice, message: String, key: String) {
        // Drop repeats for the same device within the throttle window.
        let now = Date()
        if let last = lastEventAt[key], now.timeIntervalSince(last) < repeatWindow,
           message == "Connected" {
            return
        }
        lastEventAt[key] = now

        let name = device.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        controller?.presentPopup(IslandPopup(
            id: "bt.\(key).\(message)",
            title: (name?.isEmpty == false ? name! : "Bluetooth Device"),
            message: message,
            icon: .symbol(Self.symbol(for: device)),
            accent: accent,
            autoDismissAfter: bannerDuration))
    }

    /// Pick a glyph for the device. Name heuristics first (Apple devices report
    /// recognisable names), falling back to the Bluetooth major device class.
    static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        switch true {
        case name.contains("airpods max"):                 return "airpodsmax"
        case name.contains("airpods pro"):                 return "airpodspro"
        case name.contains("airpods"):                     return "airpods"
        case name.contains("beats"):                       return "beats.headphones"
        case name.contains("keyboard"):                    return "keyboard"
        case name.contains("trackpad"):                    return "hand.point.up.left.fill"
        case name.contains("mouse"):                       return "magicmouse.fill"
        case name.contains("watch"):                       return "applewatch"
        case name.contains("iphone"):                      return "iphone"
        case name.contains("ipad"):                        return "ipad"
        case name.contains("controller"), name.contains("xbox"),
             name.contains("dualsense"), name.contains("dualshock"):
            return "gamecontroller.fill"
        case name.contains("speaker"), name.contains("soundlink"),
             name.contains("boom"), name.contains("homepod"):
            return "hifispeaker.fill"
        default: break
        }
        // Major device class fallback (see Bluetooth assigned numbers).
        switch Int(device.deviceClassMajor) {
        case 0x04: return "headphones"        // Audio
        case 0x05: return "keyboard"          // Peripheral (keyboard/pointing)
        case 0x02: return "iphone"            // Phone
        case 0x01: return "laptopcomputer"    // Computer
        default:   return "dot.radiowaves.left.and.right"
        }
    }
}
