import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation
import ObjectiveC
import os

/// Lightweight diagnostic log for the HUD / brightness path, written to
/// `/tmp/di_hud_debug.log`. Gated on the `DIDebugHUD` user default (read once),
/// NOT an env var, so it works for the normal `open`-launched app where TCC
/// grants live (env vars aren't forwarded through LaunchServices). Enable with:
///   `defaults write io.github.gcrft123.lyria DIDebugHUD -bool YES`
/// then relaunch. Safe to call from any thread.
enum HUDDebug {
    static let enabled = UserDefaults.standard.bool(forKey: "DIDebugHUD")
    private static let path = "/tmp/di_hud_debug.log"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, message())
        let data = Data(line.utf8)
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// Replaces the macOS volume/brightness HUD with the island's own.
///
/// macOS gives no way to suppress the system overlay directly, so we intercept
/// the hardware media keys BEFORE the system sees them: a `CGEventTap` on the
/// `NSSystemDefined` stream catches volume up/down/mute and brightness up/down,
/// SWALLOWS them (so the system never shows its HUD), applies the change
/// ourselves (CoreAudio for volume, the private DisplayServices framework for
/// brightness), and presents an island HUD instead.
///
/// The tap needs **Accessibility** permission (System Settings ▸ Privacy &
/// Security ▸ Accessibility). Without it `CGEvent.tapCreate` returns nil, so on
/// first launch we trigger the system prompt and keep retrying until it's
/// granted — until then the system's own HUD keeps working untouched.
///
/// Debug: `DI_DISABLE_HUD=1` skips the tap entirely (so the app doesn't grab the
/// media keys / need Accessibility while testing other features); `DI_MOCK_HUD=
/// volume|brightness|keyboard|mute` seeds a sample overlay at launch (handled in
/// the controller) to verify rendering without a real keypress.
@MainActor
final class SystemHUDProvider: IslandContentProvider {

    let id = "io.github.gcrft123.lyria.hud"

    private weak var controller: DynamicIslandController?

    /// The media-key session tap, serviced off the main runloop (see `EventTap`).
    private var tap: EventTap?
    private var retryTimer: Timer?

    /// Thread-safe mirrors of "is there controllable brightness / keyboard-backlight
    /// hardware here", read by the off-main tap callback so it can decide whether to
    /// swallow the brightness / illumination keys WITHOUT touching the main actor
    /// (probing DDC or CoreBrightness on the tap thread would stall system input).
    /// Refreshed on the main thread at install and whenever one of those keys is
    /// seen — so at worst the first press right after a monitor hot-plug passes
    /// through to the system, then self-corrects. Volume / mute need no mirror
    /// (always ours).
    private nonisolated let brightnessControllable = OSAllocatedUnfairLock(initialState: false)
    private nonisolated let keyboardBacklightControllable = OSAllocatedUnfairLock(initialState: false)
    /// Debounce so a held key doesn't re-probe DDC every pulse.
    private var lastCapabilityRefresh: TimeInterval = 0

    /// External-display brightness over DDC/CI (MonitorControl-style). Built-in
    /// panels still go through DisplayServices; this only kicks in when the key
    /// targets an external monitor that speaks DDC.
    private let ddc = DDCBrightnessController()

    private let disabled = ProcessInfo.processInfo.environment["DI_DISABLE_HUD"] == "1"
        || ProcessInfo.processInfo.environment["DI_MOCK_HUD"] != nil

    /// One adjustment step, matching the system's 16 notches per full range.
    private let step: Float = 1.0 / 16.0

    // MARK: Hold-to-repeat (per-pulse acceleration)
    //
    // Holding a volume/brightness key on this hardware produces NOT a sustained
    // press but a slow (~3 Hz) stream of OS key *pulses* — a keyDown + keyUp pair
    // ~15 ms apart, every ~300 ms. There is no "key is held" signal anywhere we
    // can see it: not in the CGEvent layer (the key-up fires 15 ms after every
    // down, so it never means "released"), and not in IOHIDManager (these keys
    // emit no raw HID at all on this keyboard — verified across every device).
    //
    // With only a ~3 Hz heartbeat and no release edge, a free-running timer that
    // ramps faster than the heartbeat MUST over-shoot when the key is let go (it
    // keeps stepping into empty air until a watchdog notices the pulses stopped)
    // — that's the double-tap runaway. So we never run a timer of our own:
    // **every committed step maps 1:1 to a real OS pulse**, which makes "tap
    // twice" exactly two steps, always.
    //
    // To still make *holding* fast despite the slow pulse rate, we grow the step
    // SIZE the longer the same key keeps repeating (see `holdMultiplier`). The
    // ramp's perceived smoothness comes from the HUD bar animating between values
    // in the view — that commits nothing, so it can't over-step either.

    /// One logical hold-capable key (mute is excluded — it's a one-shot toggle).
    private enum HoldKey: Equatable {
        case volumeUp, volumeDown, brightnessUp, brightnessDown, keyboardUp, keyboardDown
    }

    /// The key whose pulse run we're currently counting, for acceleration.
    private var holdKey: HoldKey?
    /// Uptime of the last pulse for `holdKey`, to tell a continued hold from a
    /// fresh gesture.
    private var holdLastTime: TimeInterval = 0
    /// How many consecutive auto-repeat pulses we've seen for `holdKey`.
    private var holdCount = 0
    /// Pulses farther apart than this start a fresh gesture (reset acceleration
    /// to ×1). Sized to bracket this keyboard's auto-repeat (~150–315 ms while
    /// held) so a real hold keeps accelerating, while *deliberately*-spaced taps
    /// (slower than this) each stay at exactly one notch — which is what keeps a
    /// double-tap from ever building speed.
    private let holdMaxGap: TimeInterval = 0.35

    // CoreAudio's volume read lags its writes, so a fast burst of
    // read-modify-write steps all read the same stale value and collapse into
    // one notch. We defeat that by tracking the target volume ourselves between
    // rapid presses (`volumeCache`), reseeding from the device only on a fresh
    // press after a pause. (Brightness already accumulates in the DDC
    // controller's own level cache, so it needs no equivalent here.)

    /// Our running target volume during a hold, in 0…1. `nil` until seeded.
    private var volumeCache: Float?
    /// Uptime of the last volume keypress, to tell a fresh press from a repeat.
    private var lastVolumeKeyTime: TimeInterval = 0
    /// Uptime of the last mute toggle, to debounce a held mute key.
    private var lastMuteKeyTime: TimeInterval = 0

    /// Same running-target trick as `volumeCache`, for the keyboard backlight —
    /// CoreBrightness's read can lag a fast burst of writes, so we accumulate our
    /// own target during a hold and only reseed from the device after a pause.
    private var keyboardCache: Float?
    /// Uptime of the last keyboard-backlight keypress.
    private var lastKeyboardKeyTime: TimeInterval = 0
    /// Level to restore when the toggle key turns the backlight back on.
    private var keyboardRestoreLevel: Float = 0.5
    /// Uptime of the last backlight toggle, to debounce a held toggle key.
    private var lastKeyboardToggleTime: TimeInterval = 0
    /// A repeat (vs. a fresh press) is anything within this window of the last.
    private let holdWindow: TimeInterval = 0.5

    // NX_KEYTYPE_* codes carried in an `NSSystemDefined` event's `data1`.
    private let soundUp: Int32 = 0
    private let soundDown: Int32 = 1
    private let brightnessUp: Int32 = 2
    private let brightnessDown: Int32 = 3
    private let mute: Int32 = 7
    // Keyboard-backlight keys (F5/F6 on a MacBook) carry these NX_KEYTYPE codes.
    private let illuminationUp: Int32 = 21
    private let illuminationDown: Int32 = 22
    private let illuminationToggle: Int32 = 23

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        guard !disabled else { return }
        installTap()
    }

    func stopObserving() {
        retryTimer?.invalidate()
        retryTimer = nil
        tap?.disable()
        tap = nil
    }

    // MARK: Hold acceleration

    /// Record one OS key pulse for a hold-capable key and return the multiplier
    /// to scale this step by. Call exactly once per keyDown.
    ///
    /// We run no timer of our own: each call corresponds to a real OS pulse, so
    /// the *count* of steps always equals the count of pulses (tap twice → two
    /// steps, never a runaway). The multiplier just grows the step SIZE while the
    /// same key keeps auto-repeating, so holding ramps quickly even though the
    /// keyboard only pulses ~3×/sec. A gap longer than `holdMaxGap`, or a
    /// different key, starts the run over at ×1 (so taps stay precise).
    private func holdMultiplier(for key: HoldKey) -> Float {
        let now = ProcessInfo.processInfo.systemUptime
        if holdKey == key, now - holdLastTime <= holdMaxGap {
            holdCount += 1
        } else {
            holdKey = key
            holdCount = 1
        }
        holdLastTime = now
        switch holdCount {
        case 1:  return 1        // a single tap is always exactly one notch
        case 2:  return 1.5      // a fast 2nd pulse (auto-repeat) starts the ramp
        case 3:  return 2.5
        case 4:  return 3.5
        case 5:  return 4.5
        default: return 5.5      // sustained hold: cap the per-pulse step
        }
    }

    // MARK: Event tap

    private func installTap() {
        guard tap == nil else { return }

        // Need Accessibility to create a session tap. We DON'T prompt here —
        // onboarding owns the Accessibility ask (it deep-links to the pane), and a
        // second system "would like to control…" alert at launch is redundant. Just
        // poll silently until it's granted, then the tap comes up on the next tick.
        guard AXIsProcessTrusted() else {
            scheduleRetry()
            return
        }

        refreshCapabilityMirrors(force: true)

        // NSSystemDefined is event type 14; media keys arrive on this stream.
        // Watch BOTH NSSystemDefined (type 14, media keys: volume/mute) AND plain
        // keyDown (type 10) at the session level — exactly like MonitorControl's
        // MediaKeyTap. The brightness keys (F1/F2) are the reason for the keyDown
        // mask: on a Mac with no built-in display they never become a subtype-8
        // media key, but they DO arrive as a keyDown for F14 (107) / F15 (113)
        // with the Fn flag set, which only a type-10 session tap can catch.
        // (Holding a key just produces a stream of these keyDowns, so we ride
        // the OS's own auto-repeat — no key-up tracking needed.)
        let mask = CGEventMask(1 << 10) | CGEventMask(1 << 14)
        let tap = EventTap(mask: mask) { [weak self] type, event in
            self?.handleTap(type: type, event: event) ?? false
        }
        tap.onStandDown = { [weak self] in self?.tapStoodDown() }
        guard tap.enable() else {
            scheduleRetry()
            return
        }
        self.tap = tap
        retryTimer?.invalidate()
        retryTimer = nil
    }

    /// Accessibility was revoked while running — drop the dead tap and wait for
    /// the grant to return (then rebuild).
    private func tapStoodDown() {
        tap = nil
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installTap() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    /// Recompute which brightness / keyboard-backlight hardware we can drive, into
    /// the thread-safe mirrors the tap callback reads. Debounced so a held key
    /// doesn't re-probe DDC every pulse.
    private func refreshCapabilityMirrors(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastCapabilityRefresh < 1.0 { return }
        lastCapabilityRefresh = now
        let canBrightness = brightnessTarget() != nil
        let canKeyboard = KeyboardBacklight.isAvailable
        brightnessControllable.withLock { $0 = canBrightness }
        keyboardBacklightControllable.withLock { $0 = canKeyboard }
    }

    /// Apply the adjustment for one of our keys and present the island HUD.
    /// Returns true when the key is one we own (so the callback swallows it,
    /// hiding the system overlay); false to let everything else pass through.
    fileprivate func handle(keyCode: Int32, isDown: Bool) -> Bool {
        HUDDebug.log("key keyCode=\(keyCode) down=\(isDown)")
        switch keyCode {
        case soundUp:
            if isDown { adjustVolume(by: step * holdMultiplier(for: .volumeUp), direction: 1) }
            return true
        case soundDown:
            if isDown { adjustVolume(by: -step * holdMultiplier(for: .volumeDown), direction: -1) }
            return true
        case mute:
            // Debounce so a held mute key doesn't flicker mute on/off.
            if isDown {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastMuteKeyTime > 0.3 { lastMuteKeyTime = now; toggleMute() }
            }
            return true
        case brightnessUp, brightnessDown:
            // Only swallow the key (and show our HUD) if we can actually drive
            // SOME display; otherwise let the system handle it normally.
            guard let display = brightnessTarget() else {
                HUDDebug.log("brightness: no controllable display \(ddc.debugSummary())")
                return false
            }
            let goingUp = keyCode == brightnessUp
            if isDown {
                let m = holdMultiplier(for: goingUp ? .brightnessUp : .brightnessDown)
                adjustBrightness(display, by: (goingUp ? step : -step) * m,
                                 direction: goingUp ? 1 : -1, steps: Int(m.rounded()))
            }
            return true
        case illuminationUp, illuminationDown:
            // Only take over (and show our HUD) when there's a controllable
            // backlight — an external keyboard with none falls through to the
            // system, exactly like the no-display brightness case above.
            guard KeyboardBacklight.isAvailable else {
                HUDDebug.log("keyboard backlight: no controllable keyboard")
                return false
            }
            let goingUp = keyCode == illuminationUp
            if isDown {
                let m = holdMultiplier(for: goingUp ? .keyboardUp : .keyboardDown)
                adjustKeyboardBacklight(by: (goingUp ? step : -step) * m,
                                        direction: goingUp ? 1 : -1)
            }
            return true
        case illuminationToggle:
            guard KeyboardBacklight.isAvailable else { return false }
            // Debounce so a held toggle key doesn't flicker the backlight.
            if isDown {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastKeyboardToggleTime > 0.3 {
                    lastKeyboardToggleTime = now
                    toggleKeyboardBacklight()
                }
            }
            return true
        default:
            return false
        }
    }

    /// The display a brightness key should act on, or `nil` if none is
    /// controllable. Preference: the screen under the cursor (if we can drive
    /// it), else any external monitor that speaks DDC, else the built-in panel.
    private func brightnessTarget() -> CGDirectDisplayID? {
        let cursor = cursorDisplay()
        if canControl(cursor) { return cursor }
        if let external = ddc.firstControllableExternal() { return external }
        let main = CGMainDisplayID()
        if CGDisplayIsBuiltin(main) != 0, Self.displayServices != nil { return main }
        return nil
    }

    /// Whether we can drive this specific display's brightness.
    private func canControl(_ display: CGDirectDisplayID) -> Bool {
        if CGDisplayIsBuiltin(display) != 0 { return Self.displayServices != nil }
        return canControlExternal(display)
    }

    /// An external display we can drive: DDC/CI if the monitor actually accepts it,
    /// else DisplayServices for Apple panels (Studio Display / Pro Display XDR), which
    /// don't speak DDC at all — `DisplayServicesGetBrightness` succeeds only for those.
    private func canControlExternal(_ display: CGDirectDisplayID) -> Bool {
        ddc.canControl(display) || Self.brightness(display) != nil
    }

    /// The external displays currently attached (non-built-in, online).
    private static func externalDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsOnline($0) != 0 }
    }

    /// Drive an external monitor's brightness over DDC for an F1/F2 keyDown (the
    /// type-10 F14/F15+Fn path). We only take over EXTERNAL monitors (built-in
    /// panels are left to the system); preference is the monitor under the
    /// cursor, else any monitor we can drive. One DDC step per keyDown, with the
    /// step growing while the key is held (`holdMultiplier`). Returns `true` if we
    /// handled it (so the caller can swallow the key), `false` to let the system
    /// have it.
    private func handleExternalBrightnessKey(up: Bool) -> Bool {
        guard externalBrightnessTarget() != nil else {
            HUDDebug.log("brightnessKey up=\(up) "
                + "no external/DDC \(ddc.debugSummary()) — left to system")
            return false
        }
        let m = holdMultiplier(for: up ? .brightnessUp : .brightnessDown)
        adjustExternalBrightness(up: up, steps: Int(m.rounded()))
        return true
    }

    /// The external monitor a brightness key should drive: the one under the
    /// cursor if we can control it, else any controllable external monitor.
    private func externalBrightnessTarget() -> CGDirectDisplayID? {
        let cursor = cursorDisplay()
        if CGDisplayIsBuiltin(cursor) == 0, canControlExternal(cursor) { return cursor }
        return Self.externalDisplays().first { canControlExternal($0) }
    }

    /// `steps` brightness steps on the external monitor, presenting the island
    /// HUD. `steps` > 1 while a held key accelerates. Routes through the shared path
    /// so an Apple external panel (no DDC) is driven via DisplayServices, and the HUD
    /// only shows when control actually works.
    private func adjustExternalBrightness(up: Bool, steps: Int = 1) {
        guard let display = externalBrightnessTarget() else { return }
        adjustBrightness(display, by: (up ? step : -step) * Float(max(1, steps)),
                         direction: up ? 1 : -1, steps: max(1, steps))
    }

    /// The display the cursor is currently over, falling back to the main display.
    private func cursorDisplay() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            if let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return number
            }
        }
        return CGMainDisplayID()
    }

    // MARK: Actions

    private func adjustVolume(by delta: Float, direction: Int) {
        guard let device = Self.defaultOutputDevice() else { return }
        // Display-audio path: when the active output's volume isn't settable by
        // macOS — the classic case being an external monitor's HDMI/DisplayPort
        // speakers — drive that monitor's speaker volume over DDC instead, so the
        // keys actually do something. Only kicks in when a DDC-capable display is
        // connected; otherwise we fall through to the normal system path below.
        if !Self.volumeSettable(device), let display = ddc.firstControllableExternal() {
            let steps = max(1, Int((abs(delta) / step).rounded()))
            if let level = ddc.adjustAudio(display, bySteps: direction * steps) {
                HUDDebug.log("volume external display=\(display) steps=\(steps) → level=\(level)")
                controller?.presentHUD(SystemHUD(kind: .volume, level: level, muted: false),
                                       direction: direction)
                return
            }
        }
        // Build on our own running target during a hold; only reseed from the
        // device on a fresh press (after a pause) so we pick up volume the user
        // changed elsewhere. CoreAudio's read lags its writes, so a rapid burst
        // of read-modify-write steps would otherwise all read the same stale
        // value and collapse into a single notch.
        let now = ProcessInfo.processInfo.systemUptime
        let base: Float
        if let cached = volumeCache, now - lastVolumeKeyTime < holdWindow {
            base = cached
        } else {
            base = Self.volume(of: device) ?? 0
        }
        lastVolumeKeyTime = now
        let next = max(0, min(1, base + delta))
        volumeCache = next
        Self.setVolume(next, of: device)
        // Any volume key un-mutes, matching the system behaviour.
        Self.setMuted(false, of: device)
        controller?.presentHUD(SystemHUD(kind: .volume, level: Double(next), muted: false),
                               direction: direction)
    }

    private func toggleMute() {
        guard let device = Self.defaultOutputDevice() else { return }
        let nowMuted = !Self.muted(of: device)
        Self.setMuted(nowMuted, of: device)
        let level = Double(Self.volume(of: device) ?? 0)
        controller?.presentHUD(SystemHUD(kind: .volume, level: level, muted: nowMuted),
                               direction: 0)
    }

    private func adjustBrightness(_ display: CGDirectDisplayID, by delta: Float,
                                  direction: Int, steps: Int = 1) {
        // External monitor that actually speaks DDC → DDC/CI.
        if CGDisplayIsBuiltin(display) == 0,
           let level = ddc.adjust(display, bySteps: direction * max(1, steps)) {
            HUDDebug.log("brightness external(DDC) display=\(display) steps=\(steps) → level=\(level)")
            controller?.presentHUD(SystemHUD(kind: .brightness, level: level),
                                   direction: direction)
            return
        }
        // Built-in, or an Apple external panel → DisplayServices. Only present the HUD
        // if it truly drives the display: `brightness()` returns nil for a non-Apple
        // external (where DDC also failed), so we leave that key to the system rather
        // than showing a change that never lands.
        guard let current = Self.brightness(display) else {
            HUDDebug.log("brightness display=\(display): no DDC, not DisplayServices-drivable — left to system")
            return
        }
        let next = max(0, min(1, current + delta))
        guard Self.setBrightness(next, display: display) else { return }
        HUDDebug.log("brightness DisplayServices display=\(display) \(current) → \(next)")
        controller?.presentHUD(SystemHUD(kind: .brightness, level: Double(next)),
                               direction: direction)
    }

    /// Step the keyboard backlight and present the island HUD. Mirrors
    /// `adjustVolume`: it builds on our own running target during a hold (so a
    /// rapid burst of steps doesn't collapse on CoreBrightness's lagging read)
    /// and only reseeds from the device on a fresh press after a pause.
    private func adjustKeyboardBacklight(by delta: Float, direction: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let base: Float
        if let cached = keyboardCache, now - lastKeyboardKeyTime < holdWindow {
            base = cached
        } else {
            base = KeyboardBacklight.level() ?? 0
        }
        lastKeyboardKeyTime = now
        let next = max(0, min(1, base + delta))
        keyboardCache = next
        if next > 0.0001 { keyboardRestoreLevel = next }
        KeyboardBacklight.setLevel(next)
        HUDDebug.log("keyboard backlight \(base) → \(next)")
        controller?.presentHUD(SystemHUD(kind: .keyboardBacklight, level: Double(next)),
                               direction: direction)
    }

    /// Toggle the backlight off ↔ its last on-level, like the system's F-key.
    private func toggleKeyboardBacklight() {
        let current = KeyboardBacklight.level() ?? 0
        let next: Float
        if current > 0.0001 {
            keyboardRestoreLevel = current
            next = 0
        } else {
            next = keyboardRestoreLevel > 0.0001 ? keyboardRestoreLevel : 0.5
        }
        keyboardCache = next
        KeyboardBacklight.setLevel(next)
        HUDDebug.log("keyboard backlight toggle \(current) → \(next)")
        controller?.presentHUD(SystemHUD(kind: .keyboardBacklight, level: Double(next)),
                               direction: next > current ? 1 : -1)
    }

    // MARK: C tap callback

    /// Runs on the EVENT-TAP THREAD. Decides whether to swallow the key — from the
    /// event and the thread-safe capability mirrors only, never touching the main
    /// actor — and dispatches the actual hardware work (DDC, CoreAudio, the HUD)
    /// to the main actor asynchronously, so this returns promptly and never stalls
    /// system input.
    nonisolated private func handleTap(type: CGEventType, event: CGEvent) -> Bool {
        // Plain keyDown stream: on Macs with no built-in display the brightness
        // keys never become a subtype-8 media key — instead they arrive HERE as
        // F14 (107, dimmer) / F15 (113, brighter) keyDowns with the Fn flag set.
        if type.rawValue == 10 {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let isFn = event.flags.contains(.maskSecondaryFn)
            guard isFn, keycode == 107 || keycode == 113 else { return false }
            let controllable = brightnessControllable.withLock { $0 }
            let up = keycode == 113
            // Hop to main to drive the monitor (only if we can) and refresh the
            // capability mirror so it tracks monitor hot-plugs.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if controllable { _ = self.handleExternalBrightnessKey(up: up) }
                    self.refreshCapabilityMirrors()
                }
            }
            return controllable
        }

        // Only NSSystemDefined (14) subtype-8 media-key events are of interest
        // (volume up/down/mute, plus brightness/illumination on built-in keyboards).
        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8
        else { return false }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A

        // Swallow decision straight from the cached mirrors (lock-free, no main
        // hop). Volume / mute are always ours; brightness / illumination only when
        // there's hardware we can drive.
        let swallow: Bool
        let refreshAfter: Bool
        switch keyCode {
        case soundUp, soundDown, mute:
            swallow = true;  refreshAfter = false
        case brightnessUp, brightnessDown:
            swallow = brightnessControllable.withLock { $0 };  refreshAfter = true
        case illuminationUp, illuminationDown, illuminationToggle:
            swallow = keyboardBacklightControllable.withLock { $0 };  refreshAfter = true
        default:
            return false   // not one of ours (e.g. play/pause) — pass straight through
        }

        // Do the work on the main actor. For brightness / illumination we hop even
        // when NOT swallowing, so a stale "no hardware" mirror self-corrects after
        // a hot-plug (the next press then swallows correctly).
        if swallow || refreshAfter {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if swallow { _ = self.handle(keyCode: keyCode, isDown: isDown) }
                    if refreshAfter { self.refreshCapabilityMirrors() }
                }
            }
        }
        return swallow
    }

    // MARK: CoreAudio (volume)

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    /// Reads the master volume, falling back to the average of the L/R channels
    /// for devices that expose no master element.
    private static func volume(of device: AudioDeviceID) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &addr) {
            var vol = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        var total: Float = 0, count: Float = 0
        for channel in UInt32(1)...UInt32(2) {
            addr.mElement = channel
            if AudioObjectHasProperty(device, &addr) {
                var vol = Float(0)
                var size = UInt32(MemoryLayout<Float>.size)
                if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr {
                    total += vol; count += 1
                }
            }
        }
        return count > 0 ? total / count : nil
    }

    private static func setVolume(_ value: Float, of device: AudioDeviceID) {
        var clamped = max(0, min(1, value))
        let size = UInt32(MemoryLayout<Float>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &addr),
           isSettable(device, &addr) {
            AudioObjectSetPropertyData(device, &addr, 0, nil, size, &clamped)
            return
        }
        for channel in UInt32(1)...UInt32(2) {
            addr.mElement = channel
            if AudioObjectHasProperty(device, &addr), isSettable(device, &addr) {
                AudioObjectSetPropertyData(device, &addr, 0, nil, size, &clamped)
            }
        }
    }

    private static func muted(of device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &val) == noErr && val != 0
    }

    private static func setMuted(_ muted: Bool, of device: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr), isSettable(device, &addr) else { return }
        var val: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
    }

    /// Whether macOS can set this output device's volume at all (master or per
    /// channel). False for most HDMI/DisplayPort display audio — the signal we use
    /// to route the keys to DDC instead.
    private static func volumeSettable(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &addr), isSettable(device, &addr) { return true }
        for channel in UInt32(1)...UInt32(2) {
            addr.mElement = channel
            if AudioObjectHasProperty(device, &addr), isSettable(device, &addr) { return true }
        }
        return false
    }

    private static func isSettable(_ device: AudioDeviceID,
                                  _ addr: inout AudioObjectPropertyAddress) -> Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    // MARK: DisplayServices (brightness)

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// Resolved once from the private DisplayServices framework. `nil` if it
    /// can't be loaded (then brightness keys simply do nothing visible).
    private static let displayServices: (get: GetBrightness, set: SetBrightness)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let getSym = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSym = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        return (unsafeBitCast(getSym, to: GetBrightness.self),
                unsafeBitCast(setSym, to: SetBrightness.self))
    }()

    private static func brightness(_ display: CGDirectDisplayID) -> Float? {
        guard let ds = displayServices else { return nil }
        var level: Float = 0
        return ds.get(display, &level) == 0 ? level : nil
    }

    /// Set brightness via DisplayServices; returns whether it took (0 == success).
    /// It drives the built-in panel AND Apple external displays (Studio Display, Pro
    /// Display XDR); a non-Apple external returns a failure, which the caller uses to
    /// avoid showing a HUD for a change that won't happen.
    @discardableResult
    private static func setBrightness(_ value: Float, display: CGDirectDisplayID) -> Bool {
        guard let ds = displayServices else { return false }
        return ds.set(display, max(0, min(1, value))) == 0
    }
}

/// Drives the built-in keyboard backlight through the private CoreBrightness
/// framework's `KeyboardBrightnessClient` — the same object macOS itself uses
/// for the F5/F6 keys. There's no public API for this, so we resolve the class
/// at runtime and call its two float-typed methods
/// (`brightnessForKeyboard:` / `setBrightness:forKeyboard:`) through their IMPs:
/// a plain `perform(_:with:)` can't pass or return a `float`, but a typed
/// `@convention(c)` function pointer obtained from the method's IMP can.
///
/// Everything is best-effort: if the framework or class can't be resolved (e.g.
/// an external keyboard with no controllable backlight), `isAvailable` is false
/// and the provider leaves the illumination keys to the system.
private enum KeyboardBacklight {

    // (self, _cmd, keyboardID) -> level   and   (self, _cmd, level, keyboardID) -> ok
    private typealias GetIMP = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetIMP = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    /// The built-in keyboard's id in CoreBrightness's world. 1 across all the
    /// hardware this has been seen on.
    private static let keyboardID: UInt64 = 1

    private struct Client {
        let object: AnyObject
        let get: GetIMP
        let set: SetIMP
        let getSel: Selector
        let setSel: Selector
    }

    private static let client: Client? = {
        // CoreBrightness isn't linked, so make sure it's loaded before asking the
        // runtime for its class.
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        _ = dlopen(path, RTLD_LAZY)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            return nil
        }
        let object = cls.init()
        let getSel = NSSelectorFromString("brightnessForKeyboard:")
        let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let getMethod = class_getInstanceMethod(cls, getSel),
              let setMethod = class_getInstanceMethod(cls, setSel)
        else { return nil }
        let get = unsafeBitCast(method_getImplementation(getMethod), to: GetIMP.self)
        let set = unsafeBitCast(method_getImplementation(setMethod), to: SetIMP.self)
        return Client(object: object, get: get, set: set, getSel: getSel, setSel: setSel)
    }()

    /// Whether a controllable keyboard backlight physically exists here. The
    /// class resolves even on Macs with no backlit keyboard (e.g. a Mac mini with
    /// an external keyboard); in that case the level reads back negative, so we
    /// require a valid 0…1 reading — otherwise the illumination keys are left to
    /// the system instead of being swallowed for a backlight that isn't there.
    static var isAvailable: Bool {
        guard let level = rawLevel() else { return false }
        return level >= 0
    }

    /// Current backlight level in 0…1, or `nil` if unavailable. Clamps the
    /// CoreBrightness `-1` "no backlight" sentinel up to 0.
    static func level() -> Float? {
        guard let raw = rawLevel() else { return nil }
        return max(0, raw)
    }

    private static func rawLevel() -> Float? {
        guard let c = client else { return nil }
        return c.get(c.object, c.getSel, keyboardID)
    }

    /// Set the backlight level (clamped to 0…1). No-op when unavailable.
    @discardableResult
    static func setLevel(_ value: Float) -> Bool {
        guard let c = client else { return false }
        return c.set(c.object, c.setSel, max(0, min(1, value)), keyboardID)
    }
}
