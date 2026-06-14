import AppKit
import SwiftUI

/// Integration contract for the now-playing music feature.
@MainActor
protocol MusicIslandProvider: IslandContentProvider {
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func seek(to time: TimeInterval)
    func setVolume(_ volume: Double)
    func toggleShuffle()
    func cycleRepeat()
    func toggleFavorite()
}

/// Mirrors Apple Music onto the island.
///
/// Polls Music once a second (and refreshes immediately on Music's
/// `playerInfo` distributed notification) for the current track, pushing a
/// `NowPlaying` snapshot to the controller. Transport intents are sent straight
/// to Music via `MusicBridge`, with an optimistic local update so the UI reacts
/// instantly instead of waiting for the next poll.
@MainActor
final class MusicPlayerProvider: MusicIslandProvider {
    let id = "io.github.gcrft123.lyria.music"

    private weak var controller: DynamicIslandController?
    private let bridge = MusicBridge()
    private var pollTimer: Timer?
    private var distributedObserver: NSObjectProtocol?

    /// Poll cadence. While something is PLAYING we poll fast to keep the scrubber
    /// honest; when paused/stopped/nothing we back off, since position isn't moving
    /// and Music's `playerInfo` notification gives an instant refresh on any change.
    /// This keeps an idle Mac from doing cross-process IPC to Music once a second.
    private let activeInterval: TimeInterval = 1.0
    private let idleInterval: TimeInterval = 4.0
    private var currentInterval: TimeInterval = 0

    /// Set DI_MOCK_MUSIC=1 to show a fake track (for previewing the UI without
    /// Apple Music actually playing).
    private var useMock: Bool { ProcessInfo.processInfo.environment["DI_MOCK_MUSIC"] == "1" }

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        if useMock {
            controller?.updateNowPlaying(Self.mockTrack())
            return
        }

        refresh()
        schedulePoll(idleInterval)   // upgraded to fast by refresh() once it sees playback

        // Music posts this whenever the track or play state changes.
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopObserving() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
    }

    // MARK: Polling

    private func refresh() {
        guard !useMock else { return }
        // The read runs off the main thread; the completion is delivered on main.
        bridge.snapshot { [weak self] snapshot in
            guard let self else { return }
            self.controller?.updateNowPlaying(snapshot)
            // Match the poll cadence to playback state.
            self.schedulePoll(snapshot?.isPlaying == true ? self.activeInterval : self.idleInterval)
        }
    }

    /// (Re)arm the poll timer at `interval`, but only if the cadence actually
    /// changed — so a steady state doesn't churn timers every tick.
    private func schedulePoll(_ interval: TimeInterval) {
        guard interval != currentInterval else { return }
        currentInterval = interval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func scheduleSync(after seconds: TimeInterval = 0.35) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.refresh()
        }
    }

    /// Apply an immediate local change so the UI feels responsive.
    private func optimistic(_ mutate: (inout NowPlaying) -> Void) {
        guard var nowPlaying = controller?.nowPlaying else { return }
        mutate(&nowPlaying)
        controller?.updateNowPlaying(nowPlaying)
    }

    // MARK: Transport

    func togglePlayPause() {
        guard !useMock else { optimistic { $0.isPlaying.toggle(); $0.sampledAt = Date() }; return }
        bridge.playPause()
        optimistic { nowPlaying in
            let position = nowPlaying.currentElapsed()
            nowPlaying.isPlaying.toggle()
            nowPlaying.elapsed = position
            nowPlaying.sampledAt = Date()
        }
        scheduleSync()
    }

    func nextTrack() {
        guard !useMock else { return }
        bridge.nextTrack()
        scheduleSync(after: 0.2)
    }

    func previousTrack() {
        guard !useMock else { return }
        bridge.backTrack()
        scheduleSync(after: 0.2)
    }

    func seek(to time: TimeInterval) {
        optimistic { nowPlaying in
            nowPlaying.elapsed = max(0, min(time, nowPlaying.duration))
            nowPlaying.sampledAt = Date()
        }
        guard !useMock else { return }
        bridge.seek(to: time)
        scheduleSync()
    }

    func setVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        optimistic { $0.volume = clamped }
        guard !useMock else { return }
        bridge.setVolume(clamped)
        // No scheduleSync: re-reading mid-drag would fight the user's slider.
    }

    func toggleShuffle() {
        let enabled = !(controller?.nowPlaying?.shuffle ?? false)
        optimistic { $0.shuffle = enabled }
        guard !useMock else { return }
        bridge.setShuffle(enabled)
        scheduleSync()
    }

    func cycleRepeat() {
        let current = controller?.nowPlaying?.repeatMode ?? .off
        let next: RepeatMode
        switch current {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        optimistic { $0.repeatMode = next }
        guard !useMock else { return }
        bridge.setRepeat(next)
        scheduleSync()
    }

    func toggleFavorite() {
        let next = !(controller?.nowPlaying?.isFavorited ?? false)
        optimistic { $0.isFavorited = next }
        guard !useMock else { return }
        bridge.setFavorited(next)
        scheduleSync()
    }

    // MARK: Mock

    private static func mockTrack() -> NowPlaying {
        NowPlaying(
            title: "Dreams",
            artist: "Fleetwood Mac",
            album: "Rumours",
            duration: 257,
            elapsed: 56,
            sampledAt: Date(),
            isPlaying: true,
            shuffle: false,
            repeatMode: .off,
            volume: 0.65,
            trackID: "mock",
            isFavorited: ProcessInfo.processInfo.environment["DI_MOCK_FAVORITED"] == "1",
            artwork: nil,
            accent: Palette.purple,
            queue: [
                QueueTrack(id: 1, title: "Go Your Own Way", artist: "Fleetwood Mac"),
                QueueTrack(id: 2, title: "The Chain", artist: "Fleetwood Mac"),
                QueueTrack(id: 3, title: "Landslide", artist: "Fleetwood Mac"),
                QueueTrack(id: 4, title: "Rhiannon", artist: "Fleetwood Mac"),
                QueueTrack(id: 5, title: "Don't Stop", artist: "Fleetwood Mac"),
                QueueTrack(id: 6, title: "Gypsy", artist: "Fleetwood Mac"),
            ]
        )
    }
}
