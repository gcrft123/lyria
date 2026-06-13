import SwiftUI

/// Album artwork with a rounded-rectangle mask, or a music-note placeholder.
struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(Palette.surfaceRaised)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: 0.5)
        )
    }
}
