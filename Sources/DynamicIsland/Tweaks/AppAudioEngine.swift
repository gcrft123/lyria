import AudioToolbox
import CoreAudio
import Foundation
import os

/// Per-application audio processing — volume, **5-band EQ**, and **stereo pan** —
/// via the macOS 14.4+ Core Audio process-tap API (the same family the beat-glow
/// `AudioRhythmMonitor` uses).
///
/// macOS has no public per-app volume/EQ control, so we synthesise one: for every
/// app the user has touched (non-default volume, mute, EQ, or pan) we create a
/// process tap with `muteBehavior = .muted` — that REMOVES the app's audio from the
/// normal output — then fold all those taps into ONE private aggregate device that
/// ALSO contains the current default output device. A single IO proc reads each
/// tap's captured stereo audio, runs it through that app's biquad EQ cascade,
/// applies its volume and L/R pan gains, and sums the result back into the output.
/// Apps the user hasn't touched are never tapped (they play normally), so the
/// engine is fully dormant until a tweak is set. The system/master volume is the
/// output device's own volume, so it still scales everything.
///
/// Live params (gain/pan/coeffs) live in lock-protected `AppDSP` objects so dragging
/// a slider just recomputes a few numbers (no expensive pipeline rebuild); the
/// pipeline is only rebuilt when the SET of controlled apps changes. The biquad
/// filter *state* is touched only by the IO proc (rebuild stops the device first,
/// so there's never concurrent access). Best-effort: any failure tears down and the
/// apps simply play normally.
///
/// NOT `@MainActor`: the IO proc runs on its own queue. `apply` is called from main.
final class AppAudioEngine {

    /// The fixed 5-band graphic-EQ center frequencies (sub-bass → treble).
    static let bandFreqs: [Float] = [60, 230, 910, 3600, 14000]
    static let bandQ: Float = 1.0
    static var bandCount: Int { bandFreqs.count }

    /// One app's desired processing. `eqBandsDB` is the *effective* per-band gain in
    /// dB (boosts already folded in by the store); `pan` is -1 (left) … +1 (right).
    struct Controlled: Equatable {
        let pid: pid_t
        let gain: Float           // volume, 0 when muted
        let pan: Float            // -1…+1
        let eqBandsDB: [Float]    // count == bandCount
    }

    /// Normalised biquad coefficients (a0 == 1). Identity by default (passthrough).
    struct BiquadCoeffs: Equatable {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    }

    /// Per-app DSP: live params (lock-guarded) + per-channel cascade state (IO only).
    final class AppDSP {
        // Live params — written under the engine lock, snapshotted by the IO proc.
        var gain: Float = 1
        var panL: Float = 1
        var panR: Float = 1
        var coeffs: [BiquadCoeffs] = Array(repeating: BiquadCoeffs(), count: AppAudioEngine.bandCount)
        // Direct-Form-II-Transposed state (2 per band per channel) — IO thread only.
        var z1L = [Float](repeating: 0, count: AppAudioEngine.bandCount)
        var z2L = [Float](repeating: 0, count: AppAudioEngine.bandCount)
        var z1R = [Float](repeating: 0, count: AppAudioEngine.bandCount)
        var z2R = [Float](repeating: 0, count: AppAudioEngine.bandCount)

        /// Run a tap's stereo input through the EQ cascade, then volume × pan, and
        /// ADD into the (already-cleared) output. Strided so it works for interleaved
        /// (stride = channel count) and non-interleaved (stride = 1) buffers alike.
        /// Mutates only this object's state.
        func process(frames: Int,
                     sL: UnsafePointer<Float>, inStrideL: Int,
                     sR: UnsafePointer<Float>, inStrideR: Int,
                     dL: UnsafeMutablePointer<Float>, outStrideL: Int,
                     dR: UnsafeMutablePointer<Float>, outStrideR: Int,
                     coeffs: [BiquadCoeffs], gain: Float, panL: Float, panR: Float) {
            let n = coeffs.count
            let gL = gain * panL, gR = gain * panR
            var i = 0
            while i < frames {
                var xL = sL[i * inStrideL], xR = sR[i * inStrideR]
                var k = 0
                while k < n {
                    let c = coeffs[k]
                    let yL = c.b0 * xL + z1L[k]
                    z1L[k] = c.b1 * xL - c.a1 * yL + z2L[k]
                    z2L[k] = c.b2 * xL - c.a2 * yL
                    xL = yL
                    let yR = c.b0 * xR + z1R[k]
                    z1R[k] = c.b1 * xR - c.a1 * yR + z2R[k]
                    z2R[k] = c.b2 * xR - c.a2 * yR
                    xR = yR
                    k += 1
                }
                dL[i * outStrideL] += xL * gL
                dR[i * outStrideR] += xR * gR
                i += 1
            }
        }
    }

    private let lock: os_unfair_lock_t = {
        let l = os_unfair_lock_t.allocate(capacity: 1); l.initialize(to: os_unfair_lock()); return l
    }()
    /// pid → live DSP, read by the IO proc (lock-guarded for the param fields).
    private var dsp: [pid_t: AppDSP] = [:]
    /// The most recent desired params per pid (used to seed `AppDSP` on rebuild).
    private var desiredByPID: [pid_t: Controlled] = [:]
    /// Tap order (input pair i ↔ tapPIDs[i]), read by the IO proc.
    private var tapPIDs: [pid_t] = []
    /// The aggregate's sample rate (for biquad coefficients).
    private var sampleRate: Double = 48000
    /// Debug: log the actual IO buffer layout on the first mix callback.
    private var didLogLayout = false
    private var ioCallbacks = 0

    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var currentSet: [pid_t] = []
    private let queue = DispatchQueue(label: "io.github.gcrft123.lyriaaudio.tap", qos: .userInitiated)

    private let debug = ProcessInfo.processInfo.environment["DI_DEBUG_AUDIO"] == "1"
    private func log(_ m: @autoclosure () -> String) {
        if debug { FileHandle.standardError.write(Data(("[appaudio] " + m() + "\n").utf8)) }
    }

    deinit { teardown(); lock.deinitialize(count: 1); lock.deallocate() }

    /// Set the full list of controlled apps. Updates live params (gain/pan/EQ) in
    /// place; rebuilds the tap pipeline only if the set of pids changed.
    func apply(_ controlled: [Controlled]) {
        os_unfair_lock_lock(lock)
        desiredByPID = Dictionary(uniqueKeysWithValues: controlled.map { ($0.pid, $0) })
        for c in controlled { if let d = dsp[c.pid] { configure(d, with: c, fs: sampleRate) } }
        os_unfair_lock_unlock(lock)

        let pids = controlled.map(\.pid).sorted()
        guard pids != currentSet else { return }   // same apps → params already updated
        currentSet = pids
        rebuild(pids: pids)
    }

    // MARK: Coefficients

    /// Apply a `Controlled`'s params to an `AppDSP`. Caller holds the lock.
    private func configure(_ d: AppDSP, with c: Controlled, fs: Double) {
        d.gain = c.gain
        let p = max(-1, min(1, c.pan))
        d.panL = 1 - 0.5 * p     // pan left (-1) boosts L to 1.5, cuts R to 0.5
        d.panR = 1 + 0.5 * p
        var cs = [BiquadCoeffs](repeating: BiquadCoeffs(), count: Self.bandCount)
        for i in 0..<Self.bandCount {
            let db = i < c.eqBandsDB.count ? c.eqBandsDB[i] : 0
            cs[i] = Self.peaking(freq: Self.bandFreqs[i], dbGain: db, q: Self.bandQ, fs: Float(fs))
        }
        d.coeffs = cs
    }

    /// RBJ "cookbook" peaking-EQ biquad, normalised so a0 == 1. Flat → identity.
    private static func peaking(freq: Float, dbGain: Float, q: Float, fs: Float) -> BiquadCoeffs {
        guard abs(dbGain) > 0.01, fs > 0 else { return BiquadCoeffs() }
        let A = powf(10, dbGain / 40)
        let w0 = 2 * .pi * freq / fs
        let cw = cosf(w0), sw = sinf(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha / A
        return BiquadCoeffs(
            b0: (1 + alpha * A) / a0,
            b1: (-2 * cw) / a0,
            b2: (1 - alpha * A) / a0,
            a1: (-2 * cw) / a0,
            a2: (1 - alpha / A) / a0)
    }

    // MARK: Pipeline

    private func rebuild(pids: [pid_t]) {
        teardown()
        guard !pids.isEmpty else { log("no controlled apps — pipeline down"); return }
        guard #available(macOS 14.4, *) else { log("macOS < 14.4 — per-app audio unavailable"); return }

        // 1. One muted tap per controlled process.
        var taps: [AudioObjectID] = []
        var orderedPIDs: [pid_t] = []
        var tapUIDs: [CFString] = []
        for pid in pids {
            guard let processObject = Self.processObject(for: pid) else { continue }
            let desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
            desc.name = "DI-AppAudio-\(pid)"
            desc.isPrivate = true
            desc.muteBehavior = .muted   // remove the app's audio from the normal output
            var tap = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateProcessTap(desc, &tap) == noErr,
                  tap != AudioObjectID(kAudioObjectUnknown),
                  let uid = Self.tapUID(tap)
            else { continue }
            taps.append(tap); orderedPIDs.append(pid); tapUIDs.append(uid)
        }
        guard !taps.isEmpty, let outputUID = Self.defaultOutputDeviceUID() else { taps.forEach { AudioHardwareDestroyProcessTap($0) }; return }

        // 2. Aggregate = default output device + all the taps.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DI App Audio Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: tapUIDs.map {
                [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true]
            },
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate) == noErr,
              aggregate != AudioObjectID(kAudioObjectUnknown)
        else { taps.forEach { AudioHardwareDestroyProcessTap($0) }; log("aggregate failed"); return }

        // 3. Read the aggregate's sample rate and seed per-app DSP state.
        let fs = Self.nominalSampleRate(aggregate) ?? 48000
        if debug {
            log("aggregate fs=\(Int(fs)) taps=\(orderedPIDs.count) " +
                "in=\(Self.describeStreamConfig(aggregate, scope: kAudioObjectPropertyScopeInput)) " +
                "out=\(Self.describeStreamConfig(aggregate, scope: kAudioObjectPropertyScopeOutput))")
            didLogLayout = false
        }
        os_unfair_lock_lock(lock)
        sampleRate = fs
        tapPIDs = orderedPIDs
        var newDSP: [pid_t: AppDSP] = [:]
        for pid in orderedPIDs {
            let d = AppDSP()
            if let c = desiredByPID[pid] { configure(d, with: c, fs: fs) }
            newDSP[pid] = d
        }
        dsp = newDSP
        os_unfair_lock_unlock(lock)
        tapIDs = taps
        aggregateID = aggregate

        // 4. IO proc: EQ + volume + pan each tap into the output.
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) {
            [self] _, inInputData, _, outOutputData, _ in
            mix(input: inInputData, output: outOutputData)
        }
        guard status == noErr, let proc else { teardown(); log("io proc failed"); return }
        procID = proc
        if AudioDeviceStart(aggregate, proc) != noErr { teardown(); log("device start failed"); return }
        log("LIVE — \(orderedPIDs.count) app(s) tapped @ \(Int(fs))Hz")
    }

    /// EQ + volume + pan each tapped app into the output. Assumes the aggregate
    /// presents each tap as a consecutive stereo pair of input buffers in tap-list
    /// order (non-interleaved float), matching `tapPIDs`.
    private func mix(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard outputs.count > 0 else { return }

        // Snapshot order + params under the lock; keep DSP refs (state is IO-only).
        os_unfair_lock_lock(lock)
        let order = tapPIDs
        let refs: [AppDSP?] = order.map { dsp[$0] }
        let params: [(g: Float, pL: Float, pR: Float, c: [BiquadCoeffs])?] = order.map {
            guard let d = dsp[$0] else { return nil }
            return (d.gain, d.panL, d.panR, d.coeffs)
        }
        os_unfair_lock_unlock(lock)

        if debug && !didLogLayout {
            didLogLayout = true
            var s = "mix#1 inputs=\(inputs.count) "
            for i in 0..<inputs.count { let b = inputs[i]; s += "in[\(i)](ch=\(b.mNumberChannels),by=\(b.mDataByteSize)) " }
            s += "| outputs=\(outputs.count) "
            for i in 0..<outputs.count { let b = outputs[i]; s += "out[\(i)](ch=\(b.mNumberChannels),by=\(b.mDataByteSize)) " }
            s += "| taps=\(order.count)"
            log(s)
        }

        // Flatten input & output into per-channel accessors (base ptr + stride),
        // which handles interleaved (stride = channel count) AND non-interleaved
        // (stride = 1) buffer layouts. Channel order is tap order: tap t = channels
        // 2t (L) and 2t+1 (R).
        var inChans: [(base: UnsafePointer<Float>, stride: Int, frames: Int)] = []
        for bi in 0..<inputs.count {
            let b = inputs[bi]
            guard let d = b.mData else { continue }
            let nch = max(1, Int(b.mNumberChannels))
            let frames = Int(b.mDataByteSize) / MemoryLayout<Float>.size / nch
            let p = UnsafePointer(d.assumingMemoryBound(to: Float.self))
            for j in 0..<nch { inChans.append((p + j, nch, frames)) }
        }

        // Clear the output, then build its per-channel accessors.
        var outChans: [(base: UnsafeMutablePointer<Float>, stride: Int, frames: Int)] = []
        for bi in 0..<outputs.count {
            let b = outputs[bi]
            guard let d = b.mData else { continue }
            memset(d, 0, Int(b.mDataByteSize))
            let nch = max(1, Int(b.mNumberChannels))
            let frames = Int(b.mDataByteSize) / MemoryLayout<Float>.size / nch
            let p = d.assumingMemoryBound(to: Float.self)
            for j in 0..<nch { outChans.append((p + j, nch, frames)) }
        }
        guard let outL = outChans.first else { return }
        let outR = outChans.count > 1 ? outChans[1] : outL   // mono output → fold

        for t in 0..<order.count {
            guard let d = refs[t], let p = params[t] else { continue }
            let li = t * 2, ri = t * 2 + 1
            guard ri < inChans.count else { continue }
            let inL = inChans[li], inR = inChans[ri]
            let frames = min(inL.frames, inR.frames, outL.frames, outR.frames)
            d.process(frames: frames,
                      sL: inL.base, inStrideL: inL.stride,
                      sR: inR.base, inStrideR: inR.stride,
                      dL: outL.base, outStrideL: outL.stride,
                      dR: outR.base, outStrideR: outR.stride,
                      coeffs: p.c, gain: p.g, panL: p.pL, panR: p.pR)
        }

        // Guard against EQ/pan boost clipping (clamp each output buffer once).
        for bi in 0..<outputs.count {
            let b = outputs[bi]
            guard let d = b.mData else { continue }
            Self.clamp(d.assumingMemoryBound(to: Float.self), Int(b.mDataByteSize) / MemoryLayout<Float>.size)
        }

        if debug {
            ioCallbacks += 1
            if ioCallbacks <= 250, ioCallbacks % 50 == 0 {
                func pk(_ base: UnsafePointer<Float>, _ stride: Int, _ frames: Int) -> Float {
                    var p: Float = 0, i = 0; while i < frames { p = max(p, abs(base[i * stride])); i += 1 }; return p
                }
                let inL = inChans.count > 0 ? pk(inChans[0].base, inChans[0].stride, inChans[0].frames) : -1
                let inR = inChans.count > 1 ? pk(inChans[1].base, inChans[1].stride, inChans[1].frames) : -1
                let oL = pk(UnsafePointer(outL.base), outL.stride, outL.frames)
                let oR = pk(UnsafePointer(outR.base), outR.stride, outR.frames)
                log(String(format: "peak inL=%.4f inR=%.4f outL=%.4f outR=%.4f cb=%d", inL, inR, oL, oR, ioCallbacks))
            }
        }
    }

    private static func clamp(_ p: UnsafeMutablePointer<Float>, _ frames: Int) {
        var i = 0
        while i < frames {
            let v = p[i]
            if v > 1 { p[i] = 1 } else if v < -1 { p[i] = -1 }
            i += 1
        }
    }

    private func teardown() {
        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if #available(macOS 14.4, *) { tapIDs.forEach { AudioHardwareDestroyProcessTap($0) } }
        tapIDs = []
        os_unfair_lock_lock(lock); tapPIDs = []; dsp = [:]; os_unfair_lock_unlock(lock)
    }

    // MARK: Core Audio helpers

    /// Debug: describe a device's stream configuration (buffers × channels) for a scope.
    private static func describeStreamConfig(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return "n/a" }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return "err" }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var s = "buffers=\(list.count)["
        for b in list { s += "(ch=\(b.mNumberChannels),by=\(b.mDataByteSize))" }
        return s + "]"
    }

    private static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sr = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &sr) == noErr, sr > 0 else { return nil }
        return sr
    }

    /// The PIDs of processes currently producing OUTPUT audio (macOS 14.2+).
    static func soundProducingPIDs() -> Set<pid_t> {
        guard #available(macOS 14.2, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &objects) == noErr else { return [] }

        var result = Set<pid_t>()
        for object in objects {
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &runAddr, 0, nil, &rSize, &running) == noErr, running != 0
            else { continue }
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = -1
            var pSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &pSize, &pid) == noErr, pid >= 0 {
                result.insert(pid)
            }
        }
        return result
    }

    @available(macOS 14.2, *)
    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var inPID = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            system, &addr, UInt32(MemoryLayout<pid_t>.size), &inPID, &size, &object)
        return status == noErr && object != AudioObjectID(kAudioObjectUnknown) ? object : nil
    }

    private static func tapUID(_ tap: AudioObjectID) -> CFString? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue()
    }

    private static func defaultOutputDeviceUID() -> CFString? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var dSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &devAddr, 0, nil, &dSize, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue()
    }
}
