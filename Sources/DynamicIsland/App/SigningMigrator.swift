import AppKit
import CryptoKit
import Foundation

/// A one-time bridge across the code-signing identity change.
///
/// Every release up to and including 0.2.1 was signed with a local self-signed
/// certificate ("DynamicIsland Local", no Team ID). From the next release the app
/// is signed with the project's Developer ID. Sparkle refuses an update whose code
/// signature doesn't match the installed app's — "Code signature of new version
/// doesn't match the old version" — and that check runs inside the OLD app. So the
/// crossing has to be handled here, in the last self-signed build, or every
/// existing user is stranded on a manual download.
///
/// This installs that ONE update itself. It is deliberately narrow, and all four
/// gates must hold or it does nothing and leaves the update to Sparkle:
///
///   1. The running app is NOT Developer ID signed. Once migrated this is false
///      forever, so the path retires itself.
///   2. The appcast's newest item has a higher build than the running app.
///   3. The downloaded archive carries a valid EdDSA signature for the app's own
///      `SUPublicEDKey` — the same key, over the same bytes, that Sparkle would
///      check. A tampered appcast or a MITM'd download cannot clear this without
///      the private key, which is the whole security of the bypass.
///   4. The unpacked bundle is Developer ID signed by the pinned Team ID, carries
///      our bundle identifier, and its build really is higher.
///
/// Only then is the bundle swapped, by a detached script that waits for us to
/// quit, keeps a backup, and rolls back if the copy fails.
@MainActor
final class SigningMigrator {

    /// The Developer ID team the migrated build must be signed by. Pinned so this
    /// path can only ever install *our* signed app, never an arbitrary bundle.
    private static let expectedTeamID = "2R2HK79MH6"

    /// Whether this build predates the identity change and therefore owns the
    /// update path. False for any Developer ID build, which retires the migrator.
    static var isTransitionalBuild: Bool {
        !isDeveloperIDSigned(bundleURL: Bundle.main.bundleURL)
    }

    private var running = false
    private weak var controller: DynamicIslandController?

    init(controller: DynamicIslandController?) {
        self.controller = controller
    }

    // MARK: Entry point

    /// Look for the migration update and install it. Safe to call repeatedly; does
    /// nothing on a Developer ID build, and nothing if already in flight.
    /// Returns true if it took ownership of an update (so Sparkle should stay out).
    @discardableResult
    func migrateIfNeeded() async -> Bool {
        guard Self.isTransitionalBuild, !running else { return false }
        running = true
        defer { running = false }

        do {
            guard let item = try await newestAppcastItem(),
                  item.build > Self.currentBuild else { return false }
            let archive = try await download(item)
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            guard verifyEdDSA(fileURL: archive, base64Signature: item.edSignature) else {
                log("archive failed EdDSA verification — leaving the update to Sparkle")
                return false
            }
            let unpacked = try unpack(archive)
            guard let newApp = try appBundle(in: unpacked) else {
                log("no app bundle in the archive"); return false
            }
            guard try validate(newApp, expectedBuild: item.build) else { return false }
            guard destinationIsWritable() else {
                notify(title: "Update needs a manual install",
                       message: "Lyria can't write to \(Bundle.main.bundleURL.deletingLastPathComponent().path)")
                return false
            }
            log("installing \(item.shortVersion) (build \(item.build)) outside Sparkle")
            try swapAndRelaunch(with: newApp)
            return true
        } catch {
            log("migration did not complete: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Appcast

    struct Item {
        let build: Int
        let shortVersion: String
        let url: URL
        let edSignature: String
    }

    private func newestAppcastItem() async throws -> Item? {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feed) else { return nil }
        let (data, response) = try await URLSession.shared.data(from: feedURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let parser = AppcastParser()
        guard parser.parse(data) else { return nil }
        // The enclosure must be https: the EdDSA check is the real gate, but there
        // is no reason to ever fetch this over a plaintext connection.
        return parser.items
            .filter { $0.url.scheme == "https" }
            .max { $0.build < $1.build }
    }

    /// Minimal appcast reader: every item's build, version, enclosure URL and
    /// signature. Sparkle owns the real feed semantics — this only needs enough to
    /// find the one update it may install, and everything it returns is verified
    /// downstream anyway.
    final class AppcastParser: NSObject, XMLParserDelegate {
        private(set) var items: [Item] = []
        private var build: Int?
        private var shortVersion = ""
        private var text = ""

        func parse(_ data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            return parser.parse()
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            text = ""
            switch element {
            case "item":
                build = nil; shortVersion = ""
            case "enclosure":
                guard let urlString = attrs["url"], let url = URL(string: urlString),
                      let signature = attrs["sparkle:edSignature"] else { return }
                // Deltas also appear as <enclosure>; they carry sparkle:deltaFrom
                // and are useless here (we install the full archive).
                guard attrs["sparkle:deltaFrom"] == nil else { return }
                let itemBuild = build ?? Int(attrs["sparkle:version"] ?? "") ?? 0
                guard itemBuild > 0 else { return }
                items.append(Item(build: itemBuild, shortVersion: shortVersion,
                                  url: url, edSignature: signature))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "sparkle:version": build = Int(value)
            case "sparkle:shortVersionString": shortVersion = value
            default: break
            }
        }
    }

    // MARK: Download + verification

    private func download(_ item: Item) async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: item.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("download returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyria-migrate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(item.url.lastPathComponent)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func verifyEdDSA(fileURL: URL, base64Signature: String) -> Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else { return false }
        return Self.verifyEdDSA(fileURL: fileURL, base64Signature: base64Signature,
                                publicKeyBase64: key)
    }

    /// The archive's Ed25519 signature over its own bytes, against the app's
    /// `SUPublicEDKey`. This is the gate that makes bypassing Sparkle safe: it is
    /// the identical check Sparkle performs, with the identical key, so only the
    /// holder of the private key can get code past it.
    nonisolated static func verifyEdDSA(fileURL: URL, base64Signature: String,
                                        publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let signature = Data(base64Encoded: base64Signature),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }

    private func unpack(_ archive: URL) throws -> URL {
        let dir = archive.deletingLastPathComponent().appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", archive.path, dir.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw Failure("ditto failed (\(task.terminationStatus))") }
        return dir
    }

    private func appBundle(in directory: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "app" }
    }

    /// The unpacked bundle must be ours, newer, and Developer ID signed by the
    /// pinned team. Belt and braces on top of the EdDSA check: even a correctly
    /// signed archive is refused if it isn't the migrated app we expect.
    private func validate(_ app: URL, expectedBuild: Int) throws -> Bool {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == Bundle.main.bundleIdentifier,
              let buildString = info["CFBundleVersion"] as? String, let build = Int(buildString),
              build > Self.currentBuild, build == expectedBuild
        else { log("unpacked bundle is not the expected newer build"); return false }

        guard Self.isDeveloperIDSigned(bundleURL: app) else {
            // A self-signed successor needs no bypass — Sparkle can install it.
            log("unpacked bundle is not Developer ID signed by \(Self.expectedTeamID)")
            return false
        }
        return true
    }

    /// Whether `bundleURL` is validly signed by our pinned Developer ID team,
    /// anchored to Apple's root.
    nonisolated static func isDeveloperIDSigned(bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: Install

    private func destinationIsWritable() -> Bool {
        FileManager.default.isWritableFile(atPath:
            Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    /// Hand the swap to a detached script: a bundle can't replace itself while it
    /// is running. The script waits for our pid to go away, moves the old bundle
    /// aside as a backup, copies the new one into place, rolls back if that fails,
    /// and relaunches.
    private func swapAndRelaunch(with newApp: URL) throws {
        let destination = Bundle.main.bundleURL
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".lyria-backup-" + UUID().uuidString + ".app")
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyria-swap-" + UUID().uuidString + ".sh")

        let body = Self.swapScript(pid: ProcessInfo.processInfo.processIdentifier,
                                   destination: destination, newApp: newApp,
                                   backup: backup, scriptPath: script, relaunch: true)
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [script.path]
        try task.run()

        notify(title: "Updating Lyria", message: "Restarting to finish the update")
        // Give the popup a beat to draw, then step aside for the script.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// The swap script, as text, so the real thing can be exercised in tests
    /// against throwaway directories — this is the one step that deletes an app
    /// bundle, and its rollback has to be known-good rather than assumed.
    ///
    /// The old bundle is moved aside (not deleted) before the new one is copied
    /// in, so a failed copy can put it straight back. Nothing is removed until
    /// the replacement is known to have landed.
    nonisolated static func swapScript(pid: Int32, destination: URL, newApp: URL,
                                       backup: URL, scriptPath: URL, relaunch: Bool) -> String {
        """
        #!/bin/sh
        PID=\(pid)
        DEST=\(shellQuote(destination.path))
        NEW=\(shellQuote(newApp.path))
        BACKUP=\(shellQuote(backup.path))
        # Wait (bounded, ~20s) for the old app to exit before touching its bundle.
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
        /bin/rm -rf "$BACKUP"
        /bin/mv "$DEST" "$BACKUP" || exit 1
        if /usr/bin/ditto "$NEW" "$DEST"; then
            /bin/rm -rf "$BACKUP"
        else
            /bin/rm -rf "$DEST"
            /bin/mv "$BACKUP" "$DEST"
            exit 1
        fi
        \(relaunch ? "/usr/bin/open \"$DEST\"" : "")
        /bin/rm -f \(shellQuote(scriptPath.path))
        """
    }

    nonisolated static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Plumbing

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    private func notify(title: String, message: String) {
        controller?.presentPopup(IslandPopup(
            id: "signing-migration",
            title: title,
            message: message,
            icon: .symbol("arrow.down.circle"),
            accent: .indigo,
            autoDismissAfter: 6))
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("Lyria: update migration — \(message)\n".utf8))
    }
}
