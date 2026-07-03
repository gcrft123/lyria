import AppKit
import Combine
import SwiftUI

/// Owns the island panels: one per enabled+connected display, so the island is
/// cloned onto each screen. Hover / clicks / scroll / the pin corner are routed to
/// whichever panel the cursor is over; the shared `DynamicIslandController` resolves
/// per-display state (only the screen under the cursor expands; a HUD shows only on
/// its screen).
@MainActor
final class IslandWindowController: NSObject {

    private let controller: DynamicIslandController
    private let configuration: IslandConfiguration

    /// One panel per enabled+connected display.
    private var panels: [CGDirectDisplayID: IslandPanel] = [:]
    /// The display the cursor is currently over (has a panel), for routing.
    private var activeDisplayID: CGDirectDisplayID?
    /// The panel under the cursor, else any panel (for focus/keyboard).
    private var activePanel: IslandPanel? { (activeDisplayID.flatMap { panels[$0] }) ?? panels.values.first }

    private var hoverTimer: Timer?

    /// Pending collapse, scheduled when the pointer leaves and cancelled if it
    /// comes back — see `updateHover`.
    private var exitWorkItem: DispatchWorkItem?

    /// For the `.click` / `.scroll` expand triggers: whether the user has performed
    /// the trigger gesture during the current visit, so the island should stay
    /// expanded while the pointer remains over it.
    private var expansionCommitted = false

    /// Forgiveness margin around the COMPACT pill for hit-testing.
    private let hoverPadding: CGFloat = 8
    /// A more generous margin once the island is EXPANDED.
    private let expandedHoverPadding: CGFloat = 26
    /// The effective margin for the active display — bigger when its card is expanded.
    private var activeHoverPadding: CGFloat {
        let expanded = activeDisplayID.map { controller.mode(for: $0).isExpanded } ?? false
        return expanded ? expandedHoverPadding : hoverPadding
    }

    /// How long the island stays expanded after the pointer leaves before collapsing.
    private let exitGrace: TimeInterval = 0.13

    // MARK: Scroll-to-switch state

    private var scrollAccum: CGFloat = 0
    private var lastScrollSwitch: Date = .distantPast
    private let scrollSwitchCooldown: TimeInterval = 0.3
    private func scrollThreshold(precise: Bool) -> CGFloat { precise ? 28 : 1 }
    private var scrollMonitor: Any?
    private let scrollDebug = ProcessInfo.processInfo.environment["DI_DEBUG_SCROLL"] == "1"
    private var cancellables: Set<AnyCancellable> = []

    init(controller: DynamicIslandController) {
        self.controller = controller
        self.configuration = controller.configuration
        super.init()

        // Editing a timer name / search field needs the keyboard, so focus the
        // (normally non-activating) panel while a text field is up, then hand it back.
        controller.onEditingChange = { [weak self] editing in
            self?.setPanelEditing(editing)
        }
    }

    // MARK: Panels

    /// Build a panel for `displayID`, hosting the island bound to that display, with
    /// the popup / click-to-expand handlers wired to it.
    private func makePanel(displayID: CGDirectDisplayID, screen: NSScreen) -> IslandPanel {
        let canvas = NSRect(x: 0, y: 0, width: configuration.canvasWidth, height: configuration.canvasHeight)
        let panel = IslandPanel(contentRect: canvas, configuration: configuration)

        let root = DynamicIslandView(controller: controller, displayID: displayID)
            .environmentObject(controller.settings)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = canvas
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // While a popup owns the island, clicks act on it (left = open/dismiss,
        // right = dismiss). With no popup these return false so SwiftUI controls
        // (transport, sidebar, gear) get the click as before.
        hosting.onMouseDown = { [weak self] in
            guard let self else { return false }
            if self.controller.activePopup != nil {
                // A live-activity notification that opens an app reveals it under the
                // pointer (NOT pinned): commit the expansion so it holds for any
                // trigger, then collapses normally when the pointer leaves.
                let opensApp = self.controller.activePopup?.app != nil
                self.controller.activatePopup()
                if opensApp {
                    self.expansionCommitted = true
                    self.controller.interactionHandler?.pointerDidEnter(display: displayID)
                }
                return true
            }
            // Click-to-expand: on the `.click` trigger, the first click on this
            // display's compact pill commits its expansion (and is consumed).
            if self.controller.settings.expandTrigger == .click, !self.controller.mode(for: displayID).isExpanded {
                self.expansionCommitted = true
                self.controller.interactionHandler?.pointerDidEnter(display: displayID)
                return true
            }
            return false
        }
        hosting.onRightMouseDown = { [weak self] in
            guard let self, self.controller.activePopup != nil else { return false }
            self.controller.dismissPopup()
            return true
        }

        position(panel, on: screen)
        panel.acceptsMouseMovedEvents = true
        panel.orderFrontRegardless()
        return panel
    }

    /// Anchor a panel so its top edge is flush with the screen's top and its centre
    /// matches the screen centre (over the notch / menu-bar centre).
    private func position(_ panel: IslandPanel, on screen: NSScreen) {
        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - configuration.canvasWidth / 2,
                                     y: frame.maxY - configuration.canvasHeight))
    }

    /// Create / remove / reposition panels so there's exactly one per enabled display.
    private func reconcile() {
        let wanted = Dictionary(uniqueKeysWithValues: enabledScreens().compactMap { screen in
            DisplayCatalog.displayID(of: screen).map { ($0, screen) }
        })
        for (id, panel) in panels where wanted[id] == nil {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for (id, screen) in wanted {
            if let existing = panels[id] { position(existing, on: screen) }
            else { panels[id] = makePanel(displayID: id, screen: screen) }
        }
    }

    /// The screens the island should appear on — those the user hasn't opted out of.
    /// Falls back to every screen if they've turned all of them off (so it never
    /// vanishes).
    private func enabledScreens() -> [NSScreen] {
        let enabled = NSScreen.screens.filter { screen in
            guard let id = DisplayCatalog.displayID(of: screen),
                  let uuid = DisplayCatalog.persistentID(for: id) else { return true }
            return controller.settings.showsIsland(onDisplay: uuid)
        }
        return enabled.isEmpty ? NSScreen.screens : enabled
    }

    /// Hide / show every island panel (e.g. while the onboarding takeover owns the
    /// screen, so the real islands never peek through behind it).
    func setVisible(_ visible: Bool) {
        for panel in panels.values { visible ? panel.orderFrontRegardless() : panel.orderOut(nil) }
    }

    // MARK: Keyboard focus (in-island text editing)

    private var appToRestoreFocus: NSRunningApplication?

    /// Give/return keyboard focus for in-island text editing — on the panel the
    /// cursor is over (where the field is).
    private func setPanelEditing(_ editing: Bool) {
        if editing {
            let me = NSRunningApplication.current
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != me.processIdentifier {
                appToRestoreFocus = front
            }
            NSApp.activate(ignoringOtherApps: true)
            activePanel?.makeKeyAndOrderFront(nil)
        } else {
            activePanel?.makeFirstResponder(nil)
            restorePreviousAppFocus()
        }
    }

    private func restorePreviousAppFocus() {
        if let prev = appToRestoreFocus, !prev.isTerminated {
            appToRestoreFocus = nil
            prev.activate(options: [.activateIgnoringOtherApps])
        } else {
            appToRestoreFocus = nil
            NSApp.deactivate()
        }
    }

    // MARK: Lifecycle

    /// Places the panels on screen and starts tracking layout / setting changes.
    func show() {
        reconcile()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Re-clone when the user toggles which displays show the island.
        controller.settings.$islandDisplayOptOut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)

        startHoverTracking()

        // Scroll-to-switch-apps: a local monitor gets first look at every wheel event
        // over a panel, before any NSScrollView swallows it.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollEvent(event) ?? event
        }

        if ProcessInfo.processInfo.environment["DI_DEBUG_SCROLL"] == "1" {
            for delay in [3.0, 5.0, 7.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.debugDumpScrollViews()
                }
            }
        }
    }

    private func debugDumpScrollViews() {
        guard let root = activePanel?.contentView else { return }
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
        reconcile()
    }

    // MARK: Hover

    private func startHoverTracking() {
        // ~33 Hz: cheap (a point read + rect tests) and reacts with no perceptible delay.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func updateHover() {
        let location = NSEvent.mouseLocation

        // The panel on the display the cursor is over (if that display shows the island).
        let cursorDisplay = NSScreen.screens.first { $0.frame.contains(location) }
            .flatMap { DisplayCatalog.displayID(of: $0) }
        let active: (id: CGDirectDisplayID, panel: IslandPanel)? =
            cursorDisplay.flatMap { id in panels[id].map { (id, $0) } }
        activeDisplayID = active?.id

        // Only the panel under the cursor may capture events; the rest pass through.
        for (id, panel) in panels where id != active?.id { panel.ignoresMouseEvents = true }

        // Popups own the island (cloned on every screen); the active panel captures +
        // grows it. For the immunity tail after it clears we keep collapsed.
        if controller.activePopup != nil {
            exitWorkItem?.cancel(); exitWorkItem = nil
            if let active {
                active.panel.ignoresMouseEvents = false
                controller.setPopupHovered(
                    islandRect(for: active.panel, displayID: active.id, inflatedBy: activeHoverPadding).contains(location))
            } else {
                controller.setPopupHovered(false)
            }
            if controller.isHovered { controller.setHovered(nil) }
            return
        }
        if controller.blocksHoverActivation {
            active?.panel.ignoresMouseEvents = true
            if controller.isHovered { controller.setHovered(nil) }
            return
        }

        guard let active else {
            // Cursor isn't over any island's screen → outside every island.
            handleOutside()
            return
        }

        // `inside` tracks the POINTER over the active display's island — not the
        // editing state — so a clear exit while a field is focused ends editing.
        let inside = islandRect(for: active.panel, displayID: active.id, inflatedBy: activeHoverPadding).contains(location)

        if inside {
            exitWorkItem?.cancel(); exitWorkItem = nil
            active.panel.ignoresMouseEvents = false

            // For `.hover` just being inside expands; `.click`/`.scroll` wait for the
            // committed gesture. An already-expanded card stays open while inside.
            let shouldExpand = controller.settings.expandTrigger == .hover
                || expansionCommitted
                || controller.pinned
                || controller.isEditing
                || controller.mode(for: active.id).isExpanded

            if shouldExpand {
                controller.interactionHandler?.pointerDidEnter(display: active.id)
                controller.setPinCornerHovered(controller.mode(for: active.id).isExpanded
                    && pinCornerRect(for: active.panel, displayID: active.id).contains(location))
            } else {
                // Over the compact pill, waiting for the click/scroll gesture: capture
                // events (to detect it) but stay collapsed.
                if controller.hoveredDisplay == active.id { controller.setHovered(nil) }
                controller.setPinCornerHovered(false)
            }
        } else {
            active.panel.ignoresMouseEvents = true
            controller.setPinCornerHovered(false)
            handleOutside()
        }
    }

    /// Exit path when the cursor is outside every island — hold the expanded state
    /// briefly (grace), or collapse if nothing keeps it open.
    private func handleOutside() {
        if controller.isHovered || controller.isEditing {
            scheduleExitIfNeeded()
        } else {
            expansionCommitted = false
            controller.interactionHandler?.pointerDidExit()
        }
    }

    /// Zone over the active card's top-right corner, where the pin affordance sits.
    private func pinCornerRect(for panel: IslandPanel, displayID: CGDirectDisplayID) -> NSRect {
        let size = controller.geometry(for: displayID).size
        let rightX = panel.frame.midX + size.width / 2
        let topY = panel.frame.maxY - configuration.topInset
        let reach: CGFloat = 52   // inward from the corner
        let out: CGFloat = 14     // a touch past the corner (the button overhangs)
        return NSRect(x: rightX - reach, y: topY - reach, width: reach + out, height: reach + out)
    }

    /// Arms a one-shot collapse `exitGrace` from now (if not already armed). When it
    /// fires it re-checks whether the pointer is over ANY island (a re-entry — even
    /// onto another display's island — keeps things open).
    private func scheduleExitIfNeeded() {
        guard exitWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.exitWorkItem = nil
            let loc = NSEvent.mouseLocation
            let overAny = self.panels.contains { id, panel in
                self.islandRect(for: panel, displayID: id, inflatedBy: self.activeHoverPadding).contains(loc)
            }
            if !overAny {
                // End any text editing so a focused field doesn't pin the island open
                // after the pointer has clearly left.
                if self.controller.isEditing { self.controller.endEditing() }
                self.expansionCommitted = false
                self.controller.interactionHandler?.pointerDidExit()
            }
        }
        exitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + exitGrace, execute: work)
    }

    /// A panel's island hitbox in screen coordinates. The visible blob floats
    /// `topInset` below the screen top (shadow room), but the hitbox stretches to the
    /// very top edge so slamming the pointer up triggers the island.
    private func islandRect(for panel: IslandPanel, displayID: CGDirectDisplayID, inflatedBy padding: CGFloat = 0) -> NSRect {
        let size = controller.geometry(for: displayID).size
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

    /// First-look handler for the local scroll monitor. Returns `nil` to consume the
    /// event (an app switch / expansion) or the event to let it reach the view under
    /// the cursor (a scrollable list / strip).
    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        guard let win = event.window as? IslandPanel,
              let displayID = panels.first(where: { $0.value === win })?.key else { return event }

        // Scroll-to-expand: on the `.scroll` trigger, a downward scroll over this
        // display's compact pill commits its expansion.
        if controller.settings.expandTrigger == .scroll, !controller.mode(for: displayID).isExpanded {
            if event.scrollingDeltaY < 0 {
                expansionCommitted = true
                controller.interactionHandler?.pointerDidEnter(display: displayID)
                return nil
            }
            return event
        }
        if isOverScrollable(event, in: win) {
            if scrollDebug { logScroll("pass→content", event) }
            return event
        }
        let consumed = handleScroll(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        if scrollDebug { logScroll(consumed ? "switch app" : "ignore", event) }
        return consumed ? nil : event
    }

    /// Whether the pointer is over an overflowing scroll view in `panel`.
    private func isOverScrollable(_ event: NSEvent, in panel: IslandPanel) -> Bool {
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
        return doc.frame.height > clip.height + 1 || doc.frame.width > clip.width + 1
    }

    private func logScroll(_ decision: String, _ event: NSEvent) {
        FileHandle.standardError.write(Data(
            "[scroll] \(decision) dy=\(Int(event.scrollingDeltaY)) precise=\(event.hasPreciseScrollingDeltas)\n".utf8))
    }

    /// Advance the main-island app for a scroll not over scrollable content. Only
    /// switches while the focused island is expanded; one app per gesture.
    private func handleScroll(deltaY: CGFloat, precise: Bool) -> Bool {
        guard case .expanded = controller.mode else {
            scrollAccum = 0
            return false
        }
        if Date().timeIntervalSince(lastScrollSwitch) > scrollSwitchCooldown {
            scrollAccum += deltaY
            if abs(scrollAccum) >= scrollThreshold(precise: precise) {
                controller.cycleApp(by: scrollAccum < 0 ? 1 : -1)
                scrollAccum = 0
                lastScrollSwitch = Date()
            }
        } else {
            scrollAccum = 0
        }
        return true
    }
}
