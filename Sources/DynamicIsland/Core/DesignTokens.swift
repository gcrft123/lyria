import SwiftUI

// =============================================================================
//  Design tokens — the SINGLE SOURCE OF TRUTH for spacing, radius, color, motion,
//  icon sizing, and elevation. See DESIGN_GUIDELINES.md for the rules.
//
//  HARD RULE: views MUST use these tokens (and `Typography`) instead of raw
//  literals. No ad-hoc `.padding(7)`, `.cornerRadius(9)`, `.white.opacity(0.42)`,
//  `Color(red:…)`, or `.spring(response:…)` in view code.
//
//  The only sanctioned raw numbers in views are:
//    • SF Symbol point sizes (use `IconSize`), and
//    • precise layout geometry that lives in `IslandConfiguration`.
// =============================================================================

// MARK: - Spacing

/// The spacing/padding scale (points). Everything that separates or insets
/// content MUST come from here. Ramp: 1 · 2 · 4 · 6 · 8 · 10 · 12 · 16 · 20 · 24.
enum Spacing {
    /// 0pt — explicit "no gutter" (e.g. a view that manages its own margins).
    static let zero: CGFloat = 0
    /// 1pt — hairline gaps only (e.g. a divider's own thickness). Avoid for layout.
    static let hairline: CGFloat = 1
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 16
    static let xxxl: CGFloat = 20
    static let xxxxl: CGFloat = 24
}

// MARK: - Radius

/// Corner-radius scale (points). Continuous ("squircle") curve is the default for
/// rectangles ≥ `md`; use `Capsule()` for fully-rounded pills, not a huge radius.
enum Radius {
    static let xs: CGFloat = 2     // ticks, tiny chips
    static let sm: CGFloat = 4     // small inner elements
    static let md: CGFloat = 8     // chips, buttons, small cards
    static let lg: CGFloat = 12    // standard cards / list rows
    static let xl: CGFloat = 16    // large panels / stage box
    static let popup: CGFloat = 28 // the popup/HUD shell
    static let shell: CGFloat = 36 // the expanded island shell
}

// MARK: - Palette

/// Every color in the UI. The island paints on black, so foreground colors are
/// white at fixed opacities (the "ramp"), surfaces/strokes are translucent white,
/// and hues come from the named accents / per-app tints — never raw `Color(red:…)`.
enum Palette {
    // Base
    static let background = Color.black

    // Text / foreground ramp (opacity of white)
    static let textPrimary = Color.white                  // 1.00 — titles, key values
    static let textHigh = Color.white.opacity(0.85)       // 0.85 — strong secondary
    static let textSecondary = Color.white.opacity(0.60)  // 0.60 — labels, metadata
    static let textTertiary = Color.white.opacity(0.40)   // 0.40 — captions, hints
    static let textFaint = Color.white.opacity(0.28)      // 0.28 — disabled / decorative

    // Surfaces (translucent white fills on black)
    static let surfaceSubtle = Color.white.opacity(0.05)  // resting card/row fill
    static let surface = Color.white.opacity(0.08)        // default control fill
    static let surfaceRaised = Color.white.opacity(0.12)  // hover / emphasized fill
    static let surfaceStrong = Color.white.opacity(0.16)  // pressed / track fill

    // Strokes / separators
    static let hairlineStroke = Color.white.opacity(0.10) // 1pt dividers
    static let stroke = Color.white.opacity(0.12)         // resting borders
    static let strokeStrong = Color.white.opacity(0.20)   // hover / focused borders

    // Elevation
    static let shadow = Color.black.opacity(0.32)         // standard drop shadow

    // Named accents (the only hues allowed; consolidate, don't invent new ones)
    static let blue = Color(red: 0.30, green: 0.60, blue: 1.00)
    static let cyan = Color(red: 0.30, green: 0.80, blue: 0.92)
    static let teal = Color(red: 0.35, green: 0.82, blue: 0.80)
    static let green = Color(red: 0.32, green: 0.85, blue: 0.45)
    static let indigo = Color(red: 0.62, green: 0.55, blue: 0.98)
    static let purple = Color(red: 0.70, green: 0.42, blue: 0.95)
    static let pink = Color(red: 0.95, green: 0.30, blue: 0.55)
    static let red = Color(red: 0.98, green: 0.36, blue: 0.34)
    static let orange = Color(red: 0.98, green: 0.58, blue: 0.30)
    static let amber = Color(red: 1.00, green: 0.74, blue: 0.30)

    /// Text/glyphs drawn ON a filled accent (e.g. a selected pill). Accents are
    /// light, so this is black.
    static let onAccent = Color.black

    // Semantic accents
    static let favorite = Color(red: 1.00, green: 0.27, blue: 0.38) // heart
    static let recording = orange                                   // camera/mic
    static let positive = green
    static let danger = red
    static let alarm = Color(red: 1.00, green: 0.27, blue: 0.23)    // fired/ringing timer

    /// Music's fallback accent when artwork tinting is off (neutral, near-white).
    static let neutralAccent = Color(white: 0.82)

    // Per-app tints (one hue per app; referenced by `IslandApp.tint`).
    static let tintCalendar = red
    static let tintDashboard = indigo
    static let tintTimers = cyan
    static let tintWeather = blue
    static let tintTweaks = green
}

// MARK: - Motion

/// The standard animation curves. All UI motion MUST use a `Motion` spring so
/// timing/feel stays consistent (and overlapping interactions settle naturally).
/// Each token maps to ONE kind of element/interaction — see the "Animation
/// standards by element" table in DESIGN_GUIDELINES.md.
enum Motion {
    // — Controls & interaction —
    /// Hover swell / highlight fade on controls, rows, chips, icons.
    static let hover = Animation.spring(response: 0.30, dampingFraction: 0.66)
    /// Press dip — snappier than hover so taps feel tactile.
    static let press = Animation.spring(response: 0.24, dampingFraction: 0.55)

    // — Navigation inside a screen —
    /// Page / tab / detail push within an app (e.g. Tweaks list ↔ detail).
    static let transition = Animation.spring(response: 0.34, dampingFraction: 0.86)

    // — The island shell —
    /// The silhouette + size morph when the island expands/collapses. Snappy with a
    /// touch of overshoot — fast enough that open/close feels immediate, not laggy.
    static let morph = Animation.spring(response: 0.30, dampingFraction: 0.80)
    /// The app/content cross-fade INSIDE the shell. Smooth and near-simultaneous with
    /// the silhouette (no perceptible trailing delay that reads as lag).
    static let contentMorph = Animation.spring(response: 0.26, dampingFraction: 0.90)
    /// Side islands / edge extensions / secondary islands sliding alongside.
    static let side = Animation.spring(response: 0.44, dampingFraction: 0.78)

    // — Overlays —
    /// Popups / banners / HUD presenting and dismissing.
    static let popup = Animation.spring(response: 0.30, dampingFraction: 0.85)

    // — Emphasis & ambient —
    /// Celebratory pops / selection emphasis (bouncy).
    static let pop = Animation.spring(response: 0.32, dampingFraction: 0.60)
    /// Gentle, slow settle for large/ambient value changes.
    static let gentle = Animation.spring(response: 0.45, dampingFraction: 0.85)

    /// Accessibility "Reduce Motion" fallback: a plain cross-fade with no spring
    /// overshoot. Substitute for any of the above when reduce-motion is on.
    static let reduced = Animation.easeInOut(duration: 0.3)
}

/// Standard `AnyTransition`s for views that insert/remove. Pair each with the
/// matching `Motion` curve (see the doc).
enum Transitions {
    /// A detail page pushing in from the trailing edge (Motion.transition).
    static let detailPush = AnyTransition.move(edge: .trailing).combined(with: .opacity)
    /// The list returning from the leading edge (Motion.transition).
    static let listReturn = AnyTransition.move(edge: .leading).combined(with: .opacity)
    /// A popup/banner dropping from the top of the island (Motion.popup).
    static let popup = AnyTransition.scale(scale: 0.9, anchor: .top).combined(with: .opacity)
    /// A plain cross-fade for content swaps (Motion.contentMorph / .transition).
    static let fade = AnyTransition.opacity
}

// MARK: - IconSize

/// SF Symbol point sizes. Symbols are the one place raw `.system(size:)` is
/// allowed — but the size MUST come from this scale.
enum IconSize {
    static let xs: CGFloat = 9
    static let sm: CGFloat = 11
    static let md: CGFloat = 13
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 30
}

// MARK: - Layout (position, vertical rhythm & control metrics)

/// Standard POSITIONS inside the expanded shell, the vertical RHYTHM between
/// text/element roles, and CONTROL metrics (hit targets, icon-button sizes).
///
/// This exists so the same kind of element always sits the same distance from
/// the same reference, and so a primary app view can be reasoned about as a
/// fixed stack that FILLS the standard card height (see DESIGN_GUIDELINES.md §9
/// "Layout, position & vertical rhythm" — the rule that prevents the recurring
/// "compressed UI" bug). Views MUST express insets/positions with these tokens;
/// the per-card window geometry (the card's own width/height) still lives in
/// `IslandConfiguration`.
enum Layout {
    // — Content insets inside the expanded card (mirror the card's own margins) —
    /// Shell top → first element (eyebrow / app title / first row).
    static let insetTop: CGFloat = 28
    /// Shell side → content (left & right gutter).
    static let insetH: CGFloat = 18
    /// Last element → shell bottom.
    static let insetBottom: CGFloat = 28

    // — Vertical rhythm between roles (top-of-element → top-of-next) —
    /// App/screen title (or eyebrow) → first primary row beneath it.
    static let titleToContent: CGFloat = 16
    /// Between two sections of a page.
    static let sectionGap: CGFloat = 20
    /// Between rows within a list.
    static let rowGap: CGFloat = 10
    /// A primary label → its own sub-label (e.g. title over artist).
    static let labelGap: CGFloat = 2

    // — Standard element heights —
    /// An eyebrow / section-header row.
    static let headerHeight: CGFloat = 24
    /// A standard tappable list / menu / toggle / picker row.
    static let listRowHeight: CGFloat = 44
    /// A list→detail category navigation row (a touch taller, more presence).
    static let navRowHeight: CGFloat = 48

    // — Control metrics (hit targets) —
    /// The minimum tappable square for ANY control.
    static let hitTargetMin: CGFloat = 28
    /// The standard icon-button background circle/rect.
    static let iconButton: CGFloat = 30
    /// A compact icon-button background (dense rows / sidebars).
    static let iconButtonCompact: CGFloat = 24

    // — Onboarding (the first-launch takeover card) —
    /// Width of the onboarding card that grows out of the notch.
    static let onboardingWidth: CGFloat = 472
    /// Resting content height for a text/permission act (grows for the trailer).
    static let onboardingHeight: CGFloat = 284
    /// Taller height for the trailer / personalize acts with a live preview.
    static let onboardingTallHeight: CGFloat = 372
    /// The live-preview tile (mini island vignette) inside the card.
    static let onboardingPreview: CGFloat = 128
    /// The tiny "waking" pill the card grows out of in Act 0.
    static let onboardingSeedWidth: CGFloat = 210
    static let onboardingSeedHeight: CGFloat = 48
}

// MARK: - Elevation (shadows)

/// Standard drop shadows. Use these instead of ad-hoc `.shadow(...)`.
extension View {
    /// The island shell's shadow.
    func shellShadow() -> some View {
        shadow(color: Palette.shadow, radius: 13, y: 6)
    }
    /// A small lift for floating controls (knobs, popovers).
    func raisedShadow() -> some View {
        shadow(color: Color.black.opacity(0.30), radius: 3, y: 1)
    }
}
