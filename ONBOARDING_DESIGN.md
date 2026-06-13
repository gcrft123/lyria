# Dynamic Island — Onboarding Design

**Status:** design only (not built). This is the spec for first-launch onboarding.

---

## 0. The one idea everything hangs on

**The island onboards you as itself.** There is no separate setup window, no wizard
chrome. On first launch the Dynamic Island *descends from the notch, wakes up, and
introduces itself in the first person.* Every feature is shown by the island actually
*doing* it; every permission is a "sense" the island asks to borrow, and the moment you
grant it the matching feature **lights up live with your real data.**

Why this is the right call for this app specifically:

- The product **is** a notch-resident object. A modal window would betray that. Onboarding
  in-situ teaches the exact spatial place and gestures the user will use forever.
- The app already has a complete **mock-data layer** (`DI_MOCK_MUSIC/CALENDAR/WEATHER/
  TIMERS/…`, `DI_FORCE_*`). The entire "trailer" can run with zero permissions, so the
  user sees the payoff **before** being asked to trust anything.
- The signature motion (morph, beat-glow ripple, side-island fan-out, favorite burst) is
  genuinely beautiful — onboarding is the one time we get to choreograph it on purpose.

**Voice:** the island speaks. First person, warm, confident, a little witty, never cute to
the point of annoying. "I live up here now." "Mind if I borrow your ears?" "There. Try me."

---

## 1. Principles

1. **Show, don't list.** No bullet-point feature tour. The island performs a 12-second
   trailer of itself.
2. **Earn each permission.** Never a permissions wall up front. Ask exactly when the value
   is on screen and greyed-out, so granting = instant gratification.
3. **Every grant is a payoff.** The feature animates to life with *the user's own* data the
   instant macOS returns from the system dialog.
4. **Always skippable, never punished.** Skip a permission → that feature sleeps, reachable
   later from Settings. Skip onboarding entirely → sensible defaults, re-runnable.
5. **Trust is a feature.** One honest beat: everything is local, nothing leaves the Mac.
   Said *before* the scary asks (Accessibility, Full Disk Access, audio).
6. **Respect the system.** Reduced-motion, VoiceOver, and "I'll do it later" are first-class.

---

## 2. The arc (seven acts)

A cinematic spine, ~60–90s if you watch every beat, ~20s if you rush. Each act is a state
in an `OnboardingCoordinator` (see §10). The island grows to a dedicated **onboarding card**
(a touch larger than the normal expanded card so copy + a live preview fit).

### Act 0 — Awakening (~3s, no interaction)
- The notch is empty. A single soft accent point of light appears dead-center under the
  notch and **breathes** once.
- The black pill **extrudes downward out of the notch** and settles — `Motion.morph`,
  the same birth it does every expand, but slowed and deliberate. A faint accent halo
  blooms (`shellShadow` + the accent glow already in `DynamicIslandView`).
- No text yet. Just: *something just woke up at the top of my screen.*

### Act 1 — Hello (~4s)
- The pill expands to the onboarding card. Centered: the app wordmark + a one-line
  greeting that shimmers in (a left-to-right highlight sweep).
  > **Dynamic Island**
  > "Hi. I live up here now — let me show you what I can do."
- Bottom-right: a quiet **Skip intro** link. Bottom-left: a tiny progress rail (dots per
  act). Primary affordance: **a single glowing chevron / "Begin" pill.**

### Act 2 — The Trailer (~12s, auto-plays, runs on MOCK DATA)
The island morphs through its repertoire as live vignettes — content swaps with
`Motion.contentMorph`, the shell barely resizes so it reads as *one object changing its
mind.* Each vignette is ~2s and uses the existing mock providers, so **no permission is
needed to watch it.**

| Beat | What plays | Signature flourish |
|------|-----------|--------------------|
| Music | mock "Dreams — Fleetwood Mac" with the scrubber moving | the **beat-glow ripple** sheds from the edges (synthetic tempo) |
| Timers | a 00:05 countdown ticks down and **fires** | the ring flashes red (`RingingGlowOverlay`), then a side-island timer chip slides out |
| Calendar | "Design Review · in 14 min" as the compact live-activity, ring depleting | side-island fan-out |
| Weather | the animated sky + big temp resolves over a mock city | ambient `Motion.gentle` settle |
| Dashboard | the music-mirror layout assembles row by row | the whole card "inhales" |
| Tweaks (cameo) | EQ sliders nudge themselves, the pan dot glides L→R | accent sweep |

Ends on the **Dashboard "home"** held for a beat — *"That's home. Here's what I'll need to
make it real."* A **Continue** pill advances; the trailer loops if untouched.

### Act 3 — Borrowing senses (permissions, choreographed)
The heart of the experience. First, **one trust beat** (full card, ~3s, dismissible):
> "Here's the deal: everything I do stays on your Mac. No account, no cloud, nothing
> phones home. I just need to borrow a few of your Mac's senses."

Then permissions are presented **one card at a time**, ordered low-friction → high-value →
advanced. Each card is a **split**: left = a *greyed, dormant* live preview of the feature;
right = the ask + a **Grant** button + a **Maybe later** link.

The magic: tapping **Grant** triggers the real macOS dialog (or deep-links to System
Settings for the panel-only ones). The coordinator **polls the existing permission checks**
(the app already does this for hover/audio/calendar). When the grant lands — even after the
user tabs to System Settings and back — the **dormant preview ignites**: it animates from
desaturated → full color + motion, with the user's *real* data, and a `Motion.pop`
celebration. A soft single chime (optional, off under Do-Not-Disturb).

See §3 for the full permission choreography.

### Act 4 — Make it yours (~10s, personalization, live)
Four quick choices, each with the island previewing the change in real time:

1. **Accent** — "Tint me with your album art, or keep me neutral?" → toggles
   `tintWithArtwork`; the glow recolors live to the currently-playing artwork.
2. **How I open** — Hover / Click / Scroll (the real `expandTrigger` setting). The card
   demonstrates the chosen gesture immediately ("like this →").
3. **Your apps** — a row of app glyphs (Music, Timers, Calendar, Weather, Tweaks); toggle
   which ride in the sidebar. They slide in/out of a mini sidebar preview.
4. **Glow** — a single slider; the halo + beat ripple scale live as you drag.

### Act 5 — Try me (~15s, hands-on, the only "tutorial")
Coach-marked, interactive. The island waits for the *real* gesture and reacts:
- "**Open me.**" (Hover / Click / Scroll — matched to their Act-4 choice.) ✓ when done.
- "**Scroll to flip through your apps.**" The sidebar highlight moves as they scroll. ✓
- "**Want me to stay? Grab the pin.**" Reveals the corner thumbtack; pinning it ✓ and shows
  the ✕. Unpins to continue.
- "**Press ⌥Tab** to fan out every open window." Fires the window switcher overlay once. ✓
- (If they granted audio) "**Play something.**" The beat glow reacts to their actual audio —
  the single most "whoa" moment; hold on it.

A live checklist ticks off. Any step is **Skippable**; nothing blocks.

### Act 6 — You're set (~4s, finale)
The signature flourish, fully choreographed:
- The glow swells to full, the side islands **fan all the way out and tuck back** in
  sequence, a **favorite-burst** of particles pops from center, the beat ripple does one
  big shed.
- Card collapses through `Motion.morph` down to the resting **compact pill**, settling with
  its lively overshoot.
- Final line lingers for a second under the pill, then fades:
  > "I'll be right here. Find me anytime — and the gear's where you change all this."
  (A one-time arrow points at the sidebar gear / how to reach Settings.)
- Onboarding-complete flag is set. Never auto-runs again.

---

## 3. Permission choreography

Presented in this order (skip any; the feature simply sleeps). Each "lights up" preview
reuses existing live data paths.

| # | Permission | Feature it ignites | Island copy | If declined |
|---|-----------|--------------------|-------------|-------------|
| 1 | **Accessibility** | ⌥Tab window switcher + global hot-keys | "Let me see your windows so ⌥Tab can fan them all out." | switcher dormant; re-enable in Settings |
| 2 | **Automation → Music** (Apple Events) | live now-playing mirror + transport | "Mind if I peek at Apple Music? I'll mirror what's playing and let you skip from up here." | Music tile shows "Nothing playing"; works when granted later |
| 3 | **Audio capture** (system tap) | beat-reactive glow + per-app Tweaks (EQ/vol/pan) | "Borrow your ears? I'll pulse to the beat — and let you EQ any app." | glow uses synthetic tempo; Tweaks audio off |
| 4 | **Calendar** | upcoming events + the in-N-min live activity | "Show me your calendar and I'll surface what's next, right on the notch." | Calendar tile empty |
| 5 | **Location** | local weather (sky + temp) | "Where are you? Just for local weather — nothing else." | Weather asks for a manual city or sleeps |
| 6 | **Full Disk Access** *(advanced, opt-in)* | notification mirroring + DND swap | "Advanced: I can replace system banners with my own. This one needs Full Disk Access." | system banners stay; clearly marked optional |
| 7 | **Bluetooth** *(low-key)* | device connect/disconnect banners | "I'll wave when your AirPods connect." | no BT banners |

**System-dialog handling (critical):** several of these (Accessibility, Full Disk Access)
only open a System Settings *pane*, not an in-app prompt. The card switches to a **"waiting"
state** ("I opened Settings for you — flip the switch and come right back ↩") and the
coordinator watches for the grant so the ignite-animation fires **the instant they return**.
This "leave, toggle, come back, watch it bloom" loop is the emotional core — design it to
feel rewarding, not like homework.

**Grouping option (decide):** offer a "**Grant the recommended set**" fast-path on the trust
card for power users, which walks them sequentially, vs. the one-at-a-time storytelling.
Recommend defaulting to one-at-a-time, with "skip to the end" always available.

---

## 4. Motion & visual language (reuse the design system)

Everything maps to existing `Motion`/`Transitions` tokens — onboarding invents **no** new
primitives, it just *sequences* them:

- Island birth / collapse / card resize → `Motion.morph`.
- Vignette + card content swaps → `Motion.contentMorph` (+ the standard content transition).
- Side-island fan-out → `Motion.side`.
- Permission "ignite" + finale particle burst → `Motion.pop` (+ the favorite-burst effect).
- Ambient settles (weather, glow scaling) → `Motion.gentle`.
- Coach-mark callouts / "waiting for Settings" cards → `Motion.popup` + `Transitions.popup`.
- Beat ripple → the real `AudioRhythmMonitor` / `BeatGlowOverlay` (synthetic tempo until
  audio is granted).
- All color/spacing/type from `Palette` / `Spacing` / `Layout` / `Typography`. A new
  `Layout.onboardingCard*` size + the copy type roles (greeting = `title`, body =
  `bodyRegular`, captions/hints = `footnote`/`textTertiary`). **0 design-lint violations.**

**Dormant vs. ignited preview:** dormant = grayscale + `textFaint` + still; ignited =
full accent + live motion. The transition between them is the signature "lighting up."

---

## 5. Pacing

| Act | Watch-all | Rushed |
|-----|-----------|--------|
| 0 Awakening | 3s | 3s (unskippable, it's short & gorgeous) |
| 1 Hello | 4s | instant (Begin) |
| 2 Trailer | 12s | skippable after 1 loop |
| 3 Permissions | ~25s | as many as they grant; Skip-all available |
| 4 Personalize | 10s | accept defaults |
| 5 Try me | 15s | Skip |
| 6 Finale | 4s | 4s |

Target: a delighted user spends ~90s; an impatient one is done in ~15s with good defaults.

---

## 6. Copy deck (first draft — island voice)

- Awake → (no copy)
- Hello → "Hi. I live up here now — let me show you what I can do."
- Trailer end → "That's home. Here's what I'll need to make it real."
- Trust → "Everything I do stays on your Mac. No account, no cloud. I just need to borrow a
  few senses."
- Waiting on Settings → "Opened Settings for you — flip the switch, then come back ↩"
- Ignite (generic) → "There it is. ✨"
- Personalize intro → "Now make me yours."
- Try-me intro → "Your turn. Try me out."
- Finale → "I'll be right here. The gear's where you change all this."

*(All strings centralized for localization from day one.)*

---

## 7. Accessibility & inclusivity

- **Reduced Motion** (`NSWorkspace.accessibilityDisplayShouldReduceMotion`): replace morphs/
  particles with cross-fades; the trailer becomes a slow stepped slideshow; no auto-advance.
- **VoiceOver:** each act is an accessibility element with a label = the island's line;
  permissions are real buttons with hints; the trailer is announced, not silently animated.
- **Reduce Transparency / Increase Contrast:** dial the glow down, solidify the card.
- **Keyboard-only:** full Tab/Return path through every act; ⌥Tab demo has a visible
  fallback button.
- **No audio required:** chimes are optional and suppressed under DND; nothing depends on
  sound.
- **Color-blind:** never use color alone to signal dormant/ignited — also use motion +
  the lock/check glyphs.

---

## 8. Edge cases & lifecycle

- **Re-run:** Settings → General → "Replay intro." Also a hidden `DI_FORCE_ONBOARDING=1`
  for dev/screenshots (consistent with existing `DI_FORCE_*`).
- **Partial grants:** onboarding completes regardless; dormant features show a subtle "asleep"
  hint in their tile with a one-tap enable.
- **Denied a permission:** no nagging. The tile stays dormant; Settings has the re-ask.
- **Multi-display / no notch:** the island already prefers the notched screen and falls back
  to top-center; onboarding follows the same anchor. On a non-notch Mac, Act 0 grows from the
  top edge instead of "out of the notch."
- **Quit mid-onboarding:** resume at the last completed act next launch (persist the act
  index), or offer "start over."
- **Update onboarding:** when a *new* feature ships, a tiny one-card "what's new" mini-intro
  (same engine, single act) — not the full sequence.
- **Permission revoked later:** if the OS revokes (e.g. after an update), the feature tile
  goes dormant and offers re-grant; no forced re-onboarding.

---

## 9. What makes it "epic" (the share-worthy moments)

1. The island **being born out of the notch** and *talking to you* — nobody expects the
   chrome itself to be the guide.
2. **Watching weather resolve to your actual city** / your real song appear the second you
   grant — permissions become dopamine, not friction.
3. The **"play something" beat** where the glow pulses to whatever you put on.
4. The **finale flourish** — the side islands fanning out and the burst — begs to be
   screen-recorded.

---

## 10. Technical architecture (sketch only — not built)

High-level shape so the design is buildable without surprises:

- **`OnboardingCoordinator`** (`ObservableObject`): owns `phase: OnboardingPhase`
  (`.awakening, .hello, .trailer(beat), .permission(kind, state), .personalize, .tryMe(step),
  .finale, .done`), advance/skip/back, and persists `onboardingCompleted` + last act in
  `AppSettings`/UserDefaults.
- **New `IslandMode.onboarding(phase)`** (or a parallel overlay the controller yields to,
  above apps but below HUD), so the existing geometry/morph pipeline drives the card. The
  coordinator feeds the controller mock data via the **existing `DI_MOCK_*` providers** for
  the trailer — no new fake-data system needed.
- **`OnboardingView`** + per-act subviews, composed from existing components (the compact/
  expanded app views are literally what the trailer shows). Token-compliant.
- **Permission layer:** a small `PermissionService` wrapping the checks the app already does
  (Accessibility, Apple Events, audio tap, EventKit, CoreLocation, FDA, Bluetooth), exposing
  `status(for:)` + `request(for:)` + a poll so "granted while away" is detected on return /
  `applicationDidBecomeActive`.
- **Interaction (Act 5):** reuse the real hover/scroll/pin/switcher paths in a "guided" mode
  where the coordinator listens for the genuine gesture and checks it off.
- **Reduced-motion / a11y branches** decided in the view from system flags.

No code yet — this section is just to prove the chosen experience fits the existing engine
(it does: morph, mock providers, permission checks, and side-islands are all already here).

---

## 11. Open decisions (for you)

1. **Length default:** auto-play the full ~90s arc, or open on a compact "Begin / Skip"
   and let them opt into depth? (Recommend: short Awakening+Hello auto, everything after is
   user-paced.)
2. **Permissions:** one-at-a-time storytelling (recommended) vs. a "grant recommended set"
   fast-path — or offer both?
3. **Sound:** subtle chimes on ignite + finale (DND-aware), or fully silent?
4. **Scope of v1:** ship Acts 0–3 + finale first (awaken, trailer, permissions, set), and
   add Personalize + Try-me (4–5) in a fast follow? Or all seven at once?
5. **Tone:** how chatty should the island be — the witty first-person voice here, or more
   restrained/Apple-neutral?

---

## 12. Implemented — dev notes

Built under `Sources/DynamicIsland/Onboarding/`:
`OnboardingCoordinator` (autoplay state machine), `OnboardingView` + `OnboardingActs`/`Acts2`
(the seven acts), `PermissionService` (real status reads + System Settings deep-links +
grant polling), `OnboardingAudio` (synthesized ambient pad + chimes, no asset files),
`OnboardingWindowController`/`OnboardingPanel` (the takeover). First-launch gated on
`AppSettings.onboardingCompleted`; "Replay the intro" lives in Settings → General.

Decisions applied: **autoplay** (Awakening→Hello→Trailer auto-advance; permissions /
personalize / try-me are user-paced), **one-at-a-time** permissions with ignite-on-grant,
**synthesized chimes + ambient pad**, **all seven acts**, **restrained** copy.

Env hooks:
- `DI_FORCE_ONBOARDING=1` — run the real fullscreen takeover regardless of the flag.
- `DI_ONBOARD_PREVIEW=1` — render in a small, lower-left, **non-focus-stealing** window
  (for inspection without taking over the screen).
- `DI_ONBOARD_PHASE=hello|trailer|permissions|personalize|tryMe|finale` — jump to and HOLD
  on one act (autoplay + permission polling suppressed). `DI_ONBOARD_BEAT=0…4` picks the
  trailer vignette.
- `DI_DISABLE_ONBOARDING_AUDIO=1` — silence the pad/chimes.

Known v1 simplifications (vs. the full design above): the trailer vignettes are compact
self-contained minis (not the live app views driven by mock providers); permission "ignite"
auto-detects Accessibility/Calendar/Location/Bluetooth and self-confirms Music/Audio/Full
Disk (no clean read API); try-me is a guided checklist (acknowledge each step) rather than
live gesture capture; personalize covers the three real settings (tint, expand trigger,
glow). All are straightforward to deepen later.
