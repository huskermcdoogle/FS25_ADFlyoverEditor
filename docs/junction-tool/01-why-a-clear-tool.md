# Why a clear tool

*Draft 1, 2026-09-30. Working notes for us. To be polished for the GitHub docs later.*

The junction tool will do two jobs: **clear** a junction, then **build** it again. This page says why
the clear exists and what it must hand to the builder. Everything else in the plan follows from it.

## The problem

- **Junctions arrive messy.** AutoDrive fills a map from the map's own road lines. At junctions that
  gives clusters of forks a few metres apart, lanes that cross, points on top of each other, and loose
  pieces that go nowhere.
- **Hand fixes pile up.** Players hook things up by hand over time, and each fix adds more of the same.
- **You can't build a clean junction on top of an old one.** New turns would join the old ones, and
  AutoDrive would drive whichever it liked.
- **Clearing by hand is slow and easy to get wrong.** A junction holds dozens of points. Miss one link
  and the roads are still joined. AutoDrive's own teal "merge" dots once found 24 missed links across
  14 of 60 junctions that our own checks called clean.

## What the clear hands the builder

1. **An empty middle.** Nothing inside joins one road to another. No teal dots left.
      - we need to make a call as to whether leaving through roads on is a good idea or not
      - Likely yes on T's and Y's but 4w is another story.  If we do for the 4w cases, we may need to connections to the crossing path, either adding them at the "box" or making sure there are none. May end up being an option.

2. **Stubs.** Every lane that enters or leaves ends at a known point, facing a known direction, level
   with its partner lane.
3. **A description of the junction:**
   - its centre;
   - which road is the main road;
   - what kind it is (T square, T skew, Y merge, Corner T, crossroads);
   - the angle each side road joins at;
   - which roads are one-way.
   - what paved or dirt junciton approaches/mouths look like/shape size.
4. **Room between the stubs** for the turns the builder will add.
5. **Nothing else touched.** Roads past the junction stay as they were. With "through roads kept" on,
   the main road runs straight through unbroken.

This list is still open; we are probably missing something. Candidates to weigh:

- each road's type: main or secondary, one lane or two, so new turns match the road they join;
- a record of the turns that existed before the clear;
- the grade itself, and how sure the tool was;
- for a split junction, which part each stub belongs to;
- who made each road: the map, the player, or our tool.

## Why the clear has to get the centre right

The builder draws every turn from stub to stub, so the stubs decide the turns.

- If the centre is off, the stubs on one side sit too close. The turns get tight and trailers cut the
  corner.
- The stubs on the other side sit too far out, so the junction takes up more road than it needs.

So the clear places the centre and the stubs, then grades its own fit, before anything is built. When no
fit passes, it shows its best two or three and you pick.

## Other uses of the clear on its own

- Cleaning up a junction before hooking it up by hand.
- Finding out what the tool thinks a junction is (its kind, main road and centre) without changing
  anything.

## Still open

- **What the clear hands the builder** is probably incomplete. See the candidates above.
- **Removing a junction entirely**, for example a side road that is no longer on the map: possibly an
  option on the clear, or a separate tool. We have no clear case for it yet.
- ~~Where the stubs end.~~ Decided 2026-09-30: stubs reach in to the edge of the other road's pavement,
  and the builder trims each back to where its turn starts. See [What the builder needs](02-what-the-builder-needs.md).
- ~~Through roads kept at a crossroads.~~ Decided 2026-09-30: an option. By default nothing joins them
  where they cross.
