--[[
MapProbe - reports the real shape of the base game's HUD map and map-hotspot classes, so the two
features that depend on them are built against what exists rather than against a guess.

Wanted for:
  1. keeping the editor panel clear of the large bottom-left map - needs the map's screen rectangle
     and a way to tell small / large / hidden apart;
  2. marking the flyover camera's position and aim on that map - needs a hotspot class that can be
     positioned in the world and, for the aim, rotated.

Today this project twice wrote code against base-game methods that did not exist (a setIsVisible on
the input help, a frame-time console command). Both of these features sit on internals just as
undocumented, so this asks first. Run FlyoverProbeMap once with the map SMALL and once LARGE.
]]

ADFlyoverMapProbe = {}

local M = ADFlyoverMapProbe

--- Every key reachable on an object - its own and its class's - as "name:type", sorted. Numbers
--- are printed with their value, since for a map those are exactly the rectangle being looked for.
local function describe(obj, maxItems)
    if type(obj) ~= "table" then
        return tostring(obj)
    end
    local seen, items = {}, {}
    local function collect(t, depth)
        if type(t) ~= "table" or depth > 4 then
            return
        end
        for k, v in pairs(t) do
            local key = tostring(k)
            if not seen[key] then
                seen[key] = true
                local kind = type(v)
                if kind == "number" then
                    items[#items + 1] = string.format("%s=%.4f", key, v)
                elseif kind == "boolean" or kind == "string" then
                    items[#items + 1] = string.format("%s=%s", key, tostring(v))
                else
                    items[#items + 1] = string.format("%s:%s", key, kind)
                end
            end
        end
        local mt = getmetatable(t)
        if mt ~= nil and type(mt.__index) == "table" then
            collect(mt.__index, depth + 1)
        end
    end
    collect(obj, 0)
    table.sort(items)
    if maxItems ~= nil and #items > maxItems then
        local cut = {}
        for i = 1, maxItems do cut[i] = items[i] end
        cut[#cut + 1] = string.format("... (%d more)", #items - maxItems)
        items = cut
    end
    return table.concat(items, ", ")
end

--- Which of these method names a class actually provides.
local function methods(class, names)
    if type(class) ~= "table" then
        return "(class not present)"
    end
    local found, missing = {}, {}
    for _, name in ipairs(names) do
        if type(class[name]) == "function" then
            found[#found + 1] = name
        else
            missing[#missing + 1] = name
        end
    end
    return string.format("HAS [%s]  LACKS [%s]", table.concat(found, " "), table.concat(missing, " "))
end

function M.run()
    local out = {}
    local function log(fmt, ...)
        local line = string.format(fmt, ...)
        out[#out + 1] = line
        Logging.info("[FlyoverMapProbe] %s", line)
    end

    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    log("hud = %s", tostring(hud))

    -- The HUD map. Its field name is itself a guess, so try the likely ones and report each.
    local map = nil
    for _, name in ipairs({ "ingameMap", "ingameMapElement", "miniMap", "minimap", "gameMap" }) do
        local candidate = hud ~= nil and hud[name] or nil
        log("hud.%s = %s", name, tostring(candidate))
        if map == nil and type(candidate) == "table" then
            map = candidate
            M.mapFieldName = name
        end
    end

    if map ~= nil then
        log("MAP (hud.%s): %s", M.mapFieldName, describe(map, 160))
        for _, sub in ipairs({ "layout", "state", "mapElement", "mapOverlay", "background" }) do
            if type(map[sub]) == "table" then
                log("MAP.%s: %s", sub, describe(map[sub], 120))
            elseif map[sub] ~= nil then
                log("MAP.%s = %s", sub, tostring(map[sub]))
            end
        end
    end

    -- Hotspot classes: which exist, and which of the setters the marker would need.
    local wanted = { "new", "setWorldPosition", "setWorldRotation", "setRotation", "setPlayer",
        "setVehicle", "setOwnerFarmId", "delete", "getIsVisible", "setVisible", "setColor",
        "getWorldPosition", "getWorldRotation", "setBlinking", "setPersistent" }
    for _, className in ipairs({ "MapHotspot", "PlaceableHotspot", "PlayerHotspot", "TourHotspot",
        "AIHotspot", "VehicleHotspot" }) do
        log("%s: %s", className, methods(rawget(_G, className) or _G[className], wanted))
    end
    log("hud.addMapHotspot=%s  mission.addMapHotspot=%s",
        tostring(hud ~= nil and type(hud.addMapHotspot) == "function"),
        tostring(g_currentMission ~= nil and type(g_currentMission.addMapHotspot) == "function"))

    -- The camera: where the aim comes from.
    local editor = ADFlyoverEditor
    local cam = editor ~= nil and editor.camera or nil
    if cam ~= nil then
        log("CAMERA: %s", describe(cam, 120))
    else
        log("CAMERA: editor not open - open it and run this again to see the camera's fields.")
    end

    return table.concat(out, "\n")
end
