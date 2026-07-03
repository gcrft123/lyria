import SwiftUI

/// The morphing black silhouette of a notch-integrated island.
///
/// Its top edge is flush with the screen (square top corners, so it fuses
/// seamlessly with the physical notch / bezel) and its bottom corners are
/// rounded. The bottom radius animates as the shape morphs between the bare
/// notch, a live activity, and the expanded card.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let b = max(0, min(bottomRadius, min(rect.width, rect.height) / 2))
        let t = max(0, min(topRadius, min(rect.width, rect.height) / 2))
        var p = Path()
        // An OPEN outline: the top edge is deliberately omitted so a stroke traces
        // only the two sides and the rounded bottom — the top sits flush behind the
        // bezel, so a ring/hairline there would be wrong. Filling or clipping this
        // path implicitly closes the top with a straight edge, so the solid black
        // silhouette is unchanged; only strokes skip the top.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + t))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + t))
        return p
    }
}
