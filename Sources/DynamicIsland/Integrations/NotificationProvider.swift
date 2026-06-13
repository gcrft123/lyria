import AppKit
import Foundation
import SQLite3

/// Integration seam for surfacing system notifications on the island.
///
/// Mirrors *every* macOS notification into the island's popup framework by
/// reading Notification Center's own store — the SQLite database at
/// `~/Library/Group Containers/group.com.apple.usernoted/db2/db`. There is no
/// public API to observe other apps' banners, so we poll that database for new
/// `record` rows, decode each one's binary-plist payload (`titl` / `subt` /
/// `body`), resolve the sending app via the `app` table's bundle id, and hand
/// the result to `controller.presentPopup` wearing that app's real icon.
///
/// Reading the database requires **Full Disk Access** (granted in System
/// Settings ▸ Privacy & Security). Without it the copy step fails; we surface a
/// one-time popup asking for the permission and otherwise stay quiet.
@MainActor
protocol NotificationIslandProvider: IslandContentProvider {}

@MainActor
final class NotificationProvider: NotificationIslandProvider {
    let id = "com.dynamicisland.notifications"

    private weak var controller: DynamicIslandController?

    /// Called once the first successful DB read proves we have access (Full Disk
    /// Access granted). Used to enable banner suppression only when mirroring can
    /// actually take over — never when access is missing.
    var onAccessConfirmed: (() -> Void)?
    private var didConfirmAccess = false

    /// Fallback poll cadence. Detection is normally event-driven (see
    /// `startWatching`); this timer is just a safety net for any change the file
    /// watchers miss, or for when they can't arm (e.g. Full Disk Access denied).
    private let pollInterval: TimeInterval = 2.0
    /// Debounce window: collapse a flurry of DB writes into one read.
    private let eventCoalesce: TimeInterval = 0.08
    /// How long each banner stays up before the next takes over. When more
    /// notifications are still queued behind it we cycle faster so a backlog
    /// clears at a watchable pace; when it's the last one we let it linger.
    private let queuedBannerDuration: TimeInterval = 6.0
    private let soloBannerDuration: TimeInterval = 10.0

    private var pollTimer: Timer?
    /// Watches the Notification Center DB files so we can read the instant a
    /// notification is written, instead of waiting out the poll interval.
    private var watchers: [FileWatcher] = []
    /// Coalesces a burst of file-change events into a single read.
    private var eventPollWork: DispatchWorkItem?
    private var pending: [NotificationCenterReader.RawNotification] = []
    /// The earliest the next banner may appear — set to when the current banner
    /// finishes, so queued banners play strictly one after another.
    private var nextSlotAt: Date = .distantPast
    /// The scheduled hand-off to the next queued banner, so we never double up.
    private var pumpWorkItem: DispatchWorkItem?
    private var didWarnNoAccess = false

    /// The database read state lives here; all calls are funnelled through a
    /// serial queue so the cursor (`lastRowID`) is only ever touched off-main
    /// and in order.
    private let reader = NotificationCenterReader()
    private let readerQueue = DispatchQueue(label: "com.dynamicisland.notifications.reader")

    private let ownBundleID = Bundle.main.bundleIdentifier

    private let mockMode = ProcessInfo.processInfo.environment["DI_MOCK_NOTIFICATION"] == "1"

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        // Debug: render a representative system banner without needing Full
        // Disk Access or a real incoming notification.
        if mockMode {
            controller?.presentPopup(IslandPopup(
                id: "mock-notification",
                title: "Pamela Yee",
                message: "Are we still on for dinner tonight?",
                icon: .bundle("com.apple.MobileSMS"),
                launchBundleID: "com.apple.MobileSMS"))
            return
        }

        // Anchor the cursor at the newest existing record so we never replay
        // the backlog — only notifications that arrive *after* launch surface.
        // This read also doubles as the access attempt that registers the app
        // in the Full Disk Access list (a TCC-denied read adds it, toggled off).
        readerQueue.async { [reader] in
            reader.seekToEnd()
        }

        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // React to DB writes in real time so a banner appears right when the
        // system one does, rather than up to a poll-interval later.
        startWatching()

        // Poll once right away so a missing-access state surfaces (and the
        // Full Disk Access pane opens) at launch instead of after the first
        // interval.
        poll()
    }

    func stopObserving() {
        pollTimer?.invalidate()
        pollTimer = nil
        pumpWorkItem?.cancel()
        pumpWorkItem = nil
        eventPollWork?.cancel()
        eventPollWork = nil
        watchers.forEach { $0.stop() }
        watchers.removeAll()
    }

    // MARK: Real-time change watching

    /// Watch the live store's `db`, its `-wal` sidecar (appended on every commit),
    /// and their parent directory (so a checkpoint that recreates the `-wal` is
    /// caught too). Any change schedules a debounced read.
    private func startWatching() {
        let dbPath = reader.databasePath
        let dir = (dbPath as NSString).deletingLastPathComponent
        let onChange: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.scheduleEventPoll() }
        }
        for path in [dbPath + "-wal", dbPath, dir] {
            let watcher = FileWatcher(path: path, queue: readerQueue, onChange: onChange)
            watcher.start()
            watchers.append(watcher)
        }
    }

    /// Coalesce a burst of change events (a commit touches several files) into a
    /// single read a beat later, so we read once the write has settled.
    private func scheduleEventPoll() {
        eventPollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.poll() }
        eventPollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + eventCoalesce, execute: work)
    }

    // MARK: Polling

    private func poll() {
        readerQueue.async { [weak self, reader] in
            let result = reader.newNotifications()
            DispatchQueue.main.async {
                self?.handle(result)
            }
        }
    }

    private func handle(_ result: NotificationCenterReader.ReadResult) {
        switch result {
        case .accessDenied:
            warnNoAccessOnce()
        case .unavailable:
            break // no database (notifications off, or path moved) — stay quiet
        case .ok(let raw):
            // A successful read (even an empty one) confirms Full Disk Access —
            // safe now to let the system's own banners be suppressed.
            if !didConfirmAccess {
                didConfirmAccess = true
                onAccessConfirmed?()
            }
            let mine = ownBundleID
            let usable = raw.filter { note in
                guard note.bundleID != mine else { return false }
                return !(note.title.isEmpty && note.body.isEmpty && note.subtitle.isEmpty)
            }
            pending.append(contentsOf: usable)
            pumpQueue()
        }
    }

    /// Drain the queue one banner at a time. A banner stays up for
    /// `queuedBannerDuration` while others wait behind it, or `soloBannerDuration`
    /// when it's the last one; the following banner is then shown the instant
    /// this one finishes, so a burst plays back-to-back rather than all at once.
    private func pumpQueue() {
        guard !pending.isEmpty, let controller else { return }

        // A banner is still on screen — wait out its slot, then try again.
        let now = Date()
        guard now >= nextSlotAt else {
            scheduleNextPump(at: nextSlotAt)
            return
        }

        let note = pending.removeFirst()
        // More still queued behind this one → cycle fast; otherwise let it linger.
        let duration = pending.isEmpty ? soloBannerDuration : queuedBannerDuration
        nextSlotAt = now.addingTimeInterval(duration)
        controller.presentPopup(makePopup(from: note, duration: duration))

        // Hand off to the next banner exactly when this one finishes.
        if !pending.isEmpty { scheduleNextPump(at: nextSlotAt) }
    }

    /// Schedule a single pending drain for `time`, replacing any earlier one so
    /// the queue can't be pumped twice for the same slot.
    private func scheduleNextPump(at time: Date) {
        pumpWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.pumpQueue() }
        pumpWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, time.timeIntervalSinceNow), execute: item)
    }

    private func makePopup(from note: NotificationCenterReader.RawNotification,
                           duration: TimeInterval) -> IslandPopup {
        let hasBundle = !note.bundleID.isEmpty
        let appName = hasBundle ? Self.appName(for: note.bundleID) : nil
        let title = note.title.isEmpty ? (appName ?? "Notification") : note.title
        let message = note.body.isEmpty ? note.subtitle : note.body
        return IslandPopup(
            id: note.id,
            title: title,
            message: message,
            icon: hasBundle ? .bundle(note.bundleID) : .symbol("bell.fill"),
            launchBundleID: hasBundle ? note.bundleID : nil,
            autoDismissAfter: duration)
    }

    private func warnNoAccessOnce() {
        guard !didWarnNoAccess else { return }
        didWarnNoAccess = true
        FileHandle.standardError.write(Data(
            "DynamicIsland: notification mirroring needs Full Disk Access. Opening System Settings ▸ Privacy & Security ▸ Full Disk Access — turn on DynamicIsland there, then relaunch.\n".utf8))
        // The read above has already registered this app in the Full Disk Access
        // list (toggled off), so jump the user straight to that pane — no need to
        // hunt for the app bundle, which lives in the hidden `.build/` folder.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        controller?.presentPopup(IslandPopup(
            id: "notifications-need-fda",
            title: "Enable notification mirroring",
            message: "Turn on DynamicIsland in Full Disk Access, then relaunch",
            icon: .symbol("bell.badge"),
            accent: .orange,
            autoDismissAfter: 8))
    }

    /// Display name for a bundle id, used only when a notification omits its own
    /// title. Resolved on the main actor via NSWorkspace.
    private static func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

/// Reads new rows from Notification Center's SQLite store. Not main-actor:
/// every method is invoked on the provider's serial reader queue, which also
/// serialises access to `lastRowID`. `@unchecked Sendable` reflects that the
/// serial queue — not the type itself — provides the isolation.
final class NotificationCenterReader: @unchecked Sendable {

    struct RawNotification {
        let recID: Int64
        let bundleID: String
        let title: String
        let subtitle: String
        let body: String
        var id: String { "noted.\(recID)" }
    }

    enum ReadResult {
        /// Successful read (possibly empty) of records newer than the cursor.
        case ok([RawNotification])
        /// The database exists but couldn't be copied — almost always a missing
        /// Full Disk Access grant.
        case accessDenied
        /// No database to read (notifications disabled, or the path moved).
        case unavailable
    }

    /// `rec_id` of the last record we've already surfaced. Only new rows beyond
    /// this are reported.
    private var lastRowID: Int64 = 0

    private var dbPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
            .path
    }

    /// Filesystem path of the live store, exposed so the provider can watch it
    /// (and its `-wal`/parent directory) for changes.
    var databasePath: String { dbPath }

    /// Move the cursor to the newest existing record so the backlog is skipped —
    /// only notifications delivered after launch surface on the island.
    func seekToEnd() {
        if let maxID = readMaxRowID() { lastRowID = maxID }
    }

    func newNotifications() -> ReadResult {
        readNewRows(updatingCursor: true)
    }

    // MARK: Database access

    /// Open a private snapshot copy of the live database. The store runs in WAL
    /// mode and is constantly locked by `usernoted`, so we copy the db plus its
    /// `-wal`/`-shm` sidecars to a throwaway temp file and read that.
    private func withDatabaseCopy<T>(_ body: (OpaquePointer) -> T?) -> Result<T?, ReadError> {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("di-noted-" + UUID().uuidString)
        let tempDB = tempDir.appendingPathComponent("db")
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            // No fileExists pre-check: under a missing Full Disk Access grant even
            // a stat can be blocked, and skipping the open would mean the app
            // never registers in (and so never appears in) the FDA list. We just
            // attempt the read and classify the failure.
            try fm.copyItem(atPath: dbPath, toPath: tempDB.path)
            // Copy ONLY the `-wal`, not the `-shm`: the `-shm` is just the WAL
            // index, and a copy of it can be inconsistent with our copied `-wal`
            // if usernoted checkpoints mid-copy — which makes SQLite read FEWER
            // committed frames and silently drop the newest notification. With no
            // `-shm` present, opening the copy READWRITE forces WAL recovery,
            // which rebuilds the index from the `-wal` and sees every valid frame.
            try? fm.copyItem(atPath: dbPath + "-wal", toPath: tempDB.path + "-wal")
        } catch let error as NSError {
            try? fm.removeItem(at: tempDir)
            return .failure(Self.isMissingFile(error) ? .unavailable : .accessDenied)
        }
        defer { try? fm.removeItem(at: tempDir) }

        var handle: OpaquePointer?
        // READWRITE (on the private copy) lets SQLite replay the WAL we copied.
        guard sqlite3_open_v2(tempDB.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else {
            if let db = handle { sqlite3_close(db) }
            return .failure(.unavailable)
        }
        defer { sqlite3_close(db) }
        return .success(body(db))
    }

    private enum ReadError: Error { case accessDenied, unavailable }

    /// Distinguish "the database simply isn't there" (notifications off, path
    /// moved) from "the read was blocked" (almost always a missing Full Disk
    /// Access grant). Anything that isn't a clear file-not-found is treated as
    /// blocked, so the FDA prompt fires whenever we genuinely can't read it.
    private static func isMissingFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }

    private func readNewRows(updatingCursor: Bool) -> ReadResult {
        let cursor = lastRowID
        let outcome = withDatabaseCopy { db -> [RawNotification] in
            self.query(db, after: cursor)
        }
        switch outcome {
        case .failure(.accessDenied): return .accessDenied
        case .failure(.unavailable): return .unavailable
        case .success(let rows):
            let notes = rows ?? []
            if updatingCursor, let last = notes.last { lastRowID = max(lastRowID, last.recID) }
            return .ok(notes)
        }
    }

    private func readMaxRowID() -> Int64? {
        let outcome = withDatabaseCopy { db -> Int64 in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MAX(rec_id) FROM record", -1, &stmt, nil) == SQLITE_OK
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
        }
        if case .success(let value) = outcome { return value }
        return nil
    }

    /// Query records newer than `cursor`, joined to their app's bundle id. Falls
    /// back to a record-only query (bundle id pulled from the payload) if the
    /// schema doesn't match the expected `record`/`app` shape.
    private func query(_ db: OpaquePointer, after cursor: Int64) -> [RawNotification] {
        let joined = """
        SELECT r.rec_id, a.identifier, r.data
        FROM record r JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ? ORDER BY r.rec_id ASC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, joined, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            return collect(stmt, after: cursor, hasIdentifierColumn: true)
        }
        sqlite3_finalize(stmt)

        let fallback = "SELECT rec_id, data FROM record WHERE rec_id > ? ORDER BY rec_id ASC"
        var stmt2: OpaquePointer?
        guard sqlite3_prepare_v2(db, fallback, -1, &stmt2, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt2)
            return []
        }
        defer { sqlite3_finalize(stmt2) }
        return collect(stmt2, after: cursor, hasIdentifierColumn: false)
    }

    private func collect(_ stmt: OpaquePointer?, after cursor: Int64, hasIdentifierColumn: Bool) -> [RawNotification] {
        sqlite3_bind_int64(stmt, 1, cursor)
        var results: [RawNotification] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let recID = sqlite3_column_int64(stmt, 0)
            let dataIndex: Int32 = hasIdentifierColumn ? 2 : 1
            var columnBundle = ""
            if hasIdentifierColumn, let cstr = sqlite3_column_text(stmt, 1) {
                columnBundle = String(cString: cstr)
            }
            guard let blob = sqlite3_column_blob(stmt, dataIndex) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, dataIndex))
            guard length > 0 else { continue }
            let data = Data(bytes: blob, count: length)
            guard let parsed = Self.parse(data) else { continue }
            let bundle = columnBundle.isEmpty ? parsed.bundleID : columnBundle
            results.append(RawNotification(
                recID: recID,
                bundleID: bundle,
                title: parsed.title,
                subtitle: parsed.subtitle,
                body: parsed.body))
        }
        return results
    }

    /// Decode one record's `data` BLOB — a binary plist. The user-visible fields
    /// live under a `req` dictionary (`titl`/`subt`/`body`); the sending bundle
    /// id is at the top level under `app`.
    private static func parse(_ data: Data) -> (bundleID: String, title: String, subtitle: String, body: String)? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any] else { return nil }
        let req = (root["req"] as? [String: Any]) ?? root
        let title = (req["titl"] as? String) ?? ""
        let subtitle = (req["subt"] as? String) ?? ""
        let body = (req["body"] as? String) ?? ""
        let bundleID = (root["app"] as? String) ?? (req["app"] as? String) ?? ""
        return (bundleID, title, subtitle, body)
    }
}

/// Watches a filesystem path and calls `onChange` whenever it's written,
/// extended, or replaced — letting the notification provider react to a DB
/// commit the instant it lands instead of waiting for the next poll.
///
/// SQLite's `-wal` sidecar is periodically checkpoint-truncated and recreated,
/// which invalidates our file descriptor; the watcher detects that
/// (delete/rename/revoke) and re-arms itself on the fresh file. All state is
/// touched only on `queue` (a serial queue), so `@unchecked Sendable` is safe.
final class FileWatcher: @unchecked Sendable {
    private let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var rearmWork: DispatchWorkItem?

    init(path: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
    }

    func start() { queue.async { [weak self] in self?.arm() } }

    func stop() {
        queue.async { [weak self] in
            self?.rearmWork?.cancel()
            self?.rearmWork = nil
            self?.source?.cancel()
            self?.source = nil
        }
    }

    private func arm() {
        guard source == nil else { return }
        let fd = open(path, O_EVTONLY)
        // The file may not exist yet (e.g. no `-wal` until the first commit) or
        // be unreadable (Full Disk Access denied) — try again shortly.
        guard fd >= 0 else { scheduleRearm(); return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.onChange()
            // File swapped out from under us — re-open the replacement.
            if !flags.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.source?.cancel()
                self.source = nil
                self.scheduleRearm()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func scheduleRearm() {
        rearmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.arm() }
        rearmWork = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
