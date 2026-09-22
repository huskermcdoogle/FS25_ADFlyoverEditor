# Changelog

## 1.0.1.1 — Hotfix: field loop ignored ground plowed together into one field (2026-09-22)

Field loop only ever found a *map* field's static boundary — by asking `g_farmlandManager` which
farmland owns the cursor's position, then reading that farmland's field. Plowing the gap between
two separate map fields to work them as one — a common [Courseplay](https://github.com/Courseplay/Courseplay_FS25)
workflow — was invisible to that lookup: it was still answering "what map field owns this spot",
which doesn't change just because the ground between two of them got tilled.

Field loop now tries two Courseplay-only lookups first, when Courseplay is active, both confirmed
against Courseplay's own source rather than guessed:

- A boundary explicitly saved with Courseplay's custom-field recorder, if one exists at the site —
  cheap and exact, but the rarer case.
- Courseplay's own field-boundary scanner (`g_fieldScanner`), which traces the actual tilled-ground
  edge from the cursor position instead of a static boundary, so a plowed-together gap is just part
  of the contour. It needs no vehicle and runs synchronously, same as everything else on the card.

Falls back to the map-field lookup if neither finds anything, or Courseplay isn't installed. A new
**detect custom field** toggle on the tool card (on by default) switches back to map-field-only for
isolating a report.

Also new: an **avoid obstacles** toggle on the same card (on by default) that skips the
tree/pole/fence/building detour entirely, for a field where the obstacle check keeps flagging
something that isn't really in the way.

## 1.0.1.0 — Move tool redesign: picks, copy, disconnect, offset, rotate, auto-hookup (2026-09-21)

Fully tested in-game across several rounds on the `move-tool` branch, with real bugs found and
fixed along the way - this is not a first-pass drop.

The move tool now has three ways to pick what a drag grabs - **Point** (a single waypoint,
optionally with a falloff taper along the track), **Run** (the whole run between junctions, one
click), and **Span** (two clicks marking the ends, click near either one again to replace it,
including shrinking it back by clicking a point already inside it) - plus a shared multi-point/
region selection any of them defer to: **Alt+drag** a box (aligned to the current camera view, not
north), **Shift+drag** a circle, **Alt+Shift+drag** freehand, or hold **Space**, drag an edge, then
click once more to set the width for a rotated box. **Ctrl** is the one consistent "add to what I
already have" modifier on top of any of those, or alone for a single-point toggle. All of them work
in every tool, not just Move, and a built selection always wins over whatever "picks" mode is
active when you grab one of its members.

- **copy (hotkey B)** - leaves the originals in place and creates the drag as a new, disconnected
  piece instead. Can be turned on before, during, or even just after a drag - toggling it on right
  after releasing still converts that move into a copy, and toggling it on mid-drag (or having it
  on before you grab) freezes the real waypoint in place immediately, with a live green preview
  showing where the copy will actually land.
- **disconnect** - independent of copy now, not a sub-option of it. With copy off, it moves the
  set in place and severs its outside connections, no clone. With copy on, it clones then deletes
  the originals, same as the old "break" - a run relocated cleanly detached instead of stretching
  a connection across the map.
- **offset** (Run/Span only) - slides an existing run or span sideways IN PLACE, connections and
  all, rather than creating a new parallel track like Parallel does. Drag sets it live, releasing
  does NOT commit, wheel (from anywhere in the view, not just over the tool card) or a typed value
  fine-tunes it, right-click finishes it. An optional **offset falloff** tapers the slide toward
  either end of the chain instead of sliding it all rigidly, for blending into an existing junction
  without a hard kink.
- **rotate (hold R + wheel)** - rotate whatever is being dragged, live, around either the point you
  grabbed or the moved set's centroid ("rotate pivot" on the tool card, takes effect on the next
  grab).
- **auto-hookup** - optional, off by default; silently reconnects a dangling end left by a move,
  copy, or disconnect to whatever it lands near, within its own distance/divergence tolerance
  (separate settings from Merge's own, tighter by default since this fires with no confirmation
  step, and now dialable up to 20m instead of capping at 5m). Matches both the connection TYPE
  (one-way stays one-way, two-way stays two-way) and DIRECTION of the track it is extending, and
  now also reconnects a fork left with two or more surviving connections - not just a single dead
  end - as long as every one of them still points the same way.

Also new: a **DEBUG** section on the settings dialog with a verbose-logging toggle, off by
default. A user reported log.txt bloating badly over hours of normal editing - the mouse-click
trace and most other routine info-level lines are now gated behind it; warnings and errors always
log regardless.

## 0.31.0.2 — Hotfix: the mouse wheel freeze this line had already fixed once (2026-09-20)

Ports forward one fix that predates the junction-placement work and was never part of this
0.31.0.x line: AutoDrive's `mouseWheelActive` flag could freeze true - most commonly from a
destination list left expanded when the editor opened - which silently blocked camera zoom in
both the editor and, after closing it, the vehicle too. The editor now collapses any expanded
AutoDrive pull-down list and clears the flag on both opening and closing, instead of only
clearing it once on close. Unrelated to 0.31.0.1's AutoDrive-version compatibility fixes - this
one affects every AutoDrive version.

## 0.31.0.1 — Hotfix: older AutoDrive compatibility, menu safety, field loop (2026-09-20)

A targeted patch on top of 0.31.0.0 for players on an older AutoDrive install. If you are already
on a current AutoDrive (3.0.0.8 or newer) this release only adds the field loop and launch-button
items below - the compatibility fixes are no-ops for you.

**Older AutoDrive compatibility (3.0.0.6 and earlier)**

- **Mouse wheel dead in the editor** — every wheel-driven control (spline curvature, siding length,
  parallel distance, divide count, and more) silently did nothing, because AutoDrive only wired its
  side of the hook (`GuiTopDownCamera.onZoom`) up from version 3.0.0.8 onward. The editor now hooks
  the camera directly, so it works whether or not the installed AutoDrive ever wired that up itself.
- **Random "proxy draw failed" errors, and a flooded log** — AutoDrive's own preview-drawing function
  had no protection against an empty spline preview before 3.0.0.8, which crashed almost every frame
  once the editor was open. The editor now guards that call itself, and a failure - from this or
  anything else - now genuinely stops retrying instead of repeating the same error hundreds of times
  per session.

**Safety**

- The editor could be opened on top of certain in-game menus (for example the AI job / map-overview
  screen used to assign a vehicle job), leaving both the menu and the editor fighting over the mouse
  and camera with no clean way back out short of the debug console. Opening now refuses cleanly
  while a menu has the screen, and the launch button beside AutoDrive's HUD hides itself in the same
  situation instead of sitting there as a dead click target.

**Field loop**

- Regained its own **priority** (primary/secondary) and **track** (clockwise / counter-clockwise /
  two-way) controls on the tool card, the way draw and convert already have theirs.
- Its obstacle check now also catches **telephone poles, fences, signs and small buildings** - it was
  checking only for trees, so a loop could route straight through a pole line.

**Launch button**

- Can now be **hidden**, or **repositioned** (left / right / above / below AutoDrive's HUD instead of
  the default auto-placement), from the settings dialog under **LAUNCH BUTTON**.

**Junction tool**

- Disconnected for this release - removed from the tool panel, and refused outright if anything else
  tries to select it. The auto-junction-placement work this line shipped with is still under active
  development on the main branch and is not part of this hotfix; it is unaffected under the hood and
  will return in a future release once that work is ready.

## 0.30.20.0 — Full German manual, and a feedback link (2026-09-17)

- **Full German manual** — the in-game manual and the contextual **?** help are now fully localized:
  with the game in German, every tool's **WHAT IT DOES / HOW TO USE IT / CONTROLS** and the **General
  reference** page read in German, completing the localization begun in 0.30.19.0 (which covered the UI
  chrome and the tool summaries). The German prose is stored unwrapped in the locale and wrapped to the
  page at render, so bullets, hanging indents and umlauts all break correctly; English stays the source
  of truth in `Help.lua` and is unchanged, and any untranslated string still falls back to English.
- **Feedback** — a [Discord](https://discord.gg/teU3mXEbH) invite in the README for bugs, ideas and
  questions.

## 0.30.19.0 — German localization, and a Move-wheel fix (2026-09-17)

**German (Deutsch) support**

- With the game set to German, the editor's interface now reads in German: the whole panel (tool
  names, section headers, buttons, toggles and their option values, the settings and the standalone
  settings dialog, the per-role colour editor, the status line and the under-cursor readout), the
  **Select context menu**, the **"NEXT" step guidance**, the help/manual **chrome** (titles, prev /
  next, "browse the full manual"), and **each tool's one-line summary**. The three editor keybinding
  names are localized in the controls menu too.
- The longer **WHAT / HOW / CONTROLS** help prose stays English for now.
- Under the hood: a small, self-contained locale layer (`scripts/editor/Locale.lua`) keyed by the
  English string, with English as the fallback — so any untranslated string simply shows English and an
  English game is unchanged. Adding another language is a one-file job.

**Move wheel direction**

- The mouse wheel now **widens** Move's falloff radius on wheel-up, matching its **+** stepper. A
  spatial reach reads the opposite way from the tolerances and counts the earlier wheel reversal
  suited, so Move keeps the original direction while every other tool stays reversed.

## 0.30.16.0 — Browsable manual, wheel direction, cleaner reading surfaces (2026-09-17)

Everything since 0.30.10.0's per-tool help: a browsable in-game manual, and a pass over the editor's
wheel behaviour and how its panels and modals read against the world.

**Browsable in-game manual**

- The full manual is now readable **in-game** — a paged modal (a General reference plus one page per
  tool), opened from the **browse the full manual** button on the help panel. Prev / next buttons, the
  arrow keys, and **Esc**/**X** move through and close it; long pages **scroll** with the wheel.

**Mouse wheel**

- **Direction reversed** across the editor — numeric fields, tool settings, the settings-dialog
  fields, and the manual's page scroll now all step the natural way. Spline curvature (its own wheel)
  and the **− / +** stepper buttons are unchanged.

**Panels and modals that read clean over the world**

- The manual and the settings dialog now draw over a **cleared screen**: the world network, its
  waypoint labels, the under-cursor field readout, and the editor cursor are all suppressed while a
  modal is open, instead of showing through it.
- AutoDrive's **map-marker names** no longer bleed through the tool panel, the floating card, or the
  help card, and the **minimap airplane** no longer pokes through them either.
- The contextual **help panel** is height-capped and **scrollable** (wheel over it) on long pages, so
  the "browse the full manual" button is always on screen and clickable; it resets to the top when you
  switch tools.
- Opening a modal **freezes the camera**, so sliding the mouse to a screen edge to click a button no
  longer edge-scrolls the map.

## 0.30.10.0 — Per-tool help & a user manual (2026-09-16)

- **In-game help** — a **?** button on the panel header (and the **/** key) toggles a contextual help
  panel beside the editor that shows the **selected tool's** full help — what it does, how to use it,
  and its controls — following the tool as you switch. Non-modal, so you can read it while working.
- **User manual** — a complete written manual at [`docs/manual.md`](docs/manual.md), one section per
  tool plus a General reference. It and the in-game help are generated from one source
  (`tools/make_help.py`), so they never disagree.
- **Tool numbers renumbered** — the keycaps now run **1→9, 0** straight down the Create and Shape
  groups in the panel's reading order instead of scattering by internal id. There are ten number keys
  and fourteen tools, so the Connect and Utility tools (convert, merge, name, delete) are click-only.

## 0.30.8.0 — Settings dialog, safer recovery, better card hiding (2026-09-16)

- **Standalone settings dialog** — a modal popup opened by the **⚙ gear** on the panel header (or a
  rebindable keybind). It carries the full settings surface: ui scale, theme, accent, a per-role
  colour editor (role picker, live swatch + hex, R/G/B), reset-all and close. It matches the panel —
  the theme's own colours, at the theme's scale.
- **Reset recovery** — a `FlyoverResetTheme` console command (always available) and a rebindable
  "reset editor colours and scale" key put the theme back to default, so a custom colour that makes
  the panel unreadable can never trap you.
- **Card hiding reworked** — middle-mouse no longer hides the tool card (it was fighting the camera's
  orbit). Instead the card **auto-hides while you drag a point**, plus an **`H` key** and a **panel
  button** toggle it (and now hide the armed span-tool popup too, consistently across tools).
- **Version in the panel** — the build number shows next to the FLYOVER EDITOR title, so a screenshot
  always says which build it is.

## 0.30.2.0 — Advanced per-role colour editor (2026-09-16)

Added the third theming layer: hand-tune individual colours on top of a preset + accent.

- **In-editor colour editor** — in the panel's **Settings**, toggle **advanced colours** to open a
  **COLOUR OVERRIDE** section.
  - **edit** — click / scroll / − + to pick which of 15 roles to tune (panel bg, body text, value
    text, borders, accent text, hover, danger, tool bg, stepper bg, …).
  - **swatch + hex** — a live colour chip and hex readout of the selected role (marked *custom* once
    overridden).
  - **R / G / B** — 0–255 per channel, by click / scroll / − + / type.
  - **clear this colour** — reverts just that role back to the preset + accent.
- Overrides **layer on top** of the preset and accent, apply live, and persist to `theme.xml`.
  Switching preset or accent keeps them; **reset to default** wipes them.
- Under the hood: the resolved palette is now kept in **sRGB as well as linear** (the editor works in
  sRGB / 0–255; rendering still hands `setColor` linear), with `srgb()` / `hexOf()` accessors and a
  curated `EDITABLE_ROLES` list.

## 0.30.1.0 — Themeable, scalable panel (2026-09-16)

Reworked the editor panel from a fixed grey look into a scalable, fully themeable one, with a new
high-contrast default.

- **Scalable UI** — a mod-specific size multiplier (**0.70×–2.00×**) on top of the game's UI scale,
  so the editor can be enlarged for a high-res display or easier reading without resizing the rest of
  the HUD.
- **Colour themes** — every colour the panel draws is now a named *role* resolved from a **preset +
  accent + optional overrides**:
  - **7 presets:** Contrast Dark, Amber, Cyan, Green, Slate + Blue, HC Light, Classic.
  - **7 accents:** amber, blue, cyan, green, red, purple, white.
- **New default:** **Contrast Dark + amber at 1.0×** — deliberately off the old low-contrast
  grey-on-grey-with-blue.
- **In-editor Settings** — open from the panel's **ACTIONS → settings**; adjust scale, theme and
  accent live (click / scroll / − + / type). Everything saves automatically to `theme.xml`.
- **Gamma fix** — colours are authored in sRGB (as in the design lab) and converted to **linear**
  before `setColor`, because FS25's overlays take linear light. Without this the display gamma lifted
  every dark value to grey — which is why the dark themes (and the original panel) looked washed out.
- Internally: the ~50 hardcoded colours in the HUD became role lookups; the mouse wheel now adjusts
  any numeric field under the cursor, including the settings fields.

---

*A design preview used to choose the default palette and scale lives at the
[theme lab](https://claude.ai/artifact/H3HuvqeRZ4cuWqCgAbYyaJ).*
