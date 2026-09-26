# Flyover Editor for AutoDrive

**Build and repair your AutoDrive route network from above — on foot or in a vehicle, without driving every metre of it.**

Flyover Editor is a top-down editor for [AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive) route networks in Farming Simulator 25. Instead of hopping in a vehicle and recording track a metre at a time, you lift off into a free-flying overhead camera and edit the whole network like a map: place waypoints with a click, curve connections, offset parallel lanes, straighten and smooth existing runs, drop points back onto the ground, and clean up the tangle that every long-running save eventually collects — all from a clear, clickable panel.

It runs as a **companion mod** beside *stock* AutoDrive. It does **not** modify AutoDrive's files or your savegame's config; it attaches to AutoDrive at runtime and politely refuses to load (and tells you why) if AutoDrive isn't installed. Everything you build goes through AutoDrive's own network API, so a route laid in the flyover editor is identical to one recorded from a vehicle.

## Why you'll want it

- **See the whole picture.** A top-down camera over your farm means you plan routes looking at the actual field layout, junctions and yards — not the back of a tractor.
- **Fix, don't re-record.** Straighten a wobbly headland pass, smooth a jittery lane, re-seat floating waypoints, or delete a dead-end — in seconds, without re-driving anything.
- **A real interface, not a wall of hotkeys.** A dockable panel lists every tool with the active one highlighted, exposes options as persistent toggles, and shows a live "next step" hint for whatever you're doing.
- **Undo everything.** Every edit is undoable (Q) and redoable (E). Experiment freely.

## Opening it

- **Left Alt + F** (rebindable in the controls menu), or the button beside AutoDrive's HUD.
- **Esc** to leave.
- **1–9 and 0** select tools; **Q** undo, **E** redo; **H** hides/shows the floating tool card; **,** and **.** nudge the Move falloff.

## The tools

Tools are grouped by job on the panel. **Select** is the default mode — no tool held, click things to edit them.

### Create

- **Draw** — Place waypoints one click at a time, joining each to the last so a route grows as you go. Click empty ground to drop a point; click an existing waypoint to draw *from* it and wire straight into the network; right-click ends the run. Options: one-way / two-way, primary / secondary (give-way), and whether new points snap to the terrain or any surface.
- **Spline** — Connect two waypoints with a smooth curve instead of a straight segment, for sweeping bends a vehicle can take at speed. A live preview shows the curve before you commit; the wheel tightens or loosens the curvature, and endpoint/tangent controls flip which way the curve arrives.
- **Field loop** — Generate a complete, drivable two-way loop just outside a field's boundary, smoothed to a turning radius and nudged around any obstacles in the way (trees, poles, fences, buildings). It's a standalone loop — no map markers, not wired to the rest of the network — so you connect it in afterwards. Controls: margin, turning radius, obstacle clearance and vehicle height.
- **Parallel** — Copy an existing span or run sideways by a set distance as a second track alongside it — a passing lane or a return leg. Pick the span or run, set the distance and side, and choose whether a track beside a one-way road runs the same way or opposite as a return lane.
- **Siding** — Drop a short parallel stretch beside a run and curve it back in at both ends — a pull-off or passing siding — in a single action. Set the offset and length (the wheel drives the length) and the side.

### Shape

- **Move** — Drag a point, a span, a run or a whole selection to a new spot and re-seat it on the real ground. Click to pick, drag to move; falloff tapers the move along the track so a stretch bends smoothly instead of one point jumping. Copy drags out a new piece and leaves the original, disconnect cuts it loose, offset slides a run sideways in place, R+wheel rotates while you drag, and auto-hookup reconnects loose ends where you drop them.
- **Smooth** — Ease the small kinks out of a stretch so a driven path stops feeling jumpy. Two modes: one nudges the existing points into line (keeping junctions and markers), the other rebuilds the stretch at an even spacing.
- **Straighten** — Remove wandering detail from a stretch while keeping genuine corners, by dropping only the points that sit within a tolerance of the straight line. Raise the tolerance to flatten a real bend too; junctions in the middle are preserved.
- **Divide** — Insert a chosen number of new, evenly-spaced waypoints along a span or run, giving you handles to work with where the track was too coarse.
- **Ground** — Re-seat the waypoints of a stretch onto the surface within a tolerance, fixing points that float above the terrain or sit buried. It's smart about placed ramps and bridge decks — a point that's already correctly on one is left alone rather than dragged down to the terrain below.

### Connect

- **Convert** — Rewrite existing connections: set the direction (two-way, one-way, other way, or AutoDrive's reverse-way) and the priority (primary or give-way secondary) and one click applies both — to a single point or a whole run.
- **Merge** — Fold two separately-recorded parallel lanes into one shared track — the two directions of a road, or a lane you recorded twice. Pick the stretch on one track, then click the other track (or right-click when it's the only one); the part that will be absorbed turns green first. Merge distance and divergence keep it honest.

### Utility

- **Name** — Attach a label to a waypoint so it becomes a named destination/marker on the map, exactly the way AutoDrive targets are named.
- **Delete** — Remove a single point, a whole run between junctions, or everything you've selected — and it's undoable.

## Select mode & context menus

Select mode is where you act on what's already there. Click a point for its popup, click a second point for the **span** between them, or double-click for the whole **run** between junctions — or box, circle, freehand or Ctrl-click a **selection** and get a popup for the whole set. Popups open clear of what they act on and can be dragged aside; picking a tool from one opens that tool's card right there, and every stretch tool picks the same way (click, second click, double-click).

## Working with it

- **Tool cards.** Each tool's options on one card: toggles, side-by-side choices, and numbers you can **type, scroll, or nudge with − / + steppers**. Anything that can't apply right now is greyed out. The card stays where you put it (or pin it), steps aside when it would cover your work, and **Esc** backs out one step at a time.
- **Everywhere-undo.** Q / E, plus a live count on the panel.
- **Field readout.** The panel tells you which field/farmland the cursor is over — handy in flyover mode where there's no vehicle to tell you.

## Make it yours: scaling, themes & colours

Poor eyesight or a high-res display? The editor scales independently of the rest of the HUD:

- **UI scale** from 0.70× to 2.00×.
- **7 colour presets** (Contrast Dark, Amber, Cyan, Green, Slate + Blue, HC Light, Classic) and **7 accents** (amber, blue, cyan, green, red, purple, white), defaulting to a deliberately high-contrast dark theme.
- **Per-role colour editor** — hand-tune any of 15 interface roles (panel, cards, borders, body/value/muted text, hover, danger…) with a live swatch, hex readout and R/G/B controls.
- Everything applies **live and saves automatically**. Open it from the **gear** on the panel header or the in-panel Settings; a console command (`FlyoverResetTheme`) and a rebindable key reset colours and scale to default if a custom choice ever makes the panel hard to read.

## Built-in help

You're never lost. A **?** button (and the **/** key) shows contextual help for the current tool — what it does, how to use it, and its controls — that follows the tool as you switch. From there, open the **full browsable in-game manual**: a page per tool plus a General reference covering keys, mouse, camera and settings.

## Languages

Fully localized in **English and Deutsch** — the panel, menus, on-screen guidance, help and the complete manual all follow your game language. Adding more languages is straightforward.

## Compatibility & safety

- Reads and writes AutoDrive's network **only through AutoDrive's own API** — no changes to AutoDrive's files.
- Its settings live under `modSettings/` and never touch AutoDrive's config or your savegame.
- **Single player only.**
- **Requires `FS25_AutoDrive`.** Don't run it next to a modified AutoDrive build that already bundles its own flyover editor — whichever loads last wins.

## Install

Download `FS25_ADFlyoverEditor.zip`, drop it in your FS25 `mods` folder, and enable it alongside `FS25_AutoDrive`.

**Feedback, bugs and ideas:** join the [Discord](https://discord.gg/w6mvhuaa9k). Free and open source (MIT). By huskermcdoogle. Built to run against stock AutoDrive; not affiliated with or endorsed by the AutoDrive team.
