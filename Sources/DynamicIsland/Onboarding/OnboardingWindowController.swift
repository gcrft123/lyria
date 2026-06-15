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

    /// True while a grant is in flight and the takeover has been stepped aside
    /// (hidden for an alert, or lowered for a Settings pane). Used to decide whether
    /// becoming active again should restore the takeover.
    private var focusActive = false

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
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.focusActive {
                        // The user came back from a grant — the alert was answered, or
                        // they clicked the still-visible card after toggling a pane.
                        // Restore the takeover and clear focus so they land on the card.
                        self.setPermissionFocus(.none)
                    } else if self.panel.isVisible {
                        self.panel.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }
    }

    /// Step the takeover aside for a grant, then restore it. The strategy depends on
    /// how the grant surfaces (see `PermissionFocus`):
    ///   • `.dialog` — lower to `.normal` (the centered system alert sits above it) and
    ///     keep the app frontmost via `NSApp.activate`, since macOS only shows these
    ///     alerts for the frontmost app. When the alert is answered the app reactivates
    ///     and the observer restores the card.
    ///   • `.pane`   — only lower to `.normal` and stay visible, so System Settings can
    ///     come above it and the user can click the card to return (this agent has no
    ///     Dock icon or menu-bar item, so a visible card is the only way back).
    ///   • `.none`   — restore: back to full-screen `.screenSaver`, refronting only if
    ///     we were actually mid-grant (avoids focus thrash on ordinary act changes).
    private func setPermissionFocus(_ focus: PermissionFocus) {
        guard !preview else { return }
        switch focus {
        case .none:
            let wasFocused = focusActive
            focusActive = false
            panel.level = .screenSaver
            if wasFocused {
                panel.setFrame(OnboardingWindowController.targetScreen().frame, display: true)
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        case .pane:
            focusActive = true
            panel.level = .normal
        case .dialog:
            // Lower the takeover (a centered TCC alert sits above a `.normal`
            // window) but keep it on screen AND keep the app frontmost. Fully
            // hiding it via `orderOut` dropped this LSUIElement agent out of
            // frontmost, and macOS only shows the Calendar/Location/Bluetooth/
            // Automation prompts for the frontmost app — so the request fired but
            // no alert ever appeared. Staying active fixes that; the pane fallback
            // in PermissionService covers the case where the alert still doesn't show.
            focusActive = true
            panel.level = .normal
            NSApp.activate(ignoringOtherApps: true)
        }
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
