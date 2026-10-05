# Junction harness

Runs the mod's real junction code offline, against an exported AutoDrive network, so
a change to the clear can be measured across every junction on a map in a couple of
minutes instead of one junction at a time in the game.

Nothing here ships: `tools/` is excluded from the mod zip by `tools/build_zip.py`.

## Everyday tools (fast)

One offline clear takes under a second; these run many side by side (PAR, default 16).

- `GRAPH=net.lua bash qc.sh 39 26 "24.5,1.3"` - quick check: clears the named junctions (or x,z
  points) in both modes and prints what the card and log would say, in seconds. Part names (j39se) come
  from a private copy of the savegame's junction file.
- `GRAPH=net.lua python show.py out.html 39 26` - one picture page: before/after each clear, both
  modes, north up, with a legend and the check lines under each picture.
- `python replay_session.py <log.txt> --net <pre.xml|AutoDrive_config.xml|.lua> [--since "2026-10-02 14:00"]`
  - reads a game log, finds every clear (lock point, mode, turn radius, what it took, what the check
  said) and replays each offline on its own debug capture's network when there is one, with the game's
  settings (ADOPT) and turn radius (TURNR). Says MATCH, CLOSE (same findings, points within 3) or
  DIFFERS. A DIFFERS is the first place to look after a test session.
- `bash ../testbuild.sh [commit] [--no-launch] [--dry-run]` - test build from committed code only, in a
  temporary checkout; checks the zip's editor file is the commit's; refuses while FS25 runs; installs
  and launches.
- `reg75.sh` / `reg75check.sh` - the full pass, about 30 s each since they run in parallel.

Harness switches these use: `ADOPT=<capture meta.txt>` (the game's settings), `TURNR=<m>` (the card's
turn radius, which the clear reads too).

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

Baseline, today's builder on this branch (2026-10-02), identical on two runs, with the map export of
2026-09-27 12:47:

    67 built, 8 refused, 0 Lua errors | 283 turns laid, 17 refused
    rules: new two-way links 4 at 4 junctions | crossings without a shared point 282 at 61 | U-turn routes 7 at 7

A junction the clear calls "already clear" is built as it stands. `bash whyrefused.sh TAG` gives the
reason for each refusal.

**Use the same network the registry was made from.** All 8 refusals above are a map mismatch, not the
picker:

- That export (12,524 points) is an older network than savegame6's `AutoDrive_config.xml` (12,873
  points, 2026-09-27 12:46), which the registry numbers.
- On the older export, the 6 sites j4, j24, j25, j31, j65 and j66 are plain road, with no fork within
  30 m. The placeable T and X (j67, j68) are not there at all.
- Exported fresh from the save, the picker finds all 8 within 2.4 m of their registry positions.

Baseline on the save's own network (export it with `export_graph.py` and point `GRAPH=` at it),
identical on two runs.

The checker was corrected 2026-10-02 in three ways:
- links are keyed by their point tables, not ids (removing a point renumbers the rest, which made old
  links look new);
- a two-way road split where a turn crosses it no longer counts as a two-way turn;
- crossings more than 2 m apart in height are bridges, not crossings.

So earlier figures are not comparable. With the corrected checker:

    today's builder (1caa96e):
    75 built, 0 refused, 0 Lua errors | 310 turns laid, 17 refused
    rules: two-way turn links 13 at 10 junctions | crossings without a shared point 284 at 66 | U-turn routes 10 at 7

    with shared crossings (step 1 of the new builder):
    75 built, 0 refused, 0 Lua errors | 310 turns laid, 17 refused
    rules: two-way turn links 17 at 12 junctions | crossings without a shared point 1 at 1 | U-turn routes 15 at 11

    after merging junction-rework a008a46 (corrected twin, wider road gate) into the new builder:
    75 built, 0 refused, 0 Lua errors | 319 turns laid, 19 refused
    rules: two-way turn links 10 at 9 junctions | crossings without a shared point 1 at 1 | U-turn routes 13 at 8

The U-turn figures above came from a guess in dbgbuild.lua: a route that left the 30 m circle heading
back the way it came in. Roads that bend or loop just past the junction fooled it. Since 2026-10-02 the
regression reads the **builder's own route check** instead (`junctionRouteCheck`, the `extra=` and
`routes=` columns). It counts lane-in/lane-out pairs AutoDrive could drive that were not meant, over
links the build laid. With step 1, after the merge:

    75 built, 0 refused, 0 Lua errors | 319 turns laid, 19 refused
    rules: two-way turn links 10 at 9 junctions | crossings without a shared point 1 at 1 | extra routes 27 at 14 (of 432 routes; 4 junctions with no route check)

`NOSHARE=1` builds without the shared crossings: 17 extra routes at 8 junctions.

After two-way roads to the mouth (2026-10-02), identical on repeat:

    75 built, 0 refused, 0 Lua errors | 318 turns laid, 20 refused
    rules: two-way turn links 0 at 0 junctions | crossings without a shared point 1 at 1 | extra routes 26 at 14 (of 439 routes; 4 junctions with no route check)

After the shared point SLIDES instead of snapping (2026-10-02), identical on repeat:

    75 built, 0 refused, 0 Lua errors | 318 turns laid, 20 refused
    rules: two-way turn links 0 at 0 junctions | crossings without a shared point 0 at 0 | extra routes 18 at 10 (of 447 routes; 4 junctions with no route check)
    speed: sharp bends on our turns: 0 at 30-50 deg (12 km/h), 0 at 50+ (3 km/h) | links under 0.3 m: 50

The old snap (run a path through any point within 0.75 m) gave 194 sharp bends on our turns, 124 of them
past 50 degrees, where AutoDrive crawls at 3 km/h. 14 of the 18 extra routes left have no sharp switch:
they go round the block on existing roads. The `speed:` line counts, on the build's own turns, points that
bend 30 degrees or more (`SHOWKINK=1` lists them). `HOPS=1` traces where an extra route switches paths,
`NODEAT=x,z` prints every in/out pair at one point. `SQUARE=1` turns on the S-bend (off by default),
`SNAP=m` sets the snap distance, `TURNR=m` the turn radius.

After the pattern builder (doc 07, 2026-10-03), `PATTERN=exact` (the default, as in game):

    75 built, 0 refused, 0 Lua errors | 318 turns laid, 20 refused
    rules: two-way turn links 0 at 0 junctions | crossings without a shared point 0 at 0 | extra routes 19 at 10 (of 448 routes; 4 junctions with no route check)
    speed: sharp bends on our turns: 0 at 30-50 deg (12 km/h), 56 at 50+ (3 km/h) | links under 0.3 m: 38
    pattern placed at 7 junctions (the rest laid turn by turn) | turns laid but not drivable: 46 at 33

- The pattern places only at square X's (7 of 75); the rest are built turn by turn as before.
- The 56 sharp bends are the mod X's spokes counted against each other (corner -> centre -> next
  corner, 90 degrees), which AutoDrive never drives. Not a real speed cap.
- "Turns laid but not drivable" is new: a turn the build laid that no route can drive under the
  80-degree rule. 44 of the 46 are at junctions built turn by turn, and are there with or without
  the shared points (j5). The other 2 are the mod X at j55 and j56.
- `PATTERN=smooth` places the smooth X where it fits (the mod X where a lane bends away too soon);
  `PATTERN=off` is the old builder. `SHOWMISSING=1` lists the turns that cannot be driven and the
  bends that stop them. `dump_build.lua` + `../xt-study/drawbuilt.py` draw what a build laid.

With the T pattern too (2026-10-03), identical on repeat:

    75 built, 0 refused, 0 Lua errors | 318 turns laid, 20 refused
    rules: two-way turn links 0 at 0 junctions | crossings without a shared point 0 at 0 | extra routes 21 at 10 (of 468 routes; 4 junctions with no route check)
    speed: sharp bends on our turns: 48 at 30-50 deg (12 km/h), 58 at 50+ (3 km/h) | links under 0.3 m: 25
    pattern placed at 32 junctions (the rest laid turn by turn) | turns laid but not drivable: 34 at 20

- 7 X's and 25 T's take the pattern. Of the 34 undrivable turns, 5 are at pattern junctions (j2, j55,
  j56) and 29 at junctions still built turn by turn.
- The 48 bends at 30-50 degrees are the mod T's 45-degree corners (12 km/h, as in the mod).
- Why the rest fall back is in the `why=` column. Skewed T's (more than 15 degrees off square), T's whose
  side road is one two-way road or one-way, and X's where the clear kept only one through road.

The two-way column now counts only links whose point has BOTH its links two-way, which a two-way turn
has. A two-way road's new end, where a turn joins it, has one two-way link and one one-way, and is not
counted. `SHOWDUAL=1` lists them. A junction with nothing
new to lay stops before the route check, and shows as `extra=-1`. `SHOWPATH=1` prints each extra route's
path, with the bend at every point.

What is left, and why:
- The one crossing left is j55, a tangle of points a metre apart. The build logs that its crossings did
  not settle.
- Two-way turn links rise only because a shared crossing splits a two-way turn in two. Those turns go in
  a later step (two-way roads end at the mouth).
- The U-turn routes rise because shared points give AutoDrive more places to switch paths. The route
  check deals with them next.

To compare against an older builder, point `FE_SRC=` at a saved copy of it.

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
  end of a turn it cut), `twinstuck` (a turn of the other part's that the clear recorded before
  it cut anything and left, but that is broken - its start gone, cut part-way, or with no way in
  or out: "j39se's turn, left for j39se, but it does not drive now"), `missed`, `nobox`,
  `through`, `part` (the other part of a split junction - its own wiring, left alone on purpose),
  `twinwait` (such a turn, whole, whose only way on or off is this clear's cut lane, with through
  roads off: "j39se's turn, left for j39se: it waits for the build"), `twin` (such a turn that the
  check followed end to end and that drives now: "j39se's turn, left working"), `oneroad`,
  `selfjoin`, `crossing`.
- other problems by kind: `twin` (a turn of another part's, recorded by the clear, that does not
  drive now: its start gone, cut part-way, nothing leading onto it, leading nowhere, or reached
  only over this clear's cut lane, or leading only into it - with through roads off),
  `through` (a road cut), `stub`, `flip`, `spur` (a lane split into
  dead ends), `leftover` (the start of a turn it cut, left hanging off a lane; a way it left
  leading nowhere, or fed by nothing, that led on before the clear; or a scrap of wiring, at
  most 8 points and under 15 m end to end, cut loose and joined to nothing),
  `reach` (an edit outside the junction), and `link`, `moved`, `gone`, `new`, `vanished`,
  `stayed` for changes no part of the clear recorded.
- notes are not problems: the respacing re-laid road wholly outside the junction but
  within its own reach, which is measured along the lane from the lane's end. Whether it
  should do that is the user's call, so it is said and not counted. Also, with a split saved
  and through roads off, "the road between j20s and j20n ... is left as a piece of main road for
  the builder to join to - on purpose": a plain run from a lane start to a lane end lying
  between this part and another, which is what is left of the road between once both parts
  are cleared (the user's rule 2).
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
- A turn of another part's that the clear leaves working inside this part's area (39se's right
  turn off the main road at (9.9, -7.4) and its teal dot at (12.1, 6.3), when j39 is cleared with
  the user's split saved) used to read as `missed`. It now reads "j39se's turn, left working"
  (`twin`) - but only for a turn the clear listed as that part's before it cut anything
  (junctionTwinTurns: the selection's foreignWiring, or a run of plain points from this part's
  through road to a fork on a road that is none of its lanes), only where the check followed it
  end to end (jxCheckTwin), and only where the join's own turning is that turn, the rest of the
  drive being road (the drive may stop on the turn where a lane out's walk reaches it: 20n on
  live.lua). A turn this part's clear takes as its own is never on that list. "Left working"
  means it drives now. With through roads off such a turn is reached only over this part's cut
  lane (or leads only into it), so it reads `twinwait` ("... it waits for the build - the only
  way onto it is this clear's cut lane, 4.9 m long - it can drive again once j39 is built"), and
  the same turn is also a note of kind `twinwait` - not a problem (the user's call of 2026-10-05,
  option b; round 1 called these "left working", round 2 a problem). A turn that is broken reads
  `twinstuck` and is a problem line of kind `twin`. See "Split junctions: one part, then its
  twin" below.

## Missed turns at split junctions: missed.lua, regmissed.sh

The check names a join "another part's own wiring" when the turn it runs over is nearer another
part's meeting point - which, read wrongly, hides a turn this clear missed. So every turn of every
part is missed on purpose, one at a time, and the check's verdict on each is listed:

    LEAVE=1 K=3 lua missed.lua X Z         # keep piece 3 of the clear's own turn wiring at X Z
    bash regmissed.sh TAG                  # every part in split_decisions.txt, both modes, every piece

`missed.lua` groups the clear's turn wiring into connected pieces (in a fixed order, by place), and
the clear refuses the kept piece's points at its one remover, jxRemove, as the bound refuses a point
outside the junction. It prints the check's verdict on every join that runs over the piece
(`PIECES=1` counts the pieces, `PATH_OUT=1` prints each join's drive), and where no join runs over
it, what the check said of it instead ("said as leftover at ...": a leftover or spur line at one of
the piece's points, or naming one; "said as dot:<reason> at ...": a teal dot on one of its points, on
a point linked to one, or naming one as where a cut turn's end starts). `regmissed.sh` makes the
user's decisions into a junction file as regnames.sh does (`OUT=`, default `regmissed_out/`) and writes `regmissed<TAG>.txt`: a line per part,
setting and piece, then the totals. A join read as `part=jNNx` (or `twin=jNNx` / `twinstuck=jNNx`,
another part's turn left by the clear) is a missed turn the check passed as another part's - unless the kept piece is not the turn the join turns on (a join that only touches
the piece's end, or a kept piece that is really a stretch of main road the clear counts as wiring);
read such a line before calling it a fault.

On the network the regressions run on (2026-10-03): 92 pieces, 64 with no join over them (43 of
those said as a leftover, a spur or a teal dot, and 1 only by a dot read as another part's), joins
over them 16 missed and 11 read as another part's - at 20s, 39se, 40w and 40e. At HEAD 2a81bef: 91
pieces, 57 with no join (32 said), 18 missed, 14 another part's. 21 pieces are still passed in
silence (25 at HEAD), all but one with through roads off; none of them was said at HEAD, and every
turn HEAD said as missed is still said. The check reads whose a turn is by where it turns, and that
is not settled yet (split-part clearing, decided 2026-10-03, not built); this is the measure for
it. With split-part clearing built (2026-10-05 round 2, live.lua; a dot read as another part's turn,
`dot:twin` / `dot:twinstuck`, now counts with `dot:part` as no report, and a join read as
`twin=` / `twinstuck=` with `part=`): 61 with no join (43 said, 2 only by another part's turn's dot),
17 missed, 14 another part's (HEAD + the angle experiment, counted the same way: 64, 43, 1, 16, 11).
Nothing HEAD said goes silent. Where a line moved to another part's turn, the join's turning is
that turn and the kept piece is main road the clear counts as wiring, or is touched only at its end:
20n (through roads off) piece 1, the south lane's last 3 points, was the false "missed" of round 1;
40e piece 1 (through roads off) touches 40w's turn only at its first point, and HEAD's "made" there
was the check misreading the pre-clear clean-up's fold (fixed in jxJoinWas); 39 piece 3 (through
roads off) is the south-east lane, touched at the point 39se's turn is fed from; 39se piece 5 and
40e piece 1 (through roads kept) were "part=" at HEAD. The hook is held in a global: Lua 5.1's debug.setupvalue keeps no hold on what it sets, and
without one a run segfaulted part-way through the clear.

Four switches put back what the clear and its check did before the j39 fixes of 2026-10-02 and
2026-10-03 (all default on; `=0` turns one off, for the harness only):

- `PART_CONNECTORS=0`: a lane from one part's side road across the main road to another part's is
  kept as a through road. At j39 (the session network of 2026-10-02, the user's decisions, through
  roads kept) the north road's southbound lane then stays, and 39se's right turn off the main road at
  (9.9, -7.4) no longer drives.
- `SIDE_DUPES=0`: the tidy carries a "side road" to the box even where its whole lane in, from its far
  end to where it is cut, is a through road's own lane. Clearing 39 and then 39se (session network,
  both with through roads kept) then lays a 4 m dead end beside the main road from (12.5, -5.6), and
  the check says nothing of it. At 3 (session network, turn radius 2, through roads kept) it laid a
  19 m copy of the main road's lane, ending in a dead end.
- `RUN_STRAIGHT=0`: the "same lane twice" test walks a lane on past its anchor by the nearest point
  further out, not straight on at a fork. At 39 that took the north road's northbound lane round a
  turn at its anchor, called it a stub, and left it out of the side roads: cleared, it started 10.9 m
  from the main road while its twin ended 2.7 m from it.
- `LOOSE_ENDS=0`: the check no longer says a way the clear left leading nowhere, or fed by nothing,
  that led on before the clear. With the north road's lane now carried to the box (above), j39's own
  turn from the main road onto the north road, kept on purpose by missed.lua, leads nowhere: the
  point it led into went with the lane's old start. Nothing then drives over it, and without this
  line the check said nothing of it at all.

## Split junctions: one part, then its twin (dbgtwin.lua, regtwin.sh)

The user's rules for clearing one part of a split junction (2026-10-03, doc 04, "Split junctions:
clearing one part"), built 2026-10-05:

1. The twin's turn inside this part's area is left working. Before it cuts anything the clear lists
   the twin's turns in its area (junctionTwinTurns) and nothing in the clear may remove them
   (jxRemove refuses them). With through roads off, where such a turn leaves or joins a through lane
   inside the box, or within `JX_TWIN_LEAD` (5 m) of it, the lane is kept from that point on away from
   this part's middle and for 5 m towards it, and is cut there instead: this part's stub on that side
   is longer. At 39 the main road's lane out to the south-east now starts 4.9 m before 39se's right
   turn instead of the turn's own first point being cut away.
2. With through roads off, the road is cut and the box swept only on this part's side of the half-way
   line to each other part, so once both are cleared the road between them stays; the check says it
   as a note. Since the twin now stays wired, a click on a cleared part whose usual answer would be
   its twin (26: clear 26s, click 26s again - its lane ends lie within 15 m of 26n's forks) locks
   that part's own cleared site instead (junctionSelect; regnames.sh `clear26`).
3. One part at a time: there is no "clear all parts" on the card.
4. The check follows each listed turn end to end (jxCheckTwin) and calls it fine - `twin`, "left
   working" - only if it drives now: a way onto it and a way off it, each 60 m or as far as before
   the clear. With through roads off a turn of the twin's that runs through this part (fed from,
   or leading into, this part's middle) cannot drive until this part is built, whatever the clear
   keeps: it WAITS FOR THE BUILD - a note of kind `twinwait`, and a join or dot over it reads
   `twinwait` (the user's call of 2026-10-05, option b of doc 04). Any other turn that does not
   drive - broken, or with no way in or out at all - is a problem of kind `twin`, and a join or dot
   over it reads `twinstuck`.

`dbgtwin.lua` clears part A, then part B, and follows B's turns - as B's own preview reads them, so
independently of the clear's list - after each clear; `regtwin.sh` runs every ordered pair of parts
in split_decisions.txt, both settings:

    REGDIR=<folder> LEAVE=0 A=6.9,-13.6 B=22.5,0.1 lua dbgtwin.lua   # 39, then 39se
    REGDIR=<folder> GRAPH=<network .lua> bash regtwin.sh TAG          # every pair -> regtwinTAG.txt

A turn reads `drives`, `fromcut` / `tocut` (whole, and its way in starts - or its way on ends - at a
stub within 60 m: through roads off), `broken`, `nowayin` or `nowayout`. After A's clear dbgtwin
also says what A's check said of each (`AFTER_A SAID`): `MISMATCH` where a turn that drives is said
as a fault (a false "missed" or "made") or has a problem line, or one that does not drive is called
"left working", or a "waits for the build" note (`wait=yes`) is on a turn that drives or one that is
broken; `UNSAID` where one that does not drive gets no word at all (with how far it lies from A). A
`fromcut` / `tocut` turn is said by its waiting note and its `twinwait` join or dot (2026-10-05,
option b: same totals as round 2 on all three networks). On the session network, live.lua and graph_data.lua (2026-10-05 round 2, turn radius 12,
the user's decisions): 36 runs each, 8 refused as already clear (72 and 73); after the first clear
no turn `broken`, `nowayin` or `nowayout`; with through roads kept every turn drives (as at HEAD);
with through roads off 22-23 per network are `fromcut` / `tocut` (as many as at HEAD, where 5 of
them were broken or had no way in); MISMATCH 0 (HEAD + the angle experiment: 5-6; round 1: 14-15);
UNSAID 7-9, all through roads off and 7.6-19.4 m from A - turns of the twin hanging off the road
between (14, 39 to 39nw, 39se's main lane into 39, and two at 40, where the parts disagree about the
main road), outside A's area and so outside rule 1. HEAD: 26's second part refused too.

Two more switches (default on; `=0` turns one off, for the harness only): `TWIN_TURNS=0` drops
rules 1 and 4, `PART_ROAD=0` rule 2.

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

## Split junctions: the user's decisions and the parts' names

The game saves each junction's number, and the user's decision on splitting it, in the savegame's
`ADFlyoverEditor_junctions.xml`: `decision="split"` with one `<part name="39se" x= z=/>` a part,
`decision="whole"`, or nothing (not decided). The card offers the choice where the tool suggests a
split, once a click has locked the junction; a lock on a saved part is then called by it ("j39se") on
the card, in the log, in debug-capture folder names and in the check after the clear. The harness
numbers the map afresh and knows no decisions unless it is given a file.

A change of mind keeps the names. "Keep whole" and "not decided" set a split's parts aside: they
stay in the file as `<part>` lines under `decision="whole"` (or no decision), and "split" brings back
exactly those names at exactly those places. The card says so ("split brings back j39nw, j39,
j39se") and has one more button, "forget these names", the only thing that lets them go; after it a
split takes the card's fresh letters again. (Lettered afresh with 39se cleared, the two places left
at 39 were named j39nw and j39se - the user's j39 had become "j39se".) A part set aside still claims
a lock near it for its junction, and still stops the numbering handing a new number out there.

Numbers and decisions are only ever written into the folder they were read from, while that game is
still loaded. A decision made before a career's first save waits for that save; if the player loads
another savegame first (the old editor keeps getting update() until its files are sourced again), or
the game's folder changes, what was waiting is dropped and said so in the log, and the numbers are
read afresh from the game loaded now - never written over another career's file.

    lua split_registry.lua <junctions.xml> split_decisions.txt <out.xml>   # decisions into a copy
    REGDIR=<folder holding that file> bash reg75check.sh TAG                # any script, with them
    bash regnames.sh                                                       # the names' answer key

- `split_registry.lua` reads a junction file and `split_decisions.txt` with the editor's own reader
  and writer, and writes a copy with the decisions in it. It only writes the path it is given, and
  refuses one inside a folder holding `careerSavegame.xml`. To put it in the game: close FS25, then
  copy it over `<savegame>/ADFlyoverEditor_junctions.xml` (the game reads it once a session).
- `REGDIR` (harness.lua) makes the editor read that folder's file at its first numbering, as the game
  does; it refuses a real savegame folder. Unset, nothing changes. `dbgcheck.lua` prints `NAME`.
- `regnames.sh` (`OUT=` for its working folder, default `regnames_out/`): every part the user named
  names itself; cleared 72 and 73, whose halves share one middle, read as the bare number with
  "covers j72w and j72e"; the kept-whole junctions stay bare; with 39se cleared, 39 and 39nw keep
  their names and no new number appears, and with 39nw cleared 39se's check calls what is left at 39
  "j39" (lettered afresh it was "j39nw"); a part moved 3 m keeps its name, 6 m is "not at one of j39's
  parts" (the saved point is moved, standing in for a crossing that moved); the Y beside 39se that
  belongs to 30 stays "j30" (a saved part claims a lock only within 8 m); a cleared part covers a
  neighbour only when a click on the neighbour locks the same cleared site - never while the
  neighbour is still wired, however near; the decision buttons appear only once a click has locked
  the junction; a decision made before the career's first save is written by that save (the folder
  worked out from the slot number, then named by the save); with another game loaded before that
  save, or the folder changed under it, the other career's file is left byte for byte as it was and
  the names are its own (`switch`, `switchfolder`); 39, with 39se cleared, kept whole, not decided
  and split again comes back as j39nw, j39, j39se at the same places, the card says so, and after a
  restart too - and only "forget these names" makes a split letter it afresh (`decide1`, `decide2`);
  the file round-trips, with names set aside too, and the savegame's own file reads and writes back
  byte for byte unchanged; and split_registry.lua and the reader refuse what they must.
- An older junction-rework build (numbers saved, no decisions) reads a file with decisions without
  complaint, but the next time it gains a number it writes the file back with numbers only, and
  every decision is gone. Keep a copy of the file before running an older build on the savegame.

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

## The swept-path prediction (SweptSim)

`reg75.sh` never drives the design rig: it tests the clear, and the harness loads no SweptSim.
A change to `scripts/editor/SweptSim.lua` is measured with these instead. Build mode, rebuild
on, so each junction's turns are re-solved and the preset rig (`SweptSim.EXAMPLE_RIG`) is
driven through every one. With `TERRAIN=1` the road check is live, so the swept gate (trailer
off the road) and the sweep-wide reshape run too.

    TERRAIN=1 lua dbgswept.lua X Z         # one junction: each turn's cut-in, then a summary
    TERRAIN=1 bash sweptreg.sh TAG         # every registry junction -> sweptregTAG.txt

A turn refused with no curve at all (its last radius laid nothing) is listed as `no connector`.
`SWEPT_SRC=<file>` loads another SweptSim (an old copy from git, to compare). The summary
counts the twin's runs that hit their time limit (`out of time`) - a slower driver needs
longer to cover the same route.

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
