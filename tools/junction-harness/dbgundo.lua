-- Does undo after a junction clear put back the network exactly as it was before the clear?
--   LEAVE=0|1 lua dbgundo.lua X Z
-- Loads the REAL undo (scripts/editor/EditorHistory.lua, or EH_SRC=...) over the harness's stub,
-- then locks and clears the site the way dbgstages.lua does. Prints one line:
--   UNDO ok|FAIL pushed=N changed=yes|no undo=exact|DIFFERS|none redo=exact|DIFFERS|none stopped=yes|no
--        took=N far=N err=N after=<checksum>
-- pushed   steps the clear put on the undo stack: one if it changed anything, none if not
-- changed  whether the clear changed the network at all
-- undo     the network after one undo, against the network before the clear - every field of every
--          point, in order, compared as text
-- redo     the network after redo, against the network after the clear
-- stopped  the clear cleaned the site and then found nothing left to clear
-- after    a checksum of the network after the clear, to hold one build's clear against another's
local H = dofile("harness.lua")
dofile(os.getenv("EH_SRC") or "../../scripts/editor/EditorHistory.lua")

local function key(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return a < b
end
local function text(v)
    if type(v) == "number" then return string.format("%.17g", v) end
    if type(v) ~= "table" then return tostring(v) end
    local ks = {}
    for k in pairs(v) do ks[#ks + 1] = k end
    table.sort(ks, key)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = tostring(k) .. ":" .. text(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
--- The whole network as text, one line per point in id order, plus markers and groups.
local function net()
    local wps = ADGraphManager:getWayPoints()
    local lines = { "n=" .. #wps }
    for i = 1, #wps do lines[#lines + 1] = i .. " " .. text(wps[i]) end
    lines[#lines + 1] = "markers " .. text(ADGraphManager:getMapMarkers())
    lines[#lines + 1] = "groups " .. text(ADGraphManager:getGroups())
    return lines
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
--- Where two networks part: line counts and the first line that differs.
local function where(a, b)
    for i = 1, math.max(#a, #b) do
        if a[i] ~= b[i] then
            return string.format("%s vs %s, first at line %d:\n    want %s\n    got  %s",
                a[1], b[1], i, tostring(a[i]):sub(1, 160), tostring(b[i]):sub(1, 160))
        end
    end
    return "identical"
end
local function checksum(lines)
    local h1, h2 = 0, 0
    for _, s in ipairs(lines) do
        for i = 1, #s, 4096 do
            local bytes = { s:byte(i, math.min(i + 4095, #s)) }
            for j = 1, #bytes do
                h1 = (h1 * 31 + bytes[j]) % 2147483647
                h2 = (h2 * 131 + bytes[j]) % 2147483629
            end
        end
        h1 = (h1 * 31 + 10) % 2147483647
        h2 = (h2 * 131 + 10) % 2147483629
    end
    return string.format("%08x%08x", h1, h2)
end

H.lock(tonumber(arg[1]), tonumber(arg[2]), { mode = "clear", radius = 12, leaveThrough = (os.getenv("LEAVE") == "1") })
-- NOTHING_LEFT=1: the site reads as having nothing to clear, before the cleaning and after it, so
-- the clear cleans the site and stops. No registry junction does that on its own, and it is the one
-- way a clear can change the network without clearing anything.
if os.getenv("NOTHING_LEFT") == "1" then
    local E = ADFlyoverEditor
    local function nothing(jp)
        if jp ~= nil then
            jp.turnDebris, jp.debris, jp.throughDebris, jp.staleLinks, jp.throughLinks = {}, {}, {}, {}, {}
        end
    end
    nothing(E.junctionPreview)
    local read = E.updateJunctionPreview
    E.updateJunctionPreview = function(self, ...)
        local r = read(self, ...)
        nothing(self.junctionPreview)
        return r
    end
end
local before = net()
local d0 = ADEditorHistory:depth()
local log = H.apply()
local after = net()
local pushed = ADEditorHistory:depth() - d0
local changed = not same(before, after)

local took, far, err, stopped = "-", "-", 0, false
for _, l in ipairs(log) do
    local t, f = l:match("took (%d+) point%(s%) in all, the farthest (%d+) m")
    if t then took, far = t, f end
    if l:find("attempt to") or l:find("stack traceback") then err = err + 1 end
    if l:find("nothing here for this site to clear") then stopped = true end
end

local undo, redo, notes = "none", "none", {}
if pushed >= 1 then
    ADEditorHistory:undo()
    local back = net()
    undo = same(before, back) and "exact" or "DIFFERS"
    if undo ~= "exact" then notes[#notes + 1] = "  undo: " .. where(before, back) end
    if pushed == 1 then
        ADEditorHistory:redo()
        local again = net()
        redo = same(after, again) and "exact" or "DIFFERS"
        if redo ~= "exact" then notes[#notes + 1] = "  redo: " .. where(after, again) end
    end
elseif changed then
    notes[#notes + 1] = "  changed with nothing to undo: " .. where(before, after)
end

local ok = (pushed == 1 and undo == "exact" and redo == "exact") or (pushed == 0 and not changed)
print(string.format("UNDO %s pushed=%d changed=%s undo=%s redo=%s stopped=%s took=%s far=%s err=%d after=%s",
    ok and "ok" or "FAIL", pushed, changed and "yes" or "no", undo, redo, stopped and "yes" or "no", took, far, err,
    checksum(after)))
for _, n in ipairs(notes) do print(n) end
