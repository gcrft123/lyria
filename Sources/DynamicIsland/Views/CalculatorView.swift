import AppKit
import SwiftUI

/// The Calculator app: a four-function keypad on the left, a running history of
/// completed calculations down a sidebar on the right. Tapping a history entry
/// recalls its result into the display. Hardware keyboard input works too, once
/// the calculator is clicked (see `CalculatorKeyboard`).
struct CalculatorView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var calculator: CalculatorEngine
    /// Routes physical key presses to the engine while this view is on screen.
    @StateObject private var keyboard = CalculatorKeyboard()

    private var accent: Color { IslandApp.calculator.tint }
    private var config: IslandConfiguration { controller.configuration }

    /// The keypad layout — a uniform 4×5 grid (no spanning, so it stays tidy in the
    /// narrow card). Top row is the function keys, bottom-left is backspace.
    private var rows: [[CalcKey]] {
        [[.clear, .negate, .percent, .op(.divide)],
         [.digit(7), .digit(8), .digit(9), .op(.multiply)],
         [.digit(4), .digit(5), .digit(6), .op(.subtract)],
         [.digit(1), .digit(2), .digit(3), .op(.add)],
         [.backspace, .digit(0), .decimal, .equals]]
    }

    var body: some View {
        HStack(spacing: 0) {
            keypadColumn
            Rectangle().fill(Palette.hairlineStroke).frame(width: 1)
            historySidebar
                .frame(width: config.calculatorHistoryWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { keyboard.start(calculator) }
        .onDisappear { keyboard.stop() }
    }

    // MARK: Keypad column (display + grid)

    private var keypadColumn: some View {
        VStack(spacing: Spacing.lg) {
            displayPanel
            keypad
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayPanel: some View {
        VStack(alignment: .trailing, spacing: Spacing.xxs) {
            // A leading space keeps the row's height stable when there's no sum yet.
            Text(calculator.expression.isEmpty ? " " : calculator.expression)
                .font(Typography.callout)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            Text(calculator.display)
                .font(Typography.displayMono)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var keypad: some View {
        VStack(spacing: Spacing.md) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: Spacing.md) {
                    ForEach(rows[r]) { key in
                        CalcButton(label: label(for: key),
                                   symbol: key.symbol,
                                   kind: key.kind,
                                   accent: accent,
                                   armed: armed(key)) { press(key) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The clear key's label is state-dependent ("C" mid-entry, else "AC").
    private func label(for key: CalcKey) -> String {
        if case .clear = key { return calculator.clearLabel }
        return key.label
    }

    /// Light up the operator key that's currently awaiting its right operand.
    private func armed(_ key: CalcKey) -> Bool {
        if case .op(let o) = key { return calculator.pendingOp == o }
        return false
    }

    private func press(_ key: CalcKey) {
        switch key {
        case .digit(let d): calculator.inputDigit(d)
        case .decimal:      calculator.inputDecimal()
        case .op(let o):    calculator.setOp(o)
        case .equals:       calculator.equals()
        case .clear:        calculator.clear()
        case .negate:       calculator.negate()
        case .percent:      calculator.percent()
        case .backspace:    calculator.backspace()
        }
    }

    // MARK: History sidebar

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Text("History").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 0)
                if !calculator.history.isEmpty {
                    Button { calculator.clearHistory() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: IconSize.sm, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.island)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.md)

            if calculator.history.isEmpty {
                emptyHistory
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: Spacing.xs) {
                        ForEach(calculator.history) { entry in
                            HistoryRow(entry: entry) { calculator.recall(entry) }
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xxl)
                }
                .smoothScrollBounce()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyHistory: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: IconSize.xxl))
                .foregroundStyle(Palette.textFaint)
            Text("No history yet")
                .font(Typography.footnote)
                .foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Keys

/// One keypad key. `kind` drives its colour; `label`/`symbol` its glyph.
private enum CalcKey: Identifiable, Equatable {
    case digit(Int)
    case decimal
    case op(CalculatorEngine.Op)
    case equals
    case clear
    case negate
    case percent
    case backspace

    enum Kind { case digit, function, op, equals }

    var kind: Kind {
        switch self {
        case .digit, .decimal:                     return .digit
        case .clear, .negate, .percent, .backspace: return .function
        case .op:                                  return .op
        case .equals:                              return .equals
        }
    }

    /// A text label, or nil when the key renders an SF Symbol (see `symbol`).
    var label: String {
        switch self {
        case .digit(let d): return "\(d)"
        case .decimal:      return "."
        case .op(let o):    return o.rawValue
        case .equals:       return "="
        case .clear:        return "AC"   // resolved to "C"/"AC" by the view
        case .negate:       return "±"
        case .percent:      return "%"
        case .backspace:    return ""
        }
    }

    /// An SF Symbol name for keys drawn as a glyph rather than text.
    var symbol: String? {
        if case .backspace = self { return "delete.left" }
        return nil
    }

    var id: String {
        switch self {
        case .digit(let d): return "d\(d)"
        case .decimal:      return "dot"
        case .op(let o):    return "op\(o.rawValue)"
        case .equals:       return "eq"
        case .clear:        return "clr"
        case .negate:       return "neg"
        case .percent:      return "pct"
        case .backspace:    return "del"
        }
    }
}

/// A single keypad button: a rounded key that fills its grid cell, coloured by
/// `kind` (digits neutral, functions lighter, operators accent-tinted, `=` solid).
/// `.island` gives the swell-on-hover + dip-on-press feel; the fill also brightens
/// under the pointer so the hovered key is unmistakable.
private struct CalcButton: View {
    let label: String
    let symbol: String?
    let kind: CalcKey.Kind
    let accent: Color
    let armed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: IconSize.lg, weight: .medium))
                } else {
                    Text(label).font(Typography.titleLarge)
                }
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.island)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: armed)
    }

    private var fill: Color {
        switch kind {
        case .digit:    return hovering ? Palette.surfaceRaised : Palette.surface
        case .function: return hovering ? Palette.surfaceStrong : Palette.surfaceRaised
        case .op:       return armed ? accent : accent.opacity(hovering ? 0.30 : 0.18)
        case .equals:   return accent
        }
    }

    private var foreground: Color {
        switch kind {
        case .digit:    return Palette.textPrimary
        case .function: return Palette.textHigh
        case .op:       return armed ? Palette.onAccent : accent
        case .equals:   return Palette.onAccent
        }
    }
}

/// Routes hardware key presses to the calculator engine while the calculator is on
/// screen. A *local* key-down monitor only fires for events our app is handling —
/// and our panel is a `.nonactivatingPanel`, so it only receives keys once the user
/// has clicked into the calculator (making the panel key). A mere hover therefore
/// never steals typing from whatever app the user is actually in.
@MainActor
final class CalculatorKeyboard: ObservableObject {
    private var monitor: Any?

    func start(_ engine: CalculatorEngine) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                CalculatorKeyboard.handle(event, engine) ? nil : event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Map a key-down to an engine action. Returns true when handled (so the event
    /// is swallowed — no system beep); false to let it pass through (e.g. ⌘-shortcuts).
    private static func handle(_ event: NSEvent, _ engine: CalculatorEngine) -> Bool {
        // Never intercept ⌘/⌃/⌥ chords — those are app/system shortcuts (⌘C, ⌘Q…).
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        // Special keys by code (independent of layout): Return/Enter, Delete, Escape.
        switch event.keyCode {
        case 36, 76: engine.equals(); return true     // Return / numpad Enter
        case 51:     engine.backspace(); return true  // Delete (Backspace)
        case 53:     engine.clear(); return true       // Escape → clear
        default: break
        }
        // Printable keys by their typed character (so Shift gives +, *, % directly).
        guard let ch = event.characters?.first else { return false }
        switch ch {
        case "0"..."9": engine.inputDigit(ch.wholeNumberValue ?? 0); return true
        case ".", ",":  engine.inputDecimal(); return true
        case "+":       engine.setOp(.add); return true
        case "-":       engine.setOp(.subtract); return true
        case "*", "x", "X": engine.setOp(.multiply); return true
        case "/":       engine.setOp(.divide); return true
        case "=":       engine.equals(); return true
        case "%":       engine.percent(); return true
        case "c", "C":  engine.clear(); return true
        default:        return false
        }
    }
}

/// One history entry: the sum above its result, right-aligned. Tap to recall.
private struct HistoryRow: View {
    let entry: CalculatorEngine.Entry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .trailing, spacing: Spacing.hairline) {
                Text(entry.expression)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                Text(entry.result)
                    .font(Typography.bodyMono)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.vertical, Spacing.sm)
            .padding(.horizontal, Spacing.md)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(hovering ? Palette.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.islandFlat)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// The compact Calculator pill (only via `DI_FORCE_APP=calculator` — Calculator
/// isn't auto-active; it's reached from the sidebar). Shows the live display value.
struct CalculatorCompactView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var calculator: CalculatorEngine

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: IslandApp.calculator.icon)
                .font(.system(size: IconSize.lg))
                .foregroundStyle(IslandApp.calculator.tint)
            Text(calculator.display)
                .font(Typography.bodyMono)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            Image(systemName: "chevron.down")
                .font(.system(size: IconSize.sm, weight: .bold))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
