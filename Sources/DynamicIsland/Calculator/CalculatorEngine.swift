import Foundation

/// The brain behind the Calculator app: an immediate-execution (no operator
/// precedence, like the macOS/iOS calculator) four-function engine plus a running
/// history of completed calculations.
///
/// Pure logic — no SwiftUI — so it's fully unit-testable (see CalculatorEngineTests).
/// The view binds to the three `@Published` outputs (`display`, `expression`,
/// `history`); everything else is internal state mutated by the input methods.
@MainActor
final class CalculatorEngine: ObservableObject {

    /// One completed calculation, newest kept first in `history`.
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        /// The full sum, e.g. "12 × 3".
        let expression: String
        /// The formatted result, e.g. "36".
        let result: String
    }

    /// The big value on screen (a raw, still-being-typed string while entering).
    @Published private(set) var display: String = "0"
    /// The faint line above the display showing the sum in progress ("12 ×").
    @Published private(set) var expression: String = ""
    /// Completed calculations, newest first. Tapping one recalls its result.
    @Published private(set) var history: [Entry] = []

    /// The four operations. `rawValue` doubles as the display symbol.
    enum Op: String, Equatable {
        case add = "+", subtract = "−", multiply = "×", divide = "÷"
        func apply(_ a: Double, _ b: Double) -> Double {
            switch self {
            case .add:      return a + b
            case .subtract: return a - b
            case .multiply: return a * b
            case .divide:   return b == 0 ? .nan : a / b
            }
        }
    }

    // MARK: Internal state

    private var accumulator: Double?    // the left operand, carried across ops
    private var pending: Op?            // the operator awaiting its right operand
    private var typingNumber = false    // is `display` a number mid-entry?
    private var hasError = false        // showing "Error" until the next clear/input
    // Repeated "=": pressing = again re-applies the last op with the last operand.
    private var repeatOp: Op?
    private var repeatOperand: Double?

    /// The operator currently armed (awaiting its right operand) — drives the
    /// highlighted operator key in the keypad.
    var pendingOp: Op? { pending }

    /// "C" clears just the number being typed; "AC" (the resting label) clears all.
    var clearLabel: String { typingNumber ? "C" : "AC" }

    private static let errorText = "Error"
    private let maxDigits = 12

    // MARK: Input

    func inputDigit(_ d: Int) {
        guard (0...9).contains(d) else { return }
        if hasError { reset() }
        if typingNumber {
            if display == "0" { display = "\(d)" }
            else if digitCount(display) < maxDigits { display += "\(d)" }
        } else {
            // Starting a fresh number with no pending op means a brand-new sum, so
            // drop the previous result sitting in the accumulator.
            if pending == nil { accumulator = nil; expression = "" }
            display = "\(d)"
            typingNumber = true
        }
        clearRepeat()
    }

    func inputDecimal() {
        if hasError { reset() }
        if !typingNumber {
            if pending == nil { accumulator = nil; expression = "" }
            display = "0."
            typingNumber = true
        } else if !display.contains(".") {
            display += "."
        }
        clearRepeat()
    }

    func setOp(_ op: Op) {
        if hasError { return }
        let current = currentValue
        if pending != nil, typingNumber {
            // Chain: fold the just-typed operand into the accumulator and show it.
            commitPending(with: current)
            if hasError { return }
        } else if accumulator == nil {
            accumulator = current
        }
        // (pending set but not typing → just swap the operator, no compute.)
        pending = op
        typingNumber = false
        expression = "\(format(accumulator ?? current)) \(op.rawValue)"
        clearRepeat()
    }

    func equals() {
        if hasError { return }
        if let op = pending, let acc = accumulator {
            let operand = currentValue
            finish(acc: acc, op: op, operand: operand)
            repeatOp = op
            repeatOperand = operand
        } else if let op = repeatOp, let operand = repeatOperand {
            // Pressing = again repeats the last operation on the current result.
            finish(acc: currentValue, op: op, operand: operand)
        }
    }

    func clear() {
        if typingNumber {
            // "C": clear just the current entry, keep any pending operation.
            display = "0"
            typingNumber = false
        } else {
            reset()
        }
    }

    func negate() {
        if hasError { return }
        guard currentValue != 0 else { return }
        if display.hasPrefix("-") { display.removeFirst() } else { display = "-" + display }
        typingNumber = true
    }

    func percent() {
        if hasError { return }
        display = format(currentValue / 100)
        typingNumber = true
        clearRepeat()
    }

    func backspace() {
        if hasError { reset(); return }
        guard typingNumber else { return }
        display.removeLast()
        if display.isEmpty || display == "-" {
            display = "0"
            typingNumber = false
        }
    }

    /// Recall a past result back into the display as a fresh operand.
    func recall(_ entry: Entry) {
        reset()
        display = entry.result
        hasError = (entry.result == Self.errorText)
    }

    func clearHistory() { history.removeAll() }

    // MARK: Compute helpers

    private var currentValue: Double { Double(display) ?? 0 }

    private func commitPending(with operand: Double) {
        guard let op = pending, let acc = accumulator else { accumulator = operand; return }
        let r = op.apply(acc, operand)
        if r.isNaN || r.isInfinite { enterError(); return }
        accumulator = r
        display = format(r)
    }

    private func finish(acc: Double, op: Op, operand: Double) {
        let r = op.apply(acc, operand)
        if r.isNaN || r.isInfinite { enterError(); return }
        display = format(r)
        accumulator = r
        pending = nil
        typingNumber = false
        expression = ""
        history.insert(Entry(expression: "\(format(acc)) \(op.rawValue) \(format(operand))",
                             result: display), at: 0)
        if history.count > 50 { history.removeLast() }
    }

    private func reset() {
        display = "0"; expression = ""
        accumulator = nil; pending = nil
        typingNumber = false; hasError = false
        clearRepeat()
    }

    private func enterError() {
        display = Self.errorText; expression = ""
        accumulator = nil; pending = nil
        typingNumber = false; hasError = true
        clearRepeat()
    }

    private func clearRepeat() { repeatOp = nil; repeatOperand = nil }

    private func digitCount(_ s: String) -> Int { s.filter(\.isNumber).count }

    /// Format a value for display: a plain integer when whole, otherwise up to 8
    /// decimals with trailing zeros trimmed. No grouping separators, so the string
    /// always round-trips back through `Double(_:)` (recall + chaining rely on this).
    func format(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return Self.errorText }
        if value == 0 { return "0" }   // also collapses -0 → 0
        if value.rounded() == value, abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        var s = String(format: "%.8f", value)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
