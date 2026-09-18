# Flyover Editor — user manual

A top-down editor for AutoDrive route networks. This manual describes every tool and the controls that work everywhere. It is generated from the same source as the in-game help (`tools/make_help.py`), so the two always agree.

## Contents

- [General](#general)
- **Mode** — [Select](#select)
- **Create** — [Draw](#draw), [Spline](#spline), [Field loop](#field-loop), [Parallel](#parallel), [Siding](#siding)
- **Shape** — [Move](#move), [Smooth](#smooth), [Straighten](#straighten), [Divide](#divide), [Ground](#ground)
- **Connect** — [Convert](#convert), [Merge](#merge), [Junction](#junction)
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
- Esc - leave the editor (or close a dialog / cancel an edit).

### Mouse & camera

- Left-click - place / select / operate, depending on the tool.
- Right-click - end a run, cancel a menu, or apply an armed tool.
- Middle-mouse - orbit / spin the camera. WASD moves it.
- Wheel - camera zoom, or adjust the numeric field the cursor is over.

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
1. Drag a box across the map to multi-select points.
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

*Shape — Drag a waypoint, optionally carrying its neighbours with it.*

Move drags a waypoint to a new spot and re-seats it on the real ground there. A falloff can spread the move to nearby points along the track so a whole stretch shifts smoothly instead of one point jumping.

**How to use it**

1. Point at a waypoint and drag it; release to drop it.
1. The tool card auto-hides while you drag, so it is never in the way.
1. Set the falloff first (wheel over the card, the +/- steppers, or , and .) to carry neighbours along.

**Controls**

- **falloff along track** — how far along the run the move spreads to neighbours.
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

<a id="junction"></a>
## Junction

*Connect — One click builds a whole intersection of smooth, radius-bound turn connectors.*

Junction generates the connectors an intersection needs - every legal turn between the roads inside its scope circle - in one placement. Connectors are laid from the real lane geometry: tie-ins sit on the actual tracks, curves are bounded by the turn radius, kept on the road surface, and kept clear of static obstacles, with each turn solved at the largest radius that fits its spot. Anything that cannot be built safely is refused visibly - drawn red, counted on the card, explained in the log - rather than laid badly.

**How to use it**

1. Point at a crossing - the scope circle and the approaches it cuts preview live. The wheel sizes the circle: the primary lever for what counts as one junction.
1. Left-click LOCKS the site (the circle turns solid). The preview stops following the cursor; the wheel and the card's settings still reshape it live.
1. White curves are the turns it will lay; red ones are refused, with the reason counted on the card (too tight, off road, blocked, and so on).
1. Right-click places everything as ONE undo step. Right-click with nothing to place unlocks the site; right-click again puts the tool away.
1. With 'existing turns: rebuild', the old connectors inside the scope are cleared and laid fresh - the roads themselves are never touched.

**Controls**

- **search radius (wheel)** — the scope circle - which roads belong to this junction.
- **turn radius** — the target turning radius; each turn shrinks itself only as far as needed to fit its corner.
- **road check** — keep the vehicle corridor on the road surface; off means radius only.
- **obstacles** — refuse turns whose corridor hits trees, buildings, poles or fences.
- **corridor / clearance** — the widths for the road-surface check and the obstacle box.
- **trim/extend** — let a tie-in project past a stem that was trimmed short of the corner.
- **existing turns** — keep what is already there, or rebuild it fresh.
- **curve** — dubins (radius-bounded, pose to pose) or biarc; the shorter solution wins.

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
