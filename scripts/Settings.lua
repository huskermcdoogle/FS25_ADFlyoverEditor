--[[
Settings - companion-owned, AutoDrive-shaped.

NEVER add a key to AutoDrive.settings. Two independent reasons, both verified against the source:

  * UpdateSettingsEvent.lua does an unguarded AutoDrive.settings[name].current = value while
    iterating - `pairs(AutoDrive.settings)` has 17 call sites - so a stock client joining a host
    that injected keys takes a nil index and loses the rest of its settings sync.
  * XML.lua reads AutoDrive's config inside AutoDrive's own loadMap, seconds before this mod can
    resolve anything, so an injected key is written at save and silently skipped at load.

Writing to the AutoDrive TABLE is a different matter and is safe: `pairs(AutoDrive)` has zero call
sites, so the editor's ~30 AutoDrive.FLYOVER_* / FIELD_LOOP_* constants are invisible to AutoDrive
and need no special handling. It is only `settings` that is iterated.

The SHAPE is copied exactly because the editor's panel depends on it: applySettingValue snaps a
typed number to the nearest entry of `values` and stores an INDEX, and getSetting returns
values[current]. Reproduce that and the number rows, the snapping and getEditableNumbers all work
unchanged. Values below are lifted verbatim from the fork's Settings.lua.
]]

ADFlyoverSettings = { settings = {} }

local S = ADFlyoverSettings

S.MOD_NAME = "ADFlyoverEditor"
S.FOLDER = "modSettings/FS25_ADFlyoverEditor/"
S.FILE = "settings.xml"

S.settings.fieldLoopMargin = { values = { -10.0, -9.75, -9.50, -9.25, -9.0, -8.75, -8.50, -8.25, -8.0, -7.75, -7.50, -7.25, -7.0, -6.75, -6.50, -6.25, -6.0, -5.75, -5.50, -5.25, -5.0, -4.75, -4.50, -4.25, -4.0, -3.75, -3.50, -3.25, -3.0, -2.75, -2.50, -2.25, -2.0, -1.75, -1.50, -1.25, -1.0, -0.75, -0.50, -0.25, 0.0, 0.25, 0.50, 0.75, 1.0, 1.25, 1.50, 1.75, 2.0, 2.25, 2.50, 2.75, 3.0, 3.25, 3.50, 3.75, 4.0, 4.25, 4.50, 4.75, 5.0, 5.25, 5.50, 5.75, 6.0, 6.25, 6.50, 6.75, 7.0, 7.25, 7.50, 7.75, 8.0, 8.25, 8.50, 8.75, 9.0, 9.25, 9.50, 9.75, 10.0 }, default = 46, current = 46 }
S.settings.fieldLoopTreeClearance = { values = { 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.25, 3.5, 3.75, 4.0, 4.25, 4.5, 4.75, 5.0 }, default = 4, current = 4 }
S.settings.fieldLoopVehicleHeight = { values = { 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0 }, default = 4, current = 4 }
S.settings.fieldLoopTurningRadius = { values = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 }, default = 6, current = 6 }
S.settings.flyoverMergeDistance = { values = { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0 }, default = 5, current = 5 }
S.settings.sidingOffset = { values = { 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 6.5, 7.0, 7.5, 8.0, 8.5, 9.0, 9.5, 10.0, 10.5, 11.0, 11.5, 12.0, 12.5, 13.0, 13.5, 14.0, 14.5, 15.0, 15.5, 16.0, 16.5, 17.0, 17.5, 18.0, 18.5, 19.0, 19.5, 20.0 }, default = 7, current = 7 }
S.settings.sidingLength = { values = { 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100, 105, 110, 115, 120, 125, 130, 135, 140, 145, 150, 155, 160, 165, 170, 175, 180, 185, 190, 195, 200 }, default = 5, current = 5 }
S.settings.flyoverMergeDivergence = { values = { 0, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100 }, default = 6, current = 6 }
-- Move's own tolerance for auto-hookup (item 6) - deliberately its own setting rather than
-- reusing flyoverMergeDistance/Divergence: those back a deliberate three-click confirmed action,
-- this fires silently with no confirmation at all, so a tighter default is the safer starting
-- point even though the shape (a distance and a divergence angle) is the same idea.
S.settings.flyoverAutoHookupDistance = { values = { 0.5, 0.75, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 7.5, 10.0, 15.0, 20.0 }, default = 3, current = 3 }
S.settings.flyoverAutoHookupDivergence = { values = { 0, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100 }, default = 3, current = 3 }
-- The launch button riding on AutoDrive's HUD: whether it shows at all, and which side of the HUD
-- it anchors to. Not geometry, just a UI preference, but persisted anyway so a player who hides it
-- or moves it out of a busy corner does not have to redo that every session.
S.settings.launchButtonHidden = { values = { false, true }, default = 1, current = 1 }
S.settings.launchButtonPosition = { values = { "auto", "left", "right", "above", "below" }, default = 1, current = 1 }
-- Off by default: a user reported hours of normal editing bloating log.txt, and the overwhelming
-- majority of it is routine per-click/per-action info lines (see FlyoverEditor.lua's debugLog
-- call sites) that only matter while actively diagnosing something, not on every session.
S.settings.flyoverDebugLogging = { values = { false, true }, default = 1, current = 1 }

local function log(fmt, ...)
    Logging.info("[%s] " .. fmt, S.MOD_NAME, ...)
end

--- Gate for routine info-level logging (click traces, per-action confirmations, etc.) - NOT for
--- Logging.warning/Logging.error, which stay on unconditionally regardless of this setting; those
--- indicate an actual problem, not a bloat source. Deliberately reads Logging.info directly rather
--- than wrapping/overriding the global itself - Logging is base-game, not this mod's, and every
--- other mod plus the base game itself calls it too, so patching it globally would affect far more
--- than this mod's own log lines. Call sites across the editor were switched from Logging.info(...)
--- to ADFlyoverSettings.debugLog(...) instead - a one-word rename, not a global override.
function S.debugLog(fmt, ...)
    if S.get("flyoverDebugLogging") then
        Logging.info(fmt, ...)
    end
end

--- Fallthrough is deliberate here and ONLY here: a name we do not own goes to AutoDrive, so the one
--- genuinely-stock read the editor makes - AutoDrive.getSetting("showHUD") - keeps working, while
--- the six names we do own never touch AutoDrive.settings.
function S.get(name)
    local setting = S.settings[name]
    if setting ~= nil then
        return setting.values[setting.current]
    end
    if AutoDrive ~= nil and AutoDrive.getSetting ~= nil then
        return AutoDrive.getSetting(name)
    end
    return nil
end

--- Same contract as AutoDrive.setSettingState: takes an INDEX, not a value.
function S.setIndex(name, index)
    local setting = S.settings[name]
    if setting == nil or setting.values[index] == nil then
        return nil
    end
    setting.current = index
    S.save()
    return setting.values[index]
end

--- Snap a typed value to the nearest allowed entry, the way the editor's panel expects.
function S.setNearest(name, value)
    local setting = S.settings[name]
    if setting == nil or tonumber(value) == nil then
        return nil
    end
    value = tonumber(value)
    local bestIndex, bestDistance = setting.current, math.huge
    for i, candidate in ipairs(setting.values) do
        local distance = math.abs(candidate - value)
        if distance < bestDistance then
            bestIndex, bestDistance = i, distance
        end
    end
    return S.setIndex(name, bestIndex)
end

--- Move a setting's index by dir (usually ±1), wrapping around. setNearest assumes numeric values
--- and a distance between them, which does not mean anything for a toggle or a named position - so
--- those cycle through their values list instead.
function S.cycle(name, dir)
    local setting = S.settings[name]
    if setting == nil then
        return nil
    end
    local n = #setting.values
    local nextIndex = ((setting.current - 1 + (dir >= 0 and 1 or -1)) % n) + 1
    return S.setIndex(name, nextIndex)
end

local function settingsPath()
    if getUserProfileAppPath == nil then
        return nil
    end
    return getUserProfileAppPath() .. S.FOLDER .. S.FILE
end

function S.save()
    local path = settingsPath()
    if path == nil then
        return false
    end
    local ok, err = pcall(function()
        createFolder(getUserProfileAppPath() .. "modSettings/")
        createFolder(getUserProfileAppPath() .. S.FOLDER)
        local xml = createXMLFile("ADFlyoverSettings", path, "flyoverEditor")
        for name, setting in pairs(S.settings) do
            setXMLInt(xml, "flyoverEditor.settings." .. name .. "#current", setting.current)
        end
        saveXMLFile(xml)
        delete(xml)
    end)
    if not ok then
        Logging.warning("[%s] could not save settings: %s", S.MOD_NAME, tostring(err))
        return false
    end
    return true
end

function S.load()
    local path = settingsPath()
    if path == nil or not fileExists(path) then
        return false
    end
    local ok, err = pcall(function()
        local xml = loadXMLFile("ADFlyoverSettings", path)
        for name, setting in pairs(S.settings) do
            local stored = getXMLInt(xml, "flyoverEditor.settings." .. name .. "#current")
            -- Ignore anything out of range rather than trusting the file: an index past the end of
            -- `values` would make get() return nil, and a nil spacing has already been shown to
            -- crash the geometry rather than merely misbehave.
            if stored ~= nil and setting.values[stored] ~= nil then
                setting.current = stored
            end
        end
        delete(xml)
    end)
    if not ok then
        Logging.warning("[%s] could not load settings: %s", S.MOD_NAME, tostring(err))
        return false
    end
    return true
end

function S.describe()
    local parts = {}
    for _, name in ipairs({ "sidingOffset", "sidingLength", "fieldLoopMargin", "fieldLoopTreeClearance", "fieldLoopVehicleHeight",
                            "fieldLoopTurningRadius", "flyoverMergeDistance", "flyoverMergeDivergence",
                            "flyoverAutoHookupDistance", "flyoverAutoHookupDivergence",
                            "flyoverDebugLogging",
                            "launchButtonHidden", "launchButtonPosition" }) do
        parts[#parts + 1] = string.format("%s=%s", name, tostring(S.get(name)))
    end
    return table.concat(parts, " ")
end
