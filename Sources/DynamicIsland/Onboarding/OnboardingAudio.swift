import AVFoundation

/// Synthesized audio for onboarding — no asset files, no licensing. A soft
/// ambient pad loops under the whole sequence; bell-like chimes mark act changes
/// and the moment a permission lights up. All best-effort: if the engine can't
/// start, everything silently no-ops. Disable with `DI_DISABLE_ONBOARDING_AUDIO=1`.
@MainActor
final class OnboardingAudio {
    private let engine = AVAudioEngine()
    private let chimeNode = AVAudioPlayerNode()
    private let padNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var running = false
    private let enabled = ProcessInfo.processInfo.environment["DI_DISABLE_ONBOARDING_AUDIO"] != "1"

    /// A gentle pentatonic so any chime sits in tune with the pad (A minor pentatonic).
    private let scale: [Double] = [220.0, 261.63, 293.66, 329.63, 392.0, 440.0, 523.25]

    func start() {
        guard enabled, !running else { return }
        engine.attach(chimeNode)
        engine.attach(padNode)
        engine.connect(chimeNode, to: engine.mainMixerNode, format: format)
        engine.connect(padNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9
        do { try engine.start() } catch { return }
        running = true
        startPad()
    }

    func stop() {
        guard running else { return }
        chimeNode.stop(); padNode.stop()
        engine.stop()
        running = false
    }

    // MARK: Cues

    /// A short bell. `step` shifts up the scale (higher = more triumphant).
    func chime(step: Int = 0, gain: Float = 0.18) {
        guard running else { return }
        let root = scale[min(scale.count - 1, max(0, step))]
        let buffer = bell(frequencies: [root, root * 2, root * 3], decay: 1.1, gain: gain)
        chimeNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !chimeNode.isPlaying { chimeNode.play() }
    }

    /// A bright three-note arpeggio for a permission lighting up or the finale.
    func sparkle(gain: Float = 0.16) {
        guard running else { return }
        let notes = [scale[2], scale[4], scale[6]]
        for (i, hz) in notes.enumerated() {
            let when = AVAudioTime(sampleTime: AVAudioFramePosition(Double(i) * 0.09 * format.sampleRate),
                                   atRate: format.sampleRate)
            let buffer = bell(frequencies: [hz, hz * 2, hz * 3], decay: 1.3, gain: gain)
            chimeNode.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
        }
        if !chimeNode.isPlaying { chimeNode.play() }
    }

    // MARK: Synthesis

    private func startPad() {
        let buffer = pad(seconds: 8, roots: [110.0, 164.81]) // A2 + E3 drone
        padNode.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
        padNode.play()
    }

    /// A decaying additive bell tone.
    private func bell(frequencies: [Double], decay: Double, gain: Float) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(decay * sr)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let chans = Int(format.channelCount)
        for n in 0..<Int(frames) {
            let t = Double(n) / sr
            let env = exp(-t * 3.6)                       // exponential decay
            var s = 0.0
            for (i, f) in frequencies.enumerated() {
                s += sin(2 * .pi * f * t) / Double(i + 1) // softer upper partials
            }
            let v = Float(s / Double(frequencies.count) * env) * gain
            for c in 0..<chans { buffer.floatChannelData![c][n] = v }
        }
        return buffer
    }

    /// A slowly breathing two-voice sine pad with gentle detune + tremolo.
    private func pad(seconds: Double, roots: [Double]) -> AVAudioPCMBuffer {
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(seconds * sr)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let chans = Int(format.channelCount)
        for n in 0..<Int(frames) {
            let t = Double(n) / sr
            let tremolo = 0.6 + 0.4 * sin(2 * .pi * 0.07 * t) // slow swell
            var s = 0.0
            for f in roots {
                s += sin(2 * .pi * f * t)
                s += sin(2 * .pi * (f * 1.003) * t) * 0.5    // detuned shimmer
            }
            let v = Float(s / 3.0 * tremolo) * 0.05          // quiet bed
            for c in 0..<chans { buffer.floatChannelData![c][n] = v }
        }
        return buffer
    }
}
