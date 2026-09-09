--[[
ADFlyoverEditor - SPIKE.

Purpose: prove, in-game, the one chain the vehicle-free editor depends on -
    GuiTopDownCamera (detached free camera)
        -> camera:getPickRay()
            -> GuiTopDownCursor:getPosition()   (world x/y/z under the cursor)
                -> ADGraphManager:recordWayPoint(...)

Both Gui classes are base-game FS25, not Courseplay's - Courseplay just happens to prove they are
callable from ordinary mod Lua (scripts/gui/pages/CpConstructionFrame.lua drives exactly this pair
for its course editor). Nothing here is dev-console-only, and nothing here is ported code.

Deliberately screen-less. Courseplay hosts the pair inside a TabbedMenuFrameElement with a GUI xml,
menu registration and a pile of HUD repositioning; none of that is needed to answer the question
this spike exists to answer, and all of it would have to be redone anyway once we know the answer.
It instead drives the camera from AutoDriveRegister's already-registered but empty update/
mouseEvent/draw mod event listener stubs.

The risk this spike is measuring: GuiTopDownCamera may assume it is running inside a GUI screen
(for input contexts / action events). If it does, the log will show activation succeeding but the
camera not taking over, or the cursor never resolving a position - and the answer is that the real
thing needs the GUI frame after all. Either outcome is a result.

Every step is pcall-guarded and logged, and the console command toggles OFF as well as on, so a
half-working camera can always be escaped from the console rather than wedging the session.
]]

ADFlyoverEditor = {
    -- Camera movement and zoom run on action events, and an action event registers into whatever
    -- input context is current. Registering them without switching context first puts them in the
    -- gameplay context, where the player already owns WASD and the wheel - and the player wins, so
    -- the camera activates but will not move. Pushing a custom context first gives the camera's
    -- bindings a context of their own. Courseplay gets this via TabbedMenuFrameElement's
    -- toggleCustomInputContext, which is a GUI-screen facility; screen-less, g_inputBinding is
    -- the same thing by hand.
    INPUT_CONTEXT = "AD_FLYOVER_EDITOR",
    active = false,
    camera = nil,
    cursor = nil,
    lastWaypointId = nil,
    placedCount = 0,
    loggedNoPosition = false,
    contextPushed = false,
    inputStateOnEnter = nil,
    -- Whether our input context has been created yet this session. See enable().
    contextCreated = false,
    previousShowMouseCursor = false,
    -- No mode switching here: hold-middle-to-pan and wheel-zoom are GuiTopDownCamera's own
    -- bindings, registered by registerActionEvents(). Adding a toggle on top just puts two
    -- mechanisms on one button. The cursor stays free for picking the whole time and the camera
    -- keeps its native scheme, which is exactly how the base game's construction screen behaves.
    leftDown = false,
    rightDown = false,
    cursorX = nil,
    cursorZ = nil,
    loggedHeightComparison = false,

    tool = 1,
    lastRightPressAt = nil,
    elapsedMs = 0,
    hoverId = nil,
    selection = {},
    selectionCount = 0,
    -- Move-tool drag state. dragStart is where the grab began, so the delta (and therefore the
    -- falloff applied to the neighbours) is measured from the grab point rather than accumulating
    -- frame to frame.
    dragId = nil,
    dragStartX = nil,
    dragStartZ = nil,
    dragNeighbours = nil,
    falloffRadius = 0,
    boxActive = false,
    boxStartX = nil,
    boxStartZ = nil,
    -- Sticky connection options, shown and changed on the panel instead of held as modifier keys.
    connectionMode = 1,
    subPrio = false,
    splineFromId = nil,
    curvatureIndex = 1,
    -- Two separate spline controls, because they answer two different questions: which way the
    -- spline itself runs, and which way it should be travelling when it joins the far track.
    splineSwapEnds = false,
    splineFlipEndTangent = false,
    splineFlipStartTangent = false,
    splineToId = nil,
    deleteScope = 1,
    snapToTerrain = false,
    convertScope = 2,
    convertOp = 1,
    -- parallel and siding share this: they are the same span-select, the same wheel and the same
    -- preview, and differ only in what happens on commit. They are mutually exclusive anyway.
    offsetFromId = nil,
    offsetToId = nil,
    offsetPreview = nil,
    offsetBlockedBy = nil,
    offsetDistance = 5.0,
    offsetScope = 1,
    -- Which side the new track goes. Seeded from the cursor when the span or anchor is first
    -- picked, then owned by the panel's flip button. Deriving it from the cursor every frame read
    -- well while selecting and badly afterwards: once anchored the cursor is usually sitting ON the
    -- line, where the cross product is nearly zero and the side simply never changed.
    offsetSide = 1,
    sidingAnchorId = nil,
    sidingPreview = nil,
    sidingBlockedBy = nil,
    offsetCache = nil,
    straightenFromId = nil,
    straightenToId = nil,
    straightenPreview = nil,
    straightenTolerance = 1.0,
    divideFromId = nil,
    divideToId = nil,
    divideCount = 4,
    smoothToId = nil,
    smoothStrength = 3,
    smoothSpacing = 8,
    smoothMode = 1,
    smoothPreview = nil,
    smoothPinned = nil,
    dividePreview = nil,
    mergePreviewSpan = nil,
    mergePreviewOther = nil,
    mergePreviewQueryId = nil,
    -- Inline numeric entry: nil, or { label=, buffer=, apply=, current= }.
    editing = nil,
    -- What the cursor is currently over, and where that was last worked out.
    fieldLabel = nil,
    fieldQueryX = nil,
    fieldQueryZ = nil,
    mergeFromId = nil,
    mergeToId = nil
}

-- NONE is a real state, not an absence: with no tool selected a click does nothing at all, which
-- is what makes the editor safe to leave sitting open while looking around.
-- PLACE and CONNECT used to be separate tools. They are one now, because laying a route needs
-- both constantly - place a run, then join it to something that already exists - and switching
-- tools mid-gesture discarded lastWaypointId, so the run had to be started again. Merging also
-- stops a click on an existing waypoint stacking a second waypoint on top of it, and brings the
-- count to ten, which is exactly what the 1-0 key bindings can address: the binding is
-- (tool == 10) and "KEY_0" or ("KEY_" .. tool), so the eleventh tool previously had no key.
-- Ordered by how often each is actually reached for, because position IS the key binding: the
-- tool at 10 answers to 0, the most awkward reach, and so belongs to the one used least.
-- Order set from how the editor is really used, not from how the tools group conceptually.
ADFlyoverEditor.TOOL = { NONE = 0, DRAW = 1, MOVE = 2, DELETE = 3, NAME = 4, SPLINE = 5, DIVIDE = 6, SMOOTH = 7, CONVERT = 8, STRAIGHTEN = 9, FIELDLOOP = 10, MERGE = 11, PARALLEL = 12, SIDING = 13 }
ADFlyoverEditor.TOOL_NAMES = { "draw", "move", "delete", "name", "spline", "divide", "smooth", "convert", "straighten", "field loop", "merge", "parallel", "siding" }

-- How far around the cursor the flyover mode draws the waypoint network, in meters.
AutoDrive.FLYOVER_DRAW_RADIUS = 200
-- How close the cursor has to be to a waypoint to pick it, in meters. Generous, because the
-- camera can be zoomed a long way out and this is a world-space radius, not a screen-space one.
AutoDrive.FLYOVER_PICK_RADIUS = 4
-- Screen-space pick radius, as a fraction of screen height. This is the one that normally applies;
-- the world-space one above is only the fallback if project is unavailable.
AutoDrive.FLYOVER_PICK_SCREEN_RADIUS = 0.025
-- Proportional-move falloff radius: 0 means "move only the grabbed point". Adjusted with , and .
-- Straighten: how far a waypoint may sit from the straight line through its neighbours before it
-- counts as a deliberate bend rather than noise. The wheel dials this while the preview shows which
-- points survive, which is the only sensible way to pick it - the number alone means nothing.
-- Parallel and siding: how far to the side the new track runs. SIGNED, and the wheel runs it
-- through zero - which is how the side gets flipped, without a separate control for it.
-- A siding merges back into the main line over this many times its own offset. Deriving it
-- rather than setting it keeps the TAPER ANGLE constant: 5m out over 20m is about 14 degrees, and
-- it stays 14 degrees at any offset, which is what a vehicle following it actually cares about.
AutoDrive.FLYOVER_SIDING_MERGE_RATIO = 4

AutoDrive.FLYOVER_OFFSET_MIN = 0.1
AutoDrive.FLYOVER_OFFSET_MAX = 30
AutoDrive.FLYOVER_OFFSET_STEP = 0.1

AutoDrive.FLYOVER_STRAIGHTEN_MIN = 0
AutoDrive.FLYOVER_STRAIGHTEN_MAX = 25
AutoDrive.FLYOVER_STRAIGHTEN_STEP = 0.25

AutoDrive.FLYOVER_FALLOFF_STEP = 2.5
-- Finer than the key step: the wheel is for dialling a value in while watching it, the keys for
-- getting somewhere in a hurry.
AutoDrive.FLYOVER_FALLOFF_WHEEL_STEP = 1.0
AutoDrive.FLYOVER_FALLOFF_MAX = 60
-- Fallback merge distance, used only if the GUI setting is unavailable. The real value is the
-- flyoverMergeDistance setting.
AutoDrive.FLYOVER_MERGE_DISTANCE = 1.5
-- Cap on how far a single click's track walk may run, so a seed dropped on a huge connected
-- network cannot sweep the whole map into one merge.
AutoDrive.FLYOVER_MERGE_MAX_RUN = 4000
-- Fallback for how far the two tracks may pull apart before the merge treats them as separate
-- runs. The real value is the flyoverMergeDivergence setting.
AutoDrive.FLYOVER_MERGE_DIVERGENCE = 25
-- Below this, a Ctrl+drag counts as a click rather than a box, in meters. Wants to be small enough
-- that a deliberate box is never mistaken for a click, and large enough that a click is never
-- mistaken for a box because the mouse moved a pixel.
AutoDrive.FLYOVER_BOX_MIN_SIZE = 1.5
-- How far the cursor must move before the field under it is looked up again, in meters.
AutoDrive.FLYOVER_FIELD_QUERY_STEP = 3
-- Cap on how many waypoints one run-delete may remove, as a guard against a scope that turns out
-- to reach further than expected.
AutoDrive.FLYOVER_DELETE_RUN_MAX = 5000
-- Curvature handed to the mod when the panel says "auto". It has to be a number rather than nil:
-- the mod adds to it unguarded while an interpolation is valid.
AutoDrive.FLYOVER_DEFAULT_CURVATURE = 1.0
-- How far above the terrain a waypoint has to sit before it is treated as standing on a structure
-- whose height nothing available can measure, and therefore left alone rather than re-grounded.
AutoDrive.FLYOVER_STRUCTURE_HEIGHT = 0.5

local function tryCall(label, fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        Logging.error("[FlyoverEditor]: %s failed: %s", label, tostring(a))
        return false
    end
    return true, a, b, c
end

--- Clear the mod-global spline interpolation state.
---
--- AutoDrive:handleSplineCurvature (UtilFuncs.lua:1033) does
---     splineInterpolationUserCurvature = math.clamp(splineInterpolationUserCurvature + offset/12, ...)
--- guarded only by "splineInterpolation is valid", with no nil check on the curvature itself. That
--- hook sits on the top-down camera zoom, so leaving a valid interpolation behind with a nil
--- curvature made every subsequent mouse wheel throw - including the wheel events that run during
--- camera teardown and revertContext, which is how a stale spline turned into an editor that could
--- not exit and an input context that stayed pushed.
---
--- The two fields are therefore only ever cleared together, and never left half-set.
local function clearSplineState()
    AutoDrive.splineInterpolation = nil
    AutoDrive.splineInterpolationUserCurvature = nil
end

-- ---------------------------------------------------------------------------------------------
-- Track-to-track geometry.
--
-- Separation between two tracks is a PERPENDICULAR distance from a point to the other track's
-- polyline, not a distance between waypoints. Waypoints on two separately recorded tracks do not
-- line up: a point on one can sit midway between two points on the other, so the nearest-waypoint
-- distance reads several metres where the lanes are actually less than one apart. Measuring
-- point-to-point made the tool need a threshold wide enough to swallow a genuine two-lane road
-- before it would merge the two directions of a single-lane one.
-- ---------------------------------------------------------------------------------------------

--- Distance from a point to a line segment, and the closest point on it.
local function pointToSegment(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local lenSq = dx * dx + dz * dz
    if lenSq < 1e-9 then
        local ex, ez = px - ax, pz - az
        return math.sqrt(ex * ex + ez * ez), ax, az
    end
    -- Clamped projection, so a point beyond either end measures to that end rather than to the
    -- infinite line - otherwise two tracks that merely point at each other would measure as close.
    local t = ((px - ax) * dx + (pz - az) * dz) / lenSq
    t = math.max(0, math.min(1, t))
    local cx, cz = ax + dx * t, az + dz * t
    local ex, ez = px - cx, pz - cz
    return math.sqrt(ex * ex + ez * ez), cx, cz
end

--- Perpendicular distance from a point to a track, and the closest point on that track.
--- Also returns how far ALONG the track the closest point lies, which is what lets a set of
--- waypoints be put in track order without relying on them being connected to each other.
function ADFlyoverEditor:distanceToTrack(px, pz, orderedIds)
    local best, bx, bz, bestAlong = math.huge, nil, nil, 0
    local along = 0
    for i = 1, #orderedIds - 1 do
        local a = ADGraphManager:getWayPointById(orderedIds[i])
        local b = ADGraphManager:getWayPointById(orderedIds[i + 1])
        if a ~= nil and b ~= nil then
            local segLen = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
            local d, cx, cz = pointToSegment(px, pz, a.x, a.z, b.x, b.z)
            if d < best then
                best, bx, bz = d, cx, cz
                bestAlong = along + MathUtil.vector2Length(cx - a.x, cz - a.z)
            end
            along = along + segLen
        end
    end
    -- A single-waypoint track has no segments; fall back to the point itself.
    if best == math.huge and #orderedIds == 1 then
        local a = ADGraphManager:getWayPointById(orderedIds[1])
        if a ~= nil then
            local ex, ez = px - a.x, pz - a.z
            return math.sqrt(ex * ex + ez * ez), a.x, a.z
        end
    end
    return best, bx, bz, bestAlong
end

--- Put a run's waypoints in travel order so they can be treated as a polyline. Starts from an end
--- of the run where there is one; a closed loop has no end, so it starts at the seed.
function ADFlyoverEditor:orderRun(runSet, seedId)
    local function neighboursIn(id)
        local wp = ADGraphManager:getWayPointById(id)
        local result = {}
        if wp ~= nil then
            for _, listName in ipairs({ "out", "incoming" }) do
                for _, other in pairs(wp[listName] or {}) do
                    if runSet[other] and not table.contains(result, other) then
                        table.insert(result, other)
                    end
                end
            end
        end
        return result
    end

    local startId = seedId
    for id in pairs(runSet) do
        if #neighboursIn(id) <= 1 then
            startId = id
            break
        end
    end

    local ordered, visited = { startId }, { [startId] = true }
    local current = startId
    while true do
        local nextId = nil
        for _, other in ipairs(neighboursIn(current)) do
            if not visited[other] then
                nextId = other
                break
            end
        end
        if nextId == nil then
            break
        end
        visited[nextId] = true
        table.insert(ordered, nextId)
        current = nextId
    end

    return ordered
end

--- One line saying exactly which build is running.
---
--- FS25 does not hot-reload mod Lua, so a session started before a deploy is running the old code
--- while looking identical. Several reports this session turned out to be that rather than a bug,
--- and the only way to tell was comparing file timestamps against the log afterwards. Now the log
--- says so itself.
function ADFlyoverEditor:describeBuild()
    if ADBuildInfo == nil then
        return "build unknown (running from a working copy, not a packaged zip)"
    end
    return string.format("build %s%s, %s, \"%s\"",
        tostring(ADBuildInfo.commit),
        ADBuildInfo.dirty and " +uncommitted" or "",
        tostring(ADBuildInfo.built),
        tostring(ADBuildInfo.subject))
end

--- Describe the input binding's context state, however this game build exposes it.
---
--- The W key has died twice after extended editor use, while every enable/disable cycle logged a
--- clean "input context reverted". Something is leaking across cycles that the success message does
--- not cover, and guessing at it has failed twice. This reports whatever can actually be read, so a
--- leak shows up as a number that grows over a session rather than as a symptom noticed an hour
--- later.
function ADFlyoverEditor:describeInputState()
    local parts = {}

    -- Which context is restored depends on what the player was doing when the editor opened, so
    -- record it alongside the counts.
    local okVehicle, vehicle = pcall(function() return AutoDrive.getControlledVehicle() end)
    table.insert(parts, "inVehicle=" .. tostring(okVehicle and vehicle ~= nil))

    local function try(label, fn)
        local ok, value = pcall(fn)
        if ok and value ~= nil then
            table.insert(parts, string.format("%s=%s", label, tostring(value)))
        end
    end

    try("context", function() return g_inputBinding.currentContextName end)
    try("contexts", function()
        local n = 0
        for _ in pairs(g_inputBinding.contexts or {}) do
            n = n + 1
        end
        return n
    end)
    try("stackDepth", function() return #(g_inputBinding.contextStack or {}) end)
    try("events", function()
        local n = 0
        for _ in pairs(g_inputBinding.events or {}) do
            n = n + 1
        end
        return n
    end)
    try("nameActions", function()
        local n = 0
        for _ in pairs(g_inputBinding.nameActions or {}) do
            n = n + 1
        end
        return n
    end)
    try("cursor", function() return g_inputBinding:getShowMouseCursor() end)

    if #parts == 0 then
        return "input state not readable on this build"
    end
    return table.concat(parts, " ")
end

--- Last-resort recovery for a stranded input context, from the console.
---
--- Reverting more than once is normally wrong, which is why this is a deliberate command and not
--- something disable() does. It exists because the alternative has twice been restarting the game.
function ADFlyoverEditor:resetInput()
    Logging.info("[FlyoverEditor]: input state before reset - %s", self:describeInputState())

    if self.active then
        Logging.info("[FlyoverEditor]: still active; shutting down first.")
        self:disable()
    end

    for i = 1, 5 do
        local reverted = tryCall("revertContext " .. i, function() g_inputBinding:revertContext(false) end)
        if not reverted then
            break
        end
        Logging.info("[FlyoverEditor]: reverted a context (%d) - %s", i, self:describeInputState())
    end

    self.contextPushed = false
    Logging.info("[FlyoverEditor]: input state after reset - %s", self:describeInputState())
    Logging.info("[FlyoverEditor]: if movement is still dead, the gameplay action events are gone rather than shadowed, and only a reload restores them.")
end

function ADFlyoverEditor:isAvailable()
    return GuiTopDownCamera ~= nil and GuiTopDownCursor ~= nil
end

function ADFlyoverEditor:enable()
    -- COMPANION EDIT: refuse on a multiplayer client. Every graph write here passes
    -- sendEvent = false, and AutoDrive only writes the route file when g_server is present - so a
    -- client could edit for an hour and lose all of it with no signal. One refusal is better than
    -- eleven silent no-ops.
    if g_server == nil then
        Logging.warning("[FlyoverEditor] refusing to open on a multiplayer client: edits here are "
            .. "not sent to the server and would be lost. Host or single-player only.")
        return false
    end

    if self.active then
        Logging.info("[FlyoverEditor]: already active.")
        return
    end

    if not self:isAvailable() then
        Logging.error("[FlyoverEditor]: GuiTopDownCamera=%s GuiTopDownCursor=%s - the base game did not expose these, so the flyover editor cannot use this approach.",
            tostring(GuiTopDownCamera), tostring(GuiTopDownCursor))
        return
    end
    Logging.info("[FlyoverEditor]: GuiTopDownCamera and GuiTopDownCursor are both present.")
    -- Before ANYTHING is touched. Compared against the line printed after teardown, this is the
    -- only pair that says whether a cycle put the input system back as it found it. Logging only
    -- after the push, as the first version did, made a clean cycle indistinguishable from a lossy
    -- one.
    self.inputStateOnEnter = self:describeInputState()

    local okCam, camera = tryCall("GuiTopDownCamera.new", function() return GuiTopDownCamera.new() end)
    local okCur, cursor = tryCall("GuiTopDownCursor.new", function() return GuiTopDownCursor.new() end)
    if not okCam or not okCur or camera == nil or cursor == nil then
        return
    end
    self.camera, self.cursor = camera, cursor

    -- Start the camera over whatever the player is currently at, so the mode opens somewhere
    -- recognisable rather than at the map origin.
    local startX, startZ
    local vehicle = AutoDrive.getControlledVehicle()
    if vehicle ~= nil and vehicle.rootNode ~= nil then
        startX, _, startZ = getWorldTranslation(vehicle.rootNode)
    elseif g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil then
        startX, _, startZ = getWorldTranslation(g_localPlayer.rootNode)
    end
    if startX ~= nil then
        Logging.info("[FlyoverEditor]: camera will start at x=%.1f z=%.1f", startX, startZ)
    else
        Logging.warning("[FlyoverEditor]: no vehicle or player position to start the camera from; using the map default.")
    end

    -- Order matters: push the custom input context BEFORE registering the camera's action events,
    -- so they land in it rather than competing with the player's own WASD/wheel bindings.
    -- Third argument MUST stay false. Passing true clears the gameplay context's registered action
    -- events, and revertContext restores the context but not those events - so the player's WASD
    -- (and the rest of the gameplay bindings) stay dead for the remainder of the session. Pushing a
    -- context is already enough to stop the gameplay bindings firing while the mode is active;
    -- escape is handled by our own MENU_CANCEL/MENU_BACK events registered below. Courseplay's
    -- toggleCustomInputContext passes false here for the same reason.
    -- If a previous exit failed to revert, the context is still ours. Pushing a second one on top
    -- would need two reverts to undo and makes the stuck state worse, so reuse the one that is
    -- already there.
    if self.contextPushed then
        Logging.warning("[FlyoverEditor]: the input context from a previous session was never reverted; reusing it rather than pushing another.")
    end
    -- Create the context ONCE, then switch to it. The second argument asks for it to be created,
    -- and asking for a context that already exists is destructive: measured in game, the first call
    -- left the event count at 221 and a second took it to 210, destroying eleven of the player's
    -- own bindings, movement among them. That is why a short session was fine and repeated use was
    -- not - it needed a second activation, not a long one.
    local createContext = not self.contextCreated
    local pushed = self.contextPushed or tryCall("g_inputBinding:setContext", function()
        g_inputBinding:setContext(self.INPUT_CONTEXT, createContext, false)
    end)
    if pushed then
        self.contextCreated = true
    end
    self.contextPushed = pushed
    Logging.info("[FlyoverEditor]: custom input context '%s' pushed=%s", self.INPUT_CONTEXT, tostring(pushed))

    -- Activation happens AFTER the context push, not before it.
    --
    -- The rule already stated for registerActionEvents applies just as much here: an action event
    -- lands in whatever context is current when it is created. camera:activate() was being called
    -- while the GAMEPLAY context was still current, so anything it registered for itself - movement
    -- axes, in particular - was created there. Reverting our own context afterwards cannot remove
    -- those, and the camera is then deleted, leaving the player's movement bound to an object that
    -- no longer exists. Which is exactly the symptom: W dead until Tab re-enters a vehicle and
    -- re-registers, while Q, registered elsewhere, was unaffected.
    tryCall("camera:setTerrainRootNode", function() self.camera:setTerrainRootNode(g_terrainNode) end)
    tryCall("camera:activate", function() self.camera:activate() end)
    tryCall("cursor:activate", function() self.cursor:activate() end)

    if startX ~= nil then
        tryCall("camera:setCameraPosition", function() self.camera:setCameraPosition(startX, startZ) end)
    end

    if self.camera.registerActionEvents ~= nil then
        tryCall("camera:registerActionEvents", function() self.camera:registerActionEvents() end)
        Logging.info("[FlyoverEditor]: camera:registerActionEvents() called - WASD/zoom should now be the camera's.")
    else
        Logging.warning("[FlyoverEditor]: this GuiTopDownCamera has no registerActionEvents(); camera movement will have to be driven manually.")
    end

    local okGet, previous = pcall(function() return g_inputBinding:getShowMouseCursor() end)
    self.previousShowMouseCursor = okGet and previous or false
    Logging.info("[FlyoverEditor]: mouse cursor was %s on entry; camera:removeActionEvents is %s.",
        tostring(self.previousShowMouseCursor),
        self.camera.removeActionEvents ~= nil and "available" or "MISSING - the camera cannot unbind its own action events")

    -- Belt and braces on escape: an action event registered in our own context is the mechanism
    -- that can actually consume the key, where keyEvent below can only observe it. Registering
    -- both cancel-ish actions since which one Esc maps to varies by context.
    self.actionEventIds = {}
    for _, action in ipairs({ "MENU_CANCEL", "MENU_BACK" }) do
        if InputAction ~= nil and InputAction[action] ~= nil then
            tryCall("registerActionEvent " .. action, function()
                local _, id = g_inputBinding:registerActionEvent(InputAction[action], self,
                    function() self:onCancelAction(action) end, false, true, false, true)
                if id ~= nil then
                    table.insert(self.actionEventIds, id)
                end
            end)
        end
    end
    Logging.info("[FlyoverEditor]: registered %d cancel action event(s).", #self.actionEventIds)

    -- Free the mouse so it picks in the world; the camera keeps its own hold-middle/wheel bindings.
    tryCall("g_inputBinding:setShowMouseCursor(true)", function() g_inputBinding:setShowMouseCursor(true) end)

    self.active = true
    self.lastWaypointId = nil
    self.placedCount = 0
    self.loggedNoPosition = false
    -- Start clean: a selection or a half-dragged box left over from a previous session would be
    -- pointing at ids that may not mean the same thing any more.
    self:clearSelection()
    self.editing = nil
    self.elapsedMs = 0
    self.lastRightPressAt = nil
    self.boxActive = false
    self.boxStartX, self.boxStartZ = nil, nil
    ADEditorHistory:clear()
    Logging.info("[FlyoverEditor]: ACTIVE - %s", self:describeBuild())
end

function ADFlyoverEditor:disable()
    if not self.active then
        Logging.info("[FlyoverEditor]: not active.")
        return
    end

    -- FIRST, before touching the camera or the context. Tearing those down generates input events,
    -- and a stale spline makes those throw - which is exactly how teardown used to abort partway
    -- and leave the input context pushed with no way back.
    clearSplineState()

    if self.cursor ~= nil then
        tryCall("cursor:deactivate", function() self.cursor:deactivate() end)
        tryCall("cursor:delete", function() self.cursor:delete() end)
    end
    if self.camera ~= nil then
        -- camera:removeActionEvents() is deliberately NOT called while a context was pushed.
        --
        -- The player's W (movement) and Q (attach/detach) both stop responding after editor use,
        -- and come back when Tab re-enters a vehicle - which is exactly what re-registers the
        -- gameplay action events. Two explanations have already been wrong, both about the input
        -- context; the measurements showed the context name and event count returning to normal.
        --
        -- That leaves this. The camera's own removal appears to work by ACTION rather than by the
        -- ids it created, so removing its bindings for movement-shaped actions takes the player's
        -- bindings for those same actions with it. The events were registered into our context, so
        -- reverting that context drops them anyway and this call is redundant as well as harmful.
        --
        -- Without a pushed context there is nothing to revert, so it is still needed there.
        -- camera:removeActionEvents() is deliberately not called. It appears to remove by ACTION
        -- rather than by the ids the camera created, taking the player's bindings for those same
        -- actions with it - attach/detach stopped responding until this was dropped. The camera's
        -- events belong to our context and go when it is reverted.
        tryCall("camera:deactivate", function() self.camera:deactivate() end)
        tryCall("camera:delete", function() self.camera:delete() end)
    end

    if self.actionEventIds ~= nil then
        for _, id in ipairs(self.actionEventIds) do
            tryCall("removeActionEvent", function() g_inputBinding:removeActionEvent(id) end)
        end
        self.actionEventIds = nil
    end

    -- Restore input last, and in the reverse order it was taken: our own action events are gone by
    -- now, so the context can be popped without stranding any.
    -- The cursor decides what the mouse BUTTONS do, so leaving it on hands the player a session
    -- where right-click behaves like the camera drag.
    --
    -- The previous attempt asked isMouseActiveForHud(), which was simply the wrong question: it is
    --     return not g_gui:getIsGuiVisible() or ...
    -- so it is TRUE in all ordinary gameplay. It means "the mouse would be available to the HUD",
    -- not "the HUD wants the cursor", and asking it kept the cursor on exactly as before.
    --
    -- What actually governs the cursor is the showHUD setting - AutoDriveHud:toggleHud turns the
    -- cursor on when it enables the HUD and off when it disables it - so that is what to restore
    -- to. And the mod hides the cursor through hideMouseCursorOnNextTick (AutoDrive.lua:701)
    -- rather than calling setShowMouseCursor(false) directly, because doing it immediately while a
    -- menu is opening puts it back on; the same deferral is used here.
    local wantCursor = false
    local okHud, hudOn = pcall(function() return AutoDrive.getSetting("showHUD") end)
    if okHud then
        wantCursor = hudOn ~= nil and hudOn ~= false and hudOn ~= 0
    else
        wantCursor = self.previousShowMouseCursor == true
    end

    if wantCursor then
        tryCall("g_inputBinding:setShowMouseCursor(true)", function()
            g_inputBinding:setShowMouseCursor(true)
        end)
    else
        -- Deferred, the way the mod does it everywhere else.
        AutoDrive.hideMouseCursorOnNextTick = true
        tryCall("g_inputBinding:setShowMouseCursor(false)", function()
            g_inputBinding:setShowMouseCursor(false)
        end)
    end

    -- Leaving this set makes the mod swallow wheel events after the editor has gone.
    AutoDrive.mouseWheelActive = false
    Logging.info("[FlyoverEditor]: mouse cursor set to %s on exit (showHUD=%s, was %s on entry).",
        tostring(wantCursor), tostring(okHud and hudOn or "unreadable"), tostring(self.previousShowMouseCursor))
    if self.contextPushed then
        -- FALSE, not true. The argument was assumed to mean "clean up the events of the context
        -- being left", but the evidence says it clears the events of the context being RESTORED:
        -- the player's W key kept dying after extended editor use, every cycle logged a clean
        -- revert, and Tab-switching vehicles brought movement back - which is precisely what
        -- re-registers the gameplay action events. Destroyed, then rebuilt by the switch.
        --
        -- Nothing is leaked by passing false, because this editor already removes everything it
        -- registered: its own cancel events by id, just above, and the camera's through
        -- camera:removeActionEvents().
        --
        -- This is the same mistake as the setContext third argument fixed earlier: a boolean whose
        -- meaning was assumed rather than verified, quietly wiping the player's own bindings.
        local reverted = tryCall("g_inputBinding:revertContext", function() g_inputBinding:revertContext(false) end)
        if not reverted then
            -- Leaving the context pushed strands the player with no gameplay input at all, so this
            -- is worth one loud retry rather than a silent give-up.
            Logging.error("[FlyoverEditor]: reverting the input context failed. Retrying once - if this fails the flyover context is stuck and the game must be restarted.")
            reverted = tryCall("g_inputBinding:revertContext retry", function() g_inputBinding:revertContext(false) end)
        end
        -- Only forget the context if it actually came back off, so a later enable() can tell.
        self.contextPushed = not reverted
        if reverted then
            Logging.info("[FlyoverEditor]: input context reverted.")
        end
    end

    self.camera, self.cursor = nil, nil
    self.active = false
    Logging.info("[FlyoverEditor]: exited after placing %d waypoint(s).", self.placedCount)
    -- Compare this against the entry line of the NEXT activation. A count that climbs cycle after
    -- cycle is the leak; one that returns to where it started is not.
    -- Kept: this pair is one line each and would catch a regression of the input-context bug
    -- immediately. The per-call counters that found it were scaffolding and have been removed.
    local after = self:describeInputState()
    -- Anything different between those two lines is what this cycle leaked or destroyed. If they
    -- match and movement is still dead, the damage is not in the input binding at all and the next
    -- suspect is the camera or the cursor object rather than the context.
    -- Compare only the fields that can indicate DAMAGE, not the whole string. Measured across three
    -- sessions, a clean exit still differs in two harmless ways, and warning about them made the
    -- check cry wolf - which is worse than no check, because a real occurrence would be lost in it:
    --
    --   contexts  grows, because input contexts are created and never destroyed. Ours is created
    --             once (see contextCreated) but the count still only goes up over a session.
    --   cursor    ends up wherever AutoDrive's showHUD wants it, which the exit deliberately sets
    --             and is the correct behaviour, not a leak.
    --
    -- events and nameActions are the ones that matter. Every one of the four input-context bugs
    -- destroyed action events; none of them changed the context count.
    if self.inputStateOnEnter ~= nil then
        local function field(state, name)
            return tostring(state):match(name .. "=([^%s]+)")
        end
        local damaged = false
        for _, name in ipairs({ "events", "nameActions", "context", "stackDepth" }) do
            if field(self.inputStateOnEnter, name) ~= field(after, name) then
                damaged = true
            end
        end
        if damaged then
            Logging.warning("[FlyoverEditor]: the input system did not come back as it was found - "
                .. "action events or the context were lost. THIS is the one that strands movement keys.")
            Logging.warning("[FlyoverEditor]   before: %s", tostring(self.inputStateOnEnter))
            Logging.warning("[FlyoverEditor]   after:  %s", after)
        elseif after ~= self.inputStateOnEnter then
            Logging.info("[FlyoverEditor]: input restored; context count and cursor differ, which is "
                .. "expected. before: %s | after: %s", tostring(self.inputStateOnEnter), after)
        end
    end
end

function ADFlyoverEditor:toggle()
    if self.active then
        self:disable()
    else
        self:enable()
    end
end

function ADFlyoverEditor:endRun()
    if self.lastWaypointId == nil then
        return
    end
    Logging.info("[FlyoverEditor]: ended the run at waypoint id=%s; the next click starts a new one.",
        tostring(self.lastWaypointId))
    self.lastWaypointId = nil
end

function ADFlyoverEditor:onCancelAction(actionName)
    if not self.active or self:isGuiBlocking() then
        return
    end
    Logging.info("[FlyoverEditor]: exiting via the %s action event.", actionName)
    self:disable()
end

-- Fallback only. keyEvent can observe Esc but cannot consume it, so on its own it exits the mode
-- while the game still opens the menu; the action event above is what actually claims the key.
-- disable() is idempotent, so both firing is harmless.
--- True while a GUI dialog (the name dialog, a confirmation, the pause menu) has focus. The editor
--- has to stand down completely then: its keyEvent still fires while a dialog is up, so pressing
--- escape to dismiss the name dialog also tore down the whole editor, and clicks aimed at dialog
--- buttons would otherwise edit the world behind it.
function ADFlyoverEditor:isGuiBlocking()
    return g_gui ~= nil and g_gui.getIsGuiVisible ~= nil and g_gui:getIsGuiVisible()
end

function ADFlyoverEditor:keyEvent(unicode, sym, modifier, isDown)
    if not self.active or not isDown or self:isGuiBlocking() then
        return
    end
    if Input == nil then
        return
    end

    -- The number editor gets first refusal, so typing "5" into a field does not also switch to
    -- tool 5, and escape cancels the edit rather than closing the whole editor.
    if self:handleEditKey(unicode, sym) then
        return
    end

    -- Guarded throughout: a constant this game version does not expose would be nil, and every
    -- key would then compare equal to it - so an unguarded comparison fires on ANY keypress.
    local function isKey(name)
        return Input[name] ~= nil and sym == Input[name]
    end

    if isKey("KEY_esc") then
        Logging.info("[FlyoverEditor]: escape observed via keyEvent (fallback path).")
        self:disable()
        return
    end

    -- Tool selection on the number row. keyEvent only observes and cannot consume, which is fine
    -- here: nothing else is bound to these while the custom context is pushed.
    for tool = 1, #self.TOOL_NAMES do
        -- There is no KEY_10, so the tenth tool sits on 0 the way a number row runs.
        local keyName = (tool == 10) and "KEY_0" or ("KEY_" .. tool)
        if isKey(keyName) then
            self:setTool(tool)
            return
        end
    end

    -- Undo on Q, redo on E: left hand, next to the movement keys, and clear of everything the
    -- flyover camera registers into our context. That is the constraint that matters - not whether
    -- a key is free in gameplay, since a custom context is pushed. Ctrl+Z was unusable because the
    -- camera claims it: the player's own inputBinding.xml has CAMERA_ZOOM_IN_OUT on both KEY_z and
    -- KEY_lctrl KEY_z, and AXIS_CONSTRUCTION_CAMERA_ZOOM - which the flyover camera uses - on
    -- KEY_z. keyEvent can only observe a key, never consume it, so undo and zoom both fired.
    -- Apostrophe and semicolon stay as alternatives; nothing is bound to either.
    if isKey("KEY_q") or isKey("KEY_quote") or isKey("KEY_semicolon") then
        if ADEditorHistory:undo() ~= nil then
            -- The restore renumbers everything, so nothing that holds an id survives it.
            self:invalidateIdReferences()
        end
        return
    end

    if isKey("KEY_e") then
        if ADEditorHistory:redo() ~= nil then
            self:invalidateIdReferences()
        end
        return
    end

    -- Falloff radius for the move tool. The wheel is the camera's zoom and stays that way.
    if isKey("KEY_comma") then
        self:setFalloffRadius(self.falloffRadius - AutoDrive.FLYOVER_FALLOFF_STEP)
    elseif isKey("KEY_period") then
        self:setFalloffRadius(self.falloffRadius + AutoDrive.FLYOVER_FALLOFF_STEP)
    end
end

function ADFlyoverEditor:update(dt)
    if not self.active or self.camera == nil or self.cursor == nil then
        return
    end

    -- The editor's own clock. Advanced before the GUI check below, so time still passes while a
    -- dialog is open and a pause is not silently frozen.
    self.elapsedMs = (self.elapsedMs or 0) + (dt or 0)
    if self:isGuiBlocking() then
        return
    end

    tryCall("camera:update", function() self.camera:update(dt) end)
    tryCall("cursor:setCameraRay", function() self.cursor:setCameraRay(self.camera:getPickRay()) end)
    tryCall("cursor:update", function()
        if self.cursor.update ~= nil then self.cursor:update(dt) end
    end)

    -- Cache where the cursor is looking; the network drawing below centres on it. The y matters
    -- too: the cursor picks against the actual world surface, so on a ramp or an upper floor it
    -- already knows the height that a terrain lookup cannot see.
    local ok, x, y, z = pcall(function() return self.cursor:getPosition() end)
    if ok and x ~= nil and z ~= nil then
        self.cursorX, self.cursorZ, self.cursorY = x, z, y
    end

    self.hoverId = self:findWayPointNearCursor()
    self:updateFieldUnderCursor()

    if self.tool == self.TOOL.SPLINE then
        self:updateSplinePreview()
    elseif self.tool == self.TOOL.MERGE then
        self:updateMergePreview()
    elseif self.tool == self.TOOL.DIVIDE then
        self:updateDividePreview()
    elseif self.tool == self.TOOL.SIDING then
        self:updateSidingPreview()
    elseif self.tool == self.TOOL.PARALLEL then
        self:updateOffsetPreview()
    elseif self.tool == self.TOOL.STRAIGHTEN then
        self:updateStraightenPreview()
    elseif self.tool == self.TOOL.SMOOTH then
        self:updateSmoothPreview()
    end

    -- A drag updates live so the move is visible while the button is held, but no snapshot is
    -- taken here - that happened once, on press.
    if self.dragId ~= nil then
        self:updateDrag()
    end
end

--- Work out which field the cursor is over, for the panel.
---
--- Throttled by distance rather than run every frame: this goes through the farmland manager and
--- the answer cannot change while the cursor has not moved, so re-asking sixty times a second is
--- pure waste on a lookup that already costs more than anything else in this update.
function ADFlyoverEditor:updateFieldUnderCursor()
    if self.cursorX == nil then
        self.fieldLabel = nil
        return
    end

    if self.fieldQueryX ~= nil then
        local dx, dz = self.cursorX - self.fieldQueryX, self.cursorZ - self.fieldQueryZ
        if dx * dx + dz * dz < AutoDrive.FLYOVER_FIELD_QUERY_STEP * AutoDrive.FLYOVER_FIELD_QUERY_STEP then
            return
        end
    end
    self.fieldQueryX, self.fieldQueryZ = self.cursorX, self.cursorZ

    local label = nil
    local ok = pcall(function()
        if g_farmlandManager == nil then
            return
        end
        local farmland = g_farmlandManager:getFarmlandAtWorldPosition(self.cursorX, self.cursorZ)
        if farmland == nil then
            return
        end

        local field = farmland.getField ~= nil and farmland:getField() or nil
        if field ~= nil and field.fieldId ~= nil then
            label = "field " .. tostring(field.fieldId)
        elseif farmland.id ~= nil then
            -- Farmland with no field on it is still worth naming: it tells you the cursor is on
            -- owned land rather than off the map, which is the difference between "the field loop
            -- tool will not work here" and "you are pointing at nothing".
            label = "farmland " .. tostring(farmland.id) .. " (no field)"
        end
    end)

    self.fieldLabel = ok and label or nil
end

--- Nearest waypoint to the mouse, picked in SCREEN space.
---
--- A world-space radius is the wrong measure here: the camera zooms over a huge range, so a fixed
--- number of meters is grabby when zoomed in and almost unhittable when zoomed out. Screen space is
--- what the hand is actually aiming in, and it behaves the same at every zoom. The mod's own editor
--- picks this way too (Hud.lua uses project/g_lastMousePos).
---
--- Falls back to the world-space radius if project is unavailable or the mouse position is not
--- known yet, so picking degrades rather than stopping.
function ADFlyoverEditor:findWayPointNearCursor()
    if self.cursorX == nil then
        return nil
    end

    local wayPoints = ADGraphManager:getWayPoints()
    local searchRadiusSq = AutoDrive.FLYOVER_DRAW_RADIUS * AutoDrive.FLYOVER_DRAW_RADIUS

    if project ~= nil and g_lastMousePosX ~= nil and g_lastMousePosY ~= nil then
        local bestId, bestDistSq = nil, AutoDrive.FLYOVER_PICK_SCREEN_RADIUS * AutoDrive.FLYOVER_PICK_SCREEN_RADIUS
        for i = 1, #wayPoints do
            local wp = wayPoints[i]
            local wdx, wdz = wp.x - self.cursorX, wp.z - self.cursorZ
            -- Only project what is plausibly on screen; projecting the whole graph every frame is
            -- wasted work on a network of several thousand waypoints.
            if wdx * wdx + wdz * wdz < searchRadiusSq then
                local ok, sx, sy, depth = pcall(project, wp.x, wp.y + 0.5, wp.z)
                -- depth <= 0 means the point is behind the camera, where project still returns
                -- coordinates but mirrored ones - they would pick as if in front.
                if ok and sx ~= nil and depth ~= nil and depth > 0 then
                    local dx, dy = sx - g_lastMousePosX, sy - g_lastMousePosY
                    local distSq = dx * dx + dy * dy
                    if distSq < bestDistSq then
                        bestId, bestDistSq = wp.id, distSq
                    end
                end
            end
        end
        return bestId
    end

    local bestId, bestDistSq = nil, AutoDrive.FLYOVER_PICK_RADIUS * AutoDrive.FLYOVER_PICK_RADIUS
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        local dx, dz = wp.x - self.cursorX, wp.z - self.cursorZ
        local distSq = dx * dx + dz * dz
        if distSq < bestDistSq then
            bestId, bestDistSq = wp.id, distSq
        end
    end
    return bestId
end

function ADFlyoverEditor:setTool(tool)
    if self.tool == tool then
        return
    end
    self.tool = tool
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
    self.mergeFromId = nil
    self.mergeToId = nil
    self.divideFromId, self.divideToId, self.dividePreview = nil, nil, nil
    self.dragId = nil
    self.boxActive = false
    Logging.info("[FlyoverEditor]: tool -> %s", self.TOOL_NAMES[tool] or "none")
end

function ADFlyoverEditor:clearSelection()
    self.selection = {}
    self.selectionCount = 0
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
            Logging.info("[FlyoverEditor]: %s waypoint id=%s (%d selected).",
                self.selection[self.hoverId] and "selected" or "deselected", tostring(self.hoverId), self.selectionCount)
        end
        return
    end

    -- Shift adds to what is already selected; without it the box replaces the selection, which is
    -- the behaviour that makes a mis-aimed box cheap to correct.
    local additive = AutoDrive.leftLSHIFTmodifierKeyPressed == true or AutoDrive.rightSHIFTmodifierKeyPressed == true
    if not additive then
        self:clearSelection()
    end

    local minX, maxX = math.min(x0, x1), math.max(x0, x1)
    local minZ, maxZ = math.min(z0, z1), math.max(z0, z1)

    local added = 0
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if wp.x >= minX and wp.x <= maxX and wp.z >= minZ and wp.z <= maxZ and not self.selection[wp.id] then
            self.selection[wp.id] = true
            self.selectionCount = self.selectionCount + 1
            added = added + 1
        end
    end

    Logging.info("[FlyoverEditor]: box %s %d waypoint(s) over %.0fm x %.0fm (%d selected).",
        additive and "added" or "selected", added, maxX - minX, maxZ - minZ, self.selectionCount)
end

--- Ids shift whenever a waypoint is removed (GraphManager.lua:288), so anything holding an id has
--- to be dropped after a destructive edit rather than silently pointing at a different waypoint.
function ADFlyoverEditor:invalidateIdReferences()
    self:clearSelection()
    self.hoverId = nil
    self.smoothFromId, self.smoothToId = nil, nil
    self.smoothPreview, self.smoothPinned, self.smoothBlockedBy = nil, nil, nil
    self.splineFromId = nil
    self.mergeFromId = nil
    self.mergeToId = nil
    self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
    self.divideFromId, self.divideToId, self.dividePreview = nil, nil, nil
    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
    self.offsetFromId, self.offsetToId, self.offsetPreview = nil, nil, nil
    self.sidingAnchorId, self.sidingPreview = nil, nil
    self.smoothToId, self.smoothPreview, self.smoothPinned = nil, nil, nil
    self.dragId = nil
    self.lastWaypointId = nil
end

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

    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        local dx, dz = wp.x - self.cursorX, wp.z - self.cursorZ
        if (dx * dx + dz * dz) < radiusSq then
            ADDrawingManager:addSphereTask(wp.x, wp.y + 0.5, wp.z, 2, 1, 0.8, 0, 0.5)
            for _, targetId in pairs(wp.out or {}) do
                local target = ADGraphManager:getWayPointById(targetId)
                if target ~= nil then
                    ADDrawingManager:addLineTask(wp.x, wp.y + 0.5, wp.z,
                        target.x, target.y + 0.5, target.z, 1, 0, 1, 0)
                end
            end
        end
    end
end

function ADFlyoverEditor:drawNetwork()
    if self.cursorX == nil then
        return
    end

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
    local function accent(id, r, g, b, size)
        if id == nil then
            return
        end
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            ADDrawingManager:addSphereTask(wp.x, wp.y + 0.6, wp.z, size, r, g, b, 0.65)
        end
    end

    for id in pairs(self.selection) do
        accent(id, 0, 1, 0.2, 3.5)
    end
    accent(self.smoothFromId, 0, 0.6, 1, 4)
    accent(self.splineFromId, 0, 0.6, 1, 4)
    accent(self.mergeFromId, 1, 0.4, 0.9, 4)
    accent(self.mergeToId, 1, 0.4, 0.9, 4)

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
                pinned and 1 or 0, pinned and 0.5 or 1, pinned and 0 or 0.4, 0.8)
            if prev ~= nil then
                ADDrawingManager:addLineTask(prev.x, (prev.y or fallbackY) + 0.6, prev.z, p.x, py, p.z, 0, 1, 0.4, 1)
            end
            prev = p
        end
    end

    if self.tool == self.TOOL.SIDING and self.sidingPreview ~= nil then
        for i = 1, #self.sidingPreview do
            local p = self.sidingPreview[i]
            local py = (p.y or 0) + 0.6
            ADDrawingManager:addSphereTask(p.x, py, p.z, 2.5, 0.2, 0.8, 1, 0.6)
            if i > 1 then
                local q = self.sidingPreview[i - 1]
                ADDrawingManager:addLineTask(q.x, (q.y or 0) + 0.6, q.z, p.x, py, p.z, 1, 0.2, 0.8, 1)
            end
        end
    end

    if self.tool == self.TOOL.PARALLEL and self.offsetPreview ~= nil then
        for i = 1, #self.offsetPreview do
            local p = self.offsetPreview[i]
            local py = (p.y or 0) + 0.6
            ADDrawingManager:addSphereTask(p.x, py, p.z, 2.5, 1, 0.6, 0.1, 0.6)
            if i > 1 then
                local q = self.offsetPreview[i - 1]
                ADDrawingManager:addLineTask(q.x, (q.y or 0) + 0.6, q.z, p.x, py, p.z, 1, 1, 0.6, 0.1)
            end
        end
    end

    if self.tool == self.TOOL.STRAIGHTEN and self.straightenPreview ~= nil then
        for i = 1, #self.straightenPreview do
            local p = self.straightenPreview[i]
            local py = (p.y or 0) + 0.6
            ADDrawingManager:addSphereTask(p.x, py, p.z, 2.5, 0.4, 1, 0.4, 0.6)
            if i > 1 then
                local q = self.straightenPreview[i - 1]
                ADDrawingManager:addLineTask(q.x, (q.y or 0) + 0.6, q.z, p.x, py, p.z, 1, 0.4, 1, 0.4)
            end
        end
    end

    if self.tool == self.TOOL.DIVIDE and self.dividePreview ~= nil then
        local cursorGroundY = AutoDrive:getTerrainHeightAtWorldPos(self.cursorX, self.cursorZ)
        for i = 1, #self.dividePreview do
            local p = self.dividePreview[i]
            ADDrawingManager:addSphereTask(p.x, (p.y or cursorGroundY) + 0.6, p.z, 3, 0, 1, 0.4, 0.7)
            if i > 1 then
                local q = self.dividePreview[i - 1]
                ADDrawingManager:addLineTask(q.x, (q.y or cursorGroundY) + 0.6, q.z,
                    p.x, (p.y or cursorGroundY) + 0.6, p.z, 0, 1, 0.4, 1)
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
                1, 1, 1, 1)
        end
    end

    -- The box being dragged, drawn as four lines on the ground so it reads as a region rather
    -- than a screen overlay floating over the terrain.
    if self.boxActive and self.boxStartX ~= nil then
        local x0, z0 = self.boxStartX, self.boxStartZ
        local x1, z1 = self.cursorX, self.cursorZ
        local corners = { { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } }
        for i = 1, 4 do
            local a, b = corners[i], corners[(i % 4) + 1]
            ADDrawingManager:addLineTask(
                a[1], AutoDrive:getTerrainHeightAtWorldPos(a[1], a[2]) + 0.5, a[2],
                b[1], AutoDrive:getTerrainHeightAtWorldPos(b[1], b[2]) + 0.5, b[2],
                0, 1, 0.2, 1)
        end
    end

    -- Falloff ring, so the reach of a proportional move is visible before committing to it
    -- rather than being discovered from the result.
    if self.tool == self.TOOL.MOVE and self.falloffRadius > 0 then
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
                    0.2, 0.6, 1, 1)
            end
            prevX, prevZ = px, pz
        end
    end
end

function ADFlyoverEditor:mouseEvent(posX, posY, isDown, isUp, button)
    if not self.active or self.camera == nil or self.cursor == nil or self:isGuiBlocking() then
        return
    end

    -- The panel gets the event first. A header drag has to claim the WHOLE gesture, including the
    -- camera, or panning the camera and dragging the panel happen at the same time.
    if ADFlyoverHud:handleDrag(posX, posY, isDown, isUp, button) then
        return
    end

    -- The wheel, while a drag is in progress.
    --
    -- Normally the wheel reaches us as a camera ZOOM ACTION EVENT, which AutoDrive hooks and hands
    -- to handleWheel. That action does not fire while a mouse button is held down - measured: a
    -- four-second drag produced no wheel events at all, while scrolling with nothing held produced
    -- six in as many seconds. So the one path the falloff wheel depended on is precisely the one
    -- that is dead for the whole time it is wanted.
    --
    -- Mouse events still arrive during a drag - that is how dragging works - so take the wheel from
    -- here instead. Restricted to a live drag on purpose: outside one the action path works and
    -- handles it, and claiming it in both places would apply every notch twice.
    if isDown and self.dragId ~= nil then
        local wheelUp = Input.MOUSE_BUTTON_WHEEL_UP ~= nil and button == Input.MOUSE_BUTTON_WHEEL_UP
        local wheelDown = Input.MOUSE_BUTTON_WHEEL_DOWN ~= nil and button == Input.MOUSE_BUTTON_WHEEL_DOWN
        if wheelUp or wheelDown then
            self:handleWheel(wheelUp and 1 or -1)
            return
        end
    end

    tryCall("camera:mouseEvent", function() self.camera:mouseEvent(posX, posY, isDown, isUp, button) end)

    -- Track the press ourselves and act only on a genuine down->up transition. Acting on isUp
    -- alone stacked 15-26 waypoints on a single spot per click (87 placements across 9 distinct
    -- positions in testing), so isUp here is evidently not the one-shot edge it looks like.
    if button == 1 then
        if isDown then
            -- The panel takes the click before any tool sees it. Checked on the press so the
            -- matching release is swallowed too, rather than a button press turning into a
            -- waypoint placed on the terrain underneath the panel.
                -- An edit in progress is abandoned by clicking anywhere other than into it. Without
            -- this, clicking a number field and then clicking away left the edit live forever, and
            -- because handleEditKey swallows EVERY key while editing, the whole keyboard stopped
            -- responding - undo, the tool numbers, all of it - with nothing on screen to say why.
            local wasEditing = self.editing ~= nil

            if ADFlyoverHud:onClick(posX, posY) then
                self.panelClaimedClick = true
                return
            end
            self.panelClaimedClick = false

            if wasEditing and self.editing ~= nil then
                self:cancelEditNumber()
            end
            self.leftDown = true
            self:onLeftPress()
        elseif isUp then
            if self.panelClaimedClick then
                self.panelClaimedClick = false
                return
            end
            if self.leftDown then
                self:onLeftRelease()
            end
            self.leftDown = false
        end
    elseif button == 3 then
        -- Secondary action of the current tool. For place-waypoint that means "end this run", so
        -- the next click starts a new one instead of dragging a connection across the map.
        -- Deliberately not a timeout: a chain that breaks on its own would break exactly while
        -- lining up the next click, making the result depend on how fast you happen to work.
        if isDown then
            self.rightDown = true
        elseif isUp then
            if self.rightDown then
                self:onRightRelease()
            end
            self.rightDown = false
        end
    end
end

function ADFlyoverEditor:onLeftPress()
    -- Ctrl claims the drag for box selection, in every tool. It has to be decided here on the
    -- press, before the move tool can grab a waypoint, or a Ctrl+drag starting on top of one
    -- would move it instead of selecting.
    if AutoDrive.leftCTRLmodifierKeyPressed == true then
        self.boxActive = true
        self.boxStartX, self.boxStartZ = self.cursorX, self.cursorZ
        return
    end

    -- Only the move tool cares about the press itself; every other tool acts on release, so that
    -- a click that turns out to be a camera drag does not commit an edit.
    if self.tool == self.TOOL.MOVE and self.hoverId ~= nil then
        self:beginDrag(self.hoverId)
    end
end

function ADFlyoverEditor:onLeftRelease()
    -- Ctrl builds a selection, whatever the tool. Selection is a shared substrate rather than a
    -- tool of its own: the multi-point operations all need it, so building one should not mean
    -- leaving the tool you are working with.
    if self.boxActive then
        self:finishBoxSelect()
        return
    end

    if self.tool == self.TOOL.DRAW then
        self:drawClick()
    elseif self.tool == self.TOOL.MOVE then
        self:finishDrag()
    elseif self.tool == self.TOOL.DELETE then
        self:deleteAtCursor()
    elseif self.tool == self.TOOL.SMOOTH then
        self:smoothClick()
    elseif self.tool == self.TOOL.NAME then
        self:nameAtCursor()
    elseif self.tool == self.TOOL.SPLINE then
        self:splineClick()
    elseif self.tool == self.TOOL.MERGE then
        self:mergeClick()
    elseif self.tool == self.TOOL.FIELDLOOP then
        self:generateFieldLoopAtCursor()
    elseif self.tool == self.TOOL.CONVERT then
        self:convertAtCursor()
    elseif self.tool == self.TOOL.SIDING then
        self:sidingClick()
    elseif self.tool == self.TOOL.PARALLEL then
        self:offsetClick()
    elseif self.tool == self.TOOL.STRAIGHTEN then
        self:straightenClick()
    elseif self.tool == self.TOOL.DIVIDE then
        self:divideClick()
    end
end

--- Right-click backs out one level at a time.
---
---   1st press - stop whatever the tool is doing: commit a preview, cancel a pending span, end a
---               run, drop a selection.
---   2nd press - leave the tool entirely, so no tool is selected and clicks do nothing.
---
--- The second press only counts after a pause. Without that, finishing a span and then
--- right-clicking again out of habit would drop the tool immediately, which is a surprising way to
--- lose your place. A deliberate "I am done here" is a separate press, not part of the same flurry.
function ADFlyoverEditor:onRightRelease()
    local now = self:nowMs()
    local sincePrevious = (self.lastRightPressAt ~= nil) and (now - self.lastRightPressAt) or nil
    self.lastRightPressAt = now

    if self:stopCurrentAction() then
        return
    end

    if self.selectionCount > 0 then
        self:clearSelection()
        Logging.info("[FlyoverEditor]: selection cleared.")
        return
    end

    if self.tool == self.TOOL.NONE then
        return
    end

    if sincePrevious == nil or sincePrevious < AutoDrive.FLYOVER_TOOL_EXIT_DELAY then
        -- Too soon to be deliberate. Say so, or it looks like right-click simply stopped working.
        Logging.info("[FlyoverEditor]: nothing in progress (%.0fms since the last right-click, need %.0fms) - press again to put the %s tool away.",
            sincePrevious or 0, AutoDrive.FLYOVER_TOOL_EXIT_DELAY, self.TOOL_NAMES[self.tool] or "current")
        return
    end

    Logging.info("[FlyoverEditor]: put the %s tool away; no tool selected.", self.TOOL_NAMES[self.tool] or "current")
    self:setTool(self.TOOL.NONE)
end

--- Milliseconds since the editor was opened.
---
--- Counted from the dt handed to update() rather than read from a global. The first version tried
--- g_currentMission.time, then g_time, then os.clock, and got none of them - so it returned a
--- constant 0, every interval computed as 0, and the "second press after a pause" could never
--- happen. Presses 4.8 seconds apart were still being told to wait.
---
--- dt is already delivered every frame and needs no engine field to exist, so it cannot fail the
--- same way.
function ADFlyoverEditor:nowMs()
    return self.elapsedMs or 0
end

--- Stop whatever the current tool has in progress. Returns true if there was something to stop.
function ADFlyoverEditor:stopCurrentAction()
    local tool = self.tool

    if tool == self.TOOL.DRAW then
        if self.lastWaypointId ~= nil then
            self:endRun()
            return true
        end
    elseif tool == self.TOOL.SIDING then
        if self.sidingAnchorId ~= nil then
            self:commitSiding()
            return true
        end
    elseif tool == self.TOOL.PARALLEL then
        if self.offsetToId ~= nil then
            self:commitOffset()
            return true
        elseif self.offsetFromId ~= nil then
            self:cancelOffset()
            return true
        end
    elseif tool == self.TOOL.STRAIGHTEN then
        if self.straightenToId ~= nil then
            self:commitStraighten()
            return true
        elseif self.straightenFromId ~= nil then
            self:cancelStraighten()
            return true
        end
    elseif tool == self.TOOL.SMOOTH then
        if self.smoothToId ~= nil then
            self:commitSmooth()
            return true
        elseif self.smoothFromId ~= nil then
            self:cancelSmooth()
            return true
        end
    elseif tool == self.TOOL.SPLINE then
        if self.splineToId ~= nil then
            self:commitSplinePreview()
            return true
        elseif self.splineFromId ~= nil then
            self:cancelSplinePreview()
            return true
        end
    elseif tool == self.TOOL.DIVIDE then
        if self.divideToId ~= nil then
            self:commitDivide()
            return true
        elseif self.divideFromId ~= nil then
            self:cancelDivide()
            return true
        end
    elseif tool == self.TOOL.MERGE then
        if self.mergeFromId ~= nil or self.mergeToId ~= nil then
            Logging.info("[FlyoverEditor]: cancelled the pending merge.")
            self.mergeFromId, self.mergeToId = nil, nil
            self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
            return true
        end
    elseif tool == self.TOOL.MOVE then
        if self.dragId ~= nil then
            self:finishDrag()
            return true
        end
    end

    return false
end

-- ---------------------------------------------------------------------------------------------
-- Move, with distance-weighted falloff on the neighbours.
-- ---------------------------------------------------------------------------------------------

--- How far each waypoint is from the seed ALONG THE TRACK, out to maxDistance.
---
--- Distance along the track, not straight-line distance. Where a track loops back past itself, the
--- other limb can be a metre away in space while being a hundred metres away along the route -
--- a straight-line falloff drags it along with the grabbed point and tears the loop apart. Walking
--- the connections makes that impossible: the far limb is only reached by travelling the whole way
--- round, so it falls outside the radius on its own.
---
--- The walk includes a junction but does not continue through it: past a junction the points
--- belong to another route, and dragging those is never what moving this one means.
function ADFlyoverEditor:collectAlongTrack(seedId, maxDistance)
    local distance = { [seedId] = 0 }
    local frontier = { seedId }

    while #frontier > 0 do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                local neighbours = {}
                for _, listName in ipairs({ "out", "incoming" }) do
                    for _, other in pairs(wp[listName] or {}) do
                        if other ~= id and not table.contains(neighbours, other) then
                            table.insert(neighbours, other)
                        end
                    end
                end

                if #neighbours <= 2 or id == seedId then
                    for _, other in ipairs(neighbours) do
                        local ow = ADGraphManager:getWayPointById(other)
                        if ow ~= nil then
                            local step = MathUtil.vector2Length(ow.x - wp.x, ow.z - wp.z)
                            local d = distance[id] + step
                            -- Keep the shortest route to each point, so a track that closes into a
                            -- loop is measured the short way round rather than by whichever
                            -- direction happened to arrive first.
                            if d <= maxDistance and (distance[other] == nil or d < distance[other]) then
                                distance[other] = d
                                table.insert(nextFrontier, other)
                            end
                        end
                    end
                end
            end
        end
        frontier = nextFrontier
    end

    return distance
end

function ADFlyoverEditor:beginDrag(id)
    local wp = ADGraphManager:getWayPointById(id)
    if wp == nil then
        return
    end

    ADEditorHistory:snapshot("move waypoint")

    self.dragId = id
    self.dragStartX, self.dragStartZ = wp.x, wp.z

    -- Precompute which neighbours move and by how much. Same raised-cosine weighting the field
    -- loop generator uses for tree detours: weight 1 at the grabbed point falling smoothly to 0 at
    -- the falloff distance, with zero gradient at both ends, so the run stays smooth instead of
    -- developing a kink where the influence stops.
    self:gatherDragNeighbours()

    Logging.info("[FlyoverEditor]: grabbed waypoint id=%s (falloff %.1fm along the track, %d waypoint(s) following).",
        tostring(id), self.falloffRadius, #self.dragNeighbours)
end

--- Work out which waypoints follow the grab, and how strongly.
---
--- Records each follower's CURRENT position, which the drag then offsets from. It therefore has to
--- be called with everything sitting where it started - see setFalloffRadius, which restores before
--- re-gathering, or the recorded origins would be positions the drag had already moved.
function ADFlyoverEditor:gatherDragNeighbours()
    self.dragNeighbours = {}
    local radius = self.falloffRadius
    if self.dragId == nil or radius <= 0 then
        return
    end

    local alongTrack = self:collectAlongTrack(self.dragId, radius)
    for otherId, d in pairs(alongTrack) do
        if otherId ~= self.dragId then
            local other = ADGraphManager:getWayPointById(otherId)
            if other ~= nil then
                table.insert(self.dragNeighbours, {
                    id = otherId,
                    x = other.x,
                    z = other.z,
                    weight = 0.5 * (1 + math.cos(math.pi * d / radius))
                })
            end
        end
    end
end

--- Change the falloff, live during a drag if one is in progress.
---
--- Mid-drag this cannot simply re-gather: the followers have already been displaced, so their
--- current positions are not the origins the new set should measure from, and re-gathering over the
--- top would compound the offsets every time the wheel moved. Everything is put back first - the
--- grabbed point included, since the run's shape through it decides the along-track distances -
--- then the new set is gathered and the drag re-applied.
function ADFlyoverEditor:setFalloffRadius(value)
    value = math.max(0, math.min(AutoDrive.FLYOVER_FALLOFF_MAX, value))
    if value == self.falloffRadius then
        return
    end

    if self.dragId == nil then
        self.falloffRadius = value
        Logging.info("[FlyoverEditor]: falloff %.1fm along the track.", value)
        return
    end

    for _, n in ipairs(self.dragNeighbours or {}) do
        self:moveTo(n.id, n.x, n.z)
    end
    if self.dragStartX ~= nil then
        self:moveTo(self.dragId, self.dragStartX, self.dragStartZ)
    end

    self.falloffRadius = value
    self:gatherDragNeighbours()
    self:updateDrag()

    Logging.info("[FlyoverEditor]: falloff %.1fm along the track, %d waypoint(s) following.",
        value, #self.dragNeighbours)
end

function ADFlyoverEditor:updateDrag()
    if self.cursorX == nil or self.dragStartX == nil then
        return
    end

    local deltaX = self.cursorX - self.dragStartX
    local deltaZ = self.cursorZ - self.dragStartZ

    -- The grabbed point goes where the cursor is pointing, height included - that is what puts it
    -- on a ramp rather than on the ground below it. Followers keep to whatever surface they are
    -- already on.
    self:moveTo(self.dragId, self.cursorX, self.cursorZ, nil, self.cursorY)
    for _, n in ipairs(self.dragNeighbours or {}) do
        self:moveTo(n.id, n.x + deltaX * n.weight, n.z + deltaZ * n.weight)
    end
end

--- Move one waypoint in the horizontal plane, re-resolving its height from the terrain. Heights
--- must be re-resolved rather than carried along: a point dragged across a slope would otherwise
--- keep the elevation it had where the drag started and end up buried or floating.
--- Height at x,z interpolated along an existing chain of points.
---
--- Resampling a span has to take its heights from the span it came from, not from one end of it.
--- Every preview passed the FIRST point's height as the reference to
--- AutoDrive:getTerrainHeightAtWorldPos, whose ray starts at reference+3 and reaches only 5m down -
--- so anywhere on a slope the far end sat outside that window, the ray found nothing, and the
--- function handed back its own start height. The result was a row of preview dots all at the
--- elevation of the point the span started from.
---
--- Interpolating along the original chain is also what keeps a span that runs onto a ramp or a
--- bridge at the right height, since those points already carry it.
local function heightAlongChain(pts, x, z)
    local bestDistSq, bestY = math.huge, nil

    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local lenSq = dx * dx + dz * dz

        local t = 0
        if lenSq > 1e-9 then
            t = ((x - a.x) * dx + (z - a.z) * dz) / lenSq
            t = math.max(0, math.min(1, t))
        end

        local cx, cz = a.x + dx * t, a.z + dz * t
        local ex, ez = x - cx, z - cz
        local distSq = ex * ex + ez * ez

        if distSq < bestDistSq then
            bestDistSq = distSq
            bestY = (a.y or 0) + ((b.y or a.y or 0) - (a.y or 0)) * t
        end
    end

    return bestY or (pts[1] ~= nil and pts[1].y or nil)
end

--- Height for a waypoint at x,z.
---
--- Measured in game on a building ramp:
---     cursor reports 121.13   plain terrain 120.37
---     ray from cursor 120.37  ray from 30m up 150.37
---
--- Three things follow. The CURSOR can see the ramp - it reads a metre above the terrain there,
--- and exactly terrain height on open ground. AutoDrive:getTerrainHeightAtWorldPos CANNOT: its
--- raycast uses CollisionFlag.DEFAULT + ROAD + TERRAIN, which does not pick up the building, so it
--- returned the terrain even when told to start from the cursor's height. And starting the ray
--- higher is useless because it only casts 5m - from 30m up it hit nothing and handed back its own
--- start height.
---
--- So the cursor's height is used directly rather than being fed to a raycast that discards it.
--- `explicitY` is that value, passed for the point being placed or dragged, which is the only one
--- actually under the cursor.
---
--- For everything else - the followers in a proportional move - there is no cursor reading. A point
--- already sitting well above the terrain is on a structure the raycast cannot see, so re-grounding
--- it would drop it through the ramp it is standing on; those keep the height they have. Points at
--- terrain level are re-grounded normally.
function ADFlyoverEditor:resolveHeightAt(x, z, referenceY, explicitY)
    local terrainY = nil
    if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z)
    end

    if self.snapToTerrain then
        return terrainY or AutoDrive:getTerrainHeightAtWorldPos(x, z)
    end

    if explicitY ~= nil then
        return explicitY
    end

    if referenceY ~= nil and terrainY ~= nil
        and (referenceY - terrainY) > AutoDrive.FLYOVER_STRUCTURE_HEIGHT then
        -- On a structure. Nothing available here can see it, so leave the height alone.
        return referenceY
    end

    return AutoDrive:getTerrainHeightAtWorldPos(x, z, referenceY)
end

--- Move one waypoint in the horizontal plane and put it back on the surface.
---
--- `referenceY` says which surface: the cursor's own pick height for the waypoint being dragged,
--- and each follower's current height for the rest, so a run partly on a ramp stays on the ramp
--- instead of half of it falling to the ground.
function ADFlyoverEditor:moveTo(id, x, z, referenceY, explicitY)
    local wp = ADGraphManager:getWayPointById(id)
    if wp == nil then
        return
    end
    local y = self:resolveHeightAt(x, z, referenceY or wp.y, explicitY)
    ADGraphManager:moveWayPoint(id, x, y, z, wp.flags, false)
end

function ADFlyoverEditor:finishDrag()
    if self.dragId == nil then
        return
    end

    -- Re-ground everything that moved, at its final position and with the accurate raycast. During
    -- the drag the height only has to look right while the point is in flight; where it comes to
    -- rest is what actually matters, and the last frame of a drag is not necessarily where the
    -- button was released.
    local dropped = ADGraphManager:getWayPointById(self.dragId)
    if dropped ~= nil then
        -- Report every height source at the drop point. Whether the cursor can even see a ramp is
        -- the open question: GuiTopDownCursor may pick against the terrain only, in which case
        -- referencing it cannot help and the height has to come from somewhere else.
        local beforeY = dropped.y
        local terrainY = (g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil)
            and getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, dropped.x, 1, dropped.z) or nil
        local fromCursor = self.cursorY ~= nil
            and AutoDrive:getTerrainHeightAtWorldPos(dropped.x, dropped.z, self.cursorY) or nil
        local fromAbove = terrainY ~= nil
            and AutoDrive:getTerrainHeightAtWorldPos(dropped.x, dropped.z, terrainY + 30) or nil

        self:moveTo(self.dragId, dropped.x, dropped.z, dropped.y, self.cursorY)

        Logging.info("[FlyoverEditor]: heights at the drop point - cursor reports %s, plain terrain %s, ray from cursor %s, ray from 30m up %s, was %.2f, set to %.2f.",
            self.cursorY ~= nil and string.format("%.2f", self.cursorY) or "nil",
            terrainY ~= nil and string.format("%.2f", terrainY) or "nil",
            fromCursor ~= nil and string.format("%.2f", fromCursor) or "nil",
            fromAbove ~= nil and string.format("%.2f", fromAbove) or "nil",
            beforeY, dropped.y)
    end
    for _, n in ipairs(self.dragNeighbours or {}) do
        local wp = ADGraphManager:getWayPointById(n.id)
        if wp ~= nil then
            self:moveTo(n.id, wp.x, wp.z, wp.y)
        end
    end

    local moved = 1 + #(self.dragNeighbours or {})
    Logging.info("[FlyoverEditor]: moved %d waypoint(s) ending at id=%s, re-grounded at the drop point.",
        moved, tostring(self.dragId))
    self.dragId, self.dragStartX, self.dragStartZ, self.dragNeighbours = nil, nil, nil, nil
    ADGraphManager:markChanges()
end

-- ---------------------------------------------------------------------------------------------
-- Connect / disconnect two existing waypoints.
-- ---------------------------------------------------------------------------------------------

--- The draw tool. One click, and what it does depends on what is under the cursor:
---
---   empty ground           create a waypoint, joined to the open end of the run
---   a waypoint, no run     start the run there, creating nothing
---   a waypoint, run open   toggle the connection between the run and it, then carry on from there
---
--- The toggle is AutoDrive own, and its DIRECTIONAL semantics are why this needs no separate
--- disconnect mode. Given an existing A->B, clicking A then B removes it, while clicking B then A
--- adds B->A and so makes the pair two-way. That is the rule stock AutoDrive editor already
--- follows, so it should be familiar rather than something new to learn here.
function ADFlyoverEditor:drawClick()
    -- Nothing under the cursor: this is a placement.
    if self.hoverId == nil then
        self:placeWaypointAtCursor()
        return
    end

    -- A waypoint, and no run open: start from it rather than stacking a duplicate on top of it.
    if self.lastWaypointId == nil then
        self.lastWaypointId = self.hoverId
        Logging.info("[FlyoverEditor]: run starts at existing waypoint id=%s; click on to draw from it.",
            tostring(self.lastWaypointId))
        return
    end

    if self.lastWaypointId == self.hoverId then
        Logging.info("[FlyoverEditor]: cannot connect a waypoint to itself.")
        return
    end

    local startNode = ADGraphManager:getWayPointById(self.lastWaypointId)
    local endNode = ADGraphManager:getWayPointById(self.hoverId)
    if startNode == nil or endNode == nil then
        self.lastWaypointId = nil
        return
    end

    local reverseDirection, dualConnection = self:getConnectionOptions()

    ADEditorHistory:snapshot("toggle connection")
    ADGraphManager:toggleConnectionBetween(startNode, endNode, reverseDirection, dualConnection, false)

    Logging.info("[FlyoverEditor]: toggled the connection %s -> %s (dual=%s reverse=%s).",
        tostring(self.lastWaypointId), tostring(self.hoverId), tostring(dualConnection), tostring(reverseDirection))

    -- Carry the run on from the waypoint just clicked, so a route can be drawn straight through an
    -- existing junction without stopping to re-anchor it.
    self.lastWaypointId = self.hoverId
end

-- ---------------------------------------------------------------------------------------------
-- Delete.
-- ---------------------------------------------------------------------------------------------

ADFlyoverEditor.OFFSET_SCOPE = { SPAN = 1, RUN = 2 }
ADFlyoverEditor.OFFSET_SCOPE_NAMES = { "picked span", "whole run" }

function ADFlyoverEditor:flipOffsetSide()
    self.offsetSide = -(self.offsetSide or 1)
    self.offsetCache = nil
    Logging.info("[FlyoverEditor]: offset side -> %s.", self.offsetSide >= 0 and "left" or "right")
end

function ADFlyoverEditor:cycleOffsetScope()
    self.offsetScope = (self.offsetScope % #self.OFFSET_SCOPE_NAMES) + 1
    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
    Logging.info("[FlyoverEditor]: offset covers the %s.", self.OFFSET_SCOPE_NAMES[self.offsetScope])
end

ADFlyoverEditor.DELETE_SCOPE = { POINT = 1, RUN = 2 }
ADFlyoverEditor.DELETE_SCOPE_NAMES = { "one waypoint", "whole run" }

-- ---------------------------------------------------------------------------------------------
-- Typed numeric entry.
--
-- The mod's settings are lists of discrete values driven by arrow steppers, which is slow and
-- imprecise for a number you already know. Typing it is faster than stepping to it. The value
-- still has to land on one of the setting's steps - that is how AutoDrive stores and saves
-- settings, and going around it would mean a value that does not survive a reload - so a typed
-- number snaps to the nearest step and says so when it moved.
-- ---------------------------------------------------------------------------------------------

--- Which numbers a tool exposes. Each entry says how to read the current value and how to apply a
--- typed one, so settings and plain editor fields can sit side by side in the same list.
function ADFlyoverEditor:getEditableNumbers()
    local editor = self
    local function settingEntry(label, name, unit)
        return {
            label = label,
            unit = unit or "m",
            get = function() return ADFlyoverSettings.get(name) end,
            apply = function(value) return editor:applySettingValue(name, value) end
        }
    end

    if self.tool == self.TOOL.SIDING then
        -- Both persist, so a siding shape settled on once stays settled. The wheel drives the
        -- length because that is what changes per site; the offset is typed here.
        return {
            settingEntry("offset", "sidingOffset"),
            settingEntry("length", "sidingLength")
        }
    end

    if self.tool == self.TOOL.FIELDLOOP then
        return {
            settingEntry("margin", "fieldLoopMargin"),
            settingEntry("tree clearance", "fieldLoopTreeClearance"),
            settingEntry("turning radius", "fieldLoopTurningRadius"),
            settingEntry("vehicle height", "fieldLoopVehicleHeight")
        }
    elseif self.tool == self.TOOL.SMOOTH and self.smoothMode == self.SMOOTH_MODE.REBUILD then
        return { {
            label = "max spacing",
            unit = "m",
            get = function() return editor.smoothSpacing end,
            apply = function(value)
                editor.smoothSpacing = math.max(AutoDrive.FLYOVER_SPACING_MIN,
                    math.min(AutoDrive.FLYOVER_SPACING_MAX, value))
                return editor.smoothSpacing
            end
        } }
    elseif self.tool == self.TOOL.MERGE then
        return {
            settingEntry("merge distance", "flyoverMergeDistance"),
            settingEntry("divergence", "flyoverMergeDivergence")
        }
    elseif self.tool == self.TOOL.MOVE then
        return { {
            label = "falloff along track",
            unit = "m",
            get = function() return editor.falloffRadius end,
            apply = function(value)
                editor:setFalloffRadius(value)
                return editor.falloffRadius
            end
        } }
    end
    return {}
end

--- Snap a typed value onto the nearest step the setting actually allows, and store it there.
function ADFlyoverEditor:applySettingValue(name, value)
    local setting = ADFlyoverSettings.settings[name]
    if setting == nil or setting.values == nil then
        return nil
    end

    local bestIndex, bestDiff = nil, math.huge
    for i, v in ipairs(setting.values) do
        local diff = math.abs(v - value)
        if diff < bestDiff then
            bestIndex, bestDiff = i, diff
        end
    end
    if bestIndex == nil then
        return nil
    end

    return ADFlyoverSettings.setIndex(name, bestIndex)
end

function ADFlyoverEditor:beginEditNumber(entry)
    if self.editing ~= nil and self.editing.label ~= entry.label then
        self:cancelEditNumber()
    end
    local current = entry.get()
    self.editing = {
        label = entry.label,
        unit = entry.unit,
        apply = entry.apply,
        buffer = ""
    }
    Logging.info("[FlyoverEditor]: editing '%s' (currently %s). Type a value, Enter to apply, Esc to cancel.",
        entry.label, tostring(current))
end

function ADFlyoverEditor:cancelEditNumber()
    self.editingWarned = false
    if self.editing ~= nil then
        Logging.info("[FlyoverEditor]: '%s' left unchanged.", self.editing.label)
    end
    self.editing = nil
end

function ADFlyoverEditor:commitEditNumber()
    self.editingWarned = false
    local edit = self.editing
    self.editing = nil
    if edit == nil then
        return
    end

    local typed = tonumber(edit.buffer)
    if typed == nil then
        Logging.warning("[FlyoverEditor]: '%s' is not a number; '%s' left unchanged.",
            tostring(edit.buffer), edit.label)
        return
    end

    local applied = edit.apply(typed)
    if applied == nil then
        Logging.warning("[FlyoverEditor]: could not apply %s to '%s'.", tostring(typed), edit.label)
    elseif math.abs(applied - typed) > 1e-6 then
        Logging.info("[FlyoverEditor]: '%s' set to %.2f%s - the nearest step to the %.2f typed.",
            edit.label, applied, edit.unit or "", typed)
    else
        Logging.info("[FlyoverEditor]: '%s' set to %.2f%s.", edit.label, applied, edit.unit or "")
    end
end

--- Returns true if the key was taken by the number editor.
function ADFlyoverEditor:handleEditKey(unicode, sym)
    if self.editing == nil then
        return false
    end

    -- Every key goes to the field while one is open, so this state has to be obvious. The panel
    -- shows the field highlighted with a caret; this is the log half of the same message.
    if not self.editingWarned then
        Logging.info("[FlyoverEditor]: typing into '%s' - the keyboard goes to this field until Enter or Esc, or a click elsewhere.",
            self.editing.label)
        self.editingWarned = true
    end

    local function isKey(name)
        return Input ~= nil and Input[name] ~= nil and sym == Input[name]
    end

    if isKey("KEY_return") or isKey("KEY_KP_enter") then
        self:commitEditNumber()
        return true
    end
    if isKey("KEY_esc") then
        self:cancelEditNumber()
        return true
    end
    if isKey("KEY_backspace") then
        self.editing.buffer = string.sub(self.editing.buffer, 1, -2)
        return true
    end

    -- Digits, one decimal point and a leading minus, which is all a distance or a radius needs.
    if unicode ~= nil and unicode >= 32 and unicode < 127 then
        local ch = string.char(unicode)
        local buffer = self.editing.buffer
        local ok = false
        if ch >= "0" and ch <= "9" then
            ok = true
        elseif ch == "." and not string.find(buffer, ".", 1, true) then
            ok = true
        elseif ch == "-" and buffer == "" then
            ok = true
        end
        if ok and #buffer < 8 then
            self.editing.buffer = buffer .. ch
        end
        return true
    end

    return true
end

function ADFlyoverEditor:toggleSnapToTerrain()
    self.snapToTerrain = not self.snapToTerrain
    Logging.info("[FlyoverEditor]: heights now snap to %s.",
        self.snapToTerrain and "the terrain, ignoring structures" or "whatever surface is there")
end

function ADFlyoverEditor:cycleDeleteScope()
    self.deleteScope = (self.deleteScope % #self.DELETE_SCOPE_NAMES) + 1
    Logging.info("[FlyoverEditor]: delete removes %s.", self.DELETE_SCOPE_NAMES[self.deleteScope])
end

--- Every waypoint on the run through seedId, out to the junctions at either end.
---
--- A junction - a waypoint with more than two distinct neighbours - is where this run ends and
--- another begins, so the walk includes it but does not continue through it. Deleting the junction
--- itself would sever the routes that meet there, so it is deliberately left in place and only the
--- stretch between junctions is removed. A closed loop has no junctions at all and simply comes
--- back to the seed, which the visited set terminates.
function ADFlyoverEditor:collectRunBetweenJunctions(seedId)
    local function neighboursOf(id)
        local wp = ADGraphManager:getWayPointById(id)
        local list = {}
        if wp ~= nil then
            for _, listName in ipairs({ "out", "incoming" }) do
                for _, other in pairs(wp[listName] or {}) do
                    if other ~= id and not table.contains(list, other) then
                        table.insert(list, other)
                    end
                end
            end
        end
        return list
    end

    local run = { [seedId] = true }
    local junctions = {}
    local count = 1
    local frontier = { seedId }

    while #frontier > 0 and count < AutoDrive.FLYOVER_DELETE_RUN_MAX do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            for _, other in ipairs(neighboursOf(id)) do
                if not run[other] and not junctions[other] then
                    if #neighboursOf(other) > 2 then
                        -- The run ends here. Keep the junction; it belongs to the routes crossing.
                        junctions[other] = true
                    else
                        run[other] = true
                        count = count + 1
                        table.insert(nextFrontier, other)
                    end
                end
            end
        end
        frontier = nextFrontier
    end

    local junctionCount = 0
    for _ in pairs(junctions) do
        junctionCount = junctionCount + 1
    end
    return run, count, junctionCount, junctions
end

function ADFlyoverEditor:deleteRunAtCursor()
    local run, count, junctionCount = self:collectRunBetweenJunctions(self.hoverId)

    if count >= AutoDrive.FLYOVER_DELETE_RUN_MAX then
        Logging.warning("[FlyoverEditor]: that run reaches %d waypoints, at or past the safety cap - refusing rather than deleting most of the network. Cut it at a junction first.", count)
        return
    end

    ADEditorHistory:snapshot("delete run")

    local ids = {}
    for id in pairs(run) do
        table.insert(ids, id)
    end
    -- Highest first: removal renumbers everything above it.
    table.sort(ids, function(a, b) return a > b end)
    for _, id in ipairs(ids) do
        ADGraphManager:removeWayPoint(id, false)
    end

    Logging.info("[FlyoverEditor]: deleted a run of %d waypoint(s), stopping at %d junction(s), which were left in place.",
        #ids, junctionCount)
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:deleteAtCursor()
    -- A selection wins over the hovered point: having built one up, a click should act on it
    -- rather than quietly deleting whatever happened to be under the cursor.
    if self.selectionCount > 0 then
        self:deleteSelection()
        return
    end

    if self.hoverId == nil then
        return
    end

    if self.deleteScope == self.DELETE_SCOPE.RUN then
        self:deleteRunAtCursor()
        return
    end

    ADEditorHistory:snapshot("delete waypoint")
    local doomed = ADGraphManager:getWayPointById(self.hoverId)
    local px, pz = doomed ~= nil and doomed.x or 0, doomed ~= nil and doomed.z or 0
    ADGraphManager:removeWayPoint(self.hoverId, false)
    -- Position as well as id: removal renumbers, so deleting a run one point at a time reports the
    -- same id over and over and looks like a stuck loop when it is working correctly.
    Logging.info("[FlyoverEditor]: deleted waypoint id=%s at x=%.1f z=%.1f (%d left).",
        tostring(self.hoverId), px, pz, ADGraphManager:getWayPointsCount())
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:deleteSelection()
    ADEditorHistory:snapshot("delete selection")

    -- Delete from the highest id down. Removal renumbers every id ABOVE the one removed, so
    -- descending order means each pending id is still valid when its turn comes.
    local ids = {}
    for id in pairs(self.selection) do
        table.insert(ids, id)
    end
    table.sort(ids, function(a, b) return a > b end)

    for _, id in ipairs(ids) do
        ADGraphManager:removeWayPoint(id, false)
    end

    Logging.info("[FlyoverEditor]: deleted %d selected waypoint(s).", #ids)
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:placeWaypointAtCursor()
    if g_server == nil then
        Logging.error("[FlyoverEditor]: waypoints can only be placed on the server (host/singleplayer).")
        return
    end

    local ok, x, y, z = tryCall("cursor:getPosition", function() return self.cursor:getPosition() end)
    if not ok or x == nil or z == nil then
        -- Only log this once: if the cursor never resolves a position it will do so every frame.
        if not self.loggedNoPosition then
            Logging.warning("[FlyoverEditor]: cursor:getPosition() returned no world position - the camera/cursor pair is not resolving a pick ray outside a GUI screen.")
            self.loggedNoPosition = true
        end
        return
    end

    -- Always take the height from the terrain rather than trusting the cursor's y. The rest of the
    -- mod places waypoints this way (buildFieldLoopRing resolves every point through
    -- getTerrainHeightAtWorldPos) and those render correctly, so this keeps placement consistent
    -- with known-good behaviour instead of depending on what reference the cursor's y is in.
    local terrainY = self:resolveHeightAt(x, z, y, y)
    if not self.loggedHeightComparison then
        Logging.info("[FlyoverEditor]: height check - cursor y=%s, terrain y=%.2f (using terrain).",
            y ~= nil and string.format("%.2f", y) or "nil", terrainY)
        self.loggedHeightComparison = true
    end
    y = terrainY

    -- Sticky options from the panel rather than modifiers held during the click.
    local reverseDirection, dualConnection, flags = self:getConnectionOptions()

    ADEditorHistory:snapshot("place waypoint")

    local connectPrevious = self.lastWaypointId ~= nil
    local wp = ADGraphManager:recordWayPoint(
        x, y, z,
        connectPrevious,
        dualConnection,
        reverseDirection,
        self.lastWaypointId or 0,
        flags,
        false
    )

    local newId = (wp ~= nil and wp.id) or ADGraphManager:getWayPointsCount()
    self.lastWaypointId = newId
    self.placedCount = self.placedCount + 1

    ADGraphManager:markChanges()
    Logging.info("[FlyoverEditor]: placed waypoint id=%s at x=%.1f y=%.1f z=%.1f%s",
        tostring(newId), x, y, z, connectPrevious and " (connected to the previous one)" or "")
end

function ADFlyoverEditor:draw()
    if not self.active then
        return
    end

    tryCall("drawNetwork", function() self:drawNetwork() end)

    tryCall("flyoverPanel", function() ADFlyoverHud:draw(self) end)
end

-- ---------------------------------------------------------------------------------------------
-- Smooth / normalise a span between two waypoints.
-- ---------------------------------------------------------------------------------------------

ADFlyoverEditor.SMOOTH_MODE = { RELAX = 1, REBUILD = 2 }
ADFlyoverEditor.SMOOTH_MODE_NAMES = { "relax (move points)", "rebuild (respace)" }
AutoDrive.FLYOVER_SMOOTH_MAX = 30
-- Rebuild respaces, so the number worth having on the wheel there is the spacing, not a strength.
AutoDrive.FLYOVER_SPACING_MIN = 1.0
AutoDrive.FLYOVER_SPACING_MAX = 25.0
AutoDrive.FLYOVER_SPACING_STEP = 0.5
-- How close a waypoint must be to a remembered position to be considered the same one. Anchors do
-- not move during a rebuild, so this only has to absorb floating point noise.
AutoDrive.FLYOVER_ANCHOR_TOLERANCE = 0.05
-- How long after the previous right-click before another one puts the tool away, in milliseconds.
-- Only has to separate a deliberate second press from an accidental double-click - a double-click
-- is typically under 250ms - so it wants to be as short as will do that. A second felt like the
-- tool was ignoring the press.
AutoDrive.FLYOVER_TOOL_EXIT_DELAY = 350

function ADFlyoverEditor:cycleSmoothMode()
    self.smoothMode = (self.smoothMode % #self.SMOOTH_MODE_NAMES) + 1
    self.smoothPreview = nil
    Logging.info("[FlyoverEditor]: smooth mode -> %s.", self.SMOOTH_MODE_NAMES[self.smoothMode])
end

function ADFlyoverEditor:smoothClick()
    if self.hoverId == nil then
        return
    end

    if self.smoothFromId == nil then
        self.smoothFromId = self.hoverId
        Logging.info("[FlyoverEditor]: smoothing from id=%s; click the far end of the span.", tostring(self.smoothFromId))
        return
    end

    if self.smoothToId == nil then
        if self.hoverId == self.smoothFromId then
            return
        end
        self.smoothToId = self.hoverId
        Logging.info("[FlyoverEditor]: smoothing id=%s..id=%s in %s mode. Wheel sets %s, right-click applies.",
            tostring(self.smoothFromId), tostring(self.smoothToId),
            self.SMOOTH_MODE_NAMES[self.smoothMode],
            self.smoothMode == self.SMOOTH_MODE.REBUILD and "max spacing" or "strength")
        return
    end

    if self.hoverId ~= self.smoothFromId then
        self.smoothToId = self.hoverId
        self.smoothPreview = nil
        Logging.info("[FlyoverEditor]: span far end moved to id=%s. Right-click to clear and start again.",
            tostring(self.smoothToId))
    end
end

function ADFlyoverEditor:cancelSmooth()
    if self.smoothFromId ~= nil or self.smoothToId ~= nil then
        Logging.info("[FlyoverEditor]: smooth cancelled.")
    end
    self.smoothFromId, self.smoothToId = nil, nil
    self.smoothPreview, self.smoothPinned, self.smoothBlockedBy = nil, nil, nil
end

--- Work out what the span would look like, without changing anything.
---
--- Relax mode MOVES the existing waypoints and never adds or removes any, which is what makes it
--- safe on a real network: no connection is broken and no map marker is lost, so nothing has to be
--- refused. Junctions inside the span are pinned - moving one would drag the routes that meet
--- there - and so are both ends unless asked otherwise.
---
--- Rebuild mode is the old behaviour: delete the interior and lay down a respaced chain. It is
--- more powerful and less safe, and it still has to refuse a span containing a junction or marker.
function ADFlyoverEditor:updateSmoothPreview()
    if self.smoothFromId == nil or self.smoothToId == nil then
        self.smoothPreview = nil
        return
    end

    -- runPathBetween, NOT ADGraphManager:pathFromTo. pathFromTo is AutoDrive's route finder: it
    -- respects one-way, can route the long way round, and its result need not even begin at the
    -- waypoint that was clicked. That is what produced the nonsense refusal "id=8506 connects to
    -- id=8505 outside the span" when 8505 was the span's own start point.
    local ids = self:runPathBetween(self.smoothFromId, self.smoothToId)
    if ids == nil or #ids < 3 then
        self.smoothPreview = nil
        self.smoothBlockedBy = nil
        return
    end

    local pts = {}
    for i = 1, #ids do
        local wp = ADGraphManager:getWayPointById(ids[i])
        if wp == nil then
            self.smoothPreview = nil
            return
        end
        pts[i] = { x = wp.x, y = wp.y, z = wp.z }
    end

    if self.smoothMode == self.SMOOTH_MODE.RELAX then
        local inSpan = {}
        for _, id in ipairs(ids) do
            inSpan[id] = true
        end

        -- Pin anything that must not move: junctions, and the ends unless included.
        local pinned = {}
        for i = 2, #ids - 1 do
            local wp = ADGraphManager:getWayPointById(ids[i])
            if wp ~= nil then
                for _, listName in ipairs({ "out", "incoming" }) do
                    for _, other in pairs(wp[listName] or {}) do
                        if not inSpan[other] then
                            pinned[i] = true
                        end
                    end
                end
            end
        end

        self.smoothPinned = pinned
        self.smoothPreview = ADOffsetGeometry.relaxOpenChain(pts, self.smoothStrength, pinned)
        self.smoothPreviewIds = ids
    else
        -- Spacing comes from the wheel. The minimum tracks it rather than being fixed, so that
        -- asking for coarse spacing does not still leave dense points through the corners - the
        -- whole run gets coarser, which is what dialling it up is asking for.
        local maxSpacing = self.smoothSpacing
        local minSpacing = math.max(AutoDrive.FIELD_LOOP_ADAPTIVE_MIN_SPACING, maxSpacing * 0.25)

        local smoothed = ADOffsetGeometry.smoothOpenChain(pts, 2, AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG, 180)
        local resampled = ADOffsetGeometry.resampleOpenChainByCurvature(smoothed,
            minSpacing, maxSpacing, AutoDrive.FIELD_LOOP_ADAPTIVE_TOLERANCE)
        -- relaxOpenChain, not smoothOpenChain, for the tidying pass. smoothOpenChain REFINES -
        -- it inserts a midpoint after every eligible point - which immediately halves the spacing
        -- that was just asked for. Requesting 15m produced 2.2m average for exactly that reason.
        -- relax tucks the points without adding any, so the requested spacing survives.
        local finalPts = ADOffsetGeometry.relaxOpenChain(resampled, 1, {})

        -- Give every point a height. smoothOpenChain and resampleOpenChainByCurvature are 2D and
        -- return {x, z} only, so without this the preview had no y at all and was drawn at ground
        -- zero - a hundred-odd metres under the terrain, i.e. invisible. Relax mode never showed
        -- the problem because relaxOpenChain carries y through.
        for i = 1, #finalPts do
            finalPts[i].y = self:resolveHeightAt(finalPts[i].x, finalPts[i].z,
                heightAlongChain(pts, finalPts[i].x, finalPts[i].z))
        end

        self.smoothPreview = finalPts
        self.smoothPreviewIds = ids
        self.smoothPinned = nil
    end

    -- Rebuild deletes and replaces the interior, so it cannot cross a junction or a marker. Work
    -- that out now, while previewing, so the panel can say why - rather than leaving right-click
    -- to do nothing visible and explain itself only in the log.
    -- Rebuild splits at junctions rather than refusing, so nothing blocks it any more.
    self.smoothBlockedBy = nil
end

--- What would stop a span being deleted and rebuilt, as a short reason, or nil if nothing does.
function ADFlyoverEditor:findSpanBlocker(ids)
    local inChain = {}
    for _, id in ipairs(ids) do
        inChain[id] = true
    end
    for i = 2, #ids - 1 do
        local id = ids[i]
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            for _, listName in ipairs({ "out", "incoming" }) do
                for _, other in pairs(wp[listName] or {}) do
                    if not inChain[other] then
                        -- Name the other end too. "junction at id N" alone is not checkable
                        -- against what is on screen; the id it connects to is what makes it
                        -- possible to see whether the junction is real. Note that the span comes
                        -- from a SHORTEST path, so a shortcut link can make the path skip a
                        -- waypoint, and the skipped one then looks like an outside connection.
                        return string.format("id %d connects to id %d outside the span", id, other)
                    end
                end
            end
            if ADGraphManager:getMapMarkerByWayPointId(id) ~= nil then
                return string.format("map marker at id %d", id)
            end
        end
    end
    return nil
end

function ADFlyoverEditor:commitSmooth()
    local ids = self.smoothPreviewIds
    local newPoints = self.smoothPreview
    if ids == nil or newPoints == nil or #ids < 3 then
        self:cancelSmooth()
        return
    end

    if self.smoothMode == self.SMOOTH_MODE.RELAX then
        ADEditorHistory:snapshot("relax span")
        local moved = 0
        for i = 2, #ids - 1 do
            if not (self.smoothPinned or {})[i] then
                local p = newPoints[i]
                if p ~= nil then
                    self:moveTo(ids[i], p.x, p.z)
                    moved = moved + 1
                end
            end
        end
        Logging.info("[FlyoverEditor]: relaxed %d of %d waypoint(s) at strength %d; %d pinned (junctions or ends).",
            moved, #ids, self.smoothStrength, #ids - moved)
        ADGraphManager:markChanges()
        self.smoothFromId, self.smoothToId = nil, nil
        self.smoothPreview, self.smoothPinned = nil, nil
        self:invalidateIdReferences()
        return
    end

    ADEditorHistory:snapshot("rebuild span")
    self:rebuildSpanInPieces(ids)
    self.smoothFromId, self.smoothToId = nil, nil
    self.smoothPreview, self.smoothPinned = nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

--- Rebuild a span, splitting it at any junction or marker rather than refusing the whole thing.
---
--- Rebuild deletes and re-creates the interior, so it genuinely cannot pass through a waypoint that
--- something else is attached to - a junction onto another route, or a map marker. It used to
--- refuse the entire span for that reason, which on a well-connected network meant it could almost
--- never be applied: every span of any length crosses something.
---
--- Splitting is the way out. Each junction-free piece between two anchors is rebuilt on its own and
--- the anchors themselves are left untouched, so the routes meeting there survive.
---
--- Ids renumber on every delete (GraphManager.lua:288), so the anchors are located by POSITION
--- before anything is touched and re-found by position between pieces. Carrying ids across the
--- rebuilds would mean each piece corrupting the addresses of the ones after it.
--- The positions of everything in a span that must survive a rebuild: the two ends, plus any
--- interior waypoint another route or a map marker is attached to.
---
--- Returned as POSITIONS, not ids. Ids renumber on every delete (GraphManager.lua:288), so a piece
--- being rebuilt would corrupt the addresses of every piece after it. Positions do not move.
---
--- These are the waypoints AutoDrive itself draws as right-of-way centres - Specialization.lua:1674
--- flags a point with `#out >= 1 and #incoming >= 2`, excluding plain single-to-dual, dual-to-single
--- and straight-dual transitions. In the editor they are the pale blue spheres.
function ADFlyoverEditor:collectSpanAnchors(ids)
    local inChain = {}
    for _, id in ipairs(ids) do
        inChain[id] = true
    end

    local positions, interiorAnchors = {}, 0
    local function record(id)
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            table.insert(positions, { x = wp.x, z = wp.z })
        end
    end

    record(ids[1])
    for i = 2, #ids - 1 do
        local id = ids[i]
        local wp = ADGraphManager:getWayPointById(id)
        local isAnchor = false
        if wp ~= nil then
            for _, listName in ipairs({ "out", "incoming" }) do
                for _, other in pairs(wp[listName] or {}) do
                    if not inChain[other] then
                        isAnchor = true
                    end
                end
            end
            if ADGraphManager:getMapMarkerByWayPointId(id) ~= nil then
                isAnchor = true
            end
        end
        if isAnchor then
            record(id)
            interiorAnchors = interiorAnchors + 1
        end
    end
    record(ids[#ids])

    return positions, interiorAnchors
end

function ADFlyoverEditor:rebuildSpanInPieces(ids)
    local anchorPositions, junctions = self:collectSpanAnchors(ids)

    local maxSpacing = self.smoothSpacing
    local minSpacing = math.max(AutoDrive.FIELD_LOOP_ADAPTIVE_MIN_SPACING, maxSpacing * 0.25)

    local piecesDone, before, after = 0, 0, 0

    -- Backwards, so a piece being rebuilt cannot renumber the anchors of a piece not yet reached.
    for i = #anchorPositions - 1, 1, -1 do
        local startId = self:findWayPointAt(anchorPositions[i])
        local endId = self:findWayPointAt(anchorPositions[i + 1])
        if startId ~= nil and endId ~= nil and startId ~= endId then
            local piece = self:runPathBetween(startId, endId)
            if piece ~= nil and #piece > 2 then
                local pts = {}
                for j = 1, #piece do
                    local wp = ADGraphManager:getWayPointById(piece[j])
                    if wp ~= nil then
                        pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
                    end
                end

                local smoothed = ADOffsetGeometry.smoothOpenChain(pts, 2, AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG, 180)
                local resampled = ADOffsetGeometry.resampleOpenChainByCurvature(smoothed,
                    minSpacing, maxSpacing, AutoDrive.FIELD_LOOP_ADAPTIVE_TOLERANCE)
                local finalPts = ADOffsetGeometry.relaxOpenChain(resampled, 1, {})

                for j = 1, #finalPts do
                    finalPts[j].y = self:resolveHeightAt(finalPts[j].x, finalPts[j].z,
                        heightAlongChain(pts, finalPts[j].x, finalPts[j].z))
                end

                local a = ADGraphManager:getWayPointById(piece[1])
                local b = ADGraphManager:getWayPointById(piece[2])
                local dual = ADGraphManager:isDualRoad(a, b)
                local flags = b.flags or AutoDrive.FLAG_NONE

                before = before + #piece
                after = after + #finalPts
                if self:replaceChainInterior(piece, finalPts, dual, flags) then
                    piecesDone = piecesDone + 1
                end
            end
        end
    end

    if piecesDone == 0 then
        Logging.info("[FlyoverEditor]: nothing to rebuild - the span is all anchors, or too short between them.")
        return
    end

    Logging.info("[FlyoverEditor]: rebuilt %d piece(s) at %.1fm max spacing: %d point(s) -> %d, %d junction/marker anchor(s) kept in place.",
        piecesDone, maxSpacing, before, after, junctions)
end

--- Divide a span, splitting it at anchors the same way rebuild does.
---
--- The requested count is shared out between the pieces in proportion to their length, so asking
--- for N points across a span that happens to cross an intersection still gives roughly N points
--- overall and even spacing throughout - rather than refusing, which is what it did before.
function ADFlyoverEditor:divideSpanInPieces(ids, totalCount)
    local anchorPositions, anchors = self:collectSpanAnchors(ids)

    -- Measure every piece first, so the count can be shared out by length.
    local pieces, totalLength = {}, 0
    for i = 1, #anchorPositions - 1 do
        local startId = self:findWayPointAt(anchorPositions[i])
        local endId = self:findWayPointAt(anchorPositions[i + 1])
        local piece = (startId ~= nil and endId ~= nil and startId ~= endId)
            and self:runPathBetween(startId, endId) or nil

        local length = 0
        if piece ~= nil then
            for j = 2, #piece do
                local a = ADGraphManager:getWayPointById(piece[j - 1])
                local b = ADGraphManager:getWayPointById(piece[j])
                if a ~= nil and b ~= nil then
                    length = length + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
                end
            end
        end

        pieces[i] = { length = length }
        totalLength = totalLength + length
    end

    if totalLength <= 0 then
        Logging.info("[FlyoverEditor]: nothing to divide.")
        return
    end

    local placed, done = 0, 0

    -- Back to front, so a piece cannot renumber the anchors of one not yet reached.
    for i = #anchorPositions - 1, 1, -1 do
        local share = math.floor(totalCount * (pieces[i].length / totalLength) + 0.5)

        local startId = self:findWayPointAt(anchorPositions[i])
        local endId = self:findWayPointAt(anchorPositions[i + 1])
        if startId ~= nil and endId ~= nil and startId ~= endId then
            local piece = self:runPathBetween(startId, endId)
            if piece ~= nil and #piece >= 2 then
                local newPoints = self:evenlySpacedAlong(piece, share)
                if newPoints ~= nil and self:replaceChainInterior(piece, newPoints, self:spanStyle(piece)) then
                    placed = placed + share
                    done = done + 1
                end
            end
        end
    end

    Logging.info("[FlyoverEditor]: divided %d piece(s) into %d point(s) total, %d intersection anchor(s) kept in place.",
        done, placed, anchors)
end

--- Whether a span is dual, and what flags it carries, taken from its first connection.
function ADFlyoverEditor:spanStyle(ids)
    local a = ADGraphManager:getWayPointById(ids[1])
    local b = ADGraphManager:getWayPointById(ids[2])
    if a == nil or b == nil then
        return false, AutoDrive.FLAG_NONE
    end
    return ADGraphManager:isDualRoad(a, b), b.flags or AutoDrive.FLAG_NONE
end

--- `count` points spread evenly by arc length between the two ends of a span, ends included.
function ADFlyoverEditor:evenlySpacedAlong(ids, count)
    local pts = {}
    for _, id in ipairs(ids) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
        end
    end
    if #pts < 2 then
        return nil
    end

    local cumulative = { 0 }
    for i = 2, #pts do
        cumulative[i] = cumulative[i - 1] + MathUtil.vector2Length(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z)
    end
    local total = cumulative[#pts]
    if total <= 0 then
        return nil
    end

    local function pointAt(distance)
        for i = 2, #pts do
            if cumulative[i] >= distance then
                local segLen = cumulative[i] - cumulative[i - 1]
                local f = segLen > 0 and (distance - cumulative[i - 1]) / segLen or 0
                return {
                    x = pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f,
                    z = pts[i - 1].z + (pts[i].z - pts[i - 1].z) * f
                }
            end
        end
        return { x = pts[#pts].x, z = pts[#pts].z }
    end

    local result = { { x = pts[1].x, y = pts[1].y, z = pts[1].z } }
    for i = 1, count do
        local p = pointAt(total * i / (count + 1))
        p.y = self:resolveHeightAt(p.x, p.z, heightAlongChain(pts, p.x, p.z))
        result[#result + 1] = p
    end
    result[#result + 1] = { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }
    return result
end

--- The waypoint at a remembered position, or nil. Used to re-find anchors after a rebuild has
--- renumbered everything around them.
function ADFlyoverEditor:findWayPointAt(pos)
    local best, bestSq = nil, AutoDrive.FLYOVER_ANCHOR_TOLERANCE * AutoDrive.FLYOVER_ANCHOR_TOLERANCE
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        local dx, dz = wp.x - pos.x, wp.z - pos.z
        local d = dx * dx + dz * dz
        if d < bestSq then
            best, bestSq = wp.id, d
        end
    end
    return best
end

--- Delete the interior of a chain and lay down newPoints in its place, keeping the two endpoints
--- where they are so the span stays attached to the rest of the network.
--- Which way the span's first connection actually runs. runPathBetween returns a traversal order,
--- which is not necessarily the direction the connection was drawn in - and rebuilding always lays
--- connections in that order, so a span traversed against its own direction came back reversed.
local function spanRunsForward(chainIds)
    local a = ADGraphManager:getWayPointById(chainIds[1])
    local b = ADGraphManager:getWayPointById(chainIds[2])
    if a == nil or b == nil then
        return true
    end
    if table.contains(a.out, b.id) then
        return true -- forward, or dual, in which case either answer rebuilds correctly
    end
    if table.contains(b.out, a.id) then
        return false -- one-way, against the traversal
    end
    return true
end

--- Drop any direct connection between the two ends, in either direction.
local function severEnds(aId, bId)
    local a = ADGraphManager:getWayPointById(aId)
    local b = ADGraphManager:getWayPointById(bId)
    if a == nil or b == nil then
        return
    end
    if table.contains(a.out, b.id) then
        ADGraphManager:toggleConnectionBetween(a, b, false, false, false)
    end
    if table.contains(b.out, a.id) then
        ADGraphManager:toggleConnectionBetween(b, a, false, false, false)
    end
end

function ADFlyoverEditor:replaceChainInterior(chainIds, newPoints, dual, flags)
    -- Rebuild in the direction the span actually ran, not the direction it happened to be walked
    -- in. Reversing both arrays together keeps newPoints aligned with chainIds.
    if not spanRunsForward(chainIds) then
        local rc, rp = {}, {}
        for i = #chainIds, 1, -1 do rc[#rc + 1] = chainIds[i] end
        for i = #newPoints, 1, -1 do rp[#rp + 1] = newPoints[i] end
        chainIds, newPoints = rc, rp
    end

    local startId, endId = chainIds[1], chainIds[#chainIds]

    local doomed = {}
    for i = 2, #chainIds - 1 do
        table.insert(doomed, chainIds[i])
    end
    table.sort(doomed, function(a, b) return a > b end)

    for _, id in ipairs(doomed) do
        ADGraphManager:removeWayPoint(id, false)
    end

    -- Every removal renumbers the ids above it, so the endpoints have almost certainly moved.
    -- Their new ids are their old ones less the number of deleted points that sat below them:
    -- exact, and cheaper than trying to find them again by position.
    local function shifted(id)
        local shift = 0
        for _, deletedId in ipairs(doomed) do
            if deletedId < id then
                shift = shift + 1
            end
        end
        return id - shift
    end
    local newStartId, newEndId = shifted(startId), shifted(endId)

    -- A span with no interior has nothing to delete, so its ends are still directly connected - and
    -- the rebuild below would then add a SECOND path between them, leaving the original connection
    -- running alongside the new subdivided one. That is the fork reported as "divide connects the
    -- ends". Sever it first, so the new chain REPLACES the connection instead of joining it.
    if #chainIds == 2 then
        severEnds(newStartId, newEndId)
    end

    -- newPoints carries both endpoints; only the interior gets created.
    local previousId = newStartId
    for i = 2, #newPoints - 1 do
        local p = newPoints[i]
        local y = AutoDrive:getTerrainHeightAtWorldPos(p.x, p.z)
        local wp = ADGraphManager:recordWayPoint(p.x, y, p.z, true, dual, false, previousId, flags, false)
        -- New waypoints are appended, so their ids sit above everything already there and nothing
        -- shifts underneath us for the rest of this loop.
        previousId = (wp ~= nil and wp.id) or ADGraphManager:getWayPointsCount()
    end

    local tail = ADGraphManager:getWayPointById(previousId)
    local endNode = ADGraphManager:getWayPointById(newEndId)
    if tail == nil or endNode == nil then
        Logging.error("[FlyoverEditor]: lost the span endpoints while rebuilding (tail=%s end=%s).",
            tostring(previousId), tostring(newEndId))
        return false
    end
    ADGraphManager:toggleConnectionBetween(tail, endNode, false, dual, false)
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Name a waypoint (map marker), reusing the text dialog the mod already has.
-- ---------------------------------------------------------------------------------------------

function ADFlyoverEditor:nameAtCursor()
    if self.hoverId == nil then
        return
    end
    if ADEnterTargetNameGui == nil or g_gui == nil then
        Logging.error("[FlyoverEditor]: the name dialog is not available.")
        return
    end

    -- The dialog normally works out which waypoint to name from the controlled vehicle, which is
    -- exactly the assumption that does not hold here. This override points it at the clicked
    -- waypoint instead; the dialog clears it again on close.
    ADEnterTargetNameGui.overrideWayPointId = self.hoverId
    ADEditorHistory:snapshot("name waypoint")
    -- showDialog returns falsy rather than throwing when the screen is not registered, so check
    -- it: an unreported failure here looks exactly like "the dialog opened and did nothing".
    local shown = g_gui:showDialog("ADEnterTargetNameGui")
    if not shown then
        Logging.error("[FlyoverEditor]: the name dialog would not open - g_gui has no screen "
            .. "registered as 'ADEnterTargetNameGui'. Is AutoDrive fully loaded?")
        return
    end
    Logging.info("[FlyoverEditor]: opened the name dialog for waypoint id=%s.", tostring(self.hoverId))
end


-- ---------------------------------------------------------------------------------------------
-- Persistent connection options.
--
-- These used to be modifier keys held down during every single click (Alt for two-way, LShift for
-- secondary, RShift for reverse), inherited from the mod's own recording scheme. That is fine for
-- the occasional connection and miserable for laying a route: the combination has to be held
-- correctly for every click, there is no indication of what is currently selected, and getting it
-- wrong is only visible afterwards. They are now sticky settings shown on the panel.
-- ---------------------------------------------------------------------------------------------

ADFlyoverEditor.CONNECTION = { ONEWAY = 1, TWOWAY = 2, REVERSE = 3 }
ADFlyoverEditor.CONNECTION_NAMES = { "one-way", "two-way", "reverse" }

function ADFlyoverEditor:cycleConnectionMode()
    self.connectionMode = (self.connectionMode % #self.CONNECTION_NAMES) + 1
    Logging.info("[FlyoverEditor]: new connections are now %s.", self.CONNECTION_NAMES[self.connectionMode])
end

function ADFlyoverEditor:togglePriority()
    self.subPrio = not self.subPrio
    Logging.info("[FlyoverEditor]: new connections are now %s.", self.subPrio and "secondary" or "primary")
end

function ADFlyoverEditor:cycleFalloff()
    local next_ = self.falloffRadius + AutoDrive.FLYOVER_FALLOFF_STEP
    self:setFalloffRadius(next_ > AutoDrive.FLYOVER_FALLOFF_MAX and 0 or next_)
end

--- The three values the graph calls for, derived from the sticky settings above.
function ADFlyoverEditor:getConnectionOptions()
    local reverse = self.connectionMode == self.CONNECTION.REVERSE
    local dual = self.connectionMode == self.CONNECTION.TWOWAY
    local flags = self.subPrio and AutoDrive.FLAG_SUBPRIO or AutoDrive.FLAG_NONE
    return reverse, dual, flags
end

--- What the current tool is waiting for, in plain words. This is the line that tells you what to
--- do next instead of leaving you to remember it, and it is why the panel exists.
function ADFlyoverEditor:getNextStepLines()
    local t = self.TOOL

    if self.tool == t.NONE then
        return { "No tool selected.", "Pick one above, or press 1-9 / 0." }
    end

    if self.tool == t.DRAW then
        if self.lastWaypointId ~= nil then
            return { "Click ground to extend, or a", "waypoint to link. Right-click ends." }
        end
        return { "Click to start a run, or a", "waypoint to draw on from it." }
    elseif self.tool == t.MOVE then
        if self.dragId ~= nil then
            return { string.format("Wheel changes falloff (%.1fm),", self.falloffRadius), "live. Release to drop." }
        end
        if self.hoverId ~= nil then
            return { "Drag the highlighted waypoint." }
        end
        return { "Point at a waypoint, then drag it." }
    elseif self.tool == t.DELETE then
        if self.selectionCount > 0 then
            return { string.format("Click to delete %d selected.", self.selectionCount) }
        end
        if self.deleteScope == self.DELETE_SCOPE.RUN then
            return { "Click a run to delete all of it,", "out to the junctions at each end." }
        end
        if self.hoverId ~= nil then
            return { "Click to delete the highlighted one." }
        end
        return { "Point at a waypoint to delete it." }
    elseif self.tool == t.SMOOTH then
        if self.smoothToId ~= nil then
            if self.smoothMode == self.SMOOTH_MODE.REBUILD then
                return { string.format("Wheel sets max spacing (%.1fm).", self.smoothSpacing), "Curves stay denser." }
            end
            return { string.format("Wheel sets strength (%d).", self.smoothStrength), "Right-click applies it." }
        end
        if self.smoothFromId ~= nil then
            return { "Click the far end of the span." }
        end
        return { "Click one end of the span." }
    elseif self.tool == t.NAME then
        return { "Click a waypoint to name it." }
    elseif self.tool == t.SPLINE then
        if self.splineToId ~= nil then
            return { "Wheel adjusts the curve.", "Right-click places it." }
        end
        if self.splineFromId ~= nil then
            return { "Click the waypoint to curve to." }
        end
        return { "Click the waypoint to curve from." }
    elseif self.tool == t.FIELDLOOP then
        return { "Click inside a field to ring it.", "Uses the field loop settings." }
    elseif self.tool == t.SIDING then
        if self.sidingBlockedBy ~= nil then
            return { "Will not fit here.", "See the log for why." }
        end
        if self.sidingAnchorId ~= nil then
            return { string.format("Wheel sets length (%.0fm, %s side).",
                        ADFlyoverSettings.get("sidingLength") or 30,
                        (self.offsetSide or 1) >= 0 and "left" or "right"),
                     "Flip the side on the panel. Right-click applies." }
        end
        return { "Click where the siding should", "sit - the click is its centre." }
    elseif self.tool == t.PARALLEL then
        if self.offsetToId ~= nil then
            if self.offsetBlockedBy ~= nil then
                return { "Too tight to offset that far.", "Wheel it back, or swap sides." }
            end
            return { string.format("Wheel sets offset (%.1fm %s).", self.offsetDistance,
                        (self.offsetSide or 1) >= 0 and "left" or "right"),
                     "Flip the side on the panel. Right-click applies." }
        end
        if self.offsetFromId ~= nil then
            return { "Click the far end of the span." }
        end
        if self.offsetScope == self.OFFSET_SCOPE.RUN then
            return { "Click a run to offset the whole", "thing, junction to junction." }
        end
        return { "Click one end of a span to run", "a track alongside it." }
    elseif self.tool == t.STRAIGHTEN then
        if self.straightenToId ~= nil then
            return { string.format("Wheel sets tolerance (%.2fm).", self.straightenTolerance),
                     "Right-click straightens the span." }
        end
        if self.straightenFromId ~= nil then
            return { "Click the far end of the span." }
        end
        return { "Click one end of a span to", "straighten it." }
    elseif self.tool == t.DIVIDE then
        if self.divideToId ~= nil then
            return { string.format("Wheel sets the count (%d).", self.divideCount), "Right-click applies it." }
        end
        if self.divideFromId ~= nil then
            return { "Click the far end of the span." }
        end
        return { "Click one end of the span to divide." }
    elseif self.tool == t.CONVERT then
        return {
            string.format("Click to make %s", self.CONVERT_OP_NAMES[self.convertOp]),
            self.convertScope == self.DELETE_SCOPE.RUN and "the whole run." or "this waypoint."
        }
    elseif self.tool == t.MERGE then
        if self.mergeToId ~= nil then
            return { "Green marks what would be absorbed.", "Click a point on the OTHER track." }
        end
        if self.mergeFromId ~= nil then
            return { "Click the far end of the span,", "on the SAME track." }
        end
        return { "Click one end of the span to merge." }
    end

    return { "" }
end

-- ---------------------------------------------------------------------------------------------
-- Spline connect - the mod's own curved connection, driven from the flyover tools.
--
-- This is not a reimplementation: it calls exactly what the standard editor calls
-- (AutoDrive:createSplineInterpolationBetween, then ADGraphManager:createSplineConnection), so a
-- spline laid here is identical to one laid from a vehicle. The only differences are that the two
-- endpoints come from flyover clicks rather than the vehicle's selected/hovered node, and that the
-- curvature is a sticky panel setting rather than a wheel gesture.
-- ---------------------------------------------------------------------------------------------

-- nil means "let the mod choose", which is what the standard editor does until you scroll.
ADFlyoverEditor.CURVATURE_VALUES = { false, 0.5, 1, 2, 5 }
ADFlyoverEditor.CURVATURE_NAMES = { "auto", "0.5", "1", "2", "5" }

--- Mirror a spline control point about its node.
---
--- AutoDrive:getSplineControlPoints returns, for each end, a handle at `node + direction`, where
--- direction points at whichever neighbour forms the straightest line to the other end. On a
--- two-way track both directions exist, so that choice is a guess: the curve arrives lying against
--- the lane one way round with no way to ask for the other. Reflecting the handle through the node
--- gives exactly the opposite tangent, so the spline merges in facing the other way along the
--- track. This is the geometry of the join, not which way traffic runs - that is the separate
--- direction setting.
local function mirrorControlPoint(node, p)
    if node == nil or p == nil then
        return p
    end
    return { x = 2 * node.x - p.x, y = node.y, z = 2 * node.z - p.z }
end

-- Restored: this was removed with the old merge-direction control, leaving the panel calling a
-- function that no longer existed.
function ADFlyoverEditor:toggleSplineEnds()
    self.splineSwapEnds = not self.splineSwapEnds
    Logging.info("[FlyoverEditor]: spline endpoints are %s.", self.splineSwapEnds and "swapped" or "normal")
end

function ADFlyoverEditor:toggleSplineEndTangent()
    self.splineFlipEndTangent = not self.splineFlipEndTangent
    Logging.info("[FlyoverEditor]: spline end tangent %s.", self.splineFlipEndTangent and "flipped" or "auto")
end

function ADFlyoverEditor:toggleSplineStartTangent()
    self.splineFlipStartTangent = not self.splineFlipStartTangent
    Logging.info("[FlyoverEditor]: spline start tangent %s.", self.splineFlipStartTangent and "flipped" or "auto")
end

--- Build the interpolation, applying any tangent flips.
---
--- With both on auto this defers to the mod's own createSplineInterpolationBetween, so the result
--- is identical to the standard editor. A flip has to go the long way round - fetch the control
--- points, mirror, hand them to createSplineWithControlPoints - because the mod derives them
--- internally with no way to influence the choice.
function ADFlyoverEditor:buildSplineInterpolation(startNode, endNode)
    AutoDrive.splineInterpolation = nil

    if not self.splineFlipEndTangent and not self.splineFlipStartTangent then
        AutoDrive:createSplineInterpolationBetween(startNode, endNode)
        return
    end

    if table.contains(startNode.out, endNode.id) or table.contains(endNode.incoming, startNode.id) then
        return
    end
    local curvature = AutoDrive.splineInterpolationUserCurvature
    if type(curvature) ~= "number" or curvature < 0.5 then
        return
    end

    local ok, p0, p3 = pcall(function()
        return AutoDrive:getSplineControlPoints(startNode, endNode)
    end)
    if not ok or p0 == nil or p3 == nil then
        AutoDrive:createSplineInterpolationBetween(startNode, endNode)
        return
    end

    if self.splineFlipStartTangent then
        p0 = mirrorControlPoint(startNode, p0)
    end
    if self.splineFlipEndTangent then
        p3 = mirrorControlPoint(endNode, p3)
    end

    tryCall("createSplineWithControlPoints", function()
        AutoDrive:createSplineWithControlPoints(startNode, p0, endNode, p3)
    end)
end

function ADFlyoverEditor:cycleCurvature()
    self.curvatureIndex = (self.curvatureIndex % #self.CURVATURE_VALUES) + 1
    Logging.info("[FlyoverEditor]: spline curvature %s.", self.CURVATURE_NAMES[self.curvatureIndex])
end

function ADFlyoverEditor:splineClick()
    if self.hoverId == nil then
        return
    end

    if self.splineFromId == nil then
        self.splineFromId = self.hoverId
        Logging.info("[FlyoverEditor]: spline from id=%s; click the waypoint to curve to.", tostring(self.splineFromId))
        return
    end

    if self.splineToId == nil then
        if self.hoverId == self.splineFromId then
            return
        end
        self.splineToId = self.hoverId
        -- Curvature must be a NUMBER before the preview exists: the mod adds to it unguarded
        -- while an interpolation is valid (see clearSplineState).
        if type(AutoDrive.splineInterpolationUserCurvature) ~= "number" then
            AutoDrive.splineInterpolationUserCurvature = AutoDrive.FLYOVER_DEFAULT_CURVATURE
        end
        Logging.info("[FlyoverEditor]: previewing a spline id=%s -> id=%s. Wheel adjusts curvature, right-click places it.",
            tostring(self.splineFromId), tostring(self.splineToId))
        return
    end

    -- Both ends already chosen: a further click re-picks the far end rather than doing nothing.
    if self.hoverId ~= self.splineFromId then
        self.splineToId = self.hoverId
    end
end

--- Rebuild the preview. Called every frame while one is pending.
---
--- Recomputing continuously is the point, not waste: AutoDrive:handleSplineCurvature only adjusts
--- the curvature - and only suppresses the camera zoom to do it - while splineInterpolation is
--- valid. Keeping a live interpolation is therefore what puts curvature on the wheel and takes
--- zoom off it, and it is what makes the endpoint and merge toggles change the shape as they are
--- cycled instead of only at the moment of placing.
function ADFlyoverEditor:updateSplinePreview()
    if self.splineFromId == nil or self.splineToId == nil then
        return
    end

    -- The spline always ends on the waypoint that was clicked. An earlier version could aim at a
    -- neighbour instead, to control which way the curve entered a two-way lane, but landing
    -- somewhere other than where you clicked is a worse surprise than the control was worth.
    local startId, endId = self.splineFromId, self.splineToId
    if self.splineSwapEnds then
        startId, endId = endId, startId
    end

    local startNode = ADGraphManager:getWayPointById(startId)
    local endNode = ADGraphManager:getWayPointById(endId)
    if startNode == nil or endNode == nil then
        self:cancelSplinePreview()
        return
    end

    self.splineResolvedStart, self.splineResolvedEnd = startId, endId

    tryCall("buildSplineInterpolation", function()
        self:buildSplineInterpolation(startNode, endNode)
    end)
end

function ADFlyoverEditor:cancelSplinePreview()
    if self.splineFromId ~= nil or self.splineToId ~= nil then
        Logging.info("[FlyoverEditor]: spline preview discarded.")
    end
    self.splineFromId, self.splineToId = nil, nil
    self.splineResolvedStart, self.splineResolvedEnd = nil, nil
    clearSplineState()
end

--- Commit whatever the preview is currently showing.
function ADFlyoverEditor:commitSplinePreview()
    local startId, endId = self.splineResolvedStart, self.splineResolvedEnd
    if startId == nil or endId == nil then
        return
    end

    local startNode = ADGraphManager:getWayPointById(startId)
    local endNode = ADGraphManager:getWayPointById(endId)
    if startNode == nil or endNode == nil then
        self:cancelSplinePreview()
        return
    end

    local curvature = AutoDrive.splineInterpolationUserCurvature
    local interpolation = AutoDrive.splineInterpolation
    local reverse, dual, flags = self:getConnectionOptions()

    if interpolation == nil or not interpolation.valid
        or interpolation.waypoints == nil or #interpolation.waypoints <= 2 then
        -- Below curvature 0.5 the mod deliberately falls back to a straight line, and it also
        -- refuses a preview between two waypoints that are already connected. Both are ordinary
        -- outcomes rather than failures, so this connects them straight rather than complaining.
        Logging.info("[FlyoverEditor]: no curve to place (curvature %.2f); connecting id=%s to id=%s directly.",
            curvature or -1, tostring(startId), tostring(endId))
        ADEditorHistory:snapshot("connect (straight)")
        ADGraphManager:toggleConnectionBetween(startNode, endNode, reverse, dual, false)
        ADGraphManager:markChanges()
        self:cancelSplinePreview()
        return
    end

    -- Drop the first and last interpolated points - the endpoints already exist - and clamp height
    -- jumps, which stops points diving into the terrain over a bridge or a dip. Both copied from
    -- Hud.lua:541-552.
    local waypoints = {}
    local lastHeight = startNode.y
    for wpId, wp in pairs(interpolation.waypoints) do
        if wpId ~= 1 and wpId < (#interpolation.waypoints - 1) then
            if math.abs(wp.y - lastHeight) > 1 then
                wp.y = lastHeight
            end
            table.insert(waypoints, { x = wp.x, y = wp.y, z = wp.z })
            lastHeight = wp.y
        end
    end

    -- Honour the direction setting. createSplineConnection has no reverse parameter, so a reversed
    -- spline is built as the same curve laid down the other way: swap the endpoints and walk the
    -- interpolated points backwards. The shape is identical, the travel is opposite. Without this
    -- the reverse setting was silently discarded and there was no way to flip a spline at all.
    local chainStart, chainEnd = startId, endId
    if reverse then
        chainStart, chainEnd = endId, startId
        local flipped = {}
        for i = #waypoints, 1, -1 do
            flipped[#flipped + 1] = waypoints[i]
        end
        waypoints = flipped
    end

    ADEditorHistory:snapshot("spline connect")
    ADGraphManager:createSplineConnection(chainStart, waypoints, chainEnd, dual, false)

    -- createSplineConnection takes no flags, so a secondary spline is re-flagged afterwards. The
    -- new points are appended, so they are the last ones in the graph.
    if flags ~= AutoDrive.FLAG_NONE then
        local total = ADGraphManager:getWayPointsCount()
        for id = total - #waypoints + 1, total do
            ADGraphManager:setWayPointFlags(id, flags, false)
        end
    end

    Logging.info("[FlyoverEditor]: placed spline id=%s -> id=%s with %d point(s), curvature %.2f, %s%s%s.",
        tostring(chainStart), tostring(chainEnd), #waypoints, curvature or -1,
        dual and "two-way" or "one-way", flags ~= AutoDrive.FLAG_NONE and " secondary" or "",
        reverse and " (reversed)" or "")

    self.splineFromId, self.splineToId = nil, nil
    self.splineResolvedStart, self.splineResolvedEnd = nil, nil
    clearSplineState()
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

-- ---------------------------------------------------------------------------------------------
-- Divide - respace a span into a chosen number of evenly spaced points.
--
-- Two clicks pick the span, the wheel sets how many points go between the ends, right-click
-- applies. The wheel is the whole point of the tool: the right count is something you judge by
-- looking at it, not a number you know in advance, so it is worth being able to dial it up and
-- down and watch the result.
--
-- Spacing is by arc length along the existing path, so the divided run follows the same route -
-- this respaces a span, it does not straighten or smooth it. Use the smooth tool for that.
-- ---------------------------------------------------------------------------------------------

AutoDrive.FLYOVER_DIVIDE_MAX = 200

--- Straighten a span: drop the waypoints that are only noise, keep the ones that are a real bend.
---
--- The tolerance is what separates the two, and the preview is what makes it choosable - dial the
--- wheel and watch a bend survive or flatten. The point COUNT is preserved: the span keeps as many
--- waypoints as it had, respread evenly along the simplified shape, so straightening never leaves a
--- three-point run that has to be divided back out afterwards.
--- Span select for parallel and siding. Identical to straighten's; only the commit differs.
-- ---------------------------------------------------------------------------------------------
-- Siding
--
-- A siding has a shape you want repeatedly rather than one dialled in each time, so its offset and
-- length are persistent settings and the click just says WHERE. The click is the CENTRE, because
-- you point at the place a vehicle needs to pull over, not at where the taper should begin.
--
-- Four positions along the main line, not two:
--
--     ...A########B===========C########D...        A..B and C..D are the merges
--          \                      /               B..C is the parallel section
--           \____________________/
--
-- Only A and D need to be real waypoints - they are where the splines attach - and they almost
-- never land on an existing one, so the main line gets a waypoint inserted at each. That is the
-- divide this needs and the span-selected version did not.
-- ---------------------------------------------------------------------------------------------

--- The two ends of the run through `seedId`, or nil when it does not have exactly two.
--- collectRunBetweenJunctions returns a SET, so the ends have to be found rather than indexed:
--- they are the members with only one neighbour still inside the run. Neighbours are counted
--- uniquely, because a two-way connection appears in both `out` and `incoming`.
function ADFlyoverEditor:runEnds(seedId)
    local run, count = self:collectRunBetweenJunctions(seedId)
    if run == nil or count == nil or count < 2 then
        -- Almost always because the waypoint clicked IS a junction: the run stops at junctions, so
        -- seeding on one collects little or nothing. Worth saying, rather than reporting it as an
        -- unspecified failure to order the run - which is what sent this to the log four times.
        return nil, nil, 0, string.format(
            "id=%s gives a run of %s waypoint(s) - it is probably a junction itself. Click somewhere "
            .. "along a run instead.", tostring(seedId), tostring(count or 0))
    end
    local ends = {}
    for id in pairs(run) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            local seen, inside = {}, 0
            for _, listName in ipairs({ "out", "incoming" }) do
                for _, other in pairs(wp[listName] or {}) do
                    if run[other] and not seen[other] then
                        seen[other] = true
                        inside = inside + 1
                    end
                end
            end
            if inside <= 1 then
                ends[#ends + 1] = id
            end
        end
    end
    if #ends ~= 2 then
        return nil, nil, #ends, string.format(
            "the run through id=%s has %d clear end(s), not 2 - it branches or closes on itself.",
            tostring(seedId), #ends)
    end
    return ends[1], ends[2], 2, nil
end

--- The run through `seedId` as an ordered point list, with cumulative distance and the seed's index.
function ADFlyoverEditor:orderedRunThrough(seedId)
    local a, b, found, why = self:runEnds(seedId)
    if a == nil then
        return nil, nil, nil, why
    end

    local ids = self:runPathBetween(a, b)
    if ids == nil or #ids < 2 then
        return nil, nil, nil, string.format(
            "found the run's ends (id=%s and id=%s) but could not path between them.",
            tostring(a), tostring(b))
    end

    local pts, seedIndex = {}, nil
    for i, id in ipairs(ids) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp == nil then
            return nil, nil, nil, string.format("waypoint id=%s vanished while ordering the run.", tostring(id))
        end
        pts[i] = { x = wp.x, y = wp.y, z = wp.z, id = id }
        if id == seedId then
            seedIndex = i
        end
    end
    if seedIndex == nil then
        return nil, nil, nil, string.format(
            "the path between the run's ends (%d waypoints) does not pass through id=%s - the run "
            .. "loops, so there is more than one way round it.", #ids, tostring(seedId))
    end

    local cumulative = { 0 }
    for i = 2, #pts do
        cumulative[i] = cumulative[i - 1]
            + MathUtil.vector2Length(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z)
    end
    return pts, cumulative, seedIndex, nil
end

--- Position at `distance` along the ordered run, plus the segment it falls in.
local function pointAtDistance(pts, cumulative, distance)
    if distance <= 0 then
        return { x = pts[1].x, y = pts[1].y, z = pts[1].z }, 1, 0
    end
    local total = cumulative[#pts]
    if distance >= total then
        return { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }, #pts - 1, 1
    end
    for i = 2, #pts do
        if cumulative[i] >= distance then
            local segLen = cumulative[i] - cumulative[i - 1]
            local t = segLen > 0 and (distance - cumulative[i - 1]) / segLen or 0
            return {
                x = pts[i - 1].x + (pts[i].x - pts[i - 1].x) * t,
                y = (pts[i - 1].y or 0) + ((pts[i].y or 0) - (pts[i - 1].y or 0)) * t,
                z = pts[i - 1].z + (pts[i].z - pts[i - 1].z) * t,
            }, i - 1, t
        end
    end
    return { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }, #pts - 1, 1
end

--- The stretch of the run between two distances, with its ends interpolated exactly.
local function subChainByDistance(pts, cumulative, from, to)
    local out = {}
    local head = pointAtDistance(pts, cumulative, from)
    out[1] = head
    for i = 1, #pts do
        if cumulative[i] > from and cumulative[i] < to then
            out[#out + 1] = { x = pts[i].x, y = pts[i].y, z = pts[i].z }
        end
    end
    out[#out + 1] = pointAtDistance(pts, cumulative, to)
    return out
end

--- Everything the preview and the commit both need, so they cannot disagree about the shape.
function ADFlyoverEditor:sidingPlan()
    if self.sidingAnchorId == nil then
        return nil, nil
    end
    local pts, cumulative, seedIndex, why = self:orderedRunThrough(self.sidingAnchorId)
    if pts == nil then
        return nil, why or "could not order the run through that waypoint."
    end

    local offset = ADFlyoverSettings.get("sidingOffset") or 5
    local length = ADFlyoverSettings.get("sidingLength") or 30
    local merge = offset * AutoDrive.FLYOVER_SIDING_MERGE_RATIO
    local needed = length + 2 * merge
    local total = cumulative[#pts]
    if total < needed then
        return nil, string.format(
            "this run is %.0fm long; a %.0fm siding at %.1fm offset needs %.0fm including its merges.",
            total, length, offset, needed)
    end

    -- Centre the siding on the click, then slide it along if it would run off either end.
    local centre = cumulative[seedIndex]
    centre = math.max(needed / 2, math.min(total - needed / 2, centre))

    local aDistance = centre - needed / 2
    local dDistance = centre + needed / 2
    local parallel = subChainByDistance(pts, cumulative, aDistance + merge, dDistance - merge)

    local side = self.offsetSide or 1
    local track, err = ADOffsetGeometry.offsetOpenChain(parallel, offset * side)
    if track == nil then
        return nil, err
    end

    return {
        points = pts,
        cumulative = cumulative,
        aDistance = aDistance,
        dDistance = dDistance,
        track = track,
        offset = offset,
        length = length,
        merge = merge,
        side = side,
    }
end

--- Insert a waypoint partway along an existing connection, keeping the connection intact through it.
function ADFlyoverEditor:insertOnSegment(aId, bId, position, dual, flags)
    local a = ADGraphManager:getWayPointById(aId)
    local b = ADGraphManager:getWayPointById(bId)
    if a == nil or b == nil then
        return nil
    end
    -- Sever first, or the new point runs alongside the original connection rather than replacing it.
    local severed = false
    if table.contains(a.out, b.id) then
        ADGraphManager:toggleConnectionBetween(a, b, false, false, false)
        severed = true
    end
    if table.contains(b.out, a.id) then
        ADGraphManager:toggleConnectionBetween(b, a, false, false, false)
        severed = true
    end
    if not severed then
        -- These two are not actually connected any more, so inserting between them would fork the
        -- line rather than split it. Refusing is right: silently forking is the bug this guards.
        Logging.warning("[FlyoverEditor]: id=%s and id=%s are no longer connected, so nothing was "
            .. "inserted between them.", tostring(aId), tostring(bId))
        return nil
    end
    local y = self:resolveHeightAt(position.x, position.z, position.y)
    local wp = ADGraphManager:recordWayPoint(position.x, y, position.z, true, dual, false, aId, flags, false)
    local newId = (wp ~= nil and wp.id) or ADGraphManager:getWayPointsCount()
    local newNode = ADGraphManager:getWayPointById(newId)
    local bNode = ADGraphManager:getWayPointById(bId)
    if newNode ~= nil and bNode ~= nil then
        ADGraphManager:toggleConnectionBetween(newNode, bNode, false, dual, false)
    end
    return newId
end

--- A waypoint at `distance` along the run: the existing one when it is close enough, otherwise a
--- new one inserted into the connection there.
function ADFlyoverEditor:waypointAtDistance(pts, cumulative, distance, dual, flags)
    local position, segment, t = pointAtDistance(pts, cumulative, distance)
    if t <= 0.02 then
        return pts[segment].id
    end
    if t >= 0.98 then
        return pts[segment + 1].id
    end
    return self:insertOnSegment(pts[segment].id, pts[segment + 1].id, position, dual, flags)
end

function ADFlyoverEditor:sidingClick()
    if self.hoverId == nil then
        return
    end
    self.sidingAnchorId = self.hoverId
    self.sidingPreview = nil
    local seedPts = self:orderedRunThrough(self.sidingAnchorId)
    if seedPts ~= nil then
        self.offsetSide = self:offsetSideFromCursor(seedPts)
    end
    local plan, err = self:sidingPlan()
    if plan == nil then
        Logging.warning("[FlyoverEditor]: %s", tostring(err))
        return
    end
    Logging.info("[FlyoverEditor]: siding centred on id=%s - %.0fm long, %.1fm to the %s, merging "
        .. "over %.0fm at each end. Wheel changes the length, right-click applies.",
        tostring(self.sidingAnchorId), plan.length, plan.offset,
        plan.side >= 0 and "left" or "right", plan.merge)
end

function ADFlyoverEditor:updateSidingPreview()
    if self.sidingAnchorId == nil then
        self.sidingPreview, self.sidingBlockedBy = nil, nil
        return
    end
    local plan, err = self:sidingPlan()
    self.sidingPreview = plan ~= nil and plan.track or nil
    self.sidingBlockedBy = err
end

function ADFlyoverEditor:commitSiding()
    local plan, err = self:sidingPlan()
    if plan == nil then
        Logging.warning("[FlyoverEditor]: %s", tostring(err))
        self:cancelSiding()
        return
    end

    local first = ADGraphManager:getWayPointById(plan.points[1].id)
    local second = ADGraphManager:getWayPointById(plan.points[2].id)
    local dual = ADGraphManager:isDualRoad(first, second)
    local flags = second.flags or AutoDrive.FLAG_NONE

    ADEditorHistory:snapshot("siding")

    -- Insert the far attachment, then RE-DERIVE the run before inserting the near one.
    --
    -- Doing both from the same snapshot is wrong whenever they land on the same segment, which a
    -- sparse run makes easy - a 30m siding with 8m merges spans 46m, so one long segment is enough.
    -- The first insertion severs a->b and leaves a->new->b; the second then looks for a->b, does not
    -- find it, severs nothing, and adds a SECOND path between the same two waypoints. That is the
    -- double connection.
    --
    -- Re-deriving is safe and cheap: inserting a waypoint on the line adds a vertex without moving
    -- anything, so every distance along the run is unchanged and aDistance still means what it did.
    local dId = self:waypointAtDistance(plan.points, plan.cumulative, plan.dDistance, dual, flags)
    if dId == nil then
        Logging.error("[FlyoverEditor]: could not place the siding's far attachment point.")
        self:cancelSiding()
        return
    end

    local freshPoints, freshCumulative = self:orderedRunThrough(self.sidingAnchorId)
    if freshPoints == nil then
        Logging.error("[FlyoverEditor]: lost the run after inserting the far attachment point.")
        self:cancelSiding()
        return
    end

    local aId = self:waypointAtDistance(freshPoints, freshCumulative, plan.aDistance, dual, flags)
    if aId == nil or dId == nil then
        Logging.error("[FlyoverEditor]: could not place the siding's attachment points.")
        self:cancelSiding()
        return
    end

    local firstNewId, lastNewId = self:createRunFrom(plan.track, dual, flags)
    if firstNewId == nil or lastNewId == nil then
        Logging.error("[FlyoverEditor]: the siding track could not be created.")
        self:cancelSiding()
        return
    end

    self:splineConnectIds(aId, firstNewId, dual, flags)
    self:splineConnectIds(lastNewId, dId, dual, flags)

    Logging.info("[FlyoverEditor]: laid a %.0fm siding %.1fm to the %s with %.0fm merges, %d track "
        .. "waypoint(s), attached at id=%s and id=%s.",
        plan.length, plan.offset, plan.side >= 0 and "left" or "right", plan.merge,
        #plan.track, tostring(aId), tostring(dId))

    self.sidingAnchorId, self.sidingPreview = nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelSiding()
    if self.sidingAnchorId ~= nil then
        Logging.info("[FlyoverEditor]: cancelled the siding.")
    end
    self.sidingAnchorId, self.sidingPreview, self.sidingBlockedBy = nil, nil, nil
end

function ADFlyoverEditor:offsetClick()
    if self.hoverId == nil then
        return
    end

    -- Whole-run scope needs one click, not two: the ends are wherever the run meets a junction,
    -- or where it simply stops. collectRunBetweenJunctions is what delete's run scope already uses.
    if self.offsetScope == self.OFFSET_SCOPE.RUN then
        local run, count = self:collectRunBetweenJunctions(self.hoverId)
        if run == nil or count == nil or count < 2 then
            Logging.warning("[FlyoverEditor]: no run found through id=%s.", tostring(self.hoverId))
            return
        end

        -- collectRunBetweenJunctions returns a SET, not an ordered list, so the two ends have to be
        -- found rather than indexed: they are the members with only one neighbour still inside the
        -- run. Neighbours are counted uniquely, because a two-way connection appears in both `out`
        -- and `incoming` and would otherwise count twice and hide every end.
        local ends = {}
        for id in pairs(run) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                local seen, inside = {}, 0
                for _, listName in ipairs({ "out", "incoming" }) do
                    for _, other in pairs(wp[listName] or {}) do
                        if run[other] and not seen[other] then
                            seen[other] = true
                            inside = inside + 1
                        end
                    end
                end
                if inside <= 1 then
                    ends[#ends + 1] = id
                end
            end
        end

        if #ends ~= 2 then
            Logging.warning("[FlyoverEditor]: the run through id=%s has %d clear end(s), not 2. Use "
                .. "the picked-span scope and click both ends yourself.", tostring(self.hoverId), #ends)
            return
        end
        self.offsetFromId, self.offsetToId = ends[1], ends[2]
        self.offsetPreview, self.offsetCache = nil, nil
        local seedPts = self:offsetSpanPoints()
        if seedPts ~= nil then
            self.offsetSide = self:offsetSideFromCursor(seedPts)
        end
        Logging.info("[FlyoverEditor]: whole run of %d waypoint(s), id=%s to id=%s. Wheel sets the "
            .. "offset (%.1fm); the side follows the cursor. Right-click applies.",
            count, tostring(self.offsetFromId), tostring(self.offsetToId), self.offsetDistance)
        return
    end

    if self.offsetFromId == nil then
        self.offsetFromId = self.hoverId
        Logging.info("[FlyoverEditor]: %s from id=%s; click the far end of the span.",
            self.TOOL_NAMES[self.tool] or "offset", tostring(self.offsetFromId))
        return
    end

    if self.hoverId == self.offsetFromId then
        return
    end

    local span = self:runPathBetween(self.offsetFromId, self.hoverId)
    if span == nil then
        Logging.warning("[FlyoverEditor]: id=%s is not connected to id=%s, so they are not two ends of one span.",
            tostring(self.hoverId), tostring(self.offsetFromId))
        return
    end

    self.offsetToId = self.hoverId
    self.offsetPreview, self.offsetCache = nil, nil
    local seedPts = self:offsetSpanPoints()
    if seedPts ~= nil then
        self.offsetSide = self:offsetSideFromCursor(seedPts)
    end
    Logging.info("[FlyoverEditor]: span of %d waypoint(s). Wheel sets the offset (%.1fm); the side "
        .. "follows the cursor. Right-click applies.", #span, self.offsetDistance)
end

--- Points of the selected span, and the span itself.
function ADFlyoverEditor:offsetSpanPoints()
    if self.offsetFromId == nil or self.offsetToId == nil then
        return nil, nil
    end
    local span = self:runPathBetween(self.offsetFromId, self.offsetToId)
    if span == nil or #span < 2 then
        return nil, span
    end
    local pts = {}
    for _, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
        end
    end
    if #pts < 2 then
        return nil, span
    end
    return pts, span
end

--- Which side of the span the cursor is on: +1 left of travel, -1 right.
---
--- The side deliberately does NOT come from click order. Picking the far end first would otherwise
--- mirror the whole result, which is invisible until it is too late and impossible to reason about.
--- Taking it from the cursor makes it obvious instead: point at the side you want and the preview
--- is there, whichever end you happened to click first.
function ADFlyoverEditor:offsetSideFromCursor(pts)
    local cx, cz = self.cursorX, self.cursorZ
    if cx == nil or cz == nil then
        return 1
    end

    local bestIndex, bestDistance = 1, math.huge
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local lengthSquared = dx * dx + dz * dz
        local t = 0
        if lengthSquared > 1e-9 then
            t = math.max(0, math.min(1, ((cx - a.x) * dx + (cz - a.z) * dz) / lengthSquared))
        end
        local d = MathUtil.vector2Length(cx - (a.x + t * dx), cz - (a.z + t * dz))
        if d < bestDistance then
            bestIndex, bestDistance = i, d
        end
    end

    local a, b = pts[bestIndex], pts[bestIndex + 1]
    local cross = (b.x - a.x) * (cz - a.z) - (b.z - a.z) * (cx - a.x)
    return cross >= 0 and 1 or -1
end

function ADFlyoverEditor:updateOffsetPreview()
    local pts = self:offsetSpanPoints()
    if pts == nil or self.offsetDistance < 0.1 then
        self.offsetPreview, self.offsetBlockedBy, self.offsetCache = nil, nil, nil
        return
    end

    local signed = self.offsetDistance * (self.offsetSide or 1)

    -- The offset is O(n^2) in the fold removal, and this runs every frame while a preview is up.
    -- On a long run that is thousands of segment-pair tests per frame for a result that only
    -- changes when the span, the distance or the side does - so only recompute when one of them has.
    local key = string.format("%s:%s:%.2f:%d:%d",
        tostring(self.offsetFromId), tostring(self.offsetToId), signed, #pts, self.offsetScope)
    if self.offsetCache ~= nil and self.offsetCache.key == key then
        self.offsetPreview, self.offsetBlockedBy = self.offsetCache.points, self.offsetCache.err
        return
    end

    local offset, err = ADOffsetGeometry.offsetOpenChain(pts, signed)
    self.offsetPreview, self.offsetBlockedBy = offset, err
    self.offsetSignedDistance = signed
    self.offsetCache = { key = key, points = offset, err = err }
end

--- Lay a chain of new waypoints down, joined in order. Returns the first and last new ids.
function ADFlyoverEditor:createRunFrom(points, dual, flags)
    local firstId, previousId = nil, nil
    for _, p in ipairs(points) do
        local y = self:resolveHeightAt(p.x, p.z, p.y)
        local wp = ADGraphManager:recordWayPoint(p.x, y, p.z, previousId ~= nil, dual, false,
            previousId or 0, flags, false)
        previousId = (wp ~= nil and wp.id) or ADGraphManager:getWayPointsCount()
        firstId = firstId or previousId
    end
    return firstId, previousId
end

--- A spline between two existing waypoints, falling back to a straight connection when the mod
--- declines to interpolate - which it does for short or already-connected pairs, and which is an
--- ordinary outcome rather than a failure.
function ADFlyoverEditor:splineConnectIds(startId, endId, dual, flags)
    local a = ADGraphManager:getWayPointById(startId)
    local b = ADGraphManager:getWayPointById(endId)
    if a == nil or b == nil then
        return false
    end
    if type(AutoDrive.splineInterpolationUserCurvature) ~= "number" then
        AutoDrive.splineInterpolationUserCurvature = AutoDrive.FLYOVER_DEFAULT_CURVATURE
    end

    local built = pcall(function() self:buildSplineInterpolation(a, b) end)
    local interpolation = AutoDrive.splineInterpolation
    if not built or interpolation == nil or not interpolation.valid
        or interpolation.waypoints == nil or #interpolation.waypoints <= 2 then
        ADGraphManager:toggleConnectionBetween(a, b, false, dual, false)
        return true
    end

    local middle = {}
    for i, wp in ipairs(interpolation.waypoints) do
        if i ~= 1 and i < #interpolation.waypoints then
            middle[#middle + 1] = { x = wp.x, y = wp.y, z = wp.z }
        end
    end
    ADGraphManager:createSplineConnection(startId, middle, endId, dual, false)
    if flags ~= nil and flags ~= AutoDrive.FLAG_NONE then
        local total = ADGraphManager:getWayPointsCount()
        for id = total - #middle + 1, total do
            ADGraphManager:setWayPointFlags(id, flags, false)
        end
    end
    return true
end

--- Commit for both parallel and siding.
---
--- Direction: the new run mirrors the source. A two-way span gives a two-way track, because
--- "opposite" means nothing there. A one-way span gives a track running the OTHER way, which is the
--- point of laying one - a return lane rather than a second lane going the same way - and it is
--- done simply by laying the points down back to front.
---
--- Siding additionally splines both ends into the span it came from, giving a genuine alternative
--- route: from one end you can take the main line or the siding, rejoining at the other. No
--- dividing is needed, because the attachment points are the span's own endpoints, which already
--- exist - that is what selecting a span rather than a length buys.
function ADFlyoverEditor:commitOffset()
    local pts, span = self:offsetSpanPoints()
    local newPoints = self.offsetPreview
    if pts == nil or span == nil or newPoints == nil or #newPoints < 2 then
        if self.offsetBlockedBy ~= nil then
            Logging.warning("[FlyoverEditor]: %s", self.offsetBlockedBy)
        end
        self:cancelOffset()
        return
    end

    local first = ADGraphManager:getWayPointById(span[1])
    local second = ADGraphManager:getWayPointById(span[2])
    local dual = ADGraphManager:isDualRoad(first, second)
    local flags = second.flags or AutoDrive.FLAG_NONE
    local siding = self.tool == self.TOOL.SIDING

    local laying = newPoints
    if not dual and not siding then
        local flipped = {}
        for i = #newPoints, 1, -1 do
            flipped[#flipped + 1] = newPoints[i]
        end
        laying = flipped
    end

    ADEditorHistory:snapshot(siding and "siding" or "parallel track")
    local firstNewId, lastNewId = self:createRunFrom(laying, dual, flags)

    if siding and firstNewId ~= nil and lastNewId ~= nil then
        self:splineConnectIds(span[1], firstNewId, dual, flags)
        self:splineConnectIds(lastNewId, span[#span], dual, flags)
    end

    Logging.info("[FlyoverEditor]: laid a %s of %d waypoint(s) %.1fm to the %s%s.",
        siding and "siding" or "parallel track", #laying, self.offsetDistance,
        (self.offsetSide or 1) >= 0 and "left" or "right",
        siding and ", splined in at both ends" or (dual and ", two-way" or ", running opposite"))

    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelOffset()
    if self.offsetFromId ~= nil or self.offsetToId ~= nil then
        Logging.info("[FlyoverEditor]: cancelled the span.")
    end
    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
end

function ADFlyoverEditor:straightenClick()
    if self.hoverId == nil then
        return
    end

    if self.straightenFromId == nil then
        self.straightenFromId = self.hoverId
        Logging.info("[FlyoverEditor]: straightening from id=%s; click the far end of the span.",
            tostring(self.straightenFromId))
        return
    end

    if self.hoverId == self.straightenFromId then
        return
    end

    local span = self:runPathBetween(self.straightenFromId, self.hoverId)
    if span == nil then
        Logging.warning("[FlyoverEditor]: id=%s is not connected to id=%s, so they are not two ends of one span.",
            tostring(self.hoverId), tostring(self.straightenFromId))
        return
    end

    self.straightenToId = self.hoverId
    self.straightenPreview = nil
    Logging.info("[FlyoverEditor]: span of %d waypoint(s). Wheel sets the tolerance (%.2fm), right-click applies.",
        #span, self.straightenTolerance)
end

--- Points of the current span, or nil.
function ADFlyoverEditor:straightenSpanPoints()
    if self.straightenFromId == nil or self.straightenToId == nil then
        return nil, nil
    end
    local span = self:runPathBetween(self.straightenFromId, self.straightenToId)
    if span == nil or #span < 3 then
        return nil, span
    end
    local pts = {}
    for _, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
        end
    end
    if #pts < 3 then
        return nil, span
    end
    return pts, span
end

--- `count` interior points spread evenly by arc length along `pts`, endpoints included.
local function respreadAlong(pts, count)
    local cumulative = { 0 }
    for i = 2, #pts do
        cumulative[i] = cumulative[i - 1]
            + MathUtil.vector2Length(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z)
    end
    local total = cumulative[#pts]
    if total <= 0 then
        return nil
    end

    local function pointAt(distance)
        for i = 2, #pts do
            if cumulative[i] >= distance then
                local segLen = cumulative[i] - cumulative[i - 1]
                local f = segLen > 0 and (distance - cumulative[i - 1]) / segLen or 0
                return {
                    x = pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f,
                    z = pts[i - 1].z + (pts[i].z - pts[i - 1].z) * f,
                }
            end
        end
        return { x = pts[#pts].x, z = pts[#pts].z }
    end

    local out = { { x = pts[1].x, y = pts[1].y, z = pts[1].z } }
    for i = 1, count do
        out[#out + 1] = pointAt(total * i / (count + 1))
    end
    out[#out + 1] = { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z }
    return out
end

function ADFlyoverEditor:updateStraightenPreview()
    local pts, span = self:straightenSpanPoints()
    if pts == nil then
        self.straightenPreview = nil
        return
    end

    local simplified = ADPolygonUtils.simplifyOpenChainRDP(pts, self.straightenTolerance)
    if simplified == nil or #simplified < 2 then
        self.straightenPreview = nil
        return
    end

    -- Same interior count as the span had, respread along the simplified shape.
    local result = respreadAlong(simplified, #pts - 2)
    if result == nil then
        self.straightenPreview = nil
        return
    end
    for i = 2, #result - 1 do
        result[i].y = self:resolveHeightAt(result[i].x, result[i].z, heightAlongChain(pts, result[i].x, result[i].z))
    end

    self.straightenPreview = result
    self.straightenKept = #simplified
end

function ADFlyoverEditor:commitStraighten()
    local pts, span = self:straightenSpanPoints()
    local newPoints = self.straightenPreview
    if pts == nil or span == nil or newPoints == nil then
        self:cancelStraighten()
        return
    end

    local first = ADGraphManager:getWayPointById(span[1])
    local second = ADGraphManager:getWayPointById(span[2])
    local dual = ADGraphManager:isDualRoad(first, second)
    local flags = second.flags or AutoDrive.FLAG_NONE

    ADEditorHistory:snapshot("straighten span")
    self:replaceChainInterior(span, newPoints, dual, flags)

    Logging.info("[FlyoverEditor]: straightened a %d-point span at %.2fm tolerance (%d point(s) were a real bend).",
        #pts, self.straightenTolerance, math.max(0, (self.straightenKept or 2) - 2))

    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelStraighten()
    if self.straightenFromId ~= nil or self.straightenToId ~= nil then
        Logging.info("[FlyoverEditor]: cancelled the straighten span.")
    end
    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
end

function ADFlyoverEditor:divideClick()
    if self.hoverId == nil then
        return
    end

    if self.divideFromId == nil then
        self.divideFromId = self.hoverId
        Logging.info("[FlyoverEditor]: dividing from id=%s; click the far end of the span.", tostring(self.divideFromId))
        return
    end

    if self.divideToId == nil then
        if self.hoverId == self.divideFromId then
            return
        end
        local span = self:runPathBetween(self.divideFromId, self.hoverId)
        if span == nil then
            Logging.warning("[FlyoverEditor]: id=%s is not connected to id=%s, so they are not two ends of one span.",
                tostring(self.hoverId), tostring(self.divideFromId))
            return
        end
        self.divideToId = self.hoverId
        -- Start from what is already there, so the wheel adjusts from the current spacing rather
        -- than jumping to an arbitrary default.
        self.divideCount = math.max(0, #span - 2)
        Logging.info("[FlyoverEditor]: span of %d waypoint(s), %d between the ends. Wheel to change, right-click to apply.",
            #span, self.divideCount)
        return
    end

    -- Both ends chosen: another click re-picks the far end.
    if self.hoverId ~= self.divideFromId then
        self.divideToId = self.hoverId
        self.dividePreview = nil
        -- Reset the count to what this span already has, exactly as the second click does.
        -- Without this the count carried over from the previous span, so the same wheel position
        -- meant something entirely different from one span to the next - 39 points wheeled up on a
        -- long span were then applied to a single segment.
        self.divideCount = self:currentInteriorCount(self.divideFromId, self.divideToId)
        Logging.info("[FlyoverEditor]: span far end moved to id=%s, %d point(s) between the ends. Right-click to clear and start again.",
            tostring(self.divideToId), self.divideCount)
    end
end

--- How many waypoints currently sit between two ends, or 0 if they are not connected.
function ADFlyoverEditor:currentInteriorCount(fromId, toId)
    local span = self:runPathBetween(fromId, toId)
    if span == nil then
        return 0
    end
    return math.max(0, #span - 2)
end

--- Wheel handler. Returns true when the wheel was consumed, which is what stops the camera zoom.
function ADFlyoverEditor:handleWheel(offset)
    if offset == nil or offset == 0 then
        return false
    end
    local step = offset > 0 and 1 or -1

    -- Siding: the wheel is the LENGTH, because that is the dimension that changes per site. The
    -- offset is a shape you settle on once, so it lives in the panel's number field instead.
    if self.tool == self.TOOL.SIDING and self.sidingAnchorId ~= nil then
        local setting = ADFlyoverSettings.settings.sidingLength
        if setting ~= nil then
            local nextIndex = math.max(1, math.min(#setting.values, setting.current + step))
            if nextIndex ~= setting.current then
                ADFlyoverSettings.setIndex("sidingLength", nextIndex)
            end
        end
        return true
    end

    if self.tool == self.TOOL.PARALLEL and self.offsetToId ~= nil then
        self.offsetDistance = math.max(AutoDrive.FLYOVER_OFFSET_MIN,
            math.min(AutoDrive.FLYOVER_OFFSET_MAX,
                self.offsetDistance + step * AutoDrive.FLYOVER_OFFSET_STEP))
        self.offsetCache = nil
        return true
    end

    if self.tool == self.TOOL.STRAIGHTEN and self.straightenToId ~= nil then
        self.straightenTolerance = math.max(AutoDrive.FLYOVER_STRAIGHTEN_MIN,
            math.min(AutoDrive.FLYOVER_STRAIGHTEN_MAX,
                self.straightenTolerance + step * AutoDrive.FLYOVER_STRAIGHTEN_STEP))
        return true
    end

    if self.tool == self.TOOL.DIVIDE and self.divideToId ~= nil then
        self.divideCount = math.max(0, math.min(AutoDrive.FLYOVER_DIVIDE_MAX, self.divideCount + step))
        return true
    end

    -- Only while a drag is actually in progress, NOT merely because the move tool is selected.
    -- Claiming the wheel for the whole tool would take camera zoom away for as long as move was
    -- active, which is most of the time. Holding the button is an unambiguous signal that the
    -- wheel is wanted for the drag; let go and it is the zoom again. Same rule as divide and
    -- smooth, which only claim it while a span is pending.
    if self.tool == self.TOOL.MOVE and self.dragId ~= nil then
        self:setFalloffRadius(self.falloffRadius + step * AutoDrive.FLYOVER_FALLOFF_WHEEL_STEP)
        return true
    end

    -- The wheel reaches here (measured: 211 offers in one session) but declines while the move tool
    -- is up, so say which half of the guard failed rather than needing another session to find out.
    if self.tool == self.TOOL.MOVE then
        Logging.info("[FlyoverEditor]: wheel declined in move - dragId=%s (no drag in progress, so "
            .. "the wheel stays with the camera zoom).", tostring(self.dragId))
    end

    if self.tool == self.TOOL.SMOOTH and self.smoothToId ~= nil then
        -- Each mode gets the number it actually uses. Rebuild ignores strength entirely - its
        -- pipeline is a fixed smooth/resample/smooth - so the wheel appeared dead there while
        -- quietly changing a value nothing read.
        if self.smoothMode == self.SMOOTH_MODE.REBUILD then
            self.smoothSpacing = math.max(AutoDrive.FLYOVER_SPACING_MIN,
                math.min(AutoDrive.FLYOVER_SPACING_MAX,
                    self.smoothSpacing + step * AutoDrive.FLYOVER_SPACING_STEP))
        else
            self.smoothStrength = math.max(0, math.min(AutoDrive.FLYOVER_SMOOTH_MAX, self.smoothStrength + step))
        end
        return true
    end

    return false
end

--- Evenly spaced points along the span, by arc length.
function ADFlyoverEditor:updateDividePreview()
    if self.divideFromId == nil or self.divideToId == nil then
        self.dividePreview = nil
        return
    end

    local span = self:runPathBetween(self.divideFromId, self.divideToId)
    if span == nil or #span < 2 then
        self.dividePreview = nil
        return
    end

    local pts = {}
    for _, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            table.insert(pts, { x = wp.x, y = wp.y, z = wp.z })
        end
    end
    if #pts < 2 then
        self.dividePreview = nil
        return
    end

    -- Cumulative length, so points can be placed at exact fractions of the total.
    local cumulative = { 0 }
    for i = 2, #pts do
        cumulative[i] = cumulative[i - 1] + MathUtil.vector2Length(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z)
    end
    local total = cumulative[#pts]
    if total <= 0 then
        self.dividePreview = nil
        return
    end

    local function pointAt(distance)
        for i = 2, #pts do
            if cumulative[i] >= distance then
                local segLen = cumulative[i] - cumulative[i - 1]
                local f = segLen > 0 and (distance - cumulative[i - 1]) / segLen or 0
                return {
                    x = pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f,
                    z = pts[i - 1].z + (pts[i].z - pts[i - 1].z) * f
                }
            end
        end
        return { x = pts[#pts].x, z = pts[#pts].z }
    end

    local result = { { x = pts[1].x, y = pts[1].y, z = pts[1].z } }
    for i = 1, self.divideCount do
        local p = pointAt(total * i / (self.divideCount + 1))
        -- Reference the height where this point actually is, not where the span began.
        p.y = self:resolveHeightAt(p.x, p.z, heightAlongChain(pts, p.x, p.z))
        table.insert(result, p)
    end
    table.insert(result, { x = pts[#pts].x, y = pts[#pts].y, z = pts[#pts].z })

    self.dividePreview = result
    -- Divide splits at intersections rather than refusing, so nothing blocks it any more.
    self.divideBlockedBy = nil
end

function ADFlyoverEditor:cancelDivide()
    if self.divideFromId ~= nil or self.divideToId ~= nil then
        Logging.info("[FlyoverEditor]: divide cancelled.")
    end
    self.divideFromId, self.divideToId, self.dividePreview = nil, nil, nil
    self.divideBlockedBy = nil
end

function ADFlyoverEditor:commitDivide()
    local span = self:runPathBetween(self.divideFromId, self.divideToId)
    local newPoints = self.dividePreview
    if span == nil or newPoints == nil or #span < 2 then
        self:cancelDivide()
        return
    end


    local second = ADGraphManager:getWayPointById(span[2])
    local first = ADGraphManager:getWayPointById(span[1])
    local dual = ADGraphManager:isDualRoad(first, second)
    local flags = second.flags or AutoDrive.FLAG_NONE

    ADEditorHistory:snapshot("divide span")
    self:divideSpanInPieces(span, self.divideCount)

    self.divideFromId, self.divideToId, self.dividePreview = nil, nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

-- ---------------------------------------------------------------------------------------------
-- Convert a track: priority, direction, or reversed.
--
-- Scoped the same way as delete - one waypoint, or the whole run out to the junctions at each end -
-- because these are the same kind of edit: something you decide about a stretch of route, not about
-- an individual point.
-- ---------------------------------------------------------------------------------------------

ADFlyoverEditor.CONVERT_OP = { SECONDARY = 1, PRIMARY = 2, TWOWAY = 3, ONEWAY = 4, REVERSE = 5 }
ADFlyoverEditor.CONVERT_OP_NAMES = { "secondary", "primary", "two-way", "one-way", "reversed" }

function ADFlyoverEditor:cycleConvertOp()
    self.convertOp = (self.convertOp % #self.CONVERT_OP_NAMES) + 1
    Logging.info("[FlyoverEditor]: convert will make it %s.", self.CONVERT_OP_NAMES[self.convertOp])
end

function ADFlyoverEditor:cycleConvertScope()
    self.convertScope = (self.convertScope % #self.DELETE_SCOPE_NAMES) + 1
    Logging.info("[FlyoverEditor]: convert applies to %s.", self.DELETE_SCOPE_NAMES[self.convertScope])
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

function ADFlyoverEditor:convertAtCursor()
    if self.hoverId == nil then
        return
    end

    -- Which waypoints, and in what order. Direction work needs the run as an ordered polyline, not
    -- a set: "one-way" and "reversed" only mean anything relative to travelling along it.
    local ordered
    -- Points whose FLAGS may change. The boundary junctions are deliberately not in here: their
    -- priority belongs to the routes that meet at them, not to this leg.
    local flagIds = nil
    if self.convertScope == self.DELETE_SCOPE.RUN then
        local run, count, _, junctions = self:collectRunBetweenJunctions(self.hoverId)
        if count >= AutoDrive.FLYOVER_DELETE_RUN_MAX then
            Logging.warning("[FlyoverEditor]: that run reaches %d waypoints, at or past the safety cap - refusing.", count)
            return
        end
        ordered = self:orderRun(run, self.hoverId)
        flagIds = {}
        for _, id in ipairs(ordered) do
            table.insert(flagIds, id)
        end

        -- Extend the ordered list onto the junctions at each end. Without this the connections
        -- BETWEEN the last run point and the junction were never touched, so converting a leg to
        -- two-way left its two end connections one-way and the leg still could not be driven both
        -- ways - the change looked like it had not taken at all.
        local function junctionNeighbourOf(id)
            local wp = ADGraphManager:getWayPointById(id)
            if wp == nil then
                return nil
            end
            for _, listName in ipairs({ "out", "incoming" }) do
                for _, other in pairs(wp[listName] or {}) do
                    if junctions[other] then
                        return other
                    end
                end
            end
            return nil
        end

        if #ordered > 0 then
            local head = junctionNeighbourOf(ordered[1])
            if head ~= nil then
                table.insert(ordered, 1, head)
            end
            local tail = junctionNeighbourOf(ordered[#ordered])
            if tail ~= nil and tail ~= head then
                table.insert(ordered, tail)
            end
        end
    else
        -- A single waypoint on its own has no direction, so the pair either side of it is the
        -- smallest thing the direction operations can act on.
        ordered = { self.hoverId }
        local wp = ADGraphManager:getWayPointById(self.hoverId)
        if wp ~= nil and self.convertOp ~= self.CONVERT_OP.SECONDARY and self.convertOp ~= self.CONVERT_OP.PRIMARY then
            for _, other in pairs(wp.out or {}) do
                table.insert(ordered, other)
                break
            end
        end
    end

    if #ordered == 0 then
        return
    end

    ADEditorHistory:snapshot("convert " .. self.CONVERT_OP_NAMES[self.convertOp])

    local op = self.convertOp
    local changed = 0

    if op == self.CONVERT_OP.SECONDARY or op == self.CONVERT_OP.PRIMARY then
        local flags = (op == self.CONVERT_OP.SECONDARY) and AutoDrive.FLAG_SUBPRIO or AutoDrive.FLAG_NONE
        for _, id in ipairs(flagIds or ordered) do
            ADGraphManager:setWayPointFlags(id, flags, false)
            changed = changed + 1
        end
    else
        for i = 1, #ordered - 1 do
            local a, b = ordered[i], ordered[i + 1]
            local aw = ADGraphManager:getWayPointById(a)
            local bw = ADGraphManager:getWayPointById(b)
            if aw ~= nil and bw ~= nil then
                local forward = table.contains(aw.out, b)
                local backward = table.contains(bw.out, a)

                if op == self.CONVERT_OP.TWOWAY then
                    if not (forward and backward) then
                        addLink(a, b)
                        addLink(b, a)
                        changed = changed + 1
                    end
                elseif op == self.CONVERT_OP.ONEWAY then
                    -- Keep the walk direction. On an already two-way run there is no existing
                    -- direction to preserve, so one has to be chosen; 'reversed' flips it if it
                    -- came out the wrong way round.
                    if forward and backward then
                        removeLink(b, a)
                        changed = changed + 1
                    elseif not forward and backward then
                        removeLink(b, a)
                        addLink(a, b)
                        changed = changed + 1
                    elseif not forward and not backward then
                        addLink(a, b)
                        changed = changed + 1
                    end
                elseif op == self.CONVERT_OP.REVERSE then
                    if forward ~= backward then
                        if forward then
                            removeLink(a, b)
                            addLink(b, a)
                        else
                            removeLink(b, a)
                            addLink(a, b)
                        end
                        changed = changed + 1
                    end
                end
            end
        end
    end

    Logging.info("[FlyoverEditor]: converted %s to %s (%d change(s)).",
        (op == self.CONVERT_OP.SECONDARY or op == self.CONVERT_OP.PRIMARY)
            and string.format("%d waypoint(s)", #(flagIds or ordered))
            or string.format("%d connection(s) across %d waypoint(s), junctions at the ends included",
                #ordered - 1, #ordered),
        self.CONVERT_OP_NAMES[op], changed)
    if changed == 0 then
        Logging.info("[AD]   nothing to do - it was already %s.", self.CONVERT_OP_NAMES[op])
    end

    ADGraphManager:markChanges()
end

-- ---------------------------------------------------------------------------------------------
-- Merge two tracks, chosen by clicking one waypoint on each.
--
-- This replaces an earlier version that swept a radius around the cursor and guessed which pairs
-- belonged together. That guessing was the whole problem: it could not tell two lanes of a road
-- from a run hairpinning back past itself, so it needed a graph-distance heuristic to avoid
-- destroying turnarounds, and it still gave no way to say WHICH two tracks were meant.
--
-- Naming the two tracks removes the ambiguity at the source. Each click seeds a walk along its own
-- run, and only pairs with one point from each run are considered - so a run can never be merged
-- into itself, whatever its shape.
-- ---------------------------------------------------------------------------------------------

--- Walk outward from a seed along its run, stopping at junctions. A junction is a waypoint with
--- more than two distinct neighbours: the run genuinely branches there, and continuing through it
--- would drag an unrelated route into the merge.
--- `blocked` marks waypoints the walk must not enter. Used to wall off the span being merged, so
--- collecting the OTHER track cannot run through the point where the two join and come back along
--- the span itself.
function ADFlyoverEditor:collectRun(seedId, maxNodes, blocked)
    maxNodes = maxNodes or AutoDrive.FLYOVER_MERGE_MAX_RUN
    blocked = blocked or {}

    local run = { [seedId] = true }
    local count = 1
    local junctions = 0
    local frontier = { seedId }

    while #frontier > 0 and count < maxNodes do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                local neighbours = {}
                for _, listName in ipairs({ "out", "incoming" }) do
                    for _, other in pairs(wp[listName] or {}) do
                        if not table.contains(neighbours, other) then
                            table.insert(neighbours, other)
                        end
                    end
                end

                -- Walk through ordinary points and through the seed itself, but stop at a junction
                -- reached from elsewhere - that is where this run ends and another begins.
                if #neighbours <= 2 or id == seedId then
                    for _, other in ipairs(neighbours) do
                        if not run[other] and not blocked[other] then
                            run[other] = true
                            count = count + 1
                            table.insert(nextFrontier, other)
                        end
                    end
                else
                    junctions = junctions + 1
                end
            end
        end
        frontier = nextFrontier
    end

    return run, count, junctions
end

--- Shortest path between two waypoints along their run, ignoring link direction. Direction has to
--- be ignored: the span is being pointed at on screen, and whether the two clicks happen to go with
--- or against the one-way arrows is not something the user should have to think about.
function ADFlyoverEditor:runPathBetween(startId, endId, maxNodes)
    maxNodes = maxNodes or AutoDrive.FLYOVER_MERGE_MAX_RUN

    local cameFrom = { [startId] = false }
    local frontier = { startId }
    local visited = 1
    local found = startId == endId

    while #frontier > 0 and not found and visited < maxNodes do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                for _, listName in ipairs({ "out", "incoming" }) do
                    for _, other in pairs(wp[listName] or {}) do
                        if cameFrom[other] == nil then
                            cameFrom[other] = id
                            visited = visited + 1
                            if other == endId then
                                found = true
                                break
                            end
                            table.insert(nextFrontier, other)
                        end
                    end
                    if found then break end
                end
            end
            if found then break end
        end
        frontier = nextFrontier
    end

    if not found then
        return nil
    end

    local path, id = {}, endId
    while id do
        table.insert(path, 1, id)
        id = cameFrom[id]
    end
    return path
end

--- Work out what a merge would take, and remember it so draw() can show it.
---
--- Where two tracks converge and separate again the overlapping stretch is genuinely hard to see:
--- the two lines are within a metre of each other, drawn on top of each other, and the point where
--- they diverge past the merge distance is invisible. Guessing where to put the span clicks is
--- what makes the tool fiddly, and guessing wrong is what makes it fail. Showing the answer before
--- committing turns that guess into something you can see.
---
--- Recomputed only when the span or the hovered waypoint changes, not every frame.
function ADFlyoverEditor:updateMergePreview()
    if self.mergeFromId == nil then
        self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
        return
    end

    -- The far end of the span is whichever is settled: the locked second click, else whatever is
    -- hovered, so the corridor is visible while still choosing it.
    local endId = self.mergeToId or self.hoverId
    if endId == nil or endId == self.mergeFromId then
        self.mergePreviewSpan, self.mergePreviewOther = nil, nil
        return
    end

    local queryId = tostring(self.mergeFromId) .. ":" .. tostring(endId) .. ":" .. tostring(self.mergeToId ~= nil and self.hoverId or "")
    if queryId == self.mergePreviewQueryId then
        return
    end
    self.mergePreviewQueryId = queryId

    local span = self:runPathBetween(self.mergeFromId, endId)
    self.mergePreviewSpan = span
    self.mergePreviewOther = nil
    if span == nil then
        return
    end

    local inSpan = {}
    for _, id in ipairs(span) do
        inSpan[id] = true
    end

    local mergeDistance = ADFlyoverSettings.get("flyoverMergeDistance") or AutoDrive.FLYOVER_MERGE_DISTANCE
    local nearSpan = {}
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if not inSpan[wp.id] and self:distanceToTrack(wp.x, wp.z, span) <= mergeDistance then
            nearSpan[wp.id] = true
        end
    end

    -- Once the span is locked, narrow the preview to the track under the cursor, which is what the
    -- third click will actually pick.
    if self.mergeToId ~= nil and self.hoverId ~= nil and nearSpan[self.hoverId] then
        self.mergePreviewOther = self:connectedWithin(self.hoverId, nearSpan)
    else
        self.mergePreviewOther = nearSpan
    end
end

function ADFlyoverEditor:mergeClick()
    if self.hoverId == nil then
        return
    end

    -- Three clicks: two on the same track marking the length to merge, then one on the other
    -- track. The span is what stops a merge running away down the whole length of both runs.
    if self.mergeFromId == nil then
        self.mergeFromId = self.hoverId
        Logging.info("[FlyoverEditor]: merge span starts at id=%s; click the other end of the span on the SAME track.",
            tostring(self.mergeFromId))
        return
    end

    if self.mergeToId == nil then
        if self.hoverId == self.mergeFromId then
            return
        end
        local span = self:runPathBetween(self.mergeFromId, self.hoverId)
        if span == nil then
            Logging.warning("[FlyoverEditor]: id=%s is not connected to id=%s, so those are not two ends of one span. The first two clicks both go on the SAME track.",
                tostring(self.hoverId), tostring(self.mergeFromId))
            return
        end
        self.mergeToId = self.hoverId
        Logging.info("[FlyoverEditor]: merge span is %d waypoint(s); now click a point on the OTHER track.", #span)
        return
    end

    local fromId, toId = self.mergeFromId, self.mergeToId
    self.mergeFromId, self.mergeToId = nil, nil
    self:mergeTracks(fromId, toId, self.hoverId)
end

--- Merge a span of one track with the stretch of another track running alongside it.
---
--- The other track is found GEOMETRICALLY - every waypoint outside the span that lies within the
--- merge distance of it - rather than by walking outward from the third click. Walking was too
--- fragile on a real network: the span is itself a shortest path, and where two lanes interconnect
--- it can consume the very neighbours the walk needs, leaving it stranded on the seed with nothing
--- to measure. Proximity to the span is also simply a better definition of "the track running
--- alongside this one" than "whatever is reachable from here".
---
--- The third click still matters: it says WHICH nearby track is meant, and nothing is merged
--- unless it is one of the waypoints found.
---
--- Separation is measured perpendicularly, from each waypoint to the other track as a polyline,
--- not from waypoint to waypoint. Two separately recorded tracks do not have their points aligned,
--- so a nearest-waypoint measure reads several metres where the lanes are less than one apart.
function ADFlyoverEditor:mergeTracks(spanStartId, spanEndId, seedB)
    local span = self:runPathBetween(spanStartId, spanEndId)
    if span == nil then
        Logging.warning("[FlyoverEditor]: lost the span between id=%s and id=%s.",
            tostring(spanStartId), tostring(spanEndId))
        return
    end

    local inSpan = {}
    for _, id in ipairs(span) do
        inSpan[id] = true
    end

    if inSpan[seedB] then
        Logging.warning("[FlyoverEditor]: id=%s is part of the span itself; the third click goes on the OTHER track.",
            tostring(seedB))
        return
    end

    local mergeDistance = ADFlyoverSettings.get("flyoverMergeDistance") or AutoDrive.FLYOVER_MERGE_DISTANCE

    -- Everything running alongside the span, whatever it is connected to.
    local nearSpan, nearCount = {}, 0
    local nearestOutside = math.huge
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if not inSpan[wp.id] then
            local dist = self:distanceToTrack(wp.x, wp.z, span)
            if dist <= mergeDistance then
                nearSpan[wp.id] = true
                nearCount = nearCount + 1
            elseif dist < nearestOutside then
                nearestOutside = dist
            end
        end
    end

    if not nearSpan[seedB] then
        local seed = ADGraphManager:getWayPointById(seedB)
        local seedDist = seed ~= nil and self:distanceToTrack(seed.x, seed.z, span) or nil
        Logging.warning("[FlyoverEditor]: the waypoint clicked for the other track is %s from the span, further than the %.1fm merge distance. Raise Flyover: Merge Distance, or click a point that actually runs alongside the span.",
            seedDist ~= nil and string.format("%.2fm", seedDist) or "an unknown distance",
            mergeDistance)
        return
    end

    -- Keep only the piece connected to the third click, so a different track that happens to pass
    -- close by somewhere else along the span is not swept in as well.
    local divergence = ADFlyoverSettings.get("flyoverMergeDivergence") or AutoDrive.FLYOVER_MERGE_DIVERGENCE
    local runB, bridged = self:connectedWithin(seedB, nearSpan, divergence)

    -- Order the other track by how far along the SPAN each of its waypoints sits, not by walking
    -- its own connections. The walk cannot cross the gap where the tracks diverged - that is the
    -- whole reason the divergence tolerance exists - so ordering that way returned only the piece
    -- on one side of the gap and the merge stopped there regardless of the tolerance.
    local orderedB = {}
    local alongOf = {}
    for id in pairs(runB) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            local _, _, _, along = self:distanceToTrack(wp.x, wp.z, span)
            alongOf[id] = along
            table.insert(orderedB, id)
        end
    end
    table.sort(orderedB, function(a, b) return alongOf[a] < alongOf[b] end)
    local countB = 0
    for _ in pairs(runB) do
        countB = countB + 1
    end

    if #orderedB < 2 then
        Logging.warning("[FlyoverEditor]: only %d waypoint(s) of the other track run within %.1fm of the span - not enough to merge. %d waypoint(s) were near the span in total.",
            #orderedB, mergeDistance, nearCount)
        return
    end

    -- Which span waypoints run close alongside it, and where their centre line is.
    local aInside, aTarget = {}, {}
    local nearestMiss = math.huge
    for _, idA in ipairs(span) do
        local a = ADGraphManager:getWayPointById(idA)
        if a ~= nil then
            local dist, cx, cz = self:distanceToTrack(a.x, a.z, orderedB)
            if dist <= mergeDistance then
                table.insert(aInside, idA)
                aTarget[idA] = { x = (a.x + cx) / 2, z = (a.z + cz) / 2 }
            elseif dist < nearestMiss then
                nearestMiss = dist
            end
        end
    end

    if #aInside == 0 then
        Logging.info("[FlyoverEditor]: no part of the %d-waypoint span runs within %.1fm of the other track. Closest they come is %s.",
            #span, mergeDistance,
            nearestMiss < math.huge and string.format("%.2fm", nearestMiss) or "not measurable")
        return
    end

    local bInside, inB = {}, {}
    for _, idB in ipairs(orderedB) do
        table.insert(bInside, idB)
        inB[idB] = true
    end

    ADEditorHistory:snapshot("merge tracks")
    self:absorbTrack(span, aInside, aTarget, bInside, inB)

    Logging.info("[FlyoverEditor]: merged %d of %d span waypoint(s) with %d from the other track, within %.1fm.",
        #aInside, #span, #bInside, mergeDistance)
    if nearestMiss < math.huge then
        Logging.info("[AD]   the rest of the span stays separate; nearest it came was %.2fm.", nearestMiss)
    end
    if bridged > 0 then
        Logging.info("[AD]   crossed %d waypoint(s) where the tracks pulled apart, within the %.0fm divergence tolerance, and picked the track up again on the far side.",
            bridged, divergence)
    end
    if countB < nearCount then
        Logging.info("[AD]   %d other waypoint(s) were also near the span but not connected to the one clicked, and were left alone.",
            nearCount - countB)
    end
end

--- The waypoints reachable from seedId, staying near the span but tolerating gaps where the two
--- tracks pull apart.
---
--- Requiring every step to be inside the corridor was the clumsiness: real tracks converge and
--- diverge along their length - round an obstacle, past a gateway, through a yard - and the first
--- place they part company by more than the merge distance ended the walk. What should have been
--- one merge became several, each needing its own span picked by hand.
---
--- The walk may now leave the corridor and carry on, as long as it gets back inside within
--- `tolerance` metres of travel. Points outside the corridor are traversed but never returned:
--- where the tracks genuinely separate they stay separate, which is the point. Only the reachable
--- near-span waypoints come back.
function ADFlyoverEditor:connectedWithin(seedId, allowed, tolerance)
    tolerance = tolerance or 0

    -- debt = how far this walk has travelled since it was last inside the corridor.
    local debt = { [seedId] = 0 }
    local found = { [seedId] = allowed[seedId] == true }
    local frontier = { seedId }
    local bridged = 0

    while #frontier > 0 do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                for _, listName in ipairs({ "out", "incoming" }) do
                    for _, other in pairs(wp[listName] or {}) do
                        local ow = ADGraphManager:getWayPointById(other)
                        if ow ~= nil then
                            local step = MathUtil.vector2Length(ow.x - wp.x, ow.z - wp.z)
                            local newDebt
                            if allowed[other] then
                                newDebt = 0
                            else
                                newDebt = debt[id] + step
                            end

                            if newDebt <= tolerance and (debt[other] == nil or newDebt < debt[other]) then
                                if debt[other] == nil and not allowed[other] then
                                    bridged = bridged + 1
                                end
                                debt[other] = newDebt
                                if allowed[other] then
                                    found[other] = true
                                end
                                table.insert(nextFrontier, other)
                            end
                        end
                    end
                end
            end
        end
        frontier = nextFrontier
    end

    return found, bridged
end

--- Move the span onto the centre line, pull the other track's connections onto it, make the merged
--- stretch two-way, and delete what was absorbed.
function ADFlyoverEditor:absorbTrack(span, aInside, aTarget, bInside, inB)
    -- Reposition first, so "nearest surviving waypoint" below is measured against where the merged
    -- lane actually ends up rather than where it used to be.
    for _, idA in ipairs(aInside) do
        local a = ADGraphManager:getWayPointById(idA)
        local target = aTarget[idA]
        if a ~= nil and target ~= nil then
            a.x, a.z = target.x, target.z
            a.y = AutoDrive:getTerrainHeightAtWorldPos(a.x, a.z)
        end
    end

    local function nearestSurviving(x, z)
        local bestId, bestSq = nil, math.huge
        for _, idA in ipairs(aInside) do
            local a = ADGraphManager:getWayPointById(idA)
            if a ~= nil then
                local dx, dz = a.x - x, a.z - z
                local d = dx * dx + dz * dz
                if d < bestSq then
                    bestId, bestSq = idA, d
                end
            end
        end
        return bestId
    end

    local function addLink(fromId, toId)
        if fromId == nil or toId == nil or fromId == toId then
            return
        end
        local from = ADGraphManager:getWayPointById(fromId)
        local to = ADGraphManager:getWayPointById(toId)
        if from == nil or to == nil then
            return
        end
        if not table.contains(from.out, toId) then
            table.insert(from.out, toId)
        end
        if not table.contains(to.incoming, fromId) then
            table.insert(to.incoming, fromId)
        end
    end

    -- Anything outside the absorbed stretch that pointed into it has to be re-attached, or the
    -- routes either side of the merge are severed. Direction is preserved on both sides.
    for _, idB in ipairs(bInside) do
        local b = ADGraphManager:getWayPointById(idB)
        if b ~= nil then
            local anchor = nearestSurviving(b.x, b.z)
            for _, other in pairs(b.out or {}) do
                if not inB[other] then
                    addLink(anchor, other)
                end
            end
            for _, other in pairs(b.incoming or {}) do
                if not inB[other] then
                    addLink(other, anchor)
                end
            end
        end
    end

    -- The absorbed track carried the opposite direction of travel. Deleting it would leave the
    -- merged stretch one-way, which is the whole thing this tool exists to fix, so the reverse
    -- links are added explicitly along the span.
    local insideSet = {}
    for _, idA in ipairs(aInside) do
        insideSet[idA] = true
    end
    for i = 1, #span - 1 do
        local a, b = span[i], span[i + 1]
        if insideSet[a] and insideSet[b] then
            addLink(a, b)
            addLink(b, a)
        end
    end

    -- Strip every reference to the doomed waypoints before deleting any of them, then delete
    -- highest id first: removal renumbers everything above it.
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        for _, listName in ipairs({ "out", "incoming" }) do
            local cleaned = {}
            for _, id in pairs(wp[listName] or {}) do
                if not inB[id] and id ~= wp.id and not table.contains(cleaned, id) then
                    table.insert(cleaned, id)
                end
            end
            wp[listName] = cleaned
        end
    end

    local doomed = {}
    for _, id in ipairs(bInside) do
        table.insert(doomed, id)
    end
    table.sort(doomed, function(x, y) return x > y end)
    for _, id in ipairs(doomed) do
        ADGraphManager:removeWayPoint(id, false)
    end

    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

-- ---------------------------------------------------------------------------------------------
-- Field loop, generated at the cursor.
--
-- The generator used to insist on being run from inside a vehicle, purely because that was where
-- it got its position from. Pointing at the field is the obvious gesture in a mode that has no
-- vehicle, so the position lookup was split out and this feeds it the cursor instead.
-- ---------------------------------------------------------------------------------------------

function ADFlyoverEditor:generateFieldLoopAtCursor()
    if g_server == nil then
        Logging.error("[FlyoverEditor]: field loops can only be generated on the server (host/singleplayer).")
        return
    end
    if self.cursorX == nil then
        return
    end

    -- COMPANION EDIT: the `or` fallbacks match what the merge reads already do. Without them a nil
    -- margin becomes `-nil` inside the offset, which is a hard Lua error on the first click, on a
    -- path with no pcall around it.
    local marginDistance = ADFlyoverSettings.get("fieldLoopMargin") or 1.25
    local treeClearance = ADFlyoverSettings.get("fieldLoopTreeClearance") or 1.25
    local turningRadius = ADFlyoverSettings.get("fieldLoopTurningRadius") or 8

    -- A field loop can add hundreds of waypoints in one click, which is exactly the kind of thing
    -- that wants to be undoable in one step.
    ADEditorHistory:snapshot("field loop")

    local ok = AutoDrive:generateFieldLoopAt(self.cursorX, self.cursorZ,
        marginDistance, treeClearance, turningRadius, "ADFlyoverEditor field loop")

    if ok then
        self:invalidateIdReferences()
        ADGraphManager:markChanges()
    end
end
