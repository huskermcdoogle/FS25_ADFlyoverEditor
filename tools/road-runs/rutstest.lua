-- The rut-pair reading, on made-up cross-sections from the 2026-10-12 game log and screenshots.
--   lua rutstest.lua
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
g_currentMission = { terrainRootNode = 1 }
dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder
local fails = 0
-- pattern: one char per 0.5 m from -8 to +8 (33 chars, the log's layout without the '|'); 'd' = dirt
local function case(name, pattern, want)
    local function isRoad(x, z)
        local i = math.floor((x + 8) / 0.5 + 0.5) + 1
        local c = pattern:sub(i, i)
        return c == "d" or c == "g"
    end
    local bands = RF.bandsAt(isRoad, 0, 0, 1, 0, "track")
    local pick = nil
    for _, b in ipairs(bands) do if pick == nil or math.abs(b.mid) < math.abs(pick.mid) then pick = b end end
    local got = pick and pick.mid or 999
    local ok = math.abs(got - want) <= 0.3
    if not ok then fails = fails + 1 end
    print(string.format("%s %-22s middle %.2f (want %.2f)  %s", ok and "ok  " or "FAIL", name, got, want, pattern))
end
-- log 21:39 "FFFFFFFFFF....dd|..dd..dFFFFFFFFFF": ruts at -1..-0.5 and +1..+1.5, a stray mud strip at +3
case("ruts + headland mud", "..............dd..dd..d..........", 0.25)
case("ruts 2 m apart", ".............dd...dd..............", 0.0)
case("three strips", "............dd..dd..dd...........", -0.75)
case("wide gravel track", "...........gggggggggg............", -0.25)
case("one rut only", "..............dd...................", -0.75)
print(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
