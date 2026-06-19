import SwiftUI

/// The morphing liquid-glass tab pill at the top of the Music app.
///   • Now Playing active → three text labels (active one highlighted).
///   • Search / Library active → the active tab expands into a search field and the
///     other two collapse into icon buttons.
struct MusicTabBar: View {
    @Binding var tab: MusicTab
    @Binding var query: String
    @ObservedObject var controller: DynamicIslandController

    @FocusState private var searchFocused: Bool
    @Namespace private var highlight

    private var accent: Color {
        controller.nowPlaying.map { controller.settings.accent(for: $0) } ?? Palette.neutralAccent
    }

    var body: some View {
        // The glass sits on its OWN stable layer (constant identity, never
        // animated): when it shared the animated content's layer, morphing into the
        // Now Playing labels dropped the Liquid Glass for a frame until the next
        // render. Only the slot content animates.
        ZStack {
            GlassPill()
            HStack(spacing: Spacing.xs) {
                ForEach(MusicTab.allCases) { slot($0) }
            }
            .padding(Spacing.xs)
            .animation(Motion.transition, value: tab)
        }
        .frame(height: 38)
        .onChange(of: tab) { syncEditing($0) }
        .onAppear { syncEditing(tab) }
        .onDisappear { controller.endEditing() }
    }

    /// Each tab renders as a label (Now Playing mode), an expanded search field (the
    /// active browse tab), or an icon (an inactive tab while browsing).
    @ViewBuilder
    private func slot(_ t: MusicTab) -> some View {
        if t != .nowPlaying, t == tab {
            searchField(t).frame(maxWidth: .infinity)
        } else if tab == .nowPlaying {
            label(t).frame(maxWidth: .infinity)
        } else {
            icon(t)
        }
    }

    private func label(_ t: MusicTab) -> some View {
        let active = (t == tab)
        return Button { tab = t } label: {
            Text(t.title)
                .font(Typography.caption)
                .foregroundStyle(active ? Palette.onAccent : Palette.textHigh)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background {
                    if active {
                        Capsule().fill(accent).matchedGeometryEffect(id: "tabHighlight", in: highlight)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.island)
    }

    private func icon(_ t: MusicTab) -> some View {
        Button { tab = t } label: {
            Image(systemName: t.icon)
                .font(.system(size: IconSize.md, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 38, height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.island)
    }

    private func searchField(_ t: MusicTab) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: IconSize.sm, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            TextField(t.searchPrompt, text: $query)
                .textFieldStyle(.plain)
                .font(Typography.callout)
                .foregroundStyle(Palette.textPrimary)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: IconSize.sm))
                        .foregroundStyle(Palette.textTertiary)
                        .contentShape(Circle())
                }
                .buttonStyle(.island)
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: 30)
        .background(Capsule().fill(Palette.surfaceStrong))
        .contentShape(Capsule())
    }

    /// Begin/end panel keyboard editing as the active tab gains/loses its search
    /// field (so the island stays open while typing — mirrors `TimerExpandedView`).
    private func syncEditing(_ t: MusicTab) {
        if t == .nowPlaying {
            controller.endEditing()
            searchFocused = false
        } else {
            controller.beginEditing()
            DispatchQueue.main.async { searchFocused = true }
        }
    }
}
