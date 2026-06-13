import SwiftUI

/// A transient volume / brightness readout that briefly takes over the island,
/// replacing the system's own on-screen HUD.
///
/// The `SystemHUDProvider` intercepts the hardware volume/brightness keys
/// (swallowing them so macOS shows no HUD of its own), applies the change
/// itself, and presents one of these. The controller auto-dismisses it after a
/// short beat, the way the system overlay fades out.
struct SystemHUD: Equatable {

    enum Kind: Equatable {
        case volume
        case brightness
        case keyboardBacklight
    }

    var kind: Kind

    /// The filled fraction of the bar, 0…1.
    var level: Double

    /// Output is muted (volume only). When set the bar reads empty and the
    /// glyph shows a slashed speaker.
    var muted: Bool = false

    /// The fraction the bar should actually fill — empty while muted.
    var fill: Double { muted ? 0 : max(0, min(1, level)) }

    /// SF Symbol for the leading glyph, reflecting the current level / mute.
    var symbol: String {
        switch kind {
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboardBacklight:
            return level <= 0.0001 ? "keyboard" : "keyboard.fill"
        case .volume:
            if muted || level <= 0.0001 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}
