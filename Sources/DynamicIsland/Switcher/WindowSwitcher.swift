import AppKit
import Combine

/// The Alt+Tab window-switcher state machine.
///
/// `SwitcherHotKey` drives it from the global event tap: `begin()` on the first
/// Option+Tab, `selectNext()`/`selectPrevious()` on each further Tab while Option
/// is held, and `commit()` when Option is released (focusing the selected window)
/// or `cancel()` on Escape. `SwitcherWindowController` observes `isActive` to show
/// / hide the overlay, and the SwiftUI grid reads `windows` + `selectedIndex`.
@MainActor
final class WindowSwitcher: ObservableObject {

    @Published private(set) var isActive = false
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var selectedIndex = 0

    /// The currently highlighted window, if any.
    var selected: WindowInfo? {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
    }

    /// Bumped on every open so a slow thumbnail load from a previous open can't
    /// apply its results to a newer session.
    private var generation = 0

    /// Open the switcher: snapshot the windows (cheap — no thumbnails) and show the
    /// overlay IMMEDIATELY, then stream thumbnails in asynchronously. Preselects the
    /// window *behind* the frontmost (one Option+Tab → previous window). No-op if
    /// there's nothing to switch to.
    func begin() {
        let list = WindowEnumerator.currentWindows()
        guard !list.isEmpty else { return }
        generation += 1
        windows = list
        selectedIndex = list.count > 1 ? 1 : 0
        if !isActive { isActive = true }
        loadThumbnails(for: list, generation: generation)
    }

    /// Capture thumbnails off the main thread, then fold them into `windows` (only
    /// if this is still the same, active session).
    private func loadThumbnails(for list: [WindowInfo], generation gen: Int) {
        let ids = list.map { $0.id }
        Task.detached(priority: .userInitiated) { [weak self] in
            let thumbs = WindowEnumerator.thumbnails(for: ids)
            guard !thumbs.isEmpty else { return }
            await MainActor.run {
                guard let self, self.isActive, self.generation == gen else { return }
                self.windows = self.windows.map { window in
                    guard let image = thumbs[window.id] else { return window }
                    return WindowInfo(id: window.id, pid: window.pid, appName: window.appName,
                                      title: window.title, icon: window.icon,
                                      thumbnail: image, axElement: window.axElement)
                }
            }
        }
    }

    /// The grid's current column count, reported by the view so Up/Down can move
    /// a whole row. 1 until the overlay lays out.
    private(set) var columnCount = 1
    func setColumns(_ count: Int) { columnCount = max(1, count) }

    func selectNext() {
        guard isActive, !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % windows.count
    }

    func selectPrevious() {
        guard isActive, !windows.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + windows.count) % windows.count
    }

    /// Move down one grid row (same column), clamped — no wrap past the last row.
    func selectDown() {
        guard isActive, !windows.isEmpty else { return }
        let next = selectedIndex + columnCount
        if next < windows.count { selectedIndex = next }
    }

    /// Move up one grid row (same column), clamped — no wrap past the first row.
    func selectUp() {
        guard isActive, !windows.isEmpty else { return }
        let prev = selectedIndex - columnCount
        if prev >= 0 { selectedIndex = prev }
    }

    /// Focus the selected window and close the switcher.
    func commit() {
        guard isActive else { return }
        let target = selected
        end()
        if let target { WindowEnumerator.focus(target) }
    }

    /// Focus a specific window (a mouse click on its cell) and close.
    func choose(_ window: WindowInfo) {
        guard isActive else { return }
        end()
        WindowEnumerator.focus(window)
    }

    /// Highlight a window without committing (mouse hover over its cell).
    func select(_ window: WindowInfo) {
        guard isActive, let index = windows.firstIndex(of: window) else { return }
        if selectedIndex != index { selectedIndex = index }
    }

    /// Close without focusing (Escape).
    func cancel() {
        guard isActive else { return }
        end()
    }

    private func end() {
        isActive = false
        // Keep `windows` so the overlay can fade out cleanly; cleared on next begin.
    }

    // MARK: Debug

    /// `DI_MOCK_SWITCHER=1` seeds a few synthetic windows so the overlay can be
    /// rendered/screenshotted without pressing Option+Tab or granting Screen
    /// Recording. Committing a mock window is a harmless no-op (no real pid).
    func beginMock() {
        func sym(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        windows = [
            WindowInfo(id: 1, pid: -1, appName: "Finder", title: "Finder — Downloads",
                       icon: sym("folder.fill"), thumbnail: nil),
            WindowInfo(id: 2, pid: -1, appName: "Finder", title: "Finder — LocalSend",
                       icon: sym("folder.fill"), thumbnail: nil),
            WindowInfo(id: 3, pid: -1, appName: "Firefox", title: "Firefox — GitHub",
                       icon: sym("globe"), thumbnail: nil),
            WindowInfo(id: 4, pid: -1, appName: "Firefox", title: "Firefox — AltTab",
                       icon: sym("globe"), thumbnail: nil),
            WindowInfo(id: 5, pid: -1, appName: "Firefox", title: "Firefox — You Need…",
                       icon: sym("globe"), thumbnail: nil),
            WindowInfo(id: 6, pid: -1, appName: "Bitwarden", title: "Bitwarden — Vault",
                       icon: sym("lock.shield.fill"), thumbnail: nil),
            WindowInfo(id: 7, pid: -1, appName: "Firefox", title: "Firefox — Mac | How…",
                       icon: sym("globe"), thumbnail: nil),
        ]
        selectedIndex = 0
        isActive = true
    }
}
