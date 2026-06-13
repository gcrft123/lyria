import CoreGraphics

/// The visual mode the island is currently presenting.
///
/// The controller derives this from the active apps' hierarchy, the user's
/// sidebar selection, and whether the pointer is hovering:
///   - nothing active             → `.idle`
///   - active, not hovered        → `.compact(topApp)`
///   - active/hovered             → `.expanded(selectedApp)`
///   - gear tapped in the sidebar → `.settings`
enum IslandMode: Equatable {
    /// Resting pill, nothing to show.
    case idle
    /// Compact summary of one app (not hovered).
    case compact(IslandApp)
    /// Full app view with the sidebar (hovered).
    case expanded(IslandApp)
    /// Settings page, opened from the gear at the bottom of the sidebar.
    case settings
    /// A popup (notification / live activity) taking over the island. Sits at
    /// the very top of the hierarchy — present whenever one is active.
    case popup(IslandPopup)

    /// A transient volume / brightness HUD taking over the island, replacing the
    /// system's own overlay. Sits ABOVE popups — pressing a hardware key is an
    /// immediate, intentional action.
    case hud(SystemHUD)

    /// A transient, glanceable live activity in the compact notch (e.g. the
    /// onboarding "open me" hint). UNLIKE a popup it does not block hover — the
    /// island still opens on hover/click/scroll while it's up.
    case liveActivity(LiveActivity)

    /// The app this mode is presenting, if any. (A popup's *open-target* app is
    /// on the popup itself, not here — this is the app whose view is showing.)
    var app: IslandApp? {
        switch self {
        case .compact(let app), .expanded(let app): return app
        case .idle, .settings, .popup, .hud, .liveActivity: return nil
        }
    }

    var isExpanded: Bool {
        switch self {
        case .expanded, .settings: return true
        case .idle, .compact, .popup, .hud, .liveActivity: return false
        }
    }
}

/// Concrete geometry for the current mode: the single source of truth for "how
/// big and how round is the island right now". Resolved by the controller,
/// which has all the state (selected app, volume reveal, timer count) the size
/// depends on.
struct IslandGeometry: Equatable {
    var size: CGSize
    var cornerRadius: CGFloat
}
