-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "isJunction" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Draw.lua needs %s, which no file loaded before it shares", name)
    end
end
local isJunction = ADFlyoverEditor.shared.isJunction
-- MODSPLIT: end of the helpers

-- AutoDrive's own network rendering lives on the VEHICLE specialization
-- (AutoDrive:onDrawEditorMode, Specialization.lua:809), so with no vehicle entered nothing is
-- drawn at all - which is why placed waypoints were audible but invisible. ADDrawingManager
-- itself is global and is already pumped from AutoDrive:draw(), so the flyover mode can just
-- submit its own draw tasks. Limited to a radius around the cursor: the graph can hold thousands
-- of waypoints and all of them every frame is wasted work.
--- Minimal network rendering for the on-foot case, where the mod's own vehicle-scoped editor
--- drawing cannot run. Deliberately plain: it exists so the mode is usable without a vehicle, not
--- to reproduce the mod's colour scheme.
function ADFlyoverEditor:drawNetworkFallback()
    local radiusSq = AutoDrive.FLYOVER_DRAW_RADIUS * AutoDrive.FLYOVER_DRAW_RADIUS
    local wayPoints = ADGraphManager:getWayPoints()
    local lw = (ADFlyoverTheme ~= nil and ADFlyoverTheme.lineWeight) or 2

    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        local dx, dz = wp.x - self.cursorX, wp.z - self.cursorZ
        if (dx * dx + dz * dz) < radiusSq then
            ADDrawingManager:addSphereTask(wp.x, wp.y + 0.5, wp.z, 2, 1, 0.8, 0, 0.15)
            for _, targetId in pairs(wp.out or {}) do
                local target = ADGraphManager:getWayPointById(targetId)
                if target ~= nil then
                    ADDrawingManager:addLineTask(wp.x, wp.y + 0.5, wp.z,
                        target.x, target.y + 0.5, target.z, lw, 0, 1, 0)
                end
            end
        end
    end
end

function ADFlyoverEditor:drawNetwork()
    if self.cursorX == nil then
        return
    end

    -- Global preview line weight (a theme/display setting): the width passed as the SCALE argument of
    -- every addLineTask below, so one setting thickens or thins all of the editor's world-space lines.
    local lw = (ADFlyoverTheme ~= nil and ADFlyoverTheme.lineWeight) or 2

    -- The NETWORK itself is drawn by the mod's own editor rendering (AutoDrive:onDrawEditorMode),
    -- which is now centred on this cursor rather than on the vehicle. Drawing a second copy here
    -- put two sets of spheres and lines on every waypoint, in two different colour schemes.
    --
    -- That rendering is a vehicle specialization callback though, and it only runs for the
    -- CONTROLLED vehicle - so on foot there is no vehicle to run it and nothing would be drawn at
    -- all. That was the original "waypoints are audible but invisible" bug, so it keeps a fallback.
    -- COMPANION EDIT: draw the fallback whenever the PROXY did not draw this frame, rather than
    -- whenever the player is on foot. The old test was right only while the fork's own re-centring
    -- inside AutoDrive's Specialization.lua existed; here the proxy is the thing that may or may
    -- not have run, and it declines when there is no vehicle with AutoDrive state to borrow.
    -- Draw our own network ONLY when AutoDrive's cannot be used - i.e. there is no vehicle with
    -- AutoDrive state for the proxy to borrow. Whenever the proxy can draw, we draw nothing and the
    -- network on screen is AutoDrive's own, in AutoDrive's own colours. That is the whole point of
    -- the proxy: one renderer, theirs, so the editor cannot drift from what the rest of the mod
    -- shows.
    if ADFlyoverProxy == nil or not ADFlyoverProxy.willDraw() then
        self:drawNetworkFallback()
    end

    -- What is left is only what the mod cannot know about: which waypoints this editor considers
    -- hovered, selected, or the pending end of a connection.
    -- The 4th colour argument to addSphereTask is NOT alpha/opacity - DrawingManager:drawSphere
    -- adds it directly to self.emittivity (a dynamic, ambient-light-aware glow baseline, roughly
    -- 0-0.45) as an EMISSIVE intensity. Every sphere in this file was passing 0.4-1.0 there;
    -- AutoDrive's own markers (same call, same shader) use ~0.15. The excess pushed colour
    -- channels toward clipping, especially in bright daylight - a clipped RGB triple reads as
    -- white regardless of the intended hue, which is why every highlight in the editor read as
    -- washed-out/pale rather than distinctly coloured (reported and root-caused 2026-09-21).
    -- Every addSphereTask call below (not addLineTask - it takes no alpha at all) now uses one of
    -- three tiers instead of a dozen ad hoc values: 0.10 (dim/secondary), 0.15 (normal - matches
    -- AutoDrive's own value exactly), 0.20 (standout - the "you would grab this" markers).
    local function accent(id, r, g, b, size)
        if id == nil then
            return
        end
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            ADDrawingManager:addSphereTask(wp.x, wp.y + 0.6, wp.z, size, r, g, b, 0.15)
        end
    end

    for id in pairs(self.selection) do
        accent(id, 0, 1, 0.2, 3.5)
    end
    -- The span the active span tool has picked, marked the same way Move marks its span: the two ends
    -- large, the points between them smaller, all in that blue. Without it a picked span or run was
    -- invisible until the tool had something to preview (Ground only ever showed points OFF the ground),
    -- so a working pick read as "nothing selected".
    local pickFrom, pickTo = self:pickedSpanEnds()
    if pickFrom ~= nil then
        accent(pickFrom, 0, 0.6, 1, 4)
        if pickTo ~= nil then
            accent(pickTo, 0, 0.6, 1, 4)
            local key = tostring(self.tool) .. ":" .. tostring(pickFrom) .. ":" .. tostring(pickTo)
            if self.pickHighlightKey ~= key then
                self.pickHighlightKey = key
                self.pickHighlightIds = self:spanBetween(pickFrom, pickTo) or {}
            end
            for _, id in ipairs(self.pickHighlightIds) do
                if id ~= pickFrom and id ~= pickTo then
                    accent(id, 0, 0.6, 1, 2.5)
                end
            end
        end
    end
    accent(self.smoothFromId, 0, 0.6, 1, 4)
    accent(self.splineFromId, 0, 0.6, 1, 4)
    accent(self.mergeFromId, 1, 0.4, 0.9, 4)
    accent(self.mergeToId, 1, 0.4, 0.9, 4)
    -- Matches smooth/spline's own blue exactly (0, 0.6, 1), not a new colour - the original
    -- (0.2, 0.7, 1) added red and extra green, which pushed it toward pale/near-white and was
    -- reported hard to see (2026-09-21); this value is already proven visible in this same file.
    accent(self.moveSpanFromId, 0, 0.6, 1, 4)
    accent(self.moveSpanToId, 0, 0.6, 1, 4)
    if self.moveSpanIds ~= nil then
        for id in pairs(self.moveSpanIds) do
            if id ~= self.moveSpanFromId and id ~= self.moveSpanToId then
                accent(id, 0, 0.6, 1, 2.5)
            end
        end
    end
    -- The chain currently being offset - amber, distinct from span's blue, for the whole time it
    -- is live (both the cursor-drag phase and the released-but-still-pending-commit phase).
    if self.moveOffsetChainIds ~= nil then
        for _, id in ipairs(self.moveOffsetChainIds) do
            accent(id, 1, 0.65, 0, 3)
        end
    end

    -- Move falloff preview: the waypoints the falloff would carry, measured ALONG THE TRACK (not a
    -- circle - the reach follows the run through junctions, so a ring would lie about it). The centre
    -- is the point being dragged, or the last one pointed at, so wheeling the radius over the tool
    -- card shows its reach live. Sized and brightened by how far each point would actually move.
    -- A pending offset owns the interaction (a stray click elsewhere is ignored - see onLeftPress)
    -- but the hover preview below did not know that, and kept lighting up whatever run/point the
    -- cursor passed over anyway - misleading, since nothing you hover actually does anything while
    -- one is pending (reported 2026-09-21: "other spans are highlighting, but not selecting").
    if self.tool == self.TOOL.MOVE and self.moveOffsetChainIds == nil then
        local centreId = self.dragId or self.moveFocusId
        -- The yellow run preview: while a run is being dragged, or - locked to run with nothing picked - the
        -- run a grab WOULD take under the pointer. Not otherwise: a picked run already shows in blue, and
        -- the old "moveSelectMode stays RUN" left this yellow on after Esc had cleared the pick.
        local runPreview = (self.dragId ~= nil and self.moveSelectMode == self.MOVE_SELECT.RUN)
            or (self.dragId == nil and self.pickFilter == "run" and self.moveSpanIds == nil)
        if centreId ~= nil and runPreview then
            -- Run mode: highlight the whole run the point belongs to. Not weighted by taper here -
            -- this fires before a grab even starts, when there is no drag distance yet to weight
            -- by, so it shows WHAT would move rather than how much.
            local c = ADGraphManager:getWayPointById(centreId)
            -- Third return is an ORDERED ARRAY (see the same note in gatherDragNeighbours's Run
            -- branch) - ipairs, not pairs, or `id` binds to the array INDEX (1, 2, 3...) instead
            -- of the actual waypoint id, which is why this never highlighted anything real.
            -- Junctions excluded from the highlight too, matching what an actual grab now does.
            local _, _, ids = self:resolveWholeRun(centreId)
            if c ~= nil then
                ADDrawingManager:addSphereTask(c.x, c.y + 0.7, c.z, 4.5, 1, 0.8, 0.15, 0.20)
            end
            if ids ~= nil then
                for _, id in ipairs(ids) do
                    if id ~= centreId and not isJunction(id) then
                        local wp = ADGraphManager:getWayPointById(id)
                        if wp ~= nil then
                            ADDrawingManager:addSphereTask(wp.x, wp.y + 0.7, wp.z, 3.5, 1, 0.82, 0.2, 0.15)
                        end
                    end
                end
            end
        elseif centreId ~= nil and self.moveSelectMode == self.MOVE_SELECT.POINT then
            -- Point only - this is collectAlongTrack's own radius-reach preview, which has
            -- nothing to do with Span's falloff (tapers to the span's own two picked ends, no
            -- radius involved at all). Left ungated it fired for Span too (reported 2026-09-21):
            -- a misleading preview around whatever was merely hovered, unrelated to the actual
            -- span - the real click logic already correctly ignored points outside the span, only
            -- the PREVIEW was wrong.
            local radius = self.moveFalloffOn and (self.falloffRadius or 0) or 0
            -- With a selection the preview must show what a grab would ACTUALLY do: only the selection's
            -- own points, and only when the pointer is on it and it is one run (a scattered one is rigid).
            local selOnly = self.selectionCount > 0
            if selOnly or self.moveSpanIds ~= nil then
                radius = 0   -- the reach preview is a single point's; picks and selections have none
            end
            if radius > 0 then
                local c = ADGraphManager:getWayPointById(centreId)
                if c ~= nil then
                    ADDrawingManager:addSphereTask(c.x, c.y + 0.7, c.z, 4.5, 1, 0.8, 0.15, 0.20)
                    -- Same exclusion as the actual grab (gatherDragNeighbours) - a junction the
                    -- radius merely reaches is never a follower, so it should not preview as one.
                    local reached = self:collectAlongTrack(centreId, radius)
                    for otherId, d in pairs(reached) do
                        if otherId ~= centreId and not isJunction(otherId)
                            and (not selOnly or self.selection[otherId]) then
                            local wp = ADGraphManager:getWayPointById(otherId)
                            if wp ~= nil then
                                local w = 0.5 * (1 + math.cos(math.pi * math.min(d, radius) / radius))
                                ADDrawingManager:addSphereTask(wp.x, wp.y + 0.7, wp.z,
                                    2 + 3 * w, 1, 0.82, 0.2, 0.10 + 0.10 * w)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Show what the Select-mode context menu is about to act on, so its "N points" has a visible
    -- referent in the world. Amber, distinct from the green selection and the blue span-from marker.
    local menu = self.ctxMenu
    if menu ~= nil then
        local hr, hg, hb = 1, 0.82, 0.15
        if menu.kind == "point" then
            accent(menu.id, hr, hg, hb, 4.5)
        elseif menu.kind == "span" and menu.ids ~= nil then
            local prev = nil
            for _, id in ipairs(menu.ids) do
                accent(id, hr, hg, hb, 3.2)
                local wp = ADGraphManager:getWayPointById(id)
                if wp ~= nil then
                    if prev ~= nil then
                        ADDrawingManager:addLineTask(prev.x, prev.y + 0.7, prev.z, wp.x, wp.y + 0.7, wp.z, lw, hr, hg, hb)
                    end
                    prev = wp
                end
            end
        elseif menu.kind == "run" and menu.runSet ~= nil then
            for id in pairs(menu.runSet) do
                accent(id, hr, hg, hb, 3.2)
                local wp = ADGraphManager:getWayPointById(id)
                if wp ~= nil then
                    for _, other in pairs(wp.out or {}) do
                        if menu.runSet[other] then
                            local ow = ADGraphManager:getWayPointById(other)
                            if ow ~= nil then
                                ADDrawingManager:addLineTask(wp.x, wp.y + 0.7, wp.z, ow.x, ow.y + 0.7, ow.z, lw, hr, hg, hb)
                            end
                        end
                    end
                end
            end
        end
    end

    if self.tool == self.TOOL.SMOOTH and self.smoothPreview ~= nil then
        -- Never fall back to zero: a missing height there drew the whole preview underground
        -- instead of showing anything wrong.
        local fallbackY = AutoDrive:getTerrainHeightAtWorldPos(self.cursorX, self.cursorZ)
        local prev = nil
        for i = 1, #self.smoothPreview do
            local p = self.smoothPreview[i]
            local py = (p.y or fallbackY) + 0.6
            local pinned = (self.smoothPinned or {})[i]
            ADDrawingManager:addSphereTask(p.x, py, p.z, pinned and 3.5 or 2.5,
                pinned and 1 or 0, pinned and 0.5 or 1, pinned and 0 or 0.4, 0.20)
            if prev ~= nil then
                ADDrawingManager:addLineTask(prev.x, (prev.y or fallbackY) + 0.6, prev.z, p.x, py, p.z, lw, 0, 1, 0.4)
            end
            prev = p
        end
    end

    if self.tool == self.TOOL.SIDING and self.sidingPreview ~= nil then
        for i = 1, #self.sidingPreview do
            local p = self.sidingPreview[i]
            local py = (p.y or 0) + 0.6
            ADDrawingManager:addSphereTask(p.x, py, p.z, 2.5, 0.2, 0.8, 1, 0.15)
            if i > 1 then
                local q = self.sidingPreview[i - 1]
                ADDrawingManager:addLineTask(q.x, (q.y or 0) + 0.6, q.z, p.x, py, p.z, lw, 0.2, 0.8, 1)
            end
        end
    end

    if self.tool == self.TOOL.PARALLEL and self.offsetPreview ~= nil then
        for i = 1, #self.offsetPreview do
            local p = self.offsetPreview[i]
            local py = (p.y or 0) + 0.6
            ADDrawingManager:addSphereTask(p.x, py, p.z, 2.5, 1, 0.6, 0.1, 0.15)
            if i > 1 then
                local q = self.offsetPreview[i - 1]
                ADDrawingManager:addLineTask(q.x, (q.y or 0) + 0.6, q.z, p.x, py, p.z, lw, 1, 0.6, 0.1)
            end
        end
    end

    -- Each offender gets a marker where it is, a marker where it would land, and a line between
    -- them, so the SIZE of the error reads at a glance. Red for a point above the ground, blue for
    -- one buried below it - the two want different explanations and are worth telling apart.
    if self.tool == self.TOOL.GROUND and self.groundPreview ~= nil then
        for _, p in ipairs(self.groundPreview) do
            local above = p.delta > 0
            local r, g, b = 1, 0.3, 0.2
            if not above then
                r, g, b = 0.3, 0.6, 1
            end
            ADDrawingManager:addSphereTask(p.x, p.y + 0.4, p.z, 3, r, g, b, 0.20)
            ADDrawingManager:addSphereTask(p.x, p.targetY + 0.4, p.z, 2, r, g, b, 0.10)
            ADDrawingManager:addLineTask(p.x, p.y + 0.4, p.z, p.x, p.targetY + 0.4, p.z, lw, r, g, b)
        end
    end

    -- Junction preview: the scope circle, the approaches it cuts (green = entry, amber = exit, with a
    -- stub along the travel direction), and each new turn drawn as its track-tangent connector curve.
    -- Nothing here changes the network until right-click.
    -- PLACE MODE's preview (doc 08): the piece that right-click will lay. WHITE = the pattern fitted to the
    -- crossing, AMBER = the plain piece (it does not fit), dimmer while it still follows the cursor; small
    -- white spheres = its shared points, RED spheres = the loose ends you join by hand. Where it cannot
    -- place at all, one red sphere at the cursor (the card says why).
    if self.tool == self.TOOL.JUNCTION and self.junctionPreview ~= nil and self.junctionPreview.placeMode then
        local jp = self.junctionPreview
        -- Following the cursor: thin and faint. Locked: full width and brightness, so the lock shows.
        local locked = self.junctionArmed ~= nil
        local k = locked and 1 or 0.35
        local plw = locked and lw or lw * 0.5
        if jp.ok and jp.plan ~= nil then
            local r, g, b = 1, 1, 1
            if jp.plan.shape == "plain" then r, g, b = 1, 0.72, 0.18 end
            for _, line in ipairs(jp.plan.lines or {}) do
                local pts = line.pts
                for i = 2, #pts do
                    local q, p = pts[i - 1], pts[i]
                    ADDrawingManager:addLineTask(q.x, (q.y or 0) + 0.5, q.z, p.x, (p.y or 0) + 0.5, p.z, plw,
                        r * k, g * k, b * k)
                end
            end
            for _, m in ipairs(jp.plan.marks or {}) do
                ADDrawingManager:addSphereTask(m.x, (m.y or 0) + 0.5, m.z, 1.4, k, k, k, 0.15)
            end
            for _, e in ipairs(jp.plan.loose or {}) do
                ADDrawingManager:addSphereTask(e.x, (e.y or 0) + 0.6, e.z, 2.2, 1, 0.2, 0.15, 0.2)
            end
        else
            ADDrawingManager:addSphereTask(jp.cx, (jp.cy or 0) + 0.6, jp.cz, 2.2, 1, 0.2, 0.15, 0.2)
        end
    elseif self.tool == self.TOOL.JUNCTION and self.junctionPreview ~= nil then
        local jp = self.junctionPreview
        local baseY = (jp.cy or AutoDrive:getTerrainHeightAtWorldPos(jp.cx, jp.cz) or 0)
        -- NB: addLineTask is (sx, sy, sz, ex, ey, ez, SCALE, r, g, b) - scale (line width) then colour,
        -- no alpha. lw is the global preview line weight (see the top of drawNetwork).

        -- Scope circle on the ground: thin grey while it scouts under the cursor, solid white once the
        -- site is locked (left-click) and it stops following the mouse.
        local segs = 48
        local px0, pz0
        local sr, sg, sb, sw = 0.55, 0.6, 0.66, lw * 0.5
        if jp.armed then sr, sg, sb, sw = 1, 1, 1, lw end
        for i = 0, segs do
            local a = (i / segs) * 2 * math.pi
            local px = jp.cx + math.sin(a) * jp.radius
            local pz = jp.cz + math.cos(a) * jp.radius
            if px0 ~= nil then
                ADDrawingManager:addLineTask(px0, baseY + 0.3, pz0, px, baseY + 0.3, pz, sw, sr, sg, sb)
            end
            px0, pz0 = px, pz
        end

        -- THE PATTERN, where the build will lay it (a locked site the pattern fits, jp.patternFit): its own
        -- lines in white and its shared points, as place drew them - not the turn-by-turn curves below,
        -- which the right-click would not lay. Those are drawn only on a locked site the pattern does not
        -- fit; following the cursor nothing is drawn, as the build does not know yet which it will be.
        local fit = jp.patternFit
        local turnByTurn = AutoDrive.FLYOVER_JUNCTION_BUILD_PATTERN == false
            or (self.junctionArmed ~= nil and (fit == nil or not fit.ok))
        if fit ~= nil and fit.ok then
            for _, line in ipairs(fit.lines or {}) do
                local pts = line.pts
                for i = 2, #pts do
                    local q, p = pts[i - 1], pts[i]
                    ADDrawingManager:addLineTask(q.x, (q.y or baseY) + 0.5, q.z, p.x, (p.y or baseY) + 0.5, p.z, lw, 1, 1, 1)
                end
            end
            for _, m in ipairs(fit.marks or {}) do
                ADDrawingManager:addSphereTask(m.x, (m.y or baseY) + 0.5, m.z, 1.4, 1, 1, 1, 0.15)
            end
        end
        -- NEW turns as track-tangent connector curves (white): tie-in ON the entry track, curve, tie-in
        -- ON the exit track. The small white spheres mark the tie-in (merge / exit) points - sitting on
        -- the real road a radius-appropriate distance back from where the tracks meet, NOT the boundary.
        for _, m in ipairs(turnByTurn and jp.movements or {}) do
            if (not m.exists or m.rebuild) and m.connector ~= nil then
                local c = m.connector
                local chain = { { x = c.ax, y = baseY + 0.5, z = c.az } }
                for _, p in ipairs(c.points) do
                    chain[#chain + 1] = { x = p.x, y = (p.y or baseY) + 0.5, z = p.z }
                end
                chain[#chain + 1] = { x = c.bx, y = baseY + 0.5, z = c.bz }
                -- White = will be laid; RED = refused on place (tighter than the turn radius even at
                -- the floor, or no radius keeps the vehicle corridor on the road).
                local cr, cg, cb = 1, 1, 1
                if m.refused ~= nil then cr, cg, cb = 1, 0.25, 0.2 end
                for i = 2, #chain do
                    local q, r = chain[i - 1], chain[i]
                    ADDrawingManager:addLineTask(q.x, q.y, q.z, r.x, r.y, r.z, lw, cr, cg, cb)
                end
                ADDrawingManager:addSphereTask(c.ax, (c.ay or baseY) + 0.5, c.az, 1.8, cr, cg, cb, 0.20)
                ADDrawingManager:addSphereTask(c.bx, (c.by or baseY) + 0.5, c.bz, 1.8, cr, cg, cb, 0.20)
                -- Swept-path prediction (locked site): where the design rig would actually go. ORANGE =
                -- tow rear axle, CYAN = trailer axle - the recorder's colours, so a recorded run and a
                -- prediction overlaid read the same. A trailer that would run its inside edge past the
                -- corridor draws RED instead of cyan.
                if m.swept ~= nil then
                    local sw = m.swept
                    local function track(pts, r, g, b, lift)
                        for i = 2, #pts do
                            local q, p = pts[i - 1], pts[i]
                            ADDrawingManager:addLineTask(q.x, baseY + lift, q.z, p.x, baseY + lift, p.z, lw * 0.7, r, g, b)
                        end
                    end
                    track(sw.tow, 1, 0.55, 0.1, 0.35)
                    if sw.wide then track(sw.trailer, 1, 0.2, 0.15, 0.4)
                    else track(sw.trailer, 0.2, 0.85, 1, 0.4) end
                end
            end
        end

        -- Approaches as tall pillars: GREEN = entry lane, AMBER = exit lane, with a direction arm on top.
        for _, ap in ipairs(jp.approaches) do
            local w = ap.selWp or ap.wp
            local r, g, b = 1, 0.65, 0.1                      -- exit: amber
            if ap.dir == "in" then r, g, b = 0.1, 1, 0.3 end   -- entry: green
            local gy = (w.y or baseY)
            ADDrawingManager:addLineTask(w.x, gy, w.z, w.x, gy + 4, w.z, lw, r, g, b)
            ADDrawingManager:addSphereTask(w.x, gy + 4, w.z, 2.5, r, g, b, 0.20)
            ADDrawingManager:addLineTask(w.x, gy + 4, w.z,
                w.x + math.sin(ap.bearing) * 4, gy + 4, w.z + math.cos(ap.bearing) * 4, lw, r, g, b)
        end

        -- Clear mode: RED spheres for what right-click removes, dim BLUE for through-path points a
        -- "leave through paths" clear will spare - so the shape of what stays behind is visible
        -- before committing to it, the same way the build side shows white before placing.
        if jp.clearMode then
            local leave = self.junctionLeaveThrough ~= false
            local doomed = leave and jp.turnDebris or jp.debris
            for _, w in ipairs(doomed or {}) do
                ADDrawingManager:addSphereTask(w.x, (w.y or baseY) + 0.5, w.z, 1.6, 1, 0.2, 0.15, 1)
            end
            -- And what the box sweep will take: everything inside the roads' offset lines.
            for _, w in ipairs(type(jp.boxSweep) == "table" and jp.boxSweep or {}) do
                ADDrawingManager:addSphereTask(w.x, (w.y or baseY) + 0.5, w.z, 1.6, 1, 0.2, 0.15, 1)
            end
            if leave then
                for _, w in ipairs(jp.throughDebris or {}) do
                    ADDrawingManager:addSphereTask(w.x, (w.y or baseY) + 0.5, w.z, 1.4, 0.2, 0.5, 1, 0.7)
                end
            end
            -- YELLOW lines: each road's claim - its centreline offset either side by half its track
            -- spread plus the clearance. GREEN spheres: where each lane end will finish, which is
            -- where its own path first meets someone else's claim. Both come from the tidy itself,
            -- run in dry mode, so this is not a drawing of what should happen - it is what will.
            -- Typed, not just nil-checked. These come back from the tidy, and an early return there
            -- once handed back counts instead of lists - which threw inside the renderer on every
            -- frame. Drawing is not where a shape mistake should surface.
            for _, b in ipairs(type(jp.tidyBands) == "table" and jp.tidyBands or {}) do
                ADDrawingManager:addLineTask(b.ax, baseY + 1.2, b.az, b.bx, baseY + 1.2, b.bz,
                    lw, 1, 0.9, 0.15)
            end
            for _, e in ipairs(type(jp.tidyEnds) == "table" and jp.tidyEnds or {}) do
                ADDrawingManager:addSphereTask(e.x, (e.y or baseY) + 1.0, e.z, 2.0, 0.2, 1, 0.3, 1)
            end
        end
    end

    if self.tool == self.TOOL.STRAIGHTEN and self.straightenPreview ~= nil then
        for i = 1, #self.straightenPreview do
            local p = self.straightenPreview[i]
            local py = (p.y or 0) + 0.6
            ADDrawingManager:addSphereTask(p.x, py, p.z, 2.5, 0.4, 1, 0.4, 0.15)
            if i > 1 then
                local q = self.straightenPreview[i - 1]
                ADDrawingManager:addLineTask(q.x, (q.y or 0) + 0.6, q.z, p.x, py, p.z, lw, 0.4, 1, 0.4)
            end
        end
    end

    if self.tool == self.TOOL.DIVIDE and self.dividePreview ~= nil then
        local cursorGroundY = AutoDrive:getTerrainHeightAtWorldPos(self.cursorX, self.cursorZ)
        for i = 1, #self.dividePreview do
            local p = self.dividePreview[i]
            ADDrawingManager:addSphereTask(p.x, (p.y or cursorGroundY) + 0.6, p.z, 3, 0, 1, 0.4, 0.15)
            if i > 1 then
                local q = self.dividePreview[i - 1]
                ADDrawingManager:addLineTask(q.x, (q.y or cursorGroundY) + 0.6, q.z,
                    p.x, (p.y or cursorGroundY) + 0.6, p.z, lw, 0, 1, 0.4)
            end
        end
    end

    -- The span in one colour and everything that would be absorbed into it in another, so the
    -- stretch where the two tracks actually run together is visible before anything is changed.
    if self.tool == self.TOOL.MERGE then
        for _, id in ipairs(self.mergePreviewSpan or {}) do
            accent(id, 1, 0.5, 0, 2.5)
        end
        for id in pairs(self.mergePreviewOther or {}) do
            accent(id, 0, 1, 0.4, 2.5)
        end
    end
    -- Hover last so it reads on top of a selected waypoint rather than being hidden by it.
    accent(self.hoverId, 1, 1, 1, 4)

    local cursorY = AutoDrive:getTerrainHeightAtWorldPos(self.cursorX, self.cursorZ)

    -- Rubber band from the open end of the run to the cursor, so the pending connection is
    -- visible rather than something you only discover after clicking. The connect tool gets the
    -- same treatment from its first-picked waypoint.
    local anchorId = self.lastWaypointId
    if self.tool == self.TOOL.PARALLEL or self.tool == self.TOOL.SIDING then
        anchorId = self.offsetFromId
    elseif self.tool == self.TOOL.GROUND then
        anchorId = self.groundFromId
    elseif self.tool == self.TOOL.STRAIGHTEN then
        anchorId = self.straightenFromId
    elseif self.tool == self.TOOL.SMOOTH then
        anchorId = self.smoothFromId
    elseif self.tool == self.TOOL.SPLINE then
        anchorId = self.splineFromId
    elseif self.tool == self.TOOL.MERGE then
        anchorId = self.mergeToId or self.mergeFromId
    end
    if anchorId ~= nil then
        local anchor = ADGraphManager:getWayPointById(anchorId)
        if anchor ~= nil then
            ADDrawingManager:addLineTask(
                anchor.x, anchor.y + 0.5, anchor.z,
                self.cursorX, cursorY + 0.5, self.cursorZ,
                lw, 1, 1, 1)
        end
    end

    -- The box being dragged, drawn as four lines on the ground so it reads as a region rather
    -- than a screen overlay floating over the terrain.
    if self.boxActive and self.boxStartX ~= nil then
        local frame = self:boxFrame(self.boxStartX, self.boxStartZ, self.cursorX, self.cursorZ)
        local corners = frame.corners
        for i = 1, 4 do
            local a, b = corners[i], corners[(i % 4) + 1]
            ADDrawingManager:addLineTask(
                a[1], AutoDrive:getTerrainHeightAtWorldPos(a[1], a[2]) + 0.5, a[2],
                b[1], AutoDrive:getTerrainHeightAtWorldPos(b[1], b[2]) + 0.5, b[2],
                lw, 0, 1, 0.2)
        end
    end

    -- Rotated box, mid-sequence: an edge line while only the first corner is placed, the full
    -- rotated rectangle (edgeBoxFrame, live against the cursor as the not-yet-clicked point) once
    -- the edge is set too - so the shape it is ABOUT to commit is always visible before the
    -- deciding click, the same principle box/circle/freehand's own live previews already follow.
    if self.rotBoxActive and self.rotBoxP1X ~= nil then
        if self.rotBoxDragging then
            ADDrawingManager:addLineTask(
                self.rotBoxP1X, AutoDrive:getTerrainHeightAtWorldPos(self.rotBoxP1X, self.rotBoxP1Z) + 0.5, self.rotBoxP1Z,
                self.cursorX, AutoDrive:getTerrainHeightAtWorldPos(self.cursorX, self.cursorZ) + 0.5, self.cursorZ,
                lw, 0, 1, 0.2)
        else
            local frame = self:edgeBoxFrame(self.rotBoxP1X, self.rotBoxP1Z, self.rotBoxP2X, self.rotBoxP2Z,
                self.cursorX, self.cursorZ)
            if frame ~= nil then
                local corners = frame.corners
                for i = 1, 4 do
                    local a, b = corners[i], corners[(i % 4) + 1]
                    ADDrawingManager:addLineTask(
                        a[1], AutoDrive:getTerrainHeightAtWorldPos(a[1], a[2]) + 0.5, a[2],
                        b[1], AutoDrive:getTerrainHeightAtWorldPos(b[1], b[2]) + 0.5, b[2],
                        lw, 0, 1, 0.2)
                end
            end
        end
    end

    -- The circle being dragged - drawn as a ring the same way the falloff ring is, from the two
    -- points as a diameter rather than a centre and radius, matching finishCircleSelect.
    if self.circleActive and self.circleStartX ~= nil then
        local x0, z0 = self.circleStartX, self.circleStartZ
        local x1, z1 = self.cursorX, self.cursorZ
        local centreX, centreZ = (x0 + x1) / 2, (z0 + z1) / 2
        local radius = MathUtil.vector2Length(x1 - x0, z1 - z0) / 2
        local segments = 32
        local prevX, prevZ
        for i = 0, segments do
            local angle = (i / segments) * 2 * math.pi
            local px = centreX + math.cos(angle) * radius
            local pz = centreZ + math.sin(angle) * radius
            if prevX ~= nil then
                ADDrawingManager:addLineTask(
                    prevX, AutoDrive:getTerrainHeightAtWorldPos(prevX, prevZ) + 0.5, prevZ,
                    px, AutoDrive:getTerrainHeightAtWorldPos(px, pz) + 0.5, pz,
                    lw, 0, 1, 0.2)
            end
            prevX, prevZ = px, pz
        end
    end

    -- The freehand trace so far, drawn as the sampled path plus the closing segment back to its
    -- start - the same implicit close finishFreehandSelect's polygon test uses, so the preview
    -- never promises a shape the hit test does not actually use.
    if self.freehandActive and self.freehandPoints ~= nil and #self.freehandPoints >= 2 then
        local points = self.freehandPoints
        for i = 1, #points do
            local a = points[i]
            local b = points[(i % #points) + 1]
            ADDrawingManager:addLineTask(
                a.x, AutoDrive:getTerrainHeightAtWorldPos(a.x, a.z) + 0.5, a.z,
                b.x, AutoDrive:getTerrainHeightAtWorldPos(b.x, b.z) + 0.5, b.z,
                lw, 0, 1, 0.2)
        end
    end

    -- Frozen copy (dragFrozenCopy - see beginDrag/toggleMoveCopy/updateDrag): the real
    -- waypoint(s) stay put, which is the whole point, but that also means nothing at all follows
    -- the cursor any more - reported 2026-09-21, "doesn't show us our new copy until drop, so we
    -- have no idea where it is going." Preview-only marker(s) at exactly the position the copy
    -- WOULD land at right now, using the identical rotate-then-translate math updateDrag itself
    -- uses when not frozen, so the preview never promises a spot the actual release would not
    -- also produce.
    if self.tool == self.TOOL.MOVE and self.dragId ~= nil and self.dragFrozenCopy
        and self.dragStartX ~= nil then
        local py = AutoDrive:getTerrainHeightAtWorldPos(self.cursorX, self.cursorZ) + 0.7
        ADDrawingManager:addSphereTask(self.cursorX, py, self.cursorZ, 4.5, 0.2, 1, 0.3, 0.20)
        local cosA, sinA = math.cos(self.moveRotateAngle), math.sin(self.moveRotateAngle)
        local pivotX = self.moveRotatePivotX or self.dragStartX
        local pivotZ = self.moveRotatePivotZ or self.dragStartZ
        local deltaX, deltaZ = self.cursorX - self.dragStartX, self.cursorZ - self.dragStartZ
        for _, n in ipairs(self.dragNeighbours or {}) do
            local ox, oz = n.x - pivotX, n.z - pivotZ
            local px = pivotX + ox * cosA - oz * sinA + deltaX * n.weight
            local pz = pivotZ + ox * sinA + oz * cosA + deltaZ * n.weight
            local ny = AutoDrive:getTerrainHeightAtWorldPos(px, pz) + 0.7
            ADDrawingManager:addSphereTask(px, ny, pz, 3.5, 0.2, 1, 0.3, 0.15)
        end
    end

    -- Frozen offset (copy on): the original chain stays put, so draw where the copy will go - its points
    -- and the line through them - in the same green as the frozen-copy drag preview above.
    if self.tool == self.TOOL.MOVE and self.moveOffsetFrozen and self.moveOffsetTargets ~= nil then
        local prev = nil
        for i = 1, #(self.moveOffsetChainIds or {}) do
            local t = self.moveOffsetTargets[i]
            if t ~= nil then
                local ty = AutoDrive:getTerrainHeightAtWorldPos(t.x, t.z) + 0.7
                ADDrawingManager:addSphereTask(t.x, ty, t.z, 3.5, 0.2, 1, 0.3, 0.15)
                if prev ~= nil then
                    ADDrawingManager:addLineTask(prev.x, prev.y, prev.z, t.x, ty, t.z, lw, 0.2, 1, 0.3)
                end
                prev = { x = t.x, y = ty, z = t.z }
            end
        end
    end

    -- Falloff ring, so the reach of a proportional move is visible before committing to it
    -- rather than being discovered from the result. Point only - Run's taper has no radius, it
    -- follows the run's own ends, so a ring here would just be wrong.
    if self.tool == self.TOOL.MOVE and self.moveSelectMode == self.MOVE_SELECT.POINT
        and self.moveFalloffOn and self.falloffRadius > 0 then
        local centreX = self.cursorX
        local centreZ = self.cursorZ
        if self.dragId ~= nil and self.dragStartX ~= nil then
            centreX, centreZ = self.dragStartX, self.dragStartZ
        end
        local segments = 32
        local prevX, prevZ
        for i = 0, segments do
            local angle = (i / segments) * 2 * math.pi
            local px = centreX + math.cos(angle) * self.falloffRadius
            local pz = centreZ + math.sin(angle) * self.falloffRadius
            if prevX ~= nil then
                ADDrawingManager:addLineTask(
                    prevX, AutoDrive:getTerrainHeightAtWorldPos(prevX, prevZ) + 0.5, prevZ,
                    px, AutoDrive:getTerrainHeightAtWorldPos(px, pz) + 0.5, pz,
                    lw, 0.2, 0.6, 1)
            end
            prevX, prevZ = px, pz
        end
    end
end
