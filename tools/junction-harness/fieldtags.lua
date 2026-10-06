-- AUTODRIVE'S FIELD POINT TAGS SURVIVE OUR TOOLS (AutoDrive 3.0.1.4). Its editor lays a loop round a
-- field (Ctrl+Shift+F) and tags each point with a flag bit (FLAG_FIELD_POINT, 8) and the field's number
-- (wp.fieldID); pressed again it deletes the points carrying both and lays the loop anew. The rules
-- (ADFlyoverRecordWayPoint, ADFlyoverEditor.fieldOf / withPriority):
--   a priority change keeps every other bit;
--   a point that replaces or carries on a field point (smooth, divide, straighten, a point put into a
--   link of the loop) takes its field number, and the bit with it;
--   any other new point (a copy, a new road) drops the bit: without the number it is a stray.
-- Runs the real editor code on a few points laid far from the network, with stand-ins for the graph
-- calls the harness does not have.
--   lua fieldtags.lua            prints one line per check, then "N ok, M failed"
dofile("harness.lua")
local E = ADFlyoverEditor
local G = ADGraphManager
local FIELD = 8
-- AutoDrive's flag values (scripts/AutoDrive.lua, 3.0.1.4); the harness's stand-in does not have them
AutoDrive.FLAG_NONE, AutoDrive.FLAG_SUBPRIO = 0, 1
AutoDrive.FLAG_TRAFFIC_SYSTEM, AutoDrive.FLAG_TRAFFIC_SYSTEM_CONNECTION, AutoDrive.FLAG_FIELD_POINT = 2, 4, 8

-- what AutoDrive does and the harness stubs out
function ADGraphManager:setWayPointFlags(id, flags) local w = self:getWayPointById(id) if w then w.flags = flags end end
function ADGraphManager:toggleConnectionBetween(a, b, reverse, dual)
    local function has(t, v) for i, x in ipairs(t) do if x == v then return i end end end
    local i = has(a.out, b.id)
    if i then
        table.remove(a.out, i)
        local j = has(b.incoming, a.id) if j then table.remove(b.incoming, j) end
    else
        table.insert(a.out, b.id) table.insert(b.incoming, a.id)
        if dual then table.insert(b.out, a.id) table.insert(a.incoming, b.id) end
    end
end
E.resolveHeightAt = function(_, _, _, y) return y or 0 end
ADEditorHistory = ADEditorHistory or {}
ADEditorHistory.snapshot = function() end

local ok, failed = 0, 0
local function check(name, cond, detail)
    if cond then ok = ok + 1 print("ok    " .. name)
    else failed = failed + 1 print("FAIL  " .. name .. (detail and ("  (" .. detail .. ")") or "")) end
end
local function isField(w) return math.floor((w.flags or 0) / 8) % 2 == 1 end
-- a chain of points far from the network, linked one way, each tagged as field `fid` (or plain)
local function chain(n, x0, flags, fid)
    local ids = {}
    for i = 1, n do
        local w = G:recordWayPoint(x0 + 10 * (i - 1), 0, 9000, i > 1, false, false, ids[#ids], flags)
        w.fieldID = fid
        ids[#ids + 1] = w.id
    end
    return ids
end

-- 1. the helpers
check("withPriority: field point made secondary keeps its field bit", E.withPriority(FIELD, true) == FIELD + 1)
check("withPriority: secondary field point made primary keeps its field bit", E.withPriority(FIELD + 1, false) == FIELD)
check("withPriority: map-road marks (2, 4) stay too", E.withPriority(6, true) == 7)
check("fieldOf: a field point gives its number", E.fieldOf({ flags = FIELD, fieldID = 7 }) == 7)
check("fieldOf: a number without the bit is no field point", E.fieldOf({ flags = 0, fieldID = 7 }) == nil)
check("fieldOf: the bit without a number is no field point", E.fieldOf({ flags = FIELD }) == nil)

-- 2. new points
local w = ADFlyoverRecordWayPoint(9000, 0, 9000, false, false, false, 0, FIELD + 1, false)
check("a new point copying a field point's flags (a copy) drops the field bit", w.flags == 1 and w.fieldID == nil,
    "flags " .. tostring(w.flags))
w = ADFlyoverRecordWayPoint(9010, 0, 9000, false, false, false, 0, FIELD + 1, false, 7)
check("a new point carrying on field 7 keeps the bit and the number", w.flags == FIELD + 1 and w.fieldID == 7,
    "flags " .. tostring(w.flags) .. " field " .. tostring(w.fieldID))
w = ADFlyoverRecordWayPoint(9020, 0, 9000, false, false, false, 0, 6 + FIELD, false, 7)
check("map-road marks still dropped on a new point, field kept", w.flags == FIELD and w.fieldID == 7, "flags " .. tostring(w.flags))

-- 3. convert: a selection of field points made secondary, then primary
local ids = chain(3, 9100, FIELD, 7)
E.selection, E.selectionCount = {}, 0
for _, id in ipairs(ids) do E.selection[id] = true E.selectionCount = E.selectionCount + 1 end
E:menuConvertSelection(E.CONVERT_OP.SECONDARY)
local allSec, allField = true, true
for _, id in ipairs(ids) do
    local p = G:getWayPointById(id)
    if p.flags % 2 ~= 1 then allSec = false end
    if not isField(p) or p.fieldID ~= 7 then allField = false end
end
check("convert to secondary: the points are secondary", allSec)
check("convert to secondary: they are still field 7's points", allField)
E:menuConvertSelection(E.CONVERT_OP.PRIMARY)
local p1 = G:getWayPointById(ids[1])
check("convert back to primary: still field 7's", p1.flags == FIELD and p1.fieldID == 7, "flags " .. tostring(p1.flags))

-- 4. smooth / divide / straighten: a stretch of field 7's loop rebuilt
ids = chain(4, 9200, FIELD, 7)
local before = G:getWayPointsCount()
local newPts = { { x = 9200, z = 9000 }, { x = 9207, z = 9001 }, { x = 9214, z = 9002 }, { x = 9221, z = 9001 }, { x = 9230, z = 9000 } }
E:replaceChainInterior(ids, newPts, false, G:getWayPointById(ids[2]).flags)
local made, madeOk = 0, true
for i = 1, G:getWayPointsCount() do
    local q = G:getWayPointById(i)
    if q.z >= 9000.5 and q.x > 9200 and q.x < 9230 then
        made = made + 1
        if not (isField(q) and q.fieldID == 7) then madeOk = false end
    end
end
check("a rebuilt stretch of field 7's loop: 3 new points", made == 3, "made " .. made)
check("a rebuilt stretch of field 7's loop: all still field 7's", madeOk)

-- 5. a point put into a link
ids = chain(2, 9300, FIELD, 7)
local nid = E:insertOnSegment(ids[1], ids[2], { x = 9305, y = 0, z = 9000 }, false, FIELD)
local n = G:getWayPointById(nid)
check("a point put into a link of field 7's loop is field 7's", n and isField(n) and n.fieldID == 7)
local a = chain(1, 9400, FIELD, 7)[1]
local b = chain(1, 9410, FIELD, 9)[1]
G:toggleConnectionBetween(G:getWayPointById(a), G:getWayPointById(b), false, false)
nid = E:insertOnSegment(a, b, { x = 9405, y = 0, z = 9000 }, false, FIELD)
n = G:getWayPointById(nid)
check("a point put between two different fields' points belongs to neither", n and not isField(n) and n.fieldID == nil,
    n and ("flags " .. tostring(n.flags)) or "none")

print(string.format("%d ok, %d failed", ok, failed))
