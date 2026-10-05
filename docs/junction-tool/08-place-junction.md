# Place a junction (one click)

*Plan, 2026-10-05. Nothing built yet. Replaces the "build" direction of doc 06 for this branch.*

## What it is

Point at roads that cross. The tool shows the X or T it will place, fitted to those roads. One click
places it and hooks it up. One undo takes it all back.

This branch only places pieces. Clearing and rebuilding existing junctions stays with junction-rework.

## Never refused, never the old method

An X or T is always placed. Place never falls back to the old turn-by-turn builder.

- **Fits:** square roads with one-way lanes in pairs. The pattern is fitted to them and every end is
  joined.
- **Doesn't fit yet:** for example a skewed road, a single two-way or one-way side road, a lane bending
  away, or a cross road cut into two stubs. The plain square X or T is placed at the cursor, lined up
  with the main road, as the mod does. Ends that land on a lane are joined. The rest are left loose
  and listed on the card, to join by hand. Loose ends are fine for now.
- **Fit harder, case by case:** each case above gets taught to the pattern in turn, so fewer ends are
  left loose.
- **Only two hard stops:** no roads at the cursor (nothing to line up with), and turn wiring already
  there (clear it first).

## What it places

The pattern from doc 07, already built and tested offline on this branch:

- the mod's shape or the smooth shape (a card setting), sized from the lane gap;
- a shared point wherever two paths cross or merge;
- every path one-way;
- the left turns sharing one centre point, so they go one at a time;
- every new point at ground height.

It hooks up by joining the lanes it lands on. A side road's lanes are carried to the pattern, and any
leftover lane end is taken away.

## Before the click

- The card shows: X or T, the shape, the lane gap, whether it fits, and which ends will be left loose.
- The pattern is drawn where it will go, with loose ends marked.

## After the click

- One undo for the whole piece.
- The route check runs. The card says if a route we didn't lay turns up, or a turn we laid can't be
  driven.

## Steps

1. **Its own entry point.** A "place" mode that finds the crossing at the cursor, using the pattern's
   own finder (the X's four corners, or the T's lane ends) rather than the clear's picker.
2. **The plain-piece fallback.** When the fit fails, line the square piece up with the main road at the
   cursor, join what lands on a lane, and list the loose ends.
3. **Preview.** Draw the pattern and fill the card before the click.
4. **Place.** Lay it, hook it up, run the checks, one undo.
5. **Offline test.** A harness script that clears a site first and then places. It runs over the X's and
   T's from the 75, counting fitted, placed plain, loose ends, and route-check results.
6. **In-game test.** j11 (X) and j9 (T), cleared first: look only, no driving. A short test page.
7. **Fit harder, one case at a time.** In order of how many of the 75 each would fix: skewed T's (12),
   one-way and two-way side roads (10), the cross road cut into stubs (3).

## Progress

- **Build mode is back to junction-rework's** (2026-10-05). It no longer tries the pattern, so it no
  longer falls back quietly. Regression matches the build before the pattern (ec4f2fb).
- **Step 1 done offline** (2026-10-05). "place" is the third action on the junction card; the card
  shows the shape (mod or smooth), what it will place and the lane gap, or why it can't. Right-click
  places it under one undo. `tools/junction-harness/dbgplace.lua` runs it:

  | Site | Mod shape | Smooth shape |
  |---|---|---|
  | j11 (X), cleared | placed, 12 points | placed, 51 points |
  | j9 (T), cleared | placed, 8 points | placed, 21 points |
  | j3 (T, about 30 degrees off square), cleared | not placed: angled side road | same |
  | j11 not cleared | refused: clear it first | same |

  The j3 case is what step 2's plain-piece fallback is for. The route check isn't run after placing
  yet (step 4).
- **Step 2 done offline** (2026-10-05). Where the crossing doesn't fit, the mod's square X or T goes in
  lined up with the main road at the cursor:
  - a T when lane ends lie on one side of the main road, an X when they lie on both sides or there are none;
  - each of its points that lands on a lane running its way joins that lane, and the rest are laid free;
  - free arm ends are the loose ends: counted on the card and listed in the log.

  "Turn wiring still here" is now the clear's own judgement: place refuses exactly where the clear would
  find something to take out. A road splitting into its two lanes is no longer mistaken for wiring.
  All 75, cleared first (`regplace.sh`, identical on repeat): 32 fitted, 37 plain, 6 refused (j14, j20,
  j26, j39, j40, j68: the clear leaves wiring there), 0 Lua errors, 74 loose ends at 27 junctions.
- **Step 3 done offline** (2026-10-05). Place mode draws its own preview:
  - white lines: the pattern fitted to the crossing;
  - amber lines: the plain piece;
  - dimmer while it still follows the cursor;
  - small white spheres: shared points; red spheres: loose ends;
  - one red sphere at the cursor where nothing can be placed.

  The hint line under the card says what right-click will place. The old drawing expected a build or
  clear preview and would have thrown on a place preview in game; place now never reaches it. The real
  draw routine runs clean offline on both shapes and the plain piece.
- **First in-game look** (build 444, 2026-10-05; results on the test page): no errors in the log.
  - **Passed:** the card, the refusal at an uncleared j11, the mod X and smooth X at j11 (on the ground,
    one undo each), and the mod T and smooth T at j9. A mod T also placed at j2.
  - **Skew:** at j9 (side road about 12 degrees off square), both shapes stay square to the main road,
    so they don't follow the side road. The smooth T's right curve meets the side lane badly.
  - **j3 failed:** the plain T went in, but its side arms didn't reach the angled side road (2 loose
    ends). In the game's network the fit stopped at "2 lane ends, 1 lane start", not at the angle as
    offline, but either way the square piece can't reach a road 30 degrees off.
  - **Locked vs following:** the brightness change isn't noticeable.
  - **j2:** another road leading into the area near the junction gave trouble.
- **Skew, offline** (2026-10-05). The piece leans to the side or cross road's real angle, up to 45
  degrees off square, for the fitted pattern (both shapes) and the plain piece alike:
  - The frame has two directions of its own, one along each road. Straight paths stay straight and
    curves stay tangent to the lanes they join.
  - Each corner cut starts and ends a quarter lane gap from the corner in metres along each lane, so its
    two bends stay equal. At 45 degrees the worst bend on any turn is 68, under AutoDrive's 80; with the
    mod's fixed positions it would have been 90.
  - The plain piece takes the main road from a lane that runs on past the cursor (a side lane can't be
    the main road), and its lane gap from the opposite lane nearest in a straight line (a curving road
    read short before).
  - The lock now shows: following the cursor is thin and faint, locked is full width and bright.
  - j9 leans 14 degrees, j3 29 degrees: both fit now, every end joined. All 75 (identical on repeat):
    43 fitted, 26 plain, 6 refused (the same where the clear leaves wiring), 0 errors, 66 loose ends at
    23 junctions. Before the lean: 32, 37, 6, and 74 at 27.
- **Second in-game look** (build 446, 2026-10-05): j9 good in both shapes. j3 failed again (the lean
  went the wrong way and the lock moved with the view); j7 wasn't seen as leaning; at j2 the clear left
  another branch unconnected. The save hadn't changed since 27 September, so the network matched
  offline. The differences came from WHERE the click landed:
  - **The click picks the junction:** pointing anywhere on a junction the clear knows, place works from
    that junction's own centre, as the clear does. j3 now gives the same mod T from three click spots.
  - **The side road is a pair:** a lane in and a lane out running opposite ways, a lane gap apart. A
    stray end the clear left nearby (as at j3 in game) is ignored instead of stopping the fit. The plain
    piece also leaves ends running along the main road out of its lean.
  - **Limits from AutoDrive's 80-degree rule on the mod shape:** a T to 50 degrees off square (worst
    bend 72; at 55 the sharp left bends 81), an X to 35 (its lefts run corner - centre - corner, worst
    73; at 45 it would be 90). j7 is about 47 degrees off: it fits now.
  - A skewed road is now reported as skewed, not as "no main-road lane"; the plain piece's debug line no
    longer fills the log on every cursor move.
  - All 75 (identical on repeat, both shapes): 47 fitted, 22 plain, 6 refused, 0 errors, 61 loose ends
    at 20 junctions.
  - Not done: j2's other branch. The clear leaves it unconnected and place doesn't join it.
- **Third in-game look** (build 447, 2026-10-05): j3 and j7 fit and leaned right in both shapes, no
  errors. Still to fix: the preview slid about off a junction (and cost time doing it), locking far from
  the centre moved the piece, a "frame" line logged on every preview, and j66's two-way side road wasn't
  joined. Fixed offline:
  - **Only on a junction.** Off a junction place does nothing and says "point at a junction". On one,
    the piece is worked out from the junction's own place (the clear's finder, or else the numbered
    list, which keeps a junction's place after the clear has emptied it), and the pick is remembered
    per 2 m of cursor travel.
  - **Two-way side road (one road both ways):** the mod T splits it into its two lanes at the mouth
    (lane out -> road end -> lane in): j4 and j65 fit now. Smooth needs two real side lanes, so it falls
    back to the mod shape. The plain piece joins its side arms to a two-way road end too, but only where
    every bend is under 80 degrees: j66 (a Y about 60 degrees off square) would double back, so its
    arms stay loose.
  - The frame line is logged only when placing.
- **Fourth in-game look** (build 448, 2026-10-05): all 7 passed, no errors. Nothing drawn off a
  junction, no lag; j3 placed the same leaning T locked from either edge; j11 the same X locked from a
  corner; j66 refused for its two-way road. j2 was refused too, which is wrong for it (see the j2 test
  case under two-way roads).
  - All 75 (identical on repeat, both shapes): 49 fitted, 20 plain, 6 refused, 0 errors, 54 loose ends
    at 18 junctions. Not yet: a two-way MAIN road (j24).
- **Two-way roads: TABLED** (decided 2026-10-05). How two-way roads should join a placed piece needs its
  own research first. Until then place refuses any junction where a road running both ways meets: "a
  two-way road meets here - two-way roads aren't handled yet". This is the one exception to "never
  refused".
  - The two-way side road work above stays in the code, switched off
    (`FLYOVER_JUNCTION_PLACE_TWO_WAY = true` brings it back): the mod T splitting a two-way side road
    into its two lanes at the mouth, and the plain piece joining its side arms to a two-way road end
    only where every bend is under 80 degrees.
  - Refused for it on the 75: j2, j4, j24, j31, j65, j66, j69, j70, j71, j74. (j2 placed fine in game
    on build 447; its nearby branch is probably the two-way road.)
  - Open questions for the research: one two-way road splitting into a piece's two lanes, a two-way
    MAIN road (j24), a Y far off square (j66), and AutoDrive's two-way rule (on a two-way link it
    stops checking for traffic, doc 05).
  - **Test case for advanced behaviour: j2** (user, in-game test of build 448, 2026-10-05). j2 is a T;
    the two-way road beside it is a SEPARATE junction. Place should still lay j2's T and ignore the
    two-way street entirely, not refuse. The refusal today is wrong for j2. Distance can't tell them
    apart: j2's two-way road comes within 4.1 m of its centre, as close as the real two-way side roads
    at j4 (3.8 m) and j65 (3.5 m). Telling "a separate junction next door" from "this junction's own
    side road" needs a junction's roads to be known by what they join, not by how near they are.
    Ties in with the clear's own separate-junction work (junction-rework).
  - All 75 with two-way refused: 46 fitted, 13 plain, 16 refused (10 two-way, 6 wiring left by the
    clear), 0 errors, 32 loose ends at 11 junctions.
- **j2's other branch, decided** (2026-10-05): it is a separate junction and must not affect the main
  one. Place ignores it: it never joins it, never bends to it, and leaves it for you to hook up by hand.
  Recognising a separate junction nearby, and not cutting it loose in the first place, is the clear's
  job (junction-rework), not place's.

## Not in this plan

- Clearing, and the old turn-by-turn builder.
- Fitting over existing wiring.
- Sizing from the paved area (swing wide).

## Decided (2026-10-05)

- **"Place" is a third mode on the junction card:** clear, build, place.
- **A crossing with turn wiring already there is refused.** The card says to clear it first. Place never
  deletes anything.
- **Never refused, never the old method** (see above): a plain piece with loose ends when it doesn't
  fit, and both the fallback and fitting harder are in scope. Loose ends are fine for now.
- **A route-check problem after placing is marked on the card, not refused.** The check is a
  self-check: it traces every way AutoDrive could drive through the piece and says if a route appears
  that we didn't mean, or a turn we laid can't be driven. (Follows from "never refused".)

## Decisions needed

- The build tool on this branch currently tries the pattern first and quietly falls back to the old
  method. Recommended: take that back out, so build is exactly junction-rework's and the pattern lives
  only in place.
