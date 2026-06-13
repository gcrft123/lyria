import SwiftUI

/// The animated "now playing" equalizer bars (Apple Music's now-playing glyph).
///
/// Heights are driven by offset sine waves via a `TimelineView`, so the motion
/// is continuous and smooth. When paused, the timeline stops and the bars
/// settle to a short, even height.
struct NowPlayingBars: View {
    var color: Color
    var isPlaying: Bool
    var barCount: Int = 4
    var maxHeight: CGFloat = 16
    var barWidth: CGFloat = 2.5

    private let speeds: [Double] = [3.1, 4.5, 2.6, 3.8]
    private let phases: [Double] = [0.0, 1.3, 2.5, 0.7]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: height(for: index, at: t))
                }
            }
            .frame(height: maxHeight, alignment: .center)
            .animation(Motion.hover, value: isPlaying)
        }
    }

    private func height(for index: Int, at time: Double) -> CGFloat {
        guard isPlaying else { return maxHeight * 0.28 }
        let i = index % speeds.count
        let wave = sin(time * speeds[i] + phases[i]) * 0.5 + 0.5  // 0...1
        return maxHeight * (0.28 + 0.72 * wave)
    }
}
