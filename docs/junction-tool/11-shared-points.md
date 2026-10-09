# Shared points at crossings: what we should do (2026-10-09)

Where two lines cross, a **shared point** is the one place AutoDrive can see that two trucks will
meet. This page works out when to give a crossing one. The facts it rests on, from AutoDrive
3.0.1.4's code, are in doc 10; the numbers come from the registry junctions built with the swept
check on (`tools/junction-harness`, build of 2026-10-09). **Nothing here is built yet** - it is the
plan, for the user to decide on.

## The problem in one line

A shared point makes trucks wait for each other, but it also lets AutoDrive **switch** from one line
to the other there. With a two-way line, switching can open a back door: at j100 a truck on the road
could turn off at a crossing and drive back down a turn the trailer had been refused for.

## What the code says happens (doc 10)

**With a shared point:**
- The two trucks reach the point from different directions, so one of them waits (doc 10, fact 5).
- A truck on a two-way link never checks (fact 2), so the truck on the road waits for it.
- AutoDrive may route from one line onto the other there wherever the bend is 80 degrees or less
  (fact 9). A two-way line runs both ways, so every direction of it counts: only a crossing at 80-100
  degrees is closed both ways.

**Without a shared point:**
- The traffic rule never fires (fact 6).
- Only the front sensors are left. A truck stops for another truck once it is in the box ahead of it,
  along its own path (`VirtualSensors.lua` 292; `CollisionDetectionModule.lua` 42-87).
- At a shallow crossing the other truck comes in from the side, so it is seen late - a side swipe.
- If each truck sees the other in front, both stop. Nothing in the stop path times out
  (`DrivePathModule.lua` 354), so they stay stuck.

## One fact about our own turns that changes the picture

A two-way turn that ends on a road's one-way lane can never be driven backwards. Its link onto (or
off) the lane is one-way (the user's rule of 2026-10-09), so there is no way into it from that end.
Its only other way in backwards would be a shared point.

So on those turns, "two-way" does exactly one thing: the truck on it does not check, and keeps right
of way over the road's trucks. Making the turn one-way just across a crossing takes **no movement
away** - and it closes the back door.

Turns between two two-way roads (j101's kind) are different: they really are driven both ways, and
cannot be made one-way anywhere.

## Measured: the 39 crossings with a two-way line

At the 13 registry junctions where a two-way line crosses another line without a shared point today
(80-100 degree rule):

| The other line | Safe if the turn is one-way there | Unsafe either way |
|---|---|---|
| A road lane | 18 | 2 (2 and 57 degrees, both running the same way) |
| Another two-way turn | 10 | 1 (15 degrees) |
| A one-way turn | 4 | 2 (51 and 71 degrees, same way) |
| The two-way farm track itself | 0 | 2 (6 and 11 degrees) |
| **All** | **32** | **7** |

"Safe if one-way there": with the turn one-way across the crossing, the two lines run more than 80
degrees apart, so AutoDrive refuses to switch either way - the shared point is safe.

The 7 left are shallow crossings of lines running nearly the same way. The two with the farm track
itself (j90, j92) look like a fault in the turn's shape - a turn should not graze the track it leaves
- and want a look of their own.

## What we should do - the recommendation

1. **Give every crossing a shared point when AutoDrive can be stopped from switching there.** Trucks
   that can see each other beat a few metres of two-way line. A crossing without one is the last
   resort, and the card says so.
2. **A two-way turn that ends on a road lane goes one-way across each crossing**, in its own
   direction. That takes nothing away (above), and 32 of 39 crossings become safe to share.
3. **Start the one-way piece where the truck can still stop.** A truck only starts checking once it
   is on a one-way link (fact 2), and then looks 5 points ahead (fact 3). One link before the crossing
   is too late at speed; about two links or 8-10 m before it, and one link after.
4. **Turns driven both ways (between two two-way roads)** share a point only at 80-100 degrees. Below
   that, square the crossing up with a small S-bend in the turn (the old `FLYOVER_JUNCTION_SQUARE_CROSSINGS`
   code), or reshape the turn.
5. **The 7 shallow same-way crossings:** square them up to over 80 degrees, or leave them without a
   shared point and warn on the card. Look at j90 / j92 separately.
6. **Check every change** with the route check (routes we did not mean must not rise), the overlap
   count, and the traffic simulator (doc 09) before it reaches the game.

## What it costs

- At a crossing the turn's truck checks for traffic instead of keeping right of way: whoever gets
  there first goes, as everywhere else. The road still gives way to it at every other shared point.
- The user's rule "two-way all the way to the merge" (2026-10-09) gets an exception at crossings -
  **this needs the user's yes.**
- Squaring a crossing up puts an S-bend in the turn: slower there. In 2026-10-02 tests it added 20
  sharp bends across the registry, which is why it was switched off.

## Not known yet

- Whether two trucks stopped nose to nose at an unshared crossing ever free themselves in game. The
  code shows no timeout; a game test would settle it.
- How often a one-way piece starting 8-10 m before a crossing still leaves a truck braking hard. The
  traffic simulator can measure it.
