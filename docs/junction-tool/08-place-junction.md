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
