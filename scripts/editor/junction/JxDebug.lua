-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "junctionRegistryFolder" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxDebug.lua needs %s, which no file loaded before it shares", name)
    end
end
local junctionRegistryFolder = ADFlyoverEditor.shared.junctionRegistryFolder
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- DEBUG CAPTURE: THE NETWORK EITHER SIDE OF EVERY CHANGE, PLUS WHAT THE TOOL SAID WHILE MAKING IT.
--
-- A fault you can see on your screen and I cannot reproduce on mine is the expensive kind. A whole
-- day went into one: four offline tests all came back clean because my copy of the network was not
-- the one the fault was in, and the junction had been renumbered in between, so we were not even
-- discussing the same crossing. What finally settled it in a single step was a pair of hand-saved
-- networks from either side of one clear. This does that automatically.
--
-- Each change writes a numbered folder under the savegame:
--
--     flyoverDebug/0007_clear_j60_-921.9_-46.9/
--         meta.txt   build, tool, settings, where it was locked, what it was called
--         pre.xml    the network before
--         post.xml   the network after
--         tool.log   every line this tool logged while doing it
--
-- The number leads: click through a sequence and the folders read in the order you did them, so a
-- fault that only appears when one thing follows another can be followed the same way.
--
-- pre.xml and post.xml are AutoDrive's OWN route format, written by AutoDrive's own writer. Nothing
-- new to parse and nothing new to get wrong: the game will load either one straight back in, and it
-- is the same format as the routes saved by hand that solved this in the first place.
--
-- Off unless switched on, and never on by accident - the toggle is on the junction card, it says so
-- while it is on, and it costs nothing at all while it is off.
local FLYOVER_DEBUG_DIR = "flyoverDebug/"
local jxDebugSeq = 0

--- EVERY LINE THE TOOL SAYS WHILE A CAPTURE IS RUNNING, taken at the source.
---
--- The first version read log.txt instead - remembering how long it was at the start and taking
--- whatever had been added by the end. It came back empty every time: FS25 buffers that file, so at
--- the moment a clear finishes none of its lines have reached the disk yet. The capture wrote a
--- one-byte tool.log beside two perfectly good network snapshots.
---
--- So the lines are taken where they are made. Logging is wrapped for the length of the capture and
--- put back afterwards, and each call is passed straight through - nothing is swallowed, and the
--- game's own log is unchanged.
local jxDebugLines = nil
local jxDebugSaved = nil
local jxDebugWritten = 0          -- how many lines a previous capture has already taken
local JX_DEBUG_KEEP = 4000

--- EVERYTHING THE TOOL SAID, FROM THE MOMENT CAPTURE WAS SWITCHED ON.
---
--- Capture used to begin when a change began, and a junction is worked out BEFORE that: which
--- crossing was picked, how the arms read, which turns were refused, what kind of junction it was
--- called. All of that happens at lock time and none of it was in the folder - so the capture could
--- say a site had been read as a 4-way offset but not why, and answering that meant going to the
--- game's own log, which is overwritten on every launch and holds every other mod's output too.
---
--- So the wrap goes on when capture is switched ON and stays on, collecting into a ring buffer. Each
--- capture then writes everything logged since the PREVIOUS capture: the lock that led to it, the
--- change itself, and anything in between. One folder, whole story, nothing to fetch separately.
local function jxDebugLogArm()
    if Logging == nil or jxDebugSaved ~= nil then return end
    jxDebugLines, jxDebugWritten = {}, 0
    jxDebugSaved = { info = Logging.info, warning = Logging.warning, error = Logging.error }
    local function wrap(level, original)
        return function(fmt, ...)
            if jxDebugLines ~= nil then
                local ok, line = pcall(string.format, fmt, ...)
                jxDebugLines[#jxDebugLines + 1] = level .. (ok and line or tostring(fmt))
                -- Bounded, so a long session cannot grow without limit. Trimming loses the oldest
                -- lines, so the count already written is pulled back with it.
                if #jxDebugLines > JX_DEBUG_KEEP then
                    local drop = #jxDebugLines - JX_DEBUG_KEEP
                    local keep = {}
                    for i = drop + 1, #jxDebugLines do keep[#keep + 1] = jxDebugLines[i] end
                    jxDebugLines = keep
                    jxDebugWritten = math.max(0, jxDebugWritten - drop)
                end
            end
            if original ~= nil then return original(fmt, ...) end
        end
    end
    Logging.info = wrap("", jxDebugSaved.info)
    Logging.warning = wrap("WARNING: ", jxDebugSaved.warning)
    Logging.error = wrap("ERROR: ", jxDebugSaved.error)
end

--- Put Logging back. Always restores, even if nothing was collected.
local function jxDebugLogDisarm()
    if jxDebugSaved ~= nil and Logging ~= nil then
        Logging.info, Logging.warning, Logging.error =
            jxDebugSaved.info, jxDebugSaved.warning, jxDebugSaved.error
    end
    jxDebugSaved, jxDebugLines, jxDebugWritten = nil, nil, 0
end

--- Everything logged since the last capture took its share, and mark it taken.
local function jxDebugLogTake()
    local out = {}
    for i = jxDebugWritten + 1, #(jxDebugLines or {}) do out[#out + 1] = jxDebugLines[i] end
    jxDebugWritten = #(jxDebugLines or {})
    return out
end

--- Write the whole network, as AutoDrive writes its routes. True when the file is there.
local function jxDebugWriteGraph(path)
    if createXMLFile == nil or AutoDrive == nil or AutoDrive.writeGraphToXml == nil then return false end
    local ok = pcall(function()
        local xml = createXMLFile("flyoverDebug_xml", path, "routeExport")
        if xml == nil or xml == -1 then return end
        AutoDrive.writeGraphToXml(xml, "routeExport", ADGraphManager:getWayPoints(),
            ADGraphManager:getMapMarkers(), ADGraphManager:getGroups())
        saveXMLFile(xml)
        delete(xml)
    end)
    return ok == true
end

--- THE MAP'S OWN ROADS, SAVED FOR THE HARNESS. The traffic splines are the lines the game's AI
--- traffic drives, and what AutoDrive builds a map's network from when it scans it. They are the
--- map maker's roads, independent of any flag on a waypoint, so they say which lanes lie on a real
--- road. Written to <savegame>/ADFlyoverEditor_roadSplines.xml, one entry per spline: its length and
--- its centre-line sampled every `step` metres as "x,z;x,z;...". Returns the count and the path.
function ADFlyoverEditor:dumpRoadSplines(step)
    step = step or 2
    local ai = g_currentMission ~= nil and g_currentMission.aiSystem or nil
    local splines = ai ~= nil and ai.roadSplines or nil
    if splines == nil then return nil, "this map has no traffic splines the game has loaded" end
    local root = junctionRegistryFolder()
    if root == nil then return nil, "no savegame folder yet - save the game once first" end
    local path = root .. "ADFlyoverEditor_roadSplines.xml"
    local xml = createXMLFile("flyoverRoadSplines", path, "roadSplines")
    if xml == nil or xml == -1 then return nil, "could not create " .. path end
    local n = 0
    for _, spline in pairs(splines) do
        local len = getSplineLength(spline) or 0
        if len > 0 then
            local pts, k = {}, math.max(1, math.floor(len / step))
            for i = 0, k do
                local x, _, z = getSplinePosition(spline, i / k)
                if x ~= nil then pts[#pts + 1] = string.format("%.2f,%.2f", x, z) end
            end
            local key = string.format("roadSplines.spline(%d)", n)
            setXMLString(xml, key .. "#name", tostring(getName(spline) or ""))
            setXMLFloat(xml, key .. "#length", len)
            setXMLString(xml, key .. "#points", table.concat(pts, ";"))
            n = n + 1
        end
    end
    saveXMLFile(xml)
    delete(xml)
    return n, path
end

--- Start and stop collecting, for the toggle. Methods, because the toggle sits well above these
--- file-locals and a file-local named from above binds to a global instead.
function ADFlyoverEditor:debugCaptureArm() jxDebugLogArm() end
function ADFlyoverEditor:debugCaptureDisarm() jxDebugLogDisarm() end

--- Where captures are being written, and how many have been written this session. A method, so the
--- card and the toggle can ask without reaching for file-locals declared below them.
function ADFlyoverEditor:debugCaptureWhere()
    local root = junctionRegistryFolder()
    if root == nil then return nil, jxDebugSeq end
    return root .. FLYOVER_DEBUG_DIR, jxDebugSeq
end

--- Begin capturing one change. `what` names the operation ("clear", "build"), `site` is where it
--- was locked and may be nil. Returns the folder it will write into, or nil when capture is off or
--- there is nowhere to write - and everything after it then does nothing, so no caller needs to ask
--- whether capture is on.
---
--- The pre-state is written HERE, before the change, because there is no getting it back afterwards.
---
--- `jname` is what the junction is called (jp.junctionName: "j39se" once the user has split 39),
--- worked out from where the selection locked it. Without it the number is looked up from `site`,
--- which by now is the box's middle - and at 26 that is nearer the other half.
function ADFlyoverEditor:debugCaptureBegin(what, site, extra, jname)
    if AutoDrive.FLYOVER_DEBUG_CAPTURE ~= true then return nil end
    local root = junctionRegistryFolder()
    if root == nil then return nil end

    jxDebugSeq = jxDebugSeq + 1
    local name
    if site ~= nil and site.x ~= nil then
        -- The number is in the folder name so a sequence can be talked about, and the COORDINATE is
        -- in it too because the number is only good for this session - clearing junctions reshuffles
        -- them, and a capture read back tomorrow would otherwise name a different crossing.
        local n = self:junctionNumberAt(site.x, site.z)
        local label = jname
        if label == nil and n ~= nil then label = string.format("j%02d", n) end
        name = string.format("%04d_%s_%s%.1f_%.1f", jxDebugSeq, what or "op",
            label ~= nil and (label .. "_") or "", site.x, site.z)
        site = { x = site.x, z = site.z, n = n, name = label }
    else
        name = string.format("%04d_%s", jxDebugSeq, what or "op")
    end
    local dir = root .. FLYOVER_DEBUG_DIR .. name .. "/"
    if createFolder ~= nil then
        pcall(createFolder, root .. FLYOVER_DEBUG_DIR)
        pcall(createFolder, dir)
    end

    local cap = {
        dir = dir, what = what, site = site, extra = extra,
        t0 = getDate ~= nil and getDate("%H:%M:%S") or "",
    }
    jxDebugLogArm()
    if not jxDebugWriteGraph(dir .. "pre.xml") then
        -- Put Logging back before leaving. Bailing out with it still wrapped would have left every
        -- line the game logs for the rest of the session going into a buffer nothing ever reads.
        Logging.warning("[FlyoverEditor]: debug capture - could not write the network into %s. Capture is on but this change will not be recorded.", dir)
        return nil
    end
    Logging.info("[FlyoverEditor]: debug capture %04d - recording this %s into %s", jxDebugSeq, what or "change", dir)
    return cap
end

--- Finish a capture: the network as it now is, and everything the tool said while changing it.
function ADFlyoverEditor:debugCaptureEnd(cap)
    if cap == nil then return end
    jxDebugWriteGraph(cap.dir .. "post.xml")

    local meta = {
        -- Both versions, the way the card reports them: if the Lua and the modDesc disagree, the
        -- game was reloaded without a restart, and a capture that did not say so would have someone
        -- reading it against the wrong source.
        string.format("build          %s", (ADFlyoverPrelude ~= nil and ADFlyoverPrelude.BUILD) or "?"),
        string.format("modDesc        %s", (ADFlyoverPrelude ~= nil and ADFlyoverPrelude.MODDESC_VERSION) or "?"),
        string.format("tool           %s", tostring(cap.what)),
        string.format("started        %s", tostring(cap.t0)),
        string.format("finished       %s", getDate ~= nil and getDate("%H:%M:%S") or ""),
        string.format("waypoints now  %d", ADGraphManager:getWayPointsCount()),
    }
    if cap.site ~= nil then
        meta[#meta + 1] = string.format("locked at      %.2f, %.2f", cap.site.x or 0, cap.site.z or 0)
        if cap.site.name ~= nil then meta[#meta + 1] = string.format("junction       %s", cap.site.name) end
    end
    for _, line in ipairs(cap.extra or {}) do meta[#meta + 1] = line end

    -- EVERY SETTING THE CLEAR COULD HAVE READ, as it stood at the moment of the clear.
    --
    -- The harness runs on the constants' defaults; the game runs on whatever is persisted, and two
    -- of the junction values are saved between sessions on purpose. That is enough to make the same
    -- code on the same network give a different answer in each - which it did: one lane finished
    -- 18.5 m from the middle in game and 5.6 m offline, from the very same pre.xml.
    --
    -- Enumerated rather than listed by hand, so a setting added later cannot quietly go unrecorded.
    -- With these in the capture, a replay can be set up to match the game exactly instead of being
    -- assumed to.
    -- WHAT IT WAS RUNNING ON. A drop that needs a second question answered before it can be read
    -- is not a drop. Game build, AutoDrive's version, the map, the savegame, and every mod loaded -
    -- because "it does this for me and not for you" is usually one of those and nothing else.
    meta[#meta + 1] = ""
    meta[#meta + 1] = "-- what it was running on --"
    meta[#meta + 1] = string.format("%-46s %s", "game",
        (g_gameVersionDisplay ~= nil and tostring(g_gameVersionDisplay))
        or (getVersionString ~= nil and tostring(getVersionString())) or "?")
    meta[#meta + 1] = string.format("%-46s %s", "AutoDrive",
        (AutoDrive ~= nil and AutoDrive.version ~= nil) and tostring(AutoDrive.version) or "?")
    meta[#meta + 1] = string.format("%-46s %s", "map",
        (AutoDrive ~= nil and AutoDrive.loadedMap ~= nil) and tostring(AutoDrive.loadedMap) or "?")
    do
        local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
        meta[#meta + 1] = string.format("%-46s %s", "savegame",
            (info ~= nil and info.savegameIndex ~= nil) and tostring(info.savegameIndex) or "?")
        meta[#meta + 1] = string.format("%-46s %s", "multiplayer",
            (g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil)
            and tostring(g_currentMission.missionDynamicInfo.isMultiplayer) or "?")
    end
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local ok, mods = pcall(function() return g_modManager:getActiveMods() end)
        if ok and type(mods) == "table" then
            meta[#meta + 1] = ""
            meta[#meta + 1] = "-- mods loaded --"
            local names = {}
            for _, m in pairs(mods) do
                if type(m) == "table" and m.modName ~= nil then
                    names[#names + 1] = string.format("%s %s", tostring(m.modName), tostring(m.version or ""))
                end
            end
            table.sort(names)
            for _, n in ipairs(names) do meta[#meta + 1] = "  " .. n end
        end
    end

    meta[#meta + 1] = ""
    meta[#meta + 1] = "-- settings as they stood --"
    do
        local names = {}
        for k, v in pairs(AutoDrive or {}) do
            if type(k) == "string" and k:sub(1, 8) == "FLYOVER_"
                and (type(v) == "number" or type(v) == "boolean" or type(v) == "string") then
                names[#names + 1] = k
            end
        end
        table.sort(names)
        for _, k in ipairs(names) do
            meta[#meta + 1] = string.format("%-46s %s", k, tostring(AutoDrive[k]))
        end
        for _, k in ipairs({ "junctionRadius", "junctionTurnRadius", "junctionLeaveThrough",
                             "junctionMode", "fieldLoopDirection", "connectionMode", "subPrio" }) do
            meta[#meta + 1] = string.format("%-46s %s", "editor." .. k, tostring(self[k]))
        end
    end
    -- Positions, never ids: every removal reissues the ids above it, so an id written here would
    -- name a different point by the time anyone read it back.
    meta[#meta + 1] = ""
    meta[#meta + 1] = "pre.xml and post.xml are AutoDrive route exports - loadable in game, and"
    meta[#meta + 1] = "readable by the offline harness. Points are matched by position, not by id."

    local f = io.open(cap.dir .. "meta.txt", "w")
    if f ~= nil then f:write(table.concat(meta, "\n") .. "\n") f:close() end
    local lines = jxDebugLogTake()
    local l = io.open(cap.dir .. "tool.log", "w")
    if l ~= nil then l:write(table.concat(lines, "\n") .. "\n") l:close() end
    Logging.info("[FlyoverEditor]: debug capture %04d - written, %d log line(s). %s",
        jxDebugSeq, #lines, cap.dir)
end
