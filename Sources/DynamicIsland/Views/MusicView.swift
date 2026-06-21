import SwiftUI

/// The three top-level Music tabs.
enum MusicTab: String, CaseIterable, Identifiable {
    case nowPlaying, search, library
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .search: return "Search"
        case .library: return "Library"
        }
    }
    var icon: String {
        switch self {
        case .nowPlaying: return "waveform"
        case .search: return "magnifyingglass"
        case .library: return "square.stack.fill"
        }
    }
    /// Placeholder for the inline search field (search / library tabs only).
    var searchPrompt: String {
        switch self {
        case .search: return "Find a song…"
        case .library: return "Find in library…"
        case .nowPlaying: return ""
        }
    }
    /// `DI_MUSIC_TAB=search|library|nowplaying` opens a tab directly (screenshots).
    static func fromEnv(_ v: String?) -> MusicTab? {
        switch v {
        case "search": return .search
        case "library", "lib": return .library
        case "nowplaying", "now": return .nowPlaying
        default: return nil
        }
    }
}

/// The Music app shell: a morphing liquid-glass tab bar over the active tab's
/// content (Now Playing player + Up Next, Search, or Library). On the browse tabs
/// the player shrinks to a floating glass mini-pill docked at the bottom; tapping
/// it returns to Now Playing.
struct MusicView: View {
    @ObservedObject var controller: DynamicIslandController
    /// Observed so the persisted nav state (tab / field / pushed pages) drives the UI.
    @ObservedObject var store: MusicLibraryStore

    init(controller: DynamicIslandController) {
        _controller = ObservedObject(wrappedValue: controller)
        _store = ObservedObject(wrappedValue: controller.musicLibrary)
    }

    private var config: IslandConfiguration { controller.configuration }
    private var accent: Color {
        controller.nowPlaying.map { controller.settings.accent(for: $0) } ?? Palette.neutralAccent
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            MusicTabBar(tab: $store.tab, query: $store.fieldText, controller: controller)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.md)

            ZStack(alignment: .bottom) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // The shrunken player, docked at the bottom on the browse tabs.
                if store.tab != .nowPlaying, controller.nowPlaying != nil {
                    MiniPlayerPill(controller: controller) { store.tab = .nowPlaying }
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.md)
                        .transition(.move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.morph, value: store.tab)
        .animation(Motion.transition, value: store.detail?.id)
        .animation(Motion.transition, value: store.seeAll?.id)
        .onAppear { store.loadIfNeeded() }
        .onChange(of: store.tab) { newTab in
            store.detail = nil; store.seeAll = nil
            // The volume row only lives in Now Playing — collapse it elsewhere so the
            // card height doesn't get stuck taller on the browse tabs.
            if newTab != .nowPlaying { controller.setVolumeRevealed(false) }
            // Each browse tab starts with a fresh field (Search and Library are independent).
            store.clearSearch(); store.fieldText = ""
        }
        .onChange(of: store.fieldText) { q in
            // Typing in either browse field returns to its list; Search also hits the
            // store, while Library just filters its loaded lists client-side via `q`.
            guard store.tab != .nowPlaying else { return }
            store.detail = nil; store.seeAll = nil
            if store.tab == .search { store.search(q) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let detail = store.detail {
            MusicCollectionDetailView(store: store, collection: detail, accent: accent,
                                      onBack: { store.detail = nil }, onGoToAlbum: goToAlbum)
        } else if let seeAll = store.seeAll {
            MusicSeeAllView(store: store, data: seeAll, accent: accent,
                            onBack: { store.seeAll = nil }, openCollection: open, goToAlbum: goToAlbum)
        } else {
            switch store.tab {
            case .nowPlaying:
                nowPlaying
            case .search:
                MusicSearchView(store: store, accent: accent, openCollection: open,
                                goToAlbum: goToAlbum, seeAll: { store.seeAll = $0 })
            case .library:
                MusicLibraryView(store: store, accent: accent, filter: store.fieldText, openCollection: open,
                                 goToAlbum: goToAlbum, seeAll: { store.seeAll = $0 })
            }
        }
    }

    private func open(_ collection: MusicCollection) {
        store.seeAll = nil
        store.detail = collection
    }

    /// "Go to Album" from a song → its album detail (looked up in the loaded library).
    private func goToAlbum(_ song: MusicSong) {
        if let album = store.albums.first(where: { $0.id == song.albumID }) { open(album) }
    }

    /// The Now Playing tab: the shared player column (compacted to fit under the tab
    /// bar). When there's an Up Next queue it sits beside the player; with no queue
    /// the sidebar is dropped and the player fills the whole content width.
    @ViewBuilder
    private var nowPlaying: some View {
        if let np = controller.nowPlaying, !np.queue.isEmpty {
            HStack(spacing: Spacing.zero) {
                MusicPlayerColumn(controller: controller, rowSpacing: Spacing.xxxl, vMargin: Spacing.md)
                    .frame(width: config.musicPlayerWidth)
                Rectangle().fill(Palette.hairlineStroke).frame(width: 1).padding(.vertical, Spacing.lg)
                QueueSidebar(queue: np.queue, onPlay: { controller.playQueueItem($0) })
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.island)
        } else {
            // No queue (or nothing playing) — the player spans the full width.
            MusicPlayerColumn(controller: controller, rowSpacing: Spacing.xxxl, vMargin: Spacing.md)
                .buttonStyle(.island)
        }
    }

    /// Phase-1 placeholder for the Search / Library tabs (filled in by later phases).
    private func placeholder(_ title: String, _ icon: String, _ subtitle: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: IconSize.xxxl, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            Text(title).font(Typography.subheadline).foregroundStyle(Palette.textSecondary)
            Text(subtitle).font(Typography.footnote).foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
