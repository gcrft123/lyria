import SwiftUI

/// A `.liveActivity`-style popup that ISN'T backed by an island app — a compact
/// center-island status pill for system events (battery / Wi-Fi / Bluetooth /
/// Focus). A leading accent glyph, a title + short value, and a chevron when a
/// left-click does something (e.g. opens System Settings).
///
/// Clicks are handled at the window-controller level (left opens / dismisses,
/// right dismisses), so this view is purely visual.
struct StatusActivityView: View {
    let popup: IslandPopup
    /// Whether the pointer is hovering (the pill has already grown a touch).
    let hovered: Bool

    private var accent: Color { popup.accent ?? popup.app?.tint ?? AppSettings.neutralAccent }
    /// A left-click only shows the chevron when it actually opens something.
    private var hasAction: Bool {
        popup.app != nil || popup.launchBundleID != nil || popup.openURL != nil
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle().fill(accent.opacity(0.22)).frame(width: 30, height: 30)
                Image(systemName: symbolName)
                    .font(.system(size: IconSize.md, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(popup.title)
                    .font(Typography.calloutStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if !popup.message.isEmpty {
                    Text(popup.message)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.sm)
            if hasAction {
                Image(systemName: "chevron.right")
                    .font(.system(size: IconSize.sm, weight: .bold))
                    .foregroundStyle(hovered ? Palette.textSecondary : Palette.textFaint)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbolName: String {
        switch popup.icon {
        case .symbol(let name): return name
        case .app(let app): return app.icon
        case .bundle: return "bell.fill"
        }
    }
}
