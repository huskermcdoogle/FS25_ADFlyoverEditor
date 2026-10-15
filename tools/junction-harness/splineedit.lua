-- EDIT A PLACED SPLINE, offline (2026-10-15): the real editor (every module, Spline.lua included) on
-- the exported network. Picks up to N runs (between junctions, at least 30 m), and for each: selects it
-- the way the card's "edit placed" click does, moves its middle point 2 m sideways, applies, then checks
--   - the run laid again still joins its own two end waypoints (the same tables as before),
--   - no link from the rest of the network to the run's ends or anywhere else was lost,
--   - the new run passes within 0.6 m of where the point was moved to,
--   - nothing raised a Lua error.
--   lua splineedit.lua [N]          (from tools/junction-harness)
-- the terrain heights are needed (the laid points sit on the ground): as TERRAIN=1 would
local realGetenv = os.getenv
os.getenv = function(k) if k == "TERRAIN" then return realGetenv(k) or "1" end return realGetenv(k) end
local H = dofile("harness.lua")
local E = ADFlyoverEditor
g_server = g_server or {}
-- the game's default spacing (the harness answers 1 for settings it does not know)
local realGet = ADFlyoverSettings.get
ADFlyoverSettings.get = function(name) if name == "splineSpacing" then return 4 end return realGet(name) end
E.warnPlayer = function(_, m) print("  [warning box] " .. tostring(m)) end
E.cursorX, E.cursorZ, E.leftDown = nil, nil, false

local N = tonumber(arg[1]) or 12
local function nb(w)
    local t, seen = {}, {}
    for _, l in ipairs({ w.out or {}, w.incoming or {} }) do
        for _, id in ipairs(l) do if not seen[id] then seen[id] = true t[#t + 1] = id end end
    end
    return t
end
local function linksOf()
    local L = {}
    for _, w in ipairs(ADGraphManager:getWayPoints()) do
        local o, i = {}, {}
        for _, id in ipairs(w.out or {}) do o[ADGraphManager:getWayPointById(id)] = true end
        for _, id in ipairs(w.incoming or {}) do i[ADGraphManager:getWayPointById(id)] = true end
        L[w] = { out = o, inc = i }
    end
    return L
end
local function distToRun(run, x, z)
    local best = math.huge
    for i = 2, #run do
        local a, b = run[i - 1], run[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local l2 = dx * dx + dz * dz
        local t = l2 > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2)) or 0
        best = math.min(best, math.sqrt((x - a.x - dx * t) ^ 2 + (z - a.z - dz * t) ^ 2))
    end
    return best
end

-- the runs to try: seeds spread over the network, each run once
local tried, seeds = {}, {}
local all = ADGraphManager:getWayPoints()
for i = 1, #all, 37 do
    local w = all[i]
    if #seeds >= N then break end
    if w ~= nil and #nb(w) == 2 and not tried[w] then
        local run = E:orderedRunThrough(w.id)
        if run ~= nil and #run >= 8 then
            local len = 0
            for k = 2, #run do len = len + math.sqrt((run[k].x - run[k - 1].x) ^ 2 + (run[k].z - run[k - 1].z) ^ 2) end
            local fresh = true
            for _, q in ipairs(run) do if tried[ADGraphManager:getWayPointById(q.id)] then fresh = false end end
            if len >= 30 and fresh then
                for _, q in ipairs(run) do tried[ADGraphManager:getWayPointById(q.id)] = true end
                seeds[#seeds + 1] = ADGraphManager:getWayPointById(w.id)
            end
        end
    end
end

local pass, fail = 0, 0
for n, seedW in ipairs(seeds) do
    local seed = seedW.id
    local ok, err = pcall(function()
        E:cancelMultiSpline()
        E.splineEditMode = true
        local before = linksOf()
        assert(E:splineEditSelect(seed), "select refused")
        local e = E.splineEdit
        local A, B = ADGraphManager:getWayPointById(e.ids[1]), ADGraphManager:getWayPointById(e.ids[#e.ids])
        local inRun = {}
        for _, id in ipairs(e.ids) do inRun[ADGraphManager:getWayPointById(id)] = true end
        local pts = E.splinePoints
        if #pts < 3 then
            -- a straight run has only its two ends as points: put one in the middle, as a click on the line does
            local run = E:orderedRunThrough(seed)
            local m = run[math.floor(#run / 2) + 1]
            table.insert(pts, 2, { x = m.x, y = m.y, z = m.z })
        end
        local k = math.floor((#pts + 1) / 2)
        local a, b = pts[k - 1], pts[k + 1]
        local nx, nz = -(b.z - a.z), b.x - a.x
        local nl = math.sqrt(nx * nx + nz * nz)
        local tx, tz = pts[k].x + 2 * nx / nl, pts[k].z + 2 * nz / nl
        pts[k] = { x = tx, y = pts[k].y, z = tz }
        local nIds = #e.ids
        E:splineEditApply()
        assert(E.splineEdit == nil, "edit not cleared")
        -- the run from A again
        local run2 = E:orderedRunThrough(A.id)
        local last = run2[#run2]
        local endsOk = (run2[1].id == A.id and last.id == B.id) or (run2[1].id == B.id and last.id == A.id)
        local near = distToRun(run2, tx, tz)
        -- links lost outside the run
        local lost = 0
        for w, l in pairs(before) do
            if w.id > 0 and not inRun[w] or w == A or w == B then
                for o in pairs(l.out) do
                    if o.id > 0 and not inRun[o] then
                        local still = false
                        for _, id in ipairs(w.out or {}) do if id == o.id then still = true end end
                        if not still then lost = lost + 1 end
                    end
                end
            end
        end
        local good = endsOk and near < 0.6 and lost == 0
        print(string.format("run %2d: %d -> %d waypoints, ends %s, passes %.2f m from the moved point, %d link(s) lost: %s",
            n, nIds, #run2, endsOk and "kept" or "LOST", near, lost, good and "ok" or "FAIL"))
        if good then pass = pass + 1 else fail = fail + 1 end
    end)
    if not ok then
        fail = fail + 1
        print(string.format("run %2d: ERROR %s", n, tostring(err)))
    end
end
print(string.format("%d of %d runs edited cleanly", pass, pass + fail))
print((fail == 0 and pass > 0) and "SPLINE EDIT PASS" or "SPLINE EDIT FAIL")
