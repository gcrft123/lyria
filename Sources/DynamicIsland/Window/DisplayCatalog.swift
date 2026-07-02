import AppKit

/// A connected display, for the "show the island on these screens" setting.
struct DisplayInfo: Identifiable {
    /// Stable UUID string — survives resolution changes and reconnects, so a
    /// remembered choice sticks to the physical display.
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let isMain: Bool
}

/// Enumerates the connected displays and resolves their stable identifiers. Shared
/// by the Displays settings page and the window controller's screen targeting.
enum DisplayCatalog {

    /// The connected displays, main first then by name.
    static func connected() -> [DisplayInfo] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let num = displayID(of: screen), let uuid = persistentID(for: num) else { return nil }
            return DisplayInfo(id: uuid, displayID: num, name: name(of: screen, id: num), isMain: num == mainID)
        }
        .sorted { ($0.isMain ? 0 : 1, $0.name) < ($1.isMain ? 0 : 1, $1.name) }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Stable UUID string for a display id (survives resolution / reconnect).
    static func persistentID(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
    }

    private static func name(of screen: NSScreen, id: CGDirectDisplayID) -> String {
        let n = screen.localizedName
        if !n.isEmpty { return n }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "External Display"
    }
}
