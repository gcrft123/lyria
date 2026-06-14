import ApplicationServices
import CoreGraphics
import Foundation
import os

/// A single dedicated background thread that services every `CGEventTap`
/// callback, kept strictly OFF the main runloop. (See `EventTap` for *why* that
/// is a correctness requirement, not an optimization.)
///
/// It runs a bare `CFRunLoop`, kept alive by a mach port, that tap run-loop
/// sources attach to. Both of the app's taps share this one thread; their
/// callbacks are fast and non-blocking, so serializing them here is fine.
final class EventTapThread: @unchecked Sendable {
    static let shared = EventTapThread()

    // Written once on the dedicated thread before `init` returns (published via
    // the semaphore), then only read — so post-init access is race-free.
    private var cfRunLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    private init() {
        let thread = Thread { [self] in
            cfRunLoop = CFRunLoopGetCurrent()
            // A runloop with no input sources returns immediately from `run`; a
            // mach port keeps it alive until taps attach (and after they detach).
            RunLoop.current.add(NSMachPort(), forMode: .common)
            ready.signal()
            while true { CFRunLoopRunInMode(.defaultMode, 1.0e9, false) }
        }
        thread.name = "io.github.gcrft123.lyria.eventtap"
        thread.qualityOfService = .userInteractive   // service input promptly
        thread.start()
        ready.wait()
    }

    func add(_ source: CFRunLoopSource) {
        guard let cfRunLoop else { return }
        CFRunLoopAddSource(cfRunLoop, source, .commonModes)
        CFRunLoopWakeUp(cfRunLoop)
    }

    func remove(_ source: CFRunLoopSource) {
        guard let cfRunLoop else { return }
        CFRunLoopRemoveSource(cfRunLoop, source, .commonModes)
        CFRunLoopWakeUp(cfRunLoop)
    }
}

/// An active session `CGEventTap` serviced on `EventTapThread`, never on the main
/// runloop.
///
/// WHY THIS EXISTS — an *active* head-insert session tap
/// (`.cgSessionEventTap` + `.defaultTap`) is dispatched SYNCHRONOUSLY by the
/// window server: it withholds delivery of every keystroke and mouse click
/// system-wide until the tap's callback returns. Run that callback on the main
/// runloop and any main-thread stall — heavy SwiftUI layout, a slow DDC/I²C
/// brightness write, or the burst of work when the user revokes Accessibility —
/// freezes the keyboard and mouse for the WHOLE system (the cursor still glides,
/// because it's composited separately). That is the exact lock-up this type
/// prevents.
///
/// The contract: the `Handler` runs on the event-tap thread and must be fast and
/// lock-free. It decides ONLY whether to swallow the event; any real work
/// (driving hardware, updating UI) it hands to the main queue asynchronously.
/// The tap therefore returns promptly no matter what the main thread is doing.
///
/// It also stands down cleanly if Accessibility is revoked mid-run (rather than
/// spinning to re-enable a tap it no longer has permission for), calling
/// `onStandDown` on the main actor so the owner can rebuild once it's granted.
final class EventTap: @unchecked Sendable {

    /// Runs on the EVENT-TAP THREAD for each matched event. Return `true` to
    /// swallow the event, `false` to pass it through. MUST be fast and
    /// non-blocking — dispatch any main-actor / hardware work yourself, async.
    typealias Handler = @Sendable (CGEventType, CGEvent) -> Bool

    private let mask: CGEventMask
    private let handler: Handler

    /// Guards the tap port so the tap thread can re-enable it while the main
    /// thread is tearing it down. `nil` ⇒ not running.
    private let portLock = OSAllocatedUnfairLock<CFMachPort?>(initialState: nil)
    /// Touched only on the main thread (enable/disable).
    private var source: CFRunLoopSource?

    /// Called on the main actor if the tap stands down (e.g. Accessibility
    /// revoked) so the owner can schedule a rebuild.
    @MainActor var onStandDown: (() -> Void)?

    init(mask: CGEventMask, handler: @escaping Handler) {
        self.mask = mask
        self.handler = handler
    }

    /// Create + start the tap. Returns false if Accessibility isn't granted yet
    /// (the owner should retry later). Main-thread only.
    @MainActor @discardableResult
    func enable() -> Bool {
        if portLock.withLock({ $0 != nil }) { return true }   // already running
        guard AXIsProcessTrusted() else { return false }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.trampoline,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            return false
        }
        portLock.withLock { $0 = tap }
        source = src
        EventTapThread.shared.add(src)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Stop + detach the tap. Main-thread only. Safe to call repeatedly.
    @MainActor
    func disable() {
        let tap = portLock.withLock { port -> CFMachPort? in
            defer { port = nil }
            return port
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { EventTapThread.shared.remove(source) }
        source = nil
    }

    // MARK: Tap-thread trampoline

    private static let trampoline: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()

        // macOS disables a tap that times out or is interrupted.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.handleDisabled()
            return Unmanaged.passUnretained(event)
        }

        return tap.handler(type, event) ? nil : Unmanaged.passUnretained(event)
    }

    /// On the tap thread. Re-arm if we still hold Accessibility; otherwise stand
    /// down — don't spin re-enabling a tap we can no longer use (which is what
    /// happens the instant the user toggles Accessibility off).
    private func handleDisabled() {
        if AXIsProcessTrusted(), let tap = portLock.withLock({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.disable()
                    self.onStandDown?()
                }
            }
        }
    }
}
