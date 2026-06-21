import AppKit

/// Static geometry and window-behaviour settings for the island.
///
/// These values describe the *collapsed* resting appearance and where the
/// panel lives on screen. Per-state sizing (expanded, notification, etc.) is
/// derived at runtime in `IslandState`.
struct IslandConfiguration {

    // MARK: Collapsed geometry

    /// Width of the resting pill, in points.
    var collapsedWidth: CGFloat = 200

    /// Height of the resting pill, in points.
    var collapsedHeight: CGFloat = 36

    // MARK: Now-playing geometry

    /// Compact now-playing pill (artwork · title/artist · bars).
    var compactWidth: CGFloat = 360
    var compactHeight: CGFloat = 44

    /// The standardized expanded-card *content* width (the app area, right of the
    /// sidebar) that EVERY app uses — set to the Calendar grid's width so all
    /// apps share one window size and the morph between them is a pure height
    /// change. `expandedHeight` is the resting height (no volume bar);
    /// `expandedVolumeHeight` is the taller height once the volume bar is
    /// revealed. The card grows downward, so the upper rows stay put.
    var expandedWidth: CGFloat = 508
    // STANDARD EXPANDED HEIGHT = 324 (Calendar's natural grid height). Every
    // primary app (Music, Timers, Calendar, Weather, Settings) uses this same card
    // height so switching between them in the sidebar is a PURE cross-fade with NO
    // height change — the window's proportional size stays consistent. 324 was
    // chosen because Calendar's month grid needs ≈324 and can't shrink; the
    // flexible apps meet it (Music scaled UP, Weather/Settings down, their overflow
    // scrolls). The music player's rows are scaled to fill 324 exactly —
    // `expandedHeight` MUST equal the summed rows + gaps + margins (the VStack pins
    // to `.top`, so a mismatch leaves a bottom void): 68+37+47+38 rows + 3·26 gaps +
    // 2·28 margins = 324; volume adds one row+gap (22+26) → 372.
    var expandedHeight: CGFloat = 324
    var expandedVolumeHeight: CGFloat = 372
    var expandedCornerRadius: CGFloat = 36

    /// The icon sidebar that runs down the left of every expanded app, letting
    /// the user switch which app fills the main island. The expanded card grows
    /// leftward by this width; `expandedTotalWidth` is the full card width.
    var sidebarWidth: CGFloat = 52
    var expandedTotalWidth: CGFloat { sidebarWidth + expandedWidth }

    /// The Music app's queue ("Up Next") sidebar carves its width out of the
    /// SHARED `expandedWidth` — the card stays the standard size; the player is just
    /// compressed to `musicPlayerWidth` on the left to make room (its UI is simple
    /// with lots of negative space). A 1px divider sits between them.
    var musicQueueWidth: CGFloat = 196
    var musicPlayerWidth: CGFloat { expandedWidth - musicQueueWidth }

    // Expanded layout metrics. Kept here (not just in the view) so the window
    // controller can compute the volume hover zones from the same numbers.
    var expandedHMargin: CGFloat = 18
    var expandedVMargin: CGFloat = 28
    var expandedRowSpacing: CGFloat = 26
    var topRowHeight: CGFloat = 68
    var progressRowHeight: CGFloat = 37
    var transportRowHeight: CGFloat = 47
    var volumeRowHeight: CGFloat = 22
    var bottomRowHeight: CGFloat = 38

    // MARK: Timers app geometry

    /// Compact timer pill (icon · name · live value) shown when Timers is the
    /// top app and the island isn't hovered.
    var timerCompactWidth: CGFloat = 260

    /// Expanded timers card. Height = base (header + create row) plus a row per
    /// visible timer, up to `timersMaxRows` (beyond which the list scrolls).
    // Sized so a full 3-timer list fills the STANDARD page (116 + 3·64 + 2·8 =
    // 324), and the floor (`max(content, expandedHeight)` in the controller) keeps
    // the empty / few-timer states at that same 324 so Timers matches every other app.
    var timersBaseHeight: CGFloat = 116
    var timerRowHeight: CGFloat = 64
    var timersRowSpacing: CGFloat = 8
    var timersMaxRows: Int = 3
    /// Extra height added while the countdown creator is open.
    var timerCreatorHeight: CGFloat = 86

    // MARK: Calendar app geometry

    /// Compact calendar pill (circular countdown ring · event title · "in N min")
    /// shown while an event is imminent and the island isn't hovered.
    var calendarCompactWidth: CGFloat = 280

    /// Expanded calendar card height — this IS the STANDARD 324 (see
    /// `expandedHeight`); Calendar's month grid sets the standard, every other app
    /// matches it, so switching doesn't resize the window.
    var calendarExpandedHeight: CGFloat = 324

    /// Width of the Month/Day left pane (the grid / day list) and of the
    /// Month·Week·Day segmented switcher in the top bar.
    var calendarGridWidth: CGFloat = 262
    var calendarModeSwitcherWidth: CGFloat = 178

    // MARK: Weather app geometry

    /// Compact weather pill (condition glyph · temp · short condition · place)
    /// shown when Weather is the displayed app and the island isn't hovered.
    var weatherCompactWidth: CGFloat = 300

    /// Expanded weather card height. Width is the shared `expandedWidth`. The card
    /// keeps the island's black background (like every other app); the animation
    /// lives in a contained hero banner. Tall enough for that hero (animated sky +
    /// big temp + inline stats), the hourly strip, and the start of the 7-day list
    /// (which scrolls). Kept compact.
    var weatherExpandedHeight: CGFloat = 324

    // MARK: Dashboard app geometry

    /// Compact dashboard pill (only reachable via `DI_FORCE_APP=dashboard` —
    /// Dashboard isn't auto-active, it's the expanded "home", so this rarely shows).
    var dashboardCompactWidth: CGFloat = 320

    /// Expanded dashboard card height — the shared standard, so the dashboard is the
    /// same height as every other app (a pure cross-fade when switching). The
    /// layout is compressed to fit; `DI_DASH_PROTO=1…4` selects a layout variant.
    var dashboardExpandedHeight: CGFloat = 324

    // MARK: Calculator app geometry

    /// Compact calculator pill (only via `DI_FORCE_APP=calculator` — Calculator
    /// isn't auto-active; it's reached from the sidebar). Shows the live value.
    var calculatorCompactWidth: CGFloat = 300

    /// Expanded calculator card height — the shared STANDARD 324, so switching to it
    /// from any other app is a pure cross-fade with no resize.
    var calculatorExpandedHeight: CGFloat = 324

    /// Width of the history sidebar, carved out of the shared `expandedWidth` (the
    /// keypad fills the remainder, with a 1px divider between).
    var calculatorHistoryWidth: CGFloat = 188

    // MARK: Settings card geometry

    /// The settings page, opened from the gear in the sidebar. Matches the
    /// STANDARD 324 (see `expandedHeight`) so opening settings is a pure cross-fade
    /// with no resize; its content scrolls if it needs more room.
    var settingsHeight: CGFloat = 324

    /// The Settings → Tweaks → "EQ & Spatial" sub-page needs real vertical room
    /// (presets row + 5-band sliders + pan, or the spatial stage); the standard 324
    /// visibly compresses it, so that page alone grows the settings card to this
    /// height (the controller picks it when `appVolumeStore.eqPageActive`).
    var tweaksEQHeight: CGFloat = 416

    // MARK: Popup (notification / live-activity) geometry

    /// A popup temporarily takes over the main island. It's a little larger than
    /// the compact pill ("expand it a little"), and grows a touch more on hover
    /// to signal it's clickable. Corner radius sits between the compact pill and
    /// the expanded card.
    var popupWidth: CGFloat = 372
    var popupHeight: CGFloat = 96
    var popupHoveredWidth: CGFloat = 384
    var popupHoveredHeight: CGFloat = 104
    var popupCornerRadius: CGFloat = 28

    /// A `.liveActivity`-style popup (weather change / imminent calendar event): the
    /// compact center-island pill, grown a touch on hover to signal it's clickable.
    var liveActivityPopupWidth: CGFloat = 360
    var liveActivityPopupHeight: CGFloat = 44
    var liveActivityPopupHoveredWidth: CGFloat = 376
    var liveActivityPopupHoveredHeight: CGFloat = 50

    // MARK: System HUD (volume / brightness) geometry

    /// The transient volume/brightness HUD that replaces the system overlay: a
    /// slim pill (icon + bar) a touch larger than the compact now-playing pill.
    /// Rendered fully rounded (corner radius = height/2), like the iPhone's.
    var hudWidth: CGFloat = 372
    var hudHeight: CGFloat = 46

    /// A transient compact live activity (e.g. the onboarding hint) — a pill at
    /// the compact bar height, like the weather flash.
    var liveActivityWidth: CGFloat = 300

    /// Gap between the very top of the display and the top of the pill.
    ///
    /// Applied as padding *inside* the (flush-to-top) panel, so the island
    /// floats a little below the edge — like the iPhone's — and its drop
    /// shadow has room to render instead of being clipped by the screen edge.
    /// Set to `0` to sit perfectly flush.
    var topInset: CGFloat = 10

    // MARK: Panel canvas

    /// The hosting panel is larger than the pill so that expanded states, the
    /// secondary side islands, and drop shadows all have room to draw without
    /// resizing the window (resizing a borderless panel mid-animation is visibly
    /// janky). Wide enough for the expanded card (sidebar + content) plus a
    /// couple of secondary islands and the camera/mic indicator to its right.
    var canvasWidth: CGFloat = 920
    var canvasHeight: CGFloat = 440

    /// Gaps between the island (or the previous extension) and a side
    /// extension. `attached` blobs sit almost flush; `detached` ones float with
    /// a visible separation.
    var extensionAttachedGap: CGFloat = 3
    var extensionDetachedGap: CGFloat = 8

    // MARK: Window behaviour

    /// Stacking level for the panel. `.statusBar` (25) sits just above the
    /// menu bar (24) so the island overlays the notch area without covering
    /// alerts or the screen saver.
    var windowLevel: NSWindow.Level = .statusBar

    /// Whether the island should remain visible on every Space and over
    /// full-screen apps.
    var showsOnAllSpaces: Bool = true

    /// When `true`, the panel passes all mouse events through to whatever is
    /// beneath it, so the island is purely decorative and never gets in the
    /// way. The hover/expand integration sets this to `false` (and adds
    /// hit-testing) when it is built; until then the view's hover/click seams
    /// exist but receive no events.
    var clickThrough: Bool = true

    static let `default` = IslandConfiguration()
}
