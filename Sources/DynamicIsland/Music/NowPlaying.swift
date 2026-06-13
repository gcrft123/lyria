import AppKit
import SwiftUI

/// Repeat mode, mirrored from Music's `song repeat`.
enum RepeatMode: Equatable {
    case off, one, all
}

/// One upcoming track in the queue sidebar (a trimmed view of a Music track).
struct QueueTrack: Identifiable, Equatable {
    let id: Int          // position used for ordering/identity
    let title: String
    let artist: String
}

/// A snapshot of what Apple Music is currently playing.
///
/// `elapsed` is sampled at `sampledAt`; use `currentElapsed(at:)` to get a
/// smoothly interpolated position between samples so the progress bar advances
/// without polling Music many times per second.
struct NowPlaying {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var elapsed: TimeInterval
    var sampledAt: Date
    var isPlaying: Bool
    var shuffle: Bool
    var repeatMode: RepeatMode

    /// Music's output volume, 0...1.
    var volume: Double

    /// Stable id (Music database ID) used to detect track changes.
    var trackID: String

    /// Whether the track is "Favorited" (loved) in Apple Music. Default `false`
    /// so existing initialisers that omit it still compile.
    var isFavorited: Bool = false

    var artwork: NSImage?
    /// Colour pulled from the artwork, used for the glow / accents.
    var accent: Color

    /// Upcoming tracks from the current playlist (best-effort "Up Next"). Empty
    /// when there's no playlist context (radio, autoplay, a single song).
    var queue: [QueueTrack] = []

    /// Interpolated playback position, accounting for elapsed wall-clock time.
    func currentElapsed(at date: Date = Date()) -> TimeInterval {
        guard duration > 0 else { return 0 }
        guard isPlaying else { return min(max(0, elapsed), duration) }
        let projected = elapsed + date.timeIntervalSince(sampledAt)
        return min(max(0, projected), duration)
    }
}

/// Formats seconds as `m:ss`.
func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
