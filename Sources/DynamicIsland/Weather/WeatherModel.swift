import SwiftUI

/// The semantic weather category, mapped from a WMO weather code (the codes
/// Open-Meteo returns). Mirrors the buckets Apple's Weather app draws icons and
/// backgrounds for.
enum WeatherKind: Equatable {
    case clear            // 0
    case partlyCloudy     // 1, 2
    case cloudy           // 3
    case fog              // 45, 48
    case drizzle          // 51, 53, 55
    case rain             // 61, 63, 80, 81
    case heavyRain        // 65, 82
    case snow             // 71, 73, 75, 77, 85, 86
    case sleet            // 56, 57, 66, 67
    case thunderstorm     // 95, 96, 99

    /// Bucket a raw WMO code.
    static func from(code: Int) -> WeatherKind {
        switch code {
        case 0:                 return .clear
        case 1, 2:              return .partlyCloudy
        case 3:                 return .cloudy
        case 45, 48:            return .fog
        case 51, 53, 55:        return .drizzle
        case 56, 57, 66, 67:    return .sleet
        case 61, 63, 80, 81:    return .rain
        case 65, 82:            return .heavyRain
        case 71, 73, 75, 77, 85, 86: return .snow
        case 95, 96, 99:        return .thunderstorm
        default:                return .cloudy
        }
    }
}

/// A coarse weather bucket used to derive `precipitating` (drives the precip
/// accents). Was the animation backdrop selector before the sky was removed.
enum SkyKind: Equatable {
    case clear, partlyCloudy, cloudy, fog, rain, snow, thunderstorm
}

/// A resolved condition: the semantic kind plus day/night, with the display
/// string, SF Symbol, and animation bucket derived from them.
struct WeatherCondition: Equatable {
    let kind: WeatherKind
    let isDay: Bool

    init(code: Int, isDay: Bool) {
        self.kind = .from(code: code)
        self.isDay = isDay
    }

    init(kind: WeatherKind, isDay: Bool) {
        self.kind = kind
        self.isDay = isDay
    }

    /// Short label shown under the temperature ("Partly Cloudy", "Rain", …).
    var description: String {
        switch kind {
        case .clear:        return isDay ? "Sunny" : "Clear"
        case .partlyCloudy: return isDay ? "Partly Cloudy" : "Partly Cloudy"
        case .cloudy:       return "Cloudy"
        case .fog:          return "Fog"
        case .drizzle:      return "Drizzle"
        case .rain:         return "Rain"
        case .heavyRain:    return "Heavy Rain"
        case .snow:         return "Snow"
        case .sleet:        return "Sleet"
        case .thunderstorm: return "Thunderstorms"
        }
    }

    /// A multicolor SF Symbol, day/night aware (used in the compact pill, hero,
    /// hourly, and daily rows).
    var symbol: String {
        switch kind {
        case .clear:        return isDay ? "sun.max.fill" : "moon.stars.fill"
        case .partlyCloudy: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy:       return "cloud.fill"
        case .fog:          return "cloud.fog.fill"
        case .drizzle:      return isDay ? "cloud.drizzle.fill" : "cloud.drizzle.fill"
        case .rain:         return "cloud.rain.fill"
        case .heavyRain:    return "cloud.heavyrain.fill"
        case .snow:         return "cloud.snow.fill"
        case .sleet:        return "cloud.sleet.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        }
    }

    /// The animation bucket for the backdrop.
    var sky: SkyKind {
        switch kind {
        case .clear:                       return .clear
        case .partlyCloudy:                return .partlyCloudy
        case .cloudy:                      return .cloudy
        case .fog:                         return .fog
        case .drizzle, .rain, .heavyRain:  return .rain
        case .snow, .sleet:                return .snow
        case .thunderstorm:                return .thunderstorm
        }
    }

    /// Whether anything is falling (drives the hourly precip chance accents).
    var precipitating: Bool {
        switch sky { case .rain, .snow, .thunderstorm: return true; default: return false }
    }
}

/// A severe-weather advisory attached to a reading (warning/watch/advisory).
/// Open-Meteo's basic forecast doesn't carry these, so the live path leaves it
/// `nil` for now; a future alert source (or the mock path) populates it. Its
/// arrival is one of the two triggers that briefly promote Weather to the notch.
struct WeatherAlert: Equatable {
    /// Stable id so a repeated reading of the SAME alert doesn't re-flash.
    let id: String
    /// Short headline shown in the compact pill, e.g. "Severe Thunderstorm Warning".
    let headline: String
}

/// One hour in the hourly strip.
struct HourForecast: Identifiable, Equatable {
    let id: Int               // unix timestamp, stable
    let date: Date
    let temperature: Double
    let condition: WeatherCondition
    let precipProbability: Int // 0…100
    var isNow: Bool = false
}

/// One day in the 7-day list.
struct DayForecast: Identifiable, Equatable {
    let id: Int
    let date: Date
    let low: Double
    let high: Double
    let condition: WeatherCondition
    let precipProbability: Int
}

/// A complete weather reading for one place, everything the views render.
struct WeatherSnapshot: Equatable {
    var locationName: String
    var temperature: Double
    var apparentTemperature: Double   // "feels like"
    var condition: WeatherCondition
    var humidity: Int                 // %
    var windSpeed: Double             // mph or km/h per unit
    var precipitation: Double         // current, in/mm
    var precipProbability: Int        // today's max chance, %
    var high: Double
    var low: Double
    var hourly: [HourForecast]
    var daily: [DayForecast]
    var isFahrenheit: Bool
    var windUnit: String
    var timeZone: TimeZone
    var updatedAt: Date
    /// An active severe-weather advisory, if any (drives the alert flash + the
    /// compact pill's warning treatment). `nil` in the ordinary case.
    var alert: WeatherAlert? = nil

    /// The coolest low / warmest high across the week — the scale the daily
    /// range bars are drawn against (Apple Weather's signature).
    var weekLow: Double { daily.map(\.low).min() ?? low }
    var weekHigh: Double { daily.map(\.high).max() ?? high }
}

// MARK: - Formatting helpers

enum WeatherFormat {
    /// "72°" — rounded, degree sign, no unit letter (matches Apple Weather).
    static func temp(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    /// Bare rounded number, for the range-bar endpoints where the column header
    /// already implies degrees.
    static func tempNumber(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }

    static func hour(_ date: Date, in tz: TimeZone, now: Bool) -> String {
        if now { return "Now" }
        let f = DateFormatter()
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "ha"            // 9AM, 12PM
        return f.string(from: date).replacingOccurrences(of: "AM", with: "AM")
    }

    static func weekday(_ date: Date, in tz: TimeZone, today: Bool) -> String {
        if today { return "Today" }
        let f = DateFormatter()
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE"           // Mon, Tue
        return f.string(from: date)
    }

    /// Map a temperature (in the displayed unit) to a color, cool → warm, for
    /// the daily range bars. Thresholds are tuned for Fahrenheit; Celsius values
    /// are converted on the way in.
    static func color(forTemp value: Double, isFahrenheit: Bool) -> Color {
        let f = isFahrenheit ? value : value * 9 / 5 + 32
        switch f {
        case ..<32:  return Palette.cyan   // icy
        case ..<50:  return Palette.blue   // cool
        case ..<62:  return Palette.teal
        case ..<72:  return Palette.green
        case ..<82:  return Palette.amber
        case ..<92:  return Palette.orange
        default:     return Palette.red    // hot
        }
    }
}
