--[[ MULTIPLAYER STEP 0: DO TAGS SURVIVE AUTODRIVE'S RENUMBERING?

Runs AutoDrive's REAL GraphManager.lua (taken from the installed FS25_AutoDrive.zip, not a copy of
ours) against a real network, puts our own permanent tag on every point table (wp.fxTag), then
does thousands of random edits the way the multiplayer "one door" will do them. After every edit it
checks the whole network in TAG terms against a model that never uses AutoDrive numbers:

  - every tag the model still has is on a table that sits at wayPoints[wp.id];
  - its position and flags are what the model says;
  - its out and incoming lists, turned into tags, are what the model says, in the same order.

If all of that holds, a change written as "tag A links to tag B" means the same thing on every PC
no matter how many deletes renumbered the points underneath. It also times what deletes cost.

Then it shows the one AutoDrive trap the door must avoid: deleting a point that still has a reverse
link pointing at it (and incoming links of its own) leaves that link dangling, and the renumbering
quietly turns it into a link to the NEXT point.

    lua tag_survival.lua <AutoDrive GraphManager.lua> <network from export_full.py> [ops] [seed]
]]

local GM_PATH, NET_PATH = arg[1], arg[2]
local OPS = tonumber(arg[3] or "5000")
local SEED = tonumber(arg[4] or "20261016")
assert(GM_PATH and NET_PATH, "usage: lua tag_survival.lua <GraphManager.lua> <network.lua> [ops] [seed]")

-- ------------------------------------------------------------------ the little of FS25 it needs
-- The table helpers are AutoDrive's own (scripts/Utils/UtilFuncs.lua), same bodies.
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
local GM = ADGraphManager
GM.changes = false

-- ------------------------------------------------------------------ load the network as AD holds it
local net = dofile(NET_PATH)
local wps = {}
for i, w in ipairs(net.wayPoints) do
    wps[i] = GM:createNode(i, w.x, w.y, w.z, { unpack(w.out) }, { unpack(w.incoming) }, w.flags, nil, nil)
end
GM.wayPoints = wps
GM.mapMarkers = {}
for i, m in ipairs(net.mapMarkers or {}) do
    GM.mapMarkers[i] = { id = m.id, name = m.name, group = m.group, markerIndex = i }
end
local N0 = #wps
print(string.format("network: %d points, %d markers", N0, #GM.mapMarkers))

-- ------------------------------------------------------------------ tags and the tag-only model
local nextTag = 0
local function newTag() nextTag = nextTag + 1 return nextTag end
local model = {}       -- tag -> { x, y, z, flags, out = {tags}, incoming = {tags} }
for _, wp in ipairs(wps) do wp.fxTag = newTag() end
for _, wp in ipairs(wps) do
    local o, n = {}, {}
    for _, id in ipairs(wp.out) do o[#o + 1] = wps[id].fxTag end
    for _, id in ipairs(wp.incoming) do n[#n + 1] = wps[id].fxTag end
    model[wp.fxTag] = { x = wp.x, y = wp.y, z = wp.z, flags = wp.flags, out = o, incoming = n }
end
local function modelTags()
    local t = {}
    for tag in pairs(model) do t[#t + 1] = tag end
    table.sort(t)   -- never let pairs() order reach a decision
    return t
end

local function removeFirst(list, v)
    for i = 1, #list do if list[i] == v then table.remove(list, i) return end end
end
local function has(list, v) for i = 1, #list do if list[i] == v then return true end end return false end

-- find a point's table by tag, the way the door will (a tag -> table map kept beside the graph)
local byTag = {}
for _, wp in ipairs(wps) do byTag[wp.fxTag] = wp end

-- ------------------------------------------------------------------ the check
local checks, failures = 0, 0
local function fail(msg) failures = failures + 1 if failures <= 10 then print("FAIL: " .. msg) end end
local function sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function checkAll(label)
    checks = checks + 1
    local n = 0
    for i, wp in ipairs(GM.wayPoints) do
        n = n + 1
        if wp.id ~= i then fail(string.format("%s: table at %d says id %d", label, i, wp.id)) end
        local m = model[wp.fxTag]
        if m == nil then fail(string.format("%s: table at %d has tag %s the model deleted", label, i, tostring(wp.fxTag)))
        else
            if wp.x ~= m.x or wp.y ~= m.y or wp.z ~= m.z or wp.flags ~= m.flags then
                fail(string.format("%s: tag %d moved or reflagged unexpectedly", label, wp.fxTag))
            end
            local o, inc = {}, {}
            for _, id in ipairs(wp.out) do o[#o + 1] = GM.wayPoints[id] and GM.wayPoints[id].fxTag or -1 end
            for _, id in ipairs(wp.incoming) do inc[#inc + 1] = GM.wayPoints[id] and GM.wayPoints[id].fxTag or -1 end
            if not sameList(o, m.out) then fail(string.format("%s: tag %d out lists differ", label, wp.fxTag)) end
            if not sameList(inc, m.incoming) then fail(string.format("%s: tag %d incoming lists differ", label, wp.fxTag)) end
        end
    end
    local mc = 0
    for _ in pairs(model) do mc = mc + 1 end
    if mc ~= n then fail(string.format("%s: model has %d points, AutoDrive %d", label, mc, n)) end
    for tag, wp in pairs(byTag) do
        if model[tag] == nil then fail(label .. ": byTag kept a deleted tag")
        elseif GM.wayPoints[wp.id] ~= wp then fail(string.format("%s: tag %d not at its own id", label, tag)) end
    end
end

-- ------------------------------------------------------------------ the door's operations
-- Each changes AutoDrive the way the editor does (sendEvent = false) and the model in tags.

local function linkSet(a, b)   -- one-way a -> b, idempotent
    local wa, wb = byTag[a], byTag[b]
    if has(model[a].out, b) then return end
    GM:toggleConnectionBetween(wa, wb, false, false, false)
    table.insert(model[a].out, b); table.insert(model[b].incoming, a)
end

local function linkClear(a, b) -- removes a -> b if there, idempotent
    local wa, wb = byTag[a], byTag[b]
    if not (has(wa.out, wb.id) or has(wb.incoming, wa.id)) then return end
    GM:toggleConnectionBetween(wa, wb, false, false, false)
    removeFirst(model[a].out, b); removeFirst(model[b].incoming, a)
end

local function deleteClean(t)
    -- The door clears EVERY link touching the point first, including reverse links into it that
    -- the point's own incoming list does not know about. Then AutoDrive removes the bare point.
    local wp = byTag[t]
    for _, o in ipairs({ unpack(model[t].out) }) do linkClear(t, o) end
    for _, i in ipairs({ unpack(model[t].incoming) }) do linkClear(i, t) end
    for _, other in ipairs(modelTags()) do
        if other ~= t and has(model[other].out, t) then
            -- reverse link (out with no incoming): AutoDrive's toggle removes the out entry
            local wo = byTag[other]
            GM:toggleConnectionBetween(wo, wp, false, false, false)
            removeFirst(model[other].out, t)
        end
    end
    local c = os.clock()
    GM:removeWayPoint(wp.id, false)
    adDelTime = adDelTime + (os.clock() - c)
    model[t] = nil
    byTag[t] = nil
end

local function add(x, y, z, flags)
    local wp = GM:recordWayPoint(x, y, z, false, false, false, 0, flags, false)
    local t = newTag()
    wp.fxTag = t
    byTag[t] = wp
    model[t] = { x = x, y = y, z = z, flags = flags, out = {}, incoming = {} }
    return t
end

local function move(t, x, y, z, flags)
    GM:moveWayPoint(byTag[t].id, x, y, z, flags, false)
    local m = model[t]
    m.x, m.y, m.z, m.flags = x, y, z, flags
end

local function spline(a, b, count)
    -- AutoDrive's own createSplineConnection: new points, chained a -> ... -> b
    local wa, wb = byTag[a], byTag[b]
    local pts = {}
    for k = 1, count do
        local f = k / (count + 1)
        pts[k] = { x = wa.x + (wb.x - wa.x) * f, y = wa.y, z = wa.z + (wb.z - wa.z) * f }
    end
    local before = #GM.wayPoints
    GM:createSplineConnection(wa.id, pts, wb.id, false, false)
    local prev = a
    for id = before + 1, #GM.wayPoints do
        local wp = GM.wayPoints[id]
        local t = newTag()
        wp.fxTag, byTag[t] = t, wp
        model[t] = { x = wp.x, y = wp.y, z = wp.z, flags = wp.flags, out = {}, incoming = {} }
        table.insert(model[prev].out, t); table.insert(model[t].incoming, prev)
        prev = t
    end
    table.insert(model[prev].out, b); table.insert(model[b].incoming, prev)
end

-- ------------------------------------------------------------------ random edits
math.randomseed(SEED)
local function anyTag()
    local wp = GM.wayPoints[math.random(1, #GM.wayPoints)]
    return wp.fxTag
end
adDelTime = 0
local counts = { del = 0, add = 0, move = 0, set = 0, clear = 0, spline = 0 }
local delTime = 0
checkAll("start")
local t0 = os.clock()
for step = 1, OPS do
    local r = math.random()
    if r < 0.30 then
        local c = os.clock()
        deleteClean(anyTag())
        delTime = delTime + (os.clock() - c)
        counts.del = counts.del + 1
    elseif r < 0.45 then
        local a = anyTag()
        local t = add(model[a].x + 3, model[a].y, model[a].z + 3, 0)
        linkSet(a, t)
        counts.add = counts.add + 1
    elseif r < 0.65 then
        local t = anyTag()
        move(t, model[t].x + math.random() - 0.5, model[t].y, model[t].z + math.random() - 0.5, model[t].flags)
        counts.move = counts.move + 1
    elseif r < 0.80 then
        local a, b = anyTag(), anyTag()
        if a ~= b then linkSet(a, b) counts.set = counts.set + 1 end
    elseif r < 0.95 then
        local a = anyTag()
        local o = model[a].out[1]
        if o ~= nil then linkClear(a, o) counts.clear = counts.clear + 1 end
    else
        local a, b = anyTag(), anyTag()
        if a ~= b then spline(a, b, math.random(2, 6)) counts.spline = counts.spline + 1 end
    end
    -- a full check is ~17k points; do it often, not always, so the run stays quick
    if step % 50 == 0 or step == OPS then checkAll("after edit " .. step) end
end
local total = os.clock() - t0
print(string.format("edits: %d (delete %d, add %d, move %d, link set %d, link clear %d, spline %d)",
    OPS, counts.del, counts.add, counts.move, counts.set, counts.clear, counts.spline))
print(string.format("network now: %d points; full tag checks: %d; failures: %d", #GM.wayPoints, checks, failures))
print(string.format("time: %.2f s in all; one clean delete %.2f ms on average, of which AutoDrive's removeWayPoint %.2f ms (Lua 5.1, this PC)",
    total, counts.del > 0 and delTime / counts.del * 1000 or 0, counts.del > 0 and adDelTime / counts.del * 1000 or 0))

-- ------------------------------------------------------------------ table identity through setWayPoints
-- A whole-network push (join, reload) builds NEW tables, so tags must travel with it.
local copy = {}
for i, wp in ipairs(GM.wayPoints) do copy[i] = GM:createNode(i, wp.x, wp.y, wp.z, wp.out, wp.incoming, wp.flags) end
GM:setWayPoints(copy)
local lost = 0
for _, wp in ipairs(GM.wayPoints) do if wp.fxTag == nil then lost = lost + 1 end end
print(string.format("after a whole-network push: %d of %d points have no tag (expected: all of them)", lost, #GM.wayPoints))

-- ------------------------------------------------------------------ the dangling-link trap
-- Point P has a normal incoming link from A, and a reverse link from R (R.out has P, P.incoming does
-- not have R). AutoDrive's removeWayPoint only scans for reverse links when P has NO incoming, so R's
-- link to P survives the delete and, after renumbering, points at whatever moved into P's number.
local function demo()
    local s = {}
    s[1] = GM:createNode(1, 0, 0, 0, { 2 }, {}, 0)      -- A -> P
    s[2] = GM:createNode(2, 4, 0, 0, {}, { 1 }, 0)      -- P
    s[3] = GM:createNode(3, 8, 0, 0, { 2 }, {}, 0)      -- R -> P, reverse (P does not list R)
    s[4] = GM:createNode(4, 12, 0, 0, {}, {}, 0)        -- Q, unrelated
    s[1].fxTag, s[2].fxTag, s[3].fxTag, s[4].fxTag = "A", "P", "R", "Q"
    GM:setWayPoints(s)
    GM:removeWayPoint(2, false)
    local R = nil
    for _, wp in ipairs(GM.wayPoints) do if wp.fxTag == "R" then R = wp end end
    local target = R.out[1] and GM.wayPoints[R.out[1]] and GM.wayPoints[R.out[1]].fxTag or "nothing"
    print(string.format("trap: after deleting P with AutoDrive alone, R's reverse link now points at %s", target))
end
demo()

if failures > 0 then os.exit(1) end
