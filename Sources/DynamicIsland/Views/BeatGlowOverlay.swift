import SwiftUI
import QuartzCore

/// Accent-tinted glow ripples that shed outward from the island's LEFT and
/// RIGHT edges, pulsing in time with the music — the island's take on Tesla's
/// "Light Sync".
///
/// It prefers REAL audio: an `AudioRhythmMonitor` taps the system output mix and
/// reports a live loudness envelope plus detected beat onsets, which drive a
/// continuous "breathing" glow (brightness tracks loudness) with a sharper
/// ripple shed on every beat. When the tap isn't available (older OS, capture
/// denied, nothing tappable) the monitor reports `isLive == false` and we fall
/// back to a synthetic *musical* tempo (`beatsPerMinute`) so the effect still
/// reads as "to the beat".
///
/// Each beat spawns a fresh ripple: a soft copy of the island's silhouette that
/// grows horizontally outward and fades as it travels. Because this layer sits
/// BEHIND the solid black island, the inner part of every ripple is occluded —
/// only the bands bleeding past the left/right edges show, so it reads as waves
/// shedding sideways.
///
/// Driven by an explicit `TimelineView(.periodic)` at a fixed frame rate — NOT
/// `.animation`, which stalls inside the non-activating panel (the same reason
/// `RingingGlowOverlay` uses `.periodic`). Time is read from `CACurrentMediaTime`
/// so it shares one clock with the audio thread's beat timestamps. Purely
/// decorative — never hit-tests.
struct BeatGlowOverlay: View {
    /// Matches the live island so the ripple starts flush with its silhouette.
    var cornerRadius: CGFloat
    var size: CGSize
    var accent: Color
    /// Scales the ripple opacity (shares the user's "Glow intensity" slider).
    var intensity: Double
    /// The live rhythm engine. When it isn't delivering audio we fall back to the
    /// synthetic tempo below.
    var monitor: AudioRhythmMonitor

    // MARK: Synthetic fallback

    /// Synthetic tempo. 120 BPM (two pulses a second) reads as an energetic but
    /// not frantic beat.
    private let beatsPerMinute: Double = 120
    /// A fallback ripple lives a little longer than one beat so successive waves
    /// overlap into a continuous flow instead of a strobe.
    private let fallbackLifeBeats: Double = 1.5
    /// How many overlapping fallback ripples to keep alive (⌈lifeBeats⌉ + slack).
    private let fallbackWaveCount = 3

    // MARK: Shared geometry

    /// How far a ripple travels outward at the end of its life, as a fraction of
    /// the island's half-width on each side (so the glow reaches well past the
    /// edges before it dies).
    private let travel: CGFloat = 0.55
    /// Lifetime of a real-beat ripple (seconds) — independent of any tempo since
    /// we don't know the song's BPM.
    private let beatLife: Double = 0.66

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in
            // One monotonic clock shared with the audio thread's beat stamps.
            let now = CACurrentMediaTime()
            let snap = monitor.snapshot()

            ZStack {
                if snap.isLive {
                    liveContent(now: now, snapshot: snap)
                } else {
                    fallbackContent(now: now)
                }
            }
            .frame(width: size.width, height: size.height)
            .compositingGroup()
        }
        .allowsHitTesting(false)
    }

    // MARK: Live (real audio)

    @ViewBuilder
    private func liveContent(now: Double, snapshot snap: RhythmSnapshot) -> some View {
        // Continuous loudness halo: a gentle, non-expanding outward glow whose
        // brightness and reach track the music's instantaneous loudness.
        ambientHalo(level: snap.level)

        // Beat ripples: every detected onset sheds an expanding wave, stronger
        // hits shedding brighter.
        ForEach(Array(snap.beats.enumerated()), id: \.offset) { _, beat in
            let p = (now - beat.time) / beatLife
            if p >= 0, p <= 1 {
                ripple(progress: p, strength: 0.45 + 0.55 * beat.strength)
            }
        }
    }

    /// A soft, mostly-sideways glow that simply gets brighter and reaches a touch
    /// further out the louder the music is — the steady "breathing" underneath
    /// the beat ripples.
    @ViewBuilder
    private func ambientHalo(level: Double) -> some View {
        let l = max(0, min(1, level))
        if l > 0.02 {
            let scaleX = 1 + travel * 0.5 * CGFloat(l)
            let scaleY = 1 + travel * 0.08 * CGFloat(l)
            IslandShape(cornerRadius: cornerRadius)
                .fill(accent)
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: scaleX, y: scaleY, anchor: .center)
                .blur(radius: 14)
                .opacity(intensity * 0.5 * l)
        }
    }

    // MARK: Synthetic fallback

    @ViewBuilder
    private func fallbackContent(now: Double) -> some View {
        let beat = 60.0 / beatsPerMinute
        let life = beat * fallbackLifeBeats
        // Index of the beat happening right now; ripples are anchored to
        // successive past beats so they stay phase-locked to the clock.
        let currentBeat = floor(now / beat)
        ForEach(0..<fallbackWaveCount, id: \.self) { k in
            let birth = (currentBeat - Double(k)) * beat
            let p = (now - birth) / life          // 0 (just born) … 1 (dead)
            if p >= 0, p <= 1 {
                ripple(progress: p, strength: 1)
            }
        }
    }

    // MARK: Ripple

    /// One ripple at normalised life `progress` (0…1), its opacity scaled by
    /// `strength` (a beat's intensity). Grows horizontally, softens, and fades as
    /// it ages.
    private func ripple(progress p: Double, strength: Double) -> some View {
        // Expand mostly sideways (only a hair vertically so it reads as side
        // waves, not an all-round bloom), soften with distance, fade as it
        // travels.
        let scaleX = 1 + travel * CGFloat(p)
        let scaleY = 1 + travel * 0.16 * CGFloat(p)
        let fade = pow(1 - p, 1.6)                 // bright at the edge, gone far out
        let opacity = intensity * 0.65 * fade * strength

        return IslandShape(cornerRadius: cornerRadius)
            .fill(accent)
            .frame(width: size.width, height: size.height)
            .scaleEffect(x: scaleX, y: scaleY, anchor: .center)
            .blur(radius: 7 + 18 * p)
            .opacity(opacity)
    }
}
