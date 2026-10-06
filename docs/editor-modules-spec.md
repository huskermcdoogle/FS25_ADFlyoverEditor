# Splitting the editor into modules

Status: draft for review, 2026-10-05. Nothing has moved yet.

## In short

- **What:** `scripts/editor/FlyoverEditor.lua` is one file of 29,600 lines. Split it into 30
  files, one per tool or junction stage, **without changing what any of it does.**
- **Why now:**
  - It hit a hard Lua limit today. One file can hold only 200 local names at once, and the merge of the
    placeable branch made 205, so the file would not load. Five `do ... end` blocks fixed it for now,
    with 21 names to spare. Both branches keep adding names.
  - Two branches editing one 29,600-line file makes every merge slow and risky.
  - Finding code, reviewing it and handing a piece to an agent all mean reading one giant file.
- **How we know nothing changed:** every move is one commit, and every commit must pass the full offline
  test set with output identical to the commit before, byte for byte. A compile check also proves that
  no helper lost its caller.
- **What it needs from you:**
  1. OK this plan and the file layout below.
  2. A freeze: while the split runs, no other branch edits the editor files.
  3. One short in-game check at the end of each phase.

## What is there today

| | |
|---|---|
| FlyoverEditor.lua | 29,573 lines, 493 functions (352 of them `ADFlyoverEditor:` methods) |
| file-level local names | 204 declared; peak 179 at once after today's `do ... end` blocks (limit 200) |
| junction code | 18,660 lines, 63% of the file (lines 9759-28418) |
| FlyoverHud.lua | 3,012 lines, 24 file-level locals: fine as it is, not part of this split |

**How tangled it is.** Methods (`function ADFlyoverEditor:foo()`) can move to any file freely: they hang
off one shared table. Only file-level `local` helpers tie code together.
- 97 of the 204 local helpers are used outside their own section.
- The editor tools (select, move, delete, smooth...) share little: 14 helpers in all.
- The junction code is the knot: its core section has 67 helpers, and 52 of them are used in the other
  junction sections.
- 19 of the shared helpers are **junction state that gets reassigned** (for example `jxJournal`,
  `jxStage`, `jxKeptRoad`, `jxLaySeq`). These cannot simply be copied into another file. They must become
  fields of a shared table. The full list is in Phase 1.

**Giant functions.** Some single functions are very long. They move whole and stay whole in this split:

| function | lines |
|---|---|
| updateJunctionPreview | 2,697 |
| junctionTidyLaneEnds | 1,574 |
| junctionTidyByPaths | 1,366 |
| junctionClassify | 1,002 |
| jxCheckTouched | 821 |

They are inside Lua's per-function limits: the most upvalues in one function is 19 of 60.

## Rules for the split

1. **Move code, don't change it.** Function bodies and their comments move as they are. The only edits
   allowed are:
   - each new file's header (its local aliases, below);
   - the 20 reassigned shared locals turned into table fields;
   - Prelude's file list;
   - the harness loader.
2. **One move per commit, every commit gated** (see Gates).
3. **Shared helpers.**
   - A file that provides helpers publishes them on one table, `ADFlyoverEditor.shared`, in a block at its
     end.
   - A file that uses them takes local aliases at its top (`local jxBegin = ADFlyoverEditor.shared.jxBegin`),
     so call sites stay exactly as they are.
   - Reassigned state can't be aliased: an alias would keep the old value. It becomes a field of a shared
     table first (Phase 1).
4. **No new global names.** Everything new hangs off `ADFlyoverEditor`, so the arming allow-list and the
   environment probe are untouched.
5. **Each new file is one unbroken stretch of today's file, and the files load in the old order**
   (Prelude's `EDITOR_FILES` list). So everything a file does when it loads still happens in the order it
   did, and a file only ever needs helpers from files above it. At load, a missing alias is said in the
   log with the file's name, not left as a nil that fails later.
6. **Modules move out from the end of the file backwards.** Lua code can only use a local helper declared
   above it, so what stays in FlyoverEditor.lua (always the top of the old file) never needs anything from
   a moved file. Every in-between state is a working editor.
7. **Size:** each file stays under about 120 file-level locals and about 3,000 lines. One exception: the
   junction preview is a single 2,700-line function and gets a file of its own.

## Target layout

| file | from (today's lines) | size |
|---|---|---|
| `FlyoverEditor.lua` (core: state, enable/disable, keys, escape, update) | 1-1970 | 1,970 |
| `tools/Menus.lua` (select mode: point, span, set and run menus) | 1971-2485 | 515 |
| `tools/Selection.lua` (setTool, chains, box, circle and freehand select) | 2486-3070 | 585 |
| `Draw.lua` (drawNetwork and its fallback) | 3071-3724 | 654 |
| `Mouse.lua` (mouse events, left and right press and release) | 3725-4417 | 693 |
| `tools/Move.lua` | 4419-5302 | 884 |
| `tools/ConnectDelete.lua` | 5303-6322 | 1,020 |
| `tools/TypedEntry.lua` | 6323-6992 | 670 |
| `tools/Smooth.lua` | 6993-7641 | 649 |
| `tools/Connections.lua` (name marker, connection options, spline connect) | 7642-8190 | 549 |
| `tools/Siding.lua` (divide, siding) | 8191-9164 | 974 |
| `tools/Ground.lua` (ground and the road-surface probe) | 9165-9758 | 594 |
| `tools/Appearance.lua`, `tools/Convert.lua`, `tools/Merge.lua`, `tools/FieldLoop.lua` | 28419-end | 263 / 296 / 540 / 56 |
| `junction/JxCore.lua` (journal, labels, shared helpers) | 9759-10619 | 861 |
| `junction/JxBuild.lua` (build, pattern, place) | 10620-12131 | 1,512 |
| `junction/JxFind.lua` (virgin form, where roads meet, real or faux) | 12132-12700 | 569 |
| `junction/JxDebug.lua` (debug capture) | 12701-13016 | 316 |
| `junction/JxRegistry.lua` (numbers, split decisions, part names) | 13017-13905 | 889 |
| `junction/JxPlaceCheck.lua` (the route check for a placed piece) | 13906-14079 | 174 |
| `junction/JxPreview.lua` (updateJunctionPreview) | 14080-16776 | 2,697 |
| `junction/JxSwept.lua` (swept prediction, corridors, kickouts, chains) | 16777-17992 | 1,216 |
| `junction/JxTidy.lua` (click, lane-end tidy, clear stubs) | 17993-19745 | 1,753 |
| `junction/JxRebuild.lua` (smooth rebuild, tidy by paths, integrity sweep) | 19746-21718 | 1,973 |
| `junction/JxClassify.lua` (kind, turns vote) | 21719-22867 | 1,149 |
| `junction/JxParts.lua` (split parts, cleared-site reading) | 22868-23624 | 757 |
| `junction/JxCheck.lua` (the clean-up checks) | 23625-26873 | 3,249 |
| `junction/JxCheckCard.lua` (check report, card record, twin turns) | 26874-28418 | 1,545 |

Where each file starts is set in `tools/modsplit/modules.txt` (one line a file, matched on the text that
opens it, so it survives edits). `python tools/modsplit/split.py plan` lists every file still to move:
its lines, the helpers it needs from above, the helpers files below it need from it, and what blocks it.
`JxCheck.lua` is just over the size target; it can be split at `jxCheckTouched` later if wanted.

## Phases

**Phase 0: tooling. No editor change.**
- The harness reads the module list from Prelude's `EDITOR_FILES`, the same list the game uses, so
  offline and in-game load the same files in the same order.
- `bundle.py` writes one-file snapshots of the editor, each module wrapped in `do ... end`. Today's tools
  that take one file (`FE_SRC`) and A/B comparisons keep working.
- `split.py plan`: the dependency report, from `modules.txt`. Re-run before every move.
- `split.py move`: moves the last module still in FlyoverEditor.lua to its file, writes the shared and
  alias blocks, unwraps any of today's `do ... end` blocks the cut goes through, and lists the file in
  Prelude. It refuses when a helper the module needs is reassigned. Never by hand.
- `gate.sh`: the gates below in one command.
- Checks per file:
  - `luac -p`;
  - a file-level local count;
  - the global-name diff: no new global read or write except the planned tables.

**Phase 1: shared state, in place.** The planner finds 19 reassigned junction state locals that cross a
file boundary (`jxJournal`, `jxStage`, `jxKeptRoad`, `jxTwinKeep`, `jxTwinHeld`, `jxWhy`, `jxWasLoose`, `jxCut`,
`jxExisted`, `jxInRespace`, `jxRespaceRun`, `jxBuildNew`, `jxCentreNode`, `jxLayLabel`, `jxLinkLabel`,
`jxNodeLabel`, `jxLaySeq`, `jxShallowJoins`, `jxSquaredJoins`). They become fields of one state table, still
inside the one file. One commit, gated.

**Phase 2: the tools at the end of the file out** (Field loop, Merge, Convert, Appearance). Low risk:
they need 1-4 helpers each. One file per commit.

**Phase 3: the junction code out (14 files),** from the last up: CheckCard, Check, Parts, Classify,
Rebuild, Tidy, Swept, Preview, PlaceCheck, Registry, Debug, Find, Build, Core. JxCore goes last and
shares 52 helpers with the rest.

**Phase 4: the tools at the top out** (Ground, Siding, Connections, Smooth, TypedEntry, ConnectDelete,
Move, Mouse, Draw, Selection, Menus). They need 1-4 helpers each.

**Phase 5: clean-up.**
- Check today's `do ... end` blocks are gone (the mover unwraps them as it cuts).
- Update the harness README and the build notes.
- Build the zip (`build_zip.py` already checks that every file Prelude sources is in it).
- In-game check.

**Not in this spec:** breaking up the giant functions. That changes code rather than moving it. It needs
its own tests and its own decision.

## Gates

`bash tools/modsplit/gate.sh` runs them, always against the commit before (a one-file bundle of it), and
everything must match byte for byte.

**Every commit (quick, about 4 minutes):**
- `luac -p` on every editor file, the main-chunk slot count, and the global-name diff: a helper that lost
  its local shows up as a new global name;
- the editor loads offline the way it loads in game (Prelude's list), with no missing helper;
- `reg75`, `reg75check` (both through-road modes), `regbuild`, `regplace` (exact).

**End of each phase (full, `gate.sh --full`, about 16 minutes):** all of the quick gate, plus:
- `reg75`, `reg75check` with the split registry (REGDIR);
- `reg75click`, `reg75undo`, `reg_extra`, `regnames` (99 ok);
- `regtwin`, `regplace` (smooth), `regmissed`, `dbgtypes`;
- the working tree's clear and check run twice, because node-keyed `pairs()` order can differ between
  runs.

The network is `graph_data.lua`, a fresh export of savegame6 (2026-10-05). `GATE_NETS` adds more.

Why quick is enough between phase ends: what can go wrong in a move is mostly caught before any test runs.
- A helper left behind: the global-name diff.
- Shared state copied instead of shared: the planner refuses the move.
- A file loaded too early: the load check.
- A change in what runs at load, and in what order: impossible by the move order.
The tests are the backstop.

**In-game check, end of each phase:**
- the log says every editor file sourced, with no errors;
- open the editor, and each tool card opens;
- clear j39, undo, redo;
- place on one junction;
- leave and re-enter the career.

## Branches

- **Before Phase 1,** merge or park every branch that edits the editor:
  - the placeable branch: merged today up to 31b7d0f, still active; pause it for the split, or merge
    again first;
  - the warning box branch: 1 commit, on hold.
  - main has no editor commits that junction-rework lacks.
- **During the split:** no edits to the editor files anywhere else.
- **After the split:** another branch ports its changes by function name. The move map says where each
  function went.

## Risks and what covers them

| risk | covered by |
|---|---|
| an alias taken before its provider loaded (nil at run time) | load order, plus a load-time line naming any missing alias; the harness loads the same list |
| shared state copied instead of shared | the reassigned-locals list (dependency report, re-run every move); those become table fields |
| a helper left behind, now read as a global | global-name diff per commit |
| a behaviour change hidden by a test that doesn't reach it | the full gate set, twice; the in-game check per phase |
| merge pain with active branches | the freeze, and porting by function name with the move map |
| speed | aliases keep helpers local; one table lookup at load time only |
