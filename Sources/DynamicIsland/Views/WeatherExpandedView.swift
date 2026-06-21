import SwiftUI

/// The Weather app filling the main island. Plain content on the island's black
/// background like every other app: a hero (place · big temperature · condition,
/// with the condition glyph + feels-like / high-low trailing), a stats row
/// (humidity · wind · precip), a horizontal hourly strip, and a scrolling 7-day
/// list with temperature-range bars.
struct WeatherExpandedView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var weather: WeatherManager

    var body: some View {
        Group {
            if let snap = weather.snapshot {
                content(snap)
            } else {
                loading
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Layout

    private func content(_ snap: WeatherSnapshot) -> some View {
        VStack(spacing: Spacing.xl) {
            hero(snap)
            statsRow(snap)
            hourly(snap)
            daily(snap)
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xxl)
        .padding(.bottom, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Hero (plain, on black)

    private func hero(_ snap: WeatherSnapshot) -> some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(snap.locationName)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(WeatherFormat.temp(snap.temperature))
                    .font(.system(size: 46, weight: .thin)) // design-lint:allow — hero temperature numeral, above the type scale
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
                Text(snap.condition.description)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.xs)
            VStack(alignment: .trailing, spacing: Spacing.sm) {
                Image(systemName: snap.condition.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Palette.textHigh)
                    .font(.system(size: IconSize.xxxl))
                Text("Feels \(WeatherFormat.temp(snap.apparentTemperature))")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                Text("H:\(WeatherFormat.temp(snap.high))  L:\(WeatherFormat.temp(snap.low))")
                    .font(Typography.captionMono)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // MARK: Stats row (on black)

    private func statsRow(_ snap: WeatherSnapshot) -> some View {
        HStack(spacing: 0) {
            stat("humidity", "\(snap.humidity)%")
            stat("wind", "\(Int(snap.windSpeed.rounded())) \(snap.windUnit)")
            stat("umbrella", "\(snap.precipProbability)%")
        }
        .padding(.vertical, Spacing.xxs)
    }

    private func stat(_ icon: String, _ value: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: IconSize.sm, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(Typography.caption)
                .foregroundStyle(Palette.textHigh)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Hourly strip (on black)

    private func hourly(_ snap: WeatherSnapshot) -> some View {
        // A plain SwiftUI ScrollView, NOT HWheelScroll: nesting an NSScrollView +
        // NSHostingView inside the island throws an Auto Layout exception during the
        // hover-expand window resize (crashed when the Weather notification was
        // hovered). The horizontal strip still drags / trackpad-swipes.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xxs) {
                ForEach(snap.hourly) { h in
                    VStack(spacing: Spacing.sm) {
                        Text(WeatherFormat.hour(h.date, in: snap.timeZone, now: h.isNow))
                            .font(Typography.caption)
                            .foregroundStyle(h.isNow ? Palette.textPrimary : Palette.textHigh)
                        Image(systemName: h.condition.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Palette.textHigh)
                            .font(.system(size: IconSize.lg))
                            .frame(height: 18)
                        Text(h.precipProbability >= 10 ? "\(h.precipProbability)%" : " ")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textTertiary)
                        Text(WeatherFormat.temp(h.temperature))
                            .font(Typography.calloutMono)
                            .foregroundStyle(Palette.textPrimary)
                    }
                    .frame(width: 42)
                    .padding(.vertical, Spacing.sm)
                    .background(h.isNow ? AnyShapeStyle(Palette.surfaceRaised) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                }
            }
            .padding(.horizontal, Spacing.xxs)
        }
        .frame(height: 78)
        .smoothScrollBounce()
    }

    // MARK: Daily list (on black)

    private func daily(_ snap: WeatherSnapshot) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(snap.daily.enumerated()), id: \.element.id) { idx, day in
                    if idx > 0 {
                        Rectangle().fill(Palette.hairlineStroke).frame(height: 1)
                    }
                    dayRow(day, snap: snap, today: idx == 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dayRow(_ day: DayForecast, snap: WeatherSnapshot, today: Bool) -> some View {
        HStack(spacing: Spacing.lg) {
            Text(WeatherFormat.weekday(day.date, in: snap.timeZone, today: today))
                .font(today ? Typography.calloutStrong : Typography.callout)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 40, alignment: .leading)

            Image(systemName: day.condition.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.textHigh)
                .font(.system(size: IconSize.md))
                .frame(width: 22)

            if day.precipProbability >= 10 {
                Text("\(day.precipProbability)%")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 24, alignment: .leading)
            } else {
                Spacer().frame(width: 24)
            }

            Text(WeatherFormat.tempNumber(day.low) + "°")
                .font(Typography.calloutMono)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 26, alignment: .trailing)

            rangeBar(day: day, snap: snap)
                .frame(height: 4)
                .frame(maxWidth: .infinity)

            Text(WeatherFormat.tempNumber(day.high) + "°")
                .font(Typography.calloutMono)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 26, alignment: .leading)
        }
        .padding(.vertical, Spacing.md)
    }

    /// A track spanning the week's full low→high range, with a gradient-tinted
    /// segment marking this day's low→high (cool→warm via `WeatherFormat.color`).
    private func rangeBar(day: DayForecast, snap: WeatherSnapshot) -> some View {
        GeometryReader { geo in
            let span = max(1, snap.weekHigh - snap.weekLow)
            let lo = CGFloat((day.low - snap.weekLow) / span)
            let hi = CGFloat((day.high - snap.weekLow) / span)
            let x = geo.size.width * lo
            let w = max(8, geo.size.width * (hi - lo))
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceStrong)
                Capsule()
                    .fill(LinearGradient(
                        colors: [WeatherFormat.color(forTemp: day.low, isFahrenheit: snap.isFahrenheit),
                                 WeatherFormat.color(forTemp: day.high, isFahrenheit: snap.isFahrenheit)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: w)
                    .offset(x: x)
            }
        }
    }

    // MARK: Loading / empty (on black)

    private var loading: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "cloud.sun.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.textHigh)
                .font(.system(size: IconSize.xxxl))
            Text(weather.errorMessage ?? "Getting weather…")
                .font(Typography.callout)
                .foregroundStyle(Palette.textHigh)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
