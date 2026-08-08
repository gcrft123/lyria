import Foundation

/// Tests for the one-time code-signing migration (`SigningMigrator`).
///
/// This is the one path that installs code while stepping around Sparkle's own
/// code-signature check, so its two gates are exercised against REAL artifacts
/// rather than fixtures: a genuinely EdDSA-signed archive, and genuinely signed
/// app bundles. Artifact-backed cases skip (loudly) when the artifacts aren't
/// present, so a fresh clone still runs the suite green.
@MainActor
func runSigningMigrationTests() {
    testAppcastParsing()
    testAppcastIgnoresDeltas()
    testEdDSAVerification()
    testDeveloperIDRequirement()
    testSwapReplacesBundle()
    testSwapRollsBackOnFailure()
    testShellQuotingSurvivesAwkwardPaths()
}

// MARK: Appcast parsing

private let sampleAppcast = """
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Lyria</title>
    <item>
      <title>0.2.2</title>
      <sparkle:version>8</sparkle:version>
      <sparkle:shortVersionString>0.2.2</sparkle:shortVersionString>
      <enclosure url="https://example.test/Lyria-0.2.2.zip" length="10" type="application/octet-stream" sparkle:edSignature="AAAA"/>
      <sparkle:deltas>
        <enclosure url="https://example.test/Lyria8-7.delta" sparkle:deltaFrom="7" length="5" type="application/octet-stream" sparkle:edSignature="BBBB"/>
      </sparkle:deltas>
    </item>
    <item>
      <title>0.2.1</title>
      <sparkle:version>7</sparkle:version>
      <sparkle:shortVersionString>0.2.1</sparkle:shortVersionString>
      <enclosure url="https://example.test/Lyria-0.2.1.zip" length="9" type="application/octet-stream" sparkle:edSignature="CCCC"/>
    </item>
  </channel>
</rss>
"""

@MainActor
private func testAppcastParsing() {
    let parser = SigningMigrator.AppcastParser()
    expect(parser.parse(Data(sampleAppcast.utf8)), "appcast parses")
    expectEqual(parser.items.count, 2, "full-archive items")
    let newest = parser.items.max { $0.build < $1.build }
    expectEqual(newest?.build, 8, "newest build")
    expectEqual(newest?.shortVersion, "0.2.2", "newest short version")
    expectEqual(newest?.edSignature, "AAAA", "newest signature")
    expectEqual(newest?.url.absoluteString, "https://example.test/Lyria-0.2.2.zip", "newest url")
}

/// A delta enclosure must never be mistaken for the full archive: the migrator
/// installs whole bundles, and a delta would fail verification at best.
@MainActor
private func testAppcastIgnoresDeltas() {
    let parser = SigningMigrator.AppcastParser()
    _ = parser.parse(Data(sampleAppcast.utf8))
    expect(!parser.items.contains { $0.url.absoluteString.hasSuffix(".delta") },
           "deltas are not offered as installable items")
    expect(!parser.items.contains { $0.edSignature == "BBBB" }, "delta signature not picked up")
}

// MARK: EdDSA — the gate that makes the bypass safe

/// Verify against the real signed archive and the real public key, then confirm
/// the check actually FAILS on a tampered byte and on a foreign signature. A
/// gate that only ever returns true would be worse than no gate.
@MainActor
private func testEdDSAVerification() {
    guard let (archive, signature, publicKey) = releaseArtifacts() else {
        skip("EdDSA verification: no signed archive in dist/ (run Scripts/release.sh first)")
        return
    }
    expect(SigningMigrator.verifyEdDSA(fileURL: archive, base64Signature: signature,
                                       publicKeyBase64: publicKey),
           "the real signed archive verifies against SUPublicEDKey")

    // Flip one byte of a copy: the signature must no longer match.
    let tampered = FileManager.default.temporaryDirectory
        .appendingPathComponent("tampered-" + UUID().uuidString + ".zip")
    if var data = try? Data(contentsOf: archive), data.count > 4096 {
        data[4096] = data[4096] &+ 1
        try? data.write(to: tampered)
        expect(!SigningMigrator.verifyEdDSA(fileURL: tampered, base64Signature: signature,
                                            publicKeyBase64: publicKey),
               "a tampered archive is rejected")
        try? FileManager.default.removeItem(at: tampered)
    }

    // A well-formed but wrong signature must be rejected.
    let wrong = Data(repeating: 0, count: 64).base64EncodedString()
    expect(!SigningMigrator.verifyEdDSA(fileURL: archive, base64Signature: wrong,
                                        publicKeyBase64: publicKey),
           "a forged signature is rejected")

    // Garbage inputs must fail closed, not crash.
    expect(!SigningMigrator.verifyEdDSA(fileURL: archive, base64Signature: "not base64!",
                                        publicKeyBase64: publicKey),
           "unparseable signature is rejected")
    expect(!SigningMigrator.verifyEdDSA(fileURL: archive, base64Signature: signature,
                                        publicKeyBase64: "not base64!"),
           "unparseable key is rejected")
}

// MARK: Developer ID pinning

/// The self-signed build must read as transitional and the Developer ID build
/// must not — that boolean is what makes the migrator retire itself.
@MainActor
private func testDeveloperIDRequirement() {
    let root = repoRoot()
    let selfSigned = root.appendingPathComponent(".build/Lyria.app")
    if FileManager.default.fileExists(atPath: selfSigned.path) {
        expect(!SigningMigrator.isDeveloperIDSigned(bundleURL: selfSigned),
               "the local self-signed build is NOT accepted as Developer ID")
    } else {
        skip("Developer ID check: no .build/Lyria.app (run ./build.sh first)")
    }

    // A path that isn't a bundle at all must fail closed.
    expect(!SigningMigrator.isDeveloperIDSigned(
        bundleURL: URL(fileURLWithPath: "/usr/bin/true-does-not-exist")),
           "a missing bundle is not Developer ID signed")
}

// MARK: The bundle swap

/// The happy path: the new bundle replaces the old one and no backup is left
/// behind. Run against throwaway directories, using the SHIPPED script text.
@MainActor
private func testSwapReplacesBundle() {
    guard let bed = makeSwapBed() else { expect(false, "could not stage swap test"); return }
    defer { try? FileManager.default.removeItem(at: bed.root) }

    let ok = runSwapScript(bed, newAppExists: true)
    expect(ok, "swap script succeeds")
    expectEqual(contents(of: bed.destination.appendingPathComponent("marker.txt")), "new",
                "destination now holds the new bundle")
    expect(!FileManager.default.fileExists(atPath: bed.backup.path), "backup cleaned up")
}

/// The path that matters most: if the copy fails after the old bundle has been
/// moved aside, the old bundle must come back rather than the user losing the app.
@MainActor
private func testSwapRollsBackOnFailure() {
    guard let bed = makeSwapBed() else { expect(false, "could not stage swap test"); return }
    defer { try? FileManager.default.removeItem(at: bed.root) }

    // Delete the replacement so ditto cannot succeed.
    try? FileManager.default.removeItem(at: bed.newApp)

    let ok = runSwapScript(bed, newAppExists: false)
    expect(!ok, "swap script reports failure")
    expectEqual(contents(of: bed.destination.appendingPathComponent("marker.txt")), "old",
                "the original bundle is restored after a failed copy")
    expect(!FileManager.default.fileExists(atPath: bed.backup.path), "no stray backup left")
}

/// Paths with spaces and quotes must not break out of the script's quoting.
@MainActor
private func testShellQuotingSurvivesAwkwardPaths() {
    expectEqual(SigningMigrator.shellQuote("/Apps/My App.app"), "'/Apps/My App.app'",
                "spaces are quoted")
    expectEqual(SigningMigrator.shellQuote("/Apps/It's.app"), "'/Apps/It'\\''s.app'",
                "single quotes are escaped")
    // A path crafted to close the quote and append a command must stay inert.
    // Checked by handing it to a real shell: the quoted form has to echo back
    // verbatim, and the smuggled command must not have run.
    let canary = FileManager.default.temporaryDirectory
        .appendingPathComponent("lyria-injection-canary-" + UUID().uuidString)
    let hostile = "/tmp/x'; touch \(canary.path); echo '"
    let quoted = SigningMigrator.shellQuote(hostile)

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "printf '%s' \(quoted)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try? task.run()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    task.waitUntilExit()

    expectEqual(out, hostile, "the shell reads the quoted path back verbatim")
    expect(!FileManager.default.fileExists(atPath: canary.path),
           "the smuggled command did not execute")
    try? FileManager.default.removeItem(at: canary)
}

private struct SwapBed {
    let root: URL, destination: URL, newApp: URL, backup: URL, script: URL
}

/// A throwaway "installed app", "new app", and script path under a temp root.
@MainActor
private func makeSwapBed() -> SwapBed? {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("lyria-swaptest-" + UUID().uuidString)
    let destination = root.appendingPathComponent("Lyria.app")
    let newApp = root.appendingPathComponent("new/Lyria.app")
    do {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.createDirectory(at: newApp, withIntermediateDirectories: true)
        try "old".write(to: destination.appendingPathComponent("marker.txt"),
                        atomically: true, encoding: .utf8)
        try "new".write(to: newApp.appendingPathComponent("marker.txt"),
                        atomically: true, encoding: .utf8)
    } catch { return nil }
    return SwapBed(root: root, destination: destination, newApp: newApp,
                   backup: root.appendingPathComponent(".backup.app"),
                   script: root.appendingPathComponent("swap.sh"))
}

/// Generate the real script and run it. `pid` is our own, already-running process
/// only in the sense that the wait loop needs a pid that is NOT alive — we pass a
/// reaped one so the script proceeds immediately instead of waiting 20 seconds.
@MainActor
private func runSwapScript(_ bed: SwapBed, newAppExists: Bool) -> Bool {
    let deadPID: Int32 = 999_999   // never a live pid; kill -0 fails immediately
    let body = SigningMigrator.swapScript(pid: deadPID, destination: bed.destination,
                                          newApp: bed.newApp, backup: bed.backup,
                                          scriptPath: bed.script, relaunch: false)
    guard (try? body.write(to: bed.script, atomically: true, encoding: .utf8)) != nil else { return false }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = [bed.script.path]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return false }
    task.waitUntilExit()
    return task.terminationStatus == 0
}

private func contents(of url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>"
}

// MARK: Helpers

/// The newest full archive in `dist/` plus its signature from `docs/appcast.xml`
/// and the app's public key from `Resources/Info.plist`.
@MainActor
private func releaseArtifacts() -> (archive: URL, signature: String, publicKey: String)? {
    let root = repoRoot()
    let appcastURL = root.appendingPathComponent("docs/appcast.xml")
    let infoURL = root.appendingPathComponent("Resources/Info.plist")
    guard let appcast = try? Data(contentsOf: appcastURL),
          let info = NSDictionary(contentsOf: infoURL),
          let publicKey = info["SUPublicEDKey"] as? String else { return nil }

    let parser = SigningMigrator.AppcastParser()
    guard parser.parse(appcast),
          let newest = parser.items.max(by: { $0.build < $1.build }) else { return nil }
    let archive = root.appendingPathComponent("dist/" + newest.url.lastPathComponent)
    guard FileManager.default.fileExists(atPath: archive.path) else { return nil }
    return (archive, newest.edSignature, publicKey)
}

/// Tests run from the repo root (Scripts/test.sh), but fall back to walking up
/// from this file so a different working directory still resolves.
private func repoRoot() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Resources/Info.plist").path) {
        return cwd
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root
}
