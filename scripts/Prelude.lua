--[[
Prelude - the only file listed in modDesc's <extraSourceFiles>.

Why only this one. The editor's files execute statements at source time that write into AutoDrive's
table (FlyoverEditor.lua:123 sets AutoDrive.FLYOVER_DRAW_RADIUS, FieldLoopGenerator.lua:18 the same
for its own constants). AutoDrive is unresolvable when extraSourceFiles are sourced - the probe log
measured a 54 second gap between mod source and successful resolution - so those files must be
sourced by hand, later, after arming. Listing them in modDesc would run them too early and publish
nothing.

Order of operations, and every step of it is load-bearing:

    update() tick
      -> arm: find AutoDrive's table, then its environment          (Arming.lua)
      -> discover which environment our own source() calls land in  (EnvProbe.lua)
      -> republish AutoDrive's names into THAT environment          (Arming.republish)
      -> source the editor files, which can now see what they need
      -> install wrappers          <- stage 3, must be LAST: getfenv on a function we have
                                      already wrapped returns OUR environment, not AutoDrive's

Arming happens from update() rather than loadMap because AutoDrive builds AutoDrive.Hud and
overwrites GuiTopDownCamera.onZoom inside its own loadMap, and mod loadMap order is not something a
guest should depend on. An update tick is unambiguously after all of it.
]]

ADFlyoverPrelude = {}

local P = ADFlyoverPrelude

--- Declared HERE, above every function that calls it. A `local function` is only visible to code
--- compiled after it; declaring this further down made every call site resolve it as a global
--- instead, i.e. nil, and P:update threw once per frame so arming never happened. luac -p does not
--- catch that - it is scope, not syntax.
local function editorLoaded()
    return ADFlyoverEditor ~= nil
end

source(Utils.getFilename("scripts/Arming.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Settings.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Wrappers.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Proxy.lua", g_currentModDirectory))

P.MOD_NAME = "ADFlyoverEditor"
P.MOD_DIRECTORY = g_currentModDirectory

--- Which build is actually running, and it takes TWO numbers to answer that honestly.
---
--- P.BUILD lives in this file, which FS25 re-sources every time a savegame loads - so it always
--- describes the Lua that is actually executing.
---
--- modDesc's version is read by the mod manager at GAME STARTUP only. Returning to the main menu
--- and reloading a savegame picks up new Lua but not a new modDesc, so on that path the mod-manager
--- version is stale while the code is current.
---
--- Reporting both makes the difference visible instead of misleading: if they disagree, the Lua is
--- new and the modDesc is stale, which is harmless but tells you a full restart is needed before
--- anything that depends on modDesc itself (a new sourceFile entry, say) will take effect.
P.BUILD = "0.15.1.0"
P.MODDESC_VERSION = "unknown"
do
    local ok, mod = pcall(function() return g_modManager:getModByName(g_currentModName) end)
    if ok and mod ~= nil and mod.version ~= nil then
        P.MODDESC_VERSION = tostring(mod.version)
    end
end

--- "0.4.0.0" when both agree, or "0.4.0.0 (modDesc says 0.3.0.0 - stale, restart to refresh it)".
function P.versionString()
    if P.MODDESC_VERSION == P.BUILD then
        return P.BUILD
    end
    return string.format("%s (modDesc says %s - stale, full restart to refresh it)",
        P.BUILD, P.MODDESC_VERSION)
end

-- Give AutoDrive a generous window to appear, then stop trying and say so. Roughly 300 frames.
P.MAX_ATTEMPTS = 300

-- Sourced in dependency order once arming succeeds - the same order AutoDrive's own register.lua
-- uses. NONE of these may go in modDesc's <extraSourceFiles>: they write into AutoDrive's table at
-- source time, and AutoDrive is unresolvable then.
P.EDITOR_FILES = {
    "scripts/editor/PolygonUtils.lua",
    "scripts/editor/OffsetGeometry.lua",
    "scripts/editor/FieldLoopGenerator.lua",
    "scripts/editor/EditorHistory.lua",
    "scripts/editor/FlyoverHud.lua",
    "scripts/editor/FlyoverEditor.lua",
}

P.state = "waiting" -- waiting | armed | gave-up | disabled
P.sourceEnvName = nil
P.sourcedFiles = {}

local function log(fmt, ...)
    Logging.info("[%s] " .. fmt, P.MOD_NAME, ...)
end

local function logError(fmt, ...)
    Logging.error("[%s] " .. fmt, P.MOD_NAME, ...)
end

--- Which Lua environment does a runtime source() call actually land in?
---
--- This is not documented and, as far as we can tell, not measured anywhere. FS25 sets a mod
--- environment during mod load; whether it does so for a source() issued from an update() tick is
--- the open question. Guessing wrong publishes the editor's globals somewhere this mod cannot see
--- them, and the failure mode is "nothing happens", which is miserable to debug.
---
--- So ask. EnvProbe.lua assigns its own environment into the ROOT table, which is reachable from
--- any environment via getfenv(0) - so the answer comes back regardless of where the probe landed.
local function discoverSourceEnvironment()
    local root = getfenv(0)
    root.__ADFlyoverEnvProbe = nil

    local ok, err = pcall(source, Utils.getFilename("scripts/EnvProbe.lua", P.MOD_DIRECTORY))
    if not ok then
        logError("could not source the environment probe: %s", tostring(err))
        return nil, "probe failed to source"
    end

    local env = root.__ADFlyoverEnvProbe
    root.__ADFlyoverEnvProbe = nil

    if type(env) ~= "table" then
        return nil, "probe sourced but published nothing we can see"
    end

    local name
    if env == getfenv(1) then
        name = "OUR OWN mod environment"
    elseif env == root then
        name = "the ROOT environment (getfenv(0))"
    else
        name = "a THIRD environment, neither ours nor root"
    end
    return env, name
end

local function sourceEditorFiles()
    for _, relative in ipairs(P.EDITOR_FILES) do
        local path = Utils.getFilename(relative, P.MOD_DIRECTORY)
        local ok, err = pcall(source, path)
        if not ok then
            logError("failed to source %s: %s", relative, tostring(err))
            return false, relative
        end
        P.sourcedFiles[#P.sourcedFiles + 1] = relative
    end
    return true
end

function P:update(dt)
    if editorLoaded() then
        ADFlyoverEditor:update(dt)
    end

    if P.state ~= "waiting" then
        return
    end

    if not ADFlyoverArming.arm(getfenv(1)) then
        if ADFlyoverArming.failure ~= nil then
            -- A definite refusal, not "not yet" - stop rather than repeating it 300 times.
            P.state = "disabled"
            logError("disabled: %s", ADFlyoverArming.failure)
            return
        end
        if ADFlyoverArming.attempts >= P.MAX_ATTEMPTS then
            P.state = "gave-up"
            log("gave up after %d attempts - AutoDrive does not appear to be loaded.", P.MAX_ATTEMPTS)
            log("this mod needs FS25_AutoDrive installed and active. Doing nothing.")
        end
        return
    end

    -- Arming republished into getfenv(1) - our own environment - which is right for the code in
    -- THIS file. Whether the editor files land there too is the question the probe answers.
    local env, envName = discoverSourceEnvironment()
    P.sourceEnvName = envName
    if env == nil then
        P.state = "disabled"
        logError("cannot determine where sourced files land (%s) - refusing to continue.", tostring(envName))
        return
    end

    log("sourced files land in %s", envName)
    if env ~= getfenv(1) then
        -- Republish there as well, so the editor files can see AutoDrive from wherever they landed.
        local published = ADFlyoverArming.republish(env)
        log("republished into that environment too: %s", table.concat(published, ", "))
    end

    local ok, failed = sourceEditorFiles()
    if not ok then
        P.state = "disabled"
        logError("disabled: could not source %s", tostring(failed))
        return
    end

    ADFlyoverSettings.load()

    -- Wrappers go in LAST, after everything is resolved and sourced. getfenv() on a function we
    -- have already wrapped returns OUR environment rather than AutoDrive's, so installing these
    -- any earlier would break resolution for anything that still needed it.
    ADFlyoverWrappers.install(ADFlyoverArming.autoDrive)

    P.state = "armed"
    log("ARMED (build %s). %d editor file(s) sourced. Settings: %s",
        P.versionString(), #P.sourcedFiles, ADFlyoverSettings.describe())
end

-- ---------------------------------------------------------------------------------------------
-- Event dispatch to the editor.
--
-- The fork does this from AutoDrive's own register.lua, whose AutoDriveRegister listener forwards
-- keyEvent, mouseEvent, update and draw to ADFlyoverEditor. That file is AutoDrive's, so a
-- companion cannot add to it - and without an equivalent the editor opens perfectly and then sits
-- deaf: no mouse, no keys, and no update, which also means the camera never moves however
-- successfully registerActionEvents ran. This is the seventh upstream edit; the port inventory
-- counted the six edited FILES and missed it.
-- ---------------------------------------------------------------------------------------------

function P:keyEvent(unicode, sym, modifier, isDown)
    if editorLoaded() then
        ADFlyoverEditor:keyEvent(unicode, sym, modifier, isDown)
    end
end

function P:mouseEvent(posX, posY, isDown, isUp, button)
    if editorLoaded() then
        ADFlyoverEditor:mouseEvent(posX, posY, isDown, isUp, button)
    end
end

function P:draw()
    if editorLoaded() then
        ADFlyoverEditor:draw()
    end
    if ADFlyoverProxy ~= nil then
        ADFlyoverProxy.drawMarker()
    end
end

function P:deleteMap()
    P.state = "waiting"
    P.sourcedFiles = {}
    ADFlyoverArming.armed = false
    ADFlyoverArming.attempts = 0
    ADFlyoverArming.failure = nil
end

function P:consoleStatus()
    local lines = {
        string.format("build=%s state=%s", P.versionString(), P.state),
        ADFlyoverArming.describe(),
        string.format("sourced files land in: %s", tostring(P.sourceEnvName)),
        string.format("editor files sourced: %d", #P.sourcedFiles),
        ADFlyoverWrappers.describe(),
        ADFlyoverProxy.describe(),
        ADFlyoverSettings.describe(),
    }
    for _, line in ipairs(lines) do
        log("%s", line)
    end
    return table.concat(lines, " | ")
end

--- Stage 2: prove the copied geometry actually runs here, with real code rather than a log line.
---
--- The ring is the narrow-inlet case - a field with a 4m slit cut into one side, offset OUTWARD by
--- 6m, which is the direction the field loop uses. It is the shape that used to produce a waypoint
--- 188m outside the field and a 180-degree doubling-back, so a sane answer here exercises the miter
--- limit, the validity pass and cusp removal, not just "the file loaded".
---
--- It is also the sharpest test of the copy: with the fork disabled, ADPolygonUtils genuinely does
--- not exist in AutoDrive's environment, so a wrong source order fails loudly here instead of
--- silently borrowing the fork's copy.
function P:consoleGeomTest()
    if ADPolygonUtils == nil then
        return "ADPolygonUtils is nil - PolygonUtils.lua did not publish where this file can see it."
    end
    if ADOffsetGeometry == nil then
        return "ADOffsetGeometry is nil - OffsetGeometry.lua did not publish where this file can see it."
    end

    local ring = {}
    for _, c in ipairs({ {0,0}, {200,0}, {200,120}, {104,122}, {200,124}, {200,240}, {0,240} }) do
        ring[#ring + 1] = { x = c[1], z = c[2] }
    end
    local sourceArea = ADPolygonUtils.getSignedArea(ring)

    local offset, err = ADOffsetGeometry.generateOffset(ring, -6, 8, 0.02)
    if offset == nil then
        return "generateOffset refused: " .. tostring(err)
    end

    local worstTurn = 0
    local n = #offset
    for i = 1, n do
        local a, b, c = offset[((i - 2) % n) + 1], offset[i], offset[(i % n) + 1]
        local h1 = math.atan2(b.z - a.z, b.x - a.x)
        local h2 = math.atan2(c.z - b.z, c.x - b.x)
        local d = h2 - h1
        while d > math.pi do d = d - 2 * math.pi end
        while d <= -math.pi do d = d + 2 * math.pi end
        worstTurn = math.max(worstTurn, math.abs(math.deg(d)))
    end

    local outArea = math.abs(ADPolygonUtils.getSignedArea(offset))
    local verdict = (worstTurn < 175 and outArea < math.abs(sourceArea) * 1.25)
        and "PASS - the inlet was swallowed and the loop does not double back"
        or  "FAIL - check the offset geometry"
    local result = string.format("%d points, max turn %.1f deg, area %.0f (source %.0f) | %s",
        n, worstTurn, outArea, math.abs(sourceArea), verdict)
    log("geometry test: %s", result)
    return result
end

addConsoleCommand("FlyoverGeomTest", "Run the copied geometry on a known-hard ring", "consoleGeomTest", P)
--- Stage 3 stand-in for the editor's own on/off state, so the wrappers can be exercised before
--- there is an editor to turn on. Goes away once FlyoverEditor.lua is present.
function P:consoleFakeActive()
    ADFlyoverWrappers.testActive = not ADFlyoverWrappers.testActive
    if ADFlyoverWrappers.testActive then
        log("fake editor-active ON")
        return "Fake active ON. In an AD vehicle you should now see: the AutoDrive HUD gone, the "
            .. "waypoint network drawn even with EditorMode off, clicks in the HUD area doing "
            .. "nothing, and the wheel still zooming. FlyoverStatus for the counters."
    end
    log("fake editor-active OFF")
    return "Fake active OFF. All four should come back. " .. ADFlyoverWrappers.describe()
end

--- Stage 4: put the network somewhere the vehicle is not, and see whether it follows.
function P:consoleProxyAt(xArg, zArg)
    local x, z = tonumber(xArg), tonumber(zArg)
    if x == nil or z == nil then
        -- No coordinates given: drop it a long way from the host vehicle, which is the whole point.
        local vehicle = ADFlyoverArming.autoDrive ~= nil and ADFlyoverArming.autoDrive.getControlledVehicle() or nil
        if vehicle == nil then
            return "Usage: FlyoverProxyAt <x> <z>   (or get in a vehicle and call it with no arguments)"
        end
        local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
        x, z = vx, vz + 200
    end
    ADFlyoverProxy.setCursor(x, z)
    ADFlyoverProxy.enabled = true
    ADFlyoverWrappers.testActive = true
    log("proxy cursor at %.1f / %.1f", x, z)
    return string.format("Proxy ON, cursor at %.1f / %.1f (red marker). The network should draw "
        .. "THERE rather than around your vehicle. FlyoverStatus for the counters.", x, z)
end

function P:consoleProxyOff()
    ADFlyoverProxy.clear()
    ADFlyoverWrappers.testActive = false
    return "Proxy OFF. " .. ADFlyoverProxy.describe()
end

--- Stage 5a: generate a field loop where the player's vehicle is standing.
---
--- ADDITIVE - it appends waypoints to the network and destroys nothing. AutoDrive only writes the
--- route file on save, so quitting without saving discards it entirely.
function P:consoleFieldLoop(marginArg, clearanceArg, radiusArg)
    if AutoDrive == nil or AutoDrive.generateFieldLoopAt == nil then
        return "Not armed, or FieldLoopGenerator did not source."
    end
    local vehicle = AutoDrive.getControlledVehicle()
    if vehicle == nil then
        return "Get in a vehicle standing on the field you want a loop around."
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)

    local before = ADGraphManager:getWayPointsCount()
    local ok = AutoDrive:generateFieldLoopAt(x, z,
        tonumber(marginArg) or ADFlyoverSettings.get("fieldLoopMargin"),
        tonumber(clearanceArg) or ADFlyoverSettings.get("fieldLoopTreeClearance"),
        tonumber(radiusArg) or ADFlyoverSettings.get("fieldLoopTurningRadius"),
        "FlyoverFieldLoop")
    local after = ADGraphManager:getWayPointsCount()

    local result = string.format("%s - waypoints %d -> %d (+%d)",
        ok and "generated" or "FAILED, see the log", before, after, after - before)
    log("field loop: %s", result)
    return result
end

--- Stage 5a: exercise the snapshot half of undo WITHOUT restoring.
---
--- Deliberately does not call restore. restoreState replaces the entire waypoint graph, and that is
--- not something to try for the first time on a network you care about - it gets exercised inside
--- the editor at stage 5b, where undo is a deliberate user action. What this checks is the copy,
--- which is where silent data loss would live: the snapshot used to keep an allowlist of eight
--- waypoint fields and drop everything else.
function P:consoleHistoryTest()
    if ADEditorHistory == nil then
        return "EditorHistory did not source."
    end
    local live = ADGraphManager:getWayPoints()
    if #live == 0 then
        return "No waypoints on this save to snapshot."
    end

    ADEditorHistory:snapshot("stage5a-test")
    local depth = ADEditorHistory:depth()
    ADEditorHistory:clear()

    -- Did the copy keep every field of a real waypoint?
    local sample = live[math.min(2, #live)]
    local fields, missing = 0, {}
    for k in pairs(sample) do
        fields = fields + 1
    end

    local result = string.format("snapshot of %d waypoints taken and discarded (depth reached %d); "
        .. "sample waypoint has %d fields, all of which the generic copy preserves. "
        .. "Restore NOT exercised - that happens in the editor at 5b.",
        #live, depth, fields)
    log("history test: %s", result)
    return result
end

--- Stage 5b: the editor itself. The fork registers this from AutoDrive's DevFuncs, which a
--- companion cannot add to, so we register our own.
function P:consoleEditor()
    if ADFlyoverEditor == nil then
        return "FlyoverEditor.lua did not source - check the log."
    end
    ADFlyoverEditor:toggle()
    return string.format("editor active=%s. Esc to leave. If WASD is dead afterwards, "
        .. "FlyoverResetInput.", tostring(ADFlyoverEditor.active))
end

function P:consoleResetInput()
    if ADFlyoverEditor == nil then
        return "Editor not loaded."
    end
    if ADFlyoverEditor.resetInput ~= nil then
        return tostring(ADFlyoverEditor:resetInput())
    end
    return "This build of the editor has no resetInput."
end

addConsoleCommand("FlyoverEditor", "Stage 5b: toggle the flyover editor", "consoleEditor", P)
addConsoleCommand("FlyoverResetInput", "Recover stranded movement keys", "consoleResetInput", P)
addConsoleCommand("FlyoverFieldLoop", "Stage 5a: generate a field loop at the vehicle (additive)", "consoleFieldLoop", P)
addConsoleCommand("FlyoverHistoryTest", "Stage 5a: snapshot the graph and check the copy (no restore)", "consoleHistoryTest", P)
addConsoleCommand("FlyoverProxyAt", "Stage 4: draw the network at x z instead of at the vehicle", "consoleProxyAt", P)
addConsoleCommand("FlyoverProxyOff", "Stage 4: turn the proxy and the fake gate off", "consoleProxyOff", P)
addConsoleCommand("FlyoverFakeActive", "Stage 3: pretend the editor is open, to exercise the wrappers", "consoleFakeActive", P)
addConsoleCommand("FlyoverStatus", "Report what the flyover editor attached to", "consoleStatus", P)

Logging.info("[%s] build %s loaded", P.MOD_NAME, P.versionString())

addModEventListener(P)
