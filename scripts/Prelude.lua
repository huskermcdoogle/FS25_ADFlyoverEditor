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

P.MOD_NAME = "ADFlyoverEditor"
P.MOD_DIRECTORY = g_currentModDirectory

-- Give AutoDrive a generous window to appear, then stop trying and say so. Roughly 300 frames.
P.MAX_ATTEMPTS = 300

-- Stage 1 ships no editor files. Sourced in dependency order once arming succeeds; the order is
-- the same one AutoDrive's own register.lua uses.
P.EDITOR_FILES = {
    -- "scripts/editor/PolygonUtils.lua",
    -- "scripts/editor/OffsetGeometry.lua",
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

    P.state = "armed"
    log("ARMED. %d editor file(s) sourced. Settings: %s", #P.sourcedFiles, ADFlyoverSettings.describe())
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
        string.format("state=%s", P.state),
        ADFlyoverArming.describe(),
        string.format("sourced files land in: %s", tostring(P.sourceEnvName)),
        string.format("editor files sourced: %d", #P.sourcedFiles),
        ADFlyoverSettings.describe(),
    }
    for _, line in ipairs(lines) do
        log("%s", line)
    end
    return table.concat(lines, " | ")
end

addConsoleCommand("FlyoverStatus", "Report what the flyover editor attached to", "consoleStatus", P)

addModEventListener(P)
