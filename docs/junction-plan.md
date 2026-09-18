# Auto junction placement — design & implementation plan

**Status:** proposed (design). Not yet built. Two decisions still open (see *Open decisions*).

Goal: a tool that builds a working AutoDrive intersection between nearby tracks — smooth, tangential,
one-way curved connectors (merge and diverge ramps), kept clear of obstacles — matching the geometry
the network already uses. Longer term, a one-click generator for a whole intersection.

---

## 1. Why this shape — survey of savegame 4 (Riverbend_Springs)

Before designing anything, the existing network was profiled from
`savegame4/AutoDrive_config.xml` (see `tools/`-style survey scripts in the session scratchpad). The
numbers below are the rationale for every design choice that follows.

- **12,479 waypoints**, but only **486 junctions** (degree ≥ 3): **399 three-way, 84 four-way, 3
  five-way**. 145 dead-ends; the other 11,848 are plain degree-2 line points.
- **Waypoints sit ~4 m apart** (median nearest-neighbour 3.96 m). Curves are formed by point density,
  not by any stored radius.
- **~95 % of junction arms are one-way** (1,472 one-way vs 76 two-way). This is a **one-way-lane**
  network.
- **Median angle between arms at a junction is 10°** (p10 5°, p90 30°). Junctions are **shallow
  forks**, not perpendicular crossroads.
- **303 junction pairs sit within 8 m of each other.** Intersections are **clusters of closely-spaced
  split/merge nodes**, not single hubs.
- Two representative sites:
  - **id 952 (4-way):** three one-way arms coming *in* from bearings 287–315° (0.4–5.7 m apart), one
    going *out* at 115° — a **merge funnel**; 7 other junctions within 15 m.
  - **id 1204 (5-way):** three one-way arms fanning *out* at 283–299° (~3 m), one coming *in* — a
    **diverge fan**; 5 other junctions within 15 m.

**Takeaway.** Real intersections here are smooth, tangential, one-way **merge funnels and diverge
fans** built from several ~4 m-spaced nodes, arms clearing at shallow angles. That is the geometry to
reproduce. A single sharp "shared node" is **not** how these are built and would drive badly — it is
the *common-node collision* pattern, which is deferred (see §7).

---

## 2. What V1 is

A **one-click intersection generator** — the "Field loop" of junctions. You click near where roads
should meet and it builds the whole set of smooth one-way connectors needed to make the intersection
work, previews it, and commits on confirm.

It is explicitly **not** "insert one shared node." Each movement gets its own tangent curved ramp,
matching the spread-cluster style the map already uses.

---

## 3. Decisions locked in

1. **Connector priority — match the joined road.** Each connector inherits the priority of the
   through-road it ties into (primary stays primary, secondary stays secondary).
2. **Both directions.** On a one-way network a connector runs one way: a **merge** (on-ramp, A→B) or a
   **diverge** (off-ramp, B→A). A complete intersection needs both for every lane pair, so the
   generator builds the whole set — merge funnels *and* diverge fans — not one direction.
3. **Clear of all obstacles, via the physics world.** Not just trees. Sample points along each
   proposed connector and run an engine **collision / overlap query** (a box the width of the road plus
   a clearance margin) at each — the same mechanism AutoDrive uses for its own obstacle detection. A
   hit against *any* static collidable (building, **fence, light pole, sign**, tree) flags that stretch,
   so the curve is nudged or the movement is refused with a reason. One check covers every obstacle
   type instead of a brittle per-type list from `placeables.xml`.
4. **One click builds the whole intersection**, not one connector at a time.

---

## 4. Pipeline

When you click near where roads should meet:

1. **Scope** — gather every track segment within a radius of the click.
2. **Approaches** — group those segments into distinct one-way *approaches* (each: a lane entering or
   leaving the area, with its direction and priority). This is the step that turns a pile of nodes into
   "road 1 in, road 1 out, road 2 in, road 2 out…".
3. **Movement matrix** — decide which entering approaches connect to which exiting approaches (all
   legal turns, no U-turns). For a clean crossing that is the standard set.
4. **Connectors** — generate all the tangent curves at once:
   - leave the source lane tangent to its travel direction, arrive at the destination lane tangent to
     its direction, at a shallow join angle (~10–20°, matching the survey);
   - radius ≥ the turning-radius setting; resampled to ~4 m spacing;
   - each inherits its through-road's priority (decision 1);
   - each cleared against **all** obstacles (decision 3) *and* against the other connectors.
5. **Node structure** — spread merge/diverge nodes, matching the map today. (The single **common node**
   for collision-prioritisation is V2, see §7.)
6. **Preview then commit** — the whole proposed intersection draws live (green where clear, red where
   blocked) so it is seen before it is placed; right-click builds it, as **one** undo step.

---

## 5. The hard part, and how it is de-risked

Auto-inferring *intent* from a single click — how many roads, which lanes pair up, at odd angles or
offsets — is the genuinely tricky part. Mitigations:

- **Nail the clean case first**: two roads crossing (each one-way, or a one-way pair). That is most of
  the 84 four-way junctions on the map.
- **Lean on the preview**: the full proposed intersection is always shown before commit, with a
  scope-radius / turning-radius / clearance the user can dial, so a bad guess is *visible*, not
  destructive.
- **Keep a fallback**: when auto-grouping is ambiguous, drop to "click the roads to include" — the same
  generator, explicit inputs.

---

## 6. Reuse map (keeps new risk low)

| Need | Reuse |
|---|---|
| Smooth curve between two tracks | Spline path (`AutoDrive.createSplineInterpolationBetween`) |
| Radius, resample to spacing, obstacle-aware routing | `OffsetGeometry`, `FieldLoopGenerator` |
| Splice a tie-in node onto a segment | Divide (insert-and-rewire) |
| One-way direction & priority on connections | Draw, Convert |
| Per-point height onto the surface | Ground |
| Undo, live preview | `EditorHistory:snapshot`, `drawNetwork` |
| Obstacle detection against all collidables | engine collision/overlap query (as AutoDrive uses) |

Genuinely new code: the pair/approach proximity scan, the tangent tie-in placement, the movement
matrix, and the collision-clearance gate.

---

## 7. Deferred (V2+)

- **Common-node convergence for collision handling** — route multi-way movements through one shared,
  prioritised node so AutoDrive serialises vehicles through it. A refinement layered on top of the
  smooth connectors, and the opposite of the spread-cluster style the map uses today, so it earns its
  own design pass. (This is the "logic point people have determined helps multi-directional
  intersections" — worth doing, later.)
- **Auto-scan the whole map** for candidate intersections (linter-style batch build/repair).
- **Messy / offset N-way inference** and connector-vs-connector deconfliction at dense sites.

---

## 8. Codebase integration

- `TOOL.JUNCTION`, name `junction`, **Connect** group, click-only (like Convert/Merge — no keycap, no
  renumber). New icon cell in `textures/tool_icons.dds` via `tools/make_tool_icons.py`.
- `ADFlyoverEditor:updateJunctionPreview()` (scope → approaches → movements → connectors → clearance),
  called from `update()` while the tool is active.
- `ADFlyoverEditor:applyJunction()` on right-click: splice tie-ins, lay connector chains, height,
  `EditorHistory:snapshot`, log.
- Tool-card fields (wheel / steppers / typed): **scope radius**, **connect distance**, **height
  tolerance** (overpass guard), **turning radius**, **obstacle clearance**; toggle: priority source.
- Help entry via `tools/make_help.py` → `scripts/editor/Help.lua`; German in `scripts/editor/Locale.lua`.

---

## 9. Open decisions

- **A. Approach grouping in V1.** *Recommended:* target the **clean 2-road crossing** first (fast to a
  working, previewable tool); arbitrary N-way inference is a follow-up. Alternative: require full N-way
  from day one (much longer, more guessing).
- **B. When the auto-guess is unsure.** *Recommended:* **fall back to "click the roads to include"**
  (same generator, explicit inputs). Alternative: always just preview the best guess and let the user
  accept/reject.

Once A and B are settled, this plan is ready to turn into an implementation task.
