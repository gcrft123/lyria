import SwiftUI

/// The icon column down the left of every expanded app. Tapping an app icon
/// pins that app into the main island; the current one is highlighted, and
/// active apps carry a small dot so you can tell what's running at a glance. A
/// gear icon pinned to the BOTTOM opens the settings page (it's treated like an
/// app in the sidebar, but kept out of the scroll-to-switch rotation).
struct AppSidebarView: View {
    @ObservedObject var controller: DynamicIslandController
    /// The app currently filling the main island.
    var selected: IslandApp

    /// Lets the selection highlight slide between icons instead of cross-fading.
    @Namespace private var highlight

    private var config: IslandConfiguration { controller.configuration }

    /// When the settings page is up, the gear is lit and no app icon is.
    private var settingsActive: Bool { controller.isShowingSettings }

    private var accentColor: Color {
        controller.nowPlaying.map { controller.settings.accent(for: $0) } ?? AppSettings.neutralAccent
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            ForEach(IslandApp.allCases.sorted { $0.sidebarOrder < $1.sidebarOrder }) { app in
                iconButton(app)
            }
            Spacer(minLength: 0)
            // Settings lives at the bottom, set apart from the app list.
            settingsButton
        }
        .padding(.vertical, Spacing.xxl)
        .frame(width: config.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Palette.hairlineStroke)
                .frame(width: 1)
        }
        // Slide the highlight (and ease the icon tint) as the pick — or the
        // settings page — changes.
        .animation(Motion.hover, value: selected)
        .animation(Motion.hover, value: settingsActive)
    }

    private func iconButton(_ app: IslandApp) -> some View {
        // An app icon is only lit when it's the pick AND settings isn't showing.
        let isSelected = app == selected && !settingsActive
        let isActive = controller.activeApps.contains(app)
        return Button {
            controller.selectApp(app)
        } label: {
            iconLabel(app.icon, lit: isSelected, highlighted: isSelected)
                .overlay(alignment: .topTrailing) {
                    if isActive {
                        Circle()
                            .fill(app == .music ? accentColor : app.tint)
                            .frame(width: 5, height: 5)
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.island)
    }

    private var settingsButton: some View {
        Button {
            controller.toggleSettings()
        } label: {
            iconLabel("gearshape.fill", lit: settingsActive, highlighted: settingsActive)
        }
        .buttonStyle(.island)
    }

    /// A sidebar glyph with the optional shared highlight pill. `highlighted`
    /// hosts the single `matchedGeometryEffect` pill, so it flies between
    /// whichever app icon — or the gear — is currently selected.
    private func iconLabel(_ systemName: String, lit: Bool, highlighted: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: IconSize.lg, weight: .semibold))
            .foregroundStyle(lit ? Palette.textPrimary : Palette.textTertiary)
            .frame(width: 32, height: 32)
            .background(
                ZStack {
                    if highlighted {
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(accentColor.opacity(0.22))
                            .matchedGeometryEffect(id: "sidebarHighlight", in: highlight)
                    }
                }
            )
            .contentShape(Rectangle())
    }
}
