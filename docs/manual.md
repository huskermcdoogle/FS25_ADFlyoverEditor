# Flyover Editor — user manual

A top-down editor for AutoDrive route networks. This manual describes every tool and the controls that work everywhere. It is generated from the same source as the in-game help (`tools/make_help.py`), so the two always agree.

## Contents

- [General](#general)
- **Mode** — [Select](#select)
- **Create** — [Draw](#draw), [Spline](#spline), [Field loop](#field-loop), [Parallel](#parallel), [Siding](#siding)
- **Shape** — [Move](#move), [Smooth](#smooth), [Straighten](#straighten), [Divide](#divide), [Ground](#ground)
- **Connect** — [Convert](#convert), [Merge](#merge)
- **Utility** — [Name](#name), [Delete](#delete)

## General

Opening, leaving, and the keys and controls that work everywhere.

### Opening & leaving

- Open the editor with Left Alt + F (rebindable in the controls menu), or the button beside AutoDrive's HUD.
- Press Esc to leave. Every edit is undoable.
- Single player only. Edits are written when you are the host.

### Keys

- 1-9, 0 - select a tool (the number shown on each tool button).
- Q - undo,  E - redo.
- H - hide / show the floating tool card (it also auto-hides while you drag).
- , and . - move tool falloff radius down / up.
- B - toggle the move tool's copy setting (Move tool only).
- R (held) + wheel - rotate whatever is being dragged (Move tool only, mid-drag).
- Esc - leave the editor (or close a dialog / cancel an edit).

### Mouse & camera

- Left-click - place / select / operate, depending on the tool.
- Right-click - end a run, cancel a menu, or apply an armed tool.
- Middle-mouse - orbit / spin the camera. WASD moves it.
- Wheel - camera zoom, or adjust the numeric field the cursor is over.
- Ctrl - the universal "add to selection" modifier: held on top of any shape below, or alone (plain Ctrl-click) to toggle a single point. Works in every tool.
- Alt+drag - box-select (aligned to the current camera view, not north).
- Shift+drag - circle-select; the two dragged points are a diameter, not a centre and radius.
- Alt+Shift+drag - freehand-select; trace a shape and release to close it.
- Space+drag+click - rotated box-select: hold Space, press-drag-release sets one edge (Space only needs to be held at the press), then one more plain click sets the width and finishes.

### The tool card

- The floating card carries the active tool's settings. It jumps out BESIDE the first click of each action - offset, never on top of what you clicked.
- Drag it by its header strip (the bar with the tool's name) to park it anywhere. Once you have placed it yourself, it stays put for the whole session and never jumps again.
- H hides and shows it; it also auto-hides while you drag a waypoint.

### Numeric fields

- Every number on the panel can be changed three ways: click the - / + steppers, scroll the wheel over it, or click the value and type it.

### Settings & colours

- The gear on the panel header (or a rebindable key) opens the settings dialog: UI scale, theme preset, accent colour, and a per-role colour editor.
- Settings are also on the panel under ACTIONS > settings. Everything applies live and saves automatically.
- Console command FlyoverResetTheme (or a rebindable key) resets colours and scale to default if a custom colour ever makes the panel hard to read.

<a id="select"></a>
## Select

*Mode — The default mode. Click things to edit them; no tool is held.*

Select mode is where you inspect and act on what is already there rather than creating anything. Clicking the network opens a context menu for whatever you clicked, and the same click can escalate from a single point to a whole span to a whole run, so you rarely have to switch tools to make an edit.

**How to use it**

1. Click a waypoint to open its POINT menu (name, move, connect, convert, delete).
1. Click again on the same point, or double-click, to grab the SPAN either side of it.
1. A further click grabs the whole RUN between the two nearest junctions.
1. Alt+drag a box, Shift+drag a circle, Alt+Shift+drag freehand, or Space+drag+click a rotated box to multi-select points - works in every tool, not just Select. Hold Ctrl on top of any of these (or alone) to ADD to the selection instead of replacing it; a plain Ctrl-click toggles one point at a time.
1. The clicked point/span/run is highlighted in the world while its menu is open.
1. Right-click closes the menu without doing anything.

**Controls**

- **Point menu** — name, move, connect from here, spline from here, one/two-way, primary/secondary, delete.
- **Span / run menu** — straighten, smooth, divide, ground, parallel (run), one/two-way, flip direction, delete.
- **Arm a tool** — choosing an action from a menu ARMS that tool on the selection; dial its setting, then right-click to apply.

<a id="draw"></a>
## Draw

*Create — Place waypoints and connect them into a route.*

Draw lays down new waypoints one click at a time, joining each to the last so a route grows as you go. It is the basic way to build track that is not derived from an existing shape.

**How to use it**

1. Click empty ground to drop a waypoint; each new one connects to the previous.
1. Click an existing waypoint to start drawing FROM it, wiring the new run into the network.
1. Right-click ends the current run, so the next click starts a fresh one.

**Controls**

- **direction** — whether new connections are one-way or two-way.
- **priority** — primary or secondary (secondary shows as a give-way road).
- **snap to** — surface or terrain - what the new points sit on.

<a id="spline"></a>
## Spline

*Create — Draw a smooth curved connection between two points.*

Spline connects two waypoints with a curve rather than a straight segment, for sweeping bends a vehicle can follow at speed. A live preview shows the curve before you commit it.

**How to use it**

1. Click the start waypoint, then the end waypoint - the curve previews between them.
1. Scroll the wheel to tighten or loosen the curvature while the preview is up.
1. Click again / confirm to place it; right-click cancels.

**Controls**

- **curvature (wheel)** — how tight the curve is, clamped to a sane range.
- **endpoints** — which end the curve is computed from (reshapes it).
- **end / start tangent** — flip the direction the curve leaves each end.
- **direction / priority** — as for Draw - one/two-way and primary/secondary.

<a id="field-loop"></a>
## Field loop

*Create — Generate a drivable loop around the field under the cursor.*

Field loop builds a complete two-way route that runs just outside a field's boundary, smoothed to a turning radius and nudged inward around any trees in the way. It is a standalone loop - no map markers, not wired to the rest of the network - so you connect it in afterwards with Draw or the editor.

**How to use it**

1. Point the cursor at the field you want the loop around.
1. Select the field loop tool - it reads the field boundary and lays the loop.
1. Wire the loop into your network afterwards if you need it connected.

**Controls**

- **margin** — how far outside the boundary the loop runs.
- **tree clearance** — how far the loop keeps from trees before detouring.
- **turning radius** — the tightest turn the loop is allowed to make.
- **vehicle height** — how tall a machine the tree check clears for.
- **detect custom field** — on by default; when Courseplay is active, also finds one of ITS custom fields (a boundary you recorded, possibly bridging several map fields), not just a field shipped with the map. No effect without Courseplay. Turn it off to fall back to the map-field-only lookup if it ever misreads a field on your save.

<a id="parallel"></a>
## Parallel

*Create — Lay a track running parallel to a span or run.*

Parallel offsets an existing span or run sideways by a set distance to make a second track alongside it - a passing lane or a return leg.

**How to use it**

1. Pick the span (two points) or run you want to run alongside.
1. Set the distance and side, then apply - the new parallel track is created.

**Controls**

- **distance** — how far to the side the new track sits.
- **side** — left or right of the original's direction of travel.
- **covers** — whether it works on the picked span or the whole run.

<a id="siding"></a>
## Siding

*Create — A parallel spur that splines back in at both ends.*

Siding drops a short parallel stretch beside a run and curves it back into the run at each end, like a pull-off or passing siding, in one action.

**How to use it**

1. Pick the anchor point on the run.
1. Set the offset and length (scroll adjusts the length), then apply.

**Controls**

- **offset** — how far to the side the siding sits.
- **length (wheel)** — how long the parallel stretch is.
- **side** — left or right.

<a id="move"></a>
## Move

*Shape — Drag a waypoint, a run, or a span - move it, copy it, break it off, or slide it sideways.*

Move drags one or more waypoints to a new spot and re-seats them on the real ground there. Picks decide WHAT moves - a single point, the whole run it belongs to, or a span you pick the two ends of - and falloff decides whether that tapers smoothly or moves as one rigid piece. Copy leaves the originals in place and creates the move as a new, disconnected piece instead; break (copy's own sub-option) goes further and deletes the originals too, so the piece ends up relocated and cleanly detached rather than stretching a connection across the map. Offset slides an existing run or span sideways IN PLACE - unlike Parallel, it does not create a new track, the same waypoints just move over, connections and all. Auto-hookup, if turned on, silently reconnects a dangling end (one made by a break, a copy, or just an ordinary move) to whatever it lands near.

**How to use it**

1. Point at a waypoint and drag it; release to drop it.
1. "picks" cycles Point / Run / Span. Span needs its two ends clicked first; once picked, click near either end again to replace it, or drag the span to move it.
1. "falloff" toggles the taper. On Point it spreads along the track by the falloff radius (wheel over the card, the +/- steppers, or , and .); on Run/Span it tapers to the run or span's own two ends automatically, with no radius to set.
1. A ctrl-click / box (Alt+drag) / circle (Shift+drag) / freehand (Alt+Shift+drag) / rotated box (Space+drag+click) selection, if one exists, always wins over picks - grab any point IN it to drag the whole set, rigid.
1. "copy" (hotkey B) toggles whether the drag creates a new, disconnected copy instead of moving the originals. It can be turned on before, during, or even just after a drag - toggling it on right after releasing still converts that move into a copy.
1. "disconnect" severs the moved piece's outside connections. On its own (copy off) it just moves and cuts loose, no clone. With copy also on, it additionally deletes the originals once the copy is made - the piece ends up relocated, not duplicated.
1. On Run or Span, "offset" changes what a drag does: instead of a free 2D move, the cursor's distance from the chain slides it sideways, the whole thing at once. Releasing does NOT drop it - wheel (or type a value) to fine-tune the distance, then right-click to finish. A stray click elsewhere is ignored while one is pending, and the wheel adjusts the pending offset from anywhere in the view, not just over the card.
1. "offset falloff", when offset is on, tapers the slide toward either end of the chain instead of sliding it all the same amount - useful for blending an offset smoothly into an existing junction or track instead of leaving a hard kink.
1. "auto-hookup", if on, checks any dangling end left by the drag (at most one existing connection) against nearby waypoints and wires it up automatically, no confirmation - its own distance/divergence tolerances appear on the card while it is on.
1. Hold R and scroll the wheel WHILE dragging to rotate whatever is moving, live - around either the point you grabbed or the moved set's centroid, whichever "rotate pivot" is set to.
1. The tool card auto-hides while you drag, so it is never in the way.

**Controls**

- **picks** — what a plain drag grabs: Point, Run, or Span. A box/circle/freehand/rotated-box/ctrl-click selection always overrides picks when you grab a member of it.
- **falloff** — on/off; Point also gets a settable radius when on.
- **copy (b)** — on/off; leaves the originals and creates a new, disconnected piece.
- **disconnect** — on/off; severs outside connections. With copy off, moves in place and cuts loose. With copy on, also deletes the originals once copied.
- **offset** — on/off (Run/Span only); drag-then-wheel sideways slide, right-click to finish.
- **rotate pivot** — click point or centroid - what R+wheel rotates the dragged set around. Takes effect on the NEXT grab.
- **offset falloff** — on/off (while offset is on); tapers the slide near the chain's own two ends instead of sliding it all rigidly.
- **auto-hookup** — on/off; silently reconnects a dangling end within tolerance.
- **snap to** — surface or terrain for the dropped point.

<a id="smooth"></a>
## Smooth

*Shape — Round off the jitter in a span or run.*

Smooth eases the small kinks out of a stretch so a driven path stops feeling jumpy. It has two modes: one nudges the existing points into line (keeping junctions and markers), the other rebuilds the stretch at an even spacing.

**How to use it**

1. Pick the span or run to smooth.
1. Choose the mode and strength/spacing, then apply.

**Controls**

- **mode** — nudge existing points, or rebuild the stretch fresh.
- **strength** — how hard the nudge pulls (nudge mode).
- **max spacing** — point spacing when rebuilding (rebuild mode).

<a id="straighten"></a>
## Straighten

*Shape — Flatten the noise out of a span while keeping real bends.*

Straighten removes wandering detail from a stretch but keeps genuine corners, by dropping only the points that sit within a tolerance of the straight line. Raise the tolerance to flatten a real bend as well. Junctions in the middle are kept.

**How to use it**

1. Pick the span or run to straighten.
1. Set the tolerance - larger removes more - then apply.

**Controls**

- **tolerance** — how far off the line a point may be before it is kept.

<a id="divide"></a>
## Divide

*Shape — Add evenly-spaced points along a span or run.*

Divide inserts a chosen number of new waypoints spread evenly by distance along a stretch, giving you handles to work with where the track was too coarse.

**How to use it**

1. Pick the span or run.
1. Set how many points to add, then apply.

**Controls**

- **points** — how many new points to space along the stretch.

<a id="ground"></a>
## Ground

*Shape — Re-seat points onto the surface under them.*

Ground drops (or raises) the waypoints of a stretch onto the ground within a tolerance, fixing points that float above the terrain or sit buried. It keeps a point that is already correctly on a placed ramp or bridge deck rather than pulling it down to the terrain the straight line runs over.

**How to use it**

1. Pick the span or run.
1. Set the tolerance (how far off the ground counts as a problem) and apply.

**Controls**

- **tolerance** — how far off the surface a point may be before it is moved.
- **level** — settle to the top surface, or the one nearest the point.
- **snap to** — terrain or any surface (roads, decks).

<a id="convert"></a>
## Convert

*Connect — Change one-way / two-way and priority.*

Convert rewrites the direction and priority of connections that already exist - make a stretch two-way, one-way, or flip it to a give-way (secondary) road - for a point, a span or a whole run.

**How to use it**

1. Pick the point, span or run.
1. Choose what to make it (two-way, one-way, primary, secondary) and apply.

**Controls**

- **make it** — two-way, one-way, primary or secondary.
- **scope** — the point, the span, or the whole run.

<a id="merge"></a>
## Merge

*Connect — Fold two parallel lanes into one shared track.*

Merge is for a stretch where two separately-recorded tracks run alongside each other - the two directions of a road, or a lane you recorded twice - and you want them to become one. You mark the length on one track, then point at the other, and the marked span is absorbed into it. It is a three-click action, not a single click on a pile of points.

**How to use it**

1. Click one end of the stretch on ONE of the two tracks.
1. Click the far end on the SAME track. The two clicks must be two ends of one connected span - if they are not on the same track a warning says so and nothing happens.
1. Click a point on the OTHER track running alongside. The part that will be absorbed turns green; the click confirms which nearby track is meant, and the merge happens.
1. The two tracks have to be within the merge distance of each other (measured across the gap between them) for anything to merge - if they are too far apart, nothing does.

**Controls**

- **merge distance** — how far apart the two tracks may sit and still merge, measured across the gap. Set on AutoDrive's settings page.
- **divergence** — how far the two tracks may pull apart ALONG the stretch before they count as separate runs and the merge stops there.

<a id="name"></a>
## Name

*Utility — Give a waypoint a map-marker name.*

Name attaches a label to a waypoint so it becomes a named destination/marker on the map, the way AutoDrive targets are named.

**How to use it**

1. Click the waypoint you want to name.
1. Type the name in the dialog that opens and confirm.

**Controls**

- **name dialog** — the base-game text entry, opened on click.

<a id="delete"></a>
## Delete

*Utility — Remove a point, a span or a run.*

Delete removes waypoints and the connections through them - a single point, a picked span, or a whole run between junctions, depending on the scope.

**How to use it**

1. Pick the point, span or run.
1. Set the scope and apply - it is removed (and undoable).

**Controls**

- **scope** — the point, the span, or the whole run.
