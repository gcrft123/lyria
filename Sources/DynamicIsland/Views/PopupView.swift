import SwiftUI

/// The notification / live-activity layout shown when a popup takes over the
/// island (`IslandMode.popup`): a leading icon chip, a bold title, and a
/// message, with a chevron hinting it's tappable.
///
/// The whole island is the hit target — left/right clicks are handled at the
/// window-controller level (left = open the app / dismiss, right = dismiss), so
/// this view is purely visual.
struct PopupView: View {
    let popup: IslandPopup
    /// Whether the pointer is hovering. The island has already grown a little
    /// (geometry); we brighten the chevron to reinforce that a click will act.
    let hovered: Bool

    private var accent: Color {
        popup.accent ?? popup.app?.tint ?? AppSettings.neutralAccent
    }

    var body: some View {
        HStack(spacing: Spacing.xl) {
            iconChip
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(popup.title)
                    .font(Typography.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(popup.message)
                    .font(Typography.bodyRegular)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.xs)
            chevron
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var iconChip: some View {
        switch popup.icon {
        case .bundle(let bundleID):
            // Mirrored system notification: show the sender app's real icon,
            // inset in the chip. Falls back to a generic bell if the app's
            // icon can't be resolved (uninstalled / sandbox-hidden).
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(Palette.surfaceSubtle)
                .frame(width: 44, height: 44)
                .overlay {
                    if let icon = Self.appIcon(for: bundleID) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 34, height: 34)
                    } else {
                        Image(systemName: "bell.fill")
                            .font(.system(size: IconSize.xl, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }
        case .symbol, .app:
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(accent.opacity(0.22))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: symbolName)
                        .font(.system(size: IconSize.xl, weight: .semibold))
                        .foregroundStyle(accent)
                )
        }
    }

    /// A chevron that brightens on hover, hinting the popup is clickable.
    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: IconSize.md, weight: .bold))
            .foregroundStyle(hovered ? Palette.textSecondary : Palette.textFaint)
    }

    private var symbolName: String {
        switch popup.icon {
        case .symbol(let name): return name
        case .app(let app): return app.icon
        case .bundle: return "bell.fill" // unused (handled above), keeps switch total
        }
    }

    /// Resolve an installed app's icon from its bundle id. Returns nil when the
    /// app can't be found so the chip can fall back to a glyph.
    private static func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
