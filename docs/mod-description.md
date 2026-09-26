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
- **Parallel** — Offset an existing span or run sideways by a set distance to create a second track alongside it — a passing lane or a return leg. Choose the distance, the side, and whether it follows the picked span or the whole run.
- **Siding** — Drop a short parallel stretch beside a run and curve it back in at both ends — a pull-off or passing siding — in a single action. Set the offset and length (the wheel drives the length) and the side.

### Shape

- **Move** — Drag a waypoint to a new spot and re-seat it on the real ground there. A falloff can spread the move to neighbouring points *along the track*, so a whole stretch shifts smoothly instead of one point jumping. The tool card auto-hides while you drag so it's never in the way.
- **Smooth** — Ease the small kinks out of a stretch so a driven path stops feeling jumpy. Two modes: one nudges the existing points into line (keeping junctions and markers), the other rebuilds the stretch at an even spacing.
- **Straighten** — Remove wandering detail from a stretch while keeping genuine corners, by dropping only the points that sit within a tolerance of the straight line. Raise the tolerance to flatten a real bend too; junctions in the middle are preserved.
- **Divide** — Insert a chosen number of new, evenly-spaced waypoints along a span or run, giving you handles to work with where the track was too coarse.
- **Ground** — Re-seat the waypoints of a stretch onto the surface within a tolerance, fixing points that float above the terrain or sit buried. It's smart about placed ramps and bridge decks — a point that's already correctly on one is left alone rather than dragged down to the terrain below.

### Connect

- **Convert** — Rewrite the direction and priority of connections that already exist: make a stretch two-way, one-way, or flip it to a give-way (secondary) road — for a single point, a span, or a whole run.
- **Merge** — Fold two separately-recorded parallel lanes into one shared track — the two directions of a road, or a lane you recorded twice. A clear three-click workflow: mark the length on one track, click the far end on the same track, then point at the other track running alongside; the part that will be absorbed turns green before it happens. Merge distance and divergence keep it honest.

### Utility

- **Name** — Attach a label to a waypoint so it becomes a named destination/marker on the map, exactly the way AutoDrive targets are named.
- **Delete** — Remove a single point, a picked span, or a whole run between junctions, depending on the scope — and it's undoable.

## Select mode & context menus

Select mode is where you inspect and act on what's already there. Click the network and a context menu opens for whatever you clicked — and the same click can escalate from a single **point** to a **span** to a whole **run** between junctions, so you rarely have to switch tools to make an edit. Menus offer name, move, connect/spline from here, one/two-way, primary/secondary, straighten, smooth, divide, ground, parallel, flip direction and delete — arming the right tool on your selection so you dial its setting and right-click to apply.

## Working with it

- **Floating tool card.** A tool's controls appear on a small card near the cursor instead of a far corner. Numeric settings can be **typed, scrolled, or nudged with − / + steppers**, and the wheel adjusts whichever field you're hovering.
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
