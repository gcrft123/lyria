import AppKit

/// Best-effort local crash breadcrumbs for the field, with no third-party SDK,
/// account, or network.
///
/// Scope is deliberately narrow and *correct*: it installs an uncaught
/// `NSException` handler (the failure mode that often DOESN'T leave a useful
/// system report) and writes a readable record to
/// `~/Library/Logs/Lyria/`. Signal-style crashes (Swift `fatalError`,
/// `precondition`, bad access) are already captured by macOS itself in
/// `~/Library/Logs/DiagnosticReports/Lyria-*.ips` — we deliberately don't
/// install signal handlers here, because doing that safely (async-signal-safe
/// only) is fragile and would duplicate what the OS already does well.
enum CrashReporter {

    private static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Lyria", isDirectory: true)
    }

    /// Install the handler. Call once, early in launch.
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.record(exception)
        }
    }

    private static func record(_ exception: NSException) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        var text = "Lyria uncaught exception — \(timestamp)\n"
        text += "Version \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        text += "\(exception.name.rawValue): \(exception.reason ?? "(no reason)")\n\n"
        text += exception.callStackSymbols.joined(separator: "\n")
        text += "\n"

        try? FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true)
        let safeStamp = timestamp.replacingOccurrences(of: ":", with: "-")
        let file = logDirectory.appendingPathComponent("crash-\(safeStamp).log")
        try? text.data(using: .utf8)?.write(to: file)
    }
}
