import SwiftUI

/// Which side of the island an extension rides on.
enum IslandExtensionEdge: Equatable {
    case leading   // to the island's left
    case trailing  // to the island's right
}

/// Whether an extension touches the island or floats with a gap.
enum IslandExtensionAttachment: Equatable {
    case attached  // flush against the island (or the previous extension)
    case detached  // separated by a gap
}

/// A side accessory to the island — a small blob that rides at the island's
/// leading or trailing edge, *at the island's height*, so it reads as a piece
/// of the island rather than a separate widget.
///
/// Extensions are pure data (icon names + tint + placement) so they diff and
/// animate cleanly. A source of extensions is an `IslandExtensionProvider`;
/// register one with `controller.register(extensionProvider:)` and push/remove
/// the extension as its state changes. The camera/mic indicator is the first
/// such provider; add more (battery, focus, timers, AirDrop, …) the same way.
struct IslandExtension: Identifiable, Equatable {
    /// Stable id; also the key the owning provider uses to update/remove it.
    let id: String

    /// Side of the island.
    var edge: IslandExtensionEdge = .trailing

    /// Flush against the island or floating with a gap.
    var attachment: IslandExtensionAttachment = .detached

    /// SF Symbol names shown left-to-right. One symbol renders as a circle (at
    /// the island's height); several widen it into a pill.
    var symbols: [String] = []

    /// Glyph / glow colour.
    var tint: Color

    /// Stacking order outward from the island on a given edge (lower = closer).
    var order: Int = 0
}

/// A source of island extensions. Implementors watch some system state and push
/// an `IslandExtension` (or remove it) into the controller as it changes.
@MainActor
protocol IslandExtensionProvider: AnyObject {
    /// Id of the extension this provider manages (matches `IslandExtension.id`).
    var extensionID: String { get }

    /// Start watching and pushing updates into the controller.
    func startProviding(into controller: DynamicIslandController)

    /// Stop watching (invalidate any timers/observers).
    func stopProviding()
}
