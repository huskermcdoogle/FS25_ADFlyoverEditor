# FS25_ADFlyoverEditor

## Tested (2026-09-08, build 0.7.1.0, stock AutoDrive 3.0.0.8, fork disabled)

| Tool | |
|---|---|
| place | ✅ |
| move | ✅ incl. falloff by wheel and by `,`/`.` |
| connect | ✅ |
| delete | ✅ |
| smooth | ✅ both modes |
| name | ✅ names the clicked waypoint |
| spline | ✅ preview, wheel, place |
| merge | ✅ |
| field loop | ✅ via console |
| divide | ✅ incl. the fork/direction fixes |
| **convert** | **not confirmed** — selected, but no completed conversion in any log |

Also verified: **settings persistence** end to end — a changed value written to
`modSettings/FS25_ADFlyoverEditor/settings.xml` as an index, read back across a full restart, and
resolved to the right value; and **zero** of our keys present in any savegame's
`AutoDrive_config.xml`, which is the half that matters, since one injected key breaks a stock
client's settings sync. Undo/redo and two open-close cycles in one session also pass.

`name`, `delete` and `merge` were the three worth doing first — each is the only exerciser of one
piece of the port. `name` is the sole user of the republished `ADEnterTargetNameGui`; `delete` is the
only thing that hits waypoint-id renumbering; `merge` is the only tool depending on
`splineInterpolation` surviving mouse events, which is what wrapper 1 exists for.

**Working as of 2026-09-08 (build 0.7.3.0).** Running beside stock AutoDrive 3.0.0.8 with the fork
disabled: camera flies, panel draws, network follows the cursor, divide and spline tools place, the
wheel adjusts curvature and span, Escape exits and returns the input system as it found it. Zero
engine Lua errors across the session.

The flyover route editor as a **companion mod**: it runs beside *stock* `FS25_AutoDrive` and does
not modify it. Attaches at runtime, or refuses to load and says why.

Build plan and the evidence behind it: `docs/companion-build-plan.md` and
`docs/companion-mod-investigation.md` in the AutoDrive fork.

## Stage 1 — infrastructure only ✅ passed 2026-09-08

Both halves verified against stock AutoDrive 3.0.0.8. With AutoDrive present: resolved on attempt 1,
all four names republished, **sourced files land in our own mod environment** (the build plan's
number-one risk, now closed), zero errors. With AutoDrive absent: gave up after 300 attempts, said so
once, game otherwise normal.


No editor yet. This stage exists to answer the plan's number-one risk: **which Lua environment a
runtime `source()` call lands in.** Every later stage depends on that, and nothing in the codebase
or the docs answers it.

What it does:

1. Finds AutoDrive's specialization table by scanning `g_vehicleTypeManager` for the `onDrawUIInfo`
   listener — structural, so it needs no mod name.
2. Takes `getfenv` of `AutoDrive.onDrawEditorMode` to get AutoDrive's whole environment.
   *Before any hook is installed* — `getfenv` on a function we have already wrapped returns **our**
   environment, which was measured the hard way.
3. Sources a one-line probe and asks it, via the root table, which environment it landed in.
4. Republishes four names (`AutoDrive`, `ADGraphManager`, `ADDrawingManager`,
   `ADEnterTargetNameGui`) into that environment. An allow-list, not an `__index` fallthrough —
   see the comment in `scripts/Arming.lua`.

## Verifying stage 1

Test against **stock AutoDrive with `FS25_AutoDrive_Gibbs` disabled**. The fork does all of this
natively, so a pass with it enabled proves nothing.

Load a savegame with AutoDrive active, then:

```
FlyoverStatus
```

The log should contain, in order:

```
resolved AutoDrive on attempt N via the g_vehicleTypeManager onDrawUIInfo listener scan
republished: AutoDrive, ADGraphManager, ADDrawingManager, ADEnterTargetNameGui
sourced files land in <X>
ARMED. 0 editor file(s) sourced.
```

**The `sourced files land in` line is the finding.** Any of the three answers is workable — the code
republishes into whatever the probe reports — but which one it is decides how stage 5 is written, so
report it.

Then **disable AutoDrive and reload**: it must give up after 300 attempts, say so once, and leave
the game otherwise normal.

## Stage 2 — the copied geometry ✅ passed 2026-09-08

`PolygonUtils.lua` and `OffsetGeometry.lua` are copied **verbatim** from the fork into
`scripts/editor/` and sourced by the prelude after arming. Same mod config as stage 1, then:

```
FlyoverGeomTest
```

Expected: `5 points, max turn 90.0 deg, area 53424 (source 47808) | PASS`

The ring is a field with a 4m inlet cut into one side, offset outward by 6m - the case that used to
produce a waypoint 188m outside the field and a 180-degree doubling-back. So a sane answer exercises
the miter limit, the validity pass and cusp removal, not merely "the file loaded".

It is also the sharpest test of the copy itself. With the fork disabled `ADPolygonUtils` genuinely
does not exist in AutoDrive's environment, so a wrong source order fails loudly with
`ADPolygonUtils is nil` instead of silently borrowing the fork's copy.

## Stage 3 — the wrappers ✅ passed 2026-09-08

Five functions inside AutoDrive's own source files were edited by the fork. A guest cannot edit
them, so they become wrappers on AutoDrive's shared table, installed **last** — after resolution and
after the editor files are sourced, because `getfenv` on an already-wrapped function returns *our*
environment.

Same mod config. Sit in an AutoDrive vehicle with its HUD visible, then:

```
FlyoverFakeActive
```

Four things should change, and all four should revert when you toggle it off again:

| | Expected while ON |
|---|---|
| AutoDrive vehicle HUD | gone |
| Waypoint network | drawn, **even with EditorMode off** |
| Clicking where the HUD was | does nothing |
| Mouse wheel | still zooms (the editor gets first refusal, not ownership — and there is no editor yet) |

Then `FlyoverStatus` for the counters. The interesting pair is `onDrawUIInfo` versus `drawHud`:
**if `onDrawUIInfo` stays at 0 while `drawHud` climbs**, then `onDrawUIInfo` does not raise in this
situation and the second wrapper is carrying the HUD suppression alone. Either answer is fine —
nothing load-bearing depends on it — but it is the one open question from the build plan, and this
is where it gets answered.

## Stage 4 — the proxy ✅ passed 2026-09-08

`draws=2874`, zero errors, network drawn at a cursor 200m from the vehicle. Counters:
`onDrawUIInfo 28730, drawHud 1, mouse 1732, editorShow 4543, wheel 0`.

So wrapper 2 does the HUD suppression in the in-vehicle case and 2b is a fallback that fires once —
on the first frame, before `proxyOwnsNetwork` flips. `wheel 0` with zoom still working confirms the
wheel falls through when no editor claims it.

The network gets re-centred on a cursor instead of the vehicle, by handing
`AutoDrive:onDrawEditorMode` a stand-in `self` whose `components[1].node` sits at the cursor and
whose `__index` sends everything else to the real vehicle. This is the mechanism the whole companion
approach rests on, already measured once by the spike at 4,813 calls with zero errors.

Sit in an AutoDrive vehicle, then:

```
FlyoverProxyAt
```

With no arguments it drops the cursor 200 m from you — a red vertical marker. **The network should
draw around the marker, not around you.** `FlyoverProxyAt <x> <z>` aims it anywhere;
`FlyoverProxyOff` ends it.

Then `FlyoverStatus`. Two counters matter:

- **`proxy draws`** climbing — the stand-in is being accepted frame after frame. If the stand-in were
  wrong, `self.ad` or `self.components[1].node` would throw on the *first* frame and the proxy would
  disable itself with the error in the log.
- **`onDrawUIInfo`** climbing — this is now allowed to fire, because `proxyOwnsNetwork` is true and
  something else is drawing. If it stays at 0 while the network still appears at the cursor, then
  `onDrawUIInfo` is not raising and `Hud.drawHud` is doing the HUD suppression alone.

Note this stage still has no `GuiTopDownCamera`, so it does **not** settle whether `onDrawUIInfo`
survives the camera — that is genuinely stage 5. What it settles is the stand-in.

## Versioning

Two numbers, because one cannot answer the question honestly.

`P.BUILD` in `Prelude.lua` is re-sourced every time a savegame loads, so it always describes the Lua
actually executing. `modDesc`'s version is read by the mod manager at **game startup only**. Both are
printed at source time, on the `ARMED` line, and by `FlyoverStatus`.

**So: reloading a savegame from the main menu is enough for Lua changes.** A full restart is only
needed when `modDesc.xml` itself changes. On the main-menu path the modDesc version goes stale while
the code is current, and the version line says so explicitly rather than misreporting:

```
build 0.4.0.0 (modDesc says 0.3.0.0 - stale, full restart to refresh it)
```

That mismatch is informational, not a fault. It matters only when a change touches modDesc — a new
`<sourceFile>` entry, say — which will not take effect until a real restart.

## Layout

| File | |
|---|---|
| `scripts/Prelude.lua` | the only `<extraSourceFiles>` entry; orders everything |
| `scripts/Arming.lua` | listener scan → `getfenv` → republish |
| `scripts/EnvProbe.lua` | one line, answers the environment question |
| `scripts/Proxy.lua` | the stand-in `self` that re-centres the network |
| `scripts/Wrappers.lua` | the five fork edits as runtime wrappers |
| `scripts/Settings.lua` | six companion-owned settings; never touches `AutoDrive.settings` |
| `tools/make_icon.py` | regenerates `icon.dds` |

Nothing but `Prelude.lua` may go in `<extraSourceFiles>`: the editor files write into AutoDrive's
table at source time, and AutoDrive is unresolvable then.
