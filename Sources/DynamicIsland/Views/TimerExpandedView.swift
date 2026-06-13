import SwiftUI

/// The Timers app filling the main island: a header with quick-add buttons, an
/// optional countdown creator, and a scrolling list of timers/stopwatches with
/// per-row pause, reset, rename, and delete.
struct TimerExpandedView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var timers: TimerManager

    private var config: IslandConfiguration { controller.configuration }
    private var accent: Color { IslandApp.timers.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header

            if controller.isCreatingTimer {
                TimerCreatorView(controller: controller, timers: timers)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if timers.timers.isEmpty {
                // Center the placeholder in whatever space is left below the
                // header. At the snug empty height this just sits it neatly under
                // the header; if the card is momentarily taller (e.g. mid-morph
                // when switching from a bigger app) the text stays centered
                // instead of clinging to the top with a void beneath it.
                Text("No timers yet — add one above")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: config.timersRowSpacing) {
                        ForEach(timers.timers) { timer in
                            TimerRowView(controller: controller, timers: timers, timer: timer)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, config.expandedHMargin)
        .padding(.vertical, config.expandedVMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: Spacing.md) {
            Text("Timers")
                .font(Typography.title2)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            quickButton("stopwatch", help: "Start a stopwatch") {
                timers.addStopwatch()
            }
            quickButton(controller.isCreatingTimer ? "xmark" : "plus", help: "New timer") {
                withAnimation(Motion.transition) {
                    controller.isCreatingTimer.toggle()
                }
            }
        }
        .frame(height: 30)
    }

    private func quickButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        IconButton(system: symbol, action: action).help(help)
    }
}

/// One row in the timers list.
private struct TimerRowView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var timers: TimerManager
    let timer: IslandTimer

    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var rowTint: Color { timer.hasFired ? .timerRing : IslandApp.timers.tint }

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: timer.kind == .countdown ? "timer" : "stopwatch")
                .font(.system(size: IconSize.md, weight: .semibold))
                .foregroundStyle(rowTint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                if isRenaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textPrimary)
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .onChange(of: nameFocused) { focused in
                            if !focused { commit() }
                        }
                } else {
                    Text(timer.name)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: startRename)
                }

                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let clock = formatClock(timer.displayValue(at: context.date))
                    Text(clock)
                        .font(Typography.title2Mono)
                        .foregroundStyle(timer.hasFired ? rowTint : Palette.textHigh)
                        .contentTransition(.numericText())
                        .animation(Motion.hover, value: clock)
                }
            }

            Spacer(minLength: Spacing.sm)

            if !timer.hasFired {
                control(timer.isRunning ? "pause.fill" : "play.fill") {
                    timers.toggleRun(timer.id)
                }
            }
            control("arrow.counterclockwise") { timers.reset(timer.id) }
            control("xmark") { timers.remove(timer.id) }
        }
        .padding(.horizontal, Spacing.xl)
        .frame(height: controller.configuration.timerRowHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(timer.hasFired ? rowTint.opacity(0.16) : Palette.surfaceSubtle)
        )
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        IconButton(system: symbol, action: action)
    }

    private func startRename() {
        draft = timer.name
        isRenaming = true
        controller.beginEditing()
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commit() {
        guard isRenaming else { return }
        timers.rename(timer.id, to: draft)
        isRenaming = false
        nameFocused = false
        controller.endEditing()
    }
}

/// The inline countdown creator: pick a duration (steppers + presets), an
/// optional name, then Start.
private struct TimerCreatorView: View {
    @ObservedObject var controller: DynamicIslandController
    @ObservedObject var timers: TimerManager

    @State private var minutes = 5
    @State private var seconds = 0
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var accent: Color { IslandApp.timers.tint }
    private var duration: TimeInterval { TimeInterval(minutes * 60 + seconds) }

    var body: some View {
        VStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.lg) {
                stepper(value: $minutes, range: 0...180, label: "min")
                Text(":").font(Typography.title2).fontWeight(.bold).foregroundStyle(Palette.textTertiary)
                stepper(value: $seconds, range: 0...59, label: "sec", step: 5)
                Spacer()
                ForEach([1, 3, 5, 10], id: \.self) { m in
                    preset(minutes: m)
                }
            }

            HStack(spacing: Spacing.md) {
                TextField("Name (optional)", text: $name)
                    .textFieldStyle(.plain)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textPrimary)
                    .focused($nameFocused)
                    .onChange(of: nameFocused) { focused in
                        if focused { controller.beginEditing() } else { controller.endEditing() }
                    }
                    .onSubmit(start)
                    .padding(.horizontal, Spacing.lg)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: Radius.md).fill(Palette.surface))

                Button(action: start) {
                    Text("Start")
                        .font(Typography.calloutStrong)
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, Spacing.xxl)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(accent))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.islandSubtle)
                .disabled(duration < 1)
                .opacity(duration < 1 ? 0.4 : 1)
            }
        }
        .padding(Spacing.lg)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Palette.surfaceSubtle))
    }

    private func stepper(value: Binding<Int>, range: ClosedRange<Int>, label: String, step: Int = 1) -> some View {
        HStack(spacing: Spacing.sm) {
            stepButton("minus") { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) }
            VStack(spacing: Spacing.zero) {
                Text(String(format: "%02d", value.wrappedValue))
                    .font(Typography.headlineMono)
                    .foregroundStyle(Palette.textPrimary)
                Text(label)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textTertiary)
            }
            .frame(width: 26)
            stepButton("plus") { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) }
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        IconButton(system: symbol, size: .compact, weight: .bold, action: action)
    }

    private func preset(minutes m: Int) -> some View {
        Button {
            minutes = m
            seconds = 0
        } label: {
            Text("\(m)m")
                .font(Typography.caption)
                .foregroundStyle(minutes == m && seconds == 0 ? Palette.onAccent : Palette.textHigh)
                .frame(width: 28, height: 22)
                .background(
                    Capsule().fill(minutes == m && seconds == 0 ? accent : Palette.surfaceRaised)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.island)
    }

    private func start() {
        guard duration >= 1 else { return }
        timers.addCountdown(duration: duration, name: name)
        name = ""
        nameFocused = false
        controller.endEditing()
        withAnimation(Motion.transition) {
            controller.isCreatingTimer = false
        }
    }
}
