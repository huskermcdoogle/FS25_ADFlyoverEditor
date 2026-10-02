# Junction harness

Runs the mod's real junction code offline, against an exported AutoDrive network, so
a change to the clear can be measured across every junction on a map in a couple of
minutes instead of one junction at a time in the game.

Nothing here ships: `tools/` is excluded from the mod zip by `tools/build_zip.py`.

## Setup

Lua 5.1 and Python 3. Git Bash on Windows. Run everything from this folder.

Export the network from a savegame into `graph_data.lua` (git-ignored - it is your map):

    python export_graph.py "<FS25 profile>/savegame6/AutoDrive_config.xml" graph_data.lua

The harness loads `../../scripts/editor/FlyoverEditor.lua` by default, i.e. the code in
this checkout. Point it elsewhere with `FE_SRC=...`, at another graph with `GRAPH=...`,
and at another Lua with `LUA=...` (reg.sh). `RIG_TRAILER=11` matches the design rig.
`LEAVE=1` is "leave through paths" on - which is how it is usually played; test both.

## The regression - run it TWICE

    bash reg.sh TAG

Clears every junction in `sweep_all/junctions.txt` in both through-path modes and
prints points taken, worst reach, and any failures. Run it twice and diff the two
passes: the clear is deterministic, and if two identical runs disagree the
measurement is noise, not signal.

## One junction

    LEAVE=1 lua dbgstages.lua X Z          # the stage-by-stage account of one clear

## The check after a clear

Every clear checks its own work and only reports: it never undoes or refuses anything.
Check 1, "middle empty": no lane coming in on one road can drive out on another through
the middle, and no teal dot (AutoDrive's merge point) is left there. Check 2, "nothing
else touched": every change matches the clear's own record of its edits, stays inside
the junction, and no road that drove through has been cut.

    LEAVE=1 lua dbgcheck.lua X Z           # one junction: the check's log lines and card
    bash reg75check.sh TAG                 # every registry junction, both through modes

`reg75check.sh` writes `reg75checkTAG_1.txt` / `_0.txt`: one line per junction, then that
junction's problem lines, then the totals. Run it twice and diff, as with `reg75.sh` -
both runs must be byte-identical. The line reads:

    jN | joins N reason:n | dots N reason:n | other N kind:n | wrongBefore N | notes N | err=N

- joins and dots are split by the reason each was left for, worst first: `made` (the
  clear made it - a new link, or two points folded into one), `crossmade` (it joined the
  two kept through roads), `new` (a teal dot that was not there), `selfmade`, `tail` (the
  end of a turn it cut), `missed`, `nobox`, `through`, `part` (the other part of a split
  junction - its own wiring, left alone on purpose), `oneroad`, `selfjoin`, `crossing`.
- other problems by kind: `through` (a road cut), `stub`, `flip`, `spur` (a lane split into
  dead ends), `leftover` (the start of a turn it cut, left hanging off a lane), `reach`
  (an edit outside the junction), and `link`, `moved`, `gone`, `new`, `vanished`,
  `stayed` for changes no part of the clear recorded.
- notes are not problems: the respacing re-laid road wholly outside the junction but
  within its own reach, which is measured along the lane from the lane's end. Whether it
  should do that is the user's call, so it is said and not counted.
- `err` counts Lua errors, including a step of the check that failed; such a junction
  shows `NO CHECK` and the card says the check could not run.

Two switches on `dbgcheck.lua` test the check itself:

- `THROW=snapshot|routes|keep|check` makes one step of the check throw. With it (or with
  `NET=1`) it prints the clear's total (`TOOK`), a checksum of the whole network (`NET`)
  and whether the clear's last steps ran (`ENDED`). Compare with a run without THROW: the
  clear must be identical, and the card must read "could not run".
- `WIRE=1` wires a lane end the clear laid to the nearest lane start it laid, recorded as
  the tidy's own edit, and prints `WIRED (a) to (b)`. The check must name it as a new join
  ("now joins ... joined by a link that was not there before the clear, from (a) to (b)"),
  with that same link, never as one the clear missed. Run it over every junction in both
  modes when the join rules change: at 38, 58, 63 and 65 the lane out was re-laid for
  50 m past the wired link, and only this showed the link being missed.

Reading a join line:

- "the lane in from the west" is a lane coming in; "the lane out to the north, from its
  start at (x, z)," is a lane that now starts inside the junction (the clear cut it there).
- Roads are named from where each lane lies exactly 30 m from the middle. Two lanes there
  within 7 m of each other are one road, so a drive back out along it is "turns back out
  along the same road". Known exceptions: 67 and 68 (test leftovers, lanes under 30 m)
  and 22's west road, which loops through a hairpin.
- "joins a road the clear did not count as one of this junction's" means the drive left
  on a road none of the clear's own lanes is on - not that the road belongs to another
  junction. At 40 it is the south-east road - the main road, by the user's reading - which
  the clear found no lane of, because it reads the main road as running west to north-east.
- `still` means the join drove before the clear too; `now` means it did not.

## Loop order: SHUFFLE and one junction after another

A clear renumbers the points above every one it removes, and a set keyed by point ids (or
by the points themselves) comes back from `pairs()` in an order set by those numbers (or by
memory). Wherever that order reached a choice, clearing one junction changed the clear of
its neighbour: clearing 30 and then 39 cut 39's road from the south. The editor now walks
such sets by place (`jxByPlace` in FlyoverEditor.lua). Two tests keep it that way:

    SHUFFLE=7 bash reg75.sh TAG            # any script: pairs() in a random order, fixed by the seed
    bash seqreg.sh TAG                     # clear A, then B, for every pair within 90 m

- `SHUFFLE=<seed>` (harness.lua loads `shuffle.lua`) walks every `pairs()` in a random
  order. Results must be byte-identical to a run without it, for any seed. A difference
  is a choice that depends on loop order.
- `seqreg.sh` clears junction A, then B, and compares B's result with B cleared on the
  fresh network, both through modes. It skips 67 and 68 (test junk) and the already
  cleared 69-75 (`SKIP=`); `NEAR=` sets the 90 m. `dbgseq.lua` prints each run by place,
  not by point number (`TOOK`, kept `ROUTE`s, the check's `COUNTS`, every `EDIT`), so two
  runs diff line for line. `seq<TAG>_1.txt` / `_0.txt` give one line per pair, `same` or
  `DIFFERS`, with how close A's own edits came to B's centre. Where A's edits reach B's
  roads, B cannot come out as on a fresh network (A shortened a road B keeps, say), so a
  difference there is not a fault in itself. Where A's edits stay clear of B, B must
  match. Run it again with `SHUFFLE=7`: every file must be identical.

## Click points: reg75click.sh

A clear of one junction must come out the same from any click inside it. The click is used once,
to pick the junction (`junctionSelect`); from there everything is measured from the junction's own
middle, so two clicks that pick the same site give the same clear. What can still differ is which
site a click picks: a few metres off the registry point can land on a neighbour, or on another
part of a split junction.

    bash reg75click.sh TAG                 # every registry junction, both modes, six clicks each

The six clicks: the registry point, 4 m east, west, south and north of it (`OFF=` sets the 4), and
the crossing the registry click's clear works on ("clearing the one at" in the log). Each run is
`dbgseq.lua` with `SITE=1`, which adds the site the selection locked and the crossing it cleared
(`SITE`, `CROSSING`) to its usual print-out (`TOOK`, `ROUTE`, `COUNTS`, every `EDIT` by place).
`reg75clickTAG_1.txt` / `_0.txt` give one line per junction: `same`, or `DIFFERS at` the clicks
whose output is not the registry click's, with each one's site (`same`, or where it moved to),
points taken and check counts. A difference with the same site would be the clear depending on the
click; with a moved site it is the selection picking another junction. `refused` means every
click was refused (already clear, say): nothing was compared, so it is not counted as `same`.
Skips 67 and 68 (`SKIP=`). Run it twice: identical.

What it can and cannot see: the click only picks the site, and the clear then works from the
site's middle, so on a given network two clicks that pick the same site give the same clear by
construction. A `same` line therefore says the selection is steady, not that the clear is right.
A fault that comes from the network itself - as j39's did, below - shows the same from every
click, and only on that network: run it with the drop's network as `GRAPH=`.

To run it on a network from a debug drop (the game's own, which can differ from the export: see
the j39 note below), export it with `export_route.py` and pass it as `GRAPH=`; a `REG=` file with
just the junctions wanted (lines of `n="39" x="6.9" z="-13.6"`) keeps it short.

j39, 2026-10: the in-game clear cut the main road and the harness's did not, from any click. The
click was not the cause: the game's network had two turns that cross inside 39 folded into one
point, 0.23 m apart, by an earlier clean-up. That point read as a fork and moved 39's middle 3.4 m.
Now a point where two lanes cross straight through is walked through, not read as a fork
(`jxCrossingPairs`, in `junctionCentres`), and the clean-up no longer folds two lanes that cross
(`jxLanesCross`, in `networkIntegritySweep`).

## Undo after a clear

`dbgundo.lua` loads the real undo (`scripts/editor/EditorHistory.lua`) over the harness's
stub, clears a junction, then undoes and redoes it, comparing every field of every point.

    LEAVE=1 lua dbgundo.lua X Z            # one junction: UNDO ok|FAIL pushed= changed= undo= redo=
    bash reg75undo.sh TAG                  # every registry junction, both through modes

A clear must leave exactly one undo step if it changed anything and none if it did not, and
undo must give back the network exactly as it was before the clear - cleaning included. Each
line ends with `after=`, a checksum of the network after the clear: the same junction run on
two builds with the same checksum was cleared identically. `EH_SRC=...` runs another copy of
the undo, as `FE_SRC` does for the editor.

`NOTHING_LEFT=1` makes the site read as having nothing to clear, so the clear cleans it and
stops (`stopped=yes`). No registry junction does that on its own; it is the one way a clear
changes the network without clearing anything, and that change needs its undo step too.

## Real ground (TERRAIN=1)

By default the harness sees road everywhere, flat ground at height 0, no fields and no
physics. `TERRAIN=1` swaps those for the real map, so the editor's own in-game reads
answer offline with the values the game would give:

- `getTerrainAttributesAtWorldPos` - colour, softness, materialId of the main paint per
  1 m cell (the savegame's `terrain.lod.type.cache`, layer attributes from `mapUS.i3d`)
- `getVehicleNavigationMapCostAtWorldPos` via `g_currentMission.aiSystem.navigationMap` -
  the AI drive-cost byte and blocked (255), from `vehicleNavigationCostmap.dat`
- `getTerrainHeightAtWorldPos` (bilinear), `getTerrainNormalAtWorldPos`, and
  `AutoDrive:getTerrainHeightAtWorldPos` - from `terrain.heightmap.png`
- `getDensityAtWorldPos` on `g_currentMission.terrainDetailId` - non-zero inside the map's
  field outlines (a stand-in for the field layer)
- `raycastClosest` - hits the terrain only (no road meshes, bridges, signs or trees offline).
  It is what lets the road check get past its "no physics, call it road" guard to the
  paint. `TERRAIN_RAY=0` keeps it nil.

Make the data once per map/save (pure Python, a couple of seconds, ~17 MB into the
git-ignored `terrain_data/`; `TERRAIN_DIR=...` points elsewhere):

    python make_terrain.py ["<FS25 profile>/savegame6"] [out folder]

Then any script takes it, e.g. `TERRAIN=1 bash reg75.sh TAG`. Loading adds about 0.12 s
and 15 MB per process. Look at the ground round a point, or test the road check:

    lua dbgterrain.lua X Z [R] [STEP]   # paint / cost / height / field / road grids
    lua dbgterrain.lua check            # isRoadAt at known spots: asphalt, verge, rock, field, gravel

Not offline: anything standing on the ground, and paint the player changed after the save
(the type cache is what the save wrote).

## Replaying a debug drop

A drop from `savegame6/flyoverDebug/NNNN_clear_.../` carries the network before and
after, the tool's log, and every setting it ran under. Replay it exactly:

    python export_route.py <drop>/pre.xml g.lua
    GRAPH=g.lua lua dbgreplay_cap.lua <drop> X Z

`dbgreplay_cap.lua` adopts the drop's recorded settings (via `adoptmeta.lua`) so the
replay runs on the game's values, not the harness defaults. `export_route.py` carries
the file's own incoming lists - rebuilding them from the outgoing ones changes their
order and silently drops a point wired to itself.

## Probes

`dbgrow.lua` AutoDrive's right-of-way rule - a cleared junction should leave none;
`dbgreach.lua` / `dbgdup.lua` / `dbgstub.lua` whether an approach is wired on, a
duplicate of another lane, or a dead end; `dbgshort.lua` / `dbgapproach.lua` spacing
near the box; `dbgcapture.lua` exercises the debug drop against stubbed engine calls.

## analysis/

Python, reading drops and saved AutoDrive route files directly. Paths default to
`~/OneDrive/Documents/My Games/FarmingSimulator2025`, else `~/Documents/...`; override
with `FS25_PROFILE`, `FS25_SAVEGAME`, `CAPTURE_DIR`. Every map is north up - FS25's z grows
SOUTHWARD, so small z is drawn at the top.

- `sweepcaps.py` - merges and short links before/after, for every drop in a folder
- `rowfile.py`, `rowtrue.py` - AutoDrive's right-of-way-centre rule on a saved network
- `asym.py` - links present in one direction only, and points wired to themselves
- `plotcap.py` - before/after SVG of a drop; `jmap.py` / `jzoom.py` - numbered map
- `jmap_live.py` - the whole network from the savegame itself, registry numbers, loose
  pieces in blue: `python analysis/jmap_live.py out.svg [numbers to highlight]`
- `deploy.ps1` - deploy a built zip, waiting for FS25 to exit, then relaunch and
  confirm the build from the log. Never copy the zip while the game is running.

## What the numbers do not tell you

Merge counts and short-link counts both called one junction perfect while one lane of
a road had been trimmed 13 m further back than its twin. Read the drop's `tool.log` in
full, and check a fix by whether it moves the thing it was aimed at.

## Site plots

- `dump_site.lua CX CZ R on|off out.txt [span]` - a site before and after a clear
- `plot.py out.txt out.png` - renders that dump as a before|after PNG (pure stdlib)
- `islands.lua CX CZ [R]` - every separate piece of network near a site, with its size
- `flood.lua SEED ID...` - which points a seed reaches, at several flood limits
- `dbgisland.lua CX CZ` - shrinks nearby loose pieces to fake debris, then clears
