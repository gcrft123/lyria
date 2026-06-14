import AppKit
import SwiftUI
import ScriptingBridge

/// Thin wrapper over Apple Music via ScriptingBridge.
///
/// Reads now-playing state and forwards transport commands. All access goes
/// through `MusicApplication` (declared in the bridging header). Artwork is the
/// expensive call, so it is fetched only when the track actually changes.
///
/// ScriptingBridge property reads are *synchronous Apple Events* (cross-process
/// IPC to Music.app) — a full `snapshot()` is a dozen of them, and on a 1 Hz poll
/// that stalls the main thread ~once a second. So EVERY Music access (reads and
/// transport writes alike) is confined to one serial background `queue`; reads
/// deliver their result back on the main queue. The single `SBApplication` and
/// all caches are touched only on `queue`, so there's no cross-thread sharing —
/// which is why this is safe to mark `@unchecked Sendable`.
final class MusicBridge: @unchecked Sendable {

    /// Serial queue that owns the SBApplication + caches; keeps the synchronous
    /// Apple Events off the main thread.
    private let queue = DispatchQueue(label: "io.github.gcrft123.lyria.music.io")

    private var cachedApp: SBApplication?

    // Artwork cache keyed by track id.
    private var artworkTrackID: String?
    private var cachedArtwork: NSImage?
    private var cachedAccent: Color = Palette.pink

    // Queue (upcoming-tracks) cache, recomputed only when the track changes since
    // walking the current playlist is several SB round-trips.
    private var queueTrackID: String?
    private var cachedQueue: [QueueTrack] = []
    private let debugQueue = ProcessInfo.processInfo.environment["DI_DEBUG_QUEUE"] == "1"

    /// Lazily resolve the Music application. It conforms to `MusicApplication`
    /// (declared in the bridging header), so every Music member is available
    /// directly. Accessing `isRunning` never launches Music; we gate every
    /// other call on it so we don't auto-launch.
    private var app: SBApplication? {
        if let cachedApp { return cachedApp }
        let resolved = SBApplication(bundleIdentifier: "com.apple.Music")
        cachedApp = resolved
        return resolved
    }

    // MARK: Reads

    /// Read a fresh snapshot off the main thread, delivering the result on the
    /// MAIN queue (so the caller can update UI directly). `nil` when nothing is
    /// playing/paused. The read itself — a dozen synchronous Apple Events — runs
    /// on the serial `queue`, so it never blocks the UI.
    func snapshot(_ completion: @escaping (NowPlaying?) -> Void) {
        queue.async {
            let snap = self.readSnapshot()
            DispatchQueue.main.async { completion(snap) }
        }
    }

    /// The actual (blocking) read. MUST be called on `queue`.
    private func readSnapshot() -> NowPlaying? {
        guard let app, app.isRunning else { return nil }

        let state = app.playerState
        guard state == .playing || state == .paused else { return nil }
        guard let track = app.currentTrack else { return nil }

        let trackID = String(track.databaseID)
        let title = track.name ?? ""
        // A blank title with id 0 usually means "no real track" — skip it.
        guard !(title.isEmpty && track.databaseID == 0) else { return nil }

        if trackID != artworkTrackID {
            artworkTrackID = trackID
            if let image = Self.fetchArtwork(track) {
                cachedArtwork = image
                cachedAccent = ArtworkColor.accent(from: image)
            } else {
                // No local artwork. This is normal for an Apple Music streaming /
                // catalog track that isn't in the user's library — Music only
                // exposes `artworks()` for library items. Clear the stale image and
                // fall back to Apple's public iTunes lookup (artist + title). The
                // result lands asynchronously and the next poll picks it up; the
                // accent is kept until then to avoid a flash to neutral.
                cachedArtwork = nil
                fetchRemoteArtwork(artist: track.artist ?? "", title: title, for: trackID)
            }
        }

        // Recompute the upcoming-tracks queue only when the track changes.
        if trackID != queueTrackID {
            queueTrackID = trackID
            cachedQueue = Self.computeQueue(app: app, current: track)
            if debugQueue {
                FileHandle.standardError.write(Data(
                    "DI_QUEUE playlist=\(app.currentPlaylist?.name ?? "nil") currentIndex=\(track.index) upcoming=\(cachedQueue.count): \(cachedQueue.prefix(6).map { $0.title })\n".utf8))
            }
        }

        return NowPlaying(
            title: title,
            artist: track.artist ?? "",
            album: track.album ?? "",
            duration: track.duration,
            elapsed: app.playerPosition,
            sampledAt: Date(),
            isPlaying: state == .playing,
            shuffle: app.shuffleEnabled,
            repeatMode: Self.map(app.songRepeat),
            volume: Double(app.soundVolume) / 100.0,
            trackID: trackID,
            isFavorited: track.favorited,
            artwork: cachedArtwork,
            accent: cachedAccent,
            queue: cachedQueue
        )
    }

    /// Best-effort "Up Next": the tracks AFTER the current one in the current
    /// playlist. Apple Music exposes no real queue, so this is the closest proxy
    /// (and is empty / partial for radio, autoplay, or a single song; with shuffle
    /// on it reflects playlist order, not shuffle order). Element names/artists are
    /// read via KVC — the runtime protocol cast for SB elements is unreliable.
    private static func computeQueue(app: SBApplication, current: MusicTrack) -> [QueueTrack] {
        guard let playlist = app.currentPlaylist, let tracks = playlist.tracks() else { return [] }
        let count = tracks.count
        guard count > 0 else { return [] }
        // `index` is 1-based; the next track is at 0-based array position == index.
        let start = current.index
        guard start >= 1, start < count else { return [] }
        let end = min(count, start + 15)
        var result: [QueueTrack] = []
        for position in start..<end {
            let element = tracks.object(at: position) as AnyObject
            let title = element.value(forKey: "name") as? String ?? ""
            let artist = element.value(forKey: "artist") as? String ?? ""
            guard !title.isEmpty else { continue }
            result.append(QueueTrack(id: position, title: title, artist: artist))
        }
        return result
    }

    private static func fetchArtwork(_ track: MusicTrack) -> NSImage? {
        guard let artworks = track.artworks(), artworks.count > 0 else { return nil }
        // `data` (the picture) realises to an NSImage; read it via KVC because
        // the SB element protocol cast doesn't hold at runtime.
        let element = artworks.object(at: 0) as AnyObject
        return element.value(forKey: "data") as? NSImage
    }

    /// Fallback artwork for tracks Music can't hand us a local image for (Apple
    /// Music streaming songs not in the library). Looks the song up in Apple's
    /// public iTunes Search API and downloads the cover. Fire-and-forget: on
    /// success it updates the cache (guarded so a track change mid-flight wins),
    /// and the controller's next poll renders it.
    private func fetchRemoteArtwork(artist: String, title: String, for trackID: String) {
        guard !title.isEmpty else { return }
        Task { [weak self] in
            guard let image = await Self.lookUpArtwork(artist: artist, title: title) else { return }
            // Update the caches on the same serial queue that owns them (a track
            // change mid-flight wins via the id guard).
            self?.queue.async {
                guard let self, self.artworkTrackID == trackID else { return }
                self.cachedArtwork = image
                self.cachedAccent = ArtworkColor.accent(from: image)
            }
        }
    }

    /// Query the iTunes Search API for the best-matching song and return its
    /// cover at a crisp size. Runs off the main actor (network + decode). No
    /// auth needed; failures return nil (we just show no artwork, as before).
    nonisolated private static func lookUpArtwork(artist: String, title: String) async -> NSImage? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        let term = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let results = json["results"] as? [[String: Any]],
                let artworkURLString = results.first?["artworkUrl100"] as? String
            else { return nil }
            // The API returns a 100×100 thumbnail; swap in a larger size so the
            // island art stays sharp.
            let largeURLString = artworkURLString.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let artURL = URL(string: largeURLString) else { return nil }
            let (imageData, _) = try await URLSession.shared.data(from: artURL)
            return NSImage(data: imageData)
        } catch {
            return nil
        }
    }

    private static func map(_ repeatMode: MusicERpt) -> RepeatMode {
        switch repeatMode {
        case .one: return .one
        case .all: return .all
        default: return .off
        }
    }

    // MARK: Controls
    //
    // All fire-and-forget, dispatched to the same serial `queue` as the reads so
    // the single SBApplication is only ever touched from one thread (and the
    // synchronous Apple Event never blocks the caller / main thread).

    func playPause() { queue.async { self.app?.playpause() } }
    func nextTrack() { queue.async { self.app?.nextTrack() } }
    func backTrack() { queue.async { self.app?.backTrack() } }  // restart-or-previous, like Apple Music
    func seek(to seconds: TimeInterval) { queue.async { self.app?.playerPosition = seconds } }
    func setShuffle(_ enabled: Bool) { queue.async { self.app?.shuffleEnabled = enabled } }

    /// `volume` is 0...1; Music expects 0...100.
    func setVolume(_ volume: Double) {
        queue.async { self.app?.soundVolume = Int(max(0, min(1, volume)) * 100) }
    }

    func setRepeat(_ mode: RepeatMode) {
        queue.async {
            switch mode {
            case .off: self.app?.songRepeat = .off
            case .one: self.app?.songRepeat = .one
            case .all: self.app?.songRepeat = .all
            }
        }
    }

    /// Favorite the current track (Music's "Favorite", sdef property `favorited`).
    func setFavorited(_ value: Bool) {
        queue.async {
            guard let track = self.app?.currentTrack else { return }
            track.favorited = value
        }
    }
}
