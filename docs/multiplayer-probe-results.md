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
