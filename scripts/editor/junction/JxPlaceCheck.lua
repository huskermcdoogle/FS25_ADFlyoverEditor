-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "junctionPlacePattern", "junctionRouteCheck", "junctionShareCrossings", "junctionTieTidy", "jxBuildBegin", "jxBuildEnd", "jxState", "jxpUnit", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: JxPlaceCheck.lua needs %s, which no file loaded before it shares", name)
    end
end
local junctionPlacePattern = ADFlyoverEditor.shared.junctionPlacePattern
local junctionRouteCheck = ADFlyoverEditor.shared.junctionRouteCheck
local junctionShareCrossings = ADFlyoverEditor.shared.junctionShareCrossings
local junctionTieTidy = ADFlyoverEditor.shared.junctionTieTidy
local jxBuildBegin = ADFlyoverEditor.shared.jxBuildBegin
local jxBuildEnd = ADFlyoverEditor.shared.jxBuildEnd
local jxState = ADFlyoverEditor.shared.jxState
local jxpUnit = ADFlyoverEditor.shared.jxpUnit
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

-- THE ROUTE CHECK FOR A PLACED PIECE (doc 08 step 4). The build's check (junctionRouteCheck) wants the
-- junction's lanes in and out and the turns meant; place works those out from the piece itself:
--   * lanes in and out: every lane crossing a circle three lane gaps out from the piece's centre;
--   * roads: those lanes grouped by their direction from the centre (in and out of one road sit
--     side by side);
--   * meant: every lane in to every lane out on another road - no U-turns.
-- Then the same check: routes AutoDrive could drive that we didn't mean, and meant turns it can't.
local function junctionPlaceRouteCheck(res)
    local cx, cz = res.ox, res.oz
    local Rc = math.max(12, 3 * (res.L or 4))
    local aps, seen = {}, {}
    local ldx, ldz = 0, 0
    local function add(w, dir)
        local k = tostring(w) .. dir
        if seen[k] then return end
        seen[k] = true
        aps[#aps + 1] = { wp = w, dir = dir, bearing = math.atan2(w.x - cx, w.z - cz), dx = ldx, dz = ldz }
    end
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if a ~= nil and a.id ~= nil then
            local ain = (a.x - cx) ^ 2 + (a.z - cz) ^ 2 <= Rc * Rc
            for _, bid in ipairs(a.out or {}) do
                local b = ADGraphManager:getWayPointById(bid)
                if b ~= nil then
                    local bin = (b.x - cx) ^ 2 + (b.z - cz) ^ 2 <= Rc * Rc
                    if ain ~= bin then ldx, ldz = jxpUnit(b.x - a.x, b.z - a.z) end
                    if not ain and bin then add(a, "in") elseif ain and not bin then add(b, "out") end
                end
            end
        end
    end
    if #aps == 0 then return nil end
    -- Roads: two approaches are one road's two lanes when they run parallel (either way), sit side by side
    -- (within 1.6 lane gaps across) and on the same side of the centre. Not by direction from the centre
    -- alone: a side road meeting far off square (j7, 47 degrees) comes in right beside the main road's arm.
    local road, L0 = {}, res.L or 4
    local function find(i) while road[i] ~= i do i = road[i] end return i end
    for i = 1, #aps do road[i] = i end
    for i = 1, #aps do
        for j = i + 1, #aps do
            local a, b = aps[i], aps[j]
            local par = math.abs(a.dx * b.dx + a.dz * b.dz) > 0.94
            local across = math.abs((b.wp.x - a.wp.x) * a.dz - (b.wp.z - a.wp.z) * a.dx)
            local gap = math.abs(a.bearing - b.bearing)
            if gap > math.pi then gap = 2 * math.pi - gap end
            if par and across < 1.6 * L0 and gap < math.rad(60) then road[find(i)] = find(j) end
        end
    end
    local roots, arm = {}, 0
    for i = 1, #aps do
        local r = find(i)
        if roots[r] == nil then arm = arm + 1 roots[r] = arm end
        road[i] = roots[r]
    end    local moves, placedSet = {}, {}
    for i, a in ipairs(aps) do
        if a.dir == "in" then
            for j, b in ipairs(aps) do
                if b.dir == "out" and road[i] ~= road[j] then
                    local m = { from = { wp = a.wp }, to = { wp = b.wp }, exists = false }
                    moves[#moves + 1] = m
                    placedSet[m] = true
                end
            end
        end
    end
    local rc = junctionRouteCheck({ approaches = aps, movements = moves }, placedSet, cx, cz, Rc)
    if rc == nil then return nil end
    rc.roads, rc.meant = math.max(arm, 1), #moves
    -- A ROAD NO ROUTE REACHES AT ALL isn't part of this piece: a lane of something else crossing the
    -- circle (j34), or a plain piece's arm left loose. Its turns are counted apart as "not joined" instead
    -- of as turns that can't be driven.
    local roadOf = {}
    for i, a in ipairs(aps) do roadOf[tostring(a.wp) .. a.dir] = road[i] end
    local meantBy, missBy = {}, {}
    for _, m in ipairs(moves) do
        for _, r in ipairs({ roadOf[tostring(m.from.wp) .. "in"], roadOf[tostring(m.to.wp) .. "out"] }) do
            meantBy[r] = (meantBy[r] or 0) + 1
        end
    end
    for _, e in ipairs(rc.missing or {}) do
        for _, r in ipairs({ roadOf[tostring(e.from) .. "in"], roadOf[tostring(e.to) .. "out"] }) do
            missBy[r] = (missBy[r] or 0) + 1
        end
    end
    local unjoined = {}
    for r, n in pairs(meantBy) do if (missBy[r] or 0) >= n then unjoined[r] = true end end
    local kept, nUn = {}, 0
    for _ in pairs(unjoined) do nUn = nUn + 1 end
    for _, e in ipairs(rc.missing or {}) do
        if not unjoined[roadOf[tostring(e.from) .. "in"]] and not unjoined[roadOf[tostring(e.to) .. "out"]] then
            kept[#kept + 1] = e
        end
    end
    rc.missing, rc.unjoined = kept, nUn
    return rc
end

--- Place mode's right-click: lay the X or T the preview worked out, under one undo.
function ADFlyoverEditor:applyJunctionPlace()
    local jp = self.junctionPreview
    if jp == nil or not jp.ok then return end
    local cap = self:debugCaptureBegin("place", { x = jp.cx, z = jp.cz }, {
        string.format("shape                %s", tostring(jp.shape)),
    })
    ADEditorHistory:snapshot("place junction")
    jxBuildBegin()
    local okCall, res, why = tryCall("junction place", function()
        return junctionPlacePattern(jp.cx, jp.cz, 15, jp.shape)
    end)
    local placed = okCall and res ~= nil
    -- Smooth curves cross the lanes and each other between the pattern's own points: each crossing gets
    -- its shared point, as everywhere else.
    local shared = 0
    -- (Not the plain piece: it is the mod's own shape, its shared points already in it, and it may sit
    -- over roads it does not fit, which it must not be joined to.)
    if placed and res.shape ~= "plain" and AutoDrive.FLYOVER_JUNCTION_SHARE_CROSSINGS ~= false then
        tryCall("junction share crossings", function() shared = junctionShareCrossings(jp.cx, jp.cz, 15) end)
    end
    -- ...and the old lane points left right beside the pattern's ties taken out (doc 09).
    if placed and res.shape ~= "plain" and AutoDrive.FLYOVER_JUNCTION_TIE_TIDY ~= false then
        local tidied = 0
        tryCall("junction tie tidy", function() tidied = junctionTieTidy(jp.cx, jp.cz, 15) end)
        if tidied > 0 then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d old lane point(s) right beside a new tie taken out, so AutoDrive sees further ahead.", tidied)
        end
    end
    if placed then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction placed: %s %s, lane gap %.1f m, %d turn piece(s), %d shared crossing point(s), %d loose end(s).",
            res.shape == "exact" and "mod" or res.shape, res.kind, res.L, res.turns, shared, #(res.loose or {}))
        if res.fitWhy ~= nil then
            ADFlyoverSettings.debugLog("[FlyoverEditor]:   placed plain because it does not fit: %s.", tostring(res.fitWhy))
        end
    else
        Logging.warning("[FlyoverEditor]: junction place failed: %s", tostring(why or "see above"))
    end
    -- THE ROUTE CHECK on the piece as laid (report only: never refused, doc 08).
    local rc = nil
    if placed then
        tryCall("junction place route check", function() rc = junctionPlaceRouteCheck(res) end)
    end
    local routeCard = nil
    if placed then
        if rc == nil then
            routeCard = { "Route check: could not run - see the log" }
        elseif #rc.extra == 0 and #(rc.missing or {}) == 0 then
            routeCard = { string.format("Route check: all %d routes as meant", rc.routes) }
            if (rc.unjoined or 0) > 0 then routeCard[#routeCard + 1] = string.format("%d road(s) nearby not joined to it", rc.unjoined) end
        else
            routeCard = {}
            if #rc.extra > 0 then routeCard[#routeCard + 1] = string.format("Route check: %d route(s) we did not lay", #rc.extra) end
            if #(rc.missing or {}) > 0 then routeCard[#routeCard + 1] = string.format("Route check: %d turn(s) cannot be driven", #rc.missing) end
            if (rc.unjoined or 0) > 0 then routeCard[#routeCard + 1] = string.format("%d road(s) nearby not joined to it", rc.unjoined) end
            routeCard[#routeCard + 1] = "see the log for where"
        end
        if rc ~= nil then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: junction place route check - %d road(s), %d turn(s) meant, %d route(s) found, %d extra, %d cannot be driven, %d road(s) not joined.",
                rc.roads or 0, rc.meant or 0, rc.routes, #rc.extra, #(rc.missing or {}), rc.unjoined or 0)
            for _, e in ipairs(rc.extra) do
                Logging.warning("[FlyoverEditor]:   route we did not lay: from the lane in at %.1f, %.1f to the lane out at %.1f, %.1f.",
                    e.from.x, e.from.z, e.to.x, e.to.z)
            end
            for _, e in ipairs(rc.missing or {}) do
                Logging.warning("[FlyoverEditor]:   turn that cannot be driven: from the lane in at %.1f, %.1f to the lane out at %.1f, %.1f.",
                    e.from.x, e.from.z, e.to.x, e.to.z)
            end
        end
    end
    self.junctionLastPlace = { ok = placed, kind = placed and res.kind or nil, shape = placed and res.shape or nil,
        routeCard = routeCard, extra = rc and #rc.extra or nil, missing = rc and #(rc.missing or {}) or nil, routes = rc and rc.routes or nil,
        unjoined = rc and rc.unjoined or nil,
        turns = placed and res.turns or 0, shared = shared, why = (not placed) and tostring(why) or nil,
        loose = placed and #(res.loose or {}) or 0, fitWhy = placed and res.fitWhy or nil,
        x = jp.cx, z = jp.cz }
    self.junctionLastLinkLabels = jxState.jxLinkLabel
    self.junctionLastNodeLabels = jxState.jxNodeLabel
    jxBuildEnd()
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    self:debugCaptureEnd(cap)
    self.junctionArmed, self.junctionPreview, self.junctionPreviewKey = nil, nil, nil
end
