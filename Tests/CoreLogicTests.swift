import Foundation
import SwiftUI

/// Pure-logic regression tests for the most-load-bearing value types. These are
/// the bits most likely to break silently in a refactor (mode flags, time math,
/// EQ normalization, preset matching, per-app audio defaults).
@MainActor
func runCoreLogicTests() {
    testIslandMode()
    testFormatTime()
    testNowPlayingElapsed()
    testAppEQ()
    testEQPresetMatching()
    testAppVolumeSetting()
}

// MARK: IslandMode

private func testIslandMode() {
    expect(IslandMode.idle.app == nil, "idle has no app")
    expectEqual(IslandMode.compact(.music).app, .music, "compact.app")
    expectEqual(IslandMode.expanded(.music).app, .music, "expanded.app")
    expect(IslandMode.settings.app == nil, "settings has no app")

    expectEqual(IslandMode.expanded(.music).isExpanded, true, "expanded.isExpanded")
    expectEqual(IslandMode.settings.isExpanded, true, "settings.isExpanded")
    expectEqual(IslandMode.compact(.music).isExpanded, false, "compact.isExpanded")
    expectEqual(IslandMode.idle.isExpanded, false, "idle.isExpanded")
}

// MARK: formatTime

private func testFormatTime() {
    expectEqual(formatTime(0), "0:00", "zero")
    expectEqual(formatTime(65), "1:05", "1:05")
    expectEqual(formatTime(3599), "59:59", "59:59")
    expectEqual(formatTime(-5), "0:00", "negative clamps")
    expectEqual(formatTime(.infinity), "0:00", "non-finite clamps")
}

// MARK: NowPlaying.currentElapsed

private func sampleTrack(duration: TimeInterval, elapsed: TimeInterval,
                         isPlaying: Bool, sampledAt: Date) -> NowPlaying {
    NowPlaying(
        title: "t", artist: "a", album: "al",
        duration: duration, elapsed: elapsed, sampledAt: sampledAt,
        isPlaying: isPlaying, shuffle: false, repeatMode: .off, volume: 0.5,
        trackID: "id", isFavorited: false, artwork: nil, accent: .pink, queue: [])
}

private func testNowPlayingElapsed() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    // Paused: returns the stored elapsed (clamped), ignoring wall clock.
    let paused = sampleTrack(duration: 100, elapsed: 50, isPlaying: false, sampledAt: t0)
    expectEqual(paused.currentElapsed(at: t0.addingTimeInterval(30)), 50, "paused holds position")

    // Paused beyond the end clamps to duration.
    let pastEnd = sampleTrack(duration: 100, elapsed: 150, isPlaying: false, sampledAt: t0)
    expectEqual(pastEnd.currentElapsed(at: t0), 100, "paused clamps to duration")

    // Playing: interpolates by elapsed wall-clock time.
    let playing = sampleTrack(duration: 100, elapsed: 50, isPlaying: true, sampledAt: t0)
    expectEqual(playing.currentElapsed(at: t0.addingTimeInterval(10)), 60, "playing interpolates")

    // Playing past the end clamps to duration.
    let almostDone = sampleTrack(duration: 100, elapsed: 95, isPlaying: true, sampledAt: t0)
    expectEqual(almostDone.currentElapsed(at: t0.addingTimeInterval(20)), 100, "playing clamps to duration")

    // Zero duration → 0.
    let empty = sampleTrack(duration: 0, elapsed: 10, isPlaying: true, sampledAt: t0)
    expectEqual(empty.currentElapsed(at: t0.addingTimeInterval(5)), 0, "zero duration")
}

// MARK: AppEQ

private func testAppEQ() {
    let n = AppAudioEngine.bandCount

    expect(AppEQ(bands: Array(repeating: 0, count: n)).isFlat, "all-zero is flat")
    expect(!AppEQ(bands: [0, 0, 3, 0, 0]).isFlat, "a boosted band is not flat")

    // Normalization pads short / truncates long to bandCount.
    expectEqual(AppEQ(bands: [1, 2]).bands.count, n, "short pads to bandCount")
    expectEqual(AppEQ(bands: Array(repeating: 1, count: n + 3)).bands.count, n, "long truncates to bandCount")

    // effectiveDB clamps to ±15 dB.
    let clamped = AppEQ(bands: [20, -20, 0, 0, 0]).effectiveDB()
    expectEqual(clamped[0], 15, "clamps + to 15")
    expectEqual(clamped[1], -15, "clamps - to -15")
}

// MARK: EQPreset.matching

private func testEQPresetMatching() {
    expectEqual(EQPreset.matching([0, 0, 0, 0, 0])?.name, "Flat", "flat → Flat preset")
    expectEqual(EQPreset.matching([9, 6, 1, 0, 0])?.name, "Bass Boost", "curve → Bass Boost")
    expect(EQPreset.matching([1, 1, 1, 1, 1]) == nil, "off-curve → custom (nil)")
}

// MARK: AppVolumeSetting

private func testAppVolumeSetting() {
    expect(AppVolumeSetting.default.isDefault, "default is default")
    expect(AppVolumeSetting(volume: 1, muted: false).isDefault, "full unmuted flat is default")
    expect(!AppVolumeSetting(volume: 0.5, muted: false).isDefault, "lowered volume is not default")
    expect(!AppVolumeSetting(volume: 1, muted: true).isDefault, "muted is not default")

    expectEqual(AppVolumeSetting(volume: 1, muted: true).effectiveGain, 0, "muted gain is 0")
    expectEqual(AppVolumeSetting(volume: 0.5, muted: false).effectiveGain, 0.5, "gain follows volume")
    expectEqual(AppVolumeSetting(volume: 2, muted: false).effectiveGain, 1, "gain clamps to 1")
}
