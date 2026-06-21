import AppKit

/// The floating, borderless, transparent panel that hosts the island.
///
/// Configured to behave like a system overlay: it floats above the menu bar,
/// shows on every Space, never activates the app, and (by default) lets mouse
/// events pass straight through so it never interrupts normal use.
final class IslandPanel: NSPanel {

    init(contentRect: NSRect, configuration: IslandConfiguration) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = configuration.windowLevel

        // The island chrome is always dark (hand-styled with fixed palette colors),
        // but native AppKit controls hosted inside (segmented pickers, sliders, menus)
        // follow the panel's effective appearance. Pin it to dark so they don't render
        // their unselected/secondary text in the light-mode (near-black) color, which
        // is invisible on the dark card for anyone running the system in Light Mode.
        appearance = NSAppearance(named: .darkAqua)

        // Transparent canvas — only the SwiftUI pill paints anything.
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        // Purely decorative until the interaction integration flips this off.
        ignoresMouseEvents = configuration.clickThrough

        var behavior: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
        if configuration.showsOnAllSpaces {
            behavior.insert(.canJoinAllSpaces)
            behavior.insert(.fullScreenAuxiliary)
        }
        collectionBehavior = behavior
    }

    // Allow key status so the interaction integration can receive input later;
    // `.nonactivatingPanel` keeps the frontmost app in focus regardless.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
