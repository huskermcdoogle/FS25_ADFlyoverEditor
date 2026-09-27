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
