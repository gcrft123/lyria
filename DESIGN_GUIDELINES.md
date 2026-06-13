# Dynamic Island — Design Guidelines

**These rules are mandatory.** Every view MUST follow them. They exist so the whole
island feels like one designed object instead of 50 separately-tuned screens.

There is a single source of truth for each dimension of the design, and view code
references it by name — never with a raw literal:

| Dimension | Source of truth | Swift |
|-----------|-----------------|-------|
| Type | `Typography` | `Sources/DynamicIsland/Core/Typography.swift` |
| Spacing | `Spacing` | `Sources/DynamicIsland/Core/DesignTokens.swift` |
| Radius | `Radius` | `DesignTokens.swift` |
| Color | `Palette` | `DesignTokens.swift` |
| Motion | `Motion` | `DesignTokens.swift` |
| Icon size | `IconSize` | `DesignTokens.swift` |
| Shadows | `shellShadow()` / `raisedShadow()` | `DesignTokens.swift` |
| Position / rhythm | `Layout` | `DesignTokens.swift` |
| Buttons | `.island` / `.islandSubtle` / `.islandFlat` | `Views/IslandButtonStyle.swift` |
| Icon buttons | `IconButton` | `Views/IconButton.swift` |
| Music player | `MusicPlayerColumn` | `Views/MusicPlayerColumn.swift` |
| Window / card geometry | `IslandConfiguration` | `Sources/DynamicIsland/Core/IslandConfiguration.swift` |

> **The litmus test:** if you typed a number or a color into a view, it is almost
> certainly wrong. The only raw numbers allowed in a view are SF Symbol point sizes
> (which must equal an `IconSize` value) and one-off geometry that belongs in
> `IslandConfiguration`.

---

## 1. Typography

- **MUST** use a `Typography.<role>` for every `Text`. Never `Text(...).font(.system(size:))`.
- Roles, largest → smallest: `display` (30) · `titleLarge` (20) · `title` (17) ·
  `title2` (16) · `headline` (15) · `subheadline` (14) · `bodyStrong` (13) ·
  `body` (13) · `bodyRegular` (13) · `calloutStrong` (12) · `callout` (12) ·
  `caption` (11) · `footnote` (11).
- **11pt is the readable floor.** Nothing smaller. If text feels like it needs to be
  smaller, enlarge the container instead.
- Same size, different weight → keep the role and add `.fontWeight(_:)`. Don't reach
  for a raw size.
- Live/aligned numerals (clocks, time ranges, %, counts) → the `…Mono` variants or
  `.monospacedDigit()`.
- **Color** of text comes from the `Palette` text ramp (below), never a raw opacity.

### Semantic text roles — what each *kind* of text MUST use
Pick by the text's JOB, not by eyeballing a size. Type **and** color are both fixed by
the role (this is how "primary vs secondary" stays consistent across every app).

| Text role | When it's used | Type | Color |
|-----------|----------------|------|-------|
| **App / screen title** | the one heading naming the current app or page | `title` (17) | `textPrimary` |
| **Eyebrow / section header** | a small label grouping a section ("UP NEXT", "MUSIC") | `caption` (11), usually `.uppercased()` + `.kerning(0.5)` | `textSecondary` |
| **Primary label** | the main text of a row/card (track title, event title, timer name) | `bodyStrong` (13); `subheadline` (14) in a hero/top row | `textPrimary` |
| **Secondary label / subtitle** | the sub-line under a primary (artist, place) | `callout` (12) / `footnote` (11) | `textSecondary` |
| **Metadata / timestamp** | times, dates, H/L, durations, counts | a `…Mono` variant | `textSecondary` → `textTertiary` |
| **Hero value / numeral** | the ONE big number on a screen (countdown, temp, volume %) | `display` (30) / `titleLarge` (20) + `.monospacedDigit()` | `textPrimary` |
| **Caption / hint** | helper text under a control | `footnote` (11) | `textTertiary` |
| **Placeholder / empty state** | "Nothing Playing", "Getting weather…" | `footnote` / `subheadline` | `textTertiary` → `textFaint` |
| **On-accent label** | text/glyph sitting on a filled accent (selected pill) | `caption` / `callout` | `onAccent` |

> One key value per screen is `textPrimary`; everything supporting it steps down the
> ramp. If two things are both `textPrimary`, one of them is mis-roled.

## 2. Color

The island paints on **black** (`Palette.background`). Foreground is white at fixed
opacities; surfaces and strokes are translucent white; hues come from a fixed set of
named accents.

### Foreground / text ramp — pick by role, never a raw opacity
- `textPrimary` (1.0) — titles, the one key value in a view.
- `textHigh` (0.85) — strong secondary, active-on-dark labels.
- `textSecondary` (0.60) — standard labels, metadata.
- `textTertiary` (0.40) — captions, hints, inactive glyphs.
- `textFaint` (0.28) — disabled, decorative, watermark.

### Surfaces (translucent white fills)
- `surfaceSubtle` (0.05) — resting card / row background.
- `surface` (0.08) — default control fill (icon buttons, chips).
- `surfaceRaised` (0.12) — hover / emphasized fill.
- `surfaceStrong` (0.16) — pressed fill, slider tracks.

### Strokes
- `hairlineStroke` (0.10) — 1pt dividers.
- `stroke` (0.12) — resting borders.
- `strokeStrong` (0.20) — hover / focused borders.

### Accents — the ONLY hues
`blue · cyan · teal · green · indigo · purple · pink · red · orange · amber`, plus the
semantic `favorite`, `recording`, `positive`, `danger`, and `neutralAccent`.
- **MUST NOT** introduce a new `Color(red:…)`. If you need a hue, use the closest
  existing accent. New accents are a guideline change, not a per-view decision.
- Per-app tint comes from `IslandApp.tint` (which maps to `Palette.tint*`). Music
  tints from artwork at runtime; everything else uses its fixed tint.
- Accent fills/backgrounds use the accent at a ramp opacity (e.g. `accent.opacity` is
  fine for tinting **an accent**, but plain white/black opacities must be ramp tokens).

## 3. Spacing

Scale (points): **1 · 2 · 4 · 6 · 8 · 10 · 12 · 16 · 20 · 24** → `Spacing.hairline,
xxs, xs, sm, md, lg, xl, xxl, xxxl, xxxxl`.

- **MUST** use a `Spacing` token for every `spacing:` and `.padding()`. No `.padding(7)`.
- `.padding(0)` / `spacing: 0` may stay as the literal `0`.
- Typical usage: row internal gaps `sm`–`lg`; card padding `xl`–`xxl`; section gaps
  `xxl`–`xxxl`; tight icon+label `xs`–`sm`.
- Off-scale values are snapped to the nearest token (ties round to the larger value so
  we never tighten below the grid).

## 4. Shape & radius

Scale: **2 · 4 · 8 · 12 · 16 · 28 · 36** → `Radius.xs, sm, md, lg, xl, popup, shell`.

- **MUST** use a `Radius` token for `cornerRadius`. Use `style: .continuous`.
- Fully-rounded elements use **`Capsule()`**, not a giant radius.
- Standard mapping: chips/buttons `md`; cards/list rows `lg`; large panels/stage `xl`;
  popup/HUD shell `popup`; expanded island shell `shell`; the collapsed island is a
  pill (radius = height/2).
- The island silhouette is always `IslandShape` (continuous squircle).

## 5. Sizing

- **Icons (SF Symbols):** size from `IconSize` (9 · 11 · 13 · 16 · 20 · 24 · 30).
  Inline glyphs next to `caption`/`footnote` text use `xs`/`sm`; standard control
  glyphs `md`/`lg`; hero glyphs `xl`+.
- **Hit targets & control sizes:** from `Layout` — minimum `Layout.hitTargetMin` (28×28);
  icon buttons use a `Layout.iconButton` (30) / `iconButtonCompact` (24) background. See §8.
- **In-content position & rhythm** (insets, gaps, row heights between elements) come from
  `Layout` (see §9). **Window / card geometry** (the card's own width/height) lives ONLY in
  `IslandConfiguration` — never hard-coded in a view (the linter flags 3-digit `.frame`
  literals).

## 6. Motion

**MUST** animate with a `Motion` spring (and, for views that insert/remove, a
`Transitions` value). No raw `.spring(response:…)`, `.easeInOut`, or `.easeOut` in
views. Every kind of element has ONE assigned animation — do not mix them.

### The curves
| Token | Spring | Feel |
|-------|--------|------|
| `Motion.hover` | 0.30 / 0.66 | quick, slight life |
| `Motion.press` | 0.24 / 0.55 | snappy dip |
| `Motion.transition` | 0.34 / 0.86 | smooth, minimal overshoot |
| `Motion.morph` | 0.40 / 0.72 | bouncy size/shape morph |
| `Motion.contentMorph` | 0.32 / 0.90 (+0.06s delay) | settle, lags the shell |
| `Motion.side` | 0.44 / 0.78 | springy slide |
| `Motion.popup` | 0.30 / 0.85 | controlled drop-in |
| `Motion.pop` | 0.32 / 0.60 | overshoot, celebratory |
| `Motion.gentle` | 0.45 / 0.85 | slow ambient settle |

### Animation standards by element  ← which animation each thing MUST use
| Element / interaction | Animation | Transition |
|-----------------------|-----------|------------|
| Button / icon / chip **hover swell** | `Motion.hover` | — |
| Button **press** dip | `Motion.press` (built into the button styles) | — |
| Row / card **hover highlight** (bg lift, chevron slide) | `Motion.hover` | — |
| **Selection** change (segmented tab, selected pill/ring) | `Motion.hover` | — |
| Slider **value** moved programmatically (e.g. apply EQ preset) | `Motion.transition` | — |
| Slider **value** dragged by the user | none (follows the finger) | — |
| In-app **navigation** (list ↔ detail, sub-tabs) | `Motion.transition` | `Transitions.detailPush` / `.listReturn` |
| Island **expand / collapse** (silhouette + size) | `Motion.morph` | — |
| **App / screen content swap** inside the island | `Motion.contentMorph` | `Transitions.fade` |
| **Side island / edge extension / secondary** in-out | `Motion.side` | scale+opacity |
| **Popup / banner / HUD** present & dismiss | `Motion.popup` | `Transitions.popup` |
| **Celebration** / emphasis burst | `Motion.pop` (+ signature effect) | — |
| **Ambient** value (weather, large counts, glow strength) | `Motion.gentle` | — |
| Continuous **render loops** (glow, EQ bars, progress tick) | `TimelineView(.periodic/.animation)` | — (exempt) |

### Exemptions
- **Continuous render loops** (`TimelineView`) are a render cadence, not a transition.
- **Signature / physical effects** — the accent glow and choreographed one-shots like
  the favorite-heart burst (snappy pop + particle fly-out) — are designed effects, not
  standard state transitions, and live in their own dedicated views.

## 7. Elevation (shadows)

- Use `.shellShadow()` (the island shell) or `.raisedShadow()` (floating knobs /
  popovers). No ad-hoc `.shadow(...)` with bespoke radius/offset in views.
- Accent **glow** (the beat/ringing/edge glow) is a deliberate effect, not elevation —
  it stays in its dedicated overlay views.

## 8. Buttons, controls & interaction

### The three button styles — and ONLY these three
Every `Button` MUST use one of the shared styles from `IslandButtonStyle.swift`. Never a
system style (`.plain`, `.bordered`, `.borderless`, …) and **never define a new
`ButtonStyle`** — there is exactly one (`IslandButtonStyle`), exposed three ways:

| Style | Hover swell | Use for |
|-------|-------------|---------|
| `.island` | 1.10 (full) | the default — icon buttons, chips, toggles, small controls |
| `.islandSubtle` | 1.06 (gentle) | large/primary glyphs where a big swell feels heavy (transport play, hero controls) |
| `.islandFlat` | 1.00 (none, brightness only) | wide TEXT rows — card headers, list/nav rows — where scaling the whole row is too much |

### Shared components — one implementation each (no copies that can drift)
A repeated element MUST have ONE implementation that every site reuses. Re-creating it
inline is how two "identical" things silently diverge in spacing / color / size.

- **`IconButton`** (`Views/IconButton.swift`) is THE circular icon button — reset,
  nav chevrons, quick-add, steppers, stage controls. Two sizes: `.standard`
  (`Layout.iconButton` 30 / glyph `IconSize.md`) and `.compact` (`Layout.iconButtonCompact`
  24 / glyph `IconSize.sm`), glyph `textHigh`, `surface` chip, `.island` feel. **MUST NOT**
  hand-roll a `Button { Image(systemName:)... .background(Circle()) }` — use `IconButton`.
  - `raised: true` → a FLOATING/detached affordance: solid backing + stroke + `raisedShadow()`
    so it stays legible where it overlaps an edge onto the desktop (e.g. the pin button
    straddling the card's top-right corner). `active: true` brightens the glyph for a lit
    state (e.g. the pinned ✕).
- **`MusicPlayerColumn`** (`Views/MusicPlayerColumn.swift`) is THE player (artwork →
  scrubber → transport → bottom). The full Music app and the Dashboard "mirror" BOTH
  render it (`showsVolume:` toggles the volume speaker/row); neither re-implements the
  rows. This is why their text positions and colors are guaranteed identical.
- **Toggles / sliders / segmented selectors** use the STOCK SwiftUI `Toggle(.switch)`,
  `Slider`, and `Picker(.segmented)` — built against the macOS 26 SDK these render Apple's
  **Liquid Glass** natively (and fall back to the legacy look on macOS ≤ 25). Add
  `.tint(accent)` for the active color; **don't** hand-roll glass controls with
  `.glassEffect` when a stock control exists. For the few controls with NO stock
  equivalent — the Tweaks vertical **EQ bands** + centre-origin **pan** — use the real
  Liquid Glass material via `GlassTrack` (`.glassEffect`, 26+, token fallback below).
  Excluded entirely: the **music player** and **Dashboard** keep their bespoke controls
  (`VolumeSliderView` / `ProgressBarView` / the mirror).

The linked-SDK field must be ≥ 26 for any of this to render (see `build.sh` — it stamps
`sdk 26.0` while keeping `minos 13.0`); otherwise macOS shows the legacy controls.
- General rule: if you're about to copy a control or a multi-row layout into a second
  view, extract a shared view instead. The linter can't see a duplicate — code review must.

### Button roles — pick the role, get its style + size + color
| Role | Examples | Style | Glyph (`IconSize`) | Hit target | Color (rest → active) |
|------|----------|-------|--------------------|------------|------------------------|
| **Primary / transport** | play · pause | `.islandSubtle` | `xxl`–`xxxl` | full transport row; ≥ `Layout.hitTargetMin` | `textPrimary` |
| **Secondary icon** (`IconButton`) | reset · nav chevrons · quick-add · steppers | `.island` | `.standard` `md` / `.compact` `sm` | `Layout.iconButton` (30) / `iconButtonCompact` (24) circle | `textHigh` → `textPrimary` |
| **Toggle / stateful** | shuffle · repeat · favorite · switches | `.island` | `md` | `Layout.iconButton` / `iconButtonCompact` | inactive `textSecondary` → active **accent** |
| **Tertiary / nav row** | a Settings/Tweaks category · "Wave sensitivity" | `.islandFlat` | trailing chevron `xs` | full row, height `Layout.navRowHeight` (48) | label `textPrimary`, chevron `textFaint` |
| **Eyebrow / header button** | a dashboard card header | `.islandFlat` | leading tint icon `xs` + trailing chevron `xs` | full header row, height `Layout.headerHeight` | tint icon · `caption` `textSecondary` label |
| **Segmented / tab** | EQ ↔ Spatial sub-tabs | `.island` | — | each segment ≥ `Layout.hitTargetMin` | selected = filled **accent** + `onAccent`; unselected `textSecondary` |
| **Chip / pill** | EQ presets · filters | `.island` | — | height ≈ `Layout.hitTargetMin`, radius `Radius.md` | unselected `surface` + `textSecondary`; selected accent fill + `onAccent` |
| **Destructive** | delete timer | `.island` | `md` | `Layout.iconButton` | `danger` |

### Button sizes (hit targets)
- Any tappable control MUST be **≥ `Layout.hitTargetMin` (28×28)**. Small glyphs reach
  this with a `Layout.iconButton` (30) or `iconButtonCompact` (24) background, OR by
  giving the glyph a larger frame + `.contentShape(Rectangle())` so the whole frame taps.
- A big control (transport play, a wide row) uses its **full row** as the hit area via
  `.contentShape(Rectangle())` — don't rely on the tiny glyph bounds.
- Control frame sizes come from `Layout` metrics or an `IconSize`-derived square — never a
  raw card-scale number (the linter flags 3-digit `.frame(...)` literals in views).

### Interaction
- **Hover is expected**: a swell and/or a `surfaceRaised` background lift, animated with
  `Motion.hover`. Custom hovers use a small view with `@State hovering` + `.onHover` (the
  expanded panel captures mouse events).
- **Press** dips slightly (built into the button styles, `Motion.press`).
- **Selection** is shown with the element's **accent** (filled pill, ring, or tint) +
  `onAccent` content — not a brightness change.

## 9. Layout, position & vertical rhythm

The expanded island is ONE fixed-height card (the standard **324**, see
`IslandConfiguration.expandedHeight`). The recurring **"compressed UI" bug** is a view
that lays out natural-height rows and lets the rest collapse into a void at the bottom.
Two rules prevent it: **fill discipline** and **position rhythm**.

### 9.1 Fill discipline (MUST) — every app fills the standard height
- A primary app view MUST fill the full card height. Its root MUST NOT be a top-aligned
  stack of intrinsic-height rows that leaves empty space below.
- Achieve fill ONE of two ways:
  1. **Sum-to-height rows** — fixed row heights + gaps that add up to the card height.
     *Example — the Music player:* `topRow 68 + progress 37 + transport 47 + bottom 38`
     `+ 3·26` gaps `+ 2·28` margins `= 324`. If you add/remove a row, **re-balance** so it
     still sums (the dashboard "music mirror" reuses these exact numbers — that's why it
     reads identically to the real player instead of topping out at ~50%).
  2. **Distributed fill** — give flexible rows `.frame(maxHeight: .infinity)` / explicit
     `Spacer()`s so they share the slack evenly. A trailing `Spacer(minLength: 0)` is
     **not** a substitute for content that should grow.
- Side-by-side **columns each fill independently** (in the mirror, the player column AND
  the Calendar/Weather column both reach the full 324).
- A scrolling app (Weather, Settings) fills by **overflowing into a `ScrollView`**, never
  by leaving a gap.
- Don't shrink type or controls "to make it fit" — re-balance the rhythm. The 11pt floor
  and the control sizes are fixed.

### 9.2 Position standards (measured from the shell, in points) — use `Layout`
Standard content frame inside the expanded shell:
- Insets: top `Layout.insetTop` (28) · sides `Layout.insetH` (18) · bottom
  `Layout.insetBottom` (28). (These equal the card's own `expanded*Margin`.)

| Element | Distance from the shell top | Token |
|---------|-----------------------------|-------|
| Eyebrow / app title | **28** | `Layout.insetTop` |
| First content row (a title is above it) | title bottom **+ 16** | `Layout.titleToContent` |
| First content row (no title) | **28** | `Layout.insetTop` |
| The next section | previous section **+ 20** | `Layout.sectionGap` |
| A row within a list | previous row **+ 10** | `Layout.rowGap` |
| A sub-label under its label | label bottom **+ 2** | `Layout.labelGap` |

Standard heights: header/eyebrow row `Layout.headerHeight` (24) · list/menu/toggle/picker
row `Layout.listRowHeight` (44) · list→detail nav row `Layout.navRowHeight` (48).

- MUST express every inset/position with a `Spacing` or `Layout` token — the linter
  forbids the raw number. The card's own width/height stays in `IslandConfiguration`.
- The Music player is the one bespoke full-bleed rhythm (its row heights live in
  `IslandConfiguration`); everything else uses the `Layout` rhythm above.

## 10. Menus & surfaces by role

Different containers have different jobs → different recipes. Match the role's recipe;
don't invent a one-off layout.

| Surface | Role | Recipe |
|---------|------|--------|
| **List menu** (Settings / Tweaks categories) | choose a destination | full-width `.islandFlat` rows, height `Layout.navRowHeight` (48); leading tint icon (`md`) · title `body` · trailing chevron (`xs`, `textFaint`); rows split by `hairlineStroke`; black (no card fill) |
| **Detail page** (a category opened) | edit one thing | enters via `Transitions.detailPush` / leaves via `.listReturn` (`Motion.transition`); a `title` (17) at `Layout.insetTop`; controls below on the `Layout` rhythm |
| **Card grid / dashboard** | glanceable summary | black, no card fill; each cell a tappable `.islandFlat` header (tint icon + `caption` + chevron) over its mini widget; cells **fill** the height (§9.1) |
| **Sidebar column** (queue · dashboard right) | secondary stacked list | `caption`/`textSecondary` section header over a narrow list; **two-line rows when width is tight** so nothing crowds the rounded edge; trailing inset `Layout.insetH` |
| **Segmented control / sub-tabs** (EQ ↔ Spatial) | switch mode within a page | equal segments on a `Radius.md`/`Capsule` track; selected = filled **accent** + `onAccent` (animate `Motion.hover`); unselected `textSecondary` |
| **Picker row** (lead time 5/10/15/30) | pick one value | label (`body`) + trailing inline/segmented control on one `Layout.listRowHeight` row |
| **Toggle row** (settings switches) | flip a boolean | label (`body`) + optional sub-label (`footnote`, `textTertiary`) on the left, tinted `Toggle` on the right, `Layout.listRowHeight` |
| **Popup / HUD** | transient takeover | the popup shell (`Radius.popup`), `Motion.popup` + `Transitions.popup`; icon + one-line message; grows slightly on hover to read as tappable |

## 11. Enforcement checklist (PR-blocking)

A view is compliant only if **all** are true:
- [ ] Every `Text` uses a `Typography` role, by its **semantic role** (§1) — and its
      color is the role's `Palette` ramp token (no raw `.font(.system)` / opacity).
- [ ] Every color is a `Palette` token or an accent (no raw `Color(red:…)`, no
      `Color.white` / `Color.black`, no `.white`/`.black` — with or without `.opacity()`).
- [ ] Every `spacing:` / `.padding()` is a `Spacing` **or `Layout`** token (or `0`).
- [ ] Every `cornerRadius` is a `Radius` token; pills use `Capsule()`.
- [ ] Every SF Symbol size is an `IconSize` value.
- [ ] Every animation is a `Motion` spring.
- [ ] Every shadow is `shellShadow()` / `raisedShadow()`.
- [ ] Every `Button` uses `.island` / `.islandSubtle` / `.islandFlat` by its **role**
      (§8); no system styles, no new `ButtonStyle` types.
- [ ] Every control meets the **hit-target / size** standards (`Layout` metrics, §8).
- [ ] Repeated elements reuse their **shared component** (`IconButton`, `MusicPlayerColumn`)
      — no inline copies that can drift (§8).
- [ ] Every **position/inset** is a `Spacing` / `Layout` token; the card's own
      width/height is in `IslandConfiguration` (no 3-digit `.frame` literals in views).
- [ ] The view **fills the standard height** — no top-aligned void (§9.1).
- [ ] The container uses the **right surface recipe** for its role (§10).

### What the linter enforces vs. what review enforces
`./Scripts/design-lint.sh` deterministically catches the **greppable** rules: tokens for
type/color/spacing/radius/motion/shadow/icon (including bare `.white`/`.black` and
`Color.white`/`Color.black`), allowed button styles, no new `ButtonStyle`, and no card-scale
geometry literals in views. The **structural** rules — shared components (§8), fill discipline
(§9.1), position-by-role (§9.2), and surface recipes (§10) — are review gates the grep can't see;
but because every position you need has a `Layout` token and the raw number is forbidden,
"use the token" already carries most of the weight. Drive the linter to **0** after any UI
change (or annotate a justified exception with `// design-lint:allow`).
