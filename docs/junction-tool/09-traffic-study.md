# Traffic study: two-way or one-way, spacing (2026-10-07)

The user asked whether junctions should use two-way links on purpose, to make AutoDrive's waiting rules
work for us ("AD junctions built by us bulletproof, so long as the vehicles can make the turns"). This
answers it with a simulator, not a guess.

## How it was tested

- **The rules:** AutoDrive 3.0.1.4's own code, read line for line (`CollisionDetectionModule.lua`
  88-195, the bumper box in `VirtualSensors.lua`). A truck on a two-way link never checks and never
  waits; everyone else waits for it. Otherwise a truck looks 5 points ahead (further along any two-way
  stretch) and waits when another truck, within 4 of its own points, shares one of them coming from a
  different direction.
- **The simulator:** `tools/xt-study/adtraffic.lua`. Two trucks through every pair of movements, starts
  -10 to +10 s apart, both check orders. A run ends ok, **crash** (bodies overlap) or **stand-off**
  (both stopped for good).
- **The junctions:** a clean T and X of two-lane roads, laid by the editor itself: build, place
  (exact, smooth) and the plain X piece. Plus a T of single-track farm roads.
- **Limits:** trucks keep 20 km/h through the turns (AutoDrive slows down, so real crashes would be
  fewer); the trailer follows the path exactly; the bumper box follows the path. In-game driving tests
  must confirm it.

## Results

Crashes / stand-offs, big tractor rig (Fendt 900 + Big Body), 792 runs per T, 3168 per X.

| Wiring | T built | T exact | T smooth | X built | X plain |
|---|---|---|---|---|---|
| As laid | 16 / 4 | 6 / 2 | 8 / 2 | 64 / 8 | **0 / 0** |
| Main road two-way near the middle | 12 / 4 | 12 / 0 | 8 / 4 | 60 / 6 | 4 / 0 |
| Whole junction two-way ("box") | 16 / 0 | 4 / 0 | 12 / 0 | 80 / 0 | 0 / 0 |
| Points at least 3.5 m apart | 2 / 6 | **0 / 0** | 0 / 4 | 24 / 0 | **0 / 0** |
| Box and spaced | 2 / 10 | 0 / 0 | 6 / 2 | 56 / 8 | 0 / 0 |
| Semi (Transtar + SKS), as laid | 18 / 4 | 8 / 2 | 14 / 0 | 88 / 4 | 16 / 0 |

**Farm-track T** (every road one two-way lane), where trucks merge or split at the junction:
one-way turns 0 crashes, 8 stand-offs in 1476 runs; two-way turns 36 crashes.

## What it says

1. **Two-way on purpose does not make junctions safer.** Making the main road two-way near the middle,
   or the whole junction, never beat the best one-way layout and made the two best ones worse. The box
   trades stand-offs for crashes: trucks inside never wait, so two inside meet.
2. **Two-way turns on farm tracks are worse** than today's one-way turns. One-way turns still need the
   two directions on **separate lines**: today both lie on one line, and a truck waiting on its turn
   blocks the other (80 of 82 stand-offs when both want the same turn from opposite ends).
3. **Point spacing is the big lever.** AutoDrive looks 5 points ahead, so points 2 m apart give it
   10 m - less than a truck needs to stop. With points at least 3.5 m apart the exact T and the plain X
   had no crash and no stand-off at all.
4. **A merge must share its point where the two paths first come within a truck's width**, not where
   they finally join. The built junctions' turns run side by side for several metres before their
   shared point, so bodies touch before the point AutoDrive watches. This is most of what is left in
   the built T and X after spacing.
5. **Single-track roads cannot be made safe at the junction alone.** Two trucks already on one
   two-way road heading for each other always crash: neither checks. Only a one-way link before a
   two-way stretch makes a truck look along it.
6. **The long semi** still crashes on the plain X when both trucks arrive at exactly the same moment
   (16 of 3168, all at offset 0): both see each other in the same check and the one that waits stops
   too late. Wider spacing did not help; it is a limit of AutoDrive's tie-break.

## What the builder should do

- Keep turns one-way. Use two-way only where a road really is one lane used both ways.
- Space junction points at least 3.5 m apart (the plain X piece averages 3.8 m; our built X 2.3 m).
- Put each merge's shared point where the two paths first come within a truck's width.
- On farm tracks, give each direction of a turn its own line, with room to wait off the other's.
- Run every new layout through the simulator (all movement pairs, small, big and semi) before it ships.

## Done 2026-10-08 (150f2dd)

- **Spacing:** built turns and the smooth pattern are laid with points 0.4 x the curve's radius apart,
  up to 5 m, never so far that a point bends more than 25 deg (AutoDrive keeps about 20-25 km/h).
- **Place:** old lane points within 2.5 m of a new tie are taken out; the mod's shape is untouched.
  On build the same tidy traded crashes for stand-offs, so it is place only.
- **Merges zipped back** to where the paths first touch: tried, made the built X worse, not kept.

Crashes / stand-offs, before -> after:

| Junction | Big tractor rig | Small tractor rig |
|---|---|---|
| T built | 16 / 4 -> 2 / 0 | 18 / 4 -> 4 / 0 |
| T smooth | 8 / 2 -> 2 / 0 | 20 / 2 -> 6 / 0 |
| T exact | 6 / 2 -> **0 / 0** | 8 / 2 -> **0 / 0** |
| X built | 64 / 8 -> 24 / 12 | 84 / 8 -> 60 / 8 |
| X plain piece | 0 / 0 | 0 / 0 |

The placed patterns (exact T, plain X) are now clean for both tractor rigs. The per-turn built X is
still the weak one: 24 shared points against the plain X's 9, and its merges run side by side before
they join.
