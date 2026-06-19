import SwiftUI

/// A first-class "app" that can take over the island's main area and appears in
/// the expanded sidebar. Distinct from indicators (camera/mic), which only ever
/// ride alongside as side islands and never fill the main island.
///
/// `priority` defines the hierarchy used both to pick which app fills the main
/// island (lowest number wins) and to order the secondary side islands. As more
/// apps are added, give them a priority slot here.
enum IslandApp: String, CaseIterable, Equatable, Identifiable {
    case calendar
    case dashboard
    case music
    case timers
    case weather
    case calculator

    var id: String { rawValue }

    /// Lower = higher in the hierarchy (closer to the main island).
    /// Calendar > Dashboard > Music > Timers > … (camera/mic is an indicator,
    /// not an app). Calendar leads so an imminent event's live activity takes
    /// over the notch even over playing music — a meeting in two minutes wants
    /// the glance. Dashboard sits just above Music: it's the aggregate "home"
    /// the island lands on when expanded (it embeds a mini player), so it
    /// outranks Music in the hierarchy.
    var priority: Int {
        switch self {
        case .calendar: return 0
        case .dashboard: return 1
        case .music: return 2
        case .timers: return 3
        case .weather: return 4
        case .calculator: return 6
        }
    }

    /// Top-to-bottom position in the expanded sidebar. Intentionally decoupled
    /// from `priority` (which still governs which app wins the main island and
    /// how secondaries stack): the sidebar lists Music, then Timers, then
    /// Calendar at the bottom, even though Calendar outranks them in the
    /// hierarchy.
    var sidebarOrder: Int {
        switch self {
        case .dashboard: return 0
        case .music: return 1
        case .timers: return 2
        case .calendar: return 3
        case .weather: return 4
        case .calculator: return 5
        }
    }

    /// SF Symbol shown in the sidebar and on side islands.
    var icon: String {
        switch self {
        case .calendar: return "calendar"
        case .dashboard: return "square.grid.2x2.fill"
        case .music: return "music.note"
        case .timers: return "timer"
        case .weather: return "cloud.sun.fill"
        case .calculator: return "plus.forwardslash.minus"
        }
    }

    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .dashboard: return "Dashboard"
        case .music: return "Music"
        case .timers: return "Timers"
        case .weather: return "Weather"
        case .calculator: return "Calculator"
        }
    }

    /// A fixed accent for the app. Music normally tints from its artwork, so its
    /// value here is only a fallback; the others use this everywhere.
    var tint: Color {
        switch self {
        case .calendar: return Palette.tintCalendar
        case .dashboard: return Palette.tintDashboard
        case .music: return Palette.neutralAccent
        case .timers: return Palette.tintTimers
        case .weather: return Palette.tintWeather
        case .calculator: return Palette.tintCalculator
        }
    }
}
