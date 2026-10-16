# Multiplayer BETA — the plan

Branch: `claude/multiplayer-beta`, cut from `main` at 71c9f2d (1.0.3.0), 2026-10-16.

The first research is in [`multiplayer-plan.md`](multiplayer-plan.md). It planned **one editor at a time**.
On 2026-10-16 the user made **editing at the same time a requirement**, so this page replaces that part.
The research is still right about AutoDrive's own network code, sizes, event registration timing and
the millimetre rounding (its §2, §4.2, §4.5, §6), but its line numbers predate the 30-file split.

---

## 1. What it must feel like

- **Like single player.** Your own edits show at once. No waiting on the server.
- **Several people edit at once.** No picking an area, no "ask for the editor".
- **Hardly any visible rules.** The one you can see: you cannot move what someone else is moving right
  now, and their working spot is tinted with their name while they work.
- **Undo and redo per player.**

## 2. The four parts

### 2.1 Zones that claim themselves

- When a tool starts touching points (first pick, drag start, a box, a junction circle) it claims a
  **zone**: everything within **15 m** of the points and lines it touches. The server keeps zones as
  squares on a grid, so overlap checks are quick.
- The zone **grows with the preview** and is **freed when the operation is done or cancelled** (not tied
  to right-click: that commits in some tools and cancels in others).
- **First come, first served**, decided by the server. The gesture starts at once on your PC; if the
  server says no, it is cancelled within a moment and the other player's zone shows.
- **Radius is a server setting**, default 15 m. Kept in our own server-side settings file, sent to every
  player on join. Never in `AutoDrive.settings` (that breaks stock clients, see `companion-build-plan.md`).
- **What others see** (user, 2026-10-16): another player's zone is a **tint in their colour**, and a small
  **legend in a corner of the screen** lists who is editing, by name and colour. Colours from the
  colour-blind-safe set (Okabe-Ito), low glow.
- Tools that read around themselves before building (junction clear/build read nearby roads) claim what
  they read, not only what they write.

### 2.2 Two kinds of ownership: where a point is, and its links

Decided by the user 2026-10-16:

| Thing | Who owns it during an edit |
|---|---|
| A point's **place** (position, height, flags, being deleted) | Whoever's zone it is in |
| A **link** between two points | Whoever makes or removes that link |

So Anna can link her new road onto a point Bob is dragging. Bob owns where the point goes; Anna owns the
new link. Nobody is refused.

- Links go on the wire as **set** and **clear**, never **toggle** (two toggles in a row cancel out). The
  one door turns the editor's toggles into set/clear from the state it sees.
- If Bob **deletes** the point while Anna links to it: whichever reaches the server first wins. If the
  delete wins, Anna's link is dropped and she gets a short note. If the link wins, the delete removes it
  as AutoDrive always does.

### 2.3 Points keep a name for life, and the server sets the order

- AutoDrive numbers points 1, 2, 3… with no gaps; a delete renumbers everything above it. So every point
  gets **our own permanent tag**, kept on the point itself (`wp.fxTag`). Messages name tags, never
  AutoDrive numbers. New points get a tag on the PC that makes them (player + counter).
  *Check early: AutoDrive keeps the same point table when it renumbers (it shifts the table and rewrites
  `.id`, so a field on the table should ride along).*
- AutoDrive's own multiplayer (markers, its own editor, vehicles) needs **the same numbering on every PC**.
  So the server puts all changes in one order and every PC follows it:
  - your changes apply at once on your PC;
  - if someone else's change reached the server first, your PC quietly takes yours back, applies theirs,
    and puts yours back on top. Zones mean they never touch the same place, so this always works.
- **Deletes in multiplayer are held back.** The point is unlinked and hidden at once, and really removed
  later by one "tidy now" message from the server. That keeps AutoDrive's numbers still while people
  work, which makes AutoDrive's own events far less likely to hit the wrong point. A held-back point (or
  group of points) is only really removed when **all** of these hold (user, 2026-10-16):
  - nobody is mid-operation;
  - no AutoDrive vehicle still has it ahead of it on its path. Vehicles run on the server and hold their
    path as a list of point tables (`DrivePathModule.wayPoints`, from `getPathTo`), so the server can
    check by table from the vehicle's current index onward. A vehicle already on the old road just
    drives it out; new paths cannot use it, since it has no links;
  - no map marker sits on it.

  *Open: what to do with a vehicle that sits for a long time with the point still ahead (parked, or a
  stuck job). A time limit, then ask AutoDrive to work out its path again?*

  The "tidy now" removes the whole batch in **one** pass: AutoDrive's own `removeWayPoint` renumbers the
  network on every call (6.4 ms each at 17k points offline, so 300 deletes would freeze ~2 s).
- **The door clears every link before a delete**, including reverse links into the point: AutoDrive's
  delete misses those when the point has incoming links of its own, and the renumbering then rewires
  the dangling link to the next point (found in step 0).

### 2.4 Undo per player, skip what is blocked, and say so

- Undo stops copying the whole network. Each action remembers **how to undo itself** (it is recorded by
  the one door, which sees the before-state). Faster in single player too.
- Your undo list has only your actions. An undo is a new action: it claims its zone, undoes, frees it.
- **Blocked actions are skipped, and said out loud** (user, 2026-10-16). An action is blocked when anything
  it changed has been changed since, by anyone, including your own later actions. Undo then undoes the
  newest one that is not blocked and tells you what it skipped:

  > Undid: Move 12 points. Skipped 1: Bob changed that spot (Smooth, 2 min ago).

- A **history list** on the card shows your recent actions. Blocked ones are greyed with who blocked them
  and when; clicking one flies the camera there. A blocked action can come back if the blocker undoes.
- Redo works the same way.

## 3. The safety net for AutoDrive's own editing

Other players can still edit with AutoDrive itself (recording in a vehicle, AutoDrive's own editor).
That takes no zone, and we do not block AutoDrive. Made as smooth as we can:

1. **The server watches AutoDrive's edits** as they pass through it, gives new points their tags, and
   puts them in the same order as ours. To our editors they look like any other player's action, named
   "Bob (AutoDrive)".
2. **A recording vehicle shows as a zone** that moves with it, so flyover users see it coming. Our tools
   avoid starting in it, the same as with any other zone.
3. **If AutoDrive changes a spot mid-operation**, the operation is still applied when every point it needs
   still exists. It is only refused (with a note, and taken back on your PC) when a point it needs is gone.
4. **Fingerprint check every ~30 s and after each action.** If a PC does not match the server, it reloads
   the server's copy **between operations**, never mid-drag. Because tags travel with the reload, your
   undo list survives; only entries that no longer fit are marked blocked.
5. Everything above goes to the log with the player names, so a tester's report shows what happened.

## 4. What goes over the network

| Message | When | Size |
|---|---|---|
| Zone claim / grant / refuse / grow / free | Start, growth and end of an operation | tiny |
| Zones in use (others' tints) | On change | tiny |
| Action (tagged changes + undo info) | When an operation finishes | 60 B – 60 KB (estimate with undo info), cut in 6 KB pieces |
| Order confirm | Server → everyone, per action | tiny |
| Tidy now (real deletes) | When nobody is mid-operation | small |
| Whole network + tags | Join, or a PC out of step | ~300–400 KB at 17k points |
| Junction numbers + split choices | As their own small actions | tiny |
| Server settings (zone radius) | Join, on change | tiny |

## 5. Limits we accept (BETA)

- Same mod zip on the server and every PC (not on ModHub, so the game will not hand it out).
- PC only.
- AutoDrive's own editing is guarded by the safety net, not blocked.
- Editor look settings stay per player.

## 6. Build steps (each testable on its own)

`modDesc.xml` stays `supported="false"` until step 8, except in local test builds.

| # | Step | Done when | Test with |
|---|---|---|---|
| 0 | **Measure + set up.** Whole-network push size at 17k points; check tags survive renumbering | `docs/multiplayer-probe-results.md` (offline done 2026-10-16; in-game message size still open) | This PC (+ a second licence or a helper for a client) |
| 1 | **One door, tags, self-undoing actions** — `scripts/editor/GraphOps.lua` records each action by comparing the network by tag before and after it (no call-site changes needed); undo plays actions backwards (`EditorHistory.lua`) | DONE offline 2026-10-16: `door_check.lua` 200/200 exact on 17k; 303/303 junction clears/builds exact; undo+redo 202/202 exact; `reg75.sh` identical. In-game test card next | Offline harness + single player |
| 2 | **Pack actions** — `scripts/editor/ActionCodec.lua`: action -> bytes (varints; coordinates exact, whole millimetres in 2-4 bytes) -> 6 KB pieces -> joined -> action; logged per action in game, not sent | DONE offline 2026-10-16: 300/300 random actions and 202/202 junction actions replay exactly from the unpacked copy; junction actions ~3 KB, largest 8 KB (2 pieces). In-game card next | Single player |
| 3 | **Server order, host → others** | Client matches host after every tool | Host + 1 client |
| 4 | **Clients → server** with the quiet take-back-and-reapply; held-back deletes and "tidy now" (waits for vehicles and markers) | Two editors far apart, no drift after save + reload; a vehicle drives out a deleted road | Host + 2 clients |
| 5 | **Zones** — claimed by the door at write time; tints + corner legend; radius setting | Two editors side by side, nothing lost | Host + 2 clients |
| 6 | **Per-player undo** — skip blocked, history list, messages | Undo stories in §2.4 all behave | Host + 2 clients |
| 7 | **Early zones** at gesture start, tool by tool; AutoDrive safety net (§3) | Recording next to an editor, nothing lost | Host + 2 clients |
| 8 | **BETA build** — `supported="true"`, 1.0.4.0, tester guide, issue form | Hosted test session clean | User hosts |
| 9 | **BETA round 1 on GitHub** — the user hosts, testers join | Testers' reports in issues, fixed | Testers |
| 10 | **Dedicated server** — headless load, server-only apply; a tester's rented server, or rent one | No Lua errors in the server log; same tests as 9 | Dedicated server |

Step 1 turned out small: instead of moving ~80 write sites onto new functions, the door compares the
network before and after each action (undo already marked where actions start), so it catches every
write, including ones nobody listed. Millimetre rounding is built but off (`G.QUANTIZE`); note AutoDrive
saves at 0.01 m, so rounding to the centimetre may be the better choice - decide in step 2.

**Hosting first** (user, 2026-10-16): the user hosts the early test sessions (listen server). A
dedicated server comes later, before leaving BETA: a tester's own rented server if anyone has one,
otherwise we rent one then. Until step 10 the tester guide says "listen server only".

## 7. The BETA release

- **GitHub pre-release** (never "latest"), tag `v1.0.4.0-mp-beta.1`, zip built from this branch. Main
  stays the single-player release.
- **Version** `1.0.4.0` (user, 2026-10-16), then `1.0.4.1`, … one per round; title gets "(MP BETA)".
- **Tester guide** `docs/multiplayer-beta-testers.md`: install the same zip everywhere, remove other
  copies, what to try, where `log.txt` is on PC and server, attach both plus `testresults.xml`.
- **Issue form** `.github/ISSUE_TEMPLATE/mp-beta.yml`: host or dedi, players, AutoDrive version, what you did.
- **In-game test card**: an MP plan in `tools/testplans/`, about 4 steps, pass/fail/skip only.

## 8. Still open

1. A vehicle that keeps a held-back point ahead of it for a long time (see §2.3).
2. Whole-network push size (step 0).
3. Testers: how many, and whether anyone rents a dedicated server. Crossed when we get there.
