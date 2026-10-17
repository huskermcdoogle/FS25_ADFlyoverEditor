# Multiplayer step 0 — results

2026-10-16, branch `claude/multiplayer-beta`. Step 0 of [`multiplayer-beta-plan.md`](multiplayer-beta-plan.md).
Tools in [`tools/mp-probe/`](../tools/mp-probe/README.md).

| Question | Answer | How sure |
|---|---|---|
| Does our own tag on a point survive AutoDrive's renumbering? | **Yes.** 0 failures in 7,000 random edits on a 17k network | Proven offline, AutoDrive's real code |
| How big is a whole-network push? | **~215–235 KB** at 17,174 points | Counted offline; exact figure needs one join |
| Can one FS25 message carry that? | **Not known yet** | Needs the in-game probe (two PCs, or a dedicated server + the game) |

---

## 1. Tags survive renumbering

`tools/mp-probe/tag_survival.lua` runs AutoDrive **3.0.1.4's own `GraphManager.lua`** (taken from the
installed `FS25_AutoDrive.zip`) against savegame2's network (17,174 points, 74 markers, both link lists as
stored). It puts a tag on every point table, then does random edits the way the one door will: delete,
add, move, link set, link clear, and AutoDrive's own `createSplineConnection`. A model that only knows
tags predicts the whole network; after every 50 edits all 17k points are checked against it: position,
flags, out list and incoming list in tag terms, in order.

```
seed 20261016, 2,000 edits: delete 592, add 337, move 389, set 291, clear 304, spline 81 -> 41 checks, 0 failures
seed 7,        5,000 edits: delete 1519, add 739, move 993, set 729, clear 732, spline 242 -> 101 checks, 0 failures
```

Why it works, from the code: `removeWayPoint` uses `table.remove` and rewrites `.id` on the tables that
shift, so the tables themselves (and any field we put on them) stay; `moveWayPoint` and
`setWayPointFlags` change a table in place; new points are new tables.

### Four things the door must handle (found here)

1. **A whole-network push makes new tables.** `setWayPoints` (join, `RoutesUploadEvent`, our reload)
   leaves every point without a tag (17,369 of 17,369 in the test). Tags must travel beside the graph.
   Cheap: a fresh session tags the loaded points 1..n, so the table is "1 run" plus one run per later add.
2. **AutoDrive's delete leaves a dangling link in one case, and renumbering rewires it.** If point P
   has incoming links of its own **and** a reverse link points at it (R.out has P, P.incoming does not
   list R), `removeWayPoint` does not look for R's link. After renumbering, R's link points at whatever
   took P's number. In the test it became a link from R to **itself**. This can happen in single player
   today. The door must clear every link to a point (including reverse links into it) before deleting.
3. **`createWayPointWithConnections(..., connect = true)` overwrites an existing slot** (`newId = out[1]`,
   then `setWayPoint`). Our editor never calls it (0 sites), but AutoDrive's own editing may. The safety
   net on the server must notice a replaced table at an index and tag the new one.
4. **Deleting one by one is slow.** At 17k points one `removeWayPoint` took **6.4 ms** (Lua 5.1 on this
   PC; the game may differ), because it renumbers the whole network each time. 300 deletes ≈ 2 s. The
   "tidy now" for held-back deletes must remove a batch in **one** pass (drop the tables, renumber once).
   That would also speed up big deletes in single player.

## 2. Whole-network size

`tools/mp-probe/size_estimate.lua` counts what `AutoDriveSync.streamWriteGraph` writes, field by field:

```
network: 17174 points, 42724 links (out+incoming entries), 74 markers; ids take 15 bits
without coordinates: 115 KB
  0.050 m: 16+15+16 bits per point -> 214 KB
  0.020 m: 17+16+17 bits per point -> 220 KB
  0.010 m: 18+17+18 bits per point -> 226 KB
  0.005 m: 19+18+19 bits per point -> 233 KB
tags, plain (32 bits each): 67 KB  - as runs: a few bytes
```

The one unknown is how many bits the game spends per compressed coordinate
(`NetworkUtil.writeCompressedWorldPosition` is not in the extracted scripts), so it is a range. Links are
half the size: every link is sent twice (out and incoming).

Edit messages in the new design (tags + undo info):

| Action | Size | Pieces? |
|---|---|---|
| Place a point + link it | 26 B | no |
| Drag with falloff, 21 points | 0.6 KB | no |
| Build a junction | 3.4 KB | no |
| Delete a run of 300 points | 10 KB | yes |
| Field loop, 800 points | 20 KB | yes |
| Box-move 2,000 points | 58 KB | yes |

## 3. Still to measure in the game

**`FS25_MPProbe`** (`tools/mp-probe/`, built with `build_probe.py`) is a tiny test mod: on a client,
`mpProbe all` sends one message each of 6, 64, 256, 512 and 1024 KB to the server and back, and both
logs say what arrived. That answers whether a 230 KB message works or must go in pieces. It needs two
peers on **two licences**: Giants' dedicated server guide (`dedicatedServer_en.pdf`, system requirements)
says a dedicated server needs its own licence and "You can't play with the same license key as a client
on a server", so this PC's dedicated server plus this PC's game is not an option. Ways that work: a
friend joins a game the user hosts, a second licence, or a rented server for a day. AutoDrive also logs
the real whole-network size on every join (`[AutoDriveSync] Written … bits`), so the same session gives
the exact number for section 2.

Until then the plan assumes the worst: **everything above 6 KB goes in pieces**, the whole network
included. If the probe shows 1 MB arrives intact, the pieces stay for edits and the whole network can
go in one.

---

## 4. Step 1: the one door (2026-10-16)

`scripts/editor/GraphOps.lua` describes an action as the difference between the network before and after
it, matched by tag: deleted points (with their old place in the order), added points (in order), changed
place/flags/field number, changed link lists (as tags), markers, groups - every entry with before and after.
`apply()` plays an action forwards or backwards: it reuses point tables, renumbers once, rewrites links once.

| Check | Result |
|---|---|
| `tools/mp-probe/door_check.lua`, 200 random actions of 1-25 AutoDrive edits on 17k points | 200/200 exact forwards and backwards |
| `tools/junction-harness/dbgdoor.lua` over all 101 registry junctions: clear (both modes), clear + build | 303/303 exact both ways |
| `reg75undo.sh` with undo now playing actions | 101/101 undo and redo exact, both modes |
| `reg75.sh` | identical to before the change |

Cost at 17k points (Lua 5.1 offline): describing an action ~26 ms, playing one ~12 ms, once per action.

"Exact" is strict: same number, tag, place, flags, field number, both link lists in order, markers.

## 5. Step 2: actions as bytes (2026-10-16)

`scripts/editor/ActionCodec.lua` packs an action to bytes and back, cuts the bytes into pieces of at most
6 KB, and joins them again (an action is only handed on when its last piece is in). Numbers are varints;
a coordinate that is a whole number of millimetres takes 2-4 bytes, any other its exact binary parts
(~10 bytes), so replay is exact whether or not `GraphOps.QUANTIZE` is on.

| Check | Result |
|---|---|
| `door_check.lua`, 150 random actions, played from the UNPACKED copy | 150/150 exact both ways; same with QUANTIZE on (150/150) |
| `dbgdoor.lua` over 101 junctions, clear and clear + build, from the unpacked copy | 202/202 exact both ways |
| `reg75undo.sh` with the pack check in the undo | 101/101 undo and redo exact |

Sizes: random actions of 1-25 edits median 3.4 KB (largest 5 KB); junction clears mean 3.0 KB (largest
6.2 KB), clear + build mean 3.4 KB (largest 8.0 KB, 2 pieces). Rounding to the millimetre saved only ~7%:
coordinates read from a save (2 decimals) are already whole millimetres.

In game, build 694 (2026-10-16, savegame with 12.9k points): card passed 4/4, no Lua errors.

| Action | Bytes | Pieces | Recorded | Packed |
|---|---|---|---|---|
| Move, box of ~160 points | 7,925 | 2 | 10 ms | 3 ms |
| Junction clear | 3,682 | 1 | 12 ms | 1 ms |

Faster than offline (26 ms to record at 17k points in plain Lua 5.1). Note for step 3: an undo or redo is
played locally and not packed; in multiplayer it must be sent too, as the same action with a "backwards" flag.

## 6. Steps 3-5 offline: a server and players in one process (2026-10-16)

`scripts/editor/NetCore.lua` holds the rules; `tools/mp-probe/sim.lua` plays them: a host-server and 2-3
players, each with its own copy of the 17k network, editing with AutoDrive's real GraphManager code (deletes,
records, moves, flags, toggles, splines, names, hand-made links), messages delayed 30-250 ms at random but
in order on each line, players mostly in their own slice of the map and sometimes in a shared strip.

- **Server:** replays each player's action by tag (`GraphOps.replay`, new), writes down exactly what that did,
  numbers it, sends it to everyone. The host's actions are already on the server's network.
- **Player:** applies its own edits at once; on anything from the server it takes its unconfirmed actions
  back, applies the server's, and puts its own back on top.
- **Zones:** squares the size of the radius (15 m); an action takes the squares around every point whose
  place it changes; another player's squares, held for 2 s after their last action, bounce it.
- **Joining / out of step:** "hello" gets the whole network with its tags (~400 KB at 17k, in pieces), then
  every action after it on the same line.

| Run (seed) | Players | Applied | Bounced by zone | Result |
|---|---|---|---|---|
| 60 ticks (1) | 2 | 43 | 15 | all identical to the server |
| 60 ticks + late joiner (21) | 2 + 1 | 42 | 17 | all identical, the late joiner too |
| 250 ticks (11) | 3 | 165 | 75 | all identical |
| 250 ticks, shared strip 60% (12) | 3 | 170 | 71 | all identical |
| 250 ticks, shared 60%, zones off (13) | 3 | 242 | 0 | all identical |

No player was ever out of step. `GraphOps.replay` on the network an action was made on gives the same as the
exact apply (80/80, `door_check.lua`).

The bounce rate is high because the simulator is harsh: an action every 50 ms from a random player, zones
of 3x3 squares (45 m) held 2 s, the host editing anywhere. Claiming at the start of a gesture (step 7) is
what makes bounces rare and visible beforehand; until then they are the thing to watch in testing.

The simulator found one bug of its own (messages due at the same moment could overtake each other on a
line; a game connection does not do that) - fixed.

**Not done yet:** the game side - one event class carrying these messages (registered early, see the
plan), the editor calling the boundaries, and undo after another player's change (step 6).

## 7. Step 6 offline: per-player undo (2026-10-16)

An action may be undone while everything it changed still looks exactly as it left it (`GraphOps.fits`):
its new points still there and unchanged (no one linked to them), its deleted points still gone, its moves
still in place, its links still made/broken (another player's new link on the same point does not count),
its names still given/taken. Judged on the network NOW, so a blocked action fits again by itself once the
blocker undoes. The player picks its newest own action that fits, skipping and naming the blocked ones;
the server checks again (final say), plays it by tag, sends it as a numbered action (undoOf/redoOf).
Returned points go on the end (their old place means nothing on a shared network).

`tools/mp-probe/undo_story.lua` - the story, 9 steps, all as told:
Anna moves P and Q; Bob moves P; Anna's undo takes back Q, then skips P with
"Skipped 1: Bob changed that spot (Straighten)"; Bob undoes; Anna's undo now takes back P; redo both;
Anna moves P again and Bob's redo is skipped naming Anna; Anna undoes and Bob's redo goes through.

`sim.lua` with undo 15-25% and redo 5-10% of turns, 3 players + late joiner, 250 ticks each:

| Run | Undos | Redos | Skipped as blocked | Blocked at the server | Not exact after | Result |
|---|---|---|---|---|---|---|
| shared 60% (41) | 50 | 3 | 5 | 4 | 0 | all identical |
| shared 80%, zones off (42) | 62 | 4 | 2 | 1 | 0 | all identical |
| default (43) | 39 | 2 | 3 | 0 | 0 | all identical |

Found and fixed on the way: replay put undone deletes back at their old place in the list, which the door
cannot describe, so the server's record of that undo came out empty and the players never got it. Points
now come back at the end, and the server counts any change it cannot describe (must be 0; it was 0).

Single-player undo is unchanged (`reg75undo.sh`: 101/101 undo and redo exact).

## 8. The game side (2026-10-16) - built, run offline on three "PCs", NOT yet in a real session

- `scripts/NetEvent.lua` - the one network message (kind, 7 numbers, 2 strings, a piece of bytes), sourced at
  mod load from Prelude so it is registered before anyone joins.
- `scripts/editor/NetGame.lua` - host/server/player roles, pieces in and out, boundaries (every
  EditorHistory snapshot, and a quiet moment of 150 ms with no mouse button held), per-player undo, after
  someone else's change (HUD, markers, parking spots, the editor's ids), and the safety net for AutoDrive's
  own editing (its 16 network messages wrapped: taken in without being sent again; a player whose network
  got points that way reloads the whole network 3-15 s later).
- EditorHistory in multiplayer: light entries only (tools still see the stack move), undo/redo go to NetGame.
- The "server only" refusals (opening the editor, spline, field loop, place) now ask `canEditHere()`.
- Naming in multiplayer is made locally and sent through our network, not AutoDrive's as well.
- `modDesc.xml`: multiplayer supported = true on this branch.

`tools/mp-probe/game_sim.lua` loads the REAL NetEvent.lua, NetGame.lua and everything under them into three
separate Lua environments (a host and two players), each with AutoDrive's real GraphManager on its own copy
of the 17k network, and a fake FS network that writes every message field by field and reads it back on the
other side.

| Run (seed) | Editor actions | Undo/redo | AutoDrive recordings | Result |
|---|---|---|---|---|
| 20 rounds (1) | 17 | 3 | 0 | both players identical to the host, 0 errors |
| 120 rounds (2) | 97 | 17 | 6 | identical, 0 errors; players reloaded after AutoDrive's points |
| 120 rounds (3) | 93 | 16 | 11 | identical, 0 errors |

What only a real session can check: the engine's own event handling (registration, sizes), user ids,
timing with real latency, the editor UI while things change underneath, AutoDrive vehicles on edited roads.
