import AppKit
import SwiftUI

/// Owns the island panel: builds it, hosts the SwiftUI view, pins it to the
/// top-centre of the display, and keeps it there when the screen layout
/// changes (resolution change, display connect/disconnect, etc.).
@MainActor
final class IslandWindowController: NSObject {

    private let controller: DynamicIslandController
    private let configuration: IslandConfiguration
    private let panel: IslandPanel

    private var hoverTimer: Timer?

    /// Pending collapse, scheduled when the pointer leaves and cancelled if it
    /// comes back — see `updateHover`.
    private var exitWorkItem: DispatchWorkItem?

    /// For the `.click` / `.scroll` expand triggers: whether the user has performed
    /// the trigger gesture during the current visit, so the island should stay
    /// expanded while the pointer remains over it. Reset only when it fully
    /// collapses (so a quick edge-skim re-entry stays open). Always "true" in
    /// effect for `.hover`, where merely being inside expands.
    private var expansionCommitted = false

    /// Forgiveness margin (points) around the COMPACT pill for hit-testing, so the
    /// pointer can slip slightly past the edge without collapsing the player.
    private let hoverPadding: CGFloat = 8

    /// A more generous margin once the island is EXPANDED: the keep-open region the
    /// pointer must stay within is enlarged so small drifts (reaching for a control
    /// near the edge, overshooting a button) don't collapse the card.
    private let expandedHoverPadding: CGFloat = 26

    /// The effective forgiveness margin for the current state — bigger when expanded.
    private var activeHoverPadding: CGFloat {
        controller.mode.isExpanded ? expandedHoverPadding : hoverPadding
    }

    /// How long the island stays expanded after the pointer leaves before it
    /// collapses. A brief grace makes re-entry feel sticky/magnetic and stops
    /// the player flickering shut when the pointer skims the edge — short enough
    /// that an intentional exit still feels responsive.
    private let exitGrace: TimeInterval = 0.13

    // MARK: Scroll-to-switch state

    /// Accumulated scroll delta toward the next app switch (reset on each switch
    /// and when the gesture leaves a switch zone).
    private var scrollAccum: CGFloat = 0
    /// When the last scroll-driven app switch happened — a cooldown so one flick
    /// (or a fast burst of wheel notches) advances a single app, not several.
    private var lastScrollSwitch: Date = .distantPast
    private let scrollSwitchCooldown: TimeInterval = 0.3
    /// Accumulated scroll needed to switch. Mouse wheels report small per-notch
    /// deltas (so one notch flips), trackpads report large precise deltas (so a
    /// deliberate swipe is required).
    private func scrollThreshold(precise: Bool) -> CGFloat { precise ? 28 : 1 }
    /// Local monitor that gets first look at every scroll wheel event over the
    /// panel — BEFORE any `NSScrollView` (even a non-overflowing one) eats it.
    private var scrollMonitor: Any?
    private let scrollDebug = ProcessInfo.processInfo.environment["DI_DEBUG_SCROLL"] == "1"

    init(controller: DynamicIslandController) {
        self.controller = controller
        self.configuration = controller.configuration

        let canvas = NSRect(x: 0, y: 0,
                            width: configuration.canvasWidth,
                            height: configuration.canvasHeight)
        panel = IslandPanel(contentRect: canvas, configuration: configuration)

        super.init()

        let root = DynamicIslandView(controller: controller)
            .environmentObject(controller.settings)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = canvas
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // While a popup owns the island, clicks act on it: left-click opens its
        // app (or dismisses), right-click dismisses. With no popup these return
        // false, so normal SwiftUI controls (transport, sidebar, gear) get the
        // click as before.
        hosting.onMouseDown = { [weak self] in
            guard let self else { return false }
            if self.controller.activePopup != nil {
                self.controller.activatePopup()
                return true
            }
            // Click-to-expand: when that trigger is selected and the card is still
            // compact, the first click on the pill commits the expansion (and is
            // consumed). Once expanded, clicks fall through to the controls.
            if self.controller.settings.expandTrigger == .click, !self.controller.mode.isExpanded {
                self.expansionCommitted = true
                self.controller.interactionHandler?.pointerDidEnter()
                return true
            }
            return false
        }
        hosting.onRightMouseDown = { [weak self] in
            guard let self, self.controller.activePopup != nil else { return false }
            self.controller.dismissPopup()
            return true
        }

        // Editing a timer name needs the keyboard, so focus the (normally
        // non-activating) panel while a text field is up, then hand focus back.
        controller.onEditingChange = { [weak self] editing in
            self?.setPanelEditing(editing)
        }
    }

    /// Hide / show the island panel (e.g. while the onboarding takeover owns the
    /// screen, so the real island never peeks through behind it).
    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    /// The app that was frontmost before the island grabbed focus, so it can be
    /// handed focus back when the island is done (rather than deactivating to
    /// whatever macOS picks next).
    private var appToRestoreFocus: NSRunningApplication?

    /// Give/return keyboard focus for in-island text editing (timer names).
    private func setPanelEditing(_ editing: Bool) {
        if editing {
            // Remember who was frontmost (unless it's already us) so focus returns
            // there afterwards.
            let me = NSRunningApplication.current
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != me.processIdentifier {
                appToRestoreFocus = front
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.makeFirstResponder(nil)
            restorePreviousAppFocus()
        }
    }

    /// Hand focus back to whoever owned it before the island took over. Falls back
    /// to a plain deactivate when there's nothing recorded.
    private func restorePreviousAppFocus() {
        if let prev = appToRestoreFocus, !prev.isTerminated {
            appToRestoreFocus = nil
            prev.activate(options: [.activateIgnoringOtherApps])
        } else {
            appToRestoreFocus = nil
            NSApp.deactivate()
        }
    }

    /// Places the panel on screen and starts tracking layout changes.
    func show() {
        reposition()
        panel.acceptsMouseMovedEvents = true
        panel.orderFrontRegardless()

        // Selector-based observation keeps this off the Sendable-closure path.
        // Screen-parameter changes are posted on the main thread.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        startHoverTracking()

        // Scroll-to-switch-apps: a local monitor gets first look at every wheel
        // event over the panel, BEFORE any NSScrollView (even a non-overflowing one)
        // swallows it. Over a scroll view that can actually scroll we pass the event
        // through; otherwise (sidebar, music player, short lists) we switch apps.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollEvent(event) ?? event
        }

        // DI_DEBUG_SCROLL=1: dump the NSScrollView hierarchy a few times so we can
        // see whether SwiftUI's ScrollViews are detectable / sized as expected.
        if ProcessInfo.processInfo.environment["DI_DEBUG_SCROLL"] == "1" {
            for delay in [3.0, 5.0, 7.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.debugDumpScrollViews()
                }
            }
        }
    }

    private func debugDumpScrollViews() {
        guard let root = panel.contentView else { return }
        func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        var total = 0, scrolls = 0
        func walk(_ v: NSView, _ depth: Int) {
            total += 1
            if let sv = v as? NSScrollView {
                scrolls += 1
                let clip = sv.contentView.bounds.size
                let doc = sv.documentView?.frame.size ?? .zero
                let canV = doc.height > clip.height + 1, canH = doc.width > clip.width + 1
                err("[scroll]\(String(repeating: "  ", count: depth))\(type(of: sv)) clip=\(Int(clip.width))x\(Int(clip.height)) doc=\(Int(doc.width))x\(Int(doc.height)) canScroll=\(canV || canH) [v:\(canV) h:\(canH)]")
            }
            v.subviews.forEach { walk($0, depth + 1) }
        }
        walk(root, 0)
        err("[scroll] === \(scrolls) NSScrollView(s) of \(total) views; mode=\(controller.mode) ===")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hoverTimer?.invalidate()
        exitWorkItem?.cancel()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    @objc private func screenParametersDidChange() {
        reposition()
    }

    // MARK: Hover

    /// Hover is detected by polling the cursor position on a light timer rather
    /// than with event monitors. A global `.mouseMoved` monitor only fires for
    /// events actually delivered to another app, which is unreliable over a
    /// click-through overlay; polling `NSEvent.mouseLocation` always works,
    /// needs no permissions, and is cheap (a point read + rect test).
    private func startHoverTracking() {
        // ~33 Hz: low enough to be cheap (a point read + rect test), fast enough that
        // the island reacts to the pointer arriving/leaving with no perceptible delay.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func updateHover() {
        let location = NSEvent.mouseLocation

        // Popups own the island and suppress hover-to-expand. While one is up we
        // keep capturing clicks (so the popup is actionable) and track whether
        // the pointer is over it, growing it a little. For the immunity tail
        // after it clears we keep the island collapsed so it doesn't snap open
        // the instant the popup goes away.
        if controller.activePopup != nil {
            exitWorkItem?.cancel(); exitWorkItem = nil
            panel.ignoresMouseEvents = false
            controller.setPopupHovered(
                islandScreenRect(inflatedBy: activeHoverPadding).contains(location))
            if controller.isHovered { controller.setHovered(false) }
            return
        }
        if controller.blocksHoverActivation {
            panel.ignoresMouseEvents = true
            if controller.isHovered { controller.setHovered(false) }
            return
        }

        // The whole island is hoverable — including the idle pill, so hovering it
        // expands into the app sidebar. While editing a timer name we stay open
        // regardless of where the pointer drifts.
        let inside = controller.isEditing
            || islandScreenRect(inflatedBy: activeHoverPadding).contains(location)

        if inside {
            // Re-entered before the grace timer fired — cancel any pending
            // collapse and resume capturing events so the pill is clickable /
            // scrollable (which is how the click/scroll triggers commit).
            exitWorkItem?.cancel()
            exitWorkItem = nil
            panel.ignoresMouseEvents = false

            // Whether the island should be EXPANDED right now. For `.hover` just
            // being inside is enough; `.click`/`.scroll` wait for the gesture
            // (`expansionCommitted`), set in the mouse-down / scroll handlers.
            // An already-expanded card stays expanded while the pointer is still
            // inside it — so e.g. changing the expand-trigger setting (which lives
            // INSIDE the expanded card) never collapses the card out from under you.
            let shouldExpand = controller.settings.expandTrigger == .hover
                || expansionCommitted
                || controller.pinned
                || controller.isEditing
                || controller.mode.isExpanded

            if shouldExpand {
                controller.interactionHandler?.pointerDidEnter()
                // The music player's volume/slider hover zones only make sense when
                // the music app is the one expanded in the main island.
                if isMusicExpanded {
                    updateVolumeReveal(at: location)
                    updateControlHover(at: location)
                }
                // Reveal the pin affordance while the pointer is over the card's
                // top-right corner (only when there's an expanded card to pin).
                controller.setPinCornerHovered(controller.mode.isExpanded && pinCornerRect().contains(location))
            } else {
                // Over the compact pill, waiting for the click/scroll gesture:
                // capture events (to detect it) but stay collapsed.
                if controller.isHovered { controller.setHovered(false) }
                controller.setPinCornerHovered(false)
            }
        } else {
            // Stop blocking events immediately, but hold the expanded state for
            // a short grace so a quick re-entry doesn't cause a flicker.
            panel.ignoresMouseEvents = true
            controller.setPinCornerHovered(false)
            if controller.isHovered {
                scheduleExitIfNeeded()
            } else {
                expansionCommitted = false
                controller.interactionHandler?.pointerDidExit()
            }
        }
    }

    /// Screen-coord zone over the expanded card's top-right corner, where the pin
    /// affordance sits. A generous square straddling the corner so the thumbtack
    /// is easy to summon and stays summoned while the pointer is on the button.
    private func pinCornerRect() -> NSRect {
        let size = controller.geometry.size
        let rightX = panel.frame.midX + size.width / 2
        let topY = panel.frame.maxY - configuration.topInset
        let reach: CGFloat = 52   // inward from the corner
        let out: CGFloat = 14     // a touch past the corner (the button overhangs)
        return NSRect(x: rightX - reach, y: topY - reach, width: reach + out, height: reach + out)
    }

    /// Arms a one-shot collapse `exitGrace` from now (if not already armed). It
    /// re-checks the pointer when it fires, so a return inside the window — even
    /// one the poll missed — keeps the island open.
    private func scheduleExitIfNeeded() {
        guard exitWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.exitWorkItem = nil
            let stillOutside = !self.controller.isEditing
                && !self.islandScreenRect(inflatedBy: self.activeHoverPadding)
                    .contains(NSEvent.mouseLocation)
            if stillOutside {
                // Fully collapsing now — require the click/scroll gesture again
                // next visit.
                self.expansionCommitted = false
                self.controller.interactionHandler?.pointerDidExit()
            }
        }
        exitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + exitGrace, execute: work)
    }

    /// True only when the music app fills the expanded main island (not settings,
    /// not another app), so its hover zones apply.
    private var isMusicExpanded: Bool {
        if case .expanded(.music) = controller.mode { return true }
        return false
    }

    /// Track which slider the pointer is over so it can thicken on hover.
    private func updateControlHover(at location: NSPoint) {
        guard controller.isHovered else { controller.setHoveredControl(.none); return }
        if controller.volumeRevealed, volumeBarHoverRect().contains(location) {
            controller.setHoveredControl(.volume)
        } else if progressBarHoverRect().contains(location) {
            controller.setHoveredControl(.progress)
        } else {
            controller.setHoveredControl(.none)
        }
    }

    /// Reveal the volume bar when the pointer is over the speaker icon, and
    /// keep it revealed while the pointer stays in the keep zone: the icon plus
    /// everything below the transport row (the bar AND the bottom button row).
    /// The transport (play) buttons are deliberately excluded, and the bottom
    /// row is included so moving onto it doesn't shrink the card out from under
    /// the pointer.
    private func updateVolumeReveal(at location: NSPoint) {
        guard controller.isHovered else { return }
        let revealed = controller.volumeRevealed
            ? (volumeIconRect(pad: 14).contains(location) || volumeLowerRect(pad: 14).contains(location))
            : volumeIconRect(pad: 12).contains(location)
        controller.setVolumeRevealed(revealed)
    }

    /// The island's hover hitbox in screen coordinates (Cocoa, bottom-left
    /// origin) — centred horizontally on the visible blob.
    ///
    /// The visible blob floats `topInset` below the screen's top edge (that gap
    /// is shadow room), but the HITBOX is stretched all the way up to the top of
    /// the screen so the pointer can trigger the island by slamming to the top
    /// edge — there's no dead strip above it. The bottom and width still match
    /// the visible blob, so only the top edge moves.
    private func islandScreenRect(inflatedBy padding: CGFloat = 0) -> NSRect {
        let size = controller.geometry.size
        let frame = panel.frame
        let bottomY = frame.maxY - configuration.topInset - size.height
        let topY = frame.maxY  // screen top edge — no gap above the blob
        let rect = NSRect(x: frame.midX - size.width / 2,
                          y: bottomY,
                          width: size.width,
                          height: topY - bottomY)
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    // MARK: Scroll to switch apps

    /// First-look handler for the local scroll monitor. Returns `nil` to consume
    /// the event (an app switch) or the event itself to let it reach the view under
    /// the cursor (a scrollable list / strip).
    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        // Scroll-to-expand: when that trigger is selected and the card is still
        // compact, a DOWNWARD scroll over the pill commits the expansion. (Under
        // natural scrolling a downward gesture reports a negative deltaY.)
        if controller.settings.expandTrigger == .scroll, !controller.mode.isExpanded {
            if event.scrollingDeltaY < 0 {
                expansionCommitted = true
                controller.interactionHandler?.pointerDidEnter()
                return nil
            }
            return event
        }
        if isOverScrollable(event) {
            if scrollDebug { logScroll("pass→content", event) }
            return event
        }
        let consumed = handleScroll(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        if scrollDebug { logScroll(consumed ? "switch app" : "ignore", event) }
        return consumed ? nil : event
    }

    /// Whether the pointer is over a scroll view (a SwiftUI `ScrollView` or our
    /// `HWheelScroll`) whose content actually overflows — i.e. there's something to
    /// scroll. Walks up from the deepest view under the cursor to the hosting view.
    private func isOverScrollable(_ event: NSEvent) -> Bool {
        guard let root = panel.contentView, let hit = root.hitTest(event.locationInWindow) else { return false }
        var view: NSView? = hit
        while let cur = view {
            if let scroll = cur as? NSScrollView, Self.canScroll(scroll) { return true }
            if cur === root { break }
            view = cur.superview
        }
        return false
    }

    private static func canScroll(_ scroll: NSScrollView) -> Bool {
        guard let doc = scroll.documentView else { return false }
        let clip = scroll.contentView.bounds.size
        // Overflows vertically (a list) or horizontally (a wheel-driven strip).
        return doc.frame.height > clip.height + 1 || doc.frame.width > clip.width + 1
    }

    private func logScroll(_ decision: String, _ event: NSEvent) {
        FileHandle.standardError.write(Data(
            "[scroll] \(decision) dy=\(Int(event.scrollingDeltaY)) precise=\(event.hasPreciseScrollingDeltas)\n".utf8))
    }

    /// Advance the main-island app for a scroll the monitor decided isn't over
    /// scrollable content. Returns `true` when consumed. Only switches while
    /// expanded; one app per gesture (threshold + cooldown).
    private func handleScroll(deltaY: CGFloat, precise: Bool) -> Bool {
        guard case .expanded = controller.mode else {
            scrollAccum = 0
            return false
        }
        // Accumulate until we cross the threshold, then advance one app and start a
        // cooldown that swallows the rest of the gesture (trackpad momentum / a
        // rapid burst of wheel notches).
        if Date().timeIntervalSince(lastScrollSwitch) > scrollSwitchCooldown {
            scrollAccum += deltaY
            if abs(scrollAccum) >= scrollThreshold(precise: precise) {
                // Scroll down (negative delta under natural scrolling) → next app.
                controller.cycleApp(by: scrollAccum < 0 ? 1 : -1)
                scrollAccum = 0
                lastScrollSwitch = Date()
            }
        } else {
            scrollAccum = 0
        }
        return true
    }

    // MARK: Volume hover zones (screen coordinates, Cocoa origin)

    /// Y offset (down from the card's top edge) of the transport row's top —
    /// where the volume speaker icon lives. The expanded layout is top-anchored
    /// with fixed metrics, so this is the same whether or not the bar is shown.
    private var transportTopOffset: CGFloat {
        configuration.expandedVMargin
            + configuration.topRowHeight + configuration.expandedRowSpacing
            + configuration.progressRowHeight + configuration.expandedRowSpacing
    }

    private var transportBottomOffset: CGFloat {
        transportTopOffset + configuration.transportRowHeight
    }

    private var cardTopY: CGFloat { panel.frame.maxY - configuration.topInset }
    /// Left edge of the music *content* (right of the sidebar) within the
    /// expanded card, which is centred and includes the app sidebar on its left.
    private var cardLeftX: CGFloat {
        panel.frame.midX - configuration.expandedTotalWidth / 2 + configuration.sidebarWidth
    }

    /// Zone over the speaker icon (left end of the transport row only — not the
    /// centered play buttons). Entering it reveals the volume bar.
    private func volumeIconRect(pad: CGFloat) -> NSRect {
        let top = cardTopY - transportTopOffset
        let bottom = cardTopY - transportBottomOffset
        let width = configuration.expandedHMargin + 56
        return NSRect(x: cardLeftX - pad,
                      y: bottom - pad,
                      width: width + pad,
                      height: (top - bottom) + 2 * pad)
    }

    /// Everything below the transport row, across the PLAYER column — the volume
    /// bar and the bottom (shuffle/AirPlay/repeat) row. Keeping this in the zone
    /// means the card won't shrink while the pointer is anywhere in the lower half.
    /// Uses `musicPlayerWidth` (not the full content width) since the queue sidebar
    /// occupies the right part of the content.
    private func volumeLowerRect(pad: CGFloat) -> NSRect {
        let top = cardTopY - transportBottomOffset
        let bottom = cardTopY - configuration.expandedVolumeHeight
        return NSRect(x: cardLeftX - pad,
                      y: bottom - pad,
                      width: configuration.musicPlayerWidth + 2 * pad,
                      height: (top - bottom) + 2 * pad)
    }

    // Hover bands around each slider (for thickening). Slightly padded so the
    // track is easy to land on. Spans the PLAYER column width (the queue sidebar
    // sits to its right).
    private func sliderHoverRect(topOffset: CGFloat, rowHeight: CGFloat) -> NSRect {
        let pad: CGFloat = 9
        let top = cardTopY - (topOffset - pad)
        let bottom = cardTopY - (topOffset + rowHeight + pad)
        let left = cardLeftX + configuration.expandedHMargin - pad
        let width = configuration.musicPlayerWidth - 2 * configuration.expandedHMargin + 2 * pad
        return NSRect(x: left, y: bottom, width: width, height: top - bottom)
    }

    private func progressBarHoverRect() -> NSRect {
        // The bar sits at the top of the progress row (above the time labels).
        let topOffset = configuration.expandedVMargin
            + configuration.topRowHeight + configuration.expandedRowSpacing
        return sliderHoverRect(topOffset: topOffset, rowHeight: 14)
    }

    private func volumeBarHoverRect() -> NSRect {
        let topOffset = transportBottomOffset + configuration.expandedRowSpacing
        return sliderHoverRect(topOffset: topOffset, rowHeight: configuration.volumeRowHeight)
    }

    // MARK: Positioning

    /// Anchors the canvas so its top edge is flush with the top of the display
    /// and its horizontal centre matches the display's centre — i.e. over the
    /// notch / menu-bar centre. The gap below the top edge is applied inside
    /// the view (`configuration.topInset`), leaving room for the shadow.
    private func reposition() {
        guard let screen = targetScreen() else { return }
        let frame = screen.frame
        let origin = NSPoint(
            x: frame.midX - configuration.canvasWidth / 2,
            y: frame.maxY - configuration.canvasHeight
        )
        panel.setFrameOrigin(origin)
    }

    /// Prefers a notched display (so the island sits at the notch); otherwise
    /// falls back to the main display.
    private func targetScreen() -> NSScreen? {
        if #available(macOS 12.0, *) {
            if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
                return notched
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
