import SwiftUI

/// The island's silhouette: a rounded rectangle with a continuous ("squircle")
/// corner curve, the same curve family Apple uses for the Dynamic Island. At
/// the collapsed corner radius (height / 2) this reads as a perfect pill.
///
/// Kept as its own `Shape` so the future expand animation can interpolate the
/// corner radius and the hit-test region shares the exact outline.
struct IslandShape: Shape {
    var cornerRadius: CGFloat

    /// Lets SwiftUI animate the corner radius smoothly during morphs.
    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }
}
