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
S.settings.flyoverMergeDivergence = { values = { 0, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100 }, default = 6, current = 6 }

local function log(fmt, ...)
    Logging.info("[%s] " .. fmt, S.MOD_NAME, ...)
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
    for _, name in ipairs({ "fieldLoopMargin", "fieldLoopTreeClearance", "fieldLoopVehicleHeight",
                            "fieldLoopTurningRadius", "flyoverMergeDistance", "flyoverMergeDivergence" }) do
        parts[#parts + 1] = string.format("%s=%s", name, tostring(S.get(name)))
    end
    return table.concat(parts, " ")
end
