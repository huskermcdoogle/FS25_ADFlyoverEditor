-- REDO, offline: build the given junctions in order, then clear + build each of them ROUNDS times (3 by
-- default), as the card's third action does, and say each time whether the pattern went in and what the
-- route check found. RADIUS = search radius, TURNR = turn radius, GAMEFLAGS=1 the game's checks; TRACE=1
-- says what the clear half saw.
--   lua dbgrounds.lua x1 z1 [x2 z2 ...]     e.g. the course's pair: GRAPH=course/course_init.lua REGDIR=course
--   lua dbgrounds.lua -160 -200 -140 -200
local H = dofile("harness.lua")
local E = ADFlyoverEditor
dofile("../../scripts/editor/EditorHistory.lua")
local R = tonumber(os.getenv("RADIUS") or "")
local sites = {}
for i = 1, #arg, 2 do sites[#sites + 1] = { tonumber(arg[i]), tonumber(arg[i + 1]) } end
local function rc()
    for i = #LOG, 1, -1 do local l = LOG[i] if l:find("route check %-") or l:find("AutoDrive can take") then return (l:gsub(".*route check %- ", ""):gsub(".*%]: junction route check %- ", "")) end end
    return "?"
end
for _, s in ipairs(sites) do LOG = {} H.lock(s[1], s[2], { mode = "build", radius = R }) H.build()
    print(string.format("build %.0f,%.0f: %s; %s", s[1], s[2], E.junctionLastPatternWhy and ("no pattern - " .. E.junctionLastPatternWhy) or "pattern", rc())) end
for round = 1, tonumber(os.getenv("ROUNDS") or "3") do
    for _, s in ipairs(sites) do
        LOG = {}
        H.lock(s[1], s[2], { mode = "clear", thenBuild = true, radius = R })
        local jpc = E.junctionPreview
        if os.getenv("TRACE") then print(string.format("  preview: %s clearMode=%s nothingToClear=%s refused=%s", jpc and "yes" or "no", tostring(jpc and jpc.clearMode), tostring(jpc and jpc.nothingToClear), tostring(E.junctionRefused))) end
        E:applyJunctionClearThenBuild()
        if os.getenv("TRACE") then for _, l in ipairs(LOG) do if l:find("clear %+ build %-") then print("  " .. l) end end end
        print(string.format("round %d %.0f,%.0f: %s; %s", round, s[1], s[2], E.junctionLastPatternWhy and ("no pattern - " .. E.junctionLastPatternWhy) or "pattern", rc()))
    end
end
