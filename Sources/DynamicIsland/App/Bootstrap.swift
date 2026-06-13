import AppKit

/// Program entry point.
///
/// Manual AppKit bootstrap rather than a SwiftUI `App` scene: the island needs
/// a borderless floating panel, not a normal window, so we drive
/// `NSApplication` directly. Running as `.accessory` means no Dock icon and no
/// app menu. `main()` is `@MainActor` so the whole app starts on the main
/// actor, which all the UI types require.
@main
struct DynamicIslandApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // `run()` blocks until termination, so `delegate` stays retained for the
        // process lifetime even though NSApplication only holds it weakly.
        app.run()
    }
}
