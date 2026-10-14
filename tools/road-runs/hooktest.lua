-- RF.cutEndHooks: a track coming down to a road then bending along its verge is cut at the bend;
-- one that bends far from paving, or a straight one, is left alone.   lua hooktest.lua
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local fails = 0
local function check(name, ok) print((ok and "ok   " or "FAIL ") .. name); if not ok then fails = fails + 1 end end
-- road along z = 0 (paved for z in [-4, 4]); track comes from z = 100 straight down to z = 9, then hooks
-- east 12 m along the verge at z = 9
local function line(withHook, roadZ)
    local P = {}
    for z = 100, 9, -2 do P[#P + 1] = { x = 0, z = z } end
    if withHook then for x = 2, 12, 2 do P[#P + 1] = { x = x, z = 9 } end end
    local L = 0
    for i = 2, #P do L = L + math.sqrt((P[i].x - P[i - 1].x) ^ 2 + (P[i].z - P[i - 1].z) ^ 2) end
    return { pts = P, len = L, class = "track", startTag = "end", endTag = "end" }
end
local paved = function(x, z) return math.abs(z) <= 4 end
local far = function(x, z) return math.abs(z + 100) <= 4 end
local c = RF.cutEndHooks(line(true), paved)
local e = c.pts[#c.pts]
check(string.format("hook by the road cut at the bend (ends at %.0f,%.0f, %s)", e.x, e.z, c.endTag), e.x <= 2 and c.endTag == "fork")
check("start untouched", c.pts[1].z == 100 and c.startTag == "end")
check("hook far from paving left", RF.cutEndHooks(line(true), far) .pts[#line(true).pts].x == 12)
check("straight track left", #RF.cutEndHooks(line(false), paved).pts == #line(false).pts)
local pv = line(true); pv.class = "paved"
check("paved stretch left", #RF.cutEndHooks(pv, paved).pts == #pv.pts)
-- a track that curves DOWN to the road (closer and closer) keeps its bend
local turnIn = { pts = {}, class = "track", startTag = "end", endTag = "end" }
for z = 100, 20, -2 do turnIn.pts[#turnIn.pts + 1] = { x = 0, z = z } end
for k = 1, 8 do turnIn.pts[#turnIn.pts + 1] = { x = -k * 1.4, z = 20 - k * 1.4 } end
turnIn.len = 0
for i = 2, #turnIn.pts do turnIn.len = turnIn.len + math.sqrt((turnIn.pts[i].x - turnIn.pts[i-1].x) ^ 2 + (turnIn.pts[i].z - turnIn.pts[i-1].z) ^ 2) end
check("track turning in to the road keeps its bend", #RF.cutEndHooks(turnIn, paved).pts == #turnIn.pts)
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
