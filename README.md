# FS25_ADFlyoverEditor

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

## Stage 2 — the copied geometry

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

## Stage 3 — the wrappers, still no editor

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

## Layout

| File | |
|---|---|
| `scripts/Prelude.lua` | the only `<extraSourceFiles>` entry; orders everything |
| `scripts/Arming.lua` | listener scan → `getfenv` → republish |
| `scripts/EnvProbe.lua` | one line, answers the environment question |
| `scripts/Wrappers.lua` | the five fork edits as runtime wrappers |
| `scripts/Settings.lua` | six companion-owned settings; never touches `AutoDrive.settings` |
| `tools/make_icon.py` | regenerates `icon.dds` |

Nothing but `Prelude.lua` may go in `<extraSourceFiles>`: the editor files write into AutoDrive's
table at source time, and AutoDrive is unresolvable then.
