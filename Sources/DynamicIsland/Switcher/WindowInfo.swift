import AppKit
import ApplicationServices

/// One switchable window, flattened from the Accessibility window list (+ the
/// owning app) into a value type the switcher UI can hold and diff.
struct WindowInfo: Identifiable, Equatable {
    /// The CoreGraphics window number — stable for the window's lifetime and the
    /// key used to capture a thumbnail.
    let id: CGWindowID
    let pid: pid_t
    /// The owning application's name (e.g. "Safari").
    let appName: String
    /// The window's own title (e.g. a tab/page title). From the Accessibility API,
    /// so it's available without Screen Recording.
    let title: String
    /// The app icon (always available).
    let icon: NSImage?
    /// A live snapshot of the window. `nil` without Screen Recording permission, or
    /// for windows on another Space — the UI then falls back to the large app icon.
    let thumbnail: NSImage?
    /// The Accessibility element for this window, raised directly on focus. `nil`
    /// for mock windows.
    let axElement: AXUIElement?

    init(id: CGWindowID, pid: pid_t, appName: String, title: String,
         icon: NSImage?, thumbnail: NSImage?, axElement: AXUIElement? = nil) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.title = title
        self.icon = icon
        self.thumbnail = thumbnail
        self.axElement = axElement
    }

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
    }

    /// The label under each cell: the window title if we have one, else the app
    /// name.
    var displayTitle: String { title.isEmpty ? appName : title }
}
