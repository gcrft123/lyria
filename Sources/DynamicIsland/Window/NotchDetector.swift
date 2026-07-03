import AppKit

/// The physical notch region of a display, measured in points.
///
/// `width`/`height` describe the black cut-out at the top-centre of a notched
/// MacBook screen. The notch is always centred on the display's horizontal
/// midpoint with its top flush to the screen's top edge, so those two numbers
/// (plus the screen frame, known at the call site) fully place it.
struct NotchGeometry: Equatable {
    let width: CGFloat
    let height: CGFloat
}

/// How a given display draws the island.
enum IslandRenderStyle: Equatable {
    /// The classic detached blob, floating below the top edge.
    case floating
    /// Integrated with the display's hardware notch.
    case notch(NotchGeometry)
}

/// Detects whether a display has a hardware notch and measures it.
///
/// Uses the AppKit safe-area API (macOS 12+, always available at our 13.0
/// deployment target — see `OnboardingWindowController` which already gates on
/// `safeAreaInsets.top`): the notch height is the top safe-area inset, and the
/// notch width is the gap between the two menu-bar rects that flank it.
enum NotchDetector {

    /// Fallback metrics for a display we believe is notched but whose flanking
    /// menu-bar rects came back empty (e.g. an unusual menu-bar state). Sized to
    /// the 14"/16" MacBook Pro notch.
    static let fallbackWidth: CGFloat = 200
    static let fallbackHeight: CGFloat = 32

    /// The notch geometry for a screen, or `nil` if it has no notch.
    static func geometry(for screen: NSScreen) -> NotchGeometry? {
        // Debug: synthesize a notch on the main display so notch integration can be
        // exercised on a Mac without a hardware notch. `DI_MOCK_NOTCH=1` (default
        // 200×32) or `DI_MOCK_NOTCH=<width>x<height>`.
        if let mock = mockGeometry(for: screen) { return mock }
        guard screen.safeAreaInsets.top > 0 else { return nil }
        let height = screen.safeAreaInsets.top
        let width: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = screen.frame.width - left.width - right.width
        } else {
            width = fallbackWidth
        }
        return NotchGeometry(width: width > 0 ? width : fallbackWidth,
                             height: height > 0 ? height : fallbackHeight)
    }

    /// The synthetic notch from `DI_MOCK_NOTCH`, applied to the main display only
    /// (mimicking a notched MacBook as the primary screen). `nil` when unset or for
    /// non-main screens.
    private static func mockGeometry(for screen: NSScreen) -> NotchGeometry? {
        guard let raw = ProcessInfo.processInfo.environment["DI_MOCK_NOTCH"], !raw.isEmpty,
              let num = DisplayCatalog.displayID(of: screen), num == CGMainDisplayID() else { return nil }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        if parts.count == 2, parts[0] > 0, parts[1] > 0 {
            return NotchGeometry(width: parts[0], height: parts[1])
        }
        return NotchGeometry(width: fallbackWidth, height: fallbackHeight)
    }

    /// The notch geometry for a display id, or `nil` if not connected / no notch.
    static func geometry(for displayID: CGDirectDisplayID) -> NotchGeometry? {
        guard let screen = NSScreen.screens.first(where: { DisplayCatalog.displayID(of: $0) == displayID })
        else { return nil }
        return geometry(for: screen)
    }

    /// Whether a screen has a hardware notch.
    static func hasNotch(_ screen: NSScreen) -> Bool { screen.safeAreaInsets.top > 0 }
}
