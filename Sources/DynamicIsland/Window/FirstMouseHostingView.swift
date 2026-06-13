import AppKit
import SwiftUI

/// `NSHostingView` that accepts the very first click.
///
/// The island lives in a non-activating panel, so it never becomes the active
/// app. By default AppKit swallows the first click on an inactive window (it
/// only focuses it), which would force users to click transport buttons twice.
/// Returning `true` from `acceptsFirstMouse` lets that first click flow
/// straight through to the SwiftUI control under the pointer.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Scroll-to-switch-apps is handled by a local event monitor in the window
    // controller (it needs first look at the wheel, before any NSScrollView — even a
    // non-overflowing one — consumes it), so there's no scrollWheel override here.

    /// Left/right click hooks. The window controller wires these to act on an
    /// active popup (left = open/dismiss, right = dismiss). Each returns `true`
    /// if it consumed the click; when it returns `false` we fall through to
    /// `super` so normal SwiftUI controls (transport, sidebar, gear) still work.
    var onMouseDown: (() -> Bool)?
    var onRightMouseDown: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if onMouseDown?() == true { return }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if onRightMouseDown?() == true { return }
        super.rightMouseDown(with: event)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    required init(rootView: Content) { super.init(rootView: rootView) }
}
