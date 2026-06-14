import SwiftUI

/// Whether the camera and/or microphone are currently in use system-wide.
struct DeviceUsage: Equatable {
    var camera: Bool = false
    var microphone: Bool = false

    var isActive: Bool { camera || microphone }
}

/// Watches the system camera/mic status and surfaces it as an island side
/// extension — an orange blob riding at the island's trailing edge whenever the
/// camera or mic is live. The system's "you're being recorded" tell, in the
/// island's own language.
///
/// Like the rest of the island, it polls (here once a second) rather than
/// wrangling CoreAudio/CMIO property listeners — simpler, permission-free, and
/// plenty responsive for a privacy indicator.
@MainActor
final class PrivacyMonitor: IslandExtensionProvider {

    /// Stable id for the extension this provider owns.
    let extensionID = "io.github.gcrft123.lyria.privacy"

    /// The same orange the menu-bar recording dot uses.
    static let tint = Palette.recording

    private weak var controller: DynamicIslandController?
    private var timer: Timer?

    /// DI_DEBUG_PRIVACY=1 logs each poll's detected state.
    private let debug = ProcessInfo.processInfo.environment["DI_DEBUG_PRIVACY"] == "1"

    /// DI_FORCE_PRIVACY=cam|mic|both pins the blob on for screenshots.
    private let forcedUsage: DeviceUsage? = {
        switch ProcessInfo.processInfo.environment["DI_FORCE_PRIVACY"]?.lowercased() {
        case "cam", "camera": return DeviceUsage(camera: true, microphone: false)
        case "mic", "microphone": return DeviceUsage(camera: false, microphone: true)
        case "both", "all", "1": return DeviceUsage(camera: true, microphone: true)
        default: return nil
        }
    }()

    func startProviding(into controller: DynamicIslandController) {
        self.controller = controller
        poll()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopProviding() {
        timer?.invalidate()
        timer = nil
        controller?.removeExtension(id: extensionID)
    }

    private func poll() {
        let usage = forcedUsage ?? DeviceUsage(
            camera: DeviceActivityProbe.isCameraActive(),
            microphone: DeviceActivityProbe.isMicrophoneActive())
        if debug {
            NSLog("[privacy] camera=\(usage.camera) mic=\(usage.microphone)")
        }
        apply(usage)
    }

    /// Push or pull the orange extension to mirror current usage.
    private func apply(_ usage: DeviceUsage) {
        guard let controller else { return }
        guard usage.isActive else {
            controller.removeExtension(id: extensionID)
            return
        }
        var symbols: [String] = []
        if usage.camera { symbols.append("video.fill") }
        if usage.microphone { symbols.append("mic.fill") }
        controller.setExtension(
            IslandExtension(
                id: extensionID,
                edge: .leading,
                attachment: .detached,
                symbols: symbols,
                tint: Self.tint,
                order: 0))
    }
}
