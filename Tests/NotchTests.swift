import Foundation

/// Pure-logic tests for notch integration: notch-mode opt-out resolution, the
/// remembered-display registry, and the render-style value type.
@MainActor
func runNotchTests() {
    testUsesNotchMode()
    testRememberDisplays()
    testRenderStyleEquatable()
    testNotchGeometry()
}

@MainActor
private func freshSettings() -> AppSettings {
    let suite = "notch-tests"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return AppSettings(defaults: defaults)
}

@MainActor
private func testUsesNotchMode() {
    let s = freshSettings()
    // A notched display integrates by default.
    expectEqual(s.usesNotchMode(onDisplay: "A", hasNotch: true), true, "notched default on")
    // A non-notched display never integrates, opt-out or not.
    expectEqual(s.usesNotchMode(onDisplay: "A", hasNotch: false), false, "no notch → floating")
    // Opting a notched display out reverts it to the floating island.
    s.notchModeOptOut.insert("A")
    expectEqual(s.usesNotchMode(onDisplay: "A", hasNotch: true), false, "opted out → floating")
    // The island on/off setting is independent and still resolves.
    expectEqual(s.showsIsland(onDisplay: "B"), true, "island on by default")
    s.islandDisplayOptOut.insert("B")
    expectEqual(s.showsIsland(onDisplay: "B"), false, "island opted out")
}

@MainActor
private func testRememberDisplays() {
    let s = freshSettings()
    let builtIn = DisplayInfo(id: "A", displayID: 1, name: "Built-in Display",
                              isMain: true, hasNotch: true,
                              notch: NotchGeometry(width: 200, height: 32))
    let dell = DisplayInfo(id: "B", displayID: 2, name: "DELL S2721QS",
                           isMain: false, hasNotch: false, notch: nil)
    s.rememberDisplays([builtIn, dell])
    expectEqual(s.knownDisplays["A"], "Built-in Display", "remembered notched name")
    expectEqual(s.knownDisplays["B"], "DELL S2721QS", "remembered external name")
    expect(s.notchCapable.contains("A"), "notched display is notch-capable")
    expect(!s.notchCapable.contains("B"), "external display is not notch-capable")

    // Remembering is sticky: a display stays known + notch-capable once unplugged
    // (called again without it).
    s.rememberDisplays([dell])
    expectEqual(s.knownDisplays["A"], "Built-in Display", "disconnected display stays remembered")
    expect(s.notchCapable.contains("A"), "disconnected display stays notch-capable")
}

private func testRenderStyleEquatable() {
    expect(IslandRenderStyle.floating == .floating, "floating == floating")
    let g = NotchGeometry(width: 200, height: 32)
    expect(IslandRenderStyle.notch(g) == .notch(g), "notch == notch (same geometry)")
    expect(IslandRenderStyle.floating != .notch(g), "floating != notch")
    expect(IslandRenderStyle.notch(g) != .notch(NotchGeometry(width: 180, height: 32)),
           "notch geometry participates in equality")
}

private func testNotchGeometry() {
    let g = NotchGeometry(width: 210, height: 34)
    expectEqual(g.width, 210, "notch width")
    expectEqual(g.height, 34, "notch height")
}
