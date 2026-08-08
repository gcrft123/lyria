import Foundation

// A deliberately tiny test harness. SwiftPM/XCTest don't work with this repo's
// direct-swiftc build (see build.sh), so tests are compiled into a small
// executable alongside the app sources (minus the app's @main) and run by
// Scripts/test.sh. Same module → `internal` symbols are reachable (not `private`).

enum TestState {
    static var passed = 0
    static var failed = 0
    static var failures: [String] = []
    static var skipped: [String] = []
}

/// Assert a condition; records pass/fail with a source location on failure.
func expect(_ condition: Bool, _ message: @autoclosure () -> String,
            file: StaticString = #file, line: UInt = #line) {
    if condition {
        TestState.passed += 1
    } else {
        TestState.failed += 1
        TestState.failures.append("\(file):\(line): \(message())")
    }
}

/// Assert two `Equatable` values are equal, reporting both sides on failure.
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "",
                               file: StaticString = #file, line: UInt = #line) {
    expect(actual == expected,
           "\(label.isEmpty ? "" : label + ": ")expected \(expected), got \(actual)",
           file: file, line: line)
}

/// Record a case that couldn't run for want of a build artifact. Reported at the
/// end so a skipped check is never mistaken for a passing one.
func skip(_ reason: String) {
    TestState.skipped.append(reason)
}

@main
struct DynamicIslandTests {
    @MainActor
    static func main() {
        runCoreLogicTests()
        runCalculatorEngineTests()
        runMusicLibraryTests()
        runNotchTests()
        runSigningMigrationTests()

        var line = "Tests: \(TestState.passed) passed, \(TestState.failed) failed"
        if !TestState.skipped.isEmpty { line += ", \(TestState.skipped.count) skipped" }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        for reason in TestState.skipped {
            FileHandle.standardError.write(Data("  ⊘ skipped: \(reason)\n".utf8))
        }
        for failure in TestState.failures {
            FileHandle.standardError.write(Data("  ✗ \(failure)\n".utf8))
        }
        exit(TestState.failed == 0 ? 0 : 1)
    }
}
