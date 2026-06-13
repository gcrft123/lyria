import AppKit
import Foundation
import SwiftUI

/// Surfaces AirDrop send / receive activity on the island.
///
/// macOS exposes no public API for live AirDrop progress, so this is a
/// BEST-EFFORT monitor: it tails the unified log for `sharingd` (the daemon that
/// runs AirDrop) and maps transfer-lifecycle messages to island popups —
/// "Receiving via AirDrop…" / "Sending via AirDrop…" on start, and a completion
/// banner on finish. Because the log wording (and how much is redacted as
/// `<private>`) shifts between macOS releases, the matching is deliberately
/// liberal and easy to tune; if a transfer isn't caught, the only cost is a
/// missed banner. Reading the log needs no special permission for the user's own
/// session.
@MainActor
final class AirDropProvider: IslandContentProvider {
    let id = "com.dynamicisland.airdrop"

    private weak var controller: DynamicIslandController?

    private var logTask: Process?
    /// True between a recognised start and its finish, so we present one start
    /// and one completion per transfer instead of a banner per log line.
    private var inTransfer = false
    private var transferDirection: Direction = .receiving
    private var transferStartedAt: Date = .distantPast
    /// Stale-guard: if a finish line never arrives, forget the transfer so the
    /// next start isn't swallowed.
    private let transferTimeout: TimeInterval = 120

    private let accent = Palette.blue
    private let bannerDuration: TimeInterval = 4.0

    private let mockMode = ProcessInfo.processInfo.environment["DI_MOCK_AIRDROP"] == "1"

    enum Direction { case sending, receiving }

    func didRegister(with controller: DynamicIslandController) {
        self.controller = controller
    }

    func startObserving() {
        if mockMode { runMockSequence(); return }
        startLogStream()
    }

    func stopObserving() {
        logTask?.terminate()
        logTask = nil
    }

    // MARK: Log streaming

    private func startLogStream() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = [
            "stream",
            "--style", "ndjson",
            "--level", "info",
            "--predicate", #"process == "sharingd""#
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        // The readability handler runs off-main and is invoked serially, so the
        // line buffer lives in a reference holder (captured by reference, not as
        // a mutable capture) and we parse there, then hop to main to drive the UI.
        let lineBuffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for lineData in lineBuffer.append(chunk) {
                guard let event = Self.parse(lineData) else { continue }
                DispatchQueue.main.async { [weak self] in
                    self?.handle(event)
                }
            }
        }

        do {
            try task.run()
            logTask = task
        } catch {
            FileHandle.standardError.write(Data(
                "DynamicIsland: AirDrop monitor couldn't start `log stream` (\(error.localizedDescription)).\n".utf8))
        }
    }

    /// Parse one ndjson log line into an AirDrop lifecycle event, or nil if the
    /// line isn't a transfer signal we care about.
    nonisolated private static func parse(_ line: Data) -> Event? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let message = (object["eventMessage"] as? String)?.lowercased(),
            message.contains("airdrop") || message.contains("transfer") || message.contains("askto")
        else { return nil }

        let direction: Direction =
            (message.contains("incoming") || message.contains("receiv")) ? .receiving :
            (message.contains("outgoing") || message.contains("send") || message.contains("sent")) ? .sending :
            .receiving

        let isFinish = message.contains("complet") || message.contains("finish")
            || message.contains("saved") || message.contains("success") || message.contains("done")
        let isStart = message.contains("start") || message.contains("begin")
            || message.contains("asking") || message.contains("request")
            || message.contains("incoming") || message.contains("negotiat")

        if isFinish { return Event(kind: .finish, direction: direction) }
        if isStart { return Event(kind: .start, direction: direction) }
        return nil
    }

    private func handle(_ event: Event) {
        // Expire a stuck transfer so a new one can start.
        if inTransfer, Date().timeIntervalSince(transferStartedAt) > transferTimeout {
            inTransfer = false
        }

        switch event.kind {
        case .start:
            guard !inTransfer else { return }
            inTransfer = true
            transferDirection = event.direction
            transferStartedAt = Date()
            presentStart(event.direction)
        case .finish:
            guard inTransfer else { return }
            inTransfer = false
            presentFinish(transferDirection)
        }
    }

    // MARK: Presentation

    private func presentStart(_ direction: Direction) {
        let receiving = direction == .receiving
        controller?.presentPopup(IslandPopup(
            id: "airdrop.active",
            title: "AirDrop",
            message: receiving ? "Receiving…" : "Sending…",
            icon: .symbol(receiving ? "square.and.arrow.down" : "square.and.arrow.up"),
            accent: accent,
            autoDismissAfter: nil)) // stays until the finish banner replaces it
    }

    private func presentFinish(_ direction: Direction) {
        let receiving = direction == .receiving
        controller?.presentPopup(IslandPopup(
            id: "airdrop.done",
            title: "AirDrop",
            message: receiving ? "Saved to Downloads" : "Sent",
            icon: .symbol(receiving ? "square.and.arrow.down" : "checkmark.circle.fill"),
            accent: accent,
            autoDismissAfter: bannerDuration))
    }

    // MARK: Debug

    private func runMockSequence() {
        presentStart(.receiving)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.presentFinish(.receiving)
        }
    }

    struct Event {
        enum Kind { case start, finish }
        let kind: Kind
        let direction: Direction
    }
}

/// Accumulates raw pipe chunks and yields complete newline-delimited lines.
///
/// The `log stream` ndjson output arrives in arbitrary-sized chunks that don't
/// align to line boundaries, so we buffer partial data and split on `\n`. This
/// is a reference type (rather than a captured `var`) so the off-main
/// readability handler can mutate it without tripping Swift's concurrent-capture
/// checks; it's only ever touched from that one serial handler.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let newline: UInt8 = 0x0A

    /// Append a chunk and return any complete lines it completed, leaving the
    /// trailing partial line buffered for next time.
    func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let idx = data.firstIndex(of: newline) {
            let line = data.subdata(in: data.startIndex..<idx)
            if !line.isEmpty { lines.append(line) }
            data.removeSubrange(data.startIndex...idx)
        }
        return lines
    }
}
