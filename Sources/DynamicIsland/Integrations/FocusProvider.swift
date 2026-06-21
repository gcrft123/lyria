import AppKit
import Foundation
import SwiftUI

/// Mirrors Focus / Do Not Disturb changes onto the island.
///
/// Modern macOS keeps no public API or notification for the active Focus; the
/// state lives in the (undocumented) DoNotDisturb database at
/// `~/Library/DoNotDisturb/DB/Assertions.json`, which lists an assertion record
/// per active Focus along with its mode identifier. We watch that file (reusing
/// `FileWatcher`), parse out the active mode on each change, and present a
/// banner — naming the mode via `ModeConfigurations.json` when possible
/// ("Do Not Disturb", "Work", "Sleep", …) and falling back to "Focus".
///
/// Two important constraints:
///   • Reading the file needs **Full Disk Access** (the same grant
///     `NotificationProvider` already requires). When it's missing we read
///     nothing and stay silent rather than guessing — no duplicate prompt.
///   • This app's own `FocusController` turns DND *on* to suppress system
///     banners. To avoid announcing that as if the user set it, transitions
///     involving the default DND mode are ignored while the app is asserting it
///     (`FocusController.isAssertingDND`). User-set *named* Focuses are always
///     mirrored.
@MainActor
final class FocusProvider: IslandContentProvider {
    let id = "io.github.gcrft123.lyria.focus"

    private weak var controller: DynamicIslandController?
    /// The app's own DND controller, so we can tell apart the Focus the *user*
    /// set from the DND the *app* turned on to hide system banners.
    private weak var focusController: FocusController?

    private var watchers: [FileWatcher] = []
    private let watchQueue = DispatchQueue(label: "io.github.gcrft123.lyria.focus.watch")
    private var debounce: DispatchWorkItem?

    /// Active mode identifier last observed (nil = no Focus active), so banners
    /// fire only on real transitions.
    private var lastModeID: String?

    private let accent = Color.purple
    private let bannerDuration: TimeInterval = 3.0
    private let mockMode = ProcessInfo.processInfo.environment["DI_MOCK_FOCUS"] == "1"

    private static let defaultDNDMode = "com.apple.donotdisturb.mode.default"

    init(focusController: FocusController?) {
        self.focusController = focusController
    }

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        if mockMode {
            present(name: "Do Not Disturb", active: true, symbol: "moon.fill")
            return
        }

        // Prime current state silently so an already-active Focus at launch isn't
        // announced — only changes from here surface.
        if let primed = readState() { lastModeID = primed.modeID }

        // Watch both the assertions file and its parent directory: the file is
        // rewritten atomically (replacing the inode), which the directory watch
        // and FileWatcher's re-arm-on-rename both catch.
        let onChange: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.scheduleRead() }
        }
        for path in [Self.assertionsPath, Self.dbDirectory] {
            let watcher = FileWatcher(path: path, queue: watchQueue, onChange: onChange)
            watcher.start()
            watchers.append(watcher)
        }
    }

    func stopObserving() {
        debounce?.cancel()
        debounce = nil
        watchers.forEach { $0.stop() }
        watchers.removeAll()
    }

    /// Coalesce a burst of writes into a single read once the change settles.
    private func scheduleRead() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readAndPresent() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func readAndPresent() {
        guard let state = readState() else { return } // unreadable (no FDA) → stay quiet

        let newMode = state.modeID
        guard newMode != lastModeID else { return }    // not a real transition
        let previous = lastModeID
        lastModeID = newMode

        // Ignore the default DND that *this app* toggles to suppress banners.
        if focusController?.isAssertingDND == true {
            if newMode == Self.defaultDNDMode || previous == Self.defaultDNDMode {
                return
            }
        }

        if let mode = newMode {
            present(name: state.name ?? "Focus", active: true, symbol: Self.symbol(forModeID: mode))
        } else {
            let priorName = previous.map { Self.displayName(forModeID: $0) } ?? "Focus"
            present(name: priorName, active: false, symbol: "moon")
        }
    }

    private func present(name: String, active: Bool, symbol: String) {
        controller?.presentPopup(IslandPopup(
            id: "focus.\(active ? "on" : "off")",
            style: .liveActivity,
            title: name,
            message: active ? "On" : "Off",
            icon: .symbol(symbol),
            accent: accent,
            autoDismissAfter: bannerDuration))
    }

    // MARK: Parsing

    private struct FocusState {
        /// Identifier of the active Focus mode, or nil when none is active.
        let modeID: String?
        /// Friendly name for `modeID`, when resolvable.
        let name: String?
    }

    /// Read the current Focus state. Returns nil only when the file can't be read
    /// because Full Disk Access is missing (so we stay quiet); a missing or empty
    /// file is reported as "no Focus active".
    private func readState() -> FocusState? {
        let url = URL(fileURLWithPath: Self.assertionsPath)
        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data)
            let modeID = Self.firstModeIdentifier(in: json)
            return FocusState(modeID: modeID,
                              name: modeID.map { Self.displayName(forModeID: $0) })
        } catch let error as NSError {
            if Self.isPermissionDenied(error) { return nil }   // no FDA → unknown
            return FocusState(modeID: nil, name: nil)          // absent/corrupt → none
        }
    }

    /// Recursively find the first `assertionDetailsModeIdentifier` in the parsed
    /// JSON. Its presence means a Focus is active; its absence means none is.
    private static func firstModeIdentifier(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let mode = dict["assertionDetailsModeIdentifier"] as? String { return mode }
            for value in dict.values {
                if let found = firstModeIdentifier(in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let found = firstModeIdentifier(in: value) { return found }
            }
        }
        return nil
    }

    /// A friendly name for a mode identifier: the built-in DND, a configured
    /// Focus name from `ModeConfigurations.json`, a prettified reverse-DNS tail,
    /// or the generic "Focus".
    private static func displayName(forModeID modeID: String) -> String {
        if modeID == defaultDNDMode { return "Do Not Disturb" }
        if let name = modeName(forIdentifier: modeID) { return name }
        if modeID.hasPrefix("com.apple."),
           let tail = modeID.split(separator: ".").last {
            return String(tail).capitalized
        }
        return "Focus"
    }

    /// Resolve a Focus mode's configured name from `ModeConfigurations.json`
    /// (best-effort; returns nil if the file is unreadable or the shape differs).
    private static func modeName(forIdentifier identifier: String) -> String? {
        let url = URL(fileURLWithPath: dbDirectory).appendingPathComponent("ModeConfigurations.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return findModeName(identifier: identifier, in: json)
    }

    private static func findModeName(identifier: String, in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let entry = dict[identifier], let name = extractName(entry) { return name }
            for value in dict.values {
                if let name = findModeName(identifier: identifier, in: value) { return name }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let name = findModeName(identifier: identifier, in: value) { return name }
            }
        }
        return nil
    }

    private static func extractName(_ any: Any) -> String? {
        guard let dict = any as? [String: Any] else { return nil }
        if let name = dict["name"] as? String, !name.isEmpty { return name }
        if let mode = dict["mode"] as? [String: Any],
           let name = mode["name"] as? String, !name.isEmpty { return name }
        return nil
    }

    /// A glyph for the Focus. Custom Focuses are identified by UUID (no name to
    /// match on) and fall through to the crescent moon.
    private static func symbol(forModeID id: String) -> String {
        switch id {
        case defaultDNDMode:                  return "moon.fill"
        case let s where s.contains("sleep"): return "bed.double.fill"
        case let s where s.contains("work"):  return "briefcase.fill"
        case let s where s.contains("personal"): return "person.crop.circle.fill"
        case let s where s.contains("driving"):  return "car.fill"
        case let s where s.contains("fitness"):  return "figure.run"
        case let s where s.contains("gaming"):   return "gamecontroller.fill"
        case let s where s.contains("reading"):  return "book.fill"
        case let s where s.contains("mindful"):  return "brain.head.profile"
        default:                                 return "moon.fill"
        }
    }

    // MARK: Errors / paths

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) {
            return true
        }
        return false
    }

    private static var dbDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB").path
    }

    private static var assertionsPath: String {
        dbDirectory + "/Assertions.json"
    }
}
