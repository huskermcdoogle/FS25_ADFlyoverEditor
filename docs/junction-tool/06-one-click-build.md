# Junction build (two clicks)

*Draft 1, 2026-10-01. Working notes for us. Spec, nothing built.*

Two clicks on a junction clear it, lay new turns and hook them up, all as one undo. The first click
locks the site and shows the plan; the second builds. It builds from scratch with no mod needed. It
follows the rules we took from the placeable X and T ([Placeable X and T junctions](05-placeable-junctions.md)),
and it uses the clear's centre, box and stubs ([What the builder needs](02-what-the-builder-needs.md)).

**Version 1 covers square X and T junctions only.** Skew T, Y and corner T come after.

## What you do

1. **Point at a junction.** It can be an existing one, messy or already cleared, or a bare crossing
   where roads meet with nothing joining them yet.
2. **First click locks the site.** The card shows the kind (X or T, detected), the centre, and every
   turn it will lay, coloured by whether it passes. If the kind is wrong you can switch it. Switching
   an X to a T leaves the arm you drop untouched, for example a field entrance.
3. **Second click builds.** It clears, builds and hooks up. One undo takes it all back. Right-click
   lets go of the site without building.

If something needs you, the second click does not build. The card says what and offers the choices
(see "When it stops and asks").

## What one click does

1. **Pick the site.** Same picker as the clear: centre, box and kind.
2. **Clear** what is there (skipped on a bare crossing). The middle ends up empty and the stubs reach
   in to the other road's paved edge.
3. **Measure:** lane gap, paved area, which roads are one-way.
4. **Lay the turns** by the rules below.
5. **Check everything** (see "Checks before it commits"). Any failure means nothing is built.
6. **Commit** as one undo, and save the junction's description.

## The layout rules

From doc 05. Each one is there because of how AutoDrive drives:

1. **Every merge or crossing of two paths is one shared point.** AutoDrive only makes a driver wait at
   a shared point.
2. **Every link inside the junction is one-way.** On a two-way link AutoDrive stops checking for
   traffic.
3. **Left turns go one at a time.** Opposite left turns share a point, so one waits for the other.
4. **No U-turns.**
5. **No destination at the centre.**
6. **Kept through roads at an X share a point where they cross** (decided 2026-10-01; replaces doc 02's
   "nothing joins them").
7. **Every turn AutoDrive could use must be one we meant** (see "The route check").

## Which turns it lays

- **T:** both straights stay, plus the right and left turn into the side road, and the right and left
  turn out of it.
- **X:** all four straights stay, plus a right and a left turn from each road.
- **One-way roads:** only the moves the directions allow.
- **No U-turns,** ever.

## How each turn is shaped

- **A real curve,** not a corner. The truck follows a curve, so the curve decides where the wheels go.
- **The size comes from the paved area at this junction.** It is the largest curve whose line stays on
  the paving, checked with the truck twin. It must also leave about 1 m spare on the outside, where the
  truck swings wide.
- **The speed comes from one deliberate bend** at the end of each curve. The last two pieces of the
  curve each turn by the bend for the target speed:
  - right turns: 20 km/h;
  - left turns: 25 km/h on curves of 15 m or more, easing down to 20 km/h at 8 m.
- **Points inside the junction are as far apart as the speed allows.** The bend at each must stay under
  the deliberate one. Wider spacing means drivers see each other further ahead (the "who waits" check
  looks 5 points ahead, not a distance).
- **Where a turn starts and ends:** on the lane, at a point shared with the lane. A turn starts where
  it leaves the lane and ends where it joins its exit lane.

## Opposite left turns

- **Usually they cross on their own.** Each crossing gets a shared point, so they go one at a time.
- **If they would pass without crossing** (small curves on wide roads), both are routed through the
  centre point instead: a curve onto the diagonal, through the centre, and a curve off it. That is the
  mod's shape, made smooth.
- At a curve of 1.71 times the lane gap, both pass exactly through the centre with no straight piece.

## The route check

A shared point lets AutoDrive switch from one path to another whenever the bend there is 80° or less.
So two turns that cross at a shallow angle create a new route nobody laid.

- **Found offline:** at an X with lanes 6 m apart and curves of 8 m or less, the eastbound left and the
  northbound left cross at 65-77°. AutoDrive could hop from one to the other, and one of those hops is a
  **U-turn**. The T's two left turns have the same risk. At 9 m and up they cross at 84° or more.
- **So before committing, the builder lists every route AutoDrive could take** through the junction,
  using AutoDrive's own 80° rule. Each must be one of the turns it meant to lay. A harmless wiggle that
  ends where a laid turn ends is allowed.
- **If an extra route turns up,** it tries a bigger curve for one of the two turns. If that cannot fit
  the paving, it stops and shows why.

## Bare crossings

- **Two roads crossing with nothing joining them (X):** add the shared points where the through lanes
  cross, then lay the turns.
- **A side road stopping short of the main road (T):** carry its lanes in as stubs to the main road's
  paved edge, then lay the turns.
- **Roads that do not reach each other at all:** not a junction. Refuse, and say so.

## Two-way roads

AutoDrive treats a two-way stretch like a one-lane road. Before entering it, a truck checks the whole
stretch ahead for anyone coming the other way. Once on it, the truck keeps right of way and stops
checking (doc 05). That rule is built for one-truck-wide tracks, so the builder works with it.

**A two-way road stays two-way right up to the mouth** (decided 2026-10-02):

- **Its two-way line ends at one point at the mouth.** Every turn into or out of the road starts or ends
  at that point, and the turns themselves are one-way.
- **A truck leaving the junction** checks the whole track ahead at the mouth, while it is still in the
  junction. If someone is coming, it waits there, off the track.
- **A truck arriving along the track** keeps right of way into the junction. Trucks on the junction's
  one-way lanes give way to it, because they share points with its turn.
- **Two junctions close together on one two-way road:** the road between them stays two-way too. The
  same rule covers it.

**Why not split the road into two one-way lanes before the junction?** We planned to, and the truck
twin showed it fails (`tools/xt-study/splitpair.lua`, `overlap.lua`):

- **On a narrow track, one truck arriving and one leaving:** with a split, they met head-on in 32-41 of
  41 start timings, at every split length from 10 to 30 m. Two-way to the mouth: no meetings.
- **Why:** the leaving truck only checks the track once the split is among its next 5 points. By then
  it is on the narrow stretch, so it waits there, in the way. The arriving truck is on a two-way link,
  never checks, and drives in.
- **Between two close junctions:** a guarded one-way stretch met head-on in most runs beyond 10 m.
  Left two-way: no meetings at 10-40 m.
- **A wide split** (two lanes at least 5.5 m apart, about 8.5 m of paving) would avoid the narrow
  stretch. Two-way roads that wide are rare, so it is not built (`tools/xt-study/twowidth.lua`).

Two AutoDrive behaviours found on the way, which matter anywhere:

- **A truck that stops within about 6 m of a shared point stops seeing it,** because that point has
  become the one it is heading for, and the check only looks beyond that one.
- **A waiting truck is released once the other truck's cab is 4 points past,** while its trailer can
  still be in the way.

## Stopping in time (every approach)

Measured 2026-10-02 in the truck twin on one-way lanes (`tools/xt-study/throughdist.lua`). Another
truck holds a shared point; where does ours stop? A straight road has no bends, so the corrected twin
gives the same figures.

**AutoDrive only sees a shared point once it is among the truck's next 5 points.** So how far ahead it
sees is set by the **last four gaps between points** before that shared point, not by any distance
setting. Its own steering point adds about 6 m on top.

**Through trucks are the problem.** They do not slow for the junction. Where the front stops (medium
brakes, 3 m/s²; minus is short of the shared point):

| Points every | 20 km/h | 30 km/h | 40 km/h | 50 km/h |
|---|---|---|---|---|
| 3 m | 8 m short | at it | 9 m past | 18 m past |
| 5 m | 18 m short | 12 m short | at it | 11 m past |
| 8 m | 33 m short | 26 m short | 18 m short | 4 m short |
| 5 m, with 4 junction points in the last 15 m | 3 m short | 5 m past | 15 m past | 25 m past |

The last row is the normal case. Turn starts and other shared points sit close together near every
junction, and they shrink what the truck can see to about 15 m. At that point, anything over about
20 km/h cannot stop in time.

**What the four gaps before each shared point must add up to**, for the truck to stop with its front
3 m short:

| Truck speed | 20 km/h | 25 km/h | 30 km/h | 40 km/h | 50 km/h |
|---|---|---|---|---|---|
| Last 4 gaps add up to at least | 11 m | 14 m | 18 m | 28 m | 40 m |

This applies to **every** shared point on a lane, not just the first. A truck that has to wait for the
far side of the box only sees that point once it is 5 points away, which may already be inside the box.

**Who waits:** when two trucks see each other in the same instant, the one the game updates first
waits. That is vehicle order, not road. So a fast through truck will sometimes be the one asked to wait,
and it overruns.

**Turning trucks are fine** at their 20-25 km/h, with points 4-5 m apart and no crowding. Measured the
same way on a truck coming in from a side lane (`tools/xt-study/splitdist.lua`): a 20 m one-way lane
with points every 4-5 m stops its front about 13 m short of the mouth turning right, and 11 m turning
left (corrected twin).

What this means for the builder:

1. **Turning lanes must pass the gap check.** For every shared point on a turning truck's route, the
   four gaps before it must add up to enough for the turn's target speed (the table above). If they do
   not, the build fails its checks.
2. **Through lanes stay at road speed** (decided 2026-10-02). They are not slowed for the junction, and
   the builder does not try to make them stop in time. It still spaces their points out as far as it
   can, so they get the best reach the layout allows.
3. **Space points out where it can:** approaches at 8-10 m on the straight. Add only the points the
   junction needs, and place them evenly rather than in clumps.

## When it stops and asks

- **No curve fits the paving** for a turn: show the best two or three options with a short reason each.
  You pick or cancel. This is the same as the clear's failed grade.
- **A named destination or a reverse road inside the junction:** show it, then keep, delete or cancel
  (doc 02, decision 6).
- **The route check finds an extra route it cannot fix:** show which, and do not build.
- **The kind looks unsure** (for example a fourth arm that might be a field entrance): show what it
  thinks, and let you switch.

## Checks before it commits

1. **The route check** (above).
2. **No two paths cross without a shared point.**
3. **No two-way link** inside the box. A two-way road's line ends at its point at the mouth.
4. **No destination** inside the box.
5. **The truck twin drives every turn:** wheels on the paving with the spare room, speed in its band.
6. **Nothing outside the junction changed.**
7. **The teal dots** AutoDrive would draw match the merges and crossings we meant.
8. **The gap check** on every turning route: the four gaps before each shared point add up to enough
   for the turn's speed (see "Stopping in time").

## Settings

- Target speeds: right turns, and left turns at small and large curves.
- Spare room on the outside of a turn (default 1 m).
- Through roads kept or not (existing setting).
- Signs as obstacles (existing setting).

## What we reuse, and what is new

The clear and today's builder already do much of this. Line numbers are `FlyoverEditor.lua` on this
branch.

**Reuse as it is:**

- **The picker** (`junctionSelect`, 10538). It already sees bare and cleared sites: a ring of loose lane
  ends counts as a junction (`junctionVirginSites`, 10341).
- **The clear** (`applyJunctionClear`, 22030): cleaning, smoothing, cutting, and stubs at the paved edge
  (`junctionTidyLaneEnds`, 14921).
- **Kind, centre and lane gap** (`junctionClassify`, 18205; box centre; lane gap from the lanes,
  15415).
- **The U-turn filter:** turns whose headings differ by more than 170° are never made (13185).
- **The curve solver and truck test** (`junctionSolveMovement`, 14485). It starts at the turn-radius
  setting and steps down until the curve stays on the road, misses obstacles and passes the truck twin.
  That is "the largest curve that fits", with the setting as the ceiling.
- **Tie-ins** (`junctionTieIn`, 14778): splice a turn's ends into its lanes.

**Change:**

- **Curve ceiling from the paved area,** not the 12 m setting, so wide junctions get bigger curves.
- **Point spacing after the solve:** the solver spaces points by smoothness (about 1.5 m). The
  builder then sets the deliberate speed bend and widens the spacing inside the box.
- **Two-way turns:** today the builder lays a two-way turn where a two-way road comes in (22602). That
  goes. The road's two-way line ends at the mouth and its turns are one-way (see "Two-way roads").
- **The saved description:** today the registry keeps only the number and position (11063). Doc 02 decided
  the clear saves its description; that is still to build.
- **One undo for everything.** Today the clear cleans and smooths the site before it takes its undo
  snapshot (22080-22133, then 22233), so undo cannot bring those changes back. Flagged as its own fix.
  The build must take one snapshot before anything changes.

**New:**

- **Shared points where paths cross.** Today each turn is tied in on its own. Ends are only shared if
  they land within 0.35 m (14825), and crossings get nothing.
- **Opposite left turns through one point** when they would not cross.
- **The route check.**
- **The speed bend.**
- **A build entry in the offline harness, and a build regression.** Today the harness can only run the
  clear (`harness.lua` `M.apply`), so building has no offline test at all.

## Build progress

1. **Shared points where paths cross:** built 2026-10-02 (`junctionShareCrossings` in
   `FlyoverEditor.lua`). It runs as the last step of a build:
   - every place a new link crosses another link gets one point that both run through;
   - a crossing within 0.75 m of an existing point uses that point;
   - links more than 2 m apart in height are left alone, since that is a bridge.

   Build regression: crossings without a shared point fell from 284 at 66 junctions to 1, at j55, a
   tangle of points a metre apart, which the build logs.
2. **The route check:** built 2026-10-02 (`junctionRouteCheck`). It runs after the shared crossings
   and reports only, for now:
   - From every lane in, it follows every route AutoDrive could take under its 80° rule to a lane out.
   - It lists any lane-in/lane-out pair that was not meant: skipped as a U-turn, refused, or never
     planned.
   - It only counts routes that use at least one link the build laid. Routes the roads already offered
     are not the build's doing.

   Build regression: 432 routes at 71 built junctions, **27 extra at 14 junctions**. Without the shared
   crossings, today's builder alone gives 17 at 8.

   **What the extra routes are:** mostly U-turns at crossroads. The four left turns cross each other
   near the middle, and every left turn bends the same way. So at the shared points AutoDrive can hop
   from one left turn to the next (bends of 30-78°) and go round a small ring back the way it came.
   This is the risk "The route check" section predicted.

   **Fixing it** belongs to the left-turn work (step 5 below: opposite left turns through one point,
   and curve sizes that make the left turns cross at more than 80°). Meanwhile a build with an extra
   route still builds, and the build card marks it under "last build" (decided 2026-10-02). The mark
   hides after an undo of the build, as the clear card's check does.
3. **Left turns through the centre: first try failed, switched off** (2026-10-02). The idea came from
   the mod: every left turn passes through one centre point, heading halfway between its way in and
   its way out, so left turns cross there 90° apart and AutoDrive cannot hop between them.
   - **What we tried:** each left turn as two curves (biarcs) meeting at the centre. It is kept behind
     `AutoDrive.FLYOVER_JUNCTION_LEFTS_THROUGH_CENTRE = true`.
   - **Result, worse:** extra routes went from 27 to 41-42, and refused turns from 19 to 27-37.
   - **Why:** forcing a truck-sized curve through one point along a fixed heading bends it into hooks.
     Those cross other paths at shallow angles, which opens new places to hop. The mod gets away with
     straight diagonals only because its pieces are tiny.
   - **Bigger curves do not fix it either** (offline, 2026-10-02):

     | Turn radius setting | Extra routes | Refused turns |
     |---|---|---|
     | 8 m | 21 at 15 | 17 |
     | 12 m (default) | 26 at 14 | 20 |
     | 16 m | 46 at 20 | 29 |
     | 20 m | 41 at 16 | 39 |

     With the builder's real curves, a bigger radius moves the tie-ins back, so a turn sweeps across
     more of the junction and crosses more paths. The square-junction crossing-angle study does not hold
     on real junctions.
   - **Where the switches happen** (each laid point now carries its turn's label; `HOPS=1` in
     dbgbuild). Of the 26 extra routes, switches with a bend over 20°:
     - left turn → left turn: 33 switches, in 13 routes, bends 27-78° (median 55°);
     - lane joint → left turn: 13, in 9 routes; left turn → lane joint: 9, in 7 routes;
     - anything with a right turn: 3 or fewer routes each.

     So the cause is left turns crossing other paths, mostly other left turns, at less than 80°.
   - **S-bend tried, then the real cause found** (2026-10-02):
     - The S-bend (extra points either side of the shared point, square to the crossed path) cut extra
       routes 26 → 13. But it added sharp bends to our turns.
     - AutoDrive caps speed at each point by its bend: 30° or more → 12 km/h, 50° or more → 3 km/h.
     - The real cause was the step 1 **snap**: a crossing within 0.75 m of a point ran the other path
       through that point, bending it up to 88°. That gave 194 sharp bends on our turns before any
       S-bend, and most of the shallow switches.
   - **Fix built: the shared point slides.** One of our own turn points near the crossing, with nothing
     else joined to it, moves onto the crossing (it is already on its own line). Otherwise an existing
     point is shared only if that bends the other path 10° or less; otherwise the crossing gets its own
     point. Road lanes are never bent.

     | Build | Extra routes | Bends ≥30° on our turns |
     |---|---|---|
     | Snap 0.75 m (step 1) | 25 at 14 | 194 |
     | Slide | 18 at 10 | 0 |
     | Slide + S-bend | 17 at 9 | 20 |

   - The S-bend stays in the code, **off** (`FLYOVER_JUNCTION_SQUARE_CROSSINGS`): 1 route is not worth
     20 crawl points.
   - Of the 18 left, 14 have no sharp switch: they go round the block on existing roads and come back.
     The other 4: a right turn ending where a left turn starts (j19, 40°) and a road meeting a left turn
     at 59° (j31).
4. **Two-way roads to the mouth:** built 2026-10-02.
   - **No more two-way turns.** Each direction gets its own one-way turn
     (`FLYOVER_JUNCTION_DUAL_TURNS = true` brings the old behaviour back).
   - **One tie-in point per two-way road.** Where a two-way road ends at the junction, every turn into
     or out of it ties in at one point on it, the turn-radius setting back from its end.
     - Not at its very end: that sits at the other road's edge, where turns had no room to curve. Tying
       there refused 7 more turns.
     - Switched by `FLYOVER_JUNCTION_TWO_WAY_AT_MOUTH`.
   - **A fix on the way:** the builder's "no two-way link on a one-way site" safety check was keyed to
     "two-way turns allowed". With those switched off, it started "repairing" the two-way roads
     themselves where turns spliced into them. It is now keyed to whether the site has a two-way road.
   - **The route check** no longer counts a route the planner skipped as a duplicate of a closer lane
     ("lane"), or one between two separate crossings ("far").
   - Build regression: two-way turn links 10 → **0**; turns laid 319 → 318 and refused 19 → 20 (j2);
     extra routes 26 at 14 (16 at 8 without the shared crossings). Identical on repeat.
5. Then: left turns (offline study first, see 3), the speed bend and spacing with the gap check, the
   curve ceiling from the paving, and one undo for clear and build.

## Not in version 1

- Skew T, Y and corner T.
- Left-hand traffic maps. These would be a mirror image; the mod ships a separate version for them.
- Bridges, multiplayer, roundabouts.
- Which turns to leave out (a player setting, later).

## How we test it

- **Offline, on the square X and T sites in the 75-site registry:** run all the checks above. Drive
  every turn in the truck twin. Its bend scan follows AutoDrive 3.0.1.2 since junction-rework a008a46.
- **In game:**
  - two trucks meeting at a built X and at a T, to confirm who waits;
  - the turn speeds against their targets;
  - that AutoDrive refuses the routes the route check says it refuses.

## Decided

- 2026-10-01:
  - It works on existing junctions and on bare crossings.
  - The tool detects X or T, and you can switch it. Switching an X to a T leaves the dropped arm
    untouched.
  - Version 1 is square X and T only.
  - Kept through roads at an X share a point where they cross.
  - Two clicks: the first locks the site and shows the plan, the second builds.
- 2026-10-02:
  - Two-way roads stay two-way right up to the mouth. Their line ends at one point there, and every
    turn into or out of them is one-way from that point. The split into two one-way lanes, decided
    earlier the same day, was dropped after the two-truck replays (see "Two-way roads").
  - Through traffic stays at road speed. Only slow turning trucks are counted on to wait in time. That
    is how the mod's pieces and most junctions work today. Rejected: slowing every through lane with a
    deliberate bend, and a per-junction setting. Turning lanes must pass the gap check.

## Still open

1. ~~Two-way roads: split or not, how far back, how wide.~~ Settled 2026-10-02: no split (see "Two-way
   roads").
2. ~~Two junctions close together on one two-way road.~~ Settled 2026-10-02: the road between them stays
   two-way.
3. ~~The 5-point reach on one-way approaches.~~ Measured 2026-10-02: see "Stopping in time".
   ~~What a build does when the route check finds an extra route.~~ Decided 2026-10-02: it **builds anyway
   and the card marks it** ("last build jNN - Route check: N route(s) we did not lay"), until the
   left-turn work can reshape the turns. Then it may become "refuse and undo".
4. ~~Through traffic speed at junctions.~~ Decided 2026-10-02: road speed (see Decided).
