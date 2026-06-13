import SwiftUI

/// An editable response curve: a row of control points (fixed, evenly-spaced on X)
/// whose Y the user drags to shape a 0…1 value. Used for the wave-sensitivity
/// graphs (sensitivity vs pitch / vs volume). Draws a smooth curve through the
/// points with a soft accent fill underneath.
struct CurveEditor: View {
    @Binding var values: [Double]   // each 0…1
    let accent: Color

    private let knob: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let inset = knob / 2 + 1
            let plotW = geo.size.width - inset * 2
            let plotH = geo.size.height - inset * 2
            let pts = points(plotW: plotW, plotH: plotH, inset: inset)

            ZStack {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(Palette.surfaceSubtle)
                    .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .stroke(Palette.hairlineStroke))

                CurvePath(points: pts, fillTo: geo.size.height - inset)
                    .fill(LinearGradient(colors: [accent.opacity(0.30), accent.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                CurvePath(points: pts, fillTo: nil)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                ForEach(values.indices, id: \.self) { i in
                    Circle()
                        .fill(Palette.textPrimary)
                        .overlay(Circle().stroke(accent, lineWidth: 2))
                        .frame(width: knob, height: knob)
                        .raisedShadow()
                        .position(pts[i])
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { g in
                                    let v = 1 - Double((g.location.y - inset) / max(1, plotH))
                                    var next = values
                                    next[i] = max(0, min(1, v))
                                    values = next
                                }
                        )
                }
            }
        }
    }

    private func points(plotW: CGFloat, plotH: CGFloat, inset: CGFloat) -> [CGPoint] {
        let n = max(1, values.count - 1)
        return values.indices.map { i in
            CGPoint(x: inset + CGFloat(i) / CGFloat(n) * plotW,
                    y: inset + (1 - CGFloat(values[i])) * plotH)
        }
    }
}

/// A smooth (Catmull-Rom) path through the points; if `fillTo` is set, the path is
/// closed down to that Y so it can be filled as an area.
private struct CurvePath: Shape {
    var points: [CGPoint]
    var fillTo: CGFloat?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if let fillTo {
            path.addLine(to: CGPoint(x: points.last!.x, y: fillTo))
            path.addLine(to: CGPoint(x: points.first!.x, y: fillTo))
            path.closeSubpath()
        }
        return path
    }
}
