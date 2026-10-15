-- Try settings against several roads at once: lua sweep.lua   (edit the CASES/TRIES below)
-- Each try runs: the field track (two starts), the old lane (lanetest), the lane vs the map's line,
-- the town road's weave. Lower is better everywhere.
local HERE = (arg[0]:match("^(.*)[/\]") or ".") .. "/"
local L = '"C:/Program Files (x86)/Lua/5.1/lua.exe"'
local SPL = "C:/Users/gibbs/OneDrive/Documents/My Games/FarmingSimulator2025/savegameBackup/savegame6_backup2026-10-06_17-48/ADFlyoverEditor_roadSplines.xml"
local function run(over, script, args)
    local f = assert(io.open(HERE .. "out/sweep_wrap.lua", "w"))
    f:write("RF_OVERRIDES = " .. over .. "\narg = { [0] = " .. string.format("%q", HERE .. script))
    for _, a in ipairs(args) do f:write(", " .. string.format("%q", a)) end
    f:write(" }\ndofile(arg[0])\n")
    f:close()
    local p = io.popen(L .. " " .. HERE .. "out/sweep_wrap.lua 2>&1")
    local out = p:read("*a"); p:close()
    return out
end
local TRIES = {
    "{ ROBUST_FIT = false, GUIDE_SMOOTH = 0, EDGE_FOLLOW = false, SUSPECT_WIDTH = 1.5 }",   -- before 2026-10-13
    "{}",                                                                                  -- as set
}
for _, t in ipairs(TRIES) do
    local a = run(t, "trackline.lua", { "544.5", "-880", "544.5" }):match("mean ([%d.]+) m, worst ([%d.]+)")
    local a1, a2 = run(t, "trackline.lua", { "544.5", "-880", "544.5" }):match("mean ([%d.]+) m, worst ([%d.]+)")
    local b1, b2 = run(t, "trackline.lua", { "545", "-930", "544.5" }):match("mean ([%d.]+) m, worst ([%d.]+)")
    local c1, c2 = run(t, "lanetest.lua", {}):match("mean ([%d.]+) m, worst ([%d.]+)")
    local d1, d2 = run(t, "centrestudy.lua", { SPL, "-700", "331" }):match("off ([%d.]+), worst ([%d.]+)")
    local w = run(t, "wiggle.lua", { "183.8", "4.2", "192.6", "97.3" })
    local w1, w2, w3, w4 = w:match("mean ([%d.]+) m, worst ([%d.]+).-mean ([%d.]+) m, worst ([%d.]+)")
    print(string.format("%-36s track %s/%s %s/%s  lane %s/%s  map %s/%s  town %s/%s %s/%s", t,
        a1 or "-", a2 or "-", b1 or "-", b2 or "-", c1 or "-", c2 or "-", d1 or "-", d2 or "-", w1 or "-", w2 or "-", w3 or "-", w4 or "-"))
end
