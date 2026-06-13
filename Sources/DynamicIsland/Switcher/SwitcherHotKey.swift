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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?

    private let disabled = ProcessInfo.processInfo.environment["DI_DISABLE_SWITCHER"] == "1"
        || ProcessInfo.processInfo.environment["DI_MOCK_SWITCHER"] == "1"

    private let tabKeyCode: Int64 = 48
    private let escKeyCode: Int64 = 53
    private let leftArrow: Int64 = 123
    private let rightArrow: Int64 = 124
    private let downArrow: Int64 = 125
    private let upArrow: Int64 = 126

    init(switcher: WindowSwitcher) {
        self.switcher = switcher
    }

    func start() {
        guard !disabled else { return }
        install()
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        eventTap = nil
    }

    // MARK: Tap lifecycle

    private func install() {
        guard eventTap == nil else { return }

        // Accessibility is required to create a session tap. The HUD provider
        // already prompts on first launch; here we just retry until it's granted.
        guard AXIsProcessTrusted() else {
            scheduleRetry()
            return
        }

        // keyDown = 10, flagsChanged = 12.
        let mask = CGEventMask(1 << 10) | CGEventMask(1 << 12)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            scheduleRetry()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        retryTimer?.invalidate(); retryTimer = nil
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.install() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    fileprivate func reenableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    // MARK: Handling

    /// Handle a Tab/Escape/arrow keyDown. Returns true to SWALLOW the key.
    fileprivate func handleKeyDown(keyCode: Int64, optionDown: Bool, shiftDown: Bool) -> Bool {
        if keyCode == tabKeyCode, optionDown {
            if switcher.isActive {
                shiftDown ? switcher.selectPrevious() : switcher.selectNext()
            } else {
                switcher.begin()
            }
            return true // never let the focused app receive Option+Tab
        }
        // The rest only apply WHILE the switcher is open (held Option), so arrows /
        // Escape pass through normally the rest of the time.
        guard switcher.isActive else { return false }
        switch keyCode {
        case rightArrow:
            switcher.selectNext(); return true
        case leftArrow:
            switcher.selectPrevious(); return true
        case downArrow:
            switcher.selectDown(); return true
        case upArrow:
            switcher.selectUp(); return true
        case escKeyCode:
            switcher.cancel(); return true
        default:
            return false
        }
    }

    /// On a modifier change, if Option is no longer held and the switcher is open,
    /// commit (focus the selected window).
    fileprivate func handleFlagsChanged(optionDown: Bool) {
        if !optionDown, switcher.isActive {
            switcher.commit()
        }
    }

    // MARK: C callback

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<SwitcherHotKey>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { monitor.reenableTap() }
            return Unmanaged.passUnretained(event)
        }

        let optionDown = event.flags.contains(.maskAlternate)

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let shiftDown = event.flags.contains(.maskShift)
            let consumed = MainActor.assumeIsolated {
                monitor.handleKeyDown(keyCode: keyCode, optionDown: optionDown, shiftDown: shiftDown)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            MainActor.assumeIsolated { monitor.handleFlagsChanged(optionDown: optionDown) }
            // Always pass modifier changes through — other apps need accurate flags.
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }
}
