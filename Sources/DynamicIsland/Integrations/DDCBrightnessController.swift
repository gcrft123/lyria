import AppKit
import CoreGraphics
import Foundation
import IOKit

/// Controls the brightness of EXTERNAL displays over DDC/CI — the same trick
/// MonitorControl uses, because Apple's brightness APIs (DisplayServices /
/// CoreDisplay) only touch the built-in panel.
///
/// On Apple Silicon there's no public I2C API, so we go through the private
/// `IOAVService*` symbols (resolved by `dlsym` from IOKit, like DisplayServices
/// elsewhere) and speak DDC/CI directly: a Set-VCP write of feature 0x10
/// (luminance). Each external display is paired to its `IOAVService` by walking
/// the IORegistry for `DCPAVServiceProxy` nodes whose `Location` is `External`.
///
/// Intel Macs (a different IOFramebuffer I2C path) and displays that don't speak
/// DDC simply report `canControl == false`, so the caller falls back to letting
/// the system handle the key.
///
/// The actual I2C write is dispatched to a serial background queue so it never
/// blocks the event-tap callback; the brightness level shown on the HUD is
/// tracked in an on-main cache (DDC reads are slow and many monitors refuse
/// them, so we seed once and then track writes).
@MainActor
final class DDCBrightnessController {

    // MARK: Private IOAVService bindings (resolved from IOKit at runtime)

    private typealias CreateWithServiceFn =
        @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteI2CFn =
        @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias ReadI2CFn =
        @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    // `nonisolated`: an immutable, Sendable tuple of C function pointers resolved
    // once at startup. It's read from the background `ioQueue` (the I2C write) as
    // well as the main actor; opting it out of the class's main-actor isolation
    // lets the background closure reference it without a concurrency warning.
    private nonisolated static let io: (create: CreateWithServiceFn, write: WriteI2CFn, read: ReadI2CFn)? = {
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        guard let handle = dlopen(path, RTLD_LAZY),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let write = dlsym(handle, "IOAVServiceWriteI2C"),
              let read = dlsym(handle, "IOAVServiceReadI2C")
        else { return nil }
        return (unsafeBitCast(create, to: CreateWithServiceFn.self),
                unsafeBitCast(write, to: WriteI2CFn.self),
                unsafeBitCast(read, to: ReadI2CFn.self))
    }()

    // MARK: DDC constants

    /// 7-bit I2C address of a DDC/CI display.
    private let chipAddress: UInt32 = 0x37
    /// The "source" sub-address byte that leads every DDC/CI message.
    private let dataAddress: UInt32 = 0x51
    /// VCP feature code for luminance / brightness.
    private let brightnessVCP: UInt8 = 0x10
    /// VCP feature code for the display's built-in speaker volume (MCCS "Audio:
    /// Speaker Volume"). Driven the same way as brightness, for monitors whose
    /// HDMI/DisplayPort audio macOS itself can't set.
    private let audioVCP: UInt8 = 0x62

    // MARK: State (main-actor)

    private var services: [CGDirectDisplayID: CFTypeRef] = [:]
    private var didMap = false
    /// Cached brightness per display, in the display's own 0…max DDC units.
    private var level: [CGDirectDisplayID: Int] = [:]
    private var maxValue: [CGDirectDisplayID: Int] = [:]
    /// Same, for the speaker-volume feature (separate so the two don't collide).
    private var audioLevel: [CGDirectDisplayID: Int] = [:]
    private var audioMax: [CGDirectDisplayID: Int] = [:]

    /// Serial queue for the (slow, blocking) I2C writes.
    private let ioQueue = DispatchQueue(label: "com.dynamicisland.ddc")

    init() {
        // Re-map when displays are plugged/unplugged or rearranged.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
    }

    /// Whether this display can be driven over DDC right now.
    func canControl(_ display: CGDirectDisplayID) -> Bool {
        Self.io != nil && service(for: display) != nil
    }

    /// The first external display we can drive over DDC, or `nil`. Used as a
    /// fallback target when the display under the cursor can't be controlled
    /// (e.g. the cursor is on the built-in panel but the user wants the monitor).
    func firstControllableExternal() -> CGDirectDisplayID? {
        if !didMap { rebuildMap() }
        return externalDisplays().first { services[$0] != nil }
    }

    /// One-line diagnostic of the current DDC mapping (for the debug log).
    func debugSummary() -> String {
        let displays = externalDisplays()
        let avCount = Self.io == nil ? -1 : externalAVServices().count
        return "ddc[io=\(Self.io != nil) extDisplays=\(displays) avServices=\(avCount) mapped=\(services.count)]"
    }

    /// Nudge the external display's brightness by `steps` notches (each ≈1/16 of
    /// the range, matching the system's granularity) and return the new 0…1
    /// level for the HUD. `nil` if the display can't be controlled.
    func adjust(_ display: CGDirectDisplayID, bySteps steps: Int) -> Double? {
        guard let service = service(for: display) else { return nil }
        seedIfNeeded(display, service: service)

        let mx = maxValue[display] ?? 100
        let stepSize = max(1, mx / 16)
        let current = level[display] ?? mx / 2
        let next = max(0, min(mx, current + steps * stepSize))
        level[display] = next

        writeVCP(brightnessVCP, value: next, max: mx, display: display, service: service)
        return Double(next) / Double(max(1, mx))
    }

    /// Whether this display's speaker volume can be driven over DDC right now —
    /// the same reachability as brightness (a paired external `IOAVService`).
    func canControlAudio(_ display: CGDirectDisplayID) -> Bool { canControl(display) }

    /// Nudge the external display's SPEAKER VOLUME by `steps` notches and return
    /// the new 0…1 level for the HUD. `nil` if the display can't be driven over
    /// DDC. Mirrors `adjust`, on its own VCP + cache.
    func adjustAudio(_ display: CGDirectDisplayID, bySteps steps: Int) -> Double? {
        guard let service = service(for: display) else { return nil }
        seedAudioIfNeeded(display, service: service)

        let mx = audioMax[display] ?? 100
        let stepSize = max(1, mx / 16)
        let current = audioLevel[display] ?? mx / 2
        let next = max(0, min(mx, current + steps * stepSize))
        audioLevel[display] = next

        writeVCP(audioVCP, value: next, max: mx, display: display, service: service)
        return Double(next) / Double(max(1, mx))
    }

    /// Dispatch a Set-VCP write to the I2C queue, with the retry/settle pattern
    /// many panels need. Shared by brightness and audio.
    private func writeVCP(_ vcp: UInt8, value: Int, max mx: Int,
                          display: CGDirectDisplayID, service: CFTypeRef) {
        var packet = buildPacket([vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
        let svc = service
        let chip = chipAddress
        let addr = dataAddress
        ioQueue.async {
            guard let write = Self.io?.write else { return }
            // Match MonitorControl's Arm64DDC: many panels ignore a single bare
            // write, so settle with a pre-write delay, do a couple of write cycles
            // per pass, and retry a few passes until one returns success (0).
            var lastResult: Int32 = -1
            outer: for pass in 0..<5 {
                if pass > 0 { usleep(20_000) }
                for _ in 0..<2 {
                    usleep(10_000)
                    lastResult = write(svc, chip, addr, &packet, UInt32(packet.count))
                }
                if lastResult == 0 { break outer }
            }
            HUDDebug.log("ddc write vcp=\(String(format: "%02X", vcp)) display=\(display) "
                + "next=\(value)/\(mx) result=\(lastResult) "
                + "packet=\(packet.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
    }

    func invalidate() {
        services.removeAll()
        didMap = false
        // Keep the brightness cache — the same panels usually come back.
    }

    // MARK: Seeding / reading

    /// On first touch, try one DDC read to learn the real current & max; if the
    /// monitor refuses the read (common), fall back to a sane default so the
    /// first keypress still does something reasonable.
    private func seedIfNeeded(_ display: CGDirectDisplayID, service: CFTypeRef) {
        guard level[display] == nil else { return }
        if let (current, mx) = read(service: service, vcp: brightnessVCP) {
            maxValue[display] = mx
            level[display] = current
        } else {
            maxValue[display] = 100
            level[display] = 50
        }
    }

    /// As `seedIfNeeded`, for the speaker-volume feature.
    private func seedAudioIfNeeded(_ display: CGDirectDisplayID, service: CFTypeRef) {
        guard audioLevel[display] == nil else { return }
        if let (current, mx) = read(service: service, vcp: audioVCP) {
            audioMax[display] = mx
            audioLevel[display] = current
        } else {
            audioMax[display] = 100
            audioLevel[display] = 50
        }
    }

    private func read(service: CFTypeRef, vcp: UInt8) -> (current: Int, max: Int)? {
        guard let io = Self.io else { return nil }
        // Send a Get-VCP request, then read the reply.
        var request = buildPacket([vcp])
        _ = io.write(service, chipAddress, dataAddress, &request, UInt32(request.count))
        usleep(25_000)
        var reply = [UInt8](repeating: 0, count: 12)
        guard io.read(service, chipAddress, 0, &reply, UInt32(reply.count)) == 0 else { return nil }
        let mx = Int(reply[6]) * 256 + Int(reply[7])
        let current = Int(reply[8]) * 256 + Int(reply[9])
        guard mx > 0, mx <= 0x7FFF, current >= 0, current <= mx else { return nil }
        return (current, mx)
    }

    /// Build a DDC/CI message: `[0x80|(n+1), n, payload…, checksum]`, where the
    /// checksum XORs every prior byte seeded with `(chip<<1) ^ dataAddress`. For
    /// a Set-VCP the payload is `[vcp, hi, lo]` (n=3 ⇒ opcode byte 0x03); for a
    /// Get-VCP it's `[vcp]` (n=1 ⇒ opcode byte 0x01).
    private func buildPacket(_ payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)]
        packet += payload
        var checksum = UInt8((chipAddress << 1) ^ dataAddress)
        for byte in packet { checksum ^= byte }
        packet.append(checksum)
        return packet
    }

    // MARK: Display ⇆ IOAVService mapping

    private func service(for display: CGDirectDisplayID) -> CFTypeRef? {
        if let cached = services[display] { return cached }
        if !didMap { rebuildMap() }
        return services[display]
    }

    /// Pair external displays to external `IOAVService`s in registry order. The
    /// common case (a single external monitor) maps unambiguously; multi-monitor
    /// rigs pair by enumeration order.
    private func rebuildMap() {
        didMap = true
        services.removeAll()
        let displays = externalDisplays()
        let avServices = externalAVServices()
        for (index, display) in displays.enumerated() where index < avServices.count {
            services[display] = avServices[index]
        }
    }

    private func externalDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsOnline($0) != 0 }
    }

    /// Every external display's `IOAVService`, in IORegistry order — the
    /// `DCPAVServiceProxy` nodes whose `Location` property is `External`.
    private func externalAVServices() -> [CFTypeRef] {
        guard let io = Self.io else { return [] }
        var result: [CFTypeRef] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [] }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let location = IORegistryEntryCreateCFProperty(
                entry, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
            if location == "External", let service = io.create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                result.append(service)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)
        return result
    }
}
