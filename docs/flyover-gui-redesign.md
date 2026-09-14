# Flyover editor GUI — redesign spec

Agreed design for a better‑looking, more functional editor GUI, worked out in a design dialog on
2026-09-14. **Status: design agreed, not yet built.** Nothing here is implemented; this is the brief
the build works from.

Interactive mockup used to settle it (a flat stand‑in, not the real in‑game panel):
<https://claude.ai/code/artifact/b38722a9-ba8d-4a05-9228-1114cf3d8723>

## Starting point

The current panel (`scripts/editor/FlyoverHud.lua`) is a single dark, near‑opaque text panel drawn
by hand from the game's overlay primitives, docked bottom‑left. It is information‑dense but reads
like a terminal readout: flat wrong colours, no visible button regions, a chincy text highlight, a
status line that does not stand out, a bulky footprint, and no answer for low‑res scaling. It works;
it does not look or feel like an editor. This redesign keeps what is good (map‑avoidance, the
per‑tool context, the NEXT hint) and rebuilds the rest.

## Feel

- **FS25‑native**, greyer neutral palette — it should read as part of the game, closest to the
  standard settings screens.
- **Blue** = selection / active. **Red** = destructive. **No amber / no brand accent** beyond that.
- **Rich but not busy.** Hierarchy pulls the eye, in order, to: the edit state, the active tool, and
  the NEXT instruction. Everything else is quieter.
- Condensed labels over a regular body face (the mockup used Barlow Semi Condensed + Barlow as a
  stand‑in; final faces TBD against what FS25 ships).

## Panel — the in‑world editor window

- **Floating, draggable, user‑scalable**, and it **remembers its position and scale** between
  sessions.
- **Compact** — noticeably smaller than the mockup, which ran too big. Real sizing is tuned in game.
- Keeps clear of the game's HUD map — carry over the current `mapFloorFor` behaviour.
- **Mode cue, no badge.** The panel being on screen *is* the "you are editing" signal. Instead of a
  loud EDIT MODE badge (redundant when the panel only exists in edit mode), show a quiet
  "Standard AutoDrive editing is suspended" note, an **"Esc to exit"** hint, and a **faint accent
  ring at the screen edge** — the ring is the ambient cue for when your eyes are on the map, not the
  panel.
- **Build:** a restyled **hand‑drawn overlay**, not the FS25 GUI framework. It is what already works
  over the flyover top‑down camera and the custom input context; it gives full control over
  placement and scaling. (The config screen below *does* use the real GUI framework — different job,
  different tool.)

## Toolbar & tools

- **Icon + label** buttons in clearly defined regions — labelled buttons beat icon‑only for
  discoverability, and defined regions are the fix for "I hunt for the right tool."
- A leading **Select** mode (an arrow), so "no editing tool" is an explicit, discoverable state
  rather than a hidden one.
- **Four groups:**
  - **Create** — draw, spline, field loop, parallel, siding
  - **Shape** — move, smooth, straighten, divide
  - **Connect** — convert, merge
  - **Utility** — name, delete
  - (parallel/siding sit in Create because they also make new track.)
- Number‑key shortcuts on the first ten tools, as today.
- **Icons are a deferred effort** — the mockup's glyphs are stand‑ins. Real ones are either custom
  DDS (via `tools/…`) or base‑game UI icons where they fit.

## Selection & gestures (Select mode)

- **Single‑click** a point → its context menu.
- **Click a second point** → the span (the path between the two points) → span menu.
- **Double‑click** a point → the **whole run** it belongs to → run menu.
- **Tool wins:** when an editing tool is active, left‑click performs the tool — no context menus in
  the way. Context menus are a Select‑mode behaviour.
- **Right‑click = cancel / deselect**, everywhere — backs out of a selection or a tool action.

Judge this model **in game**, not in the flat mockup — spacing and feel don't carry across.

## Context menus

- **Point:** Name this point… · Priority (primary/secondary) · Direction of its links
  (two‑way/one‑way/reverse) · Start a connection from here · Move · Delete point
- **Span:** Straighten · Smooth · Divide (add evenly spaced points) · Parallel track… · Convert
  direction · Delete span
- **Whole run:** everything in Span, plus Reverse direction · Delete run

## Inputs

- Every numeric field: **−/value/+ steppers**, **click‑to‑type**, and **Tab** between fields.
- The **mouse wheel is bound only to each tool's one key field** — the field that carries the wheel
  icon ("wheel only on key adjustment"), matching how the editor already drives one value per tool.
- **No sliders.** Considered and dropped as too busy for a small panel.

## Settings / config

- A **real FS25 settings page** (game GUI, like AutoDrive's own settings pages) — native, and it
  handles scaling and focus for free.
- Holds **only rarely‑changed things**: default merge distance, theme/colours, keybindings.
  Everything else stays live in the panel.
- Persisted through the **companion mod's own settings** (`scripts/Settings.lua`) — never written
  into `AutoDrive_config.xml`, which is the rule that keeps a stock client's settings sync intact.

## Help

- **No hover tooltips.** A **toggle‑able help overlay** (e.g. `?`) reveals all tool and control
  labels with their keys at once, then hides again — so the panel stays clean but the help is one
  keypress away.

## Deferred / to settle during the build

- Real icon design.
- Exact compact sizing of the panel.
- The full keymap (Select, help overlay, undo/redo, per‑tool keys, Esc).
- Validating the selection model live, at real scale, over the camera.
