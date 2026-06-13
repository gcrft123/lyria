import SwiftUI

/// The compact, not-hovered Weather layout: a glanceable pill with the current
/// condition glyph, temperature, a short condition word, and the place name.
struct WeatherCompactView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var weather: WeatherManager

    private var accent: Color { IslandApp.weather.tint }

    var body: some View {
        Group {
            if let snap = weather.snapshot {
                content(snap)
            } else {
                placeholder
            }
        }
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Amber used for the severe-alert glyph + headline.
    private let warning = Palette.amber

    private func content(_ snap: WeatherSnapshot) -> some View {
        let alert = snap.alert
        return HStack(spacing: Spacing.xl) {
            Image(systemName: alert != nil ? "exclamationmark.triangle.fill" : snap.condition.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(alert != nil ? AnyShapeStyle(warning) : AnyShapeStyle(Palette.textHigh))
                .font(.system(size: IconSize.xl))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(snap.locationName)
                    .font(Typography.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(alert?.headline ?? snap.condition.description)
                    .font(Typography.caption)
                    .foregroundStyle(alert != nil ? AnyShapeStyle(warning) : AnyShapeStyle(Palette.textSecondary))
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)

            Text(WeatherFormat.temp(snap.temperature))
                .font(Typography.title2Mono)
                .foregroundStyle(Palette.textPrimary)
        }
    }

    private var placeholder: some View {
        HStack(spacing: Spacing.xl) {
            Image(systemName: "cloud.sun.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.textHigh)
                .font(.system(size: IconSize.xl))
                .frame(width: 24)
            Text("Weather")
                .font(Typography.bodyStrong)
                .foregroundStyle(Palette.textPrimary)
            Spacer(minLength: Spacing.sm)
            Text("--°")
                .font(Typography.title2Mono)
                .foregroundStyle(Palette.textTertiary)
        }
    }
}
