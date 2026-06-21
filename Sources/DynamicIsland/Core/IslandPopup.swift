import SwiftUI

/// A transient notification / live-activity that takes over the main island.
///
/// Popups sit at the very TOP of the island hierarchy: while one is present it
/// fills the main island regardless of hover, app priority, or sidebar
/// selection (see `DynamicIslandController.mode`). This is the seam that push
/// notifications and live activities plug into.
///
/// Lifecycle (all on the controller):
///   - `presentPopup(_:)` shows one (replacing any current popup),
///   - `activatePopup()` is the LEFT-click action — opens the associated `app`
///     if any, then dismisses (with no app it just dismisses),
///   - `dismissPopup()` clears it (RIGHT-click, or auto-dismiss), starting a
///     brief hover-immunity tail so the island doesn't snap open underneath.
struct IslandPopup: Identifiable, Equatable {
    /// How the popup renders. `.banner` is the modal notification card (mirrored
    /// system notifications). `.liveActivity` renders the associated app's compact
    /// center-island pill instead — same hover-grow / left-click-opens / right-click-
    /// dismisses interaction, but the live-activity look (weather change, imminent
    /// calendar event) rather than the banner.
    enum Style { case banner, liveActivity }

    let id: String

    /// How this popup renders (banner card vs. compact live-activity pill).
    var style: Style = .banner

    /// Bold first line — the sender or source ("John Bob").
    var title: String

    /// Secondary line — the body ("Do you want to get pizza?").
    var message: String

    /// The leading visual, shown in a rounded chip on the left.
    var icon: Icon

    /// Which island app a left-click should open. `nil` → left-click only
    /// dismisses (a notification with nowhere to go), unless `launchBundleID`
    /// is set (then it launches that external app).
    var app: IslandApp?

    /// Bundle id of an external macOS app a left-click should launch/focus —
    /// used by mirrored system notifications (e.g. Messages opens Messages).
    /// Only consulted when `app` is nil. `nil` → no external app to open.
    var launchBundleID: String?

    /// A URL a left-click should open — used for System Settings deep links
    /// (e.g. a battery notification opens the Battery pane). Consulted when both
    /// `app` and `launchBundleID` are nil. `nil` → nothing to open.
    var openURL: String?

    /// Accent for the icon chip and hover affordance. `nil` → falls back to the
    /// associated app's tint, then a neutral grey.
    var accent: Color?

    /// Auto-dismiss after this many seconds. `nil` → stays until the user acts.
    var autoDismissAfter: TimeInterval?

    init(id: String = UUID().uuidString,
         style: Style = .banner,
         title: String,
         message: String,
         icon: Icon,
         app: IslandApp? = nil,
         launchBundleID: String? = nil,
         openURL: String? = nil,
         accent: Color? = nil,
         autoDismissAfter: TimeInterval? = nil) {
        self.id = id
        self.style = style
        self.title = title
        self.message = message
        self.icon = icon
        self.app = app
        self.launchBundleID = launchBundleID
        self.openURL = openURL
        self.accent = accent
        self.autoDismissAfter = autoDismissAfter
    }

    /// The leading glyph for a popup.
    enum Icon: Equatable {
        /// An SF Symbol name.
        case symbol(String)
        /// Reuse an island app's glyph + tint.
        case app(IslandApp)
        /// The real icon of an installed macOS app, by bundle id. Used for
        /// mirrored system notifications so each banner wears its sender's icon.
        case bundle(String)
    }
}
