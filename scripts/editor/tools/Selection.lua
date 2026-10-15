-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "linkList" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Selection.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local linkList = ADFlyoverEditor.shared.linkList
-- MODSPLIT: end of the helpers

function ADFlyoverEditor:setTool(tool)
    if self.tool == tool then
        return
    end
    -- A tool picked from a selection menu opens its card where that menu was, so the eyes do not have
    -- to move. Held until the player drags the card or the tool changes; never saved.
    local pickedFrom = self.ctxMenu
    if tool ~= self.TOOL.NONE and pickedFrom ~= nil and pickedFrom.placeX ~= nil then
        self.cardSpawnX, self.cardSpawnY = pickedFrom.placeX, pickedFrom.placeTop
        self.cardSpawnCX, self.cardSpawnCY = pickedFrom.sx, pickedFrom.sy
        self.cardSpawnPointId = pickedFrom.id   -- a point menu's own point (move has no other record of it)
        -- The HUD works out the card's real spot once per pick (the card is much taller than the menu).
        self.cardSpawnToken = (self.cardSpawnToken or 0) + 1
    else
        self.cardSpawnX, self.cardSpawnY = nil, nil
    end
    -- Remember the picker the tool came from, so Esc can step BACK to it (one level) instead of
    -- dropping all the way to plain Select.
    if tool ~= self.TOOL.NONE and pickedFrom ~= nil and pickedFrom.kind ~= "armed" then
        self.menuBackTo = pickedFrom
    else
        self.menuBackTo = nil
    end
    -- Leaving road runs drops what it has not built (picks, shaped runs).
    if self.tool == self.TOOL.ROADRUNS and self.roadRunsForget ~= nil then
        self:roadRunsForget("left the tool")
    end
    self.roadRunsBroken = nil             -- an error in road runs lasts until the tool is next chosen
    self.tool = tool
    self.lastMovedIds = nil
    self.movePickFromMenu = false
    self.pickFilter, self.pickKind, self.lastPickId = nil, nil, nil
    -- Any half-finished interaction belongs to the tool being left, not the one being entered.
    if self.editing ~= nil then
        self:cancelEditNumber()
    end
    -- Both ends, and the preview with them. Clearing only the start left a stale end behind, so
    -- the next first click fell through to the "re-pick the far end" branch instead of starting a
    -- fresh span - silently, which reads exactly like being unable to select the second point.
    self.smoothFromId, self.smoothToId = nil, nil
    self.smoothPreview, self.smoothPinned, self.smoothBlockedBy = nil, nil, nil
    if self.splineFromId ~= nil or self.splineToId ~= nil then
        self:cancelSplinePreview()
    end
    self:cancelMultiSpline()
    self.mergeFromId = nil
    self.mergeToId = nil
    self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = nil, nil, nil
    self.divideFromId, self.divideToId, self.dividePreview = nil, nil, nil
    self.junctionArmed, self.junctionPreview, self.junctionPreviewKey = nil, nil, nil
    -- road runs keeps its window of read ground (reading it again is the slow part); only the picks go
    if self.roadRunsReset ~= nil then
        self:roadRunsReset()
    end
    self.dragId = nil
    self.boxActive = false
    self.circleActive = false
    self.circleStartX, self.circleStartZ = nil, nil
    self.freehandActive = false
    self.freehandPoints = nil
    self.ctrlToggleArmed = false
    self.rotBoxActive, self.rotBoxDragging = false, false
    self.rotBoxP1X, self.rotBoxP1Z, self.rotBoxP2X, self.rotBoxP2Z = nil, nil, nil, nil
    self.moveCopyOn = false
    self.moveBreakOn = false
    self.lastMoveRecord = nil
    -- Abandons a pending offset rather than committing it - switching tools mid-adjustment is not
    -- the deliberate right-click this feature otherwise requires to commit.
    self.moveOffsetOn = false
    self:cancelMoveOffset()
    self.ctxMenu = nil
    -- A dragged card stays dragged ACROSS tool switches now, not per tool: field reports kept saying
    -- the card was in the way, and re-jumping it on every tool change undid the player's own
    -- placement. Once you put it somewhere, it stays there for the whole editor session; the
    -- jump-out-beside-the-click only serves players who never placed it themselves.
    self.moveFocusId = nil
    -- Picking a tool always brings its card back: middle-click hides the CURRENT tool's card to work
    -- under it, but switching tools should not carry that hidden state onto the next one.
    self.cardHidden = false
    -- The junction turn radius is saved with the settings but was never read back: it started at
    -- 12 m every session, whatever was saved. Read once, the first time the junction tool opens.
    if tool == self.TOOL.JUNCTION and not self.junctionTurnRadiusLoaded and ADFlyoverSettings ~= nil then
        self.junctionTurnRadiusLoaded = true
        local saved = ADFlyoverSettings.get("junctionTurnRadius")
        if type(saved) == "number" then self.junctionTurnRadius = saved end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: tool -> %s", self.TOOL_NAMES[tool] or "none")
end

function ADFlyoverEditor:clearSelection()
    self.selection = {}
    self.selectionCount = 0
end

--- Chain tools (Smooth, Straighten, Divide, Parallel, Merge) work along an ordered path, so a Ctrl-built
--- selection there has to stay ONE contiguous run: every point joined to the rest, no branches.
function ADFlyoverEditor:toolNeedsChainSelection()
    local t, T = self.tool, self.TOOL
    return t == T.SMOOTH or t == T.STRAIGHTEN or t == T.DIVIDE or t == T.PARALLEL or t == T.MERGE
end

--- The set, ordered end to end, if it is one simple chain (connected, no point joined to more than two
--- others in the set); nil otherwise. A single point is a chain of one.
function ADFlyoverEditor:orderedChain(set)
    local ids, n = {}, 0
    for id in pairs(set) do n = n + 1; ids[n] = id end
    if n == 0 then return nil end
    if n == 1 then return { ids[1] } end
    local nb = {}
    for _, id in ipairs(ids) do
        local wp = ADGraphManager:getWayPointById(id)
        local seen, list = {}, {}
        if wp ~= nil then
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
                    if set[other] and other ~= id and not seen[other] then
                        seen[other] = true
                        list[#list + 1] = other
                    end
                end
            end
        end
        if #list > 2 then return nil end   -- a branch
        nb[id] = list
    end
    local startId = nil
    for _, id in ipairs(ids) do
        if #nb[id] == 1 then startId = id break end
        if #nb[id] == 0 then return nil end   -- an island
    end
    if startId == nil then return nil end    -- a closed loop has no ends
    local order, prev, cur = { startId }, nil, startId
    while true do
        local nextId = nil
        for _, o in ipairs(nb[cur]) do
            if o ~= prev then nextId = o break end
        end
        if nextId == nil then break end
        order[#order + 1] = nextId
        prev, cur = cur, nextId
        if #order > n then return nil end
    end
    if #order ~= n then return nil end         -- not all connected
    return order
end

--- The selection ordered end to end when it is one connected run (orderedChain), else nil. Cached until
--- the selection changes, since the Move card asks every frame.
function ADFlyoverEditor:selectionChain()
    if self.selectionCount == 0 then
        return nil
    end
    local sum = 0
    for id in pairs(self.selection) do sum = sum + id end
    local key = self.selectionCount .. ":" .. sum
    if self.selectionChainKey ~= key then
        self.selectionChainKey = key
        self.selectionChainCache = self:orderedChain(self.selection) or false
    end
    return self.selectionChainCache or nil
end

--- Hand a chain (ordered ids) to the active chain tool as its span, exactly as a picked span would be.
function ADFlyoverEditor:setToolSpanFromChain(order)
    local ordered = self:trafficOrder(order)
    local a, b = ordered[1], ordered[#ordered]
    local t, T = self.tool, self.TOOL
    self.spanIds = ordered
    if t == T.SMOOTH then
        self.smoothFromId, self.smoothToId = a, b
        self.smoothPreview, self.smoothPinned = nil, nil
    elseif t == T.STRAIGHTEN then
        self.straightenFromId, self.straightenToId, self.straightenPreview = a, b, nil
    elseif t == T.DIVIDE then
        self.divideFromId, self.divideToId, self.dividePreview = a, b, nil
        self.divideCount = math.max(0, #ordered - 2)
    elseif t == T.PARALLEL then
        self.offsetFromId, self.offsetToId = a, b
        self.offsetPreview, self.offsetCache = nil, nil
        local seedPts = self:offsetSpanPoints()
        if seedPts ~= nil then self:pickSideFromCursor(seedPts) end
    elseif t == T.MERGE then
        self.mergeFromId, self.mergeToId = a, b
        self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
    end
    self.pickKind = "set"
end

--- Ctrl-click in a chain tool: add or remove the point only if the selection stays one contiguous run,
--- then use it as the tool's span. Returns true when it handled the click (added, removed or refused).
function ADFlyoverEditor:chainToggleSelected(id)
    if id == nil or not self:toolNeedsChainSelection() then
        return false
    end
    local trial = {}
    for sid in pairs(self.selection) do trial[sid] = true end
    if trial[id] then trial[id] = nil else trial[id] = true end
    -- Not `next(trial) ~= nil and self:orderedChain(trial) or {}`: a nil from orderedChain ("not one
    -- run") turned into {} there, so every click was accepted and disconnected points got through.
    local order = {}
    if next(trial) ~= nil then
        order = self:orderedChain(trial)
    end
    if order == nil then
        self:warnPlayer("That would break the selection in two - for this tool a Ctrl selection has to be one connected run.")
        return true
    end
    self:toggleSelected(id)
    if #order >= 2 then
        self:setToolSpanFromChain(order)
    else
        -- One point (or none) is not a span yet: clear any span the selection had set.
        local t, T = self.tool, self.TOOL
        self.spanIds = nil
        if t == T.SMOOTH then self.smoothFromId, self.smoothToId = nil, nil
        elseif t == T.STRAIGHTEN then self.straightenFromId, self.straightenToId = nil, nil
        elseif t == T.DIVIDE then self.divideFromId, self.divideToId = nil, nil
        elseif t == T.PARALLEL then self.offsetFromId, self.offsetToId = nil, nil
        elseif t == T.MERGE then self.mergeFromId, self.mergeToId = nil, nil
        end
    end
    local listed = {}
    for i, cid in ipairs(order) do listed[i] = tostring(cid) end
    local fromId, toId = self:pickedSpanEnds()
    ADFlyoverSettings.debugLog("[FlyoverEditor]: chain selection now %d waypoint(s): clicked id=%s, chain %s, span id=%s to id=%s.",
        self.selectionCount, tostring(id), table.concat(listed, " -> "), tostring(fromId), tostring(toId))
    return true
end

function ADFlyoverEditor:toggleSelected(id)
    if id == nil then
        return
    end
    if self.selection[id] then
        self.selection[id] = nil
        self.selectionCount = self.selectionCount - 1
    else
        self.selection[id] = true
        self.selectionCount = self.selectionCount + 1
    end
end

--- Finish a Ctrl+drag. A drag too small to be a deliberate box is treated as a plain Ctrl+click
--- on the hovered waypoint, so the two gestures share one modifier without the click becoming a
--- one-waypoint box that depends on the hand being perfectly still.
--- The camera's forward direction projected onto the ground plane, normalized. The same lookup
--- MapMarker's own aimOf() uses to point the minimap airplane icon (duplicated here in miniature
--- rather than exported - a couple of lines, and this file already owns self.camera). Falls back
--- to world +Z - the box's old, always-axis-aligned behaviour - if the camera cannot report it, so
--- a lookup failure degrades gracefully instead of breaking selection outright.
function ADFlyoverEditor:cameraForwardXZ()
    local camera = self.camera
    local node = camera ~= nil and (camera.camera or camera.cameraBaseNode) or nil
    if node ~= nil and localDirectionToWorld ~= nil then
        local ok, dx, _, dz = pcall(localDirectionToWorld, node, 0, 0, -1)
        if ok and dx ~= nil and (dx * dx + dz * dz) > 1e-6 then
            local len = math.sqrt(dx * dx + dz * dz)
            return dx / len, dz / len
        end
    end
    return 0, 1
end

--- Turn two clicked corners into a rectangle ALIGNED WITH THE CURRENT VIEW rather than world X/Z -
--- orbiting the camera and then boxing something that now runs across the screen should not need
--- an L-shaped drag to avoid sweeping up everything beside it. One basis (rx/rz = right, fx/fz =
--- forward) shared by the live preview and the actual hit test below, so the box never selects
--- something the preview did not show.
function ADFlyoverEditor:boxFrame(x0, z0, x1, z1)
    local fx, fz = self:cameraForwardXZ()
    local rx, rz = -fz, fx

    local u1 = (x1 - x0) * rx + (z1 - z0) * rz
    local v1 = (x1 - x0) * fx + (z1 - z0) * fz
    local minU, maxU = math.min(0, u1), math.max(0, u1)
    local minV, maxV = math.min(0, v1), math.max(0, v1)

    local function toWorld(u, v)
        return x0 + rx * u + fx * v, z0 + rz * u + fz * v
    end

    return {
        rx = rx, rz = rz, fx = fx, fz = fz,
        minU = minU, maxU = maxU, minV = minV, maxV = maxV,
        corners = {
            { toWorld(minU, minV) }, { toWorld(maxU, minV) },
            { toWorld(maxU, maxV) }, { toWorld(minU, maxV) },
        },
    }
end

function ADFlyoverEditor:finishBoxSelect()
    self.boxActive = false

    local x0, z0 = self.boxStartX, self.boxStartZ
    local x1, z1 = self.cursorX, self.cursorZ
    self.boxStartX, self.boxStartZ = nil, nil
    if x0 == nil or x1 == nil then
        return
    end

    if math.abs(x1 - x0) < AutoDrive.FLYOVER_BOX_MIN_SIZE and math.abs(z1 - z0) < AutoDrive.FLYOVER_BOX_MIN_SIZE then
        if self.hoverId ~= nil then
            self:toggleSelected(self.hoverId)
            if self.selectionCount > 0 then self:openSetMenu() else self:closeMenu() end
            ADFlyoverSettings.debugLog("[FlyoverEditor]: %s waypoint id=%s (%d selected).",
                self.selection[self.hoverId] and "selected" or "deselected", tostring(self.hoverId), self.selectionCount)
        end
        return
    end

    -- Ctrl adds to what is already selected; without it the box replaces the selection, which is
    -- the behaviour that makes a mis-aimed box cheap to correct.
    local additive = self.leftCtrlHeld or self.rightCtrlHeld
    if not additive then
        self:clearSelection()
    end

    local frame = self:boxFrame(x0, z0, x1, z1)

    local added = 0
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        local u = (wp.x - x0) * frame.rx + (wp.z - z0) * frame.rz
        local v = (wp.x - x0) * frame.fx + (wp.z - z0) * frame.fz
        if u >= frame.minU and u <= frame.maxU and v >= frame.minV and v <= frame.maxV
            and not self.selection[wp.id] then
            self.selection[wp.id] = true
            self.selectionCount = self.selectionCount + 1
            added = added + 1
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: box %s %d waypoint(s) over %.0fm x %.0fm, view-aligned (%d selected).",
        additive and "added" or "selected", added,
        frame.maxU - frame.minU, frame.maxV - frame.minV, self.selectionCount)
end

--- Rotated box's own frame, from three points instead of boxFrame's camera-derived basis: P1->P2
--- IS the edge (direction and length - the box's rotation, explicit rather than inferred from
--- wherever the camera happens to face), P3's perpendicular offset from that edge is the width.
--- Same returned shape as boxFrame (rx/rz/fx/fz/minU/maxU/minV/maxV/corners) so the hit test and
--- the live preview can use it identically. Returns nil for a degenerate edge or width, same
--- "too small to be deliberate" threshold boxFrame's caller uses.
function ADFlyoverEditor:edgeBoxFrame(p1x, p1z, p2x, p2z, p3x, p3z)
    local fx, fz = p2x - p1x, p2z - p1z
    local len = MathUtil.vector2Length(fx, fz)
    if len < AutoDrive.FLYOVER_BOX_MIN_SIZE then
        return nil
    end
    fx, fz = fx / len, fz / len
    local rx, rz = -fz, fx

    local w = (p3x - p2x) * rx + (p3z - p2z) * rz
    if math.abs(w) < AutoDrive.FLYOVER_BOX_MIN_SIZE then
        return nil
    end

    local minU, maxU = math.min(0, w), math.max(0, w)
    local minV, maxV = 0, len

    local function toWorld(u, v)
        return p1x + rx * u + fx * v, p1z + rz * u + fz * v
    end

    return {
        rx = rx, rz = rz, fx = fx, fz = fz,
        minU = minU, maxU = maxU, minV = minV, maxV = maxV,
        corners = {
            { toWorld(minU, minV) }, { toWorld(maxU, minV) },
            { toWorld(maxU, maxV) }, { toWorld(minU, maxV) },
        },
    }
end

--- Rotated box's click handling - three plain clicks (armed/cancelled by Space, see keyEvent),
--- not a drag, so this is reached from onLeftRelease exactly like moveSpanClick's own picking
--- clicks. First click places a corner, second sets the edge (direction + length), third sets
--- the width and commits - degenerate at either the second or third click (edge or width too
--- short) falls back to the same single-point toggle every other selection shape uses for a
--- gesture too small to be deliberate, per the "no ambiguity to guess between two different
--- actions" reasoning span's own click-to-replace already established.
--- Phase A's start: Space was held at press time (checked by the caller) - an ordinary press,
--- same as Box/Circle/Freehand's own gesture start, just gated on Space instead of Alt/Shift.
function ADFlyoverEditor:beginRotBoxDrag()
    self.rotBoxActive = true
    self.rotBoxDragging = true
    self.rotBoxP1X, self.rotBoxP1Z = self.cursorX, self.cursorZ
end

--- Phase A's end: releasing the drag sets the edge (direction + length) and moves to phase B - a
--- single plain click, no longer gated on Space (see the design note on the state block above),
--- to set the width and commit. Degenerate (edge too short) falls back to the same single-point
--- toggle every other shape uses for a gesture too small to be deliberate, and abandons the whole
--- sequence rather than leaving phase B waiting on a corner that was never really placed.
function ADFlyoverEditor:finishRotBoxEdge()
    self.rotBoxDragging = false
    local dx, dz = self.cursorX - self.rotBoxP1X, self.cursorZ - self.rotBoxP1Z
    if MathUtil.vector2Length(dx, dz) < AutoDrive.FLYOVER_BOX_MIN_SIZE then
        if self.hoverId ~= nil then
            self:toggleSelected(self.hoverId)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: %s waypoint id=%s (%d selected).",
                self.selection[self.hoverId] and "selected" or "deselected",
                tostring(self.hoverId), self.selectionCount)
        end
        self.rotBoxActive = false
        self.rotBoxP1X, self.rotBoxP1Z = nil, nil
        return
    end
    self.rotBoxP2X, self.rotBoxP2Z = self.cursorX, self.cursorZ
    ADFlyoverSettings.debugLog("[FlyoverEditor]: rotated box: edge set - click to set the width and finish.")
end

--- Commits the rotated box - same additive/hit-test shape as finishBoxSelect, just against
--- edgeBoxFrame instead of boxFrame.
function ADFlyoverEditor:finishRotBoxSelect(p3x, p3z)
    local p1x, p1z, p2x, p2z = self.rotBoxP1X, self.rotBoxP1Z, self.rotBoxP2X, self.rotBoxP2Z
    self.rotBoxActive = false
    self.rotBoxP1X, self.rotBoxP1Z, self.rotBoxP2X, self.rotBoxP2Z = nil, nil, nil, nil

    local frame = self:edgeBoxFrame(p1x, p1z, p2x, p2z, p3x, p3z)
    if frame == nil then
        if self.hoverId ~= nil then
            self:toggleSelected(self.hoverId)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: %s waypoint id=%s (%d selected).",
                self.selection[self.hoverId] and "selected" or "deselected",
                tostring(self.hoverId), self.selectionCount)
        end
        return
    end

    local additive = self.leftCtrlHeld or self.rightCtrlHeld
    if not additive then
        self:clearSelection()
    end

    local added = 0
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        local u = (wp.x - p1x) * frame.rx + (wp.z - p1z) * frame.rz
        local v = (wp.x - p1x) * frame.fx + (wp.z - p1z) * frame.fz
        if u >= frame.minU and u <= frame.maxU and v >= frame.minV and v <= frame.maxV
            and not self.selection[wp.id] then
            self.selection[wp.id] = true
            self.selectionCount = self.selectionCount + 1
            added = added + 1
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: rotated box %s %d waypoint(s) (%d selected).",
        additive and "added" or "selected", added, self.selectionCount)
end

--- Finish an Alt+drag circle. The two clicked points are a DIAMETER, not a centre and a
--- radius - the centre is their midpoint, the radius is half the distance between them - so the
--- gesture stays "click one edge, drag to the other", the same shape as box's two corners, rather
--- than needing to eyeball a centre point first. A circle has no orientation, so unlike box this
--- needs no view-alignment at all.
function ADFlyoverEditor:finishCircleSelect()
    self.circleActive = false

    local x0, z0 = self.circleStartX, self.circleStartZ
    local x1, z1 = self.cursorX, self.cursorZ
    self.circleStartX, self.circleStartZ = nil, nil
    if x0 == nil or x1 == nil then
        return
    end

    local dx, dz = x1 - x0, z1 - z0
    local diameter = math.sqrt(dx * dx + dz * dz)
    if diameter < AutoDrive.FLYOVER_BOX_MIN_SIZE then
        if self.hoverId ~= nil then
            self:toggleSelected(self.hoverId)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: %s waypoint id=%s (%d selected).",
                self.selection[self.hoverId] and "selected" or "deselected", tostring(self.hoverId), self.selectionCount)
        end
        return
    end

    -- Ctrl adds, same as box - a mis-aimed circle should be as cheap to correct as a mis-aimed box.
    local additive = self.leftCtrlHeld or self.rightCtrlHeld
    if not additive then
        self:clearSelection()
    end

    local centreX, centreZ = (x0 + x1) / 2, (z0 + z1) / 2
    local radiusSq = (diameter / 2) * (diameter / 2)

    local added = 0
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        local ex, ez = wp.x - centreX, wp.z - centreZ
        if (ex * ex + ez * ez) <= radiusSq and not self.selection[wp.id] then
            self.selection[wp.id] = true
            self.selectionCount = self.selectionCount + 1
            added = added + 1
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: circle %s %d waypoint(s), %.0fm across (%d selected).",
        additive and "added" or "selected", added, diameter, self.selectionCount)
end

--- Even-odd ray-casting point-in-polygon test. Standalone rather than a method (mirrors
--- heightAlongChain elsewhere in this file) - it has no need of self, and OffsetGeometry.lua
--- already has one of these (isPointInsideRing) but keeps it local to that file, unexported.
local function pointInPolygon(px, pz, poly)
    local inside = false
    local j = #poly
    for i = 1, #poly do
        local pi, pj = poly[i], poly[j]
        if (pi.z > pz) ~= (pj.z > pz)
            and px < (pj.x - pi.x) * (pz - pi.z) / (pj.z - pi.z) + pi.x then
            inside = not inside
        end
        j = i
    end
    return inside
end

--- Finish a Ctrl+Alt freehand drag. The traced path (sampled live in update()) is closed into a
--- polygon implicitly - pointInPolygon walks it edge i to edge i+1 including the wrap from the
--- last sampled point back to the first, so releasing anywhere just finishes the loop rather than
--- needing the hand to return to its own start.
function ADFlyoverEditor:finishFreehandSelect()
    self.freehandActive = false
    local points = self.freehandPoints
    self.freehandPoints = nil
    if points == nil then
        return
    end

    -- Too few samples to be a deliberate trace (a stationary click only ever gathers the one
    -- opening point - see the 1m-apart gate in update()) - same single-point toggle fallback box
    -- and circle both use for a drag too small to be deliberate.
    if #points < 3 then
        if self.hoverId ~= nil then
            self:toggleSelected(self.hoverId)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: %s waypoint id=%s (%d selected).",
                self.selection[self.hoverId] and "selected" or "deselected", tostring(self.hoverId), self.selectionCount)
        end
        return
    end

    -- Ctrl adds, same as box/circle - a mis-aimed trace should be as cheap to correct as either.
    local additive = self.leftCtrlHeld or self.rightCtrlHeld
    if not additive then
        self:clearSelection()
    end

    local added = 0
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if pointInPolygon(wp.x, wp.z, points) and not self.selection[wp.id] then
            self.selection[wp.id] = true
            self.selectionCount = self.selectionCount + 1
            added = added + 1
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: freehand %s %d waypoint(s) over a %d-point trace (%d selected).",
        additive and "added" or "selected", added, #points, self.selectionCount)
end

--- Ids shift whenever a waypoint is removed (GraphManager.lua:288), so anything holding an id has
--- to be dropped after a destructive edit rather than silently pointing at a different waypoint.
function ADFlyoverEditor:invalidateIdReferences()
    ADFlyoverEditor.dropReverseInCache()
    -- Menus and the menu to step back to hold waypoint ids, which an undo or a delete can renumber.
    self.ctxMenu, self.menuBackTo = nil, nil
    self:clearSelection()
    self.hoverId = nil
    self.smoothFromId, self.smoothToId = nil, nil
    self.smoothPreview, self.smoothPinned, self.smoothBlockedBy = nil, nil, nil
    self.splineFromId = nil
    self.mergeFromId = nil
    self.mergeToId = nil
    self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
    self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = nil, nil, nil
    -- Holds waypoint ids (record.members[i].id), which a destructive edit like this one shifts -
    -- see node-keyed-pairs-is-nondeterministic / junction-numbers-do-not-persist in project memory
    -- for the general rule this follows.
    self.lastMoveRecord = nil
    -- Same reasoning: moveOffsetChainIds holds waypoint ids too. A pending offset is abandoned
    -- rather than committed here, same as setTool - this fires mid-edit, not at a deliberate
    -- right-click.
    self:cancelMoveOffset()
    self.divideFromId, self.divideToId, self.dividePreview = nil, nil, nil
    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
    self.groundFromId, self.groundToId, self.groundPreview = nil, nil, nil
    self.offsetFromId, self.offsetToId, self.offsetPreview = nil, nil, nil
    self.spanIds = nil
    self.sidingAnchorId, self.sidingPreview = nil, nil
    self.smoothToId, self.smoothPreview, self.smoothPinned = nil, nil, nil
    self.dragId = nil
    self.lastWaypointId = nil
end
