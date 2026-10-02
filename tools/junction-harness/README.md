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

## One build

    lua dbgbuild.lua X Z [turnRadius]            # today's builder, on the junction as it stands
    CLEARFIRST=1 lua dbgbuild.lua X Z            # clear it first (through roads kept), then build

Runs the real `applyJunction` through `harness.lua`'s `M.build()` (lock with `mode = "build"`
first). It reports points, links, two-way links and teal dots within 40 m before and after, plus the
turns laid and refused, and ends with a `COUNTS` line for a regression to collect. On a wired
junction today's builder usually has nothing new to lay, so `CLEARFIRST=1` is the useful case.

It also checks the build against doc 06's rules, counting only what the build added:

- **new two-way links;**
- **crossings without a shared point:** two links crossing away from their ends;
- **U-turn routes:** a route AutoDrive could take into the junction and out the way it came, under its
  80-degree rule.

A build that follows doc 06 scores 0 on all three.

## The build regression - run it TWICE

    bash regbuild.sh TAG

Clears and then builds every registry junction (the same list as reg75.sh), and writes one line per
junction to `regbuildTAG.txt` plus a summary: built, refused, Lua errors, turns laid and refused, and
the three rule counts. Run it twice and diff, as for the clear.

First baseline, today's builder on this branch (2026-10-02), identical on two runs:

    60 built, 15 refused, 0 Lua errors | 248 turns laid, 14 refused
    rules: new two-way links 1 at 1 junctions | crossings without a shared point 241 at 55 | U-turn routes 3 at 3

The crossings and U-turns are expected: today's builder ties each turn in on its own and adds no shared
points. They are what the new builder must bring to 0.

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
