import SwiftUI

/// A transient, glanceable "live activity" shown in the compact notch — modelled
/// on the weather-change flash. Unlike a `popup` it does NOT take over the island
/// or block interaction: the island still opens on hover / click / scroll while
/// one is up (it sits in the compact slot and yields to hover), and it auto-clears
/// after its duration or the moment the user engages.
struct LiveActivity: Identifiable, Equatable {
    let id: String
    var symbol: String
    var title: String
    var accent: Color
}
