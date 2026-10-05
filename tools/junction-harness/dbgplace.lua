-- PLACE MODE, offline (docs/junction-tool/08-place-junction.md): lock a crossing in place mode, read the
-- card's preview, right-click it, and report what was laid.
--   lua dbgplace.lua X Z
--   GRAPH=<network .lua>   the exported map
--   CLEARFIRST=1           clear the site first (through roads kept), as you would in game
--   PATTERN=exact|smooth   the card's shape (default exact)
-- Last line, PLACE, is one line for a regression to collect.
LOG_ECHO = false
local H = dofile("harness.lua")
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
if CX == nil or CZ == nil then
    print("usage: lua dbgplace.lua X Z")
    os.exit(1)
end
local E = ADFlyoverEditor

local function count()
    local p, l = 0, 0
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil and (w.x - CX) ^ 2 + (w.z - CZ) ^ 2 <= 40 * 40 then
            p = p + 1
            l = l + #(w.out or {})
        end
    end
    return p, l
end

if os.getenv("CLEARFIRST") == "1" then
    local cjp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = true })
    if cjp ~= nil then H.apply() print("cleared the site first (through roads kept)") end
end

local p0, l0 = count()
local jp = H.lock(CX, CZ, { mode = "place" })
if jp == nil or not jp.placeMode then
    print("no place preview")
    print(string.format("PLACE %.1f %.1f ok=0 kind=- shape=- turns=0 shared=0 points=0 links=0 loose=0 why=no_preview", CX, CZ))
    return
end
if jp.ok then
    print(string.format("card: will place %s %s, lane gap %.1f m, %d loose end(s)%s", jp.plan.shape, jp.plan.kind, jp.plan.L,
        #(jp.plan.loose or {}), jp.plan.fitWhy and (" - does not fit: " .. jp.plan.fitWhy) or ""))
else
    print("card: cannot place here - " .. tostring(jp.why))
end
LOG = {}
if jp.ok then E:applyJunction() end
if os.getenv("ALL") == "1" then for _, l in ipairs(LOG) do print("  " .. l) end end
local p1, l1 = count()
local last = E.junctionLastPlace or {}
print(string.format("PLACE %.1f %.1f ok=%d kind=%s shape=%s turns=%d shared=%d points=%d links=%d loose=%d why=%s",
    CX, CZ, (jp.ok and last.ok) and 1 or 0, tostring(last.kind or (jp.plan and jp.plan.kind) or "-"),
    tostring(last.shape or "-"), last.turns or 0, last.shared or 0, p1 - p0, l1 - l0, last.loose or 0,
    (tostring(jp.ok and (last.why or "-") or jp.why)):gsub(" ", "_")))
