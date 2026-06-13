import SwiftUI

/// Volume control: a draggable track flanked by speaker glyphs, like Apple
/// Music's expanded player. Updates live while dragging. The whole row height
/// is the hit area. The track thickens on hover and glows in the accent colour
/// while being dragged.
struct VolumeSliderView: View {
    var volume: Double            // 0...1, from the model
    var accent: Color
    var isHovered: Bool
    var onChange: (Double) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    private let idleHeight: CGFloat = 4
    private let activeHeight: CGFloat = 7

    var body: some View {
        let active = isHovered || isDragging
        let trackHeight = active ? activeHeight : idleHeight

        HStack(spacing: Spacing.lg) {
            Image(systemName: "speaker.fill")
                .font(.system(size: IconSize.sm))
                .foregroundStyle(Palette.textTertiary)

            GeometryReader { geo in
                let width = geo.size.width
                let fraction = isDragging ? dragValue : min(1, max(0, volume))

                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surfaceStrong).frame(height: trackHeight)
                    Capsule()
                        .fill(Palette.textPrimary)
                        .frame(width: max(trackHeight, width * fraction), height: trackHeight)
                        .shadow(color: accent.opacity(isDragging ? 0.9 : 0), // design-lint:allow — accent drag-glow (signature effect)
                                radius: isDragging ? 7 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let fraction = min(1, max(0, value.location.x / width))
                            dragValue = fraction
                            onChange(fraction)
                        }
                        .onEnded { value in
                            let fraction = min(1, max(0, value.location.x / width))
                            onChange(fraction)
                            isDragging = false
                        }
                )
            }
            .frame(height: 22)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: IconSize.sm))
                .foregroundStyle(Palette.textTertiary)
        }
        .animation(Motion.hover, value: active)
    }
}
