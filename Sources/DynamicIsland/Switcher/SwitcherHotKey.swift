import AppKit
import ApplicationServices
import CoreGraphics

/// The global Alt+Tab hot-key, via a session `CGEventTap` (same mechanism as the
/// volume/brightness HUD).
///
/// While **Option** is held, **Tab** opens the switcher and advances the
/// selection (Shift+Tab goes back); releasing Option focuses the selected window;
/// **Escape** cancels. The Tab keystrokes are SWALLOWED so the focused app never
/// sees them. Uses Option+Tab (not Cmd+Tab) so it sits alongside the system app
/// switcher rather than fighting it — same default as alt-tab-macos.
///
/// Needs **Accessibility** permission (to create the tap); it shares the grant the
/// HUD already prompts for. `DI_DISABLE_SWITCHER=1` skips it entirely.
@MainActor
final class SwitcherHotKey {

    private let switcher: WindowSwitcher

    /// The session tap, serviced off the main runloop (see `EventTap`).
    private var tap: EventTap?
    private var retryTimer: Timer?

    private let disabled = ProcessInfo.processInfo.environment["DI_DISABLE_SWITCHER"] == "1"
        || ProcessInfo.processInfo.environment["DI_MOCK_SWITCHER"] == "1"

    // Static + nonisolated so the event-tap thread can read them without the actor.
    private nonisolated static let tabKeyCode: Int64 = 48
    private nonisolated static let escKeyCode: Int64 = 53
    private nonisolated static let leftArrow: Int64 = 123
    private nonisolated static let rightArrow: Int64 = 124
    private nonisolated static let downArrow: Int64 = 125
    private nonisolated static let upArrow: Int64 = 126

    init(switcher: WindowSwitcher) {
        self.switcher = switcher
    }

    func start() {
        guard !disabled else { return }
        install()
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        tap?.disable()
        tap = nil
    }

    // MARK: Tap lifecycle

    private func install() {
        guard tap == nil else { return }

        // Accessibility is required to create a session tap. The HUD provider
        // already prompts on first launch; here we just retry until it's granted.
        guard AXIsProcessTrusted() else {
            scheduleRetry()
            return
        }

        // keyDown = 10, flagsChanged = 12.
        let mask = CGEventMask(1 << 10) | CGEventMask(1 << 12)
        let tap = EventTap(mask: mask) { [weak self] type, event in
            self?.handle(type: type, event: event) ?? false
        }
        tap.onStandDown = { [weak self] in self?.tapStoodDown() }
        guard tap.enable() else {
            scheduleRetry()
            return
        }
        self.tap = tap
        retryTimer?.invalidate(); retryTimer = nil
    }

    /// Accessibility was revoked while running — drop the dead tap and wait for the
    /// grant to come back (then rebuild).
    private func tapStoodDown() {
        tap = nil
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.install() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: Event-tap thread

    /// Runs on the EVENT-TAP THREAD. Decides whether to swallow the key (from the
    /// event and the thread-safe `activeFlag` mirror only — never touching the
    /// main actor), and dispatches the matching switcher action to the main actor.
    nonisolated private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let optionDown = event.flags.contains(.maskAlternate)

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let shiftDown = event.flags.contains(.maskShift)
            let active = switcher.activeFlag.withLock { $0 }
            let swallow = Self.shouldSwallowKeyDown(keyCode: keyCode, optionDown: optionDown, active: active)
            if swallow {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.performKeyDown(keyCode: keyCode, optionDown: optionDown, shiftDown: shiftDown)
                    }
                }
            }
            return swallow
        }

        if type == .flagsChanged {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.handleFlagsChanged(optionDown: optionDown) }
            }
            return false   // always pass modifier changes through (apps need accurate flags)
        }

        return false
    }

    /// Pure swallow decision, safe to run off the main actor. Option+Tab is always
    /// swallowed (so the focused app never sees it); arrows / Escape only while the
    /// switcher is open.
    nonisolated private static func shouldSwallowKeyDown(keyCode: Int64, optionDown: Bool, active: Bool) -> Bool {
        if keyCode == tabKeyCode, optionDown { return true }
        guard active else { return false }
        switch keyCode {
        case leftArrow, rightArrow, downArrow, upArrow, escKeyCode: return true
        default: return false
        }
    }

    // MARK: Main-actor effects

    private func performKeyDown(keyCode: Int64, optionDown: Bool, shiftDown: Bool) {
        if keyCode == Self.tabKeyCode, optionDown {
            if switcher.isActive {
                shiftDown ? switcher.selectPrevious() : switcher.selectNext()
            } else {
                switcher.begin()
            }
            return
        }
        guard switcher.isActive else { return }
        switch keyCode {
        case Self.rightArrow: switcher.selectNext()
        case Self.leftArrow:  switcher.selectPrevious()
        case Self.downArrow:  switcher.selectDown()
        case Self.upArrow:    switcher.selectUp()
        case Self.escKeyCode: switcher.cancel()
        default: break
        }
    }

    /// On a modifier change, if Option is no longer held and the switcher is open,
    /// commit (focus the selected window).
    private func handleFlagsChanged(optionDown: Bool) {
        if !optionDown, switcher.isActive {
            switcher.commit()
        }
    }
}
