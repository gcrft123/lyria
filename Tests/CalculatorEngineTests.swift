import Foundation

/// Pure-logic tests for the Calculator engine: arithmetic, immediate-execution
/// chaining, clear/error handling, formatting, and history + recall.
@MainActor
func runCalculatorEngineTests() {
    testCalcBasicArithmetic()
    testCalcChainingAndRepeat()
    testCalcClearAndBackspace()
    testCalcDivideByZero()
    testCalcPercentAndNegate()
    testCalcFormatting()
    testCalcHistoryAndRecall()
}

/// Type a run of digits / a decimal point into the engine.
@MainActor
private func enter(_ e: CalculatorEngine, _ s: String) {
    for ch in s {
        if ch == "." { e.inputDecimal() }
        else if let d = ch.wholeNumberValue { e.inputDigit(d) }
    }
}

@MainActor
private func testCalcBasicArithmetic() {
    let e = CalculatorEngine()
    enter(e, "2"); e.setOp(.add); enter(e, "3"); e.equals()
    expectEqual(e.display, "5", "2 + 3")

    e.clear()
    enter(e, "6"); e.setOp(.multiply); enter(e, "7"); e.equals()
    expectEqual(e.display, "42", "6 × 7")

    e.clear()
    enter(e, "8"); e.setOp(.subtract); enter(e, "20"); e.equals()
    expectEqual(e.display, "-12", "8 − 20")

    e.clear()
    enter(e, "9"); e.setOp(.divide); enter(e, "2"); e.equals()
    expectEqual(e.display, "4.5", "9 ÷ 2")
}

@MainActor
private func testCalcChainingAndRepeat() {
    // Immediate execution (no precedence): 2 + 3 × 4 → (2+3)=5, then ×4 = 20.
    let e = CalculatorEngine()
    enter(e, "2"); e.setOp(.add); enter(e, "3"); e.setOp(.multiply)
    expectEqual(e.display, "5", "chain shows running total after second op")
    enter(e, "4"); e.equals()
    expectEqual(e.display, "20", "2 + 3 × 4 = 20 (immediate execution)")

    // Pressing = again repeats the last op (+? no — last was ×4) → 20 × 4 = 80.
    e.equals()
    expectEqual(e.display, "80", "repeated = re-applies × 4")

    // Changing the operator before typing replaces it (no compute): 5 + × 2 = 10.
    let e2 = CalculatorEngine()
    enter(e2, "5"); e2.setOp(.add); e2.setOp(.multiply); enter(e2, "2"); e2.equals()
    expectEqual(e2.display, "10", "operator swap before operand")
}

@MainActor
private func testCalcClearAndBackspace() {
    let e = CalculatorEngine()
    expectEqual(e.clearLabel, "AC", "rest label is AC")
    enter(e, "12")
    expectEqual(e.clearLabel, "C", "label is C while typing")
    e.clear()                       // C — clears the entry only
    expectEqual(e.display, "0", "C clears entry")

    enter(e, "5"); e.setOp(.add); enter(e, "9")
    e.clear()                       // C — keep the pending +
    enter(e, "1"); e.equals()
    expectEqual(e.display, "6", "C kept the pending op: 5 + 1")

    enter(e, "0")                   // start fresh
    e.clear()                       // AC now
    enter(e, "789"); e.backspace()
    expectEqual(e.display, "78", "backspace drops last digit")
    e.backspace(); e.backspace()
    expectEqual(e.display, "0", "backspace past the start resets to 0")
}

@MainActor
private func testCalcDivideByZero() {
    let e = CalculatorEngine()
    enter(e, "5"); e.setOp(.divide); enter(e, "0"); e.equals()
    expectEqual(e.display, "Error", "÷ 0 is an error")
    // Input recovers from the error state.
    enter(e, "7")
    expectEqual(e.display, "7", "typing recovers from Error")
}

@MainActor
private func testCalcPercentAndNegate() {
    let e = CalculatorEngine()
    enter(e, "50"); e.percent()
    expectEqual(e.display, "0.5", "50 % → 0.5")

    e.clear()
    enter(e, "5"); e.negate()
    expectEqual(e.display, "-5", "negate")
    e.negate()
    expectEqual(e.display, "5", "negate twice")
}

@MainActor
private func testCalcFormatting() {
    let e = CalculatorEngine()
    expectEqual(e.format(5), "5", "whole number has no .0")
    expectEqual(e.format(4.5), "4.5", "decimal kept")
    expectEqual(e.format(-0), "0", "minus-zero collapses to 0")

    // Float noise is trimmed: 0.1 + 0.2 reads as 0.3, not 0.30000000004.
    enter(e, "0"); e.inputDecimal(); enter(e, "1")
    e.setOp(.add)
    enter(e, "0"); e.inputDecimal(); enter(e, "2")
    e.equals()
    expectEqual(e.display, "0.3", "0.1 + 0.2 trims float noise")
}

@MainActor
private func testCalcHistoryAndRecall() {
    let e = CalculatorEngine()
    expect(e.history.isEmpty, "history starts empty")

    enter(e, "2"); e.setOp(.add); enter(e, "3"); e.equals()
    expectEqual(e.history.count, 1, "one entry after =")
    expectEqual(e.history.first?.expression, "2 + 3", "expression recorded")
    expectEqual(e.history.first?.result, "5", "result recorded")

    enter(e, "10"); e.setOp(.multiply); enter(e, "4"); e.equals()
    expectEqual(e.history.count, 2, "newest entry prepended")
    expectEqual(e.history.first?.result, "40", "newest is first")

    // Recall an old result, then keep calculating from it.
    if let entry = e.history.last { e.recall(entry) }
    expectEqual(e.display, "5", "recall loads the result")
    e.setOp(.add); enter(e, "1"); e.equals()
    expectEqual(e.display, "6", "calculation continues from recalled value")

    e.clearHistory()
    expect(e.history.isEmpty, "clearHistory empties it")
}
