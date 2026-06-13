import AppKit
import ApplicationServices

/// Lists the switchable windows and focuses one — the data layer behind the
/// Alt+Tab switcher.
///
/// The list is a HYBRID across all desktops, because neither source alone works:
///   • The **Accessibility API** (`kAXWindowsAttribute`) gives the clean, real
///     STANDARD-window set — but only for the CURRENT Space (macOS hides other
///     Spaces' windows from AX).
///   • **`CGWindowListCopyWindowInfo`** (no `.optionOnScreenOnly`) spans every
///     Space + minimized — but returns the window server's whole bag (panels,
///     popovers, background helpers), which reads as "every app".
/// So we drive off CGWindowList (front-to-back order, all Spaces) and keep a window
/// only if it's EITHER an AX-validated standard window (current Space → clean) OR,
/// when off-screen (another Space / minimized, where AX can't see it), it passes a
/// "looks like a real window" heuristic: a `.regular` app that HAS real windows,
/// a non-empty title, and a decent size. Thumbnails need Screen Recording
/// (off-Space → nil → app-icon fallback). Focus raises the AX element directly
/// (current Space); off-Space windows can only activate the app (no AX handle).
///
/// Needs **Accessibility** permission (shared with the HUD); without it the AX
/// validation is skipped and the heuristic alone is used so the list isn't empty.
enum WindowEnumerator {

    /// All real windows across every desktop/Space, MOST-RECENTLY-USED first.
    @MainActor
    static func currentWindows() -> [WindowInfo] {
        let myPID = ProcessInfo.processInfo.processIdentifier

        // 1. AX standard windows for the CURRENT Space: id → element / title.
        //
        // This is the bottleneck for opening the switcher: each app needs several
        // cross-process Accessibility round-trips, and done serially across ~20 apps
        // that was ~750ms. AX calls are thread-safe, so we fan the per-app queries
        // out with `concurrentPerform` — total time drops to roughly the SLOWEST
        // single app instead of the sum. Each worker collects locally, then merges
        // under a lock (the lock is only held for the cheap merge, not the AX work).
        var axElementByID: [CGWindowID: AXUIElement] = [:]
        var axTitleByID: [CGWindowID: String] = [:]
        var appByPID: [pid_t: NSRunningApplication] = [:]

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != myPID && !$0.isTerminated
        }
        for app in apps { appByPID[app.processIdentifier] = app }

        let mergeLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let pid = apps[index].processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.25) // don't stall on a wedged app
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement]
            else { return }
            var local: [(CGWindowID, AXUIElement, String)] = []
            for window in windows {
                if let subrole = axString(window, kAXSubroleAttribute),
                   subrole != (kAXStandardWindowSubrole as String) { continue }
                guard let wid = axWindowID(window) else { continue }
                local.append((wid, window, axString(window, kAXTitleAttribute) ?? ""))
            }
            guard !local.isEmpty else { return }
            mergeLock.lock()
            for (wid, element, title) in local {
                axElementByID[wid] = element
                axTitleByID[wid] = title
            }
            mergeLock.unlock()
        }

        // 2. Walk CGWindowList (all Spaces, front-to-back) and keep the real ones.
        guard let raw = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // Collect kept windows with their front-to-back index (the tiebreaker
        // within an app), then sort most-recently-used app first.
        var collected: [(info: WindowInfo, order: Int)] = []
        var seen = Set<CGWindowID>()
        for dict in raw {
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = dict[kCGWindowNumber as String] as? CGWindowID, !seen.contains(number),
                  let pid = dict[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let app = appByPID[pid]   // a regular, non-terminated app
            else { continue }
            if let alpha = dict[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            guard let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            let cgTitle = (dict[kCGWindowName as String] as? String) ?? ""
            let axElement = axElementByID[number]

            // Decide whether to keep + which title to show.
            let keep: Bool
            let title: String
            if axElement != nil {
                // Current Space, AX-validated as a real STANDARD window → keep at
                // any size (small real windows are legitimate when AX vouches).
                keep = true
                title = axTitleByID[number] ?? cgTitle
            } else {
                // Not AX-validated — either on ANOTHER Space (AX can't see it) or an
                // on-screen non-standard window AX rejected (a panel/popover). AX
                // can't tell us which, so require a real DOCUMENT-WINDOW signature:
                // a non-empty title and a real size. This is what excludes the
                // small off-Space auxiliary/helper windows the user flagged
                // (Mail "iCloud Mail Cleanup" 420×632, Numbers "Usage Status (Beta)"
                // 360×194, Music "MiniPlayer" 600×146, an IDE "Launchpad" 600×600,
                // status/menu strips, etc.) while keeping every real document
                // window (which on this machine were all ≥960 wide). The app is
                // already a `.regular` app, and we do NOT require a current-Space
                // window so apps living entirely on another desktop still show.
                keep = !cgTitle.isEmpty && bounds.width >= 700 && bounds.height >= 400
                title = cgTitle
            }
            guard keep else { continue }

            seen.insert(number)
            // NOTE: no thumbnail here — capturing one per window (CGWindowListCreateImage)
            // is the slow part, so the switcher loads them ASYNCHRONOUSLY after the
            // overlay is already on screen (see WindowSwitcher.begin). This keeps the
            // synchronous enumeration (run on the main thread before the overlay shows)
            // cheap.
            collected.append((WindowInfo(
                id: number, pid: pid, appName: app.localizedName ?? "",
                title: title, icon: app.icon, thumbnail: nil,
                axElement: axElement), collected.count))
        }

        // 3. Order most-recently-used first: by the app's last-activation rank
        //    (desc), then front-to-back stacking within the app (asc).
        let tracker = WindowActivationTracker.shared
        return collected.sorted { lhs, rhs in
            let rankL = tracker.rank(for: lhs.info.pid)
            let rankR = tracker.rank(for: rhs.info.pid)
            if rankL != rankR { return rankL > rankR }
            return lhs.order < rhs.order
        }.map { $0.info }
    }

    /// Debug: dump the raw CoreGraphics + AX properties of every layer-0 window
    /// owned by a regular app, so we can see what distinguishes real windows from
    /// helper/non-windows. `DI_MOCK_SWITCHER=dump`.
    static func debugDump() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var axIDs = Set<CGWindowID>()
        var appByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != myPID && !app.isTerminated {
            appByPID[app.processIdentifier] = app
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &v) == .success,
               let ws = v as? [AXUIElement] {
                for w in ws { if let id = axWindowID(w) { axIDs.insert(id) } }
            }
        }
        guard let raw = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var lines: [String] = []
        for dict in raw {
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = dict[kCGWindowNumber as String] as? CGWindowID,
                  let pid = dict[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  appByPID[pid] != nil else { continue }
            let title = dict[kCGWindowName as String] as? String ?? ""
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
            let onscreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
            let sharing = dict[kCGWindowSharingState as String] as? Int ?? -1
            let store = dict[kCGWindowStoreType as String] as? Int ?? -1
            let alpha = dict[kCGWindowAlpha as String] as? Double ?? -1
            var size = "?"
            if let bd = dict[kCGWindowBounds as String] as? NSDictionary,
               let b = CGRect(dictionaryRepresentation: bd as CFDictionary) {
                size = "\(Int(b.width))x\(Int(b.height))"
            }
            let hasThumb = thumbnail(for: number) != nil
            lines.append("[\(owner)] '\(title)' on=\(onscreen) ax=\(axIDs.contains(number)) size=\(size) share=\(sharing) store=\(store) alpha=\(alpha) thumb=\(hasThumb)")
        }
        FileHandle.standardError.write(Data(("DI_SWITCHER_DUMP\n" + lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Capture thumbnails for a set of windows. Pure CoreGraphics (no AX), so it's
    /// safe to call off the main thread — the switcher does this asynchronously
    /// AFTER the overlay is visible, so the expensive captures never delay the open.
    static func thumbnails(for ids: [CGWindowID]) -> [CGWindowID: NSImage] {
        var result: [CGWindowID: NSImage] = [:]
        for id in ids {
            if let image = thumbnail(for: id) { result[id] = image }
        }
        return result
    }

    /// A scaled snapshot of one window, or `nil` without Screen Recording / for a
    /// window on another Space.
    private static func thumbnail(for id: CGWindowID) -> NSImage? {
        guard let cg = CGWindowListCreateImage(
            .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]),
              cg.width > 1, cg.height > 1
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Focus

    /// Bring `window`'s app to the front and raise that exact window.
    static func focus(_ window: WindowInfo) {
        NSRunningApplication(processIdentifier: window.pid)?
            .activate(options: [.activateIgnoringOtherApps])
        guard let element = window.axElement else { return }
        // Un-minimize (the window may be minimized / on another Space), make it the
        // main window, and raise it.
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    // MARK: AX helpers

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
           let string = value as? String {
            return string
        }
        return nil
    }

    // `_AXUIElementGetWindow(AXUIElementRef, CGWindowID*)` — private, the only way
    // to map an AX window to its CoreGraphics number (for the thumbnail). Resolved
    // at runtime via RTLD_DEFAULT so we don't link a private symbol.
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowFn: GetWindowFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    private static func axWindowID(_ element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindowFn else { return nil }
        var wid = CGWindowID(0)
        return fn(element, &wid) == .success ? wid : nil
    }
}
