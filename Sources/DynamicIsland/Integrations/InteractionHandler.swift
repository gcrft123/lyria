import CoreGraphics
import Foundation

/// Integration seam for pointer interaction — hovering and clicking.
///
/// `IslandWindowController` does the screen hit-testing (it owns the panels) and
/// calls these methods; the handler translates them into controller state.
@MainActor
protocol IslandInteractionHandler: AnyObject {
    /// The pointer entered an island's bounds on `display`.
    func pointerDidEnter(display: CGDirectDisplayID)
    /// The pointer left every island's bounds.
    func pointerDidExit()
    /// The island was clicked (outside any interactive control).
    func pointerDidClick()
}

/// Drives the controller's hover state, which in turn expands/collapses the
/// island. Idempotent: repeated enter/exit calls collapse to a single change.
@MainActor
final class HoverInteractionHandler: IslandInteractionHandler {
    private weak var controller: DynamicIslandController?

    init(controller: DynamicIslandController) {
        self.controller = controller
    }

    func pointerDidEnter(display: CGDirectDisplayID) { controller?.setHovered(display) }
    func pointerDidExit() { controller?.setHovered(nil) }
    func pointerDidClick() {}
}
