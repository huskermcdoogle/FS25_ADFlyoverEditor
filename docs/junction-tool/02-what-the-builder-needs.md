# What the builder needs

*Draft 2, 2026-09-30. Working notes for us.*

[Why a clear tool](01-why-a-clear-tool.md) said why the clear exists. This page says what the **builder**
and the players need from it, so we can settle where the stubs end.

## What the builder does today

- **You point at a junction.** It uses the clear's junction picker, but nothing the clear works out
  after that.
- **It joins every lane in to every lane out,** except U-turns, and tests each turn: on pavement, clear
  of obstacles, drivable by a test truck and trailer. Failures show red.
- **Its "rebuild" setting deletes old turns on its own,** with none of the clear's limits.
- Decided 2026-09-20: the clear and the builder become one tool.

## What it needs from the clear

**Have:** one-way roads and right of way. Each new turn follows the lanes it joins.

**Partly:**

- **No teal dots.** Last measured 2026-09-20: 24 left at 14 of 60 junctions with through roads kept,
  18 at 11 with them off.
- **Both lanes of a road stopping together.** Only a warning in the log. It fired at 24 of 60 on
  2026-09-27 (not trusted yet).
- **Road width.** The clear reads it from the gap between a road's lanes. The builder doesn't use it.
- **A cleared T the builder can pick.** Cleared with through roads kept, it shows two lane ends. The
  picker needs three, so the builder works from where you point, or snaps to a hooked-up junction
  nearby.
- **A description of the junction.** The clear works one out, then throws it away. On a cleared site
  the builder re-reads the kind and parts from the lane ends alone, for its card.

**Missing:**

- **Room for the turns.** No number set. See below.
- **Heights.** The clear's new stub points are laid flat. Nothing reads slope or bridges. The Ground
  tool could supply heights.
- **The shape and size of each mouth,** and whether it is paved or dirt.
- **Obstacle types.** A sign and a tree refuse the same way.
- **A grade, and the best two or three fits.**
- **Which part each stub belongs to,** for a split junction.
- **Stub ends named by position,** since point numbers change with every delete.
- **Not covered yet** from page 01's list: main or secondary road, the turns before the clear, who made
  each road.

## Room for the turns

A turn needs lane to start on, back from where the two lanes would meet. The sharper the turn, the
further back it starts. At the 12 m radius:

| Turn | Starts this far back |
|---|---|
| 30° | about 3 m |
| 90° (square T) | 12 m |
| 120° | about 21 m |
| 150° (sharp side of a Y) | about 45 m |

A long truck and trailer also borrows lane: about 12 m before the turn and 17 m after, with the preset
truck; it depends on the truck. It can't do that on a side road that ends at a stub.

The builder stops following a lane at the next junction only while that junction still has turns. A
cleared neighbour is invisible to it.

## Player situations

- **Junctions AutoDrive made from the map.** Take the whole cluster of forks. Put the centre where the
  roads meet.
- **Hand-hooked junctions.** Loose scraps must not count as roads. A real road not hooked up yet does.
  The builder still joins scraps today.
- **Field entrances and driveways.** Must not count as a road or pull the centre.
- **Two junctions close together.** Clearing one must not eat the other. One junction or two is the
  player's call.
- **One-way roads.** About 95% of the roads into junctions on the survey map. Stubs keep direction.
- **Long trucks with trailers.** The trailer cuts inside the line. The truck and trailer test is not
  calibrated yet, and was never driven at a cleared junction.
- **Through roads not kept.** The lane between two cleared junctions stays loose. Tell the player.
- **Through roads kept at a crossroads.** Page 01 says keeping them is probably right for T's and Y's.
  At a crossroads both kept roads cross in the middle, and a shared point there still joins them.
- **Re-clearing a junction the tool built.** Its turns start up to about 30 m out. They are still its
  own.
- **Not handled yet:** a named destination inside a junction can be deleted; reverse roads; bridges;
  placeable junctions; multiplayer.

## Where the stubs could end

Today a side lane is cut back or carried on to the other road's edge line: its centre line plus the
gap between its lanes. A lane that never reaches one is left where it is. Pavement is not read.

- **The builder can shorten a stub** that reaches in past where its turn starts.
- **It can't lengthen one.** It starts the turn at the tip instead. The turns then split at the tip and
  bend a little tighter.

Still to settle for every stub: its heading, how straight its end is, and its point spacing. AutoDrive
sets corner speed from the angles between points, so spacing changes how fast a turn is driven.

The options, not decided:

1. **Edge of the pavement.** Good: follows the real road. Bad: we can't read pavement yet.
2. **The same distance on every road.** Good: simple, easy to grade. Bad: a Y's sharp side needs far
   more room than a square T, and a wide road gets the same as a narrow one.
3. **A mix.** For example: pavement edge, but never closer than a set distance; pavement edge on the
   main road, a set distance on side roads; or a set distance, cut short where the pavement ends.
4. **Set by the turn.** Depends on which turns a build makes, which is out of scope for now.

## Out of scope for now

- Which turns a build makes.
- Moving the centre away from obstacles (the builder's job).

## Decided 2026-09-30

1. **Stubs reach in; the builder trims.** The clear leaves stubs long, up to the edge of the other
   road's pavement. The builder cuts each one back to where its own turn starts.
2. **Through roads kept at a crossroads: an option.** By default nothing joins them where they cross.
   A setting lets the builder add the right joins at the box instead.
3. **The clear saves its description of the junction.** The builder uses it but checks it against
   what is on the ground, in case the player edited by hand since.
4. **The builder always works from the clear's centre and box,** not its own circle, even where nothing
   was cleared. One way of reading a junction for both.
5. **Signs count as obstacles,** with their own on/off setting.
6. **A named destination or reverse road inside a junction: ask each time.** Show what is there; the
   player picks keep, delete or cancel.
7. **Cutting and rejoining through roads (the j19 case):** talk it through after the rest of the plan
   is settled.

Ours to measure or propose first: how much straight lane a stub must leave; whether two lane ends are
enough to pick a cleared T; what happens to the builder's own "rebuild" delete. The handover can be
tried offline today; grading the turns offline cannot.

## Sources

- [Why a clear tool](01-why-a-clear-tool.md)
- docs/junction-plan.md (old plan and map survey)
- docs/swept-path-spec.md (truck and trailer tests)
- scripts/editor/FlyoverEditor.lua
