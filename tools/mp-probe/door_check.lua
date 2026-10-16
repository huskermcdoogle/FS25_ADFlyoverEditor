--[[ MULTIPLAYER STEP 1: DOES THE DOOR DESCRIBE EVERY ACTION EXACTLY?

Runs AutoDrive's REAL GraphManager.lua and the editor's scripts/editor/GraphOps.lua. Makes random
actions out of AutoDrive's own edits (deletes, records, moves, flags, toggles, spline connections,
markers, and the editor's kind of hand-made link changes), each action 1-25 edits. For every action:

  1. capture before, do the edits, diff -> the action
  2. a copy of BEFORE + the action played forwards  must equal the network now
  3. a copy of NOW    + the action played backwards must equal BEFORE

"Equal" is strict: same number for every point, same tag, same place, flags, field number, both link
lists in the same order, same markers. That is what multiplayer needs (every PC identical) and what
undo needs (back exactly where it was).

    lua door_check.lua <AutoDrive GraphManager.lua> <network from export_full.py> [actions] [seed]
]]

local GM_PATH, NET_PATH = arg[1], arg[2]
local ACTIONS = tonumber(arg[3] or "300")
local SEED = tonumber(arg[4] or "1")
assert(GM_PATH and NET_PATH, "usage: lua door_check.lua <GraphManager.lua> <network.lua> [actions] [seed]")

function table:contains(value) for _, v in pairs(self) do if v == value then return true end end return false end
function table:indexOf(value) for k, v in pairs(self) do if v == value then return k end end return nil end
function table:removeValue(value)
    for k, v in pairs(self) do if v == value then table.remove(self, k) return true end end
    return false
end
function table:count() local c = 0 for _ in pairs(self) do c = c + 1 end return c end
bit32 = bit32 or { band = function(a, b)
    local r, bitv = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bitv end
        a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
    end
    return r
end }
Logging = { info = function() end, warning = print, error = print }
g_server, g_client = {}, nil
AutoDrive = { Hud = { lastUIScale = 0 }, FLAG_NONE = 0, FLAG_SUBPRIO = 1,
              getAllVehicles = function() return {} end, notifyDestinationListeners = function() end }

dofile(GM_PATH)
dofile("../../scripts/editor/GraphOps.lua")
local GM, G = ADGraphManager, ADFlyoverGraphOps

local net = dofile(NET_PATH)
GM.wayPoints, GM.mapMarkers, GM.groups = {}, {}, { All = 1 }
for i, w in ipairs(net.wayPoints) do
    GM.wayPoints[i] = GM:createNode(i, w.x, w.y, w.z, { unpack(w.out) }, { unpack(w.incoming) }, w.flags, nil, nil)
end
for i, m in ipairs(net.mapMarkers or {}) do
    GM.mapMarkers[i] = { id = m.id, name = m.name, group = m.group, markerIndex = i }
    if GM.groups[m.group] == nil then GM.groups[m.group] = table.count(GM.groups) + 1 end
end
local function graph() return { wayPoints = GM.wayPoints, mapMarkers = GM.mapMarkers, groups = GM.groups } end
print(string.format("network: %d points, %d markers", #GM.wayPoints, #GM.mapMarkers))

math.randomseed(SEED)
local function any() return GM.wayPoints[math.random(1, #GM.wayPoints)] end

-- one edit, the kinds the editor and AutoDrive make
local function edit()
    local r = math.random()
    if r < 0.22 then
        GM:removeWayPoint(any().id, false)
    elseif r < 0.36 then
        local a = any()
        local wp = GM:recordWayPoint(a.x + 3, a.y, a.z + 3, false, false, false, 0, 0, false)
        GM:toggleConnectionBetween(a, wp, false, math.random() < 0.3, false)
    elseif r < 0.52 then
        local w = any()
        GM:moveWayPoint(w.id, w.x + math.random() - 0.5, w.y, w.z + math.random() - 0.5, w.flags, false)
    elseif r < 0.58 then
        local w = any()
        GM:setWayPointFlags(w.id, (w.flags == 0) and 1 or 0, false)
    elseif r < 0.72 then
        local a, b = any(), any()
        if a ~= b then GM:toggleConnectionBetween(a, b, math.random() < 0.2, math.random() < 0.3, false) end
    elseif r < 0.80 then
        -- the editor's hand-made link changes (JxCore junctionConnect / Menus setLink style)
        local a, b = any(), any()
        if a ~= b and not table.contains(a.out, b.id) then
            table.insert(a.out, b.id); table.insert(b.incoming, a.id)
        end
    elseif r < 0.86 then
        local a = any()
        local o = a.out[1]
        if o ~= nil then table.removeValue(a.out, o); local b = GM.wayPoints[o]; if b then table.removeValue(b.incoming, a.id) end end
    elseif r < 0.93 then
        local a, b = any(), any()
        if a ~= b then
            local pts = {}
            for k = 1, math.random(2, 5) do
                local f = k / 6
                pts[k] = { x = a.x + (b.x - a.x) * f, y = a.y, z = a.z + (b.z - a.z) * f }
            end
            GM:createSplineConnection(a.id, pts, b.id, math.random() < 0.3, false)
        end
    elseif r < 0.97 then
        GM:createMapMarker(any().id, "probe " .. math.random(1, 9999), false)
    else
        if #GM.mapMarkers > 0 then GM:removeMapMarker(math.random(1, #GM.mapMarkers), false) end
    end
end

local okF, okB, refused, empty, failures = 0, 0, 0, 0, 0
local sizes = { adds = 0, dels = 0, sets = 0, lists = 0 }
local t0 = os.clock()
local tDiff, tApply = 0, 0
for n = 1, ACTIONS do
    local before = G.capture(graph())
    local beforeCopy = G.copyGraph(graph())
    for _ = 1, math.random(1, 25) do edit() end
    local c = os.clock()
    local a, why = G.diff(before, graph(), "action " .. n)
    tDiff = tDiff + (os.clock() - c)
    if a == nil then
        if why == "nothing changed" then empty = empty + 1 else refused = refused + 1; print("REFUSED: " .. why) end
    else
        for k in pairs(sizes) do sizes[k] = sizes[k] + #a[k] end
        local fwd = G.copyGraph(beforeCopy)
        c = os.clock()
        local ok, err = G.apply(fwd, a, false)
        tApply = tApply + (os.clock() - c)
        local same, d = false, err
        if ok then same, d = G.same(fwd, graph()) end
        if same then okF = okF + 1 else failures = failures + 1; print("FORWARD FAIL " .. n .. ": " .. tostring(d) .. " | " .. G.describe(a)) end
        local back = G.copyGraph(graph())
        ok, err = G.apply(back, a, true)
        same, d = false, err
        if ok then same, d = G.same(back, beforeCopy) end
        if same then okB = okB + 1 else failures = failures + 1; print("BACKWARD FAIL " .. n .. ": " .. tostring(d) .. " | " .. G.describe(a)) end
    end
    if failures > 10 then break end
end
print(string.format("actions: %d | forwards exact %d | backwards exact %d | refused %d | empty %d | failures %d",
    ACTIONS, okF, okB, refused, empty, failures))
print(string.format("in all: %d added, %d deleted, %d moved/flagged, %d relinked; network now %d points",
    sizes.adds, sizes.dels, sizes.sets, sizes.lists, #GM.wayPoints))
print(string.format("time: %.1f s; diff %.1f ms per action, apply %.1f ms per action (Lua 5.1, this PC)",
    os.clock() - t0, tDiff / ACTIONS * 1000, tApply / math.max(1, okF + failures) * 1000))
if failures > 0 or refused > 0 then os.exit(1) end
