import AppKit
import CoreWLAN
import SwiftUI

/// Mirrors Wi-Fi connection changes onto the island.
///
/// Uses CoreWLAN's `CWWiFiClient` event monitoring: the system calls our
/// delegate when the radio powers on/off (`powerDidChange`), when the
/// association changes (`linkDidChange`), or when the joined network changes
/// (`ssidDidChange`). On each we re-read the interface and present a banner for
/// real transitions only.
///
/// Privacy note: reading the network *name* (`ssid()`) requires Location access
/// on recent macOS, and returns nil without it. We degrade gracefully — the
/// connected/disconnected state (from `interfaceMode()` / `powerOn()`, which
/// need no permission) is always mirrored; the SSID is shown when available and
/// omitted ("a network") otherwise. CoreWLAN delegate callbacks arrive off the
/// main thread, so each hops back onto the main actor before touching state.
@MainActor
final class WiFiProvider: NSObject, IslandContentProvider, CWEventDelegate {
    let id = "io.github.gcrft123.lyria.wifi"

    private weak var controller: DynamicIslandController?
    private let client = CWWiFiClient.shared()

    /// Last observed state, so only genuine changes produce a banner.
    private var lastPowerOn: Bool?
    private var lastConnected: Bool?
    private var lastSSID: String?

    private let accent = Color.blue
    private let bannerDuration: TimeInterval = 3.0
    private let mockMode = ProcessInfo.processInfo.environment["DI_MOCK_WIFI"] == "1"

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        if mockMode {
            controller?.presentPopup(IslandPopup(
                id: "wifi.connected",
                title: "Wi-Fi",
                message: "Connected to “HomeNet”",
                icon: .symbol("wifi"),
                accent: accent,
                autoDismissAfter: bannerDuration))
            return
        }

        // Prime current state silently so launch isn't announced.
        let iface = client.interface()
        lastPowerOn = iface?.powerOn()
        lastConnected = (iface?.powerOn() ?? false) && iface?.interfaceMode() != CWInterfaceMode.none
        lastSSID = iface?.ssid()

        client.delegate = self
        do {
            try client.startMonitoringEvent(with: .powerDidChange)
            try client.startMonitoringEvent(with: .linkDidChange)
            try client.startMonitoringEvent(with: .ssidDidChange)
        } catch {
            FileHandle.standardError.write(Data(
                "DynamicIsland: Wi-Fi monitor couldn't start (\(error.localizedDescription)).\n".utf8))
        }
    }

    func stopObserving() {
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }

    // MARK: CWEventDelegate (delivered off the main thread → hop to main)

    @objc nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    @objc nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    @objc nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.evaluate() }
    }

    // MARK: Evaluation

    /// Re-read the interface and present a banner for any real change since last
    /// time. Power-off is announced once; turning back on is left silent (the
    /// following association produces the "Connected" banner). Connecting,
    /// switching networks, and disconnecting each produce one banner.
    private func evaluate() {
        guard let iface = client.interface() else { return } // no Wi-Fi hardware

        let powerOn = iface.powerOn()
        let connected = powerOn && iface.interfaceMode() != CWInterfaceMode.none
        let ssid = connected ? iface.ssid() : nil

        defer {
            lastPowerOn = powerOn
            lastConnected = connected
            lastSSID = ssid
        }

        // Radio turned off entirely.
        guard powerOn else {
            if lastPowerOn != false {
                present(message: "Off", symbol: "wifi.slash")
            }
            return
        }

        if connected {
            // Newly connected, or hopped to a different network.
            if lastConnected != true || ssid != lastSSID {
                let where_ = ssid.map { "“\($0)”" } ?? "a network"
                present(message: "Connected to \(where_)", symbol: "wifi")
            }
        } else {
            // Dropped a connection (ignore on→idle that never had a link).
            if lastConnected == true {
                present(message: "Disconnected", symbol: "wifi.exclamationmark")
            }
        }
    }

    private func present(message: String, symbol: String) {
        controller?.presentPopup(IslandPopup(
            id: "wifi.\(message)",
            title: "Wi-Fi",
            message: message,
            icon: .symbol(symbol),
            accent: accent,
            autoDismissAfter: bannerDuration))
    }
}
