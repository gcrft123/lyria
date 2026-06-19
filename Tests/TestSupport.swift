import Foundation

// A deliberately tiny test harness. SwiftPM/XCTest don't work with this repo's
// direct-swiftc build (see build.sh), so tests are compiled into a small
// executable alongside the app sources (minus the app's @main) and run by
// Scripts/test.sh. Same module → `internal` symbols are reachable (not `private`).

enum TestState {
    static var passed = 0
    static var failed = 0
    static var failures: [String] = []
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

@main
struct DynamicIslandTests {
    @MainActor
    static func main() {
        runCoreLogicTests()
        runCalculatorEngineTests()
        runMusicLibraryTests()

        let line = "Tests: \(TestState.passed) passed, \(TestState.failed) failed\n"
        FileHandle.standardError.write(Data(line.utf8))
        for failure in TestState.failures {
            FileHandle.standardError.write(Data("  ✗ \(failure)\n".utf8))
        }
        exit(TestState.failed == 0 ? 0 : 1)
    }
}
