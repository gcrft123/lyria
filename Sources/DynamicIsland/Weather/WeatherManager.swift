import Combine
import CoreLocation
import SwiftUI

/// Owns the current weather reading and keeps it fresh.
///
/// An `ObservableObject` (mirroring `CalendarManager`) injected into the
/// controller so the weather views re-render when a new reading lands. Location
/// comes from CoreLocation (with a graceful fallback so something always shows);
/// the forecast comes from Open-Meteo's free, key-less JSON API. A periodic
/// refresh keeps it current.
///
/// Debug envs:
///   • `DI_MOCK_WEATHER=1|clear|night|clouds|rain|snow|storm|fog` — seed a
///     synthetic snapshot (no network / no location prompt). The variant picks
///     the *current* condition so each animated sky can be screenshotted.
///   • `DI_WEATHER_LOC=lat,lon` — skip CoreLocation, fetch this fixed point.
///   • `DI_WEATHER_CITY=Name` — override the displayed place name.
///   • `DI_WEATHER_UNIT=f|c` — force the temperature unit.
///   • `DI_MOCK_WEATHER_FLASH=alert|condition` — fire the 10s notch flash a few
///     seconds after launch (`alert` also attaches a severe advisory).
@MainActor
final class WeatherManager: NSObject, ObservableObject {

    /// The latest reading, or `nil` until the first fetch resolves.
    @Published private(set) var snapshot: WeatherSnapshot?
    /// A user-facing problem (no network, location denied with no fallback).
    @Published private(set) var errorMessage: String?
    /// True while a fetch is in flight (drives the loading shimmer).
    @Published private(set) var isLoading = false

    /// Fires when a freshly-landed reading is worth surfacing on its own: the
    /// coarse condition (sunny/cloudy/rainy/…) changed since the last reading,
    /// or a NEW severe-weather alert appeared. The controller listens and briefly
    /// promotes Weather to the compact notch. (A plain refresh with no change is
    /// silent.)
    let significantChange = PassthroughSubject<Void, Never>()

    /// The coarse condition of the last reading, to detect changes across
    /// refreshes; `nil` until the first reading (so the initial load never flashes).
    private var lastSky: SkyKind?
    /// The id of the last alert we flashed, so the same standing alert doesn't
    /// re-flash on every 15-minute refresh.
    private var lastAlertID: String?

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var refreshTimer: Timer?
    private var resolvedName: String?
    private var lastCoordinate: CLLocationCoordinate2D?

    /// User prefs (temperature unit). Optional so previews can omit it.
    private let settings: AppSettings?
    private var unitCancellable: AnyCancellable?

    /// Whether to show Fahrenheit. `DI_WEATHER_UNIT` env overrides the user setting;
    /// otherwise it follows the user's preference (defaulting to the locale).
    private var isFahrenheit: Bool {
        switch ProcessInfo.processInfo.environment["DI_WEATHER_UNIT"]?.lowercased() {
        case "f", "fahrenheit": return true
        case "c", "celsius":    return false
        default:                return settings?.weatherUseFahrenheit ?? (Locale.current.usesMetricSystem == false)
        }
    }

    init(settings: AppSettings? = nil) {
        self.settings = settings
        super.init()
        // Re-fetch when the user flips the unit (skipped under the env override).
        if ProcessInfo.processInfo.environment["DI_WEATHER_UNIT"] == nil, let settings {
            unitCancellable = settings.$weatherUseFahrenheit
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self, let c = self.lastCoordinate else { return }
                    Task { await self.fetch(coordinate: c) }
                }
        }

        // Mock path: seed a full synthetic snapshot and stop — no network, no
        // location prompt. The variant chooses the hero condition.
        if let mock = ProcessInfo.processInfo.environment["DI_MOCK_WEATHER"], !mock.isEmpty {
            var snap = Self.mockSnapshot(variant: mock, isFahrenheit: isFahrenheit)
            // DI_MOCK_WEATHER_FLASH=alert|condition exercises the 10s notch flash:
            // `alert` attaches a severe advisory; either value fires the trigger a
            // few seconds after launch (once the controller has subscribed, and
            // after any startup Bluetooth banner has cleared).
            let flash = ProcessInfo.processInfo.environment["DI_MOCK_WEATHER_FLASH"]?.lowercased()
            if flash == "alert" {
                snap.alert = WeatherAlert(id: "mock-alert", headline: "Severe Thunderstorm Warning")
            }
            snapshot = snap
            if let flash, !flash.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.significantChange.send()
                }
            }
            return
        }

        // Fixed-location override (handy for testing the live path deterministically).
        if let loc = ProcessInfo.processInfo.environment["DI_WEATHER_LOC"] {
            let parts = loc.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                let coord = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
                resolvedName = ProcessInfo.processInfo.environment["DI_WEATHER_CITY"]
                startRefresh(coordinate: coord)
                reverseGeocode(coord)
                return
            }
        }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        requestLocation()
        // Don't sit blank if the location grant is slow or denied: show a sane
        // default after a moment, replaced the instant a real fix arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.snapshot == nil, self.lastCoordinate == nil else { return }
            let fallback = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090) // Cupertino
            self.resolvedName = self.resolvedName ?? "Cupertino"
            self.startRefresh(coordinate: fallback)
            self.reverseGeocode(fallback)
        }
    }

    deinit { refreshTimer?.invalidate() }

    // MARK: Location

    private func requestLocation() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            locationManager.requestLocation()
        default:
            break // the 4s fallback covers denied/restricted
        }
    }

    // MARK: Refresh loop

    private func startRefresh(coordinate: CLLocationCoordinate2D) {
        lastCoordinate = coordinate
        refreshTimer?.invalidate()
        // Refresh every 15 minutes; the forecast doesn't move faster than that.
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            guard let self, let c = self.lastCoordinate else { return }
            Task { await self.fetch(coordinate: c) }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        Task { await fetch(coordinate: coordinate) }
    }

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) {
        // Only resolve a name when we weren't handed one.
        if let name = resolvedName, !name.isEmpty { return }
        let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            guard let self else { return }
            let name = placemarks?.first?.locality
                ?? placemarks?.first?.subAdministrativeArea
                ?? placemarks?.first?.administrativeArea
            Task { @MainActor in
                guard let name else { return }
                self.resolvedName = name
                if var snap = self.snapshot {
                    snap.locationName = name
                    self.snapshot = snap
                }
            }
        }
    }

    // MARK: Fetch

    private func fetch(coordinate: CLLocationCoordinate2D) async {
        isLoading = true
        defer { isLoading = false }

        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(coordinate.latitude)),
            .init(name: "longitude", value: String(coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,is_day,wind_speed_10m"),
            .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "temperature_unit", value: isFahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "wind_speed_unit", value: isFahrenheit ? "mph" : "kmh"),
        ]
        guard let url = comps.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OMResponse.self, from: data)
            if let snap = Self.snapshot(from: decoded,
                                        name: resolvedName ?? "My Location",
                                        isFahrenheit: isFahrenheit) {
                ingest(snap)
            }
        } catch {
            // Keep any prior snapshot on screen; only surface an error if blank.
            if snapshot == nil { errorMessage = "Weather unavailable" }
        }
    }

    /// Publish a freshly-fetched reading and fire `significantChange` when it
    /// crosses one of the two thresholds: a NEW severe alert, or a coarse
    /// condition change (sunny↔cloudy↔rainy…). The first-ever reading sets the
    /// baselines silently — there's nothing yet to have "changed" from.
    private func ingest(_ snap: WeatherSnapshot) {
        let prevSky = lastSky
        let prevAlertID = lastAlertID
        lastSky = snap.condition.sky
        lastAlertID = snap.alert?.id

        snapshot = snap
        errorMessage = nil

        if let alert = snap.alert, alert.id != prevAlertID {
            significantChange.send()            // a new advisory just appeared
        } else if let prevSky, prevSky != snap.condition.sky {
            significantChange.send()            // sky bucket flipped since last time
        }
    }

    // MARK: Decoding → snapshot

    private static func snapshot(from r: OMResponse, name: String, isFahrenheit: Bool) -> WeatherSnapshot? {
        let tz = TimeZone(secondsFromGMT: r.utc_offset_seconds ?? 0) ?? .current
        let now = Date()

        // Hourly: start at the current hour, take the next 24.
        var hours: [HourForecast] = []
        let times = r.hourly.time
        let startIdx = times.firstIndex { Double($0) >= now.timeIntervalSince1970 - 3600 } ?? 0
        let end = min(times.count, startIdx + 24)
        if startIdx < end {
            for i in startIdx..<end {
                let date = Date(timeIntervalSince1970: Double(times[i]))
                let isDay = (r.hourly.is_day?[safe: i] ?? 1) == 1
                let precip = r.hourly.precipitation_probability?[safe: i].flatMap { $0 } ?? 0
                hours.append(HourForecast(
                    id: times[i],
                    date: date,
                    temperature: r.hourly.temperature_2m[safe: i] ?? r.current.temperature_2m,
                    condition: WeatherCondition(code: r.hourly.weather_code[safe: i] ?? 0, isDay: isDay),
                    precipProbability: precip,
                    isNow: i == startIdx))
            }
        }

        // Daily: all 7.
        var days: [DayForecast] = []
        for i in 0..<r.daily.time.count {
            let date = Date(timeIntervalSince1970: Double(r.daily.time[i]))
            let precip = r.daily.precipitation_probability_max?[safe: i].flatMap { $0 } ?? 0
            // Daily icons read better with the daytime glyph.
            days.append(DayForecast(
                id: r.daily.time[i],
                date: date,
                low: r.daily.temperature_2m_min[safe: i] ?? 0,
                high: r.daily.temperature_2m_max[safe: i] ?? 0,
                condition: WeatherCondition(code: r.daily.weather_code[safe: i] ?? 0, isDay: true),
                precipProbability: precip))
        }

        let condition = WeatherCondition(code: r.current.weather_code, isDay: r.current.is_day == 1)
        return WeatherSnapshot(
            locationName: name,
            temperature: r.current.temperature_2m,
            apparentTemperature: r.current.apparent_temperature,
            condition: condition,
            humidity: Int((r.current.relative_humidity_2m ?? 0).rounded()),
            windSpeed: r.current.wind_speed_10m ?? 0,
            precipitation: r.current.precipitation ?? 0,
            precipProbability: days.first?.precipProbability ?? 0,
            high: days.first?.high ?? r.current.temperature_2m,
            low: days.first?.low ?? r.current.temperature_2m,
            hourly: hours,
            daily: days,
            isFahrenheit: isFahrenheit,
            windUnit: isFahrenheit ? "mph" : "km/h",
            timeZone: tz,
            updatedAt: now)
    }

    // MARK: Mock (DI_MOCK_WEATHER)

    /// Build a full synthetic snapshot with 24 hourly + 7 daily entries, the
    /// hero condition chosen by `variant`. No network, no location — used for
    /// deterministic screenshots of each animated sky.
    static func mockSnapshot(variant: String, isFahrenheit: Bool) -> WeatherSnapshot {
        // Pick the hero condition + a representative temperature for the variant.
        let (kind, isDay, baseF, name): (WeatherKind, Bool, Double, String) = {
            switch variant.lowercased() {
            case "night":   return (.clear,        false, 64, "Cupertino")
            case "clouds", "cloudy": return (.cloudy, true, 61, "San Francisco")
            case "partly", "partlycloudy": return (.partlyCloudy, true, 70, "Cupertino")
            case "rain":    return (.rain,         true,  54, "Seattle")
            case "snow":    return (.snow,         true,  28, "Denver")
            case "storm", "thunderstorm": return (.thunderstorm, true, 72, "Miami")
            case "fog":     return (.fog,          true,  57, "London")
            case "clear", "1", "sunny": return (.clear, true, 75, "Cupertino")
            default:        return (.partlyCloudy, true,  72, "Cupertino")
            }
        }()

        // Temperatures live in the displayed unit; convert the F seed if metric.
        func conv(_ f: Double) -> Double { isFahrenheit ? f : (f - 32) * 5 / 9 }
        let base = conv(baseF)
        let condition = WeatherCondition(kind: kind, isDay: isDay)
        let tz = TimeZone.current
        let now = Date()
        let cal = Calendar.current

        let startHour = cal.component(.hour, from: now)

        // A gentle diurnal curve so the hourly strip looks alive (peak ~3pm).
        func tempAt(hourOffset h: Int) -> Double {
            let hourOfDay = (startHour + h) % 24
            let warmth = -cos(Double(hourOfDay - 15) / 24 * 2 * .pi)
            return base + warmth * (conv(82) - conv(74)) // ±~8°F swing in unit
        }

        // Hourly: 24 entries from the current hour. Night flips after sunset.
        var hours: [HourForecast] = []
        for h in 0..<24 {
            let date = cal.date(byAdding: .hour, value: h, to: now) ?? now
            let hod = (startHour + h) % 24
            let day = hod >= 6 && hod < 19
            // Hero condition leads for the first few hours, then settles.
            let cond = WeatherCondition(kind: h < 6 ? kind : (kind == .thunderstorm ? .partlyCloudy : kind),
                                        isDay: day)
            hours.append(HourForecast(
                id: Int(date.timeIntervalSince1970),
                date: date,
                temperature: tempAt(hourOffset: h),
                condition: cond,
                precipProbability: condition.precipitating ? max(0, 80 - h * 4) : (h % 5 == 0 ? 10 : 0),
                isNow: h == 0))
        }

        // Daily: 7 entries, today first, with a little variety.
        let kinds: [WeatherKind] = [kind, .partlyCloudy, .clear, .cloudy, .rain, .partlyCloudy, .clear]
        var days: [DayForecast] = []
        for d in 0..<7 {
            let date = cal.date(byAdding: .day, value: d, to: now) ?? now
            let swing = conv(Double(6 + (d % 3) * 2))
            let mid = base + conv(Double(d % 4 - 1) * 3)
            let k = kinds[d % kinds.count]
            days.append(DayForecast(
                id: Int(date.timeIntervalSince1970),
                date: date,
                low: mid - swing,
                high: mid + swing,
                condition: WeatherCondition(kind: k, isDay: true),
                precipProbability: WeatherCondition(kind: k, isDay: true).precipitating ? 60 - d * 6 : (d % 3 == 0 ? 15 : 0)))
        }

        return WeatherSnapshot(
            locationName: ProcessInfo.processInfo.environment["DI_WEATHER_CITY"] ?? name,
            temperature: base,
            apparentTemperature: base - conv(3),
            condition: condition,
            humidity: condition.precipitating ? 88 : 54,
            windSpeed: isFahrenheit ? 7 : 11,
            precipitation: condition.precipitating ? (kind == .snow ? 0.2 : 0.4) : 0,
            precipProbability: days.first?.precipProbability ?? 0,
            high: days.first?.high ?? base,
            low: days.first?.low ?? base,
            hourly: hours,
            daily: days,
            isFahrenheit: isFahrenheit,
            windUnit: isFahrenheit ? "mph" : "km/h",
            timeZone: tz,
            updatedAt: now)
    }
}

// MARK: - CLLocationManagerDelegate

extension WeatherManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        MainActor.assumeIsolated {
            let coord = loc.coordinate
            // Ignore tiny jitters once we already have a fix.
            if let last = lastCoordinate,
               abs(last.latitude - coord.latitude) < 0.05,
               abs(last.longitude - coord.longitude) < 0.05 { return }
            startRefresh(coordinate: coord)
            reverseGeocode(coord)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // The 4s fallback covers this; nothing to do.
    }
}

// MARK: - Open-Meteo JSON

private struct OMResponse: Decodable {
    let utc_offset_seconds: Int?
    let current: OMCurrent
    let hourly: OMHourly
    let daily: OMDaily
}
private struct OMCurrent: Decodable {
    let temperature_2m: Double
    let apparent_temperature: Double
    let relative_humidity_2m: Double?
    let precipitation: Double?
    let weather_code: Int
    let is_day: Int
    let wind_speed_10m: Double?
}
private struct OMHourly: Decodable {
    let time: [Int]
    let temperature_2m: [Double]
    let weather_code: [Int]
    let precipitation_probability: [Int?]?
    let is_day: [Int]?
}
private struct OMDaily: Decodable {
    let time: [Int]
    let weather_code: [Int]
    let temperature_2m_max: [Double]
    let temperature_2m_min: [Double]
    let precipitation_probability_max: [Int?]?
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
