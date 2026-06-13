# CLAUDE.md — project rules

## Design system (MANDATORY — applies to every UI change)

All UI MUST follow **`DESIGN_GUIDELINES.md`**. Views reference design **tokens**, never
raw literals.

- **Tokens:** `Sources/DynamicIsland/Core/DesignTokens.swift` — `Spacing`, `Radius`,
  `Palette`, `Motion`, `Transitions`, `IconSize`, `shellShadow()/raisedShadow()` — and
  `Core/Typography.swift` for all text.
- **Forbidden in view code:** raw `Color(red:)` / `.white.opacity()` / `.black.opacity()`,
  `.font(.system(size: <number>))`, `cornerRadius: <number>`, `.spring(...)` /
  `.easeOut(...)` / `.easeInOut(...)`, `.shadow(...)`, numeric `spacing:` / `.padding(<number>)`.
  Use the token instead. The only sanctioned numbers are `IconSize` symbol sizes and
  layout geometry in `IslandConfiguration`.
- **Animations:** each element type has ONE assigned `Motion` curve — see
  DESIGN_GUIDELINES.md §6 "Animation standards by element" (hover→`Motion.hover`,
  island expand→`Motion.morph`, content swap→`Motion.contentMorph`, popup→`Motion.popup`,
  etc.). Use the matching `Transitions` value for insert/remove.
- **Escape hatch:** a genuinely justified signature effect (accent glow, favorite
  burst, volume nudge) may keep a raw value if the line is annotated `// design-lint:allow`.

### Enforcement — do this, don't rely on memory
After ANY change to a `*.swift` view, run the linter and drive it to **0**:

    ./Scripts/design-lint.sh

`./build.sh` also reports the count after every build (advisory; `DESIGN_LINT_STRICT=1`
makes it fail). A PostToolUse hook lints each `.swift` file you edit. **A task that
touches UI is not done until `./Scripts/design-lint.sh` is clean (or every remaining
hit is a `// design-lint:allow` exception).**

## Build / run
- Build: `./build.sh` (do NOT use `swift build`). Run: `./build.sh run`.
- See the user-memory notes for the test/launch conventions (raw-binary env vars,
  `DI_MOCK_*`, cursor parking, never starting Apple Music playback, etc.).
