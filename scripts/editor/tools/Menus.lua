-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "linkList" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Menus.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local linkList = ADFlyoverEditor.shared.linkList
-- MODSPLIT: end of the helpers

-- ---------------------------------------------------------------------------------------------
-- Select mode (TOOL.NONE): click waypoints to act on them directly, without picking a tool first.
--
--   single click a point   -> a menu for that point
--   click a second point    -> a menu for the span between the two
--   double-click a point    -> a menu for the whole run through it
--
-- Menu actions reuse the tools' own graph paths: point actions by pointing hoverId at the clicked
-- waypoint; span actions by driving the span tool's from/to -> preview -> commit while that tool is
-- otherwise idle; run actions by the run-scoped versions. Right-click, an empty click, or leaving
-- Select mode closes the menu.
-- ---------------------------------------------------------------------------------------------

ADFlyoverEditor.DOUBLE_CLICK_MS = 350

function ADFlyoverEditor:closeMenu()
    self.ctxMenu = nil
end

function ADFlyoverEditor:openPointMenu(id, sx, sy)
    self.ctxMenu = { kind = "point", id = id, sx = sx, sy = sy }
end

function ADFlyoverEditor:openSpanMenu(fromId, toId, sx, sy)
    local ids = self:spanBetween(fromId, toId)
    if ids == nil or #ids < 2 then
        Logging.warning("[FlyoverEditor]: id=%s and id=%s are not two ends of one connected span.",
            tostring(fromId), tostring(toId))
        self.ctxMenu = { kind = "point", id = toId, sx = sx, sy = sy }
        return
    end
    self.ctxMenu = { kind = "span", fromId = fromId, toId = toId, ids = ids, sx = sx, sy = sy }
    ADFlyoverSettings.debugLog("[FlyoverEditor]: span menu for id=%s..id=%s (%d waypoints).",
        tostring(fromId), tostring(toId), #ids)
end

--- The selection popup: after a box / circle / freehand / rotated-box / Ctrl selection in Select mode,
--- the same kind of picker the point, span and run menus are, acting on the whole selection.
function ADFlyoverEditor:openSetMenu()
    if self.tool ~= self.TOOL.NONE or self.selectionCount == 0 then
        return
    end
    local sx, sy = g_lastMousePosX or 0.5, g_lastMousePosY or 0.5
    self.ctxMenu = { kind = "set", count = self.selectionCount, sx = sx, sy = sy }
end

--- "move" on a span or run menu: switch to Move with that span / run already picked, so the next drag on
--- any of its points moves the lot (falloff tapering to its ends when on).
function ADFlyoverEditor:menuArmMoveSpan()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, isRun = m.fromId, m.toId, m.ids, (m.kind == "run")
    self:setTool(self.TOOL.MOVE)
    local set = {}
    for _, id in ipairs(ids) do set[id] = true end
    self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = from, to, set
    -- Picked from the popup: the span / run moves as a whole, tapering to its own ends (no reach value).
    -- Move's own gesture picks use the falloff value as a reach instead - see moveReach.
    self.movePickFromMenu = true
    self.pickKind = isRun and "run" or "span"
    self.moveSelectMode = isRun and self.MOVE_SELECT.RUN or self.MOVE_SELECT.SPAN
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move armed on a %d-point %s; drag any of its points.", #ids, self.pickKind)
end

function ADFlyoverEditor:menuArmMoveSelection()
    -- Move keeps the selection: dragging any selected point moves the whole set.
    self:setTool(self.TOOL.MOVE)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move armed on the %d selected waypoint(s); drag any of them.", self.selectionCount)
end

function ADFlyoverEditor:menuDeleteSelection()
    self:deleteSelection()
    self:closeMenu()
end

function ADFlyoverEditor:menuClearSelection()
    self:clearSelection()
    self:closeMenu()
end

function ADFlyoverEditor:openRunMenu(seedId, sx, sy)
    local run, count = self:collectRunBetweenJunctions(seedId)
    -- fromId/toId/ids are the run's two ends and the ordered route between them, for the span-shaped
    -- actions (straighten, smooth). nil when the run has no clear two ends (a junction seed or a
    -- closed loop); those actions then simply have nothing to act on.
    local fromId, toId, ids = self:resolveWholeRun(seedId)
    self.ctxMenu = { kind = "run", seedId = seedId, count = count or 0, runSet = run,
        fromId = fromId, toId = toId, ids = ids, sx = sx, sy = sy }
    ADFlyoverSettings.debugLog("[FlyoverEditor]: run menu through id=%s (%d waypoints).", tostring(seedId), count or 0)
end

function ADFlyoverEditor:selectClick()
    local id = self.hoverId
    local sx, sy = g_lastMousePosX or 0.5, g_lastMousePosY or 0.5
    local now = self:nowMs()
    local isDouble = id ~= nil and self.lastSelectId == id
        and (now - (self.lastSelectAt or -1e9)) < self.DOUBLE_CLICK_MS
    self.lastSelectId, self.lastSelectAt = id, now

    if id == nil then
        self:closeMenu()
        return
    end
    if isDouble then
        self:openRunMenu(id, sx, sy)
        return
    end
    -- A point menu already open on a DIFFERENT point means this second click closes a span.
    if self.ctxMenu ~= nil and self.ctxMenu.kind == "point" and self.ctxMenu.id ~= id then
        self:openSpanMenu(self.ctxMenu.id, id, sx, sy)
        return
    end
    self:openPointMenu(id, sx, sy)
end

function ADFlyoverEditor:menuTarget()
    return self.ctxMenu ~= nil and self.ctxMenu.id or nil
end

function ADFlyoverEditor:menuName()
    local id = self:menuTarget()
    if id == nil then return end
    self.hoverId = id
    self:nameAtCursor()
    self:closeMenu()
end

--- Run convertAtCursor on the clicked point without disturbing the Convert tool's own sticky op/scope.
function ADFlyoverEditor:menuConvert(op)
    local id = self:menuTarget()
    if id == nil then return end
    local savedOp, savedScope = self.convertOp, self.convertScope
    self.hoverId = id
    self.convertScope = self.DELETE_SCOPE.POINT
    self.convertOp = op
    self:convertAtCursor()
    self.convertOp, self.convertScope = savedOp, savedScope
end

--- Delete the clicked point directly, so a stray box selection cannot hijack the click.
function ADFlyoverEditor:menuDelete()
    local id = self:menuTarget()
    if id == nil then return end
    ADEditorHistory:snapshot("delete waypoint")
    local doomed = ADGraphManager:getWayPointById(id)
    local px, pz = doomed ~= nil and doomed.x or 0, doomed ~= nil and doomed.z or 0
    ADGraphManager:removeWayPoint(id, false)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: (menu) deleted waypoint id=%s at x=%.1f z=%.1f (%d left).",
        tostring(id), px, pz, ADGraphManager:getWayPointsCount())
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    self:closeMenu()
end

--- Span actions borrow the matching span tool's from/to -> preview -> commit flow, then clear the
--- borrowed state. Safe because in Select mode that tool is idle and holds no span of its own.
function ADFlyoverEditor:menuStraighten()
    local m = self.ctxMenu
    if m == nil or m.ids == nil or m.fromId == nil or m.toId == nil then return end
    self.spanIds = m.ids
    self.straightenFromId, self.straightenToId, self.straightenPreview = m.fromId, m.toId, nil
    self:updateStraightenPreview()
    if self.straightenPreview ~= nil then
        self:commitStraighten()
    end
    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
    self.spanIds = nil
    self:closeMenu()
end

function ADFlyoverEditor:menuSmooth()
    local m = self.ctxMenu
    if m == nil or m.ids == nil or m.fromId == nil or m.toId == nil then return end
    self.spanIds = m.ids
    self.smoothFromId, self.smoothToId = m.fromId, m.toId
    self.smoothPreview, self.smoothPinned, self.smoothBlockedBy = nil, nil, nil
    self:updateSmoothPreview()
    if self.smoothPreview ~= nil then
        self:commitSmooth()
    end
    self.smoothFromId, self.smoothToId = nil, nil
    self.smoothPreview, self.smoothPinned, self.smoothBlockedBy = nil, nil, nil
    self.spanIds = nil
    self:closeMenu()
end

function ADFlyoverEditor:menuDeleteSpan()
    local m = self.ctxMenu
    if m == nil or m.ids == nil then return end
    ADEditorHistory:snapshot("delete span")
    local ids = {}
    for _, id in ipairs(m.ids) do ids[#ids + 1] = id end
    -- Highest id first: removal renumbers everything above it.
    table.sort(ids, function(a, b) return a > b end)
    for _, id in ipairs(ids) do ADGraphManager:removeWayPoint(id, false) end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: deleted a span of %d waypoint(s).", #ids)
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    self:closeMenu()
end

local function addLink(fromId, toId)
    local from = ADGraphManager:getWayPointById(fromId)
    local to = ADGraphManager:getWayPointById(toId)
    if from == nil or to == nil or fromId == toId then
        return
    end
    if not table.contains(from.out, toId) then
        table.insert(from.out, toId)
    end
    if not table.contains(to.incoming, fromId) then
        table.insert(to.incoming, fromId)
    end
end

local function removeLink(fromId, toId)
    local from = ADGraphManager:getWayPointById(fromId)
    local to = ADGraphManager:getWayPointById(toId)
    if from == nil or to == nil then
        return
    end
    table.removeValue(from.out, toId)
    table.removeValue(to.incoming, fromId)
end

--- Which way traffic runs past `cur`, seen walking away from `prev`: follow the road (through points
--- with exactly one onward link) until a one-way link answers. "out" = it runs away from `prev`, "in" =
--- toward it; nil when the road stays two-way or forks first.
function ADFlyoverEditor:roadFlowBeyond(prev, cur)
    for _ = 1, 50 do
        local cw = ADGraphManager:getWayPointById(cur)
        if cw == nil then return nil end
        local nextId, count = nil, 0
        for _, listName in ipairs(LINK_LISTS) do
            for _, x in pairs(linkList(cw, listName) or {}) do
                if x ~= prev and x ~= cur and x ~= nextId then
                    nextId = x
                    count = count + 1
                end
            end
        end
        if count ~= 1 then return nil end
        local xw = ADGraphManager:getWayPointById(nextId)
        local away = table.contains(cw.out, nextId)
        local toward = xw ~= nil and table.contains(xw.out, cur)
        if away and not toward then return "out" end
        if toward and not away then return "in" end
        prev, cur = cur, nextId
    end
    return nil
end

--- Span direction: apply two-way / one-way / flip along the span's own ordered pairs. convertAtCursor
--- only offers point and whole-run scope, so the span case is done here, mirroring its link logic.
--- Kept open so directions can be tried in a row.
function ADFlyoverEditor:menuConvertSpan(op)
    local m = self.ctxMenu
    if m == nil or m.ids == nil or #m.ids < 2 then return end
    local ordered = m.ids
    local changed = 0
    if op == self.CONVERT_OP.PRIMARY or op == self.CONVERT_OP.SECONDARY then
        ADEditorHistory:snapshot("convert span priority")
        -- only the priority bit: AutoDrive's own marks (map road, field point) stay
        for _, id in ipairs(ordered) do
            local wp = ADGraphManager:getWayPointById(id)
            ADGraphManager:setWayPointFlags(id, ADFlyoverEditor.withPriority(wp and wp.flags, op == self.CONVERT_OP.SECONDARY), false)
            changed = changed + 1
        end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: span priority -> %s, %d point(s).",
            self.CONVERT_OP_NAMES[op] or "?", changed)
        ADGraphManager:markChanges()
        return
    end
    ADEditorHistory:snapshot("convert span direction")
    -- One-way runs the way the road does beyond the span's ends; failing that, the way most of the
    -- span's own one-way links already run; failing that, the order it was picked in.
    if op == self.CONVERT_OP.ONEWAY then
        local n = #ordered
        local vote = 0
        local after = self:roadFlowBeyond(ordered[n - 1], ordered[n])
        local before = self:roadFlowBeyond(ordered[2], ordered[1])
        if after == "out" then vote = vote + 1 elseif after == "in" then vote = vote - 1 end
        if before == "in" then vote = vote + 1 elseif before == "out" then vote = vote - 1 end
        if vote == 0 then
            for i = 1, n - 1 do
                local aw = ADGraphManager:getWayPointById(ordered[i])
                local bw = ADGraphManager:getWayPointById(ordered[i + 1])
                if aw ~= nil and bw ~= nil then
                    local f = table.contains(aw.out, ordered[i + 1])
                    local b = table.contains(bw.out, ordered[i])
                    if f and not b then vote = vote + 1 elseif b and not f then vote = vote - 1 end
                end
            end
        end
        if vote < 0 then
            local rev = {}
            for i = n, 1, -1 do rev[#rev + 1] = ordered[i] end
            ordered = rev
        end
    end
    for i = 1, #ordered - 1 do
        local a, b = ordered[i], ordered[i + 1]
        local aw = ADGraphManager:getWayPointById(a)
        local bw = ADGraphManager:getWayPointById(b)
        if aw ~= nil and bw ~= nil then
            local forward = table.contains(aw.out, b)
            local backward = table.contains(bw.out, a)
            if op == self.CONVERT_OP.TWOWAY then
                if not (forward and backward) then
                    addLink(a, b); addLink(b, a); changed = changed + 1
                end
            elseif op == self.CONVERT_OP.ONEWAY then
                if forward and backward then
                    removeLink(b, a); changed = changed + 1
                elseif not forward and backward then
                    removeLink(b, a); addLink(a, b); changed = changed + 1
                elseif not forward and not backward then
                    addLink(a, b); changed = changed + 1
                end
            elseif op == self.CONVERT_OP.REVERSE then
                if forward ~= backward then
                    if forward then removeLink(a, b); addLink(b, a)
                    else removeLink(b, a); addLink(a, b) end
                    changed = changed + 1
                end
            end
        end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: span direction -> %s, %d link(s) changed.",
        self.CONVERT_OP_NAMES[op] or "?", changed)
    ADGraphManager:markChanges()
end

--- What a popup's targets are now, so its buttons can offer the opposite. Direction looks at the links
--- among them (for a lone point: every link at it) and answers "two", "one" or "mixed"; priority looks at
--- the points and answers "primary", "secondary" or "mixed". nil = nothing to judge (no links / no points).
--- `ids` is a list or a set.
function ADFlyoverEditor:menuConvertState(ids)
    local set = {}
    for k, v in pairs(ids or {}) do
        if v == true then set[k] = true else set[v] = true end
    end
    local lone = next(set) ~= nil and next(set, next(set)) == nil
    local nTwo, nOne, nSub, nPrim = 0, 0, 0, 0
    for a in pairs(set) do
        local aw = ADGraphManager:getWayPointById(a)
        if aw ~= nil then
            local flags = aw.flags or 0
            if math.floor(flags / AutoDrive.FLAG_SUBPRIO) % 2 == 1 then nSub = nSub + 1 else nPrim = nPrim + 1 end
            for _, listName in ipairs(LINK_LISTS) do
                for _, b in pairs(linkList(aw, listName) or {}) do
                    if b ~= a and (lone or set[b]) then
                        local bw = ADGraphManager:getWayPointById(b)
                        if table.contains(aw.out, b) and bw ~= nil and table.contains(bw.out, a) then
                            nTwo = nTwo + 1
                        else
                            nOne = nOne + 1
                        end
                    end
                end
            end
        end
    end
    local function verdict(a, b, nameA, nameB)
        if a > 0 and b > 0 then return "mixed" end
        if a > 0 then return nameA end
        if b > 0 then return nameB end
        return nil
    end
    return verdict(nTwo, nOne, "two", "one"), verdict(nPrim, nSub, "primary", "secondary")
end

--- Run direction, via the run-scoped convert; kept open so directions can be tried in a row.
function ADFlyoverEditor:menuConvertRun(op)
    local m = self.ctxMenu
    if m == nil or m.seedId == nil then return end
    local savedOp, savedScope = self.convertOp, self.convertScope
    self.hoverId = m.seedId
    self.convertScope = self.DELETE_SCOPE.RUN
    self.convertOp = op
    self:convertAtCursor()
    self.convertOp, self.convertScope = savedOp, savedScope
end

function ADFlyoverEditor:menuDeleteRun()
    local m = self.ctxMenu
    if m == nil or m.seedId == nil then return end
    self.hoverId = m.seedId
    self:deleteRunAtCursor()
    self:closeMenu()
end

--- Arm a tool from a point menu: switch to it with the clicked point pre-loaded as the start, then
--- let the tool's own interaction finish the job (a drag, a click, the wheel). setTool clears the
--- menu and any stale tool state, so the pre-load is set AFTER it.
function ADFlyoverEditor:menuArmMove()
    local id = self:menuTarget()
    if id == nil then return end
    self:setTool(self.TOOL.MOVE)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move armed; drag waypoint id=%s.", tostring(id))
end

function ADFlyoverEditor:menuArmDraw()
    local id = self:menuTarget()
    if id == nil then return end
    self:setTool(self.TOOL.DRAW)
    self.lastWaypointId = id
    ADFlyoverSettings.debugLog("[FlyoverEditor]: draw armed from id=%s; click the next waypoint to connect.", tostring(id))
end

function ADFlyoverEditor:menuArmSpline()
    local id = self:menuTarget()
    if id == nil then return end
    self:setTool(self.TOOL.SPLINE)
    if self:splineIsMultiPoint() then
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            self:multiSplineAdd({ x = wp.x, y = wp.y, z = wp.z, wpId = wp.id })
        end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: spline armed from id=%s; click on to add points.", tostring(id))
        return
    end
    self.splineFromId = id
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline armed from id=%s; click the waypoint to curve to.", tostring(id))
end

--- Span/run arming for the adjustable span tools: switch to the tool with the span (or run)
--- pre-loaded as its from/to, then keep a compact "armed" popup in place of the action list, so the
--- tool's wheel setting and toggles are adjusted right there. Scroll changes the value; apply (or a
--- right-click) commits and returns to Select. m.fromId/toId/ids are the ends and route (spans always
--- have them; runs only when they have two clear ends).
function ADFlyoverEditor:setArmedMenu(sx, sy)
    self.ctxMenu = { kind = "armed", tool = self.tool, sx = sx or 0.5, sy = sy or 0.5 }
end

function ADFlyoverEditor:menuArmStraighten()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, sx, sy = m.fromId, m.toId, m.ids, m.sx, m.sy
    self:setTool(self.TOOL.STRAIGHTEN)
    self.spanIds = ids
    self.pickKind = (m.kind == "run") and "run" or "span"   -- what the picker menu handed over, for the card's indicator
    self.straightenFromId, self.straightenToId, self.straightenPreview = from, to, nil
    self:setArmedMenu(sx, sy)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: straighten armed on a %d-point span.", #ids)
end

function ADFlyoverEditor:menuArmSmooth()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, sx, sy = m.fromId, m.toId, m.ids, m.sx, m.sy
    self:setTool(self.TOOL.SMOOTH)
    self.spanIds = ids
    self.pickKind = (m.kind == "run") and "run" or "span"   -- what the picker menu handed over, for the card's indicator
    self.smoothFromId, self.smoothToId = from, to
    self.smoothPreview, self.smoothPinned, self.smoothBlockedBy = nil, nil, nil
    self:setArmedMenu(sx, sy)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: smooth armed on a %d-point span.", #ids)
end

function ADFlyoverEditor:menuArmDivide()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, sx, sy = m.fromId, m.toId, m.ids, m.sx, m.sy
    self:setTool(self.TOOL.DIVIDE)
    self.spanIds = ids
    self.pickKind = (m.kind == "run") and "run" or "span"   -- what the picker menu handed over, for the card's indicator
    self.divideFromId, self.divideToId = from, to
    self.dividePreview = nil
    self.divideCount = math.max(0, #ids - 2)
    self:setArmedMenu(sx, sy)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: divide armed on a %d-point span.", #ids)
end

function ADFlyoverEditor:menuArmGround()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, isRun, sx, sy = m.fromId, m.toId, m.ids, (m.kind == "run"), m.sx, m.sy
    self:setTool(self.TOOL.GROUND)
    self.offsetScope = isRun and self.OFFSET_SCOPE.RUN or self.OFFSET_SCOPE.SPAN
    self.spanIds = ids
    self.pickKind = (m.kind == "run") and "run" or "span"   -- what the picker menu handed over, for the card's indicator
    self.groundFromId, self.groundToId = from, to
    self.groundPreview = nil
    self.groundTolerance = AutoDrive.FLYOVER_GROUND_DEFAULT
    self:setArmedMenu(sx, sy)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: ground armed on a %d-point span.", #ids)
end

function ADFlyoverEditor:menuArmParallel()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, isRun, sx, sy = m.fromId, m.toId, m.ids, (m.kind == "run"), m.sx, m.sy
    self:setTool(self.TOOL.PARALLEL)
    self.offsetScope = isRun and self.OFFSET_SCOPE.RUN or self.OFFSET_SCOPE.SPAN
    self.spanIds = ids
    self.pickKind = (m.kind == "run") and "run" or "span"
    self.offsetFromId, self.offsetToId = from, to
    self.offsetPreview, self.offsetCache = nil, nil
    local seedPts = self:offsetSpanPoints()
    if seedPts ~= nil then
        self:pickSideFromCursor(seedPts)
    end
    self:setArmedMenu(sx, sy)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: parallel armed on a %d-point span.", #ids)
end

--- Apply the armed tool's pending action and return to Select mode. Same commit the tool's own
--- right-click uses; the preview it needs is rebuilt every frame by update() while the tool is active.
function ADFlyoverEditor:menuApplyArmed()
    local t = self.tool
    if t == self.TOOL.SMOOTH then self:commitSmooth()
    elseif t == self.TOOL.STRAIGHTEN then self:commitStraighten()
    elseif t == self.TOOL.DIVIDE then self:commitDivide()
    elseif t == self.TOOL.GROUND then self:commitGround()
    elseif t == self.TOOL.PARALLEL then self:commitOffset()
    end
    self:setTool(self.TOOL.NONE)
end

function ADFlyoverEditor:menuCancelArmed()
    self:setTool(self.TOOL.NONE)
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared.addLink = addLink
ADFlyoverEditor.shared.removeLink = removeLink
-- MODSPLIT: end of the shared block
