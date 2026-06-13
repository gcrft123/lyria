import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore
import os

/// One detected beat onset: when it fired (on the `CACurrentMediaTime` clock)
/// and how strong it was relative to the local average (0…1).
struct BeatEvent: Equatable {
    var time: CFTimeInterval
    var strength: Double
}

/// A thread-safe read of the live rhythm state, taken once per rendered frame.
struct RhythmSnapshot {
    /// True when the system-audio tap pipeline is up and we're analysing real
    /// audio (so silence reads as dark). When false — the tap couldn't be
    /// created — the overlay falls back to its synthetic clock.
    var isLive: Bool
    /// Smoothed, AGC-normalised loudness, 0 (silence) … 1 (loud). Drives the
    /// continuous "breathing" glow.
    var level: Double
    /// Recent beat onsets (increasing time), each shedding an expanding ripple.
    var beats: [BeatEvent]
}

/// Real-time rhythm analyzer — the "Tesla Light Sync" engine behind the beat
/// glow.
///
/// Apple Music exposes no tempo or onset data over ScriptingBridge, so instead
/// of guessing we listen to the *actual* system audio. Using the modern Core
/// Audio process-tap API (macOS 14.4+) we tap the global output mix into a
/// private aggregate device, then run a lightweight envelope + energy-based
/// onset detector on the audio callback thread. The view reads a thread-safe
/// `snapshot()` each frame to size and pulse the glow to the music.
///
/// Audio-only — it never touches the screen-recording permission. If the tap
/// can't be created (older OS, capture permission denied, no tappable output),
/// `start()` fails quietly and `isLive` stays false, so the overlay keeps its
/// synthetic 120 BPM fallback and the feature still does something.
///
/// NOT a `@MainActor` type: the audio IO block runs on its own queue and mutates
/// the shared outputs, guarded by an `os_unfair_lock`. `start()`/`stop()` are
/// called from the main actor.
final class AudioRhythmMonitor {

    // MARK: Shared outputs (audio thread ⇄ main thread, lock-protected)

    private let lock: os_unfair_lock_t = {
        let l = os_unfair_lock_t.allocate(capacity: 1)
        l.initialize(to: os_unfair_lock())
        return l
    }()

    private var sharedLevel: Double = 0
    /// True once the tap pipeline is up. When false the overlay uses its
    /// synthetic fallback; when true it shows the real audio (dark during
    /// silence, glowing with the music) — we never flip to synthetic just
    /// because a passage is quiet.
    private var running = false

    /// Fixed ring buffer of recent beats (avoids any allocation on the audio
    /// thread). 16 is plenty — a ripple only lives a fraction of a second.
    private var beatRing = [BeatEvent](repeating: BeatEvent(time: 0, strength: 0), count: 16)
    private var beatWrite = 0

    // MARK: Analysis state (audio thread only)

    private var fastEnv: Double = 0
    private var avgEnergy: Double = 0
    /// Slowly-decaying reference for the loudest recent passage. Floored so it
    /// never collapses to the noise floor (which would make silence glow).
    private var loudPeak: Double = 0
    private var lastBeat: CFTimeInterval = 0
    /// Two cascaded one-pole low-pass stages, carried across callbacks so the
    /// bass envelope is continuous. Used to weight the analysis toward low
    /// frequencies (see `process`).
    private var lp1: Double = 0
    private var lp2: Double = 0
    /// A higher-corner low-pass so we can split the signal into low / mid / high
    /// bands and weight each by the user's pitch-sensitivity curve.
    private var lpMid: Double = 0

    /// Sensitivity profile, set from the main thread (under `lock`) when the user
    /// edits the curves, read by the audio thread. `sensPitch` = low/mid/high band
    /// weights; `sensVolumeLUT` remaps loudness → glow.
    private var sensPitch: (low: Double, mid: Double, high: Double) = (1.0, 0.5, 0.28)
    private var sensVolumeLUT: [Double] = AudioRhythmMonitor.defaultVolumeLUT
    /// Audio-thread-only snapshot of `sensVolumeLUT` (taken once per callback).
    private var curVolumeLUT: [Double] = AudioRhythmMonitor.defaultVolumeLUT
    /// Default loudness response ≈ the previous fixed `pow(norm, 1.5)`.
    private static let defaultVolumeLUT: [Double] = (0...32).map { pow(Double($0) / 32, 1.5) }

    // MARK: Core Audio handles (main thread only)

    private var started = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.dynamicisland.rhythm.tap", qos: .userInteractive)

    /// DI_DEBUG_AUDIO=1 logs the tap pipeline's bring-up to stderr.
    private let debug = ProcessInfo.processInfo.environment["DI_DEBUG_AUDIO"] == "1"
    private func log(_ message: @autoclosure () -> String) {
        if debug { FileHandle.standardError.write(Data(("[rhythm] " + message() + "\n").utf8)) }
    }

    deinit {
        stop()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: Lifecycle

    /// Bring up the tap → aggregate device → IO proc pipeline. Idempotent; a
    /// failure at any step tears the partial pipeline back down and leaves the
    /// monitor "not live" so the caller falls back to the synthetic clock.
    func start() {
        guard !started else { return }
        guard #available(macOS 14.4, *) else { log("macOS < 14.4 — synthetic fallback"); return }
        log("starting…")

        // 1. Tap the global output mix (exclude nothing → whole system), without
        //    muting what the user hears.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.name = "DynamicIslandRhythmTap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTap)
        guard tapStatus == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            log("AudioHardwareCreateProcessTap failed: \(tapStatus) — synthetic fallback")
            return
        }
        tapID = newTap
        log("tap created (id \(newTap))")

        // 2. Read the tap's UID so we can fold it into an aggregate device.
        //    `AudioObjectGetPropertyData` writes a +1-retained CFStringRef, so
        //    read it through `Unmanaged` and balance the retain ourselves.
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidValue: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uidValue) {
            AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, $0)
        }
        guard uidStatus == noErr, let tapUID = uidValue?.takeRetainedValue() else {
            stop()
            return
        }

        // 3. Wrap the tap in a private, auto-starting aggregate device — that's
        //    the object we can install an IO proc on.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamicIslandRhythmTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregate)
        guard aggStatus == noErr, newAggregate != AudioObjectID(kAudioObjectUnknown) else {
            log("AudioHardwareCreateAggregateDevice failed: \(aggStatus) — synthetic fallback")
            stop()
            return
        }
        aggregateID = newAggregate
        log("aggregate device created (id \(newAggregate))")

        // 4. Install the analysis callback and start the device.
        var newProc: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, queue) {
            [self] _, inInputData, _, _, _ in
            process(inInputData)
        }
        guard createStatus == noErr, let newProc else {
            log("AudioDeviceCreateIOProcIDWithBlock failed: \(createStatus) — synthetic fallback")
            stop()
            return
        }
        procID = newProc

        let startStatus = AudioDeviceStart(aggregateID, newProc)
        guard startStatus == noErr else {
            log("AudioDeviceStart failed: \(startStatus) — synthetic fallback")
            stop()
            return
        }

        started = true
        log("LIVE — tapping system audio")
        os_unfair_lock_lock(lock)
        running = true
        os_unfair_lock_unlock(lock)
    }

    /// Tear the whole pipeline down. Safe to call when never started.
    func stop() {
        os_unfair_lock_lock(lock)
        running = false
        os_unfair_lock_unlock(lock)

        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if #available(macOS 14.4, *), tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)

        started = false
    }

    // MARK: Read (main thread, once per frame)

    func snapshot() -> RhythmSnapshot {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(lock)
        let live = running
        let level = sharedLevel
        var beats: [BeatEvent] = []
        beats.reserveCapacity(beatRing.count)
        for b in beatRing where b.time > 0 && now - b.time < 1.5 {
            beats.append(b)
        }
        os_unfair_lock_unlock(lock)

        beats.sort { $0.time < $1.time }
        return RhythmSnapshot(isLive: live, level: live ? level : 0, beats: beats)
    }

    // MARK: Audio thread

    /// Update the wave-sensitivity curves (from the main thread when settings
    /// change). Precomputes the 3 band weights + a loudness LUT for the audio thread.
    func setSensitivity(pitch: [Double], volume: [Double]) {
        let p = (low: Self.sampleCurve(pitch, 0.12),
                 mid: Self.sampleCurve(pitch, 0.5),
                 high: Self.sampleCurve(pitch, 0.88))
        let lut = (0...32).map { Self.sampleCurve(volume, Double($0) / 32) }
        os_unfair_lock_lock(lock)
        sensPitch = p
        sensVolumeLUT = lut
        os_unfair_lock_unlock(lock)
    }

    /// Linear-interpolated sample of a 0…1 curve at position `x` (0…1).
    private static func sampleCurve(_ curve: [Double], _ x: Double) -> Double {
        guard curve.count > 1 else { return curve.first ?? 0 }
        let n = Double(curve.count - 1)
        let pos = max(0, min(n, x * n))
        let i = Int(pos), f = pos - Double(i)
        return curve[i] + (curve[min(curve.count - 1, i + 1)] - curve[i]) * f
    }

    /// Split one callback's worth of samples into low / mid / high bands, weight
    /// each by the user's pitch-sensitivity curve, and hand the combined RMS to the
    /// analyzer. The tap delivers 32-bit float (possibly per-channel); the band
    /// filters run on the first channel only so their state stays coherent.
    private func process(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        os_unfair_lock_lock(lock)
        let pitch = sensPitch
        curVolumeLUT = sensVolumeLUT
        os_unfair_lock_unlock(lock)

        let lpAlpha = 0.04   // ~300 Hz corner, cascaded for the low (bass) band
        let midAlpha = 0.16  // ~1.2 kHz corner for the low+mid boundary
        var lowSq = 0.0, midSq = 0.0, highSq = 0.0
        var firstCount = 0
        for (index, buffer) in abl.enumerated() where index == 0 {
            guard let mData = buffer.mData else { continue }
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0 else { continue }
            let samples = mData.assumingMemoryBound(to: Float.self)
            var i = 0
            while i < frameCount {
                let s = Double(samples[i])
                lp1 += (s - lp1) * lpAlpha
                lp2 += (lp1 - lp2) * lpAlpha
                lpMid += (s - lpMid) * midAlpha
                let low = lp2, mid = lpMid - lp2, high = s - lpMid
                lowSq += low * low
                midSq += mid * mid
                highSq += high * high
                i += 1
            }
            firstCount = frameCount
        }
        guard firstCount > 0 else { return }
        let n = Double(firstCount)
        let rms = pitch.low * (lowSq / n).squareRoot()
                + pitch.mid * (midSq / n).squareRoot()
                + pitch.high * (highSq / n).squareRoot()
        analyze(rms: rms)
    }

    /// Linear-interpolated lookup in a loudness→glow LUT.
    private func lutLookup(_ lut: [Double], _ x: Double) -> Double {
        guard lut.count > 1 else { return lut.first ?? x }
        let n = Double(lut.count - 1)
        let pos = max(0, min(n, x * n))
        let i = Int(pos), f = pos - Double(i)
        return lut[i] + (lut[min(lut.count - 1, i + 1)] - lut[i]) * f
    }

    /// Energy-envelope follower + AGC + energy-based onset detector. Runs on the
    /// tap's serial queue, so the analysis-only fields need no locking; only the
    /// published outputs are written under the lock at the end.
    private func analyze(rms: Double) {
        let t = CACurrentMediaTime()

        // Loudness envelope: snappy attack, gentle release, so the glow leaps up
        // on hits but eases back down instead of flickering.
        let attack = 0.45
        let release = 0.08
        if rms > fastEnv {
            fastEnv += (rms - fastEnv) * attack
        } else {
            fastEnv += (rms - fastEnv) * release
        }

        // Loudness → level, faithful to absolute loudness so SILENCE stays dark.
        // A slowly-decaying reference (floored at `minReference`) gives gentle
        // automatic gain — quiet tracks still glow, loud ones don't pin — without
        // amplifying the noise floor the way a pure AGC would.
        let floor = 0.005          // below this reads as silence
        let minReference = 0.05    // AGC reference can't drop below this
        loudPeak = max(loudPeak * 0.999, fastEnv, minReference)
        let norm = max(0, min(1, (fastEnv - floor) / (loudPeak - floor)))
        // Map loudness → glow through the user's VOLUME sensitivity curve. The
        // default LUT is `pow(norm, 1.5)`, so out of the box quiet passages glow
        // much less and loud ones much more, as before.
        let level = lutLookup(curVolumeLUT, norm)

        // Onset detection: the instantaneous energy spiking well above its local
        // running average reads as a beat. Gated by an absolute floor AND by a
        // fraction of the loud reference, so quiet-room noise never "beats". A
        // refractory window stops one hit registering as a flurry.
        if avgEnergy == 0 { avgEnergy = rms }
        avgEnergy += (rms - avgEnergy) * 0.02   // ~0.5s running average
        let ratio = avgEnergy > 1e-7 ? rms / avgEnergy : 0
        var beatStrength = 0.0
        if rms > floor, rms > loudPeak * 0.18, ratio > 1.4, t - lastBeat > 0.18 {
            lastBeat = t
            // Scale by loudness so a quiet onset registers as a faint beat and a
            // loud one slams — reinforcing the "louder = stronger" sensitivity.
            let loudnessFactor = 0.4 + 0.6 * level
            beatStrength = max(0.2, min(1.0, (ratio - 1.4) / 1.2)) * loudnessFactor
        }

        os_unfair_lock_lock(lock)
        sharedLevel = level
        if beatStrength > 0 {
            beatRing[beatWrite % beatRing.count] = BeatEvent(time: t, strength: beatStrength)
            beatWrite += 1
        }
        os_unfair_lock_unlock(lock)

        if debug {
            if beatStrength > 0 { log(String(format: "beat  strength %.2f  level %.2f", beatStrength, level)) }
            dbgTick += 1
            if dbgTick % 45 == 0 { log(String(format: "level %.2f  rms %.4f", level, rms)) }
        }
    }
    private var dbgTick = 0
}
