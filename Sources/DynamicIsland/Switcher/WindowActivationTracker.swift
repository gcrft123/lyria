import AppKit

/// Tracks the order in which apps were last activated, so the window switcher can
/// list windows MOST-RECENTLY-USED first.
///
/// macOS only hands us app-level activation (`NSWorkspace.didActivate…`), not
/// per-window focus, so recency is keyed by pid: switch to an app and all its
/// windows move to the front of the list. WITHIN an app the window order falls
/// back to the window server's front-to-back stacking (which already reflects
/// recency for that app). Started at launch so the history is warm by the first
/// Option+Tab.
@MainActor
final class WindowActivationTracker {
    static let shared = WindowActivationTracker()

    /// Monotonic counter — the last value assigned to each pid is its recency.
    private var sequence = 0
    private var rankByPID: [pid_t: Int] = [:]

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
        // Seed with whatever is frontmost right now.
        if let front = NSWorkspace.shared.frontmostApplication {
            record(front.processIdentifier)
        }
    }

    /// Higher = more recently activated. Apps not activated since launch return a
    /// low sentinel so they sort after tracked ones (kept in stacking order).
    func rank(for pid: pid_t) -> Int { rankByPID[pid] ?? Int.min }

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        record(app.processIdentifier)
    }

    private func record(_ pid: pid_t) {
        sequence += 1
        rankByPID[pid] = sequence
    }
}
