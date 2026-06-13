import SwiftUI

/// App-wide typography scale.
///
/// Use these named roles instead of ad-hoc `.font(.system(size:weight:))` so
/// text stays consistent and legible across the island. The smallest role is
/// **11pt** — the readable floor. Nothing in the UI should go below it; if a
/// label feels like it needs to, make the container bigger instead of shrinking
/// the text.
///
/// Roles are ordered largest → smallest. Each bakes in a default weight; when a
/// site needs a different weight for the *same* size (e.g. bolding "today"),
/// keep the role and override with `.fontWeight(_:)` rather than reaching for a
/// raw size. For aligned/live numerals use the `…Mono` variants (or chain
/// `.monospacedDigit()` onto any role).
enum Typography {
    // MARK: Display & titles
    /// 30 / semibold — the timer's big countdown digits.
    static let display     = Font.system(size: 30, weight: .semibold)
    /// 20 / semibold — prominent standalone values (volume %, big counts).
    static let titleLarge  = Font.system(size: 20, weight: .semibold)
    /// 17 / semibold — the primary screen / app title.
    static let title       = Font.system(size: 17, weight: .semibold)
    /// 16 / semibold — secondary title / prominent row heading.
    static let title2      = Font.system(size: 16, weight: .semibold)
    /// 15 / semibold — section headers, player track title.
    static let headline    = Font.system(size: 15, weight: .semibold)
    /// 14 / semibold — sub-section headers, segmented-control labels.
    static let subheadline = Font.system(size: 14, weight: .semibold)

    // MARK: Body
    /// 13 / semibold — emphasized primary row label.
    static let bodyStrong  = Font.system(size: 13, weight: .semibold)
    /// 13 / medium — standard primary text (the default body role).
    static let body        = Font.system(size: 13, weight: .medium)
    /// 13 / regular — relaxed body / longer-form text.
    static let bodyRegular = Font.system(size: 13, weight: .regular)

    // MARK: Small / supporting (11pt floor)
    /// 12 / semibold — strong small label (pills, eyebrows, chips).
    static let calloutStrong = Font.system(size: 12, weight: .semibold)
    /// 12 / medium — secondary text & metadata.
    static let callout       = Font.system(size: 12, weight: .medium)
    /// 11 / semibold — the smallest emphasized label (captions, tags).
    static let caption       = Font.system(size: 11, weight: .semibold)
    /// 11 / medium — the smallest standard label. This is the readable floor.
    static let footnote      = Font.system(size: 11, weight: .medium)

    // MARK: Monospaced-digit variants (live clocks, time ranges, counts)
    static let displayMono = display.monospacedDigit()
    static let title2Mono  = title2.monospacedDigit()
    static let headlineMono = headline.monospacedDigit()
    static let bodyMono    = bodyStrong.monospacedDigit()
    static let calloutMono = calloutStrong.monospacedDigit()
    static let captionMono = caption.monospacedDigit()
    static let footnoteMono = footnote.monospacedDigit()
}
