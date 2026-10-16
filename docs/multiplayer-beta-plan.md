# Multiplayer BETA — the plan

Branch: `claude/multiplayer-beta`, cut from `main` at 71c9f2d (1.0.3.0), 2026-10-16.

The deep research is in [`multiplayer-plan.md`](multiplayer-plan.md) (written before the editor was split
into 30 files, so its line numbers are old; its design still holds). This page is the short version
brought up to date, plus how we get a BETA into testers' hands on GitHub.

---

## 1. The idea in one line

**One player edits at a time. When they finish an action, the server checks it, keeps it, and sends it
to everyone else.**

## 2. Who does what

| Who | Today | In the BETA |
|---|---|---|
| Single player | Edits | Same as today. Nothing sent anywhere. |
| Host (listen server) | Mod will not load in MP | Edits; every action goes out to the other players |
| Client (joined player) | Mod will not load in MP | Asks for the "edit pass"; edits; actions go to the server, which passes them on |
| Dedicated server | Never tried | No editor. Holds the pass, checks and applies actions, saves |

Why the server must be the boss: AutoDrive only saves routes on the server. An edit that never reaches
the server is gone on the next join.

## 3. What goes over the network

| Message | When | Size |
|---|---|---|
| Edit pass: ask / yes / no / give back / taken away | Opening and closing the editor | tiny |
| Keep-alive | Every 5 s while editing; pass dropped after 15 s silent | tiny |
| Action list (the "ops") | After each finished action (never mid-drag) | 50 B – 30 KB, cut in 6 KB pieces |
| Whole network | Undo, redo, or "you were out of step" | ~250–330 KB at 17k points |
| Junction numbers + split decisions | With the pass (both ways) | a few KB |

Each action list carries a **fingerprint** of the network it was made on. If the server's fingerprint is
different, the action is refused and the whole network is sent back to that player.

## 4. Limits we accept (BETA)

- One editor at a time. Others get: *"&lt;name&gt; is editing the route network."*
- Undo only works for the player holding the pass, and is wiped when the network is reloaded.
- If someone records an AutoDrive route in a vehicle while you edit, your next action may be refused
  and the editor reloads.
- Every player and the server need the **same** mod zip (not on ModHub, so the game will not hand it
  out). Dedicated server owners upload it through their panel.
- PC only. Consoles do not run script mods.
- Editor settings (theme, size, panel spot) stay per player.

## 5. What changed since the old research

| Then | Now | Effect on the plan |
|---|---|---|
| 1 file, 10,407 lines | 55 Lua files, ~54k lines | The "shim" step is bigger; the counts below replace the old ones |
| ~50 graph-writing calls | removeWayPoint 15, moveWayPoint 23, setWayPointFlags 5, toggleConnectionBetween 20, recordWayPoint 3 (already funnels through `ADFlyoverRecordWayPoint`), createSplineConnection 8, markers ~9, direct link surgery 14 sites in 5 files (JxCore, Convert, Menus, Merge, Spline) | All must go through one door |
| No junction file | `ADFlyoverEditor_junctions.xml` saved with the game, server only (`JxRegistry.lua`) | Ride along with the edit pass |
| AD 3.0.1.2 | AD 3.0.1.4, waypoints carry `fieldID` | The "add point" op carries `fieldID` too |
| No in-game test card | `tools/testplans/current.xml` + test panel | Testers tick MP steps in the game, attach `testresults.xml` |

## 6. Build steps (each one testable on its own)

`modDesc.xml` stays `supported="false"` until step 5, except in local test builds.

| # | Step | Done when | Test with |
|---|---|---|---|
| 0 | **Measure** — can AutoDrive's own whole-network upload carry a 17k-point network? Set up a dedicated server on this PC. | A number in `docs/probe-results.md` | Local dedi + this PC's game |
| 1 | **One door** — every graph write goes through `scripts/net/GraphOps.lua`. Coordinates rounded to mm. Single player only. | `reg75.sh` byte-identical to main (mm aside), grep finds no write outside the door | Offline harness |
| 2 | **Action lists** — record each action, fingerprint, pack, cut into pieces; write to the log, send nothing | Packed size of real actions logged; unpack = same network | Single player |
| 3 | **Host → others** — host edits, a client watches | Rows 1, 3–6, 11 of the old test matrix | Host + 1 client |
| 4 | **Client → server** — edit pass, refusal, reload, undo, junction numbers | Rows 2, 7–10, 16 | Local dedi + client, then 2 clients |
| 5 | **Dedicated server + BETA build** — headless load, `supported="true"`, version, tester guide | Rows 12–14; tester guide written | Local dedi |
| 6 | **BETA on GitHub** — pre-release, testers report, fix rounds | Testers' results in issues | Testers |

Step 1 is the biggest and the only one that touches the existing tools. It ships on its own if needed
(it changes nothing a player sees).

## 7. The BETA release

- **GitHub pre-release** (ticked "pre-release", so it is never "latest"), tag `v1.0.4.0-mp-beta.1`,
  zip built from this branch. Main stays the single-player release.
- **Version in `modDesc.xml`**: `1.0.4.0`, `1.0.4.1`, … one per beta round; mod title gets "(MP BETA)".
  *To confirm with the user.*
- **Same zip everywhere**: the release notes say it first. Players must remove any other copy of
  `FS25_ADFlyoverEditor` from their mods folder.
- **Tester guide** (`docs/multiplayer-beta-testers.md`): install, who should host, the 6-ish things to
  try, where `log.txt` lives on the client and the server, attach both plus `testresults.xml` to an
  issue.
- **Issue template** `.github/ISSUE_TEMPLATE/mp-beta.yml`: host or dedi, how many players, AD version,
  what you did, logs.
- **In-game test card**: an MP plan in `tools/testplans/` — short (about 4 steps), pass/fail/skip only.
- **Leaving BETA**: two rounds with no lost edits and no Lua errors on a dedicated server, then merge to
  main as a normal release.

## 8. Open questions

1. Version number scheme for the beta (above).
2. Any player may edit (agreed earlier). Do server owners want an "admins only" switch? Cheap to add in
   step 4 if testers ask.
3. Does anyone in the tester group run a rented dedicated server? That is the setup most likely to break.
4. Whole-network push size — answered by step 0.
