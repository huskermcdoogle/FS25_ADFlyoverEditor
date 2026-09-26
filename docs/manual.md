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
- , and . - Move's falloff value down / up.
- B - toggle Move's copy.
- R (held) + wheel - rotate what is being dragged (Move, mid-drag).
- Esc - back out ONE step: a typed number, a dialog, a popup (and its selection), a tool picked from a popup (back to the popup), a pending action, the selection, the tool - and only then leave the editor.

### Mouse & camera

- Left-click - pick; left-drag - move (Move). Second click = span, double-click = run, in every tool that works on a stretch.
- Right-click - apply what is pending (end a run, lay a track, commit), or close a popup.
- Middle-mouse - orbit / spin the camera. WASD moves it.
- Wheel - camera zoom, or adjust the number the cursor is over.
- Ctrl - add to / remove from the selection, on its own or on top of a shape below. In Smooth, Straighten, Divide, Parallel and Merge it must stay one connected run.
- Alt+drag box, Shift+drag circle, Alt+Shift+drag freehand, Space+drag+click rotated box.

### Popups

- Clicking the network opens a popup for the point, span, run or selection. It opens clear of what it acts on and can be dragged by its header.

### The tool card

- The floating card carries the active tool's settings: toggles lit when on, choices side by side, numbers you can step, scroll or type. Options that cannot apply right now are greyed.
- Picked from a popup, the card opens where the popup was. It steps aside when it would cover your work, and otherwise stays where you dragged it (header strip).
- Pin (on the header, or the settings dialog) keeps it exactly where it is, always.
- H hides and shows it; it also auto-hides while you drag a waypoint.

### Numeric fields

- Every number on the panel can be changed three ways: click the - / + steppers, scroll the wheel over it, or click the value and type it.

### Settings & colours

- The panel's SETTINGS has UI scale, theme and accent; drag the panel's bottom-right corner to resize. "more settings..." (or the gear) opens the dialog: line weight, per-role colours, the tool card pin, the launch button and debug logging.
- Everything applies live and saves automatically. Console command FlyoverResetTheme resets colours and scale if a custom colour ever makes the panel hard to read.

<a id="select"></a>
## Select

*Mode — The default mode. Click things to edit them; no tool is held.*

Select mode is where you act on what is already there. Clicking the network opens a small popup of actions for what you clicked - a point, a span or a whole run - and a selection opens one for the whole set, so most edits need no tool at all. The popup opens clear of what it acts on and can be dragged by its header.

**How to use it**

1. Click a waypoint: its POINT popup (name, move, connect, spline, one/two-way, primary/secondary, delete).
1. Click a second point: the SPAN between them. Double-click a point: the whole RUN.
1. Alt+drag a box, Shift+drag a circle, Alt+Shift+drag freehand, Space+drag+click a rotated box, or Ctrl-click points one by one to make a SELECTION; its popup acts on the whole set. A plain click followed by Ctrl-clicks keeps the first point; one point left is a point again.
1. Picking a tool from a popup opens that tool's card where the popup was; right-click applies, Esc steps back to the popup.
1. Esc closes the popup (and drops a selection); right-click closes it too.

**Controls**

- **Point popup** — name, move, connect, spline, make two-way / one-way, primary / secondary, delete point.
- **Span / run popup** — move, straighten, smooth, divide, ground (+ parallel on a run), make two-way / one-way, flip direction, delete.
- **Selection popup** — move, clear, make two-way / one-way, other way, primary / secondary, delete selection. Conversions only touch links BETWEEN selected points.

<a id="draw"></a>
## Draw

*Create — Place waypoints and connect them into a route.*

Draw lays down new waypoints one click at a time, joining each to the last so a route grows as you go. It is the basic way to build track that is not derived from an existing shape.

**How to use it**

1. Click empty ground to drop a waypoint; each new one connects to the previous.
1. Click an existing waypoint to start drawing FROM it, wiring the new run into the network.
1. Right-click ends the current run, so the next click starts a fresh one.

**Controls**

- **traffic** — one-way, two-way or reverse-way (a road vehicles drive in reverse gear).
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
- **spline direction** — as clicked builds the curve from the first point; reversed builds it from the far end. That reshapes the curve and, on a one-way, sets which way it runs.
- **end / start tangent** — flip the direction the curve leaves each end.
- **traffic / priority** — as for Draw - one-way, two-way or reverse-way (AutoDrive's reverse road, which vehicles drive in reverse gear) and primary/secondary.

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
- **obstacle clearance** — how far the loop keeps from trees, poles, fences and buildings before detouring.
- **turning radius** — the tightest turn the loop is allowed to make. Never used below 5m even if set lower - a sharper corner than that reads as an awkward kink rather than a smooth turn.
- **vehicle height** — how tall a machine the tree check clears for.
- **detect custom field** — on by default; also finds ground plowed to connect two separate map fields into one, not just a field shipped with the map. Turn it off to fall back to the map-field-only lookup if it ever misreads a field on your save.
- **avoid obstacles** — on by default; nudges the loop away from trees, poles, fences and buildings instead of laying it straight through them. Turn it off to take the offset boundary as laid if the obstacle check keeps flagging something that isn't really in the way.
- **combo gap** — how far to auto-search for another disconnected patch of the same field when it's split by a lane, and combine it into the same course - a live scan can only ever return the one piece a click lands on, so this finds the rest on its own, no extra clicks needed. A real per-map setting, not just a safety margin: raise it if a wide lane gets missed, lower it if it ever reaches across an actual road into an unrelated field.

<a id="parallel"></a>
## Parallel

*Create — Lay a new track running parallel to a span or run.*

Parallel copies a span or run sideways by a set distance as a second track alongside it - a passing lane or a return leg.

**How to use it**

1. Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The "picks" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.
1. The side follows where the cursor is when the span is picked; change it on the card.
1. Set the distance (type, step or wheel), then right-click to lay it.

**Controls**

- **side** — a one-way track: left / right of its direction of travel. A two-way track: left / right or up / down as it lies on screen - the words follow the camera.
- **flow** — beside a one-way road: the new track runs the SAME way, or OPPOSITE as a return lane. Greyed on a two-way road, where it makes no difference.
- **picks** — span / run - what was picked; click to lock the type.
- **distance** — how far to the side the new track sits.

<a id="siding"></a>
## Siding

*Create — A parallel spur that splines back in at both ends.*

Siding drops a short parallel stretch beside a run and curves it back into the run at each end, like a pull-off or passing siding, in one action.

**How to use it**

1. Click where the siding should sit - the click is its centre, and the side follows the cursor.
1. Set the offset and length (the wheel adjusts the length), then right-click to lay it.

**Controls**

- **side** — as for Parallel: left / right of travel on a one-way track, by screen on a two-way one.
- **offset** — how far to the side the siding sits.
- **length (wheel)** — how long the parallel stretch is.

<a id="move"></a>
## Move

*Shape — Drag a point, a span, a run or a selection - move, copy, cut loose, or slide sideways.*

Move drags waypoints to a new spot and re-seats them on the real ground there. A CLICK picks what moves (a point, a span, a run), a DRAG moves it, so picking and moving are the same gestures as everywhere else. Falloff decides whether the move tapers smoothly or goes as one rigid piece. Copy leaves the originals and moves a new copy; disconnect cuts the moved piece loose. The OFFSET action slides a span or run sideways in place instead of moving it freely.

**How to use it**

1. Press and drag a point to move it. Release to drop it.
1. Click (no drag) to pick instead: a point; a second point for the SPAN between; double-click for the whole RUN. Then drag any point of the pick to move the lot. Dragging a point outside the pick moves just that point.
1. The "picks" row lights to show what is picked. Click a type to lock it: run moves the whole run from a single grab, point never builds spans. Click it again to unlock.
1. A selection (box, circle, freehand, rotated box, Ctrl-click) wins: grab any selected point to move the set. One connected run of points counts as a span; a scattered set moves rigidly.
1. Falloff: on a single point it spreads along the track by the falloff value (wheel, steppers, typed, or , and .). On a span, run or run-shaped selection it tapers from the point you grab down to zero at its own two ends - no value to set.
1. Copy (B): on before you grab, you drag a new copy out and the original stays; turned on part way, the original drops straight back and the copy carries on; turned on just after a drop, that move becomes a copy.
1. Action OFFSET (span or run picked): the cursor's distance from the chain slides it sideways; release, fine-tune with the wheel or a typed value, right-click to finish. Copy and disconnect work here too.
1. Hold R and scroll WHILE dragging to rotate what is moving, around the grabbed point or the centroid.
1. Options that cannot apply are greyed: falloff and disconnect exclude each other, offset falloff and disconnect too, and disconnect greys when nothing connects to the piece.

**Controls**

- **picks** — point / span / run - an indicator of what a click picked, and a type lock.
- **action** — move (free drag) or offset (sideways slide; needs a span or run).
- **falloff** — tapered or rigid. A single point's reach is the falloff value.
- **auto-hookup** — on a drop, joins a dangling end to what it lands near.
- **copy (b) / disconnect** — leave a copy / cut the moved piece loose.
- **offset falloff** — (offset) tapers the slide towards the chain's ends.
- **rotate pivot** — click point or centroid, for R+wheel.
- **snap to** — terrain or surface for the dropped points.

<a id="smooth"></a>
## Smooth

*Shape — Round off the jitter in a span or run.*

Smooth eases the small kinks out of a stretch so a driven path stops feeling jumpy. Relax nudges the existing points into line (keeping junctions and markers); rebuild lays the stretch again at an even spacing.

**How to use it**

1. Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The "picks" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.
1. Or Ctrl-click the points one by one - they have to stay one connected run; a plain click afterwards drops that and starts a new pick.
1. Set the mode and strength / spacing, then right-click to apply.

**Controls**

- **mode** — relax (move points) or rebuild (respace).
- **strength** — how hard relax pulls.
- **max spacing** — point spacing when rebuilding.

<a id="straighten"></a>
## Straighten

*Shape — Flatten the noise out of a span while keeping real bends.*

Straighten removes wandering detail but keeps genuine corners, dropping only the points within a tolerance of the straight line. Junctions, markers and the ends are kept; each stretch between them is straightened along the route you picked.

**How to use it**

1. Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The "picks" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.
1. Or Ctrl-click the points one by one (one connected run).
1. Set the tolerance - larger removes more - then right-click to apply.

**Controls**

- **tolerance** — how far off the line a point may be before it is kept.

<a id="divide"></a>
## Divide

*Shape — Respace a span or run with a chosen number of points.*

Divide spreads a chosen number of waypoints evenly by distance along a stretch, along the route you picked, keeping junctions and markers where they are.

**How to use it**

1. Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The "picks" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.
1. Or Ctrl-click the points one by one (one connected run).
1. Set how many points, then right-click to apply.

**Controls**

- **points** — how many points between the ends (starts at what is there now).

<a id="ground"></a>
## Ground

*Shape — Re-seat points onto the surface under them.*

Ground drops (or raises) waypoints onto the ground within a tolerance, fixing points that float or sit buried. A point already correctly on a placed ramp or bridge deck is left there.

**How to use it**

1. Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The "picks" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.
1. Or select points - box, circle, Ctrl-click - connected or not; Ground checks each on its own.
1. Set the tolerance; the points found off the ground are marked. Right-click re-seats them.

**Controls**

- **picks** — span / run / selection.
- **level** — settle on the span line or the top surface. Greyed while snapping to terrain.
- **snap to** — terrain, or whatever surface is there (roads, decks).
- **tolerance** — how far off the surface a point may be before it is moved.

<a id="convert"></a>
## Convert

*Connect — Change a point's or run's direction and priority in one click.*

Convert rewrites connections that already exist. Set the direction AND the priority you want on the card; one click applies both, as one undo step.

**How to use it**

1. Set direction and priority on the card, and whether it applies to one waypoint or the whole run.
1. Click the point or run.

**Controls**

- **direction** — two-way, one-way, other way (flips a one-way; a reverse-way stays reverse-way), or reverse-way (AutoDrive's reverse road, driven in reverse gear).
- **priority** — primary, or secondary (a give-way road).
- **applies to** — this waypoint, or the whole run.

<a id="merge"></a>
## Merge

*Connect — Fold two parallel lanes into one shared track.*

Merge is for a stretch where two separately-recorded tracks run alongside each other - the two directions of a road, or a lane recorded twice - and you want them to become one. Pick the stretch on one track, then click the other, and the picked stretch is absorbed.

**How to use it**

1. Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The "picks" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.
1. Green marks what would be absorbed. Click the OTHER track to merge - or right-click if it is the only track alongside.
1. The two tracks have to be within the merge distance of each other for anything to merge.

**Controls**

- **merge distance** — how far apart the two tracks may sit and still merge.
- **divergence** — how far they may pull apart along the stretch before the merge stops there.
- **snap to** — terrain, or keep merged points on a bridge / ramp surface.

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

*Utility — Remove a point, a run, or a selection.*

Delete removes waypoints and the connections through them - one waypoint or a whole run between junctions per click, or everything selected.

**How to use it**

1. Click a point: it (or its run, per the card) is removed.
1. With a selection, a left click does nothing - right-click deletes the selection, Esc clears it.
1. Everything is undoable (Q).

**Controls**

- **removes** — one waypoint, or the whole run. Greyed while a selection exists.
