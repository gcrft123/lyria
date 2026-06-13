import SwiftUI

/// An interactive scrubber. Shows playback progress and lets the user drag
/// anywhere on the track to seek. While dragging it previews locally and only
/// commits the seek on release. The track thickens on hover and glows in the
/// accent colour while being dragged.
struct ProgressBarView: View {
    var elapsed: TimeInterval
    var duration: TimeInterval
    var accent: Color
    var isHovered: Bool

    /// Called on release with the chosen time.
    var onCommit: (TimeInterval) -> Void

    @State private var isDragging = false
    @State private var dragFraction: Double = 0

    private let idleHeight: CGFloat = 4
    private let activeHeight: CGFloat = 7

    var body: some View {
        let active = isHovered || isDragging
        let trackHeight = active ? activeHeight : idleHeight

        GeometryReader { geo in
            let width = geo.size.width
            let fraction = isDragging
                ? dragFraction
                : (duration > 0 ? min(1, max(0, elapsed / duration)) : 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.surfaceStrong)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Palette.textPrimary)
                    .frame(width: max(trackHeight, width * fraction), height: trackHeight)
                    .shadow(color: accent.opacity(isDragging ? 0.9 : 0), // design-lint:allow — accent drag-glow (signature effect)
                            radius: isDragging ? 7 : 0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        dragFraction = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { value in
                        let fraction = min(1, max(0, value.location.x / width))
                        onCommit(fraction * duration)
                        isDragging = false
                    }
            )
        }
        .frame(height: 14)
        .animation(Motion.hover, value: active)
    }
}
