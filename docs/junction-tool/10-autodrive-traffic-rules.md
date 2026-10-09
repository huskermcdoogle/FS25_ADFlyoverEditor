# AutoDrive's traffic rules: what we know for sure

Read from AutoDrive 3.0.1.4's own code (the installed `FS25_AutoDrive.zip`) on 2026-10-09. Line
numbers are 3.0.1.4's. The traffic check is word for word the same as in 3.0.1.2. **Anything not on
this page is not proven** - check the code before building on it, then add it here.

## Facts, from the code

1. **How often a truck checks for other trucks:** every 20 frames (`AutoDrive.lua` 69,
   `PERF_FRAMES = 20`; the check is `CollisionDetectionModule.lua` 89-194, `detectAdTrafficOnRoute`).
2. **On a two-way link a truck does not check at all** (lines 95-100). If the link it is on right now
   runs both ways, it skips the check and counts as "not waiting".
3. **What it looks at** (lines 102-121): its next 5 points, then on for as long as the links stay
   two-way. So before it drives onto a two-way stretch, it looks along the whole stretch.
4. **Who it compares with** (lines 128-136): every other running AutoDrive truck, from 4 points behind
   to 4 points ahead of where that truck is.
5. **When it waits** (lines 150-153 and 169), all three must hold:
   - a point is on both trucks' lists;
   - they reach it from **different** points before it (a merge or a crossing - a "Y");
   - the other truck is not waiting itself.

   One truck following another along the same line does not trigger it. The first point on its own
   list never triggers it either (it has no point before it to compare).
6. **Lines that share no point never make anyone wait**, however close together they run.
7. **Two trucks both already on two-way links:** neither checks. Only the bumper sensor can stop them.
8. **The bumper sensor** (`VirtualSensors.lua` 292): looks ahead along the truck's path, speed in km/h
   x 15.5 / 40 metres, from a minimum up to 50 m, and stops the truck for whatever is in front of it.
9. **Routes** (`GraphManager.lua` 1023, `prepareWayPoints`): a route may come into a point and leave it
   only if it bends **80 degrees or less** there. Over 80 it is not a route (reverse driving aside).
10. **Speed in bends** (`DrivePathModule.lua` 583-597, per point): under 5 degrees full speed; 5 to
    30 degrees from 60 down to 12 km/h; 30 to 50 degrees 12 km/h; 50 degrees or more 3 km/h - all
    times the corner speed setting.

## What follows for junctions we build

- A truck on a two-way line keeps right of way. A truck on a one-way line that shares a point with it,
  coming from another direction, waits for it.
- A shared point lets AutoDrive switch from one line to the other wherever the bend is 80 degrees or
  less (fact 9). A two-way line runs both ways, so a crossing with one is only safe between 80 and 100
  degrees.
- Two lines going opposite ways with no shared point between them are a hidden head-on: nobody waits
  (fact 6).

## Decided by the user - the builder's rules

| Date | Rule |
|---|---|
| 2026-10-08 | Never two one-way lines on top of each other in opposite directions. |
| 2026-10-09 | Except a reverse track with a one-way track back out on top of it, as in parking. A tool for placing those comes later. |
| 2026-10-08 | A turn between two two-way roads is one two-way line. |
| 2026-10-08 | No shared point with a two-way line unless the angle stops AutoDrive switching onto it (80-100 degrees). |
| 2026-10-09 | Where a two-way farm track meets a road of one-way lanes, each turn is two-way as solved, all the way to the merge. Its link onto (or off) the road's one-way lane is one-way, so nobody can drive into it backwards from the road. |
| 2026-10-02 (replaced 2026-10-08) | No two-way turns: each direction one-way, tied at the two-way road's mouth. |

## Claims that were wrong

- **"A truck coming off a two-way turn would not give way when joining the road"** (2026-10-09).
  Overstated: that truck does not check (fact 2), but a truck on the road that shares the merge point
  waits for it (fact 5). The junction is still handled - the road traffic gives way.

## Not known yet

- How often two trucks driving onto one two-way stretch from opposite ends at nearly the same moment
  miss each other. The traffic simulator (doc 09) said about 2 in 100 runs; that is the simulator, not
  the game.
- With the 80-100 degree rule, 36 crossings at 13 registry junctions have no shared point (build of
  2026-10-09). AutoDrive does not coordinate trucks at those crossings. What to do about it is
  worked out in doc 11 (not built yet, needs the user's decision).
- A truck stopped by its front sensor stays stopped while the other truck is there; nothing in that
  path times out (`DrivePathModule.lua` 354). Whether two trucks nose to nose ever free themselves in
  game is not tested.
