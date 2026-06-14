import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted (e.g. by Settings → "Replay intro") to re-run onboarding live.
    static let replayOnboarding = Notification.Name("io.github.gcrft123.lyria.replayOnboarding")
}

/// A borderless onboarding window. The real takeover becomes key (so its buttons
/// and pickers receive clicks/keys); the debug windowed preview does NOT, so it
/// never steals focus from whatever the user is doing.
final class OnboardingPanel: NSWindow {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { allowsKey }
}

/// Owns the onboarding window + coordinator for one run. Built only when
/// onboarding should show (first launch or replay); torn down on finish.
@MainActor
final class OnboardingWindowController {
    private let panel: OnboardingPanel
    private let coordinator: OnboardingCoordinator
    /// Called once onboarding finishes or is skipped.
    var onComplete: (() -> Void)?

    /// Re-fronts the takeover when the user returns to the app (e.g. back from
    /// System Settings after granting), so the card is reachable.
    private var activationObserver: NSObjectProtocol?

    /// Debug: render in a small corner window that never steals focus, so the
    /// onboarding can be inspected without taking over the screen.
    private let preview = ProcessInfo.processInfo.environment["DI_ONBOARD_PREVIEW"] == "1"

    init(settings: AppSettings) {
        coordinator = OnboardingCoordinator(settings: settings)

        let screen = OnboardingWindowController.targetScreen()
        let frame = preview ? OnboardingWindowController.previewFrame(on: screen) : screen.frame
        panel = OnboardingPanel(contentRect: frame,
                                styleMask: [.borderless],
                                backing: .buffered,
                                defer: false)
        panel.allowsKey = !preview
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Real takeover sits over everything; the preview just floats above normal
        // windows so it can be screenshotted without grabbing focus.
        panel.level = preview ? .floating : .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        let root = OnboardingView(coordinator: coordinator)
            .environmentObject(settings)
        // FirstMouse so buttons fire on the FIRST click even when the window isn't
        // key (e.g. right after returning from System Settings).
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        coordinator.onFinish = { [weak self] in self?.dismiss() }
        coordinator.onPermissionFocus = { [weak self] focus in self?.setPermissionFocus(focus) }

        if !preview {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { guard let self, self.panel.isVisible else { return }
                    self.panel.makeKeyAndOrderFront(nil) }
            }
        }
    }

    /// While a grant is in progress, drop the takeover to the normal window level
    /// so System Settings and TCC prompts can come above it; raise it back once the
    /// user moves on. (No re-activation here — that caused focus thrash.)
    private func setPermissionFocus(_ focus: Bool) {
        guard !preview else { return }
        panel.level = focus ? .normal : .screenSaver
    }

    func show() {
        if preview {
            panel.orderFrontRegardless()   // no focus steal, no activation
        } else {
            panel.setFrame(OnboardingWindowController.targetScreen().frame, display: true)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A card-sized window pinned to the lower-left, clear of the notch.
    private static func previewFrame(on screen: NSScreen) -> NSRect {
        let size = CGSize(width: Layout.onboardingWidth + 96, height: 540)
        return NSRect(x: screen.frame.minX + 60, y: screen.frame.minY + 80,
                      width: size.width, height: size.height)
    }

    private func dismiss() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        panel.orderOut(nil)
        NSApp.deactivate()
        onComplete?()
    }

    private static func targetScreen() -> NSScreen {
        if #available(macOS 12.0, *),
           let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }
}
