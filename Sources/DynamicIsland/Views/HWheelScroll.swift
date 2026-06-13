import AppKit
import SwiftUI

/// A horizontal scroller that ALSO responds to a vertical mouse wheel — a plain
/// SwiftUI `ScrollView(.horizontal)` ignores a vertical wheel on macOS, so chip /
/// icon strips can't be scrolled with a standard mouse. Backed by an
/// `NSScrollView`: a vertical wheel is redirected to horizontal motion, while a
/// trackpad's native horizontal swipe (and momentum) is left untouched.
///
/// Use exactly like a horizontal `ScrollView` and give it a height:
///     HWheelScroll { HStack { … } }.frame(height: 30)
struct HWheelScroll<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = WheelHScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .allowed
        scroll.automaticallyAdjustsContentInsets = false

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        // Pin the content to the clip's top/bottom/leading; its width stays natural
        // (so it can be wider than the clip and scroll).
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
        ])
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        (nsView.documentView as? NSHostingView<Content>)?.rootView = content
    }
}

extension View {
    /// Suppresses the elastic overscroll/rubber-band when a list's content fits
    /// (so short lists don't feel "springy/forced"), where the OS supports it.
    /// `scrollBounceBehavior` is macOS 13.3+, so it's gated for our 13.0 floor.
    @ViewBuilder func smoothScrollBounce() -> some View {
        if #available(macOS 13.3, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}

/// `NSScrollView` that turns a vertical wheel into horizontal motion.
private final class WheelHScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // A trackpad's native horizontal intent → let AppKit handle it (momentum).
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }
        guard let doc = documentView else { super.scrollWheel(with: event); return }
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        // Nothing to scroll horizontally → let the event bubble (e.g. to a parent).
        guard maxX > 0 else { super.scrollWheel(with: event); return }

        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        var x = contentView.bounds.origin.x - event.scrollingDeltaY * scale
        x = min(maxX, max(0, x))
        contentView.scroll(to: NSPoint(x: x, y: contentView.bounds.origin.y))
        reflectScrolledClipView(contentView)
    }
}
