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
P.BUILD = "0.4.0.0"
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

-- Sourced in dependency order once arming succeeds; the order is the same one AutoDrive's own
-- register.lua uses. Stage 2 enables the two pure-geometry files, which are copied VERBATIM from
-- the fork - that is the premise being tested.
P.EDITOR_FILES = {
    "scripts/editor/PolygonUtils.lua",
    "scripts/editor/OffsetGeometry.lua",
    -- "scripts/editor/FieldLoopGenerator.lua",
    -- "scripts/editor/FlyoverHud.lua",
    -- "scripts/editor/EditorHistory.lua",
    -- "scripts/editor/FlyoverEditor.lua",
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

function P:draw()
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

addConsoleCommand("FlyoverProxyAt", "Stage 4: draw the network at x z instead of at the vehicle", "consoleProxyAt", P)
addConsoleCommand("FlyoverProxyOff", "Stage 4: turn the proxy and the fake gate off", "consoleProxyOff", P)
addConsoleCommand("FlyoverFakeActive", "Stage 3: pretend the editor is open, to exercise the wrappers", "consoleFakeActive", P)
addConsoleCommand("FlyoverStatus", "Report what the flyover editor attached to", "consoleStatus", P)

Logging.info("[%s] build %s loaded", P.MOD_NAME, P.versionString())

addModEventListener(P)
