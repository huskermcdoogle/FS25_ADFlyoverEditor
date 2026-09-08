--[[
Arming - finding AutoDrive from inside a different mod's Lua environment.

FS25 gives every mod its own environment, so AutoDrive's globals are not visible by name. Measured
in game (see docs/probe-results.md in FS25_FlyoverProxySpike): plain `AutoDrive`,
`getfenv(0).AutoDrive` and `g_specializationManager:getSpecializationByName("AutoDrive")` all return
nil. Two steps get us everything:

  1. Scan g_vehicleTypeManager for the onDrawUIInfo event listener. registerEventListener stores the
     specialization TABLE and raiseEvent looks the function up by name at call time, so this returns
     the real AutoDrive table - identified structurally, so it needs no mod name and works against
     stock and any renamed fork alike.
  2. getfenv() that table's onDrawEditorMode. In Lua 5.1 a function carries the environment it was
     DEFINED in, so this hands back AutoDrive's whole mod environment - measured, 49 AD* tables.

TRAP, measured the hard way: getfenv on a function we have already WRAPPED returns OUR environment,
not AutoDrive's. So resolve before installing any hook, and resolve through a function we will never
wrap. onDrawEditorMode is the safest choice: it is registered with registerFunction, so wrapping it
would not intercept anything anyway and there is never a reason to.
]]

ADFlyoverArming = {}

local A = ADFlyoverArming

A.MOD_NAME = "ADFlyoverEditor"

-- The names the editor actually needs from AutoDrive. This is an allow-list rather than an
-- __index fallthrough to AutoDrive's environment, deliberately:
--
--   * If the player also has the Gibbs fork installed, that environment ALREADY contains
--     ADFlyoverEditor, ADEditorHistory, ADFlyoverHud, ADOffsetGeometry, ADPolygonUtils and
--     ADBuildInfo. A fallthrough would silently resolve those to the FORK's copies, and which won
--     would depend on whether the republish ran before or after our own source() calls. An
--     allow-list cannot import them.
--   * With a plain table an unknown global is nil - exactly the semantics the editor files were
--     written and tested against. A fallthrough turns a typo into a nil-index error one frame
--     later inside a pcall'd draw path, indistinguishable from a real bug.
--
-- Counts are uses across the seven editor files. Base-game globals (MathUtil, Logging, Overlay,
-- g_inputBinding, GuiTopDownCamera, ...) are in every mod environment already and need no entry.
A.REQUIRED = {
    "AutoDrive",           -- ~200 uses
    "ADGraphManager",      -- 122
    "ADDrawingManager",    -- 11
    "ADEnterTargetNameGui", -- 3
}

A.autoDrive = nil    -- AutoDrive's specialization table
A.env = nil          -- AutoDrive's whole mod environment
A.target = nil       -- the environment our own source() calls land in
A.armed = false
A.attempts = 0
A.failure = nil

local function log(fmt, ...)
    Logging.info("[%s] " .. fmt, A.MOD_NAME, ...)
end

local function logError(fmt, ...)
    Logging.error("[%s] " .. fmt, A.MOD_NAME, ...)
end

--- Does this table look like AutoDrive's specialization class?
local function looksLikeAutoDrive(t)
    return type(t) == "table"
        and type(t.onDrawEditorMode) == "function"
        and type(t.onDrawUIInfo) == "function"
        and type(t.isEditorShowEnabled) == "function"
end

--- Step 1: the only route that works. Structural, so no mod name is involved.
function A.resolveAutoDrive()
    if g_vehicleTypeManager == nil or g_vehicleTypeManager.types == nil then
        return nil
    end
    for _, typeDef in pairs(g_vehicleTypeManager.types) do
        local listeners = typeDef.eventListeners ~= nil and typeDef.eventListeners.onDrawUIInfo or nil
        if listeners ~= nil then
            for _, spec in pairs(listeners) do
                if looksLikeAutoDrive(spec) then
                    return spec
                end
            end
        end
    end
    return nil
end

--- Step 2: AutoDrive's whole environment, via a function we will never wrap.
function A.resolveEnvironment(autoDrive)
    local ok, env = pcall(getfenv, autoDrive.onDrawEditorMode)
    if not ok or type(env) ~= "table" then
        return nil
    end
    -- Sanity: if this were our own environment we would not find AutoDrive's other globals in it.
    if env.ADGraphManager == nil then
        return nil
    end
    return env
end

--- Copy the allow-listed names into `target`, which is the environment our own source() calls land
--- in - discovered rather than assumed, see Prelude.lua.
function A.republish(target)
    local published, missing = {}, {}
    for _, name in ipairs(A.REQUIRED) do
        local value = A.env[name]
        if value ~= nil then
            target[name] = value
            published[#published + 1] = name
        else
            missing[#missing + 1] = name
        end
    end
    return published, missing
end

--- Refuse to arm rather than half-arm. A guest mod that guesses wrong about its host should say so
--- at load, not fail somewhere unrelated an hour later.
function A.arm(target)
    A.attempts = A.attempts + 1

    local autoDrive = A.resolveAutoDrive()
    if autoDrive == nil then
        return false
    end

    local env = A.resolveEnvironment(autoDrive)
    if env == nil then
        A.failure = "found AutoDrive's table but could not read its environment"
        logError("%s - cannot continue.", A.failure)
        return false
    end

    A.autoDrive = autoDrive
    A.env = env
    A.target = target

    local published, missing = A.republish(target)
    if #missing > 0 then
        A.failure = "AutoDrive is missing: " .. table.concat(missing, ", ")
        logError("%s", A.failure)
        logError("this build of AutoDrive is not one this mod knows how to attach to; refusing to arm.")
        return false
    end

    log("resolved AutoDrive on attempt %d via the g_vehicleTypeManager onDrawUIInfo listener scan", A.attempts)
    log("republished: %s", table.concat(published, ", "))
    A.armed = true
    return true
end

function A.describe()
    if A.armed then
        return string.format("ARMED after %d attempt(s); republished %d names",
            A.attempts, #A.REQUIRED)
    end
    if A.failure ~= nil then
        return string.format("NOT ARMED after %d attempt(s): %s", A.attempts, A.failure)
    end
    return string.format("NOT ARMED after %d attempt(s): AutoDrive not found yet", A.attempts)
end
