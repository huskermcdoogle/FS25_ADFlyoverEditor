-- EVERY SPAN TOOL ON A LOOP, offline (2026-11-03): each span tool's own click handler on a made-up copy
-- of Welker Farms' loop, then the span that tool will act on, read back the way the tool reads it.
--
-- Network: a two-way road 1 - 2 - 3 - 4 - 5 - 6 along z=0, and a one-way loop that leaves it at junction 3
-- and comes back at junction 4, 2.5 m further on: 3 -> 7 -> 8 ... -> 14 -> 4. Clicks 7, 10, 14, 5, 3 carry
-- the span round the loop, onto the road past 4 and back to 3 (Welker 22:01). The span every tool acts on
-- must be the one carried there, 7 .. 14, 4, 3 - never the 2.5 m road between 3 and 4, nor 3 straight to 7.
--   lua spantools.lua           (from tools/junction-harness; no map data needed)
-- Prints PASS or FAIL lines and exits 1 on any FAIL.

local graphFile = os.tmpname()
do
    local f = assert(io.open(graphFile, "w"))
    f:write("return {\n")
    local roadX = { -15, -7.5, 0, 2.5, 6, 12 }
    for k = 1, 6 do
        local outs = {}
        if k > 1 then outs[#outs + 1] = k - 1 end
        if k < 6 then outs[#outs + 1] = k + 1 end
        if k == 3 then outs[#outs + 1] = 7 end
        f:write(string.format("  {id=%d,x=%.3f,y=0,z=0,flags=0,out={%s}},\n", k, roadX[k], table.concat(outs, ",")))
    end
    for k = 0, 7 do
        local a = math.rad(250 - k * 40)
        f:write(string.format("  {id=%d,x=%.3f,y=0,z=%.3f,flags=0,out={%d}},\n", 7 + k,
            1.25 + 7 * math.cos(a), 7.5 + 7 * math.sin(a), k < 7 and 8 + k or 4))
    end
    f:write("}\n")
    f:close()
end

local realGetenv = os.getenv
os.getenv = function(k) if k == "GRAPH" then return graphFile end return realGetenv(k) end
dofile("harness.lua")
os.getenv = realGetenv
os.remove(graphFile)
local E = ADFlyoverEditor
ADGraphManager.getMapMarkerByWayPointId = ADGraphManager.getMapMarkerByWayPointId or function() return nil end
getTerrainHeightAtWorldPos = function() return 0 end
E.warnPlayer = function(_, m) print("     [warning] " .. tostring(m)) end
E.selectionCount, E.pickFilter = 0, nil
local clock = 0
E.nowMs = function() return clock end

local WANT = "7,8,9,10,11,12,13,14,4,3"
local CLICKS = { 7, 10, 14, 5, 3 }

local function reset()
    E:invalidateIdReferences()
    E.spanIds, E.spanMovingEndId, E.ctxMenu = nil, nil, nil
    E.moveSpanFromId, E.moveSpanToId, E.moveSpanIds = nil, nil, nil
    E.mergeNear, E.mergePreviewQueryId = nil, nil
end
local function clickWith(fn, id)
    clock = clock + 5000   -- never a double-click
    E.hoverId = id
    fn(id)
end
local function text(list)
    if list == nil then return "none" end
    return table.concat(list, ",")
end
-- Move keeps its pick as a set; compare it as the sorted ids of WANT.
local function setText(set)
    if set == nil then return "none" end
    local t = {}
    for id in pairs(set) do t[#t + 1] = id end
    table.sort(t)
    return table.concat(t, ",")
end
local function sortedWant()
    local t = {}
    for id in WANT:gmatch("%d+") do t[#t + 1] = tonumber(id) end
    table.sort(t)
    return table.concat(t, ",")
end

local fails = 0
local function check(what, got, want)
    local ok = got == want
    print(string.format("%s %s: got %s%s", ok and "PASS" or "FAIL", what, got, ok and "" or (", want " .. want)))
    if not ok then fails = fails + 1 end
end

local TOOLS = {
    { "Smooth", E.TOOL.SMOOTH, function() E:smoothClick() end,
        function() E:updateSmoothPreview(); return text(E.smoothPreviewIds) end },
    { "Straighten", E.TOOL.STRAIGHTEN, function() E:straightenClick() end,
        function() local _, span = E:straightenSpanPoints(); return text(span) end },
    { "Divide", E.TOOL.DIVIDE, function() E:divideClick() end,
        function() return text(E:spanBetween(E.divideFromId, E.divideToId)) end },
    { "Ground", E.TOOL.GROUND, function() E:groundClick() end,
        function() return text(E:spanBetween(E.groundFromId, E.groundToId)) end },
    { "Parallel", E.TOOL.PARALLEL, function() E:offsetClick() end,
        function() local _, span = E:offsetSpanPoints(); return text(span) end },
    { "Merge", E.TOOL.MERGE, function() E:mergeClick() end,
        function() return text(E:spanBetween(E.mergeFromId, E.mergeToId)) end },
}
for _, t in ipairs(TOOLS) do
    reset()
    E.tool = t[2]
    for _, id in ipairs(CLICKS) do clickWith(t[3], id) end
    check(t[1] .. ": span carried round the loop and back", t[4](), WANT)
end

-- Move: its own click handler (moveGestureClick), then the set a drag would move.
reset()
E.tool = E.TOOL.MOVE
for _, id in ipairs(CLICKS) do clickWith(function(i) E:moveGestureClick(i) end, id) end
check("Move: span carried round the loop and back", setText(E.moveSpanIds), sortedWant())

-- Move armed from a Select popup on 7..10, then carried on with clicks 14, 5, 3.
reset()
E.tool = E.TOOL.NONE
E.ctxMenu = { kind = "span", fromId = 7, toId = 10, ids = { 7, 8, 9, 10 } }
E:menuArmMoveSpan()
for _, id in ipairs({ 14, 5, 3 }) do clickWith(function(i) E:moveGestureClick(i) end, id) end
check("Move from the Select popup: carried on round the loop and back", setText(E.moveSpanIds), sortedWant())

-- The card's NEXT text through a pick, the same on every span tool (spanPickNextStep): before the first
-- click, after it, with both ends set, after clicking the first end (picked up), and once it is placed.
local STEPS = {
    { nil, "double-click for the whole run" },
    { 7, "Click the other end" },
    { 10, "move the last end set" },
    { 7, "End picked up" },
    { 8, "move the last end set" },
}
local shown = {}
for _, t in ipairs(TOOLS) do
    reset()
    E.tool = t[2]
    local ok, where = true, ""
    for k, step in ipairs(STEPS) do
        if step[1] ~= nil then clickWith(t[3], step[1]) end
        local msg = E:getNextStepLines()
        shown[k] = shown[k] or {}
        shown[k][t[1]] = msg
        if not tostring(msg):find(step[2], 1, true) then
            ok, where = false, string.format("step %d said: %s", k, tostring(msg))
            break
        end
    end
    check(t[1] .. ": NEXT text through the pick", ok and "ok" or where, "ok")
end
-- More NEXT states (2026-11-04), the same on every span tool: after a double-click run (no end set last),
-- with the picks row locked to run or span, and armed from a Select popup (a click off it cancels).
local function nextText() return tostring(E:getNextStepLines()) end
local function has(s, w) return s:find(w, 1, true) ~= nil end
local function doubleClick(fn, id)
    clock = clock + 5000; E.hoverId = id; fn(id)
    clock = clock + 100; E.hoverId = id; fn(id)
end
for _, t in ipairs(TOOLS) do
    reset(); E.tool = t[2]
    doubleClick(t[3], 9)
    local afterRun = nextText()
    E.pickFilter = "run"
    local lockedRun = nextText()
    reset(); E.tool = t[2]
    local lockRunStart = nextText()
    E.pickFilter = "span"
    local lockSpanStart = nextText()
    E.pickFilter = nil
    reset(); E.tool = t[2]
    clickWith(t[3], 7); clickWith(t[3], 10)
    E.ctxMenu = { kind = "armed", tool = t[2] }
    local armed = nextText()
    E.ctxMenu = nil
    local ok = has(afterRun, "nearer end") and has(lockedRun, "run through that point")
        and has(lockRunStart, "Click a run") and not has(lockSpanStart, "double-click")
        and has(armed, "Esc goes back") and not has(armed, "More clicks") and not has(armed, "A click")
        and select(2, armed:gsub("Right%-click applies", "")) <= 1
    check(t[1] .. ": NEXT after a run, locked, and armed", ok and "ok" or table.concat({ afterRun, lockedRun,
        lockRunStart, lockSpanStart, armed }, " || "), "ok")
end
reset(); E.tool = E.TOOL.PARALLEL
clickWith(function() E:offsetClick() end, 7); clickWith(function() E:offsetClick() end, 10)
check("Parallel: NEXT says distance, as the card does", has(nextText(), "Wheel sets distance") and "ok" or nextText(), "ok")

-- Move: what is picked now, not the select mode.
local function moveClick(i) E:moveGestureClick(i) end
reset(); E.tool = E.TOOL.MOVE
local m0 = nextText()
clickWith(moveClick, 7)
local m1 = nextText()
clickWith(moveClick, 10)
local m2 = nextText()
reset(); E.tool = E.TOOL.MOVE
doubleClick(moveClick, 9)
local m3 = nextText()
reset(); E.tool = E.TOOL.MOVE
E.selectionCount = 3
local m4 = nextText()
E.selectionCount = 0
local okMove = has(m0, "click two points") and has(m1, "other end for a span") and has(m2, "any point of the span")
    and has(m3, "any point of the run") and has(m3, "nearer end") and has(m4, "selected point")
check("Move: NEXT for nothing, a first click, a span, a run, a selection", okMove and "ok" or table.concat({ m0, m1,
    m2, m3, m4 }, " || "), "ok")

if os.getenv("SHOWNEXT") then
    for k = 1, #STEPS do
        print(string.format("-- step %d", k))
        for _, t in ipairs(TOOLS) do print(string.format("   %-10s %s", t[1], tostring(shown[k][t[1]]))) end
    end
end

print(fails == 0 and "ALL PASS" or (fails .. " FAIL(S)"))
os.exit(fails == 0 and 0 or 1)
