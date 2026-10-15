-- AUTODRIVE'S OWN RIGHT-OF-WAY-CENTRE TEST, run offline. AutoDrive 3.0.1.2 paints a node teal when
-- two or more roads feed into it and at least one leads out - a real merge, where vehicles have to
-- yield. The rule is AutoDrive's (Specialization.lua, getWayPointsInRange), copied exactly, with its
-- three exemptions for nodes that only change road type.
--
-- After a clear there should be no merge left inside the junction: that is what a clear IS. Any
-- centre still showing near the box is a connection the clear failed to take out, and AutoDrive
-- will draw it whether or not our own logs think the site is clean.
LOG_ECHO = false
local H = dofile("harness.lua")
local CX, CZ = tonumber(arg[1]), tonumber(arg[2])
local R = tonumber(arg[3] or "30")

local function contains(t, v)
    for _, x in ipairs(t or {}) do if x == v then return true end end
    return false
end

local function centres()
    local out = {}
    for _, p in pairs(ADGraphManager:getWayPoints()) do
        if p ~= nil and p.id ~= nil and (p.x - CX)^2 + (p.z - CZ)^2 <= R*R then
            local singleIn, singleOut, dual = 0, 0, 0
            for _, i in pairs(p.incoming or {}) do
                if not contains(p.out, i) then singleIn = singleIn + 1 else dual = dual + 1 end
            end
            for _, o in pairs(p.out or {}) do
                if not contains(p.incoming, o) then singleOut = singleOut + 1 end
            end
            local isC = false
            if #(p.out or {}) >= 1 and #(p.incoming or {}) >= 2 then
                isC = true
                if dual == 1 and singleIn == 1 and singleOut == 0 then isC = false
                elseif dual == 1 and singleIn == 0 and singleOut == 1 then isC = false
                elseif dual == 2 and singleIn == 0 and singleOut == 0 then isC = false end
            end
            if isC then
                out[#out+1] = { x = p.x, z = p.z,
                    d = math.sqrt((p.x-CX)^2 + (p.z-CZ)^2),
                    inN = #(p.incoming or {}), outN = #(p.out or {}),
                    dual = dual, sIn = singleIn, sOut = singleOut }
            end
        end
    end
    table.sort(out, function(a,b) return a.d < b.d end)
    return out
end

local b = centres()
H.lock(CX, CZ, { mode="clear", radius=12, leaveThrough=(os.getenv("LEAVE") == "1") })
H.apply()
local a = centres()
print(string.format("right-of-way centres within %d m:  before %d   after %d", R, #b, #a))
print(" AFTER:")
for _, c in ipairs(a) do
    print(string.format("   %5.1f m out  %.2f,%.2f   in=%d out=%d  (dual %d, single-in %d, single-out %d)",
        c.d, c.x, c.z, c.inN, c.outN, c.dual, c.sIn, c.sOut))
end
