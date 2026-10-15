-- One test case (a track_N.xml saved in game with "draw the middle"): walk it from several mouse spots
-- along the user's middle, the way the game's hover walk does, and print the lines for scorecases.lua.
--   set AREA=<case.xml> && set AREAONLY=1 && lua casewalk.lua
-- prints: "m x z" (the user's middle), "s i x z" (spot i), "l i x z" (the line walked from spot i)
local HERE = (arg[0]:match("^(.*)[/\\]") or ".") .. "/"
local JH = dofile(HERE .. "datadir.lua")(HERE)
local real = os.getenv
os.getenv = function(k) if k == "TERRAIN_DIR" then return JH .. "terrain_data/" end return real(k) end
g_currentMission = { terrainRootNode = 1 }; AutoDrive, CollisionFlag = {}, {}
dofile(HERE .. "terrain.lua"); dofile(HERE .. "../../scripts/editor/RoadFinder.lua")
local RF = ADRoadFinder

-- the middle the user drew
local mid = {}
for x, z in TERRAIN.area.xml:match('<middle [^>]*pts="([^"]*)"'):gmatch("(%S+),(%S+)") do
    mid[#mid + 1] = { x = tonumber(x), z = tonumber(z) }
end
for _, p in ipairs(mid) do print(string.format("m %.2f %.2f", p.x, p.z)) end

-- the game's walk tests (RoadRunsTool.lua roadRunsWalkTests), every kind of road switched on
local kindAt, fieldAt = RF.groundKindAt, RF.isFieldAt
RF.kindReader, RF.fieldReader = kindAt, fieldAt
local shoulderAt = RF.newShoulderMap(kindAt)
local function nearPaved(x, z)
    local d = RF.PAVED_EDGE
    for k = 0, 7 do
        local a = k * math.pi / 4
        if kindAt(x + math.cos(a) * d, z + math.sin(a) * d) == RF.KIND_PAVED then return true end
    end
    return false
end
local function isRoadOf(cls)
    if cls == "paved" then return function(x, z) return kindAt(x, z) == RF.KIND_PAVED end end
    return function(x, z)
        local k = kindAt(x, z)
        if k ~= RF.KIND_GRAVEL and k ~= RF.KIND_DIRT then return false end
        return not nearPaved(x, z) and not shoulderAt(x, z)
    end
end
local function isStopOf(cls)
    if cls == "track" then return function(x, z) return kindAt(x, z) == RF.KIND_PAVED or shoulderAt(x, z) end end
    return nil
end

-- the spots: spread along the middle, each a little to one side (a mouse is never dead centre)
local along = { 0 }
for i = 2, #mid do along[i] = along[i - 1] + math.sqrt((mid[i].x - mid[i - 1].x) ^ 2 + (mid[i].z - mid[i - 1].z) ^ 2) end
local total = along[#along]
local FRACS = { 0.1, 0.3, 0.5, 0.7, 0.9 }
local SIDE = tonumber(os.getenv("SIDE") or "0.6")
RF.WALK.maxLen = 400                                     -- E.ROADRUNS_POINT_WALK
-- ONLY=i: just spot i; TRACE=1: the walker's own trace (RF.TRACE)
local ONLY = tonumber(os.getenv("ONLY") or "")
RF.TRACE = os.getenv("TRACE") ~= nil
for si, f in ipairs(FRACS) do
  if ONLY == nil or ONLY == si then
    local want, i = f * total, 2
    while i < #mid and along[i] < want do i = i + 1 end
    local a, b = mid[i - 1], mid[i]
    local seg = math.max(1e-6, along[i] - along[i - 1])
    local u = math.min(1, math.max(0, (want - along[i - 1]) / seg))
    local dx, dz = (b.x - a.x) / seg, (b.z - a.z) / seg
    local side = (si % 2 == 0) and SIDE or -SIDE
    local sx, sz = a.x + (b.x - a.x) * u - dz * side, a.z + (b.z - a.z) * u + dx * side
    print(string.format("s %d %.2f %.2f", si, sx, sz))
    -- one walk as the game's tool does it (RoadRunsTool roadRunsWalkLine)
    local function walkLine(wx, wz)
        local ok, r = pcall(RF.walkFrom, isRoadOf, wx, wz, { "paved", "track" }, isStopOf)
        if ok and r ~= nil and r.pts ~= nil and #r.pts >= 4 then
            local STAGES = os.getenv("STAGES") ~= nil
            local function stage(name, q)
                if STAGES then
                    print(string.format("# spot %d %s: %s", si, name, q and string.format("%d pts, %.0f m, (%.1f,%.1f)..(%.1f,%.1f) %s..%s",
                        #q.pts, q.len or 0, q.pts[1].x, q.pts[1].z, q.pts[#q.pts].x, q.pts[#q.pts].z, tostring(q.startTag), tostring(q.endTag)) or "nil"))
                end
            end
            stage("walked", r)
            if STAGES then
                for _, q in ipairs(r.pts) do print(string.format("W %.2f %.2f", q.x, q.z)) end
                for _, q in ipairs(r.raw or {}) do print(string.format("R %.2f %.2f", q.x, q.z)) end
            end
            r = RF.cutHairpins(r, wx, wz)
            stage("hairpins cut", r)
            if r ~= nil then r = RF.cutEndHooks(r, function(x, z) return kindAt(x, z) == RF.KIND_PAVED end) end
            stage("hooks cut", r)
            if r ~= nil then r = RF.trimGhosts(r, isRoadOf(r.class), r.class, wx, wz) end
            stage("ghosts trimmed", r)
            return r
        elseif not ok then
            print("e " .. si .. " " .. tostring(r))
        end
        return nil
    end
    -- VOTE=1: as a click does - walked from here and from five spots along it, the majority kept
    local r
    if os.getenv("VOTE") then RF.TRACE_VOTE = os.getenv("TRACE_VOTE") ~= nil r = RF.voteWalk(walkLine, sx, sz) else r = walkLine(sx, sz) end
    if r ~= nil and r.pts ~= nil and #r.pts >= 4 then
        print(string.format("c %d %s", si, tostring(r.class)))
        for _, p in ipairs(r.pts) do print(string.format("l %d %.2f %.2f", si, p.x, p.z)) end
    end
  end
end
