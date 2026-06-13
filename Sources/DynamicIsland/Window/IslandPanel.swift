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
