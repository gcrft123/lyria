import AppKit
import Combine
import SwiftUI

/// Owns the Alt+Tab overlay window: a full-screen, transparent, non-activating
/// panel above everything that hosts `WindowSwitcherView`. It's shown while the
/// switcher is active and ordered out otherwise.
///
/// It DOES take mouse events (cells are clickable to focus a window, and a click
/// off the grid dismisses), but stays NON-ACTIVATING so clicking it never steals
/// key focus from the app being switched FROM — the focus change must land on the
/// chosen window, not on this overlay.
@MainActor
final class SwitcherWindowController: NSObject {

    private let switcher: WindowSwitcher
    private let panel: NSPanel
    private var cancellable: AnyCancellable?

    init(switcher: WindowSwitcher) {
        self.switcher = switcher

        panel = NSPanel(
            contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        super.init()

        panel.isFloatingPanel = true
        panel.level = .popUpMenu          // above the island (.statusBar) and apps
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = false  // cells are clickable (click to focus)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: WindowSwitcherView(switcher: switcher))
        host.frame = panel.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        // Show/hide as the switcher opens/closes.
        cancellable = switcher.$isActive.sink { [weak self] active in
            self?.setVisible(active)
        }
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Cover the screen the cursor is on, so the overlay is centred where the user
    /// is looking.
    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.frame { panel.setFrame(frame, display: true) }
    }
}
