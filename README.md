# FS25_ADFlyoverEditor

The flyover route editor as a **companion mod**: it runs beside *stock* `FS25_AutoDrive` and does
not modify it. Attaches at runtime, or refuses to load and says why.

Build plan and the evidence behind it: `docs/companion-build-plan.md` and
`docs/companion-mod-investigation.md` in the AutoDrive fork.

## Stage 1 — infrastructure only

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

## Layout

| File | |
|---|---|
| `scripts/Prelude.lua` | the only `<extraSourceFiles>` entry; orders everything |
| `scripts/Arming.lua` | listener scan → `getfenv` → republish |
| `scripts/EnvProbe.lua` | one line, answers the environment question |
| `scripts/Settings.lua` | six companion-owned settings; never touches `AutoDrive.settings` |
| `tools/make_icon.py` | regenerates `icon.dds` |

Nothing but `Prelude.lua` may go in `<extraSourceFiles>`: the editor files write into AutoDrive's
table at source time, and AutoDrive is unresolvable then.
