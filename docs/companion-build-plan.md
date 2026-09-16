# FS25_FlyoverEditor — build plan

**Provenance.** Produced by a multi-agent analysis of the seven editor files against stock AutoDrive
3.0.0.8 (8 agents, ~980k tokens). It is a *plan*, not verified code — treat its line numbers and
claims as leads to check, not facts, except where noted below.

**What I verified directly before committing this:**

| Claim | Check | Result |
|---|---|---|
| The editor declares no key bindings in `modDesc.xml` | `grep -ic flyover modDesc.xml` | **0** — confirmed, and it corrected an error in `flyover-input-context.md` |
| Writing to the `AutoDrive` table is invisible to AutoDrive | `grep -rn "pairs(AutoDrive)"` | **0 call sites** — confirmed |
| Adding a key to `AutoDrive.settings` is not | `grep -rn "pairs(AutoDrive.settings)"` | **17 call sites** — confirmed; its network sync iterates them |
| A zero spacing crashes the resampler | reproduced in Lua 5.1 | **confirmed** — out of memory in <10s, since fixed (`6ee7b3d`) |

**Measured since this plan was written — stage 1, 2026-09-08, stock AutoDrive 3.0.0.8:**

Risk #1 ("most likely to break, and it breaks stage 1") is **resolved**. A runtime `source()` from an
`update()` tick lands in the companion's **own mod environment**, the same as a mod-load-time one, so
no second republish is needed and the design's fallback paths are unused. AutoDrive resolved on
attempt 1; all four names republished; zero errors. The six companion-owned settings resolved to the
correct values from their default indices, confirming the values-array-plus-index shape.

**Stages 2-4 also measured, same conditions:** the two geometry files copy across and run
identically in game and standalone; the five host wrappers install and fire; and the stand-in `self`
was accepted **2,874 times with zero errors**, rendering the network at a cursor 200m from the
vehicle. Counters showed `onDrawUIInfo` firing 28,730 times against `Hud.drawHud` once — so in the
in-vehicle case wrapper 2 does the suppression and 2b is a fallback that barely runs. Whether that
holds once `GuiTopDownCamera` is active is still the open question, now genuinely stage 5.

One bug found on the way, worth recording because the plan did not predict it: suppressing
`onDrawUIInfo` also suppresses the waypoint network, because that function draws the HUD *and then*
calls `onDrawEditorMode`. It may only fire once something else is drawing, so it is gated on the
proxy being live.

**What is still unmeasured**, and the plan is explicitly built to survive either answer: whether
`onDrawUIInfo` still raises once `GuiTopDownCamera` is active. AutoDrive works around exactly that
for its construction screen (`AutoDrive.lua:238`, `:739-745`). Stage 4's `sawOnDrawUIInfo` counter
settles it; the design keeps nothing load-bearing on it, riding `AutoDrive.draw` instead.

See `companion-mod-investigation.md` (in the AutoDrive fork repo) for the feasibility work this
rests on, and [`flyover-input-context.md`](flyover-input-context.md) for the input-context bugs.

---

# FS25_FlyoverEditor — build plan

Verified against the spike at `C:/Dropbox/Stuff/FS25 Mods/FS25_FlyoverProxySpike/scripts/FlyoverProxySpike.lua`, `register.lua:60-110/300-400`, the full fork diff (`git diff b24fbaa HEAD`), and the seven source files. Everything below is either quoted from those or is code to type.

---

## 0. The two rules that decide most of the design

**Rule A — `AutoDrive` the table is safe to write; `AutoDrive.settings` is not.**
`grep -rn "pairs(AutoDrive)" scripts/ register.lua` returns **nothing**. `pairs(AutoDrive.settings)` returns **10 hits across 5 files** (`Events/UpdateSettingsEvent.lua:20,28,40,50,60,68`, `Gui/Settings.lua:124,149`, `Manager/UserDataManager.lua:21`, `Settings.lua:1894`, plus `XML.lua:91/289`). So the ~30 `AutoDrive.FLYOVER_*` / `AutoDrive.FIELD_LOOP_*` constants that `FlyoverEditor.lua:123-159` and `FieldLoopGenerator.lua:18-38` write at source time are **invisible to AutoDrive and copy across unchanged**. Adding a single key to `AutoDrive.settings` hard-errors a stock client at `UpdateSettingsEvent.lua:82`. That asymmetry is why the constants stay and the settings move out.

**Rule B — the proxy rides `AutoDrive.draw`, never `onDrawUIInfo`.**
The gap analysis is right that nobody measured whether `onDrawUIInfo` still raises with `GuiTopDownCamera` active, and `AutoDrive.lua:238/739-745` is AutoDrive itself working around exactly that failure for the construction screen. The spike already proved `AutoDrive.draw` is a mod event listener wrapper that fires unconditionally (spike lines 241-247, `Spike.runProxyDraw` at 331). Build on that from stage 1 and item 1 of the gap list stops being a risk at all — it degrades only the *HUD suppression*, which has an independent fallback.

---

## 1. File and folder layout

```
FS25_FlyoverEditor/
├── modDesc.xml
├── icon.dds                          (from the spike's tools/make_icon.py)
├── scripts/
│   ├── Prelude.lua                   NEW  – the only file in <extraSourceFiles>
│   ├── Arming.lua                    NEW  – listener scan + getfenv + republish
│   ├── Wrappers.lua                  NEW  – the five host-side function wrappers
│   ├── Proxy.lua                     NEW  – the stand-in `self` network draw
│   ├── Settings.lua                  NEW  – companion-owned settings + modSettings XML
│   ├── BuildInfo.lua                 generated by tools/make_release.py (gitignored)
│   └── editor/                       the seven copied files, verbatim paths flattened
│       ├── PolygonUtils.lua          COPY, unchanged
│       ├── OffsetGeometry.lua        COPY, unchanged
│       ├── FieldLoopGenerator.lua    COPY + 4 edits
│       ├── FlyoverHud.lua            COPY + 3 edits
│       ├── EditorHistory.lua         COPY + 4 edits
│       └── FlyoverEditor.lua         COPY + 9 edits
└── tools/
    ├── make_icon.py                  (copy from spike)
    └── make_release.py               (writes scripts/BuildInfo.lua, defines ADBuildInfo)
```

Six copied files under `editor/`, seven counting `PolygonUtils.lua` — the investigation doc says "six" in prose and lists seven in its table. It is **seven**. Source order is fixed by `register.lua:74-84`:

```
PolygonUtils → OffsetGeometry → FieldLoopGenerator → BuildInfo → FlyoverHud → EditorHistory → FlyoverEditor
```

**None of the seven may appear in `<extraSourceFiles>`.** `FlyoverEditor.lua:123` (`AutoDrive.FLYOVER_DRAW_RADIUS = 200`) and `FieldLoopGenerator.lua:18` run at source time and `AutoDrive` is nil then — the probe log measured a 54-second gap between mod source and successful resolution. Only `Prelude.lua` is listed; it sources the rest by hand after arming.

---

## 2. `modDesc.xml` — complete

No `<actions>` block. `docs/flyover-input-context.md:128-131` is wrong: `grep -i flyover modDesc.xml` in the fork returns nothing. The editor reads raw key symbols through its own `isKey` helper (`FlyoverEditor.lua:772-774`, `:786`, `:800`, `:808`) and registers only base-game `InputAction.MENU_CANCEL` / `MENU_BACK` (`:560-568`). The `AD_FLYOVER_EDITOR` context is created at runtime by `g_inputBinding:setContext` (`FlyoverEditor.lua:509-511`) and needs no modDesc entry. Adding action names would create the collision the doc exists to prevent.

```xml
<?xml version="1.0" encoding="utf-8" standalone="no" ?>
<modDesc descVersion="107">
	<author>huskermcdoogle</author>
	<title>
		<en>Flyover Editor for AutoDrive</en>
	</title>
	<description>
		<en>
<![CDATA[A vehicle-free flyover camera for editing AutoDrive route networks: fly over the map, click to place, move, connect, delete, smooth, merge, divide and name waypoints, and generate a loop around a field boundary.

Requires FS25_AutoDrive to be installed and active. This mod does not modify AutoDrive; it attaches to it at runtime and refuses to load if it cannot.

Single-player and listen-server host only. On a multiplayer client the editor refuses to open, because its edits are not sent to the server.

Console: FlyoverEditor toggles it. FlyoverResetInput recovers stranded movement keys. FlyoverStatus reports what attached.
]]>
		</en>
	</description>
	<version>0.1.0.0</version>
	<multiplayer supported="false" />
	<iconFilename>icon.dds</iconFilename>
	<extraSourceFiles>
		<sourceFile filename="scripts/Prelude.lua" />
	</extraSourceFiles>
</modDesc>
```

`multiplayer supported="false"` is the honest value and it matches the `g_server == nil` refusal in §5.6. Every graph write in the copied files passes `sendEvent = false` and `AutoDrive:saveSavegame` (`AutoDrive.lua:542-550`) only writes routes when `g_server ~= nil` — a client can edit for an hour and lose all of it with no signal.

No `<l10n>` element: none of the seven files contains `g_i18n`, `l10n`, `getText` or an `ad_` text id. If that ever changes, the mechanism is `register.lua`'s `addModTranslations` — publish into `getfenv(0).g_i18n.texts`, because mod-scoped lookup only works for vehicles.

---

## 3. The prelude

### 3.1 The environment problem nobody has measured

Settled fact 3 gets us AutoDrive's environment. It does **not** tell us which environment a runtime `source()` call lands in. `g_currentModName` is set during mod load and not during our `update()` tick, so `source()` at runtime may attach the companion's mod env, or may dump into `getfenv(0)`. Guessing wrong means the seven files' globals (`ADFlyoverEditor`, `ADOffsetGeometry`, …) are published somewhere our own code cannot see, and the failure looks like "nothing happens".

So don't guess: **probe it.** Source a one-line file, read back the environment it actually got, and republish into *that* table. This is deterministic, self-correcting, and it is what stage 1 verifies.

`scripts/EnvProbe.lua` (this one *is* in `editor/`'s sibling position but sourced first, on its own):

```lua
-- Sourced by Prelude.lua purely to discover which Lua environment a runtime source() call lands
-- in. FS25 sets a mod environment during mod load; whether it does so for a source() issued from
-- an update() tick is not documented and not measured, and getting it wrong publishes the editor's
-- globals somewhere the companion cannot reach. So ask, rather than assume.
ADFlyoverEnvProbe = { env = getfenv(1) }
```

### 3.2 Allow-list, not `__index` fallthrough — and why

**Use an explicit allow-list.** Three reasons, in order of weight:

1. **It is the only thing that keeps the fork case honest.** If the player has `FS25_AutoDrive_Gibbs` installed, `getfenv(AD.getSetting)` returns an environment that already contains `ADFlyoverEditor`, `ADEditorHistory`, `ADFlyoverHud`, `ADOffsetGeometry`, `ADPolygonUtils` and `ADBuildInfo`. A fallthrough `__index` silently resolves those to the *fork's* copies for any name our own `source()` calls happen not to have defined yet — and which wins depends purely on whether the republish ran before or after the sources. An allow-list of four names cannot import them, and `ADBuildInfo` in particular then correctly reports *our* build rather than the host's, which is the whole point of `describeBuild` (`FlyoverEditor.lua:297-305`).
2. **The typo argument.** With fallthrough, `ADGraphManger:getWayPointById(...)` resolves to nil-index-error at the *call*, one frame later, in a `pcall`-wrapped draw path — indistinguishable from a real geometry bug. With a plain table, an unknown global is nil, which is exactly the semantics the seven files were written and tested against.
3. **The list is four names, not eight.** The spike's `PORT_NEEDS` (line 432-435) was the *probe's* checklist, not the editor's dependency set. Grepping the seven files: `ADGraphManager` 122 uses, `ADDrawingManager` 11, `ADEnterTargetNameGui` 3, `AutoDrive` throughout. `ADInputManager`, `ADMessagesManager`, `ADRoutesManager`, `ADStateModule` — **zero**. `ADCollSensor` appears once, in a comment at `FieldLoopGenerator.lua:92`; `AutoDriveHud` once, in a comment at `FlyoverEditor.lua:649`.

`MathUtil`, `Logging`, `Input`, `InputAction`, `Overlay`, `g_baseUIFilename`, `g_colorBgUVs`, `CollisionFlag`, `overlapBox`, `g_inputBinding`, `GuiTopDownCamera`, `GuiTopDownCursor` are base-game globals present in every mod environment and need no entry.

### 3.3 `scripts/Arming.lua`

```lua
--[[
Attaching to AutoDrive from outside it.

Three steps, each of which can fail on its own and each of which says so:

  1. RESOLVE  the AutoDrive specialization table, by scanning vehicle types for the registered
              onDrawUIInfo listener. Structural, so it needs no mod name and works for any build.
  2. REACH    AutoDrive's whole mod environment through getfenv on a function we will never wrap.
              Lua 5.1 functions carry the environment they were DEFINED in.
  3. REPUBLISH the four names the editor actually uses into the environment our own sourced files
              land in - by value, into a plain table, never through a write-through proxy.

Nothing here runs at mod-load time. AutoDrive.Hud does not exist until AutoDrive.lua:228 and
GuiTopDownCamera.onZoom is not overwritten until AutoDrive.lua:243, both inside AutoDrive's own
loadMap, and mod load order is not ours to control. So arming is driven from our first update()
ticks and retried until it succeeds or gives up loudly.
]]

ADFlyoverArming = {
    MOD_NAME = "FlyoverEditor",
    MAX_ATTEMPTS = 300,        -- ~5 seconds at 60fps; loadMap ordering is the only thing we wait on
    attempts = 0,
    armed = false,
    failed = false,
    AD = nil,                  -- AutoDrive's specialization table
    env = nil,                 -- AutoDrive's mod environment
    target = nil,              -- the environment our sourced files live in
    route = nil,
}

local A = ADFlyoverArming

-- The four names the seven copied files actually reference. Verified by grep, not by guesswork:
-- ADGraphManager 122 uses, ADDrawingManager 11, ADEnterTargetNameGui 3, AutoDrive throughout.
-- ADInputManager / ADMessagesManager / ADRoutesManager / ADStateModule appear zero times; the
-- spike's eight-name PORT_NEEDS list was the probe's checklist, not the editor's.
--
-- Deliberately NOT here: ADBuildInfo, ADFlyoverEditor, ADEditorHistory, ADFlyoverHud,
-- ADOffsetGeometry, ADPolygonUtils. If the host is the Gibbs fork its environment contains all
-- six, and importing them would shadow - or be shadowed by - our own copies depending on nothing
-- more than source order. We refuse to arm against the fork anyway (see checkNotTheFork), but the
-- list stays minimal so that refusal is a policy and not the only thing standing between us and a
-- silent half-import.
A.REPUBLISH = { "AutoDrive", "ADGraphManager", "ADDrawingManager", "ADEnterTargetNameGui" }

function A.log(fmt, ...)     Logging.info("[%s] " .. fmt, A.MOD_NAME, ...) end
function A.warn(fmt, ...)    Logging.warning("[%s] " .. fmt, A.MOD_NAME, ...) end
function A.err(fmt, ...)     Logging.error("[%s] " .. fmt, A.MOD_NAME, ...) end

-- ------------------------------------------------------------------ step 1: resolve the table

local function looksLikeAutoDrive(c)
    return type(c) == "table"
        and type(c.onDrawEditorMode) == "function"
        and type(c.onDrawUIInfo) == "function"
        and type(c.isEditorShowEnabled) == "function"
        and type(c.getSetting) == "function"
end

--- The engine stores the specialization TABLE in vehicleType.eventListeners and looks the function
--- up by name on it at every raise, so this hands back the very table AutoDrive's own registered
--- callbacks are dispatched through - which is what makes wrapping it work at all.
local function resolveAutoDrive()
    if g_vehicleTypeManager == nil or g_vehicleTypeManager.types == nil then
        return nil, "g_vehicleTypeManager not populated yet"
    end
    for _, typeDef in pairs(g_vehicleTypeManager.types) do
        local listeners = typeDef.eventListeners ~= nil and typeDef.eventListeners.onDrawUIInfo or nil
        if listeners ~= nil then
            for _, spec in pairs(listeners) do
                if looksLikeAutoDrive(spec) then
                    return spec, "g_vehicleTypeManager onDrawUIInfo listener scan"
                end
            end
        end
    end
    return nil, "no vehicle type carries a listener that looks like AutoDrive"
end

-- ------------------------------------------------------------- step 2: reach the environment

--- Resolve through a function we will NEVER wrap. getfenv on a function this mod has already
--- wrapped returns OUR environment, not AutoDrive's - measured in the spike at 0 of 8 names - so
--- the order here is load-bearing: environment first, hooks afterwards, and never getSetting.
local function resolveEnvironment(AD)
    local ok, env = pcall(getfenv, AD.getSetting)
    if not ok or type(env) ~= "table" then
        return nil, "getfenv(AutoDrive.getSetting) gave " .. tostring(env)
    end
    if env.ADGraphManager == nil then
        return nil, "that environment has no ADGraphManager, so it is not AutoDrive's"
    end
    return env
end

-- --------------------------------------------------------------------- the refusal conditions

--- Refuse to attach to the fork. It already ships this editor; attaching would mean two live
--- ADFlyoverEditors, colliding console commands, and our wrappers stacking on top of the fork's
--- own in-file guards (AutoDrive.lua:597, Specialization.lua:534/829, UtilFuncs.lua:1035,
--- AutoDriveUtilFuncs.lua:284) which read the FORK's ADFlyoverEditor and would never fire.
local function checkNotTheFork(env)
    if env.ADFlyoverEditor ~= nil then
        return false, "the installed AutoDrive already has the flyover editor built in "
            .. "(this looks like FS25_AutoDrive_Gibbs). Disable one of the two."
    end
    return true
end

--- Everything we intend to lean on, checked once, by name, at arm time rather than mid-edit.
local function checkSurface(AD, env)
    local missing = {}
    local function want(t, name, label)
        if t == nil or t[name] == nil then missing[#missing + 1] = label end
    end
    -- functions we wrap
    want(AD, "mouseEvent",             "AutoDrive.mouseEvent")
    want(AD, "onDrawUIInfo",           "AutoDrive.onDrawUIInfo")
    want(AD, "onDrawEditorMode",       "AutoDrive.onDrawEditorMode")
    want(AD, "handleSplineCurvature",  "AutoDrive.handleSplineCurvature")
    want(AD, "isEditorShowEnabled",    "AutoDrive.isEditorShowEnabled")
    want(AD, "draw",                   "AutoDrive.draw")
    -- functions we call
    want(AD, "getSetting",             "AutoDrive.getSetting")
    want(AD, "getControlledVehicle",   "AutoDrive.getControlledVehicle")
    want(AD, "getAllVehicles",         "AutoDrive.getAllVehicles")
    want(AD, "getTerrainHeightAtWorldPos", "AutoDrive:getTerrainHeightAtWorldPos")
    want(AD, "FLAG_SUBPRIO",           "AutoDrive.FLAG_SUBPRIO")
    -- managers
    for _, name in ipairs({ "ADGraphManager", "ADDrawingManager", "ADEnterTargetNameGui" }) do
        want(env, name, name)
    end
    local G = env.ADGraphManager
    for _, name in ipairs({ "getWayPoints", "setWayPoints", "getMapMarkers", "setMapMarkers",
                            "getGroups", "setGroups", "markChanges", "getWayPointById",
                            "recordWayPoint", "toggleConnectionBetween", "removeWayPoint",
                            "moveWayPoint", "setWayPointFlags", "createMapMarker",
                            "renameMapMarker", "prepareWayPoints" }) do
        want(G, name, "ADGraphManager:" .. name)
    end
    -- base-game classes the flyover camera is built on
    if GuiTopDownCamera == nil then missing[#missing + 1] = "GuiTopDownCamera (base game)" end
    if GuiTopDownCursor == nil then missing[#missing + 1] = "GuiTopDownCursor (base game)" end
    return #missing == 0, missing
end

-- ----------------------------------------------------------------- step 3: republish, by value

--- By VALUE into a plain table. Never a metatable that forwards writes: OffsetGeometry.lua:41 and
--- PolygonUtils.lua:8 do bare global assignments (ADOffsetGeometry = {}), and with a write-through
--- __newindex those would land in AutoDrive's environment and clobber the host's own tables. And
--- never an __index fallthrough to AutoDrive's environment: it would resolve typos silently and,
--- worse, quietly import a fork's ADFlyoverEditor for any name our sources had not yet defined.
local function republish(env, target)
    local imported, absent = {}, {}
    for _, name in ipairs(A.REPUBLISH) do
        local v = env[name]
        if v == nil then
            absent[#absent + 1] = name
        else
            target[name] = v
            imported[#imported + 1] = name
        end
    end
    return imported, absent
end

-- --------------------------------------------------------------------------------- the sources

local EDITOR_FILES = {
    "scripts/editor/PolygonUtils.lua",
    "scripts/editor/OffsetGeometry.lua",
    "scripts/editor/FieldLoopGenerator.lua",
    "scripts/editor/FlyoverHud.lua",
    "scripts/editor/EditorHistory.lua",
    "scripts/editor/FlyoverEditor.lua",
}

--- Discover the environment a runtime source() actually lands in, rather than assuming it is ours.
--- g_currentModName is set during mod load and not during an update tick, so whether FS25 attaches
--- a mod environment here is not something to guess at - the failure mode is that every editor
--- global is published somewhere we cannot see and the mod appears to do nothing.
local function resolveTargetEnv()
    local ok, e = pcall(function()
        source(Utils.getFilename("scripts/EnvProbe.lua", ADFlyoverEditorMod.dir))
        return ADFlyoverEnvProbe
    end)
    if not ok or type(e) ~= "table" or type(e.env) ~= "table" then
        return nil, "the environment probe did not come back: " .. tostring(e)
    end
    return e.env
end

function A.arm()
    A.attempts = A.attempts + 1

    local AD, route = resolveAutoDrive()
    if AD == nil then
        if A.attempts >= A.MAX_ATTEMPTS then
            A.failed = true
            A.err("gave up after %d attempts: %s. If AutoDrive is enabled for this savegame, "
                .. "report this - it is the whole basis of the mod.", A.attempts, route)
        end
        return false
    end
    A.AD, A.route = AD, route
    A.log("resolved AutoDrive on attempt %d via %s", A.attempts, route)

    local env, envErr = resolveEnvironment(AD)
    if env == nil then
        A.failed = true
        A.err("reached AutoDrive's table but not its environment: %s", envErr)
        return false
    end
    A.env = env

    local okFork, forkMsg = checkNotTheFork(env)
    if not okFork then
        A.failed = true
        A.err("refusing to load: %s", forkMsg)
        return false
    end

    local okSurface, missing = checkSurface(AD, env)
    if not okSurface then
        A.failed = true
        A.err("refusing to load - this AutoDrive is missing %d thing(s) the editor needs: %s",
            #missing, table.concat(missing, ", "))
        return false
    end

    local target, targetErr = resolveTargetEnv()
    if target == nil then
        A.failed = true
        A.err("%s", targetErr)
        return false
    end
    A.target = target
    A.log("sourced files land in %s environment",
        target == getfenv(1) and "OUR OWN mod" or (target == getfenv(0) and "the TRUE ROOT" or "a THIRD"))

    local imported, absent = republish(env, target)
    if #absent > 0 then
        A.failed = true
        A.err("refusing to load - could not republish: %s", table.concat(absent, ", "))
        return false
    end
    A.log("republished %s", table.concat(imported, ", "))

    -- Companion-owned settings BEFORE the sources, because FieldLoopGenerator.lua:107 and
    -- FlyoverEditor's number rows read through it. It never touches AutoDrive.settings.
    target.ADFlyoverSettings = ADFlyoverSettings
    ADFlyoverSettings:load()

    for _, path in ipairs(EDITOR_FILES) do
        local okSrc, srcErr = pcall(source, Utils.getFilename(path, ADFlyoverEditorMod.dir))
        if not okSrc then
            A.failed = true
            A.err("refusing to load - %s failed to source: %s", path, tostring(srcErr))
            return false
        end
    end

    -- Sanity: the sources must have published into the environment we republished into, and the
    -- ADOffsetGeometry we end up with must be OURS, not one that leaked in from a host fork.
    if target.ADFlyoverEditor == nil or target.ADOffsetGeometry == nil then
        A.failed = true
        A.err("refusing to load - the editor sourced without error but published nothing we can see. "
            .. "The target environment guess is wrong.")
        return false
    end

    ADFlyoverWrappers.install(AD, env, target)

    A.armed = true
    A.log("ARMED. Console: FlyoverEditor to open, FlyoverResetInput to recover input, FlyoverStatus.")
    return true
end
```

### 3.4 `scripts/Prelude.lua` — the only sourced file

```lua
--[[
The companion's own mod event listener. Its whole job is: hold the mod directory, arm on the first
update ticks (NOT loadMap - AutoDrive.Hud does not exist until AutoDrive.lua:228 and
GuiTopDownCamera.onZoom is not overwritten until :243, both inside AutoDrive's loadMap, and mod
load order is not ours), then forward the four callbacks to the editor once it exists.
]]

ADFlyoverEditorMod = {
    dir = g_currentModDirectory,
    name = g_currentModName,
}

local M = ADFlyoverEditorMod

source(Utils.getFilename("scripts/Settings.lua", M.dir))
source(Utils.getFilename("scripts/Arming.lua", M.dir))
source(Utils.getFilename("scripts/Wrappers.lua", M.dir))
source(Utils.getFilename("scripts/Proxy.lua", M.dir))

-- Generated by tools/make_release.py, absent when running from a working copy. Defines ADBuildInfo
-- in OUR environment; it is deliberately not on the republish list, so describeBuild reports this
-- mod's build and never the host's.
local buildInfoPath = Utils.getFilename("scripts/BuildInfo.lua", M.dir)
if fileExists ~= nil and fileExists(buildInfoPath) then
    source(buildInfoPath)
end

function M:loadMap(name)
    Logging.info("[FlyoverEditor] loaded, waiting for AutoDrive.")
end

--- Reset everything that must not survive into the next savegame.
---
--- ADFlyoverEditor.contextCreated (FlyoverEditor.lua:49) is set once at :513 and never cleared.
--- FS25 does not re-source mod Lua when the player returns to the menu and loads a different save,
--- but g_inputBinding's contexts ARE rebuilt for the new mission - so on the second mission the
--- editor would call setContext(..., create=false) for a context that does not exist. And if a
--- session ended with the editor open, `active` stays true and our wrappers go on suppressing
--- stock AutoDrive's HUD forever in the next session, which would present as an AutoDrive bug.
function M:deleteMap()
    if ADFlyoverEditor ~= nil then
        if ADFlyoverEditor.active then
            pcall(function() ADFlyoverEditor:disable() end)
        end
        ADFlyoverEditor.active = false
        ADFlyoverEditor.contextCreated = false
        ADFlyoverEditor.contextPushed = false
        ADFlyoverEditor.camera = nil
        ADFlyoverEditor.cursor = nil
        ADFlyoverEditor.cursorX, ADFlyoverEditor.cursorZ = nil, nil
    end
    if ADEditorHistory ~= nil then ADEditorHistory:clear() end
    if ADFlyoverProxy ~= nil then ADFlyoverProxy:teardown() end
end

function M:update(dt)
    if not ADFlyoverArming.armed and not ADFlyoverArming.failed then
        ADFlyoverArming.arm()
        return
    end
    if ADFlyoverEditor ~= nil then ADFlyoverEditor:update(dt) end
end

function M:keyEvent(unicode, sym, modifier, isDown)
    if ADFlyoverEditor ~= nil then ADFlyoverEditor:keyEvent(unicode, sym, modifier, isDown) end
end

function M:mouseEvent(posX, posY, isDown, isUp, button)
    if ADFlyoverEditor ~= nil then ADFlyoverEditor:mouseEvent(posX, posY, isDown, isUp, button) end
end

function M:draw()
    if ADFlyoverEditor ~= nil then ADFlyoverEditor:draw() end
end

addModEventListener(M)
```

The header comment at `FlyoverEditor.lua:17-18` ("drives the camera from AutoDriveRegister's already-registered but empty update/mouseEvent/draw stubs") becomes false and should be reworded — no code change, the companion supplies the identical four callbacks.

---

## 4. The wrappers

Six functions on the host, standing in for the five fork edits that live inside AutoDrive's own source files and are therefore not copied. Every one is reached by a **by-name lookup on the shared table at call time**, which is what makes wrapping work (settled fact 5, measured at 226,211 interceptions).

`scripts/Wrappers.lua`:

```lua
ADFlyoverWrappers = { installed = false }
local W = ADFlyoverWrappers

local function editorActive()
    return ADFlyoverEditor ~= nil and ADFlyoverEditor.active == true
end

function W.install(AD, env, target)
    if W.installed then return end

    ------------------------------------------------------------------ 1. mouse: fork AutoDrive.lua:595-601
    -- Without this every click is handled twice. AutoDrive's gate is satisfied because the flyover
    -- mode turns the mouse cursor on itself (FlyoverEditor.lua:575) and isMouseActiveForEditor is
    -- just `not g_gui:getIsGuiVisible()` (AutoDriveUtilFuncs.lua:373), so Hud.lua:812-830 runs
    -- mouseEventCreateWaypoint / DeleteWaypoint / MoveNode / SelectOrConnect on the same event.
    -- This also fixes the SPLINE tool outright: Hud.lua:795 sets splineInterpolation.valid = false
    -- on EVERY mouse event, including the right-click that commits the curve.
    -- AutoDrive is registered with addModEventListener (register.lua:394), so the engine looks the
    -- method up by name on this table each frame and the wrapper intercepts.
    local originalMouseEvent = AD.mouseEvent
    AD.mouseEvent = function(selfArg, ...)
        if editorActive() then
            AD.lastButtonDown = nil
            return
        end
        return originalMouseEvent(selfArg, ...)
    end

    ------------------------------------------------- 2. HUD: fork Specialization.lua:530-535
    -- Suppress only the HUD half. The network rendering that follows it is what the editor uses
    -- instead of drawing its own, so it must NOT be skipped here.
    -- NOTE: whether onDrawUIInfo raises at all while GuiTopDownCamera is active has never been
    -- measured (AutoDrive.lua:238/739-745 exists precisely because it stops raising under the
    -- construction screen). If it does not, this wrapper simply never fires - which costs the HUD
    -- suppression and nothing else, because the proxy rides AutoDrive.draw, not this.
    local originalOnDrawUIInfo = AD.onDrawUIInfo
    AD.onDrawUIInfo = function(vehicle, ...)
        if editorActive() then
            ADFlyoverProxy.sawOnDrawUIInfo = ADFlyoverProxy.sawOnDrawUIInfo + 1
            return
        end
        return originalOnDrawUIInfo(vehicle, ...)
    end

    ------------------------------ 2b. HUD, belt and braces: the Hud object is not built until
    -- AutoDrive.lua:228, inside AutoDrive's loadMap - which is exactly why arming happens from
    -- update() and not from ours. If wrapper 2 turns out not to fire, this one still hides the HUD.
    if AD.Hud ~= nil and type(AD.Hud.drawHud) == "function" then
        local originalDrawHud = AD.Hud.drawHud
        AD.Hud.drawHud = function(hudSelf, ...)
            if editorActive() then return end
            return originalDrawHud(hudSelf, ...)
        end
    else
        ADFlyoverArming.warn("AutoDrive.Hud was not built yet - the vehicle HUD may show through "
            .. "the flyover panel. Report this with your mod load order.")
    end

    ---------------------------------------- 3. network show: fork AutoDriveUtilFuncs.lua:284-290
    -- Called as AutoDrive.isEditorShowEnabled() with no self, hence the bare vararg. Read fresh at
    -- Specialization.lua:548 and :821, so replacing it here is enough.
    local originalIsEditorShow = AD.isEditorShowEnabled
    AD.isEditorShowEnabled = function(...)
        if editorActive() then return true end
        return originalIsEditorShow(...)
    end

    ------------------------------------------------ 4. mouse wheel: fork UtilFuncs.lua:1032-1039
    -- Wrap handleSplineCurvature, NOT GuiTopDownCamera.onZoom. Two reasons. First, onZoom is
    -- overwritten by AutoDrive itself at AutoDrive.lua:243 inside its loadMap, so ending up
    -- outermost is a load-order coin flip. Second and decisive: ADFlyoverEditor:handleWheel
    -- (FlyoverEditor.lua:3202-3238) returns FALSE for the SPLINE tool on purpose, so the wheel
    -- falls through to AutoDrive's own curvature clamp at UtilFuncs.lua:1041-1044. Hooking at
    -- onZoom level destroys that fallthrough unless it is reimplemented; hooking here preserves it
    -- for free, including handleSplineCurvature's own AutoDrive.mouseWheelActive last resort.
    local originalHandleSplineCurvature = AD.handleSplineCurvature
    AD.handleSplineCurvature = function(selfArg, offset, ...)
        if editorActive() and ADFlyoverEditor.handleWheel ~= nil then
            if ADFlyoverEditor:handleWheel(offset) then return true end
        end
        return originalHandleSplineCurvature(selfArg, offset, ...)
    end

    ------------------------------------ 5. NAME tool: fork Gui/EnterTargetNameGUI.lua (+25 lines)
    -- Class(ADEnterTargetNameGui, DialogElement) at Gui/EnterTargetNameGUI.lua:11 makes the class
    -- table the instances' __index, and Gui.lua:7/:24 register ADEnterTargetNameGui.new() under
    -- the name the editor shows, so a class-level wrapper is seen by the live dialog. Note that
    -- overrideWayPointId is read off the CLASS table, not off self - FlyoverEditor.lua:2750 sets
    -- it there and this reads it from there.
    local Gui = env.ADEnterTargetNameGui
    local originalOnOpen = Gui.onOpen
    Gui.onOpen = function(guiSelf, ...)
        local overrideId = Gui.overrideWayPointId
        if overrideId == nil then
            return originalOnOpen(guiSelf, ...)
        end
        local r = originalOnOpen(guiSelf, ...)
        -- Stock onOpen has already set editId/editName from the controlled vehicle (or from
        -- nothing, on foot). Redo that half from the clicked waypoint, exactly as the fork's
        -- overrideId branch does.
        guiSelf.editId, guiSelf.editName, guiSelf.edit = nil, nil, false
        for i, mapMarker in pairs(env.ADGraphManager:getMapMarkers()) do
            if mapMarker.id == overrideId then
                guiSelf.editId = i
                guiSelf.editName = mapMarker.name
                guiSelf.edit = true
                break
            end
        end
        if guiSelf.textInputElement ~= nil then
            guiSelf.textInputElement:setText(guiSelf.editName or "")
        end
        return r
    end

    local originalOnClickOk = Gui.onClickOk
    Gui.onClickOk = function(guiSelf, ...)
        local overrideId = Gui.overrideWayPointId
        if overrideId ~= nil and not guiSelf.edit then
            env.ADGraphManager:createMapMarker(overrideId, guiSelf.textInputElement.text)
            Gui.overrideWayPointId = nil
            if guiSelf.close ~= nil then guiSelf:close() end
            return
        end
        Gui.overrideWayPointId = nil
        return originalOnClickOk(guiSelf, ...)
    end

    -- Clear the override however the dialog is dismissed, or a later open from a vehicle is still
    -- pointed at a waypoint clicked minutes ago.
    local originalOnClose = Gui.onClose
    Gui.onClose = function(guiSelf, ...)
        Gui.overrideWayPointId = nil
        if originalOnClose ~= nil then return originalOnClose(guiSelf, ...) end
    end

    ---------------------------------------------------------- 6. the proxy, on AutoDrive.draw
    -- The one hook that is provably called every frame regardless of what owns the screen: it is a
    -- mod event listener, not a vehicle specialization raise. Queueing our network tasks here means
    -- AutoDrive's own ADDrawingManager flush on the very next line picks them up, so the editor's
    -- accents never lag the cursor by a frame either.
    local originalDraw = AD.draw
    AD.draw = function(selfArg, ...)
        if editorActive() then
            ADFlyoverProxy:runProxyDraw()
        end
        return originalDraw(selfArg, ...)
    end

    W.installed = true
    ADFlyoverArming.log("installed 6 wrappers: mouseEvent, onDrawUIInfo, Hud.drawHud, "
        .. "isEditorShowEnabled, handleSplineCurvature, EnterTargetNameGui(onOpen/onClickOk/onClose), draw.")
end
```

### `scripts/Proxy.lua`

Replaces the fork's `Specialization.lua:829-834` cursor re-centring, which cannot be reinstated by wrapping `AutoDrive.onDrawEditorMode` (settled fact 6 — `registerFunction` copies the pointer and `Specialization.lua:549` calls `self:onDrawEditorMode()`). Calling it directly with a stand-in `self` is what the spike measured at 4,813 calls, zero errors.

```lua
ADFlyoverProxy = {
    cursorNode = nil,
    drewThisFrame = false,
    sawOnDrawUIInfo = 0,
    proxyDraws = 0,
    failures = 0,
    MAX_FAILURES = 3,
}
local P = ADFlyoverProxy

local function ensureCursorNode()
    if P.cursorNode == nil or not entityExists(P.cursorNode) then
        P.cursorNode = createTransformGroup("flyoverEditorProxyCursor")
        link(getRootNode(), P.cursorNode)
    end
    return P.cursorNode
end

function P:teardown()
    if P.cursorNode ~= nil and entityExists(P.cursorNode) then delete(P.cursorNode) end
    P.cursorNode = nil
    P.drewThisFrame = false
end

--- Any vehicle carrying AutoDrive state will do: the proxy borrows its .ad tables and its four
--- specialization functions, never its position.
local function findHostVehicle(AD)
    local controlled = AD.getControlledVehicle()
    if controlled ~= nil and controlled.ad ~= nil and controlled.ad.stateModule ~= nil then
        return controlled
    end
    for _, v in pairs(AD.getAllVehicles()) do
        if v ~= nil and v.ad ~= nil and v.ad.stateModule ~= nil then return v end
    end
    return nil
end

--- components[1].node is the ONLY thing overridden; __index sends self.ad and the four
--- specialization functions to the real vehicle, so state is read and written where AutoDrive
--- expects it. That has a cost worth knowing about: Specialization.lua:868 runs
--- updateWayPointsDistance with OUR cursor coordinates, an O(n) walk of the whole network that
--- overwrites the host vehicle's cached distances, and :858-863 forces a full rebuild every time
--- the cursor pans further than AutoDrive.drawDistance / 2 (~100 m). Correctness self-heals -
--- getClosestWayPoint(nil) recomputes from the real node at :1616 - but the cost is real, and it
--- is the price of not carrying a copy of AutoDrive's 300-line renderer.
function P:runProxyDraw()
    P.drewThisFrame = false
    local AD = ADFlyoverArming.AD
    if AD == nil or ADFlyoverEditor.cursorX == nil then return end

    local vehicle = findHostVehicle(AD)
    if vehicle == nil then return end        -- on foot with no AD vehicle: fallback renderer covers it

    local ok, err = pcall(function()
        local node = ensureCursorNode()
        local y = AD:getTerrainHeightAtWorldPos(ADFlyoverEditor.cursorX, ADFlyoverEditor.cursorZ)
        setWorldTranslation(node, ADFlyoverEditor.cursorX, y, ADFlyoverEditor.cursorZ)
        AD.onDrawEditorMode(setmetatable({ components = { { node = node } } }, { __index = vehicle }))
    end)

    if ok then
        P.proxyDraws = P.proxyDraws + 1
        P.drewThisFrame = true
    else
        P.failures = P.failures + 1
        if P.failures <= P.MAX_FAILURES then
            ADFlyoverArming.err("proxy network draw failed (%d/%d): %s",
                P.failures, P.MAX_FAILURES, tostring(err))
        end
        if P.failures == P.MAX_FAILURES then
            ADFlyoverArming.err("giving up on the proxy renderer; falling back to the editor's own "
                .. "plainer network drawing for the rest of this session.")
        end
    end
end

function P:isHealthy()
    return P.failures < P.MAX_FAILURES
end
```

---

## 5. Blocker resolution

### 5.1 Settings — companion-owned, AutoDrive-shaped

**Never add a key to `AutoDrive.settings`.** `UpdateSettingsEvent.lua:82` does an unguarded `AutoDrive.settings[settingName].current = value`, so a stock client joining a host that injected six keys takes a nil index and loses the rest of the settings sync. And `XML.lua:91` reads the config from `AutoDrive.loadStoredXML()` at `AutoDrive.lua:220` — inside AutoDrive's loadMap, four seconds before we can resolve anything — so an injected key is written at save and skipped at load, silently.

The shape matters as much as the presence. `applySettingValue` (`FlyoverEditor.lua:1875-1894`) snaps a typed number to the nearest entry of `setting.values` and stores an *index*; `getSetting` returns `values[current]`. Reproduce that shape exactly, and the panel's snapping, the number rows and `getEditableNumbers` all keep working unchanged.

`scripts/Settings.lua` — the six definitions are lifted verbatim from `git show HEAD:scripts/Settings.lua` lines 1732-1834 (`fieldLoopMargin` 81 values default 46; `fieldLoopTreeClearance` 19 values default 4; `fieldLoopVehicleHeight` 8 values default 4; `fieldLoopTurningRadius` 18 values default 6; `flyoverMergeDistance` 10 values default 5; `flyoverMergeDivergence` 11 values default 6). Only the wrapper is new:

```lua
ADFlyoverSettings = { settings = {} }
local S = ADFlyoverSettings

S.settings.fieldLoopMargin = { values = { --[[ 81 entries, verbatim from Settings.lua:1734-1743 ]] },
                               default = 46, current = 46 }
S.settings.fieldLoopTreeClearance   = { values = {0.5,0.75,1.0,1.25,1.5,1.75,2.0,2.25,2.5,2.75,3.0,3.25,3.5,3.75,4.0,4.25,4.5,4.75,5.0}, default = 4,  current = 4  }
S.settings.fieldLoopVehicleHeight   = { values = {2.5,3.0,3.5,4.0,4.5,5.0,5.5,6.0},                                                     default = 4,  current = 4  }
S.settings.fieldLoopTurningRadius   = { values = {3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20},                                      default = 6,  current = 6  }
S.settings.flyoverMergeDistance     = { values = {0.5,0.75,1.0,1.25,1.5,2.0,2.5,3.0,4.0,5.0},                                           default = 5,  current = 5  }
S.settings.flyoverMergeDivergence   = { values = {0,5,10,15,20,25,30,40,50,75,100},                                                     default = 6,  current = 6  }

--- Fallthrough is deliberate here and only here: names we do not own go to AutoDrive, so the one
--- genuinely-stock read the editor makes - AutoDrive.getSetting("showHUD") at FlyoverEditor.lua:655
--- - keeps working, and the six fork-only names never touch AutoDrive.settings.
function S.get(name)
    local s = S.settings[name]
    if s ~= nil then return s.values[s.current] end
    if AutoDrive ~= nil and AutoDrive.getSetting ~= nil then return AutoDrive.getSetting(name) end
    return nil
end

--- Same contract as AutoDrive.setSettingState: takes an INDEX, not a value.
function S.setIndex(name, index)
    local s = S.settings[name]
    if s == nil or s.values[index] == nil then return nil end
    s.current = index
    S:save()
    return s.values[index]
end

local function path()
    return getUserProfileAppPath() .. "modSettings/FS25_FlyoverEditor/settings.xml"
end

function S:load()
    local ok = pcall(function()
        local p = path()
        if not fileExists(p) then return end
        local xml = loadXMLFile("flyoverSettings", p)
        if xml == nil or xml == 0 then return end
        for name, s in pairs(S.settings) do
            local v = getXMLInt(xml, "flyoverEditor." .. name .. "#current")
            if v ~= nil and s.values[v] ~= nil then s.current = v end
        end
        delete(xml)
    end)
    if not ok then ADFlyoverArming.warn("could not read settings; using defaults.") end
end

function S:save()
    pcall(function()
        createFolder(getUserProfileAppPath() .. "modSettings")
        createFolder(getUserProfileAppPath() .. "modSettings/FS25_FlyoverEditor")
        local xml = createXMLFile("flyoverSettings", path(), "flyoverEditor")
        for name, s in pairs(S.settings) do
            setXMLInt(xml, "flyoverEditor." .. name .. "#current", s.current)
        end
        saveXMLFile(xml)
        delete(xml)
    end)
end
```

There is no settings *page*: `Gui/SettingsPage.lua:36/68` looks elements up in `AutoDrive.settings[element.name]` and the elements come from `gui/globalSettingsPage.xml` inside AutoDrive's zip, which a companion cannot add to. The panel's own inline number editor is the UI, and once `applySettingValue` routes here it actually works — which it does not against stock today (`FlyoverEditor.lua:1878` returns nil, `commitEditNumber` at :1938 logs "could not apply"). That is a net gain over the fork's current merge rows, not a loss. `FlyoverHud.lua:193-194`'s "changed in AutoDrive's settings page" comment becomes false and must go.

### 5.2 Translations — nothing to do
Zero `g_i18n` / `l10n` / `getText` / `ad_` ids across all seven files. Every string is a hardcoded English literal. No `<l10n>` in modDesc.

### 5.3 Input bindings — nothing to do
See §2. Do not add `<actions>`. Correct `docs/flyover-input-context.md:128-131` and `companion-mod-investigation.md` item 4.

### 5.4 Textures — nothing to do
`FlyoverHud.lua:41-58` builds its four overlays from `Overlay.new(g_baseUIFilename)` + `setUVs(g_colorBgUVs)`, both base-game globals that AutoDrive reads and never assigns (`Hud/HudIcon.lua:11-12`). No mod-relative paths, no icon atlas, no `createImageOverlay`. The only asset is the mod's own `icon.dds`.

### 5.5 Console commands — three, renamed
`DevFuncs.lua:94-97` is fork-only and lives inside the dev-gated `AutoDrive.devAutoDriveInit`. Register from the companion, at the end of `Arming.arm()` after the sources succeed, with names that cannot collide:

```lua
addConsoleCommand("FlyoverEditor",     "Toggle the AutoDrive flyover editor", "toggle",            ADFlyoverEditor)
addConsoleCommand("FlyoverNoContext",  "Diagnostic: toggle the custom input context",
                                                                             "toggleContextMode", ADFlyoverEditor)
addConsoleCommand("FlyoverResetInput", "Recover stranded movement keys after the flyover editor",
                                                                             "resetInput",        ADFlyoverEditor)
addConsoleCommand("FlyoverStatus",     "Report what the flyover editor attached to", "consoleStatus", ADFlyoverArming)
```

`FlyoverResetInput` is not scaffolding — `flyover-input-context.md` records that the alternative was twice restarting the game. It must ship.

### 5.6 Multiplayer — one refusal, not eleven guards
Add to `ADFlyoverEditor:enable()` (`FlyoverEditor.lua:434`), immediately after the `already active` check:

```lua
    -- Every graph write in this editor passes sendEvent = false, and AutoDrive:saveSavegame
    -- (AutoDrive.lua:542-550) only writes routes when g_server ~= nil. On a client an entire
    -- session's editing reaches neither the server nor the savegame, and the next server broadcast
    -- reverts it with no signal. One refusal here is more honest than eleven per-tool guards.
    if g_server == nil then
        Logging.error("[FlyoverEditor] the flyover editor only runs on the server (single-player, "
            .. "or the multiplayer host). Your edits would not reach the server or the savegame.")
        return
    end
```

That subsumes the existing `g_server == nil` guards at `:2140-2144` and `:4039-4043`; leave them, they cost nothing.

### 5.7 Fork-only symbols — the ledger
| Symbol | Resolution |
|---|---|
| `ADPolygonUtils`, `ADOffsetGeometry`, `ADEditorHistory`, `ADFlyoverHud`, `ADFlyoverEditor`, `AutoDrive:generateFieldLoopAt`, `AutoDrive.FIELD_LOOP_*`, `AutoDrive.FLYOVER_*` | travel with the seven copies; `FIELD_LOOP_*`/`FLYOVER_*` land on the host `AutoDrive` table, which is safe by Rule A |
| six `AutoDrive.settings.*` keys | replaced by `ADFlyoverSettings` (§5.1) |
| `ADEnterTargetNameGui.overrideWayPointId` | wrapper 5 |
| `ADFlyoverEditor:handleWheel` call site | wrapper 4 |
| `ADFlyoverEditor.active/.cursorX/.cursorZ` read by AutoDrive | wrappers 1, 2, 2b, 3 + the proxy |
| `ADBuildInfo` | companion's own `tools/make_release.py`; deliberately **off** the republish list so `describeBuild` never reports the host's build |
| `AutoDrive.stripModNameFromKey` | not a dependency of any of the seven; ignore |

---

## 6. Per-file edits

### Copy **unchanged**: `PolygonUtils.lua`, `OffsetGeometry.lua`
Verified by bytecode enumeration, not grep: `OffsetGeometry.lua` touches exactly five globals — `math`, `ADOffsetGeometry`, `ADPolygonUtils`, `table`, `MathUtil`. Its `ADPolygonUtils.getSignedArea` dependency (`:326, :327, :404, :431`) is satisfied because `PolygonUtils.lua` is the seventh copied file and is sourced first. The `ADOffsetGeometry = {}` / `ADPolygonUtils = {}` global writes at `:41` / `:8` are safe because the republish is copy-in with no `__newindex` (§3.3).

### `FieldLoopGenerator.lua` — 4 edits, all `getSetting` → `ADFlyoverSettings.get`

```
:107   local halfHeight = (AutoDrive.getSetting("fieldLoopVehicleHeight") or 4.0) / 2
    →  local halfHeight = (ADFlyoverSettings.get("fieldLoopVehicleHeight") or 4.0) / 2

:519   ... or AutoDrive.getSetting("fieldLoopMargin")         → ... or ADFlyoverSettings.get("fieldLoopMargin")
:520   ... or AutoDrive.getSetting("fieldLoopTreeClearance")  → ... or ADFlyoverSettings.get("fieldLoopTreeClearance")
:521   ... or AutoDrive.getSetting("fieldLoopTurningRadius")  → ... or ADFlyoverSettings.get("fieldLoopTurningRadius")
```

`:519-521` are inside `AutoDrive:generateFieldLoop`, the vehicle console command, which the companion does not register — dead weight, but three characters each and it removes a landmine. Lines 18-38 stay as they are (Rule A). Also hoist `:107`'s lookup out of `hasTreeNear` if you want it: the amplitude search at `:244-271` calls it thousands of times per generation.

### `EditorHistory.lua` — 4 edits

**(a) `restoreState`, `:92-99`.** It is a partial reimplementation of `AutoDriveRoutesUploadEvent:run` (`Events/RoutesUploadEvent.lua:33-48`), which does six things after a full graph swap where this does two.

```lua
local function restoreState(entry)
    ADGraphManager:setWayPoints(entry.wayPoints)
    ADGraphManager:setMapMarkers(entry.mapMarkers)
    -- true, not false. GraphManager.lua:461-479 shows the updateVehicles branch is the ONLY code
    -- that rewrites vehicle.ad.groups from the new list; the waypoint swap does not do it. Without
    -- it, undoing a group creation leaves every vehicle holding a key for a group that no longer
    -- exists, and that map is serialised per vehicle so the phantom survives a save/load.
    ADGraphManager:setGroups(entry.groups, true)

    -- Markers are stored on vehicles as direct TABLE references into ADGraphManager.mapMarkers
    -- (StateModule.lua:834-855), and copyMapMarkers built brand-new tables. Without this every
    -- vehicle holds an orphan whose markerIndex may now name a different destination, and that
    -- wrong index is what gets saved. RoutesUploadEvent.lua:40-46 does exactly this.
    for _, vehicle in pairs(AutoDrive.getAllVehicles()) do
        if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
            vehicle.ad.stateModule:resetMarkersOnReload()
        end
    end

    -- setMapMarkers passes notifyDestinationListeners = false because "the caller does it"
    -- (GraphManager.lua:118-124) - we are the caller. AutoDrive.updateDestinationsMapHotspots is
    -- registered as a listener at AutoDrive.lua:512 and is the only thing that rebuilds
    -- mapHotspotsBuffer, so without this the map keeps hotspots for markers the undo deleted.
    AutoDrive:notifyDestinationListeners()
    -- Forces the HUD destination pulldown to rebuild, as GraphManager.lua:339-341 does.
    if AutoDrive.Hud ~= nil then AutoDrive.Hud.lastUIScale = 0 end

    ADGraphManager:markChanges()
end
```

**(b) `undo` `:136` and `redo` `:167`.** `table.remove(self.stack)` sits *outside* the pcall, so a throw inside `setMapMarkers` (which calls `createDebugMarkers` and walks the network) loses the snapshot *and* leaves waypoints from N with markers from now, while returning nil so the caller at `FlyoverEditor.lua:801` never invalidates its id cache. Move the `table.remove` inside the pcall, or push the entry back on failure and return a second flag so the caller invalidates anyway.

**(c) `copyWayPoints` `:37-60`.** Replace the hard-coded `{id,x,y,z,out,incoming,flags,colors}` allowlist with a generic `for k,v in pairs(wp)` that copies scalars straight through and deep-copies only `out`, `incoming`, `colors`. Same cost, and it removes a version coupling that is strictly worse for a guest than for the fork: the allowlist matches `GraphManager.lua:981-992` in *this* build, and any waypoint field a newer AutoDrive adds is stripped from all ~7000 waypoints by one keypress, marked dirty, and written to the player's route file.

**(d) log prefix.** All six `Logging` calls (`:109, :132, :143, :147, :174, :178`) say `[AD]`. Change to `[FlyoverEditor]` so companion-origin output does not misdirect AutoDrive bug reports. Same applies to `[AD] ADFlyoverEditor:` throughout `FlyoverEditor.lua` — a bulk `sed 's/\[AD\] ADFlyoverEditor/[FlyoverEditor]/g'` is worth doing once at copy time.

**Not fixed, and stated as a known limitation:** nothing clears the history stack when AutoDrive replaces the graph underneath it (`RoutesUploadEvent.lua:33`, `Sync.lua:33`, `XML.lua:111/153`). `clear()` has exactly one caller, `FlyoverEditor.lua:589`. Wrapping `ADGraphManager.setWayPoints` to clear it needs a reentrancy guard because `restoreState` itself calls `setWayPoints`. Given the single-player-only refusal in §5.6, the reachable cases are route reload and placeable import; `deleteMap` already covers the mission change. Defer, do not pretend.

### `FlyoverHud.lua` — 3 edits

```
:87    add("note", "Standard AD editing is suspended")
    →  unchanged in text, but it is only TRUE once wrapper 1 is installed. Keep it; if stage 3
       fails, change it rather than leaving the panel lying.

:95    string.format("%d  %s", i % 10, ...)
    →  local key = (i <= 10) and tostring(i % 10) or " "
       add("tool", string.format("%s  %s", key, ...))
       -- TOOL_NAMES has 11 entries (FlyoverEditor.lua:120) but the binding at :786 is
       -- (tool == 10) and "KEY_0" or ("KEY_" .. tool), so tool 11 asks for Input["KEY_11"] = nil
       -- and has no key. The panel currently prints "1  divide", duplicating tool 1's "1  place".

:193-196  drop the "changed in AutoDrive's settings page" comment; and
       string.format("%.1f m", AutoDrive.getSetting("flyoverMergeDistance") or AutoDrive.FLYOVER_MERGE_DISTANCE)
    →  string.format("%.1f m", ADFlyoverSettings.get("flyoverMergeDistance") or AutoDrive.FLYOVER_MERGE_DISTANCE)
```

The four `(wheel)` labels at `:141/:178/:180/:183` need **no** edit — wrapper 4 makes them true again.

### `FlyoverEditor.lua` — 9 edits

```
:1114  if AutoDrive.getControlledVehicle() == nil then
    →  -- Draw the fallback whenever the proxy did NOT draw this frame - on foot, with no AD
       -- vehicle to borrow, or after the proxy has failed its retry budget. The old test was
       -- "am I on foot", which was right only while the fork's Specialization.lua:829 re-centring
       -- existed; here the proxy is the thing that may or may not have run.
       if ADFlyoverProxy == nil or not ADFlyoverProxy.drewThisFrame then

:1835  get = function() return AutoDrive.getSetting(name) end,
    →  get = function() return ADFlyoverSettings.get(name) end,

:1877  local setting = AutoDrive.settings ~= nil and AutoDrive.settings[name] or nil
    →  local setting = ADFlyoverSettings.settings[name]

:1895  AutoDrive.setSettingState(name, bestIndex)
       return setting.values[bestIndex]
    →  return ADFlyoverSettings.setIndex(name, bestIndex)

:3670  AutoDrive.getSetting("flyoverMergeDistance")   → ADFlyoverSettings.get("flyoverMergeDistance")
:3757  (same)
:3787  AutoDrive.getSetting("flyoverMergeDivergence") → ADFlyoverSettings.get("flyoverMergeDivergence")

:4048  local marginDistance = AutoDrive.getSetting("fieldLoopMargin")
       local treeClearance  = AutoDrive.getSetting("fieldLoopTreeClearance")
       local turningRadius  = AutoDrive.getSetting("fieldLoopTurningRadius")
    →  local marginDistance = ADFlyoverSettings.get("fieldLoopMargin")    or AutoDrive.FIELD_LOOP_DEFAULT_MARGIN
       local treeClearance  = ADFlyoverSettings.get("fieldLoopTreeClearance") or 1.25
       local turningRadius  = ADFlyoverSettings.get("fieldLoopTurningRadius")  or 8
       -- The `or` fallbacks are what the merge reads at :3670/:3757 already have. Without them a
       -- nil margin becomes `-nil` at OffsetGeometry.lua:355 - a hard Lua error on the first click,
       -- on a path (register mouseEvent -> :1292 onLeftRelease -> :1355) with no pcall.
```

Plus the `g_server` refusal in `enable()` from §5.6 (a tenth edit), and the two comment corrections at `:17-18` and `:1114`.

`:655`'s `AutoDrive.getSetting("showHUD")` stays — stock has `showHUD` and `ADFlyoverSettings.get` would fall through to it anyway. `:2750`'s `overrideWayPointId` and `:3202`'s `handleWheel` need no edit; the wrappers reach them.

**Known, unfixed, worth logging:** `FlyoverHud.lua:140` reads `AutoDrive.splineInterpolationUserCurvature`, which is *stock* state (`Hud.lua:560/578` nil it, `Tasks/HandleHarvesterTurnTask.lua:234` sets it to 5). Wrapper 1 stops the Hud writes while the editor is open, but a harvester turn task can still rewrite the displayed curvature mid-session. Re-assert the editor's curvature at the top of each spline preview recompute rather than trusting the field to survive the frame.

---

## 7. Staged build order

Every stage ends with a mod that loads and a single thing to look at in the log or on screen. Test against **stock AutoDrive 3.0.0.8 with `FS25_AutoDrive_Gibbs` disabled** throughout — the fork does all of this natively and a pass with it enabled proves nothing.

### Stage 1 — the prelude alone. *Smallest thing that proves the mechanism.*
Ship `modDesc.xml`, `icon.dds`, `Prelude.lua`, `Arming.lua`, `EnvProbe.lua`, `Settings.lua`. `EDITOR_FILES` is empty; `Wrappers.install` and `Proxy` are stubs. Register only `FlyoverStatus`.

**Verify:** load a savegame with AutoDrive active, run `FlyoverStatus`. The log must contain, in order: `resolved AutoDrive on attempt N via g_vehicleTypeManager onDrawUIInfo listener scan`, `sourced files land in <X> environment`, `republished AutoDrive, ADGraphManager, ADDrawingManager, ADEnterTargetNameGui`, `ARMED`. **The environment line is the finding.** If it says anything other than "OUR OWN mod", note which — everything downstream depends on it, and §3.1 exists because nobody knows the answer yet. Then disable AutoDrive and reload: the log must say it gave up after 300 attempts and the game must be otherwise normal.

### Stage 2 — geometry only, no camera.
Add `PolygonUtils.lua` and `OffsetGeometry.lua` to `EDITOR_FILES`, unchanged. Add a throwaway `FlyoverGeomTest` console command that calls `ADOffsetGeometry.generateOffset` on a small hardcoded ring.

**Verify:** `FlyoverGeomTest` returns a point count and no `attempt to index global 'ADPolygonUtils'`. This proves republish-then-source ordering and the copy-in write direction in one command, before any camera is involved.

### Stage 3 — the wrappers, still no editor.
Add `Wrappers.lua` with wrappers 1, 2, 2b, 3, 4 only. Fake the gate with `ADFlyoverWrappers.testActive = true` toggled by a `FlyoverFakeActive` command, and make `editorActive()` return it while `ADFlyoverEditor` is nil.

**Verify, sitting in an AD vehicle with the HUD on:** `FlyoverFakeActive` → the AutoDrive HUD vanishes, the waypoint network appears even with EditorMode off, clicking the HUD area does nothing, and the wheel still zooms. Toggle off → all four come back. This is where you learn whether wrapper 2 or only wrapper 2b is doing the HUD suppression; the log counter tells you which.

### Stage 4 — the proxy. **This is where item 1 of the gap list is actually measured.**
Add `Proxy.lua` and wrapper 6. Reuse the spike's `ADProxySpikeAt`-style command to place the cursor 200 m away while `testActive` is on.

**Verify:** the network draws around the cursor marker, in AutoDrive's own colours, with the player still in a vehicle 200 m away. Then check `FlyoverStatus`: `proxyDraws` climbing, and `sawOnDrawUIInfo` — if that one is **zero**, `onDrawUIInfo` does not raise in this situation and wrapper 2b is carrying the HUD suppression alone. Either result is fine; the point is to know before the camera lands.

### Stage 5 — the editor, in-vehicle only.
Add `FieldLoopGenerator.lua`, `FlyoverHud.lua`, `EditorHistory.lua`, `FlyoverEditor.lua` with all edits. Register the three real console commands. Remove the fake gate.

**Verify:** `FlyoverEditor` from inside a vehicle. Camera detaches; WASD flies it; the panel draws; the network draws around the cursor and not the vehicle; place, move, connect, delete, smooth, divide all work; **the spline tool actually places a curve** (that is the single sharpest signal that wrapper 1 is live); the wheel changes divide count and smooth strength instead of zooming; NAME opens the dialog and names the *clicked* waypoint; the field-loop tool runs without a `-nil` arithmetic error; typed values in the merge and field-loop number rows stick. Then Esc, and check that WASD still moves the player — if not, `FlyoverResetInput`.

### Stage 6 — lifecycle, persistence, refusals.
No new code except `tools/make_release.py`.

**Verify, in one sitting:** (a) change merge distance, quit to menu, reload — the value persists, and `AutoDrive_config.xml` has *not* grown a `flyoverMergeDistance` key; (b) open the editor, quit to the main menu *with it still open*, load a different savegame — the AutoDrive HUD is present and normal, and `FlyoverEditor` opens cleanly rather than crashing on a missing input context (this is the `contextCreated` bug at `FlyoverEditor.lua:49/508`); (c) join a listen server as a client and run `FlyoverEditor` — it refuses with the server message; (d) enable the Gibbs fork alongside — the log says "refusing to load: the installed AutoDrive already has the flyover editor built in" and nothing else happens; (e) `describeBuild` in the log reports *this* mod's commit.

---

## 8. Risks, honestly

**1. `source()` at runtime lands in an environment we did not expect.** *Most likely to break, and it breaks stage 1.* `g_currentModName` is nil during an update tick and there is no documentation on what FS25 does then. **Detected:** the `sourced files land in <X> environment` line, plus the `published nothing we can see` refusal. **Fallback:** the probe already tells us the answer, and `republish()` writes into whatever it reports — so the *design* survives any answer. The failure case is the third one: some environment that is neither ours nor root, where our own `Wrappers.lua` cannot see `ADFlyoverEditor`. Recovery is to keep a module handle (`ADFlyoverArming.target.ADFlyoverEditor`) instead of relying on the bare global in the companion's own files. Cheap insurance: write `editorActive()` as `local E = ADFlyoverArming.target and ADFlyoverArming.target.ADFlyoverEditor` from the start.

**2. `onDrawUIInfo` stops raising once `GuiTopDownCamera` is active.** Untested, and `AutoDrive.lua:238/739-745` is AutoDrive working around exactly this for the construction screen. **Detected:** `sawOnDrawUIInfo == 0` at stage 4. **Fallback:** already built in — the proxy rides `AutoDrive.draw` (wrapper 6) so the network still renders, and wrapper 2b (`AutoDrive.Hud.drawHud`) still hides the HUD. Nothing is lost. This is why the plan does not put anything load-bearing on `onDrawUIInfo`.

**3. Wrapper installation is too early or too late.** `AutoDrive.Hud` is built at `AutoDrive.lua:228` and `GuiTopDownCamera.onZoom` is overwritten at `:243`, both inside AutoDrive's `loadMap`. Arming from `update()` should always be after. **Detected:** the `AutoDrive.Hud was not built yet` warning. **Fallback:** re-attempt the `Hud.drawHud` wrapper on each of the first N update ticks after arming.

**4. The proxy's O(n) rescan hurts on a big network.** `Specialization.lua:868` runs `updateWayPointsDistance` with cursor coordinates over ~17k waypoints, and `:858-863` forces a full rebuild every ~100 m of pan. **Detected:** frame time while panning fast, zoomed out. **Fallback:** rate-limit `runProxyDraw` to every Nth frame, or every X metres of cursor movement — the network is static between edits, so a 3-frame refresh is invisible.

**5. A stock AutoDrive point release moves something the wrappers depend on.** **Detected:** `checkSurface` refuses to arm and names every missing symbol — that is what the whole `want()` block is for. **Fallback:** the mod does nothing and says why, which is the correct behaviour for a guest.

**6. The input context strands the player's movement keys.** This is the pre-existing risk documented in `flyover-input-context.md`, unchanged by the port and unfixed by it. **Detected:** WASD dead after Esc. **Fallback:** `FlyoverResetInput`. Ship it, document it in the modDesc description (it is there in §2), and keep `deleteMap`'s reset so it cannot leak across savegames.

**7. Undo restores a graph that no longer exists.** Nothing invalidates the stack when AutoDrive replaces the graph from route reload or placeable import (§6, EditorHistory "not fixed"). **Detected:** undo produces a network from before a route reload. **Fallback:** documented limitation; the reentrancy-guarded `setWayPoints` wrapper is the fix if it becomes real.

**The single most valuable half-hour:** stage 4's `sawOnDrawUIInfo` count. It settles the one question the feasibility work explicitly did not test, and it is the only measurement in this plan whose answer could still change the design.

---

# Appendix — what a per-file analysis structurally cannot see

## What the per-file passes structurally could not see

I read `companion-mod-investigation.md` (in the AutoDrive fork repo), `docs/flyover-input-context.md`, `register.lua`, `modDesc.xml`, the full fork diff (`git diff b24fbaa HEAD`), and the spike itself at `C:/Dropbox/Stuff/FS25 Mods/FS25_FlyoverProxySpike`. Fourteen gaps, in rough order of how much they would hurt.

---

### 1. The spike did not test the flyover camera, and section B's premise depends on it

`C:/Dropbox/Stuff/FS25 Mods/FS25_FlyoverProxySpike/README.md` ends with a section headed "What it does not test": *"Mouse and keyboard routing, the flyover camera, settings injection, multiplayer."* Every number in the settled facts — 226,211 `onDrawUIInfo` interceptions, 10,010 forced `isEditorShowEnabled`, 4,813 proxy `onDrawEditorMode` calls — was measured with the player sitting in a vehicle in ordinary gameplay, with no `GuiTopDownCamera` activated and no input context pushed. The spike's own commands (`ADProxySpike`, `ADProxySpikeAt`) just move a marker; they never enter the flyover mode.

That matters because `AutoDrive:onDrawUIInfo` early-returns at `scripts/Specialization.lua:524-528` unless `AutoDrive.getControlledVehicle() == self`, and **AutoDrive itself already had to work around exactly this failure once**: `scripts/AutoDrive.lua:238` appends `ConstructionScreen.draw` and `scripts/AutoDrive.lua:739-745` calls `AutoDrive.onDrawEditorMode(vehicle)` plus `ADDrawingManager:draw()` by hand — because the normal `onDrawUIInfo` raise stops when a top-down camera screen owns the frame. The flyover editor activates the same camera class, screen-less. Nobody has measured whether the raise survives that.

If it does not, three things die silently and simultaneously: HUD suppression, the forced `isEditorShowEnabled`, and the proxy network draw (the gate that reaches `onDrawEditorMode` at all is `Specialization.lua:547`, inside `onDrawUIInfo`). The fork is equally dead in that case, which is why nobody has noticed — the fork's flyover mode may be relying on `onDrawUIInfo` continuing to fire, and that has never been isolated as a separate fact.

**Consequence:** measure it with the camera actually active before building on section B. And promote the doc's parenthetical "one refinement" — queue the proxy call from a wrapper on `AutoDrive.draw`, which is a mod event listener called unconditionally every frame — from an aside to the plan of record. It is the version that does not depend on an untested raise.

### 2. The proxy `self` writes into a real vehicle's state, from the cursor, every frame

Nothing in the six files can show this, because it happens entirely inside AutoDrive's `Specialization.lua`. With a stand-in `self` whose `components[1].node` is at the cursor:

- `Specialization.lua:858-863` compares the draw centre against `self.ad.lastDrawPosition` and calls `self:resetWayPointsDistance()` whenever the cursor moves more than `AutoDrive.drawDistance / 2` — that is `getViewDistanceCoeff() * 100` (`AutoDrive.lua:21`), roughly 100 m. Every pan of the flyover camera past that threshold forces a full rebuild.
- `Specialization.lua:868` then calls `self:updateWayPointsDistance(x, z)` with the **cursor** coordinates. That function (`Specialization.lua:1536-1571`) is an O(n) loop over the entire network — 17,174 waypoints in the test savegame — and it overwrites `self.ad.distances.wayPoints`, `distances.closest`, `distances.closestNotReverse` and `ad.wayPointsInRange` on the vehicle the player is entered in, which may be actively driving a route.

Correctness mostly self-heals, because `getClosestWayPoint(nil)` forces a recompute from the real node (`Specialization.lua:1616-1620`). But `ad.wayPointsInRange` is consumed from the cache (`Hud.lua:520`), and the per-pan full rescan is a frame cost the companion inherits and cannot avoid without dropping the proxy.

### 3. "Load order does not need to be relied on" is true for reaching the table and false for three of the proposed hooks

The doc settles load order on the grounds that all mods are sourced before any `loadMap`. That is correct for the listener scan. It is not correct for what the file analyses want to do afterwards:

- **`AutoDrive.Hud` does not exist until `AutoDrive.lua:228`**, inside AutoDrive's own `loadMap`. The FlyoverHud analysis's fix — wrap `AutoDrive.Hud.drawHud` — is a nil index if the companion's `loadMap` runs first. Same for anything that assumes `ADGraphManager:load()` (`AutoDrive.lua:218`) or `AutoDrive.loadStoredXML()` (`:220`) has already run.
- **`GuiTopDownCamera.onZoom = Utils.overwrittenFunction(...)` is installed at `AutoDrive.lua:243`, in `loadMap`.** The doc's suggestion to "wrap the same engine function *after* AutoDrive did, so you end up outermost" is a coin flip the companion does not control.
- The settings-injection window is `XML.lua:90-96`, reached from `AutoDrive.lua:220`.

**Fix:** arm from the companion's first `update()` tick (or an appended `Mission00.loadMission00Finished`), not from `loadMap`, and re-check until armed. That is a scaffolding decision no per-file pass could make.

### 4. The two file analyses give contradictory wheel fixes, and only one is right

FlyoverHud's analysis says wrap `GuiTopDownCamera.onZoom` and explicitly "do NOT wrap `AutoDrive.handleSplineCurvature`". FlyoverEditor's analysis says wrap `handleSplineCurvature`. The second is correct, and the reason is in `handleWheel` itself:

`ADFlyoverEditor:handleWheel` (`FlyoverEditor.lua:3202-3238`) returns **false** for the SPLINE tool on purpose, so the wheel falls through to AutoDrive's curvature clamp at `UtilFuncs.lua:1041-1044`. That fallthrough is what the fork's hook at `UtilFuncs.lua:1032-1039` preserves and what an outermost `onZoom` wrapper destroys, unless it re-implements the fallthrough by calling `AutoDrive:handleSplineCurvature` itself. `handleSplineCurvature` is invoked by name at `UtilFuncs.lua:1049` and `:1055`, so it is wrappable. It also returns `AutoDrive.mouseWheelActive` as its last resort — state the editor resets on teardown — which an `onZoom`-level hook never sees.

### 5. The listener scan cannot tell stock from the fork, or one AutoDrive from two

The scan identifies AutoDrive *structurally*, which is what makes it robust — and also what makes it unable to distinguish builds. `typeDef.eventListeners.onDrawUIInfo` can hold more than one matching table when two AutoDrive derivatives are installed, and `pairs()` over `g_vehicleTypeManager.types` has no defined order. Note also that `register.lua`'s `check()` was widened in this fork from `g_currentModName == "FS25_AutoDrive"` to a `string.sub(...) == "FS25_AutoDrive"` prefix test, so stock and the fork can both arm in the same session.

If the companion binds to the fork:

- The fork's environment already contains `ADFlyoverEditor`, `ADEditorHistory`, `ADFlyoverHud`, `ADOffsetGeometry`, `ADPolygonUtils` and `ADBuildInfo`. A blanket "republish everything from `getfenv`" imports the fork's editor and then either shadows or is shadowed by the companion's own copies, depending purely on whether the republish runs before or after the `source()` calls. The plan fixes that ordering for the *stock* case only.
- The fork's in-file guards (`AutoDrive.lua:597-601`, `Specialization.lua:534-536` and `:829-834`, `UtilFuncs.lua:1035-1039`, `AutoDriveUtilFuncs.lua:284-290`) read the **fork's** `ADFlyoverEditor`, which will be inactive, so they never fire — while the companion's wrappers stack on top of guards that are already there.
- The three console command names in `DevFuncs.lua:94-97` collide.

**Fix:** refuse to arm, with a log line, when the resolved environment already contains `ADFlyoverEditor`. And make the republish an explicit allow-list rather than a bulk copy of the 49 `AD*` tables.

The allow-list is far shorter than the spike's "8 needed" set suggests. Grepping the six files for each of those eight: `ADGraphManager` (122 uses), `ADDrawingManager` (11), `ADEnterTargetNameGui` (3), `AutoDrive` — and that is all. `ADInputManager`, `ADMessagesManager`, `ADRoutesManager` and `ADStateModule` appear **zero** times; `ADCollSensor` appears once, in a comment at `FieldLoopGenerator.lua:92`; `AutoDriveHud` appears once, in a comment at `FlyoverEditor.lua:649`. The spike's list was the *probe's* checklist, not the editor's dependency set, and the doc reads as though they are the same thing.

### 6. Session lifecycle across savegames — `contextCreated` is never reset

`ADFlyoverEditor.contextCreated` is declared at `FlyoverEditor.lua:49`, read at `:508`, set at `:513`, and appears nowhere else in the file. `AutoDriveRegister:deleteMap()` is empty. FS25 does not re-source mod Lua when the player returns to the main menu and loads a different savegame, but `g_inputBinding`'s contexts are rebuilt for the new mission.

So on the second mission's first activation, `setContext("AD_FLYOVER_EDITOR", false, false)` is called for a context that does not exist — the exact mirror image of bug 4 in `flyover-input-context.md`, and the one case the `contextCreated` guard gets wrong. `active`, `camera`, `cursor`, `contextPushed` and `ADEditorHistory.redoStack` survive the mission change too; if a mission ends with the editor open, `active` stays true and the companion's wrappers go on suppressing **stock AutoDrive's** HUD indefinitely in the next session — precisely the blast-radius problem that doc warns about, except now the fault presents as an AutoDrive bug. The companion needs a `deleteMap` / mission-end reset. Nothing in the six files provides one, and the fork needs the same fix.

### 7. Multiplayer and savegame, stated together, are worse than either alone

`AutoDrive:saveSavegame` (`AutoDrive.lua:542-550`, hooked via `ItemSystem.save` at `:238`) writes routes **only when `g_server ~= nil`**. Put that next to the fact that only PLACE (`FlyoverEditor.lua:2141`) and FIELDLOOP (`:4040`) guard on `g_server == nil`, and that every graph write passes `sendEvent = false`: an MP client can spend an entire session editing, and nothing is sent to the server, nothing is persisted, and the next server broadcast silently reverts it. There is no user-visible signal at any point.

The honest minimum for a companion is one check in `enable()` — refuse to open when `g_server == nil` — rather than adding guards tool by tool. Note also that `ADGraphManager.changes` is *not* a save gate (`saveToXML` runs unconditionally), so persistence is not at risk in single-player; I checked every raw-write path (`convertAtCursor`, `absorbTrack`, `commitDivide`, `generateFieldLoopAtCursor`) and each does call `markChanges()`.

### 8. Injecting into `AutoDrive.settings` on a host hard-errors stock clients

The FieldLoopGenerator pass found this; it deserves promoting from "one of several settings problems" to a rule, because it is the only one that breaks *other people's* game. `AutoDriveUpdateSettingsEvent:writeStream` (`Events/UpdateSettingsEvent.lua:19-33`) iterates `pairs(AutoDrive.settings)` and writes each name plus `setting.current` as a `UInt16`; `readStream` (`:78-84`) does an unguarded `AutoDrive.settings[settingName].current = value`. A stock client joining a host that injected six extra keys takes an "index a nil value" and loses the rest of the settings sync.

**Rule, not option: never add keys to `AutoDrive.settings`.**

### 9. Settings have a shape, not just a presence

`ADFlyoverEditor:applySettingValue` (`FlyoverEditor.lua:1875-1894`) snaps a typed number to the nearest entry of `setting.values` and calls `AutoDrive.setSettingState(name, bestIndex)`; `AutoDrive.getSetting` returns `values[current]` (`Settings.lua:1832-1849`). AutoDrive settings are **discrete indexed option lists**, not floats. A companion-owned settings store has to either reproduce that shape — so the panel's snapping behaviour and the `getEditableNumbers` contract survive — or accept that the six number rows change meaning to free-form entry. That is a design decision, and it should be made deliberately rather than discovered.

### 10. `ADEnterTargetNameGui` wrapping is viable — verified, not assumed

Two analyses asserted "instances index the class" without checking. It holds: `Class(ADEnterTargetNameGui, DialogElement)` at `Gui/EnterTargetNameGUI.lua:11` makes the instance metatable's `__index` the class table, and `Gui.lua:7` / `:24` register `ADEnterTargetNameGui.new()` under the name the editor shows (`g_gui:showDialog("ADEnterTargetNameGui")`), so a class-level wrapper on `onOpen` / `onClickOk` is seen. Worth noting that `overrideWayPointId` is read off the **class table**, not `self` (`EnterTargetNameGUI.lua:32`) — the companion sets it exactly as the fork does; only the reading branches need replicating.

### 11. Wrappers do survive later vehicle spawns — worth stating positively

`AutoDriveRegister.registerAutoDrive()` runs once, from `check()` at the bottom of `register.lua`; the `TypeManager.validateTypes` prepend only re-publishes translations. Vehicle instances clone `eventListeners` depth-2, so the stored entries remain the same table by reference. Nothing AutoDrive does after load re-registers or replaces the listener table, so wrappers installed once do not need re-installing when vehicles spawn or when a savegame loads a new fleet. This is the one lifecycle question the doc left implicit and it resolves in the companion's favour.

### 12. `flyover-input-context.md` is wrong about modDesc, and acting on it would create the bug it documents

`docs/flyover-input-context.md:128-131` says the editor's key bindings are declared in AutoDrive's `modDesc.xml` and that a companion therefore needs its own non-colliding `<actions>` / `<inputBinding>` block. `companion-mod-investigation.md` item 4 repeats it. **`grep -i flyover modDesc.xml` returns nothing.** The editor reads raw key symbols through its own `isKey` helper (`FlyoverEditor.lua:772-808`) and registers only the base-game `InputAction.MENU_CANCEL` / `MENU_BACK` (`FlyoverEditor.lua:560-568`). The `AD_FLYOVER_EDITOR` context is created at runtime and needs no modDesc entry.

Correct the doc. Adding action names on the strength of it would introduce exactly the collision risk that document exists to prevent.

### 13. Scaffolding items that have no owner

- **The file list is wrong twice.** The table in `companion-mod-investigation.md` lists `PolygonUtils.lua`, but the prose says "six files" throughout and every consumer treats it as six. It is seven. `register.lua:74-84` gives the required source order: PolygonUtils → OffsetGeometry → FieldLoopGenerator → (BuildInfo) → FlyoverHud → EditorHistory → FlyoverEditor.
- **None of the seven may go in `<extraSourceFiles>`**, because `FlyoverEditor.lua:123-159` and `FieldLoopGenerator.lua:18-38` index `AutoDrive` at source time. Only the companion's prelude is listed; it sources the seven by hand after arming.
- **`ADFlyoverResetInput` must survive the port.** It is registered at `DevFuncs.lua:97`, which is fork-only and inside the dev-gated `AutoDrive.devAutoDriveInit`. `flyover-input-context.md` is explicit that it is the only recovery path from a stranded input context — "the alternative had twice been restarting the game". It reads like diagnostic scaffolding and is not.
- **`ADBuildInfo`** (`FlyoverEditor.lua:298-305`) comes from `tools/make_release.py` writing into AutoDrive's tree. The companion needs its own generator, or `describeBuild` reports the *host's* build whenever the fork is installed and a blanket republish is used — which is the wrong answer to the exact question that function exists to answer.
- **Translations:** none of the seven files uses `g_i18n`, so nothing is needed today. If that changes, the mechanism is the one at the bottom of `register.lua`: AutoDrive publishes its texts into the true root `getfenv(0).g_i18n.texts`, because mod-scoped l10n lookup only works for vehicles.
- `modDesc.xml` still needs a real `<iconFilename>` .dds and a `<multiplayer supported="..."/>` that matches the decision in item 7.

### 14. Two edits to the copied files are cheaper than the wrappers they replace

Restating from the per-file passes because they land differently once the cross-file picture is in view: dropping the `AutoDrive.getControlledVehicle() == nil` guard at `FlyoverEditor.lua:1114` makes `drawNetworkFallback` unconditional, which is the only thing that keeps the editor usable at all if item 1 turns out badly — one line, and it is the fallback for the on-foot case regardless, since `onDrawUIInfo` provably never fires with no controlled vehicle (`Specialization.lua:524-528`). And giving `FlyoverEditor.lua:4048-4050` the same `or <constant>` fallback the merge reads already have at `:3670` / `:3757` turns a hard `-nil` arithmetic error into a working default. "Copied across unchanged" is worth giving up for both.

---

**The one-line summary of the whole pass:** the feasibility work proved that a companion can *reach* AutoDrive and *rewrite* its functions, and both hold up. What it did not prove — and explicitly says it did not test — is that AutoDrive still *calls* those functions once the flyover camera and its input context are up. Everything in section B rests on that, and it is a half-hour measurement.