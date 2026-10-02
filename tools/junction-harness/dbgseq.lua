-- ONE JUNCTION CLEARED AFTER ANOTHER: does clearing A first change what the clear does at B?
--   LEAVE=1|0 [PRE=AX,AZ] lua dbgseq.lua BX BZ
-- With PRE, junction A is cleared first (same through mode), then B. Without it B is cleared on
-- the fresh network. Prints B's result in a form that does not depend on point numbers, so the
-- two runs can be diffed line for line (seqreg.sh does that):
--   TOOK  the clear's own total            ROUTE  each through road it kept, by its two ends
--   COUNTS the check after the clear       EDIT   every point and link B's clear added or removed,
--                                                 by position (cm), sorted
-- and APART: how close A's own edits came to B's centre (not part of the comparison - it says
-- whether A could fairly have changed B's ground).
LOG_ECHO = false
local H = dofile("harness.lua")
local lv = (os.getenv("LEAVE") == "1")
local bx, bz = tonumber(arg[1]), tonumber(arg[2])
if bx == nil or bz == nil then
    print("usage: LEAVE=1|0 [PRE=AX,AZ] lua dbgseq.lua BX BZ")
    os.exit(1)
end

local function key(w) return string.format("%.2f %.2f", w.x, w.z) end
local function snap()
    local pts, links = {}, {}
    for _, w in ipairs(ADGraphManager:getWayPoints()) do
        local k = key(w)
        pts[k] = (pts[k] or 0) + 1
        for _, oid in ipairs(w.out or {}) do
            local o = ADGraphManager:getWayPointById(oid)
            if o ~= nil then
                local l = k .. " > " .. key(o)
                links[l] = (links[l] or 0) + 1
            end
        end
    end
    return { pts = pts, links = links }
end
local function diff(s0, s1)
    local lines = {}
    for _, kind in ipairs({ "pts", "links" }) do
        local a, b = s0[kind], s1[kind]
        local tag = (kind == "pts") and "point" or "link"
        for k, n in pairs(a) do
            local m = b[k] or 0
            if m < n then lines[#lines + 1] = string.format("%s - %s x%d", tag, k, n - m) end
        end
        for k, n in pairs(b) do
            local m = a[k] or 0
            if n > m then lines[#lines + 1] = string.format("%s + %s x%d", tag, k, n - m) end
        end
    end
    table.sort(lines)
    return lines
end
local function nearest(lines)
    local best = math.huge
    for _, l in ipairs(lines) do
        for x, z in l:gmatch("(%-?[%d%.]+) (%-?[%d%.]+)") do
            local d = math.sqrt((tonumber(x) - bx) ^ 2 + (tonumber(z) - bz) ^ 2)
            if d < best then best = d end
        end
    end
    return best
end

local pre = os.getenv("PRE")
if pre ~= nil and pre ~= "" then
    local px, pz = pre:match("(%S+),(%S+)")
    local s0 = snap()
    local pj = H.lock(tonumber(px), tonumber(pz), { mode = "clear", radius = 12, leaveThrough = lv })
    if pj == nil then
        print("PRE refused")
    else
        local ok, err = pcall(H.apply)
        if not ok then print("PRE STOPPED " .. tostring(err)) end
        local d = diff(s0, snap())
        print(string.format("APART A's %d edits come within %.1f m of B", #d, nearest(d)))
    end
end

local s1 = snap()
for k in pairs(LOG) do LOG[k] = nil end
local jp = H.lock(bx, bz, { mode = "clear", radius = 12, leaveThrough = lv })
-- SITE=1 (reg75click.sh): where the selection put the site, and the crossing the clear works on
-- ("clearing the one at"), to 0.1 m - two clicks inside one junction must land on the same ones.
if os.getenv("SITE") == "1" then
    local s = ADFlyoverEditor.junctionSite
    print(s and string.format("SITE %.1f %.1f", s.x, s.z) or "SITE none")
    for _, line in ipairs(LOG) do
        local x, z = line:match("clearing the one at (%-?[%d%.]+), (%-?[%d%.]+)")
        if x ~= nil then print("CROSSING " .. x .. " " .. z) break end
    end
end
if jp == nil then
    print("REFUSED " .. tostring(ADFlyoverEditor.junctionRefused))
    return
end
local routes = {}
for _, nodes in ipairs((jp.pathRoutes and jp.pathRoutes.through) or {}) do
    local a, b = nodes[1], nodes[#nodes]
    routes[#routes + 1] = string.format("ROUTE (%.1f, %.1f) to (%.1f, %.1f)", a.x, a.z, b.x, b.z)
end
table.sort(routes)
for _, r in ipairs(routes) do print(r) end
ADFlyoverEditor.junctionLastCheck = nil
local ok, log = pcall(H.apply)
if not ok then
    print("CLEAR STOPPED " .. tostring(log))
    log = LOG
end
local errs = 0
for _, line in ipairs(log) do
    local took = line:match("took %d+ point%(s%) in all, the farthest %d+ m out")
    if took ~= nil then print("TOOK " .. took) end
    if line:find("attempt to") or line:find("stack traceback") or line:find("check[^:]* failed") then
        errs = errs + 1
    end
end
local r = ADFlyoverEditor.junctionLastCheck
if r ~= nil and r.joins ~= nil then
    local function tally(list, field)
        local by, keys = {}, {}
        for _, it in ipairs(list) do
            local k = it[field] or "?"
            if by[k] == nil then keys[#keys + 1] = k end
            by[k] = (by[k] or 0) + 1
        end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%s:%d", k, by[k]) end
        return string.format("%d%s", #list, (#parts > 0) and (" " .. table.concat(parts, " ")) or "")
    end
    print(string.format("COUNTS joins %s | dots %s | other %s | notes %d",
        tally(r.joins or {}, "why"), tally(r.dots or {}, "why"), tally(r.issues or {}, "kind"), #(r.notes or {})))
else
    print("COUNTS no check")
end
print("ERRORS " .. errs)
for _, l in ipairs(diff(s1, snap())) do print("EDIT " .. l) end
