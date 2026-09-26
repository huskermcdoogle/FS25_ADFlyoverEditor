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
    -- Copy was on before or during this drag: the real waypoint(s) are frozen at their pre-drag
    -- spot and never actually move - see beginDrag/toggleMoveCopy/updateDrag/finishDrag.
    dragFrozenCopy = false,
    -- Rotate-during-a-move (settled 2026-09-21, rebound from CapsLock to R after CapsLock did not
    -- reliably hold on the first try): hold R and wheel, live, while dragging.
    -- moveRotateAngle accumulates for the CURRENT drag only (radians, reset at each grab).
    -- moveRotatePivotX/Z are the FIXED pivot the followers rotate around, computed once at grab
    -- time from their pre-drag positions (see beginDrag) - "click" means the dragged point's own
    -- start position, "centroid" means the average of the whole moved set's start positions.
    -- Never the dragged point's LIVE position, or the pivot itself would slide as you rotate.
    moveRotatePivotMode = "click",
    moveRotateAngle = 0,
    moveRotatePivotX = nil,
    moveRotatePivotZ = nil,
    falloffRadius = 0,
    -- Which waypoints a grab picks up, and whether the falloff taper applies to that pick. Falloff
    -- is a toggle sitting ON TOP of the mode (see gatherDragNeighbours): Point uses falloffRadius
    -- as today, Run tapers to the run's own two ends with no radius to set, Multi-point/box/etc.
    -- (self.selection) are always rigid regardless of this flag.
    moveSelectMode = 1,
    moveFalloffOn = true,
    -- Copy toggle and the record it needs to work retroactively (see toggleMoveCopy/finishDrag/
    -- applyMoveAsCopy): lastMoveRecord is the just-completed move's before/after positions, kept
    -- around until the NEXT drag starts so a copy toggled on after release can still replay it.
    moveCopyOn = false,
    moveBreakOn = false,
    moveAutoHookupOn = false,
    lastMoveRecord = nil,
    -- Offset (item 5): Run/Span only, slides the existing chain sideways in place rather than
    -- creating a new parallel track. moveOffsetBase is the chain's position at grab time - ids and
    -- points stay in that same order for the whole adjust session, everything else re-derives from
    -- it (see applyMoveOffset). moveOffsetChainIds ~= nil is what distinguishes "no offset session"
    -- from "grabbed, cursor-drag phase" (dragId also set) from "released, wheel/typed-entry phase"
    -- (dragId nil, chain still live) until a right-click commits it - see stopCurrentAction.
    moveOffsetOn = false,
    moveOffsetChainIds = nil,
    moveOffsetBase = nil,
    moveOffsetMovable = nil,
    moveOffsetDistance = 0,
    -- Item requested 2026-09-21: offset was all-or-nothing (the whole chain slides the same
    -- amount), so a slide meant to blend into an existing junction/track left a hard kink right at
    -- the tie-in. Off by default - the plain rigid slide is still the common case.
    moveOffsetFalloffOn = false,
    moveOffsetFalloffRadius = 8,
    -- Span's own picked ends, separate from offsetFromId/offsetToId (Parallel/Siding's own span) so
    -- the two tools cannot stomp on each other's pick.
    moveSpanFromId = nil,
    moveSpanToId = nil,
    moveSpanIds = nil,
    boxActive = false,
    boxStartX = nil,
    boxStartZ = nil,
    circleActive = false,
    circleStartX = nil,
    circleStartZ = nil,
    freehandActive = false,
    freehandPoints = nil,
    ctrlToggleArmed = false,
    -- Rotated box: Space HELD (spaceHeld, tracked in keyEvent - not a one-shot arm) claims an
    -- ordinary press-drag-release for the edge (corner 1, then direction+length), the same shape
    -- Box/Circle/Freehand already use - Space only has to be held at the moment you PRESS, same
    -- as their own modifiers, not throughout. rotBoxDragging is true for exactly that phase.
    -- Releasing sets the edge and moves to a second, separate phase (rotBoxActive stays true,
    -- rotBoxDragging goes false): a single plain click - no modifier needed any more - sets the
    -- width and commits. See beginRotBoxDrag/finishRotBoxEdge/finishRotBoxSelect.
    spaceHeld = false,
    rotBoxActive = false,
    rotBoxDragging = false,
    rotBoxP1X = nil,
    rotBoxP1Z = nil,
    rotBoxP2X = nil,
    rotBoxP2Z = nil,
    -- Our own held-modifier state - see keyEvent. Defaults false until the first keyEvent call.
    leftCtrlHeld = false,
    rightCtrlHeld = false,
    leftShiftHeld = false,
    rightShiftHeld = false,
    leftAltHeld = false,
    -- Sticky connection options, shown and changed on the panel instead of held as modifier keys.
    connectionMode = 1,
    subPrio = false,
    -- Field loop's own sticky settings: what kind of track it drops. Kept separate from
    -- connectionMode/subPrio above - a loop is not laid stroke by stroke, and "clockwise/
    -- counter-clockwise" (which way to walk the closed ring) answers a different question than
    -- "one-way/two-way/reverse" (which end of a click the direction runs). Defaults match what
    -- createFieldLoopGraph always did before these existed: secondary, two-way.
    fieldLoopSubPrio = true,
    fieldLoopDirection = 3,
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
    convertDirection = 3,   -- CONVERT_OP.TWOWAY / ONEWAY / REVERSE: the Convert tool's direction row
    convertPriority = 2,    -- CONVERT_OP.PRIMARY / SECONDARY: its priority row
    -- parallel and siding share this: they are the same span-select, the same wheel and the same
    -- preview, and differ only in what happens on commit. They are mutually exclusive anyway.
    offsetFromId = nil,
    offsetToId = nil,
    offsetPreview = nil,
    offsetBlockedBy = nil,
    offsetDistance = 5.0,
    offsetScope = 1,
    parallelFlow = 1,   -- 1 = the new track runs the SAME way as a one-way source, 2 = OPPOSITE (a return lane)
    pickFilter = nil,   -- nil = auto (the gesture decides); else "point" | "span" | "run" | "set": locked
    pickKind = nil,     -- what the last pick gesture produced, for the card's indicator
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
    groundFromId = nil,
    groundToId = nil,
    groundPreview = nil,
    groundTolerance = 0.5,
    groundLevel = 1,
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
    mergeToId = nil,
    -- Junction tool (V1): scope radius the wheel drives, the turn radius that shapes the connector
    -- curves, and the last computed preview (scope / approaches / movement matrix / connector curves).
    -- Line weight is a global theme setting.
    junctionRadius = 15,
    junctionTurnRadius = 12,
    -- Road-surface / corridor check, on by default. Off lets a turn shrink for radius alone, never
    -- for leaving the road - see junctionSolveMovement.
    junctionCheckSurface = true,
    -- Trim/extend, on by default. Off, a tie-in never projects past a stem trimmed back short of
    -- where the turn geometry wants it - see junctionWalkBack/junctionTrackConnector.
    junctionExtendTrim = true,
    -- Rebuild existing turns, OFF by default: on, an existing connection whose path leaves the road
    -- skeleton (an old connector) is deleted and laid fresh instead of being kept as "already there".
    junctionRebuild = false,
    -- Connector curve engine: Dubins (default - radius-bounded pose-to-pose via AutoDrive's own
    -- ADDubins) or the tangent biarc (also the automatic fallback when Dubins declines).
    junctionUseDubins = true,
    -- Static-obstacle check (trees, buildings, fences/poles/signs), on by default: a corridor that
    -- overlaps one shrinks its radius to swing clear, and refuses (red, "blocked") if nothing fits.
    junctionCheckObstacles = true,
    -- Card-tunable widths: the on-road corridor (surface check) and the obstacle-clearance box.
    junctionCorridor = 4.0,
    junctionClearance = 5.0,
    junctionPreview = nil,
    -- The locked site {cx, cz, cy}: left-click arms the junction here so the preview stops following
    -- the cursor and right-click places it. Nil = not armed, so right-click puts the tool away.
    junctionArmed = nil
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
ADFlyoverEditor.TOOL = { NONE = 0, DRAW = 1, MOVE = 2, DELETE = 3, NAME = 4, SPLINE = 5, DIVIDE = 6, SMOOTH = 7, CONVERT = 8, STRAIGHTEN = 9, FIELDLOOP = 10, MERGE = 11, PARALLEL = 12, SIDING = 13, GROUND = 14, JUNCTION = 15 }
ADFlyoverEditor.TOOL_NAMES = { "draw", "move", "delete", "name", "spline", "divide", "smooth", "convert", "straighten", "field loop", "merge", "parallel", "siding", "ground", "junction" }

-- The number keys select tools in the PANEL'S READING ORDER (1-9, then 0 for the tenth), NOT by the
-- internal TOOL id above - so the keycaps run 1..0 straight down the Create and Shape groups instead
-- of scattering. There are ten number keys and fourteen tools, so the Connect and Utility tools
-- (convert, merge, name, delete) get no number and are click-only. Keep this list in the same order
-- the panel lays the tools out (see the GROUPS table in FlyoverHud.buildRows).
ADFlyoverEditor.KEY_SLOTS = {
    ADFlyoverEditor.TOOL.DRAW, ADFlyoverEditor.TOOL.SPLINE, ADFlyoverEditor.TOOL.FIELDLOOP,
    ADFlyoverEditor.TOOL.PARALLEL, ADFlyoverEditor.TOOL.SIDING,
    ADFlyoverEditor.TOOL.MOVE, ADFlyoverEditor.TOOL.SMOOTH, ADFlyoverEditor.TOOL.STRAIGHTEN,
    ADFlyoverEditor.TOOL.DIVIDE, ADFlyoverEditor.TOOL.GROUND,
}

--- The keycap ("1".."9", "0", or "" for none) for a tool, from its slot in KEY_SLOTS.
function ADFlyoverEditor:toolKeyLabel(tool)
    for slot, t in ipairs(self.KEY_SLOTS) do
        if t == tool then
            return (slot == 10) and "0" or tostring(slot)
        end
    end
    return ""
end

-- How far a waypoint may sit off the ground before the ground tool calls it out, in meters. The
-- band starts well below a hand's width because the point of the tool is finding drift you cannot
-- see, and reaches high enough to ignore a genuine bridge or gantry rather than dragging it down.
AutoDrive.FLYOVER_GROUND_MIN = 0.1
AutoDrive.FLYOVER_GROUND_MAX = 10.0
AutoDrive.FLYOVER_GROUND_STEP = 0.1
AutoDrive.FLYOVER_GROUND_DEFAULT = 0.5

-- Junction scope radius: the circle the wheel resizes to include/exclude the roads at a crossing.
-- Default sized to the ~15 m spread the savegame survey found for real intersection clusters.
AutoDrive.FLYOVER_JUNCTION_RADIUS_MIN = 6.0
AutoDrive.FLYOVER_JUNCTION_RADIUS_MAX = 40.0
AutoDrive.FLYOVER_JUNCTION_RADIUS_STEP = 1.0

-- Junction turn radius: shapes the connector curves (our own tangent geometry, not AutoDrive's spline
-- curvature). Larger = wider, gentler turns. A future collision-aware version may swap this for Dubins.
AutoDrive.FLYOVER_JUNCTION_TURN_MIN = 2.0
AutoDrive.FLYOVER_JUNCTION_TURN_MAX = 30.0
AutoDrive.FLYOVER_JUNCTION_TURN_STEP = 1.0
-- Width of the corridor a junction connector must keep on the road surface: a typical tractor (~3 m)
-- plus an allowance for a trailer tracking inside the turn. Checked at the centre and both edges.
-- Default only - the live value is per-editor (junctionCorridor) and tuned on the tool card.
AutoDrive.FLYOVER_JUNCTION_CORRIDOR = 4.0
AutoDrive.FLYOVER_JUNCTION_CORRIDOR_MIN = 2.0
AutoDrive.FLYOVER_JUNCTION_CORRIDOR_MAX = 8.0
AutoDrive.FLYOVER_JUNCTION_CORRIDOR_STEP = 0.5
-- Width of the obstacle-clearance box (junctionClearance, on the card): wider than the surface
-- corridor by default so mirrors and implement overhang get breathing room past poles and trees.
AutoDrive.FLYOVER_JUNCTION_CLEARANCE = 5.0
AutoDrive.FLYOVER_JUNCTION_CLEARANCE_MIN = 2.0
AutoDrive.FLYOVER_JUNCTION_CLEARANCE_MAX = 10.0
AutoDrive.FLYOVER_JUNCTION_CLEARANCE_STEP = 0.5

-- Which surface a point is grounded to when its column has more than one - a bridge deck over a road,
-- say. "span line" follows the height the span's own ends imply; "top surface" takes the highest.
ADFlyoverEditor.GROUND_LEVEL = { SPAN = 1, TOP = 2 }
ADFlyoverEditor.GROUND_LEVEL_NAMES = { "span line", "top surface" }

function ADFlyoverEditor:cycleGroundLevel()
    self.groundLevel = (self.groundLevel % #self.GROUND_LEVEL_NAMES) + 1
    self.groundPreview = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: ground level -> %s.", self.GROUND_LEVEL_NAMES[self.groundLevel])
end

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
-- One wheel notch's worth of rotation for R+wheel (move-tool rotate), in radians. 5 degrees.
AutoDrive.FLYOVER_ROTATE_WHEEL_STEP = math.rad(5)
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

--- The game's key-binding help sits in the TOP-LEFT corner, which is where the editor panel is
--- anchored, and it draws after us - so its text came through our background. Hiding it for as long
--- as the editor is open is the honest trade: the panel lists its own keys, and the bindings the
--- help box describes are mostly suspended while editing anyway.
---
--- The previous visibility is remembered rather than assumed, so a player who had already turned
--- the help off does not get it handed back on exit. Everything is pcall'd and nil-checked: this is
--- base-game HUD internals, and failing to hide a help box must never take the editor down with it.
--- Show or hide the game's key-binding help box.
---
--- It sits in the TOP-LEFT corner - where the editor panel is anchored - and draws after us, so its
--- text came through a background that is otherwise opaque.
---
--- The probe settled how to reach it: g_currentMission.hud.inputHelp exists and carries a plain
--- `isVisible` field, but has NO setIsVisible method - that API was my invention, and asking for it
--- failed silently every frame. So the field is written directly. Writing base-game HUD state from
--- a companion mod is blunt, but this box has no setter to ask nicely with.
---
--- Written every frame while the editor is open rather than once on entry, because the HUD sets the
--- flag from its own update and a single write on activation is overwritten straight after.
function ADFlyoverEditor:setInputHelpVisible(visible)
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    local help = hud ~= nil and hud.inputHelp or nil
    if help == nil then
        return false, "no hud.inputHelp"
    end
    -- Prefer a real setter if some other version of the game does provide one; fall back to the
    -- field, which is what this one has.
    if type(help.setIsVisible) == "function" then
        local ok, err = pcall(function() help:setIsVisible(visible) end)
        return ok, ok and nil or tostring(err)
    end
    local ok, err = pcall(function() help.isVisible = visible end)
    return ok, ok and nil or tostring(err)
end

--- One-shot probe of the help box, logged on the first activation only. It is what identified the
--- missing setter, and it is kept so a future game version that moves this can be diagnosed from a
--- log rather than from another round of guesses.
function ADFlyoverEditor:probeInputHelp()
    if self.probedInputHelp then
        return
    end
    self.probedInputHelp = true

    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    if hud == nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: PROBE no g_currentMission.hud")
        return
    end

    local help = hud.inputHelp
    ADFlyoverSettings.debugLog("[FlyoverEditor]: PROBE hud.inputHelp = %s isVisible=%s",
        tostring(help), help ~= nil and tostring(rawget(help, "isVisible")) or "-")

    -- What can actually be called on it. "setIsVisible" was assumed last time and does not exist;
    -- listing the real names means the next attempt starts from fact.
    if type(help) == "table" then
        local names = {}
        for key, value in pairs(help) do
            if type(value) == "function" then
                names[#names + 1] = tostring(key)
            end
        end
        table.sort(names)
        ADFlyoverSettings.debugLog("[FlyoverEditor]: PROBE inputHelp methods: %s",
            #names > 0 and table.concat(names, ", ") or "(none directly on the table)")
    end
end

function ADFlyoverEditor:hideInputHelp()
    self:probeInputHelp()

    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    local help = hud ~= nil and hud.inputHelp or nil
    if help == nil then
        self.inputHelpWasVisible = nil
        ADFlyoverSettings.debugLog("[FlyoverEditor]: no input-help display found to hide.")
        return
    end
    -- Read the flag rather than assume it was on: someone who had already turned the help off must
    -- not have it handed back to them on exit.
    self.inputHelpWasVisible = rawget(help, "isVisible")
    local ok, err = self:setInputHelpVisible(false)
    -- Logged either way. Reporting only success is what left the first attempt unexplained.
    ADFlyoverSettings.debugLog("[FlyoverEditor]: hide key-binding help: ok=%s was=%s%s",
        tostring(ok), tostring(self.inputHelpWasVisible), err ~= nil and (" err=" .. err) or "")
end

function ADFlyoverEditor:restoreInputHelp()
    if self.inputHelpWasVisible == nil then
        return
    end
    self:setInputHelpVisible(self.inputHelpWasVisible ~= false)
    self.inputHelpWasVisible = nil
end

--- The lead from Easy Dev Controls: it hides every display with the base game's own
--- hud:consoleCommandToggleVisibility() (the gsHudVisibility console command), which covers the
--- vehicle panels (control group, Precision Farming) that hiding single components never reached. It is a TOGGLE, not a setter, so
--- only flip it if the hud says it is currently visible, remember that we did, and flip it back on
--- exit - never leave the player's HUD hidden. The state fields are logged so a wrong guess about
--- their names shows up in the log instead of silently doing nothing.
function ADFlyoverEditor:suspendWholeHud()
    self.hudToggledOff = false
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    if hud == nil or type(hud.consoleCommandToggleVisibility) ~= "function" then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: no hud:consoleCommandToggleVisibility to use.")
        return
    end
    local before = hud.isVisible
    if before == false then
        Logging.info("[FlyoverEditor]: whole-hud hide: hud already hidden (isVisible=false), leaving it alone.")
        return
    end
    local ok, err = pcall(hud.consoleCommandToggleVisibility, hud)
    local after = hud.isVisible
    Logging.info("[FlyoverEditor]: whole-hud hide: called consoleCommandToggleVisibility ok=%s err=%s isVisible %s -> %s",
        tostring(ok), tostring(err), tostring(before), tostring(after))
    -- Trust it flipped only if the field agrees, or the field is not exposed at all (nil both ways).
    self.hudToggledOff = ok and (after == false or (before == nil and after == nil))
end

function ADFlyoverEditor:restoreWholeHud()
    if not self.hudToggledOff then
        return
    end
    self.hudToggledOff = false
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    if hud == nil or type(hud.consoleCommandToggleVisibility) ~= "function" then
        return
    end
    -- Only flip back if it is still hidden; if the player already toggled it themselves, leave it.
    if hud.isVisible == false or hud.isVisible == nil then
        local ok, err = pcall(hud.consoleCommandToggleVisibility, hud)
        Logging.info("[FlyoverEditor]: whole-hud restore: ok=%s err=%s isVisible=%s", tostring(ok), tostring(err), tostring(hud.isVisible))
    end
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

--- Total distinct out+incoming neighbours for id, ANYWHERE in the graph - not just inside
--- whatever run/span it was reached from. A genuine junction, not merely a run's own end.
---
--- Nothing that reaches a junction only INCIDENTALLY ever moves it (decided 2026-09-21, after
--- testing) - Point's falloff radius happening to reach one, or resolveWholeRun's deliberate
--- extension of a run's own ends ONTO the junction at each side (reachToJunction, so falloff has a
--- real boundary to taper toward and offset knows where the chain's geometry actually terminates).
--- A junction is a shared reference point for other runs too, and a plain move was never asked to
--- touch it, even a little, even tapered near zero. An EXPLICIT pick stays movable regardless -
--- grabbing one directly in Point mode, or clicking it as one of Span's own two ends - since that
--- decides it the same way an explicit box/circle/freehand/ctrl-click selection already does.
--- Reverse-way links (AutoDrive's reverse road): listed in the START's out but NOT in the end's incoming.
--- Walking the graph by out + incoming therefore cannot see such a link from its END, and a run made
--- reverse-way fell apart into single points for every run/span/junction walk in this file ("reverse-way
--- blows it up"). reverseIn[id] lists the waypoints with a reverse link INTO id; rebuilt at most every half
--- second, and straight away after any edit (dropReverseInCache).
local reverseInCache, reverseInAt = nil, -1e9
local function reverseInIndex()
    local now = g_time or 0
    if reverseInCache ~= nil and now - reverseInAt < 500 then
        return reverseInCache
    end
    local idx = {}
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local a = wayPoints[i]
        if a ~= nil then
            for _, bId in pairs(a.out or {}) do
                local b = ADGraphManager:getWayPointById(bId)
                if b ~= nil and not table.contains(b.incoming or {}, a.id) then
                    idx[bId] = idx[bId] or {}
                    table.insert(idx[bId], a.id)
                end
            end
        end
    end
    reverseInCache, reverseInAt = idx, now
    return idx
end
function ADFlyoverEditor.dropReverseInCache()
    reverseInCache = nil
end

--- The neighbour lists a graph walk should follow: out, incoming, and the reverse-way links into this point.
local LINK_LISTS = { "out", "incoming", "reverseIn" }
local function linkList(wp, listName)
    if listName == "reverseIn" then
        return reverseInIndex()[wp.id]
    end
    return wp[listName]
end

--- Declared this early (well before its first use) so every consumer - the pre-grab preview, Point's
--- own follower gather, Run/Span/Offset's - can all see it regardless of where in the file they sit.
local function isJunction(id)
    local wp = ADGraphManager:getWayPointById(id)
    if wp == nil then
        return false
    end
    local seen, count = {}, 0
    for _, listName in ipairs(LINK_LISTS) do
        for _, other in pairs(linkList(wp, listName) or {}) do
            if not seen[other] then
                seen[other] = true
                count = count + 1
            end
        end
    end
    return count > 2
end

--- Standalone disconnect (moveBreakOn with copy OFF): severs every connection a member of movedSet
--- has to a waypoint OUTSIDE movedSet, in both directions, leaving connections WITHIN movedSet
--- untouched. Direct list surgery rather than ADGraphManager:toggleConnectionBetween - that call
--- flips whatever state is already there, which is the wrong tool for "make this unconditionally
--- true" (see the junctionConnect/junctionDisconnect primitives lower in this file for the same
--- reasoning). Declared here, before finishDrag, since Lua needs a local function defined above
--- its first use.
local function disconnectExternal(movedSet)
    for id in pairs(movedSet) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            local outIds, inIds = {}, {}
            for _, oid in ipairs(wp.out or {}) do table.insert(outIds, oid) end
            for _, iid in ipairs(wp.incoming or {}) do table.insert(inIds, iid) end
            for _, oid in ipairs(outIds) do
                if not movedSet[oid] then
                    table.removeValue(wp.out, oid)
                    local other = ADGraphManager:getWayPointById(oid)
                    if other ~= nil then table.removeValue(other.incoming, id) end
                end
            end
            for _, iid in ipairs(inIds) do
                if not movedSet[iid] then
                    table.removeValue(wp.incoming, iid)
                    local other = ADGraphManager:getWayPointById(iid)
                    if other ~= nil then table.removeValue(other.out, id) end
                end
            end
        end
    end
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
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: input state before reset - %s", self:describeInputState())

    if self.active then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: still active; shutting down first.")
        self:disable()
    end

    for i = 1, 5 do
        local reverted = tryCall("revertContext " .. i, function() g_inputBinding:revertContext(false) end)
        if not reverted then
            break
        end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: reverted a context (%d) - %s", i, self:describeInputState())
    end

    self.contextPushed = false
    ADFlyoverSettings.debugLog("[FlyoverEditor]: input state after reset - %s", self:describeInputState())
    ADFlyoverSettings.debugLog("[FlyoverEditor]: if movement is still dead, the gameplay action events are gone rather than shadowed, and only a reload restores them.")
end

function ADFlyoverEditor:isAvailable()
    return GuiTopDownCamera ~= nil and GuiTopDownCursor ~= nil
end

--- Give the mouse wheel back to the cameras: collapse any expanded AutoDrive pull-down list (the one
--- state that keeps re-asserting mouseWheelActive) and clear the flag. Used on enable and disable.
function ADFlyoverEditor:releaseAutoDriveWheel()
    local hud = AutoDrive.Hud
    local vehicle = AutoDrive.getControlledVehicle and AutoDrive.getControlledVehicle() or nil
    if hud ~= nil and hud.closeAllPullDownLists ~= nil and (AutoDrive.pullDownListExpanded or 0) ~= 0 then
        local ok, err = pcall(hud.closeAllPullDownLists, hud, vehicle)
        if ok then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: collapsed an expanded AutoDrive pull-down list (it was holding the mouse wheel).")
        else
            Logging.warning("[FlyoverEditor]: could not collapse AutoDrive's pull-down list: %s", tostring(err))
            AutoDrive.pullDownListExpanded = 0
        end
    end
    AutoDrive.mouseWheelActive = false
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

    -- Refuse while a game menu has the screen. The in-game menu's AI job / map-overview page (used
    -- to create a vehicle job) is the one that bit: AutoDrive.isMouseActiveForHud() deliberately
    -- treats its own HUD as active while that page is open (AutoDrive.aiFrameOpen), so our launch
    -- button keeps rendering and taking clicks right through it. Opening on top pushed a second
    -- input context and forced the cursor on while the job-creation GUI still owned the screen -
    -- and isGuiBlocking() being true is exactly what then made onCancelAction refuse to back out on
    -- Escape, so the only way out was the debug console. Refusing here, before anything is touched,
    -- is cheap; unwinding a half-entered state under someone else's menu is not.
    if self:isGuiBlocking() then
        Logging.warning("[FlyoverEditor]: refusing to open while a game menu has the screen (e.g. "
            .. "the AI job / map overview screen) - close it first.")
        return false
    end

    if self.active then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: already active.")
        return
    end

    if not self:isAvailable() then
        Logging.error("[FlyoverEditor]: GuiTopDownCamera=%s GuiTopDownCursor=%s - the base game did not expose these, so the flyover editor cannot use this approach.",
            tostring(GuiTopDownCamera), tostring(GuiTopDownCursor))
        return
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: GuiTopDownCamera and GuiTopDownCursor are both present.")
    -- AutoDrive's wheel hook ends in `return AutoDrive.mouseWheelActive` - a flag its HUD sets while
    -- the cursor is over a scrollable element, and RE-ASSERTS on every mouse event for as long as a
    -- pull-down list is expanded. The mouseEvent wrapper mutes AutoDrive's handler while the editor
    -- is open, so whatever that flag was at the moment of entry is frozen for the whole session: opened
    -- with a destination list still dropped down, every wheel event was "handled" and the flyover
    -- camera could not zoom - and the flag came straight back after exit too, taking the vehicle
    -- camera's zoom with it. Collapse the lists and clear the flag here, on the way in.
    self:releaseAutoDriveWheel()
    -- A proxy draw failure from an earlier session latches (see ADFlyoverProxy.failed) so one fault
    -- cannot retry and re-log itself every frame - but that means it also needs a deliberate reset
    -- somewhere, or it would follow the player into every future session too. Here, on the way in,
    -- is the natural place: a fresh open is a fresh chance.
    if ADFlyoverProxy ~= nil and ADFlyoverProxy.resetFailure ~= nil then
        ADFlyoverProxy.resetFailure()
    end
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: camera will start at x=%.1f z=%.1f", startX, startZ)
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: custom input context '%s' pushed=%s", self.INPUT_CONTEXT, tostring(pushed))

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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: camera:registerActionEvents() called - WASD/zoom should now be the camera's.")
    else
        Logging.warning("[FlyoverEditor]: this GuiTopDownCamera has no registerActionEvents(); camera movement will have to be driven manually.")
    end

    local okGet, previous = pcall(function() return g_inputBinding:getShowMouseCursor() end)
    self.previousShowMouseCursor = okGet and previous or false
    ADFlyoverSettings.debugLog("[FlyoverEditor]: mouse cursor was %s on entry; camera:removeActionEvents is %s.",
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: registered %d cancel action event(s).", #self.actionEventIds)

    -- Free the mouse so it picks in the world; the camera keeps its own hold-middle/wheel bindings.
    tryCall("g_inputBinding:setShowMouseCursor(true)", function() g_inputBinding:setShowMouseCursor(true) end)

    self:hideInputHelp()
    self:suspendWholeHud()

    self.active = true
    self.lastWaypointId = nil
    self.placedCount = 0
    self.loggedNoPosition = false
    -- Start clean: a selection or a half-dragged box left over from a previous session would be
    -- pointing at ids that may not mean the same thing any more.
    self:clearSelection()
    -- Always open in Select mode, whatever tool (or armed popup) a previous session left behind.
    self:setTool(self.TOOL.NONE)
    self.cardHidden = false
    self.settingsOpen = false
    self.advancedOpen = false
    self.themeEditRole = 1
    self.dialogOpen = false
    self.helpOpen = false
    self.manualOpen = false
    self.manualIndex = 1
    self.manualScroll = 0
    self.helpScroll = 0
    self.editing = nil
    self.elapsedMs = 0
    self.lastRightPressAt = nil
    self.boxActive = false
    self.boxStartX, self.boxStartZ = nil, nil
    -- Keep the undo history across an accidental Esc and re-open, so you can jump back in and still
    -- undo. Drop it only if the network changed while the editor was closed (a route recorded by
    -- driving, say) - those snapshots would restore a graph that no longer matches. The history is
    -- capped at 25 entries and reset on savegame reload, so it cannot grow without bound.
    local wpCount = ADGraphManager:getWayPointsCount()
    if self.historyGuardCount ~= nil and self.historyGuardCount ~= wpCount then
        ADEditorHistory:clear()
        ADFlyoverSettings.debugLog("[FlyoverEditor]: network changed while closed (%s -> %d waypoints); cleared the undo history.",
            tostring(self.historyGuardCount), wpCount)
    elseif ADEditorHistory:canUndo() or ADEditorHistory:canRedo() then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: kept the undo history from before (%d undo, %d redo).",
            ADEditorHistory:depth(), ADEditorHistory:redoDepth())
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: ACTIVE - %s", self:describeBuild())
end

function ADFlyoverEditor:disable()
    if not self.active then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: not active.")
        return
    end

    -- Remember the network size on the way out, so re-opening can tell whether it changed while the
    -- editor was closed and the kept undo history is still safe to apply.
    self.historyGuardCount = ADGraphManager:getWayPointsCount()

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

    -- Leaving this set makes the mod swallow wheel events after the editor has gone - and clearing the
    -- flag alone is not enough: an expanded pull-down list re-sets it on the next mouse event.
    self:releaseAutoDriveWheel()
    ADFlyoverSettings.debugLog("[FlyoverEditor]: mouse cursor set to %s on exit (showHUD=%s, was %s on entry).",
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
            ADFlyoverSettings.debugLog("[FlyoverEditor]: input context reverted.")
        end
    end

    self:restoreInputHelp()
    self:restoreWholeHud()

    self.camera, self.cursor = nil, nil
    self.active = false
    ADFlyoverSettings.debugLog("[FlyoverEditor]: exited after placing %d waypoint(s).", self.placedCount)
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
            ADFlyoverSettings.debugLog("[FlyoverEditor]: input restored; context count and cursor differ, which is "
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: ended the run at waypoint id=%s; the next click starts a new one.",
        tostring(self.lastWaypointId))
    self.lastWaypointId = nil
end

--- One Esc press reaches us twice - as the MENU_CANCEL/MENU_BACK action event and as a keyEvent - in
--- either order. Whichever sees it first and uses it for something smaller than leaving the editor
--- (cancelling a typed number, closing a dialog) marks it here, so the other does not then treat the
--- same press as "exit the editor".
function ADFlyoverEditor:markEscHandled()
    self.escHandledAt = self:nowMs()
end

function ADFlyoverEditor:escRecentlyHandled()
    return self.escHandledAt ~= nil and (self:nowMs() - self.escHandledAt) < 400
end

--- Throw away whatever the active tool has half-done, WITHOUT applying it (right-click is the one that
--- commits a preview; Esc must never change the network). Returns true if there was something.
function ADFlyoverEditor:cancelPendingAction()
    local t, T = self.tool, self.TOOL
    if t == T.DRAW and self.lastWaypointId ~= nil then
        self:endRun()
    elseif t == T.SIDING and self.sidingAnchorId ~= nil then
        self:cancelSiding()
    elseif t == T.MOVE and self.moveOffsetChainIds ~= nil then
        self:cancelMoveOffset()
    elseif t == T.MOVE and (self.moveSpanFromId ~= nil or self.moveSpanToId ~= nil) then
        self:cancelMoveSpan()
    elseif t == T.PARALLEL and (self.offsetFromId ~= nil or self.offsetToId ~= nil) then
        self:cancelOffset()
    elseif t == T.GROUND and (self.groundFromId ~= nil or self.groundToId ~= nil) then
        self:cancelGround()
    elseif t == T.STRAIGHTEN and (self.straightenFromId ~= nil or self.straightenToId ~= nil) then
        self:cancelStraighten()
    elseif t == T.SMOOTH and (self.smoothFromId ~= nil or self.smoothToId ~= nil) then
        self:cancelSmooth()
    elseif t == T.SPLINE and (self.splineFromId ~= nil or self.splineToId ~= nil) then
        self:cancelSplinePreview()
    elseif t == T.DIVIDE and (self.divideFromId ~= nil or self.divideToId ~= nil) then
        self:cancelDivide()
    elseif t == T.MERGE and (self.mergeFromId ~= nil or self.mergeToId ~= nil) then
        self.mergeFromId, self.mergeToId = nil, nil
        self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
    else
        return false
    end
    return true
end

--- Esc backs out ONE level, innermost first, and only leaves the editor once there is nothing left
--- to back out of: the state it was in when it first opened - Select tool, nothing picked, nothing
--- open. Returns true if it undid something, false when the editor is already there (so the caller
--- exits). Each press is one level, innermost first:
---   typed number -> dialog / manual -> open menu -> help -> pending action -> selection -> tool.
--- Esc only ever cancels; it never applies a preview.
function ADFlyoverEditor:escapeStep()
    if self.editing ~= nil then
        self:cancelEditNumber()
        return true
    end
    if self:isModalOpen() then
        if self.manualOpen then self:closeManual() else self:closeSettingsDialog() end
        return true
    end
    if self.ctxMenu ~= nil then
        if self.ctxMenu.kind == "armed" then
            -- Back to the picker the tool was chosen from (same selection, same spot), not to Select.
            local back = self.menuBackTo
            self:menuCancelArmed()
            if back ~= nil then self.ctxMenu = back end
        else
            self:closeMenu()
        end
        return true
    end
    if self.helpOpen then
        self:toggleHelp()
        return true
    end
    if self:cancelPendingAction() then
        return true
    end
    if self.selectionCount > 0 then
        self:clearSelection()
        return true
    end
    if self.tool ~= self.TOOL.NONE then
        local back = self.menuBackTo
        self:setTool(self.TOOL.NONE)
        if back ~= nil then self.ctxMenu = back end
        return true
    end
    return false
end

function ADFlyoverEditor:onCancelAction(actionName)
    if not self.active or self:isGuiBlocking() then
        return
    end
    if self:escRecentlyHandled() then
        return
    end
    if self:escapeStep() then
        self:markEscHandled()
        return
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: exiting via the %s action event.", actionName)
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
    -- Our own held-modifier state, read directly off the SAME modifier bitmask every keyEvent
    -- callback receives (base game Input.MOD_* flags) - not AutoDrive's own leftCTRLmodifierKeyPressed
    -- etc. globals, which this file used to read. AutoDrive computes those the identical way
    -- (AutoDrive.lua, AutoDrive:keyEvent) - this is base-game plumbing, not anything specific to it.
    --
    -- Captured UNCONDITIONALLY, before every early return below, on every call - not just isDown.
    -- A held key is only correctly tracked if its release (isDown == false) is seen too: gating
    -- this on isDown the way the rest of this function is gated would see Ctrl go down and then
    -- never see it come back up, leaving the flag stuck true. Left/right Alt is deliberately NOT
    -- tracked here - AutoDrive itself never reads Input.MOD_RALT anywhere, so there is no confirmed
    -- evidence that constant exists to test against.
    if Input ~= nil then
        self.leftCtrlHeld = bit32.band(modifier, Input.MOD_LCTRL) > 0
        self.rightCtrlHeld = bit32.band(modifier, Input.MOD_RCTRL) > 0
        self.leftShiftHeld = bit32.band(modifier, Input.MOD_LSHIFT) > 0
        self.rightShiftHeld = bit32.band(modifier, Input.MOD_RSHIFT) > 0
        self.leftAltHeld = bit32.band(modifier, Input.MOD_LALT) > 0
    end

    -- Space, for the rotated box - NOT part of the modifier bitmask above (that is CTRL/ALT/SHIFT
    -- only), so it needs its own down/up tracking off sym directly, same unconditional-before-any-
    -- early-return reasoning: only seeing isDown ever (as the rest of this function is gated)
    -- would see Space go down and never see it come back up.
    if Input ~= nil and Input.KEY_space ~= nil and sym == Input.KEY_space then
        self.spaceHeld = isDown
    end

    -- R, for rotate-during-a-move (settled 2026-09-21, rebound off CapsLock - it did not hold
    -- reliably, most likely the hardware-toggle behaviour flagged as an open risk when CapsLock
    -- was chosen). Same reasoning as Space: not part of the modifier bitmask, needs its own
    -- down/up tracking here rather than reading Input.MOD_*.
    if Input ~= nil and Input.KEY_r ~= nil and sym == Input.KEY_r then
        self.rotateKeyHeld = isDown
    end

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

    -- A modal (settings dialog or browsable manual) is up: Esc closes it, the arrow keys page the
    -- manual, and every other key is swallowed (no tool numbers, no undo). handleEditKey ran first
    -- above, so typing into a dialog field, and Esc to cancel that edit, both still work before this.
    if self:isModalOpen() then
        if isKey("KEY_esc") then
            if self.manualOpen then self:closeManual() else self:closeSettingsDialog() end
            self:markEscHandled()
        elseif self.manualOpen and isKey("KEY_left") then
            self:manualStep(-1)
        elseif self.manualOpen and isKey("KEY_right") then
            self:manualStep(1)
        end
        return
    end

    if isKey("KEY_esc") then
        if self:escRecentlyHandled() then
            return
        end
        if self:escapeStep() then
            self:markEscHandled()
            return
        end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: escape observed via keyEvent (fallback path).")
        self:disable()
        return
    end

    -- Tool selection on the number row, in the panel's reading order (see KEY_SLOTS). keyEvent only
    -- observes and cannot consume, which is fine here: nothing else is bound to these while the
    -- custom context is pushed.
    for slot = 1, #self.KEY_SLOTS do
        -- There is no KEY_10, so the tenth slot sits on 0 the way a number row runs.
        local keyName = (slot == 10) and "KEY_0" or ("KEY_" .. slot)
        if isKey(keyName) then
            self:setTool(self.KEY_SLOTS[slot])
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



    -- Hide/show the floating tool card. A keyboard key rather than middle mouse, which is the camera.
    if isKey("KEY_h") then
        self:toggleCard()
        return
    end

    -- Show/hide the contextual help panel. The / key is also ?, which reads as "help".
    if isKey("KEY_slash") then
        self:toggleHelp()
        return
    end

    -- Falloff radius for the move tool. The wheel is the camera's zoom and stays that way.
    if isKey("KEY_comma") then
        self:setFalloffRadius(self.falloffRadius - AutoDrive.FLYOVER_FALLOFF_STEP)
    elseif isKey("KEY_period") then
        self:setFalloffRadius(self.falloffRadius + AutoDrive.FLYOVER_FALLOFF_STEP)
    end

    -- Copy toggle on B, Move tool only - clicking the HUD row is the only other way to flip it,
    -- which is physically impossible while the mouse button is held down for a drag (the case
    -- toggleMoveCopy's case 1 exists for). A key works mid-drag; a HUD click does not.
    --
    -- NOT C: the flyover camera's own zoom/rotate cluster is bound to Z/X/C/V (reported
    -- 2026-09-21 - "zxcv zoom and rotate camera, copy with c works too, but obviously we need a
    -- new home"), and keyEvent can only OBSERVE a key, never consume it - the same reason Q/E sit
    -- on undo/redo instead of the more obvious Ctrl+Z. B is clear of that cluster and everything
    -- else this file binds (1-9/0, Q, E, H, comma/period, slash, Space).
    if self.tool == self.TOOL.MOVE and isKey("KEY_b") then
        self:toggleMoveCopy()
        return
    end
end

function ADFlyoverEditor:update(dt)
    if not self.active or self.camera == nil or self.cursor == nil then
        return
    end

    -- Asked for every frame, not once at activation. The base game re-shows its help box from its
    -- own update, so a single hide on entry is overwritten immediately - which is the likeliest
    -- reason the first attempt changed nothing on screen.
    self:setInputHelpVisible(false)

    -- The editor's own clock. Advanced before the GUI check below, so time still passes while a
    -- dialog is open and a pause is not silently frozen.
    self.elapsedMs = (self.elapsedMs or 0) + (dt or 0)
    if self:isGuiBlocking() then
        return
    end

    -- While a modal (the browsable manual or the settings dialog) is up, freeze the world: the camera
    -- is not updated, so the mouse drifting to a screen edge to reach a modal button no longer
    -- edge-scrolls the map, and the cursor/hover/preview work below is skipped too. Everything resumes
    -- the frame the modal closes. The camera keeps its position; nothing is torn down.
    if self:isModalOpen() then
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
    --
    -- Not while the mouse is over the panel. The cursor still casts its ray through the screen there,
    -- and the panel sits at the top of the screen where that ray heads for the horizon - so it hit
    -- terrain kilometres away, the network was drawn within 200m of THAT, and everything near the
    -- camera vanished whenever the mouse crossed the upper part of the panel. The last position
    -- pointed at in the world is kept instead: moving onto the panel to click a button should not
    -- move what the world is drawn around.
    -- ...unless a drag is in progress: then the cursor MUST keep tracking the world even over the
    -- card, or dragging a point through the card freezes it mid-move. The panel only pins the draw
    -- centre so moving onto a button does not shift the world; a live drag already owns the cursor.
    local overPanel = self.mouseX ~= nil and ADFlyoverHud ~= nil
        and ADFlyoverHud:isMouseOver(self.mouseX, self.mouseY)
    if not overPanel or self.dragId ~= nil then
        local ok, x, y, z = pcall(function() return self.cursor:getPosition() end)
        if ok and x ~= nil and z ~= nil then
            self.cursorX, self.cursorZ, self.cursorY = x, z, y
        end
    end

    -- Sample the traced path while a freehand drag is live. Only when the cursor has actually
    -- moved a bit since the last sample - appending every frame regardless would pile up a point
    -- for every render tick even while the hand is briefly still, for no benefit to the shape.
    if self.freehandActive and self.freehandPoints ~= nil and self.cursorX ~= nil then
        local last = self.freehandPoints[#self.freehandPoints]
        local dx, dz = self.cursorX - last.x, self.cursorZ - last.z
        if (dx * dx + dz * dz) >= 1 then -- 1m apart, squared
            table.insert(self.freehandPoints, { x = self.cursorX, z = self.cursorZ })
        end
    end

    -- Nothing in the world is under the mouse while it is on the panel, so nothing is highlighted.
    self.hoverId = not overPanel and self:findWayPointNearCursor() or nil
    -- Remember the last waypoint pointed at while the move tool is up, so the falloff preview keeps a
    -- centre after the cursor moves onto the tool card to wheel the radius.
    if self.tool == self.TOOL.MOVE and self.hoverId ~= nil then
        self.moveFocusId = self.hoverId
    end
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
    elseif self.tool == self.TOOL.GROUND then
        self:updateGroundPreview()
    elseif self.tool == self.TOOL.STRAIGHTEN then
        self:updateStraightenPreview()
    elseif self.tool == self.TOOL.SMOOTH then
        self:updateSmoothPreview()
    elseif self.tool == self.TOOL.JUNCTION then
        self:updateJunctionPreview()
    end

    -- Move: a held press that has travelled past the threshold becomes a drag.
    if self.tool == self.TOOL.MOVE and self.movePressId ~= nil and self.dragId == nil and self.leftDown
        and self.mouseX ~= nil and self.movePressMX ~= nil then
        local dx, dy = self.mouseX - self.movePressMX, self.mouseY - self.movePressMY
        if math.sqrt(dx * dx + dy * dy) > self.MOVE_DRAG_THRESHOLD then
            self:startMoveDrag(self.movePressId)
        end
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
        local tr = ADFlyoverLocale ~= nil and ADFlyoverLocale.t or function(s) return s end
        if field ~= nil and field.fieldId ~= nil then
            label = string.format(tr("field %d"), field.fieldId)
        elseif farmland.id ~= nil then
            -- Farmland with no field on it is still worth naming: it tells you the cursor is on
            -- owned land rather than off the map, which is the difference between "the field loop
            -- tool will not work here" and "you are pointing at nothing".
            label = string.format(tr("farmland %d (no field)"), farmland.id)
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

--- Span direction: apply two-way / one-way / flip along the span's own ordered pairs. convertAtCursor
--- only offers point and whole-run scope, so the span case is done here, mirroring its link logic.
--- Kept open so directions can be tried in a row.
function ADFlyoverEditor:menuConvertSpan(op)
    local m = self.ctxMenu
    if m == nil or m.ids == nil or #m.ids < 2 then return end
    ADEditorHistory:snapshot("convert span direction")
    local ordered = m.ids
    local changed = 0
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
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
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

function ADFlyoverEditor:setTool(tool)
    -- Disconnected in this release (0.31.0.1 patch notes) - the auto-junction-placement tool this
    -- 0.31.0.0 line shipped with is still mid-rework on the main line and not part of this hotfix.
    -- Its code is left untouched underneath (see the JUNCTION branches elsewhere in this file and
    -- in FlyoverHud.lua); this is the one chokepoint every selection path goes through - the panel
    -- button is already gone (see FlyoverHud's GROUPS table), this is the belt to that braces.
    if tool == self.TOOL.JUNCTION then
        Logging.warning("[FlyoverEditor]: the junction tool is disabled in this release.")
        return
    end
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
    self.tool = tool
    self.lastMovedIds = nil
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
    self.mergeFromId = nil
    self.mergeToId = nil
    self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = nil, nil, nil
    self.divideFromId, self.divideToId, self.dividePreview = nil, nil, nil
    self.junctionArmed, self.junctionPreview, self.junctionPreviewKey = nil, nil, nil
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
    local order = next(trial) ~= nil and self:orderedChain(trial) or {}
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
            if radius > 0 then
                local c = ADGraphManager:getWayPointById(centreId)
                if c ~= nil then
                    ADDrawingManager:addSphereTask(c.x, c.y + 0.7, c.z, 4.5, 1, 0.8, 0.15, 0.20)
                    -- Same exclusion as the actual grab (gatherDragNeighbours) - a junction the
                    -- radius merely reaches is never a follower, so it should not preview as one.
                    local reached = self:collectAlongTrack(centreId, radius)
                    for otherId, d in pairs(reached) do
                        if otherId ~= centreId and not isJunction(otherId) then
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
    if self.tool == self.TOOL.JUNCTION and self.junctionPreview ~= nil then
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

        -- NEW turns as track-tangent connector curves (white): tie-in ON the entry track, curve, tie-in
        -- ON the exit track. The small white spheres mark the tie-in (merge / exit) points - sitting on
        -- the real road a radius-appropriate distance back from where the tracks meet, NOT the boundary.
        for _, m in ipairs(jp.movements) do
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
            end
        end

        -- Approaches as tall pillars: GREEN = entry lane, AMBER = exit lane, with a direction arm on top.
        for _, ap in ipairs(jp.approaches) do
            local w = ap.wp
            local r, g, b = 1, 0.65, 0.1                      -- exit: amber
            if ap.dir == "in" then r, g, b = 0.1, 1, 0.3 end   -- entry: green
            local gy = (w.y or baseY)
            ADDrawingManager:addLineTask(w.x, gy, w.z, w.x, gy + 4, w.z, lw, r, g, b)
            ADDrawingManager:addSphereTask(w.x, gy + 4, w.z, 2.5, r, g, b, 0.20)
            ADDrawingManager:addLineTask(w.x, gy + 4, w.z,
                w.x + math.sin(ap.bearing) * 4, gy + 4, w.z + math.cos(ap.bearing) * 4, lw, r, g, b)
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

function ADFlyoverEditor:mouseEvent(posX, posY, isDown, isUp, button)
    -- Every event, moves included: update() needs to know whether the mouse is over the panel.
    self.mouseX, self.mouseY = posX, posY

    -- Logged BEFORE the guard, and only for real button presses, so a click that is being thrown
    -- away still leaves a trace. A siding previewed on foot and then did nothing, with no log line
    -- at all - which means the code never reached the commit, and there was no way to tell whether
    -- the click arrived and was rejected or never arrived. This says which.
    if isDown and button ~= nil
        and button ~= Input.MOUSE_BUTTON_WHEEL_UP and button ~= Input.MOUSE_BUTTON_WHEEL_DOWN then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: click button=%s active=%s camera=%s cursor=%s guiBlocking=%s",
            tostring(button), tostring(self.active), tostring(self.camera ~= nil),
            tostring(self.cursor ~= nil), tostring(self:isGuiBlocking()))
    end

    if not self.active or self.camera == nil or self.cursor == nil or self:isGuiBlocking() then
        return
    end

    -- A modal (settings dialog or the browsable manual) owns every click, and nothing reaches the
    -- camera, the panel or the tools. Both populate dialogRows, so dialogClick handles either. The
    -- wheel arrives on its own action path (handleWheel); here we take clicks and swallow the rest.
    if self:isModalOpen() then
        if button == 1 and isDown then
            ADFlyoverHud:dialogClick(posX, posY)
        end
        return
    end

    -- Middle mouse is the camera's own orbit/spin, so it is left entirely to the camera - hiding the
    -- tool card is a keyboard key, a panel button, and an automatic hide while dragging instead
    -- (see toggleCard and buildRows). Trying to share MMB fought the orbit and only half-worked.

    -- The panel gets the event first. A header drag has to claim the WHOLE gesture, including the
    -- camera, or panning the camera and dragging the panel happen at the same time.
    if ADFlyoverHud:handleDrag(self, posX, posY, isDown, isUp, button) then
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

--- Show/hide the floating tool card by hand - the keyboard key (H) and the panel button both call
--- this. The card ALSO hides on its own while you drag a point (see buildRows), so this manual
--- override is for when it covers something you want to see while you are not mid-drag. Middle mouse
--- used to do this, but that button is the camera's orbit.
function ADFlyoverEditor:toggleCard()
    self.cardHidden = not self.cardHidden
    ADFlyoverSettings.debugLog("[FlyoverEditor]: tool card %s.", self.cardHidden and "hidden" or "shown")
end

--- Show/hide the contextual help panel - the "?" button on the header and the / (?) key both call
--- this. It shows the current tool's help and follows the tool as you switch, without blocking use.
function ADFlyoverEditor:toggleHelp()
    self.helpOpen = not self.helpOpen
    -- A freshly opened help panel starts at the top of the page, not wherever the last one was left.
    if self.helpOpen then
        self.helpScroll = 0
    end
end

--- Scroll the contextual help page. Mirrors manualScrollBy: dir is the reversed wheel step, so the
--- direction matches the manual (and everything else). The HUD clamps helpScroll to the page each
--- frame, since only it knows how long the current tool's help is; here we just move it and keep it
--- off the negative side.
function ADFlyoverEditor:helpScrollBy(dir)
    self.helpScroll = math.max(0, (self.helpScroll or 0) - dir * 0.06)
end

--- True while the active tool is mid-action - a span's first end picked, a run open, a drag armed.
--- Used to fire the floating card's jump-out only ONCE per action (its first click), not on every
--- click of that action (a span's second point, say) - and not again until the NEXT action starts.
function ADFlyoverEditor:toolHasPendingStart()
    local t = self.tool
    if t == self.TOOL.STRAIGHTEN then return self.straightenFromId ~= nil
    elseif t == self.TOOL.SMOOTH then return self.smoothFromId ~= nil
    elseif t == self.TOOL.DIVIDE then return self.divideFromId ~= nil
    elseif t == self.TOOL.GROUND then return self.groundFromId ~= nil
    elseif t == self.TOOL.PARALLEL then return self.offsetFromId ~= nil
    elseif t == self.TOOL.SIDING then return self.sidingAnchorId ~= nil
    elseif t == self.TOOL.SPLINE then return self.splineFromId ~= nil
    elseif t == self.TOOL.MERGE then return self.mergeFromId ~= nil
    elseif t == self.TOOL.DRAW then return self.lastWaypointId ~= nil
    elseif t == self.TOOL.JUNCTION then return self.junctionArmed ~= nil
    end
    return false
end

function ADFlyoverEditor:onLeftPress()
    -- The floating tool card no longer jumps to the click: it stays where the player last left it
    -- (persisted), and the HUD moves it aside only while it would cover something being worked on.

    -- Rotated box, phase A: Space held claims this press to start the edge-drag - checked before
    -- everything else, same precedence as the shapes below.
    if self.spaceHeld and not self.rotBoxActive then
        self:beginRotBoxDrag()
        return
    end

    -- Rotated box, phase B: mid-sequence (edge already set, waiting for the third click) claims
    -- every press regardless of Space's state by now (see the design note above) - the press
    -- itself does nothing but stop the underlying tool's own click/drag firing underneath it; the
    -- real handling is on release (finishRotBoxSelect).
    if self.rotBoxActive then
        return
    end

    -- Reassigned 2026-09-21: Ctrl is now the ONE consistent "add to what I already have" layer,
    -- held on top of any of the shapes below (or alone, for a single point) - matching the
    -- CAD/creative-tool convention (Blender/Photoshop: Shift/modifier adds, base gesture picks
    -- the tool) rather than the file-manager one (Ctrl adds, nothing else needed) chosen for
    -- ergonomics (Ctrl+another key is easier to hold than Shift+another key). Alt/Shift/Alt+Shift
    -- now pick the SHAPE instead of Ctrl/Alt/Ctrl+Alt, freeing Ctrl for this.

    -- Alt+Shift together claims the drag for freehand selection - checked before either single
    -- modifier below, or it would never be reached. Box and Circle are the two simple shapes one
    -- modifier each picks; combining them picks the free-form one.
    if self.leftAltHeld and (self.leftShiftHeld or self.rightShiftHeld) then
        self.freehandActive = true
        self.freehandPoints = { { x = self.cursorX, z = self.cursorZ } }
        return
    end

    -- Alt alone claims the drag for box selection (view-aligned - see boxFrame).
    if self.leftAltHeld then
        self.boxActive = true
        self.boxStartX, self.boxStartZ = self.cursorX, self.cursorZ
        return
    end

    -- Shift alone claims the drag for circle selection.
    if self.leftShiftHeld or self.rightShiftHeld then
        self.circleActive = true
        self.circleStartX, self.circleStartZ = self.cursorX, self.cursorZ
        return
    end

    -- Ctrl ALONE (none of the shapes above also held) no longer triggers any drag gesture of its
    -- own - it just toggles whichever single point you release on. Claimed here on press, same as
    -- the shapes above, so the underlying tool's own click/drag never fires underneath it; no
    -- drag-distance threshold needed since there is no shape being drawn to compare against.
    if self.leftCtrlHeld then
        self.ctrlToggleArmed = true
        return
    end

    -- Only the move tool cares about the press itself; every other tool acts on release, so that
    -- a click that turns out to be a camera drag does not commit an edit. Span is the exception:
    -- picking its two ends (and later replacing one) is a plain click, not a drag, so it is left
    -- for onLeftRelease/moveSpanClick - a press only ever begins a drag once the span already
    -- exists AND the hovered point is actually a member of it.
    if self.tool == self.TOOL.MOVE and self.hoverId ~= nil then
        -- An offset already awaiting its right-click commit owns this press: resume cursor-driven
        -- adjustment if the point is part of that SAME chain, otherwise ignore the press entirely
        -- rather than silently starting a different grab and abandoning the pending one without
        -- committing OR explicitly cancelling it.
        if self.moveOffsetChainIds ~= nil then
            local inChain = false
            for _, id in ipairs(self.moveOffsetChainIds) do
                if id == self.hoverId then inChain = true break end
            end
            if inChain then
                -- dragStartX/Z are not actually read by the offset path (offsetDistanceFromCursor
                -- only needs the cursor and moveOffsetBase), but updateDrag's very first line
                -- bails out whenever dragStartX is nil - set for that guard alone, same values
                -- beginDrag itself would set.
                local wp = ADGraphManager:getWayPointById(self.hoverId)
                self.dragId = self.hoverId
                self.dragStartX, self.dragStartZ = wp ~= nil and wp.x or self.cursorX,
                    wp ~= nil and wp.z or self.cursorZ
            else
                ADFlyoverSettings.debugLog("[FlyoverEditor]: an offset is still pending - right-click to finish it first.")
            end
            return
        end

        -- A pre-built selection (Ctrl-click/box/circle/freehand/rotated box) always wins over picks
        -- - see gatherDragNeighbours's own doc comment - but this gate was only ever checking
        -- Span's own two ends, so grabbing a box-selected point that happened not to be a span
        -- member did nothing at all, silently, while Span was active (reported 2026-09-21). Now
        -- also lets a drag start when the hovered point is in the selection, matching every other
        -- picks mode.
        -- The shared gesture language: a press only RECORDS the point. Moving past a small threshold
        -- while held starts the drag (update -> startMoveDrag); letting go without moving is a CLICK,
        -- which picks (point / second click = span / double-click = run - see moveGestureClick).
        self.movePressId = self.hoverId
        self.movePressMX, self.movePressMY = self.mouseX, self.mouseY
    end
end

--- Pixels (normalised screen units) the mouse must travel while held before a press becomes a drag.
ADFlyoverEditor.MOVE_DRAG_THRESHOLD = 0.006

--- A held press has moved far enough: start dragging, and decide WHAT moves from the current pick.
---   the point is in the selection      -> the selection (rigid)
---   the point is in the picked span/run -> that span / run
---   the type filter is locked to run    -> the run through the point
---   otherwise                           -> just that point (falloff applies); any old pick is dropped
function ADFlyoverEditor:startMoveDrag(id)
    self.movePressId = nil
    if id == nil then
        return
    end
    if self.selectionCount > 0 and self.selection[id] then
        self:beginDrag(id)
        return
    end
    if self.moveSpanIds ~= nil and self.moveSpanIds[id] then
        self.moveSelectMode = (self.pickKind == "run") and self.MOVE_SELECT.RUN or self.MOVE_SELECT.SPAN
        self:beginDrag(id)
        return
    end
    if self.pickFilter == "run" then
        self.moveSelectMode = self.MOVE_SELECT.RUN
        self.pickKind = "run"
        self:beginDrag(id)
        return
    end
    self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = nil, nil, nil
    self.moveSelectMode = self.MOVE_SELECT.POINT
    self.pickKind = "point"
    self:beginDrag(id)
end

--- A click (press + release without a drag) with the Move tool: the shared span-pick gesture, whose
--- result becomes what a following drag moves.
function ADFlyoverEditor:moveGestureClick(id)
    if id == nil then
        return
    end
    if self.pickFilter == "point" then
        self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = nil, nil, nil
        self.moveSelectMode = self.MOVE_SELECT.POINT
        self.pickKind = "point"
        return
    end
    local savedHover = self.hoverId
    self.hoverId = id
    self:spanPickClick({
        getFrom = function() return self.moveSpanFromId end,
        getTo = function() return self.moveSpanToId end,
        setEnds = function(a, b)
            self.moveSpanFromId, self.moveSpanToId = a, b
            if b == nil then
                self.moveSpanIds = nil
            end
        end,
        onSpan = function(a, b, span)
            local set = {}
            for _, sid in ipairs(span or {}) do set[sid] = true end
            self.moveSpanIds = set
        end,
    })
    self.hoverId = savedHover
    if self.moveSpanToId == nil then
        self.pickKind = (self.moveSpanFromId ~= nil) and "point" or nil
        self.moveSelectMode = self.MOVE_SELECT.POINT
    else
        self.moveSelectMode = (self.pickKind == "run") and self.MOVE_SELECT.RUN or self.MOVE_SELECT.SPAN
    end
end

--- Does what the Move tool would act on have any connection to the rest of the network? Disconnect is
--- meaningless (and greyed on the card) when it has none. The target is the selection, else the picked
--- span/run, else the point last pointed at (its run when locked to run). nil when there is nothing to judge.
function ADFlyoverEditor:moveTargetHasOutsideLinks()
    local set = {}
    if self.selectionCount > 0 then
        for id in pairs(self.selection) do set[id] = true end
    elseif self.moveSpanIds ~= nil then
        for id in pairs(self.moveSpanIds) do set[id] = true end
    elseif self.moveFocusId ~= nil then
        if self.pickFilter == "run" then
            local _, _, ids = self:resolveWholeRun(self.moveFocusId)
            for _, id in ipairs(ids or { self.moveFocusId }) do set[id] = true end
        else
            set[self.moveFocusId] = true
        end
    else
        return nil
    end
    local n = 0
    for id in pairs(set) do
        n = n + 1
        if n > 600 then return true end   -- big set: assume connected rather than walk it every frame
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
                    if not set[other] then return true end
                end
            end
        end
    end
    return false
end

function ADFlyoverEditor:onLeftRelease()
    -- An armed popup owns interaction: a left click anywhere but on the popup (which the panel has
    -- already consumed) cancels back to Select, rather than letting the armed tool re-pick endpoints
    -- from the world. Apply is a right-click or the popup's own apply row.
    if self.ctxMenu ~= nil and self.ctxMenu.kind == "armed" then
        self:menuCancelArmed()
        ADFlyoverSettings.debugLog("[FlyoverEditor]: armed tool cancelled (clicked away).")
        return
    end

    if self.rotBoxDragging then
        self:finishRotBoxEdge()
        return
    end

    if self.rotBoxActive then
        self:finishRotBoxSelect(self.cursorX, self.cursorZ)
        self:openSetMenu()
        return
    end

    -- Ctrl builds a selection, whatever the tool. Selection is a shared substrate rather than a
    -- tool of its own: the multi-point operations all need it, so building one should not mean
    -- leaving the tool you are working with.
    if self.ctrlToggleArmed then
        self.ctrlToggleArmed = false
        if self:chainToggleSelected(self.hoverId) then
            return
        end
        if self.hoverId ~= nil then
            self:toggleSelected(self.hoverId)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: %s waypoint id=%s (%d selected).",
                self.selection[self.hoverId] and "selected" or "deselected", tostring(self.hoverId), self.selectionCount)
        end
        return
    end

    if self.boxActive then
        self:finishBoxSelect()
        self:openSetMenu()
        return
    end

    if self.circleActive then
        self:finishCircleSelect()
        self:openSetMenu()
        return
    end

    if self.freehandActive then
        self:finishFreehandSelect()
        self:openSetMenu()
        return
    end

    if self.tool == self.TOOL.DRAW then
        self:drawClick()
    elseif self.tool == self.TOOL.MOVE then
        -- Released: a drag finishes; a press that never became a drag is a click, which picks.
        if self.dragId ~= nil then
            self:finishDrag()
        elseif self.movePressId ~= nil then
            self:moveGestureClick(self.movePressId)
        end
        self.movePressId = nil
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
        self:convertToolClick()
    elseif self.tool == self.TOOL.SIDING then
        self:sidingClick()
    elseif self.tool == self.TOOL.PARALLEL then
        self:offsetClick()
    elseif self.tool == self.TOOL.GROUND then
        self:groundClick()
    elseif self.tool == self.TOOL.STRAIGHTEN then
        self:straightenClick()
    elseif self.tool == self.TOOL.DIVIDE then
        self:divideClick()
    elseif self.tool == self.TOOL.JUNCTION then
        self:junctionClick()
    elseif self.tool == self.TOOL.NONE then
        self:selectClick()
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
    -- A right-click finishes an armed tool (apply), or dismisses a selection menu.
    if self.ctxMenu ~= nil then
        if self.ctxMenu.kind == "armed" then
            self:menuApplyArmed()
            ADFlyoverSettings.debugLog("[FlyoverEditor]: armed tool applied (right-click).")
        else
            self:closeMenu()
            ADFlyoverSettings.debugLog("[FlyoverEditor]: context menu closed (right-click).")
        end
        return
    end

    local now = self:nowMs()
    local sincePrevious = (self.lastRightPressAt ~= nil) and (now - self.lastRightPressAt) or nil
    self.lastRightPressAt = now

    if self:stopCurrentAction() then
        return
    end

    if self.selectionCount > 0 then
        self:clearSelection()
        ADFlyoverSettings.debugLog("[FlyoverEditor]: selection cleared.")
        return
    end

    if self.tool == self.TOOL.NONE then
        return
    end

    if sincePrevious == nil or sincePrevious < AutoDrive.FLYOVER_TOOL_EXIT_DELAY then
        -- Too soon to be deliberate. Say so, or it looks like right-click simply stopped working.
        ADFlyoverSettings.debugLog("[FlyoverEditor]: nothing in progress (%.0fms since the last right-click, need %.0fms) - press again to put the %s tool away.",
            sincePrevious or 0, AutoDrive.FLYOVER_TOOL_EXIT_DELAY, self.TOOL_NAMES[self.tool] or "current")
        return
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: put the %s tool away; no tool selected.", self.TOOL_NAMES[self.tool] or "current")
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

    -- Delete with a selection: right-click is the apply.
    if tool == self.TOOL.DELETE and self.selectionCount > 0 then
        self:deleteSelection()
        return true
    end

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
    elseif tool == self.TOOL.MOVE then
        if self.moveOffsetChainIds ~= nil then
            self:commitMoveOffset()
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
    elseif tool == self.TOOL.GROUND then
        if self.groundToId ~= nil then
            self:commitGround()
            return true
        elseif self.groundFromId ~= nil then
            self:cancelGround()
            return true
        elseif self.groundUsesSelection and self.groundPreview ~= nil then
            self:commitGround()
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
        if self:mergeWithOnlyCandidate() then
            return true
        end
        if self.mergeFromId ~= nil or self.mergeToId ~= nil then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the pending merge.")
            self.mergeFromId, self.mergeToId = nil, nil
            self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
            return true
        end
    elseif tool == self.TOOL.MOVE then
        if self.dragId ~= nil then
            self:finishDrag()
            return true
        end
    elseif tool == self.TOOL.JUNCTION then
        -- Armed site: right-click places what the preview shows; if it shows nothing new, the
        -- right-click just unlocks the site. Unarmed falls through, so the next right-click puts the
        -- tool away like any other - the way OUT of the tool without placing anything.
        if self.junctionArmed ~= nil then
            local jp = self.junctionPreview
            -- Placeable = new turns OR rebuilds of existing ones: rebuild movements count into
            -- nRebuild, not nNew, and gating on nNew alone made a pure-rebuild placement report
            -- "nothing to place" and unlock instead of placing.
            if jp ~= nil and ((jp.nNew or 0) + (jp.nRebuild or 0)) > 0 then
                self:applyJunction()
            else
                ADFlyoverSettings.debugLog("[FlyoverEditor]: junction site unlocked (nothing to place).")
            end
            self.junctionArmed = nil
            self.junctionPreview, self.junctionPreviewKey = nil, nil
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
--- The walk includes a junction (as a distance reference - see gatherDragNeighbours, which drops it
--- from the actual follower list) but never continues PAST one: past a junction the points belong
--- to another route, and dragging those is never what moving this one means.
function ADFlyoverEditor:collectAlongTrack(seedId, maxDistance)
    local distance = { [seedId] = 0 }
    local frontier = { seedId }

    while #frontier > 0 do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                local neighbours = {}
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
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

    -- A new drag supersedes any pending retroactive-copy chance from the previous one - moveCopyOn
    -- itself is left alone, since toggling it on BEFORE this drag (then dragging) is exactly how
    -- copy is meant to apply to a fresh move.
    self.lastMoveRecord = nil

    ADEditorHistory:snapshot("move waypoint")

    self.dragId = id
    self.dragStartX, self.dragStartZ = wp.x, wp.z

    -- Precompute which neighbours move and by how much. Same raised-cosine weighting the field
    -- loop generator uses for tree detours: weight 1 at the grabbed point falling smoothly to 0 at
    -- the falloff distance, with zero gradient at both ends, so the run stays smooth instead of
    -- developing a kink where the influence stops.
    self:gatherDragNeighbours()

    -- Copy already on when the grab starts (reported 2026-09-21): the original should never
    -- visibly move at all in that case - you are dragging a fresh copy OUT of it from the first
    -- frame, not moving the real thing and having it snap back later. Same freeze
    -- toggleMoveCopy uses when copy comes on mid-drag instead - see updateDrag/finishDrag.
    self.dragFrozenCopy = self.moveCopyOn
    if self.moveOffsetChainIds ~= nil then
        self.moveOffsetFrozen = self.moveCopyOn and true or false
    end

    -- Rotate pivot, fixed for the whole drag (see the state table comment for why it has to be
    -- the START position, not tracked live).
    self.moveRotateAngle = 0
    if self.moveRotatePivotMode == "centroid" then
        local sumX, sumZ, n = self.dragStartX, self.dragStartZ, 1
        for _, nb in ipairs(self.dragNeighbours or {}) do
            sumX, sumZ, n = sumX + nb.x, sumZ + nb.z, n + 1
        end
        self.moveRotatePivotX, self.moveRotatePivotZ = sumX / n, sumZ / n
    else
        self.moveRotatePivotX, self.moveRotatePivotZ = self.dragStartX, self.dragStartZ
    end

    local mode = (self.selectionCount > 0 and self.selection[id]) and "selection"
        or self.MOVE_SELECT_NAMES[self.moveSelectMode]
    if self.moveOffsetChainIds ~= nil then
        -- An offset carries its chain separately from dragNeighbours; report that, not "0 following".
        ADFlyoverSettings.debugLog("[FlyoverEditor]: grabbed waypoint id=%s to OFFSET a chain of %d waypoint(s) (copy %s, disconnect %s).",
            tostring(id), #self.moveOffsetChainIds, self.moveCopyOn and "on" or "off", self.moveBreakOn and "on" or "off")
    else
        ADFlyoverSettings.debugLog("[FlyoverEditor]: grabbed waypoint id=%s (%s, %d waypoint(s) following).",
            tostring(id), mode, #self.dragNeighbours)
    end
end

--- Work out which waypoints follow the grab, and how strongly.
---
--- Records each follower's CURRENT position, which the drag then offsets from. It therefore has to
--- be called with everything sitting where it started - see refreshActiveDrag, which restores
--- before re-gathering, or the recorded origins would be positions the drag had already moved.
---
--- Three sources, checked in order:
---   1. A pre-built selection (self.selection - ctrl-click, box, later circle/freehand) wins, but
---      only when the grabbed point is actually IN it - grabbing some unrelated point elsewhere
---      moves just that point instead of hijacking the click with a stale leftover selection.
---      Always rigid: there is no single along-track "centre" a scattered set could taper from.
---   2. Run mode carries the whole run the grab belongs to. Falloff (on: taper to the run's own
---      two ends: off: rigid) - never a fixed radius, because the run's own ends already are the
---      natural falloff-to-zero points.
---   3. Point mode (the default): today's along-track falloff from a single grab, unchanged.
function ADFlyoverEditor:gatherDragNeighbours()
    self.dragNeighbours = {}
    if self.dragId == nil then
        return
    end

    if self.selectionCount > 0 and self.selection[self.dragId] then
        for id in pairs(self.selection) do
            if id ~= self.dragId then
                local wp = ADGraphManager:getWayPointById(id)
                if wp ~= nil then
                    table.insert(self.dragNeighbours, { id = id, x = wp.x, z = wp.z, weight = 1 })
                end
            end
        end
        return
    end

    if self.moveSelectMode == self.MOVE_SELECT.RUN then
        local fromId, toId, ids = self:resolveWholeRun(self.dragId)
        if fromId == nil then
            Logging.warning("[FlyoverEditor]: no clear run through id=%s to move as a run - it is "
                .. "a junction, or the run closes on itself.", tostring(self.dragId))
            return
        end
        -- resolveWholeRun's third return is an ORDERED ARRAY (#ids, ipairs - see
        -- claimWholeRunClick/self.spanIds, which rely on exactly that shape for Smooth/Divide/
        -- Ground/Straighten/Offset), not a membership set. gatherChainFollowers/gatherOffsetChain/
        -- orderRunDistances all need id-keyed membership (run[other]) - converted here, at THIS
        -- call site, the same way Span already converts runPathBetween's own array into
        -- moveSpanIds, rather than changing resolveWholeRun's established contract.
        local run = {}
        for _, id in ipairs(ids) do
            run[id] = true
        end

        -- excludeJunctionEnds = true: resolveWholeRun deliberately extends a run's own ends onto
        -- whatever junction sits beyond them (reachToJunction), which is incidental to picking
        -- Run - you clicked a point mid-run, not the junction - unlike Span, where the two ends
        -- are exactly whatever the user directly clicked.
        if self.moveOffsetOn then
            self:gatherOffsetChain(fromId, toId, run, true)
            return
        end
        self:gatherChainFollowers(fromId, toId, run, true)
        return
    end

    if self.moveSelectMode == self.MOVE_SELECT.SPAN then
        if self.moveSpanIds == nil or not self.moveSpanIds[self.dragId] then
            return
        end
        -- excludeJunctionEnds = false: a span's ends are exactly what the user clicked - if that
        -- happens to be a junction, it was explicit, the same as clicking one directly in Point.
        if self.moveOffsetOn then
            self:gatherOffsetChain(self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds, false)
            return
        end
        self:gatherChainFollowers(self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds, false)
        return
    end

    local radius = self.moveFalloffOn and self.falloffRadius or 0
    if radius <= 0 then
        return
    end

    -- A junction the radius happens to reach is a distance REFERENCE (collectAlongTrack keeps it
    -- in the map so the walk stops there correctly), not a follower - incidental reach was never
    -- an explicit pick, same reasoning as Run/Span's excludeJunctionEnds (see isJunction).
    local alongTrack = self:collectAlongTrack(self.dragId, radius)
    for otherId, d in pairs(alongTrack) do
        if otherId ~= self.dragId and not isJunction(otherId) then
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

--- Order a simple run (resolveWholeRun guarantees at most 2 in-run connections per member, so it
--- is a plain chain, not a branching graph) from `fromId` outward, giving each member's distance
--- travelled to get there, AND the walk order itself (offset's gatherOffsetChain needs the order,
--- falloff's gatherChainFollowers only ever needed the distances). Walked fresh rather than
--- trusting `run`'s pairs() order, which is address order and has nothing to do with the run's
--- actual shape - see node-keyed-pairs-is-nondeterministic in project memory.
function ADFlyoverEditor:orderRunDistances(run, fromId)
    local dist = { [fromId] = 0 }
    local orderedIds = { fromId }
    local prevId, currentId = nil, fromId
    while true do
        local wp = ADGraphManager:getWayPointById(currentId)
        if wp == nil then break end
        local nextId = nil
        for _, listName in ipairs(LINK_LISTS) do
            for _, other in pairs(linkList(wp, listName) or {}) do
                if run[other] and other ~= prevId and other ~= currentId then
                    nextId = other
                end
            end
        end
        if nextId == nil then break end
        local nwp = ADGraphManager:getWayPointById(nextId)
        if nwp == nil then break end
        dist[nextId] = dist[currentId] + MathUtil.vector2Length(nwp.x - wp.x, nwp.z - wp.z)
        table.insert(orderedIds, nextId)
        prevId, currentId = currentId, nextId
    end
    return dist, orderedIds
end

--- Run and Span's shared followers: every other member of a simple chain (a whole run, or a picked
--- span) the grab belongs to, from one end (fromId) to the other (toId).
---
--- With falloff off, every member moves exactly as far as the grab - the whole chain as one rigid
--- piece. With falloff on, each member tapers to 0 at whichever of the chain's own two ends it sits
--- towards, using ITS side's own distance to that end as the falloff reach - not a shared radius,
--- since a run's ends are structural and a span's ends are what the user just picked, either way
--- not a separate distance to dial in on top.
--- Offset's own chain setup, in place of gatherChainFollowers - it does not use the weighted
--- follower/dragNeighbours mechanism at all (dragNeighbours is left empty; updateDrag special-cases
--- offset before it ever reaches the normal per-follower loop). Captures the ORDERED chain, ids and
--- points both in walk order, ONCE at grab time - this is moveOffsetBase, and it stays fixed for
--- the whole adjust session (drag AND the wheel/typed-entry phase after release) so repeated
--- offsetOpenChain calls all measure from the same original shape rather than compounding onto
--- whatever the previous adjustment already produced.
---
--- moveOffsetMovable flags which chain positions are actually allowed to move (excludes a genuine
--- junction at either end - see isJunction) - kept the SAME LENGTH/ORDER as moveOffsetBase/
--- moveOffsetChainIds rather than dropped from them, because offsetOpenChain still needs the
--- junction's real position to compute the curve's end geometry correctly; only the WRITE-BACK in
--- applyMoveOffset skips it (Run's own case; Span's explicitly-clicked ends are never junction-
--- extended here in the first place, so this never excludes anything a user directly picked).
function ADFlyoverEditor:gatherOffsetChain(fromId, toId, run, excludeJunctionEnds)
    local _, orderedIds = self:orderRunDistances(run, fromId)
    if orderedIds[#orderedIds] ~= toId then
        Logging.warning("[FlyoverEditor]: could not walk the chain from id=%s to id=%s to offset it.",
            tostring(fromId), tostring(toId))
        return
    end

    local points = {}
    local movable = {}
    for _, id in ipairs(orderedIds) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp == nil then
            return
        end
        table.insert(points, { x = wp.x, y = wp.y, z = wp.z })
        movable[id] = not (excludeJunctionEnds and isJunction(id))
    end

    self.moveOffsetChainIds = orderedIds
    self.moveOffsetBase = points
    self.moveOffsetMovable = movable
    self.moveOffsetDistance = 0
end

--- Signed perpendicular distance from the cursor to the chain's nearest segment - same nearest-
--- segment-then-cross-product shape as offsetSideFromCursor (PARALLEL's own side picker), but
--- returning the actual magnitude too, not just the sign, since offset here is cursor-DRIVEN
--- (dynamic slide) rather than a typed magnitude with only its side read from the cursor.
local function offsetDistanceFromCursor(cx, cz, pts)
    if cx == nil or cz == nil or pts == nil or #pts < 2 then
        return nil
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
    return cross >= 0 and bestDistance or -bestDistance
end

--- Re-slide the chain from its fixed base to the current moveOffsetDistance. The one place both
--- the live cursor-drag and the wheel/typed-entry phase end up writing through - offsetOpenChain
--- takes the base and a signed distance and returns one point per input point, in the same order,
--- which is what keeps this an in-place SLIDE (existing ids, existing connections) rather than
--- PARALLEL's own use of the same function to grow a brand new track.
function ADFlyoverEditor:applyMoveOffset()
    if self.moveOffsetChainIds == nil or self.moveOffsetBase == nil then
        return
    end

    local track, err = ADOffsetGeometry.offsetOpenChain(self.moveOffsetBase, self.moveOffsetDistance)
    if track == nil then
        Logging.warning("[FlyoverEditor]: could not offset - %s", tostring(err))
        return
    end

    -- Optional taper (item requested 2026-09-21): offsetOpenChain itself only knows how to slide
    -- everything the same signed distance - blending is done here instead, by mixing each point
    -- BACK toward its own pre-offset position the closer it sits to either end of the chain, same
    -- cosine shape Point/Run's own falloff already use. nil weights (falloff off) skips the blend
    -- entirely, so the plain rigid slide costs nothing extra.
    local weights = nil
    if self.moveOffsetFalloffOn and self.moveOffsetFalloffRadius > 0 then
        weights = {}
        local base = self.moveOffsetBase
        local n = #base
        local along = { 0 }
        for i = 2, n do
            local a, b = base[i - 1], base[i]
            along[i] = along[i - 1] + MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        end
        local total = along[n]
        for i = 1, n do
            local distToNearEnd = math.min(along[i], total - along[i])
            if distToNearEnd >= self.moveOffsetFalloffRadius then
                weights[i] = 1
            else
                local t = distToNearEnd / self.moveOffsetFalloffRadius
                weights[i] = 0.5 * (1 - math.cos(math.pi * t))
            end
        end
    end

    -- Where each point of the chain goes. With copy on, the ORIGINAL chain stays put (frozen, the same
    -- rule as a plain move: copy on from the start = you slide a new copy out of it; copy turned on part
    -- way = the original drops straight back into place) and these positions are only drawn as a preview,
    -- then become the copy on commit.
    local targets = {}
    for i, id in ipairs(self.moveOffsetChainIds) do
        local p = track[i]
        if p ~= nil and (self.moveOffsetMovable == nil or self.moveOffsetMovable[id]) then
            local tx, tz = p.x, p.z
            if weights ~= nil then
                local base = self.moveOffsetBase[i]
                local w = weights[i]
                tx, tz = base.x + (p.x - base.x) * w, base.z + (p.z - base.z) * w
            end
            targets[i] = { x = tx, z = tz }
            if not self.moveOffsetFrozen then
                self:moveTo(id, tx, tz)
            end
        end
    end
    self.moveOffsetTargets = targets
end

--- Copy turned on or off while an offset is live (during the drag or while it waits for its right-click):
--- on puts the original chain straight back where it started and leaves only the preview moving; off
--- lets the original follow the offset again.
function ADFlyoverEditor:setMoveOffsetFrozen(frozen)
    if self.moveOffsetChainIds == nil then
        return
    end
    self.moveOffsetFrozen = frozen and true or false
    if self.moveOffsetFrozen then
        for i, id in ipairs(self.moveOffsetChainIds) do
            local base = self.moveOffsetBase ~= nil and self.moveOffsetBase[i] or nil
            if base ~= nil and (self.moveOffsetMovable == nil or self.moveOffsetMovable[id]) then
                self:moveTo(id, base.x, base.z)
            end
        end
    end
    self:applyMoveOffset()
end

--- Set the offset distance directly - the wheel/typed-entry path, usable both mid-drag (where it
--- is immediately overwritten by the next frame's cursor-driven update - the user's own call: drag
--- drives it live, wheel only takes over once the button is up) and after release, while the chain
--- is still awaiting its right-click commit.
function ADFlyoverEditor:setMoveOffsetDistance(value)
    if self.moveOffsetChainIds == nil then
        return
    end
    self.moveOffsetDistance = math.max(-AutoDrive.FLYOVER_OFFSET_MAX, math.min(AutoDrive.FLYOVER_OFFSET_MAX, value))
    self:applyMoveOffset()
end

--- Right-click commit for a pending offset (dragId already nil - see onLeftRelease/stopCurrentAction).
--- Re-grounds the chain at its final positions with the accurate raycast, same reasoning finishDrag
--- already gives for every other move: the last live-preview frame is not necessarily where the
--- distance was actually left.
function ADFlyoverEditor:commitMoveOffset()
    local moved = 0
    for _, id in ipairs(self.moveOffsetChainIds or {}) do
        if self.moveOffsetMovable == nil or self.moveOffsetMovable[id] then
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                self:regroundTo(id, wp.x, wp.z, wp.y)
                moved = moved + 1
            end
        end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: offset %.1fm applied to %d waypoint(s).",
        self.moveOffsetDistance, moved)

    -- Copy and disconnect apply to an offset exactly as to a plain move. This used to stop here, so an
    -- offset with copy on just slid the original and never left a copy behind. Same record shape as
    -- finishDrag: each moved point with where it started.
    local members = {}
    local frozen = self.moveOffsetFrozen
    for i, id in ipairs(self.moveOffsetChainIds or {}) do
        local base = self.moveOffsetBase ~= nil and self.moveOffsetBase[i] or nil
        if base ~= nil and (self.moveOffsetMovable == nil or self.moveOffsetMovable[id]) then
            local m = { id = id, originalX = base.x, originalZ = base.z }
            -- Frozen: the original never moved, so where the copy goes comes from the preview.
            local t = frozen and self.moveOffsetTargets ~= nil and self.moveOffsetTargets[i] or nil
            if t ~= nil then
                m.finalX, m.finalZ = t.x, t.z
            end
            members[#members + 1] = m
        end
    end
    self.moveOffsetChainIds, self.moveOffsetBase, self.moveOffsetMovable, self.moveOffsetDistance = nil, nil, nil, 0
    self.moveOffsetFrozen, self.moveOffsetTargets = false, nil

    if #members > 0 then
        if self.moveCopyOn then
            self:applyMoveAsCopy({ members = members })
            self.moveCopyOn = false
            self.moveBreakOn = false
            self.lastMoveRecord = nil
        else
            self.lastMoveRecord = { members = members }
            if self.moveBreakOn then
                local movedSet = {}
                for _, m in ipairs(members) do movedSet[m.id] = true end
                disconnectExternal(movedSet)
                ADFlyoverSettings.debugLog("[FlyoverEditor]: disconnected the %d offset waypoint(s) from their outside connections.",
                    #members)
            end
        end
    end
    ADGraphManager:markChanges()
end

--- Abandon a pending offset without committing - the waypoints stay wherever the last live
--- adjustment left them (this mirrors every other move: the position write already happened
--- frame-by-frame, same as a normal drag, not a separate preview overlay - see gatherOffsetChain).
--- Undo (Q, snapshotted at the original beginDrag) is what actually reverts the positions; this
--- just stops treating the chain as still adjustable.
function ADFlyoverEditor:cancelMoveOffset()
    self.moveOffsetChainIds, self.moveOffsetBase, self.moveOffsetMovable, self.moveOffsetDistance = nil, nil, nil, 0
    self.moveOffsetFrozen, self.moveOffsetTargets = false, nil
end

-- excludeJunctionEnds: true from Run (its ends are incidentally extended onto whatever junction
-- sits beyond them - see isJunction), false from Span (its ends are exactly what the user clicked,
-- explicit either way). dist[fromId]/dist[toId] stay valid taper REFERENCE points either way -
-- only membership in the moved set is filtered, not the distance math a taper measures against.
function ADFlyoverEditor:gatherChainFollowers(fromId, toId, run, excludeJunctionEnds)
    if not self.moveFalloffOn then
        for id in pairs(run) do
            if id ~= self.dragId and not (excludeJunctionEnds and isJunction(id)) then
                local wp = ADGraphManager:getWayPointById(id)
                if wp ~= nil then
                    table.insert(self.dragNeighbours, { id = id, x = wp.x, z = wp.z, weight = 1 })
                end
            end
        end
        return
    end

    local dist = self:orderRunDistances(run, fromId)
    local grabDist, total = dist[self.dragId], dist[toId]

    if grabDist == nil or total == nil then
        return
    end

    for id in pairs(run) do
        if id ~= self.dragId and not (excludeJunctionEnds and isJunction(id)) then
            local wp = ADGraphManager:getWayPointById(id)
            local d = dist[id]
            if wp ~= nil and d ~= nil then
                local side = d - grabDist
                local reach = side >= 0 and (total - grabDist) or grabDist
                local weight = 1
                if reach > 1e-6 then
                    local t = math.min(math.abs(side) / reach, 1)
                    weight = 0.5 * (1 + math.cos(math.pi * t))
                elseif side ~= 0 then
                    weight = 0
                end
                table.insert(self.dragNeighbours, { id = id, x = wp.x, z = wp.z, weight = weight })
            end
        end
    end
end

--- Re-run the follower gather live, mid-drag, when the mode or falloff toggle changes underneath
--- an active grab. Cannot simply re-gather in place: the followers have already been displaced by
--- the drag so far, so their current positions are not the origins the new set should measure
--- from - everything is put back first (the grabbed point too, since a run/along-track distance is
--- measured through its position), then the new set is gathered and the drag re-applied.
function ADFlyoverEditor:refreshActiveDrag()
    if self.dragId == nil then
        return
    end

    for _, n in ipairs(self.dragNeighbours or {}) do
        self:moveTo(n.id, n.x, n.z)
    end
    if self.dragStartX ~= nil then
        self:moveTo(self.dragId, self.dragStartX, self.dragStartZ)
    end

    self:gatherDragNeighbours()
    self:updateDrag()
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: falloff %.1fm along the track.", value)
        return
    end

    self.falloffRadius = value
    self:refreshActiveDrag()

    ADFlyoverSettings.debugLog("[FlyoverEditor]: falloff %.1fm along the track, %d waypoint(s) following.",
        value, #self.dragNeighbours)
end

function ADFlyoverEditor:updateDrag()
    if self.cursorX == nil or self.dragStartX == nil then
        return
    end

    -- Offset: the cursor drives the signed distance directly (dynamic slide), not a delta applied
    -- to a per-follower weight - see gatherOffsetChain/applyMoveOffset. Only while still actively
    -- held; once released the wheel/typed-entry phase takes over (setMoveOffsetDistance), and this
    -- function stops being called at all until the next grab.
    if self.moveOffsetChainIds ~= nil then
        local d = offsetDistanceFromCursor(self.cursorX, self.cursorZ, self.moveOffsetBase)
        if d ~= nil then
            self.moveOffsetDistance = math.max(-AutoDrive.FLYOVER_OFFSET_MAX,
                math.min(AutoDrive.FLYOVER_OFFSET_MAX, d))
            self:applyMoveOffset()
        end
        return
    end

    -- Frozen copy (copy was on before or during this drag - see beginDrag/toggleMoveCopy): the
    -- real waypoint(s) stay exactly where they started, full stop. finishDrag still computes
    -- where the clone belongs from dragStartX/Z and the cursor directly, so nothing here needs to
    -- track that separately - it just has nothing left to do each frame.
    if self.dragFrozenCopy then
        return
    end

    local deltaX = self.cursorX - self.dragStartX
    local deltaZ = self.cursorZ - self.dragStartZ

    -- The grabbed point goes where the cursor is pointing, height included - that is what puts it
    -- on a ramp rather than on the ground below it. Followers keep to whatever surface they are
    -- already on.
    self:moveTo(self.dragId, self.cursorX, self.cursorZ, nil, self.cursorY)

    -- Rotate (R+wheel - see applyWheelToActiveTool) composes with the translate above: each
    -- follower's ORIGINAL offset from the fixed pivot is rotated by the accumulated angle first,
    -- THEN the drag's delta is added on top - so the whole rotated shape rides along with the
    -- drag exactly the way the plain (unrotated) shape already does. moveRotateAngle stays 0
    -- unless R+wheel was actually used this drag, so cos=1/sin=0 makes this an identity transform
    -- (no different from the old plain add) whenever rotation is not in play.
    local cosA, sinA = math.cos(self.moveRotateAngle), math.sin(self.moveRotateAngle)
    local pivotX, pivotZ = self.moveRotatePivotX or self.dragStartX, self.moveRotatePivotZ or self.dragStartZ
    for _, n in ipairs(self.dragNeighbours or {}) do
        local ox, oz = n.x - pivotX, n.z - pivotZ
        local rx = pivotX + ox * cosA - oz * sinA
        local rz = pivotZ + ox * sinA + oz * cosA
        self:moveTo(n.id, rx + deltaX * n.weight, rz + deltaZ * n.weight)
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

--- Re-ground a moved point using the ground tool's surface resolver rather than the cursor's raw
--- pick. The top-down cursor sees foliage - it lands a point in a tree canopy metres off the ground -
--- while groundTargetAt uses the DEFAULT+ROAD+TERRAIN mask, so it takes the nearest REAL surface to
--- the reference height: the ground under an overhang, or a ramp/bridge the point genuinely sits on.
--- spanLineOnly = true keeps it off the ground tool's "top surface" toggle; snap-to-terrain still
--- wins inside groundTargetAt.
function ADFlyoverEditor:regroundTo(id, x, z, ref)
    local wp = ADGraphManager:getWayPointById(id)
    if wp == nil then
        return
    end
    local r = ref or wp.y
    local y = self:groundTargetAt(x, r, z, r, true) or wp.y
    ADGraphManager:moveWayPoint(id, x, y, z, wp.flags, false)
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
    -- Remember what was just carried, so the tool card can step clear of where it LANDED. The drag
    -- state is cleared below, and until now nothing recorded the dropped points at all.
    local moved = { self.dragId }
    for _, n in ipairs(self.dragNeighbours or {}) do
        if #moved < 400 then moved[#moved + 1] = n.id end
    end
    self.lastMovedIds = moved
    self.moveDropCount = (self.moveDropCount or 0) + 1

    -- Offset: releasing the mouse does NOT commit here - see gatherOffsetChain/commitMoveOffset.
    -- Only the "actively held, cursor is driving the distance" bookkeeping ends; the chain itself
    -- stays live for the wheel/typed-entry phase until a right-click commits it
    -- (stopCurrentAction).
    if self.moveOffsetChainIds ~= nil then
        self.dragId, self.dragStartX, self.dragStartZ, self.dragNeighbours, self.dragFrozenCopy = nil, nil, nil, nil, false
        return
    end

    -- Built BEFORE anything below moves further, from the pre-drag positions already tracked
    -- (dragStartX/Z for the grab, each follower's own recorded origin) - independent of whether
    -- copy is actually used this time, so a PLAIN move can still be turned into a copy afterward
    -- (see toggleMoveCopy).
    --
    -- finalX/finalZ, only when frozen (dragFrozenCopy): the real waypoint never moved this drag
    -- (updateDrag skipped it - see there), so its own x/z cannot say where the drag would have
    -- ended. Computed here with the exact same formula updateDrag would have applied every frame,
    -- so it matches what a non-frozen drag's actual final position already is. Left nil otherwise
    -- - the non-frozen path already has the true, re-grounded final position on the real waypoint
    -- by the time applyMoveAsCopy reads it below, which is more accurate than recomputing it.
    local members
    if self.dragFrozenCopy then
        local deltaX, deltaZ = self.cursorX - self.dragStartX, self.cursorZ - self.dragStartZ
        members = { { id = self.dragId, originalX = self.dragStartX, originalZ = self.dragStartZ,
            finalX = self.cursorX, finalZ = self.cursorZ } }
        for _, n in ipairs(self.dragNeighbours or {}) do
            table.insert(members, { id = n.id, originalX = n.x, originalZ = n.z,
                finalX = n.x + deltaX * n.weight, finalZ = n.z + deltaZ * n.weight })
        end
    else
        members = { { id = self.dragId, originalX = self.dragStartX, originalZ = self.dragStartZ } }
        for _, n in ipairs(self.dragNeighbours or {}) do
            table.insert(members, { id = n.id, originalX = n.x, originalZ = n.z })
        end
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

        self:regroundTo(self.dragId, dropped.x, dropped.z, dropped.y)

        ADFlyoverSettings.debugLog("[FlyoverEditor]: heights at the drop point - cursor reports %s, plain terrain %s, ray from cursor %s, ray from 30m up %s, was %.2f, set to %.2f.",
            self.cursorY ~= nil and string.format("%.2f", self.cursorY) or "nil",
            terrainY ~= nil and string.format("%.2f", terrainY) or "nil",
            fromCursor ~= nil and string.format("%.2f", fromCursor) or "nil",
            fromAbove ~= nil and string.format("%.2f", fromAbove) or "nil",
            beforeY, dropped.y)
    end
    for _, n in ipairs(self.dragNeighbours or {}) do
        local wp = ADGraphManager:getWayPointById(n.id)
        if wp ~= nil then
            self:regroundTo(n.id, wp.x, wp.z, wp.y)
        end
    end

    local moved = 1 + #(self.dragNeighbours or {})
    ADFlyoverSettings.debugLog("[FlyoverEditor]: moved %d waypoint(s) ending at id=%s, re-grounded at the drop point.",
        moved, tostring(self.dragId))
    self.dragId, self.dragStartX, self.dragStartZ, self.dragNeighbours, self.dragFrozenCopy = nil, nil, nil, nil, false

    -- Copy already toggled on before release: convert this move into a copy right now, and there
    -- is nothing left to retroactively convert later. Otherwise stash the record - a plain move,
    -- but one toggleMoveCopy can still turn into a copy afterward.
    if self.moveCopyOn then
        self:applyMoveAsCopy({ members = members })
        self.moveCopyOn = false
        self.moveBreakOn = false
        self.lastMoveRecord = nil
    else
        self.lastMoveRecord = { members = members }

        -- Standalone disconnect (copy off, break on): sever this moved set's OUTSIDE connections
        -- right here rather than via applyMoveAsCopy's clone-then-delete-original route, which only
        -- runs when copy is also on. No clone, no id churn - just moved and cut loose.
        if self.moveBreakOn then
            local movedSet = {}
            for _, m in ipairs(members) do
                movedSet[m.id] = true
            end
            disconnectExternal(movedSet)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: disconnected %d waypoint(s) from their outside connections.",
                #members)
        end

        -- Only the plain-move path - applyMoveAsCopy runs its own auto-hookup on the CLONE's ids,
        -- not these originals (a copy's whole point is starting disconnected; hookup still applies
        -- to it, just against its own new ids, not the source's).
        local ids = {}
        for _, m in ipairs(members) do
            table.insert(ids, m.id)
        end
        self:autoHookupEndpoints(ids)
    end

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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: run starts at existing waypoint id=%s; click on to draw from it.",
            tostring(self.lastWaypointId))
        return
    end

    if self.lastWaypointId == self.hoverId then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cannot connect a waypoint to itself.")
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

    ADFlyoverSettings.debugLog("[FlyoverEditor]: toggled the connection %s -> %s (dual=%s reverse=%s).",
        tostring(self.lastWaypointId), tostring(self.hoverId), tostring(dualConnection), tostring(reverseDirection))

    -- Carry the run on from the waypoint just clicked, so a route can be drawn straight through an
    -- existing junction without stopping to re-anchor it.
    self.lastWaypointId = self.hoverId
end

-- ---------------------------------------------------------------------------------------------
-- Delete.
-- ---------------------------------------------------------------------------------------------

--- Which tools offer the picked-span / whole-run choice: everything that works on a span between
--- two points. Delete and convert have their own point-vs-run scope, which means something else.
function ADFlyoverEditor:toolTakesSpanScope()
    return false   -- retired: every span tool now shows the shared pick row instead of "covers"
end

--- Tools that pick a span with the shared gesture (spanPickClick) and show the selection-type row.
--- The two ends of the span the active span tool has picked (either may be nil), for highlighting it.
function ADFlyoverEditor:pickedSpanEnds()
    local t, T = self.tool, self.TOOL
    if t == T.SMOOTH then return self.smoothFromId, self.smoothToId
    elseif t == T.DIVIDE then return self.divideFromId, self.divideToId
    elseif t == T.GROUND then return self.groundFromId, self.groundToId
    elseif t == T.STRAIGHTEN then return self.straightenFromId, self.straightenToId
    elseif t == T.PARALLEL then return self.offsetFromId, self.offsetToId
    elseif t == T.MERGE then return self.mergeFromId, self.mergeToId
    end
    return nil, nil
end

--- Is there a pick for the card's indicator to describe right now? A pending span, or (Ground) a selection.
function ADFlyoverEditor:pickIsActive()
    if self.tool == self.TOOL.MOVE then
        return self.moveSpanFromId ~= nil or self.dragId ~= nil
    end
    return self:toolHasPendingStart() or (self.tool == self.TOOL.GROUND and self.groundUsesSelection == true)
end

function ADFlyoverEditor:toolUsesSpanPick()
    return self.tool == self.TOOL.SMOOTH
        or self.tool == self.TOOL.MERGE
        or self.tool == self.TOOL.PARALLEL
        or self.tool == self.TOOL.DIVIDE
        or self.tool == self.TOOL.STRAIGHTEN
        or self.tool == self.TOOL.GROUND
end

--- One click instead of two, when the scope says whole run. Returns true when it handled the click.
---
--- In whole-run scope EVERY click resolves a run - including one made while a run is already
--- selected. It used to fall through to the two-click path instead, which treated the click as
--- re-picking the far end and quietly cut a 28-waypoint run down to 16. Whole run means the run
--- you clicked; to pick an arbitrary sub-span, switch to the picked span.
--- A refusal the player can SEE: the log line plus an on-screen warning (a log-only refusal reads as the
--- click doing nothing).
function ADFlyoverEditor:warnPlayer(message)
    if ADFlyoverLocale ~= nil and ADFlyoverLocale.t ~= nil then
        message = ADFlyoverLocale.t(message)
    end
    Logging.warning("[FlyoverEditor]: %s", message)
    if g_currentMission ~= nil and g_currentMission.showBlinkingWarning ~= nil then
        pcall(g_currentMission.showBlinkingWarning, g_currentMission, message, 4000)
    end
end

local function listHas(list, id)
    for _, v in pairs(list or {}) do
        if v == id then return true end
    end
    return false
end

--- The shortest path from startId to endId that follows the direction of the links (out only), or nil.
local function directedPath(startId, endId, maxNodes)
    local cameFrom = { [startId] = false }
    local frontier, visited, found = { startId }, 1, startId == endId
    while #frontier > 0 and not found and visited < maxNodes do
        local nextFrontier = {}
        for _, id in ipairs(frontier) do
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                for _, other in pairs(wp.out or {}) do
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

--- The route between two picked points, following the RUN'S direction: along the links from a to b, or from
--- b to a (returned in a..b order), and only if neither exists falls back to the plain path search that
--- ignores direction. Where a track has more than one route between two points (a siding, a loop, a
--- shortcut), the plain search takes the shortest and can pick one that runs against the traffic; this
--- takes the one the traffic actually uses.
function ADFlyoverEditor:spanPath(a, b)
    local maxNodes = AutoDrive.FLYOVER_MERGE_MAX_RUN
    local path = directedPath(a, b, maxNodes)
    if path ~= nil then
        return path
    end
    path = directedPath(b, a, maxNodes)
    if path ~= nil then
        local reversed = {}
        for i = #path, 1, -1 do reversed[#reversed + 1] = path[i] end
        return reversed
    end
    return self:runPathBetween(a, b)
end

--- Put a span's ids in the direction TRAFFIC runs along it. runPathBetween walks the graph ignoring link
--- direction, so a span clicked from downstream to upstream came out running AGAINST the traffic - and a
--- run's own end order was arbitrary - which made anything direction-sensitive (Parallel's "same way",
--- the side, the order of a one-way) come out backwards. One-way segments vote (a -> b only, or b -> a
--- only); two-way segments do not vote, so a two-way span keeps the order it was picked in. Returns the
--- ids (a reversed copy when they had to be turned round) and whether they were reversed.
function ADFlyoverEditor:trafficOrder(ids)
    if ids == nil or #ids < 2 then
        return ids, false
    end
    local forward, backward = 0, 0
    for i = 1, #ids - 1 do
        local a = ADGraphManager:getWayPointById(ids[i])
        local b = ADGraphManager:getWayPointById(ids[i + 1])
        if a ~= nil and b ~= nil then
            local aToB, bToA = listHas(a.out, b.id), listHas(b.out, a.id)
            if aToB and not bToA then
                forward = forward + 1
            elseif bToA and not aToB then
                backward = backward + 1
            end
        end
    end
    if backward > forward then
        local reversed = {}
        for i = #ids, 1, -1 do reversed[#reversed + 1] = ids[i] end
        return reversed, true
    end
    return ids, false
end

--- THE span-pick gesture, shared by every span tool (Smooth, Divide, Ground, Straighten; the others follow).
---
---   click a point            starts a span
---   click a second point     completes it (the path between them)
---   click again              replaces whichever end is nearer to the click
---   double-click a point     takes the whole run through it, junction to junction
---
--- self.pickFilter locks one of these types deliberately ("span": no double-click runs; "run": a single
--- click takes the run); nil is auto, where the gesture decides. self.pickKind records what the last
--- pick produced, which the tool card shows as its indicator.
---
--- `cfg` is how a tool plugs in: getFrom()/getTo() read its own end fields; setEnds(from, to, ids)
--- writes them and drops its previews; onSpan(from, to, span) (optional) runs when a full span exists.
function ADFlyoverEditor:spanPickClick(cfg)
    local id = self.hoverId
    if id == nil then
        return
    end
    local now = self:nowMs()
    local isDouble = self.lastPickId == id and (now - (self.lastPickAt or -1e9)) < self.DOUBLE_CLICK_MS
    self.lastPickId, self.lastPickAt = id, now

    local filter = self.pickFilter
    if filter ~= "span" and filter ~= "run" then
        filter = nil   -- "point" / "set" mean nothing to a span tool
    end

    if filter == "run" or (filter == nil and isDouble) then
        local fromId, toId, ids = self:resolveWholeRun(id)
        if fromId ~= nil then
            local ordered, turned = self:trafficOrder(ids)
            if turned then
                ids = ordered
                fromId, toId = ids[1], ids[#ids]
            end
            self.spanIds = ids
            cfg.setEnds(fromId, toId, ids)
            self.pickKind = "run"
            if cfg.onSpan ~= nil then cfg.onSpan(fromId, toId, ids) end
            ADFlyoverSettings.debugLog("[FlyoverEditor]: %s takes the whole run: %d waypoint(s), id=%s to id=%s.",
                self.TOOL_NAMES[self.tool] or "tool", #ids, tostring(fromId), tostring(toId))
            return
        end
        self:warnPlayer(string.format("No clear run through here - it is a junction, or a loop that leaves and returns to one "
            .. "junction. Click the two ends of the part you want instead."))
        if filter == "run" or isDouble then
            return
        end
    end

    local from, to = cfg.getFrom(), cfg.getTo()

    if from == nil then
        self.spanIds = nil
        cfg.setEnds(id, nil, nil)
        self.pickKind = "span"
        ADFlyoverSettings.debugLog("[FlyoverEditor]: %s span from id=%s; click the far end (or double-click for the whole run).",
            self.TOOL_NAMES[self.tool] or "tool", tostring(id))
        return
    end

    if to == nil then
        if id == from then
            return
        end
        local span = self:spanPath(from, id)
        if span == nil and cfg.anyPoints then
            span = { from, id }   -- a tool that does not need a path takes any two points
        end
        if span == nil then
            self:warnPlayer(string.format("Those two points are not connected, so they are not two ends of one span."))
            return
        end
        local a, b = from, id
        local ordered, turned = self:trafficOrder(span)
        if turned then
            a, b, span = id, from, ordered   -- the traffic runs the other way: the span starts at the second click
        end
        self.spanIds = span   -- the route that was picked, so the preview and the commit follow exactly it
        cfg.setEnds(a, b, nil)
        self.pickKind = "span"
        if cfg.onSpan ~= nil then cfg.onSpan(a, b, span) end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: %s span of %d waypoint(s), id=%s to id=%s%s.",
            self.TOOL_NAMES[self.tool] or "tool", #span, tostring(a), tostring(b),
            turned and " (turned round to follow the traffic)" or "")
        return
    end

    -- Both ends exist: replace whichever end is nearer this click (Move's refinement, now everywhere).
    local wp = ADGraphManager:getWayPointById(id)
    local fromWp = ADGraphManager:getWayPointById(from)
    local toWp = ADGraphManager:getWayPointById(to)
    if wp == nil or fromWp == nil or toWp == nil then
        return
    end
    local dFrom = MathUtil.vector2Length(wp.x - fromWp.x, wp.z - fromWp.z)
    local dTo = MathUtil.vector2Length(wp.x - toWp.x, wp.z - toWp.z)
    local replacingFrom = dFrom <= dTo
    local newFrom = replacingFrom and id or from
    local newTo = replacingFrom and to or id
    if newFrom == newTo then
        return
    end
    local span = self:spanPath(newFrom, newTo)
    if span == nil and cfg.anyPoints then
        span = { newFrom, newTo }
    end
    if span == nil then
        self:warnPlayer("That point is not connected to the other end, so the span was not changed.")
        return
    end
    local ordered, turned = self:trafficOrder(span)
    if turned then
        newFrom, newTo, span = newTo, newFrom, ordered
    end
    self.spanIds = span
    cfg.setEnds(newFrom, newTo, nil)
    self.pickKind = "span"
    if cfg.onSpan ~= nil then cfg.onSpan(newFrom, newTo, span) end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: %s span end replaced: %d waypoint(s), id=%s to id=%s%s.",
        self.TOOL_NAMES[self.tool] or "tool", #span, tostring(newFrom), tostring(newTo),
        turned and " (turned round to follow the traffic)" or "")
end

--- Lock the selection type (or, with nil, go back to auto). Clicking the lit type on a tool card
--- again unlocks it.
function ADFlyoverEditor:setPickFilter(filter)
    self.pickFilter = filter
    ADFlyoverSettings.debugLog("[FlyoverEditor]: selection type %s.", filter ~= nil and ("locked to " .. filter) or "auto")
end

function ADFlyoverEditor:claimWholeRunClick(setEnds)
    if self.offsetScope ~= self.OFFSET_SCOPE.RUN or self.hoverId == nil then
        return false
    end
    local fromId, toId, ids = self:resolveWholeRun(self.hoverId)
    if fromId == nil then
        Logging.warning("[FlyoverEditor]: no clear run through id=%s - it is a junction, or the run "
            .. "closes on itself. Switch to the picked span and click both ends.", tostring(self.hoverId))
        return true
    end
    self.spanIds = ids
    setEnds(fromId, toId)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: %s covers the whole run: %d waypoint(s), id=%s to id=%s.",
        self.TOOL_NAMES[self.tool] or "tool", #ids, tostring(fromId), tostring(toId))
    return true
end

ADFlyoverEditor.OFFSET_SCOPE = { SPAN = 1, RUN = 2 }
ADFlyoverEditor.OFFSET_SCOPE_NAMES = { "picked span", "whole run" }

--- Is this ordered run two-way? Sides of a two-way track have no "left of travel" (there is no single
--- direction), so the selector names them by what the player did instead. Two-way when at least half
--- the segments also run the other way, so one stray one-way piece does not flip the wording.
function ADFlyoverEditor:runIsTwoWay(pts)
    if pts == nil or #pts < 2 then return false end
    local total, reverse = 0, 0
    for i = 1, #pts - 1 do
        local a = ADGraphManager:getWayPointById(pts[i].id)
        local b = ADGraphManager:getWayPointById(pts[i + 1].id)
        if a ~= nil and b ~= nil then
            total = total + 1
            for _, otherId in pairs(b.out or {}) do
                if otherId == pts[i].id then reverse = reverse + 1 break end
            end
        end
    end
    return total > 0 and reverse * 2 >= total
end

--- Take the side from where the cursor points, and remember which side that was and whether the track
--- is two-way, so the side selector can say "picked side / other side" on a two-way track.
function ADFlyoverEditor:pickSideFromCursor(seedPts)
    local side, a, b = self:offsetSideFromCursor(seedPts)
    self.offsetSide = side
    self.offsetSidePicked = side
    self.sideTwoWay = self:runIsTwoWay(seedPts)
    -- The stretch of track the side was judged against: on a two-way track the sides are named by where
    -- they lie on SCREEN, worked out from this each frame (see screenSideLabels).
    if a ~= nil and b ~= nil then
        self.sideRefA = { x = a.x, y = a.y or 0, z = a.z }
        self.sideRefB = { x = b.x, y = b.y or 0, z = b.z }
    else
        self.sideRefA, self.sideRefB = nil, nil
    end
end

--- Where the two sides of a two-way track lie on screen: returns the words for the + side and the -
--- side (right/left when the track runs mostly up and down the screen, up/down when it runs mostly
--- across it), or nil when that cannot be worked out. Recomputed as the camera moves, so the words
--- always describe what is on screen.
function ADFlyoverEditor:screenSideLabels()
    local a, b = self.sideRefA, self.sideRefB
    if a == nil or b == nil or project == nil then return nil end
    local dx, dz = b.x - a.x, b.z - a.z
    local len = math.sqrt(dx * dx + dz * dz)
    if len < 1e-6 then return nil end
    local nx, nz = -dz / len, dx / len   -- the + side's normal, as the offset maths uses it
    local mx, my, mz = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5
    local ok0, x0, y0, d0 = pcall(project, mx, my, mz)
    local ok1, x1, y1, d1 = pcall(project, mx + nx * 5, my, mz + nz * 5)
    if not (ok0 and ok1 and x0 and x1 and d0 and d1 and d0 > 0 and d1 > 0) then return nil end
    -- Normalised screen x is squeezed by the aspect ratio; scale it back so the two axes compare fairly.
    local vx, vy = (x1 - x0) * (g_screenAspectRatio or (16 / 9)), y1 - y0
    if math.abs(vx) >= math.abs(vy) then
        if vx > 0 then return "right", "left" end
        return "left", "right"
    end
    if vy > 0 then return "up", "down" end
    return "down", "up"
end

--- The name of the current side, the same words the selector shows: left / right of travel on a one-way
--- track, picked side / other side on a two-way one.
function ADFlyoverEditor:sideName()
    local side = self.offsetSide or 1
    -- Two-way: where the side lies on screen (see the side selector on the card); one-way: left / right of
    -- the run, below.
    if self.sideTwoWay then
        local plus, minus = self:screenSideLabels()
        if plus ~= nil then
            return side >= 0 and plus or minus
        end
        return side == (self.offsetSidePicked or 1) and "picked side" or "other side"
    end
    return side >= 0 and "right" or "left"
end

function ADFlyoverEditor:flipOffsetSide()
    -- offsetSide +1 is the side the (-uz, ux) normal points to, which in this map's x/z (z grows toward
    -- the bottom of a north-up view) is the RIGHT-hand side of the direction of travel; -1 is the left.
    self.offsetSide = -(self.offsetSide or 1)
    self.offsetCache = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: offset side -> %s.", self:sideName())
end

function ADFlyoverEditor:cycleOffsetScope()
    self.offsetScope = (self.offsetScope % #self.OFFSET_SCOPE_NAMES) + 1
    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
    self.spanIds = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: offset covers the %s.", self.OFFSET_SCOPE_NAMES[self.offsetScope])
end

ADFlyoverEditor.DELETE_SCOPE = { POINT = 1, RUN = 2 }
ADFlyoverEditor.DELETE_SCOPE_NAMES = { "one waypoint", "whole run" }

-- Move's own pick, separate from DELETE_SCOPE even though Point/Run overlap it: move additionally
-- has Span (and, later, Box/Circle/Freehand), none of which delete has any use for.
ADFlyoverEditor.MOVE_SELECT = { POINT = 1, RUN = 2, SPAN = 3 }
ADFlyoverEditor.MOVE_SELECT_NAMES = { "point", "run", "span" }

--- Span mode's click handling. Point/Run grab and move in one press-drag-release gesture; Span is
--- built up first with plain clicks, and only once both ends exist does pressing on a MEMBER of it
--- become an actual grab (onLeftPress/beginDrag - see there).
---
--- Same gesture ("click the new one") whichever end is being set: with fewer than two ends picked,
--- a click fills in the next one; once both exist, a click that lands on neither end nor a member
--- replaces whichever existing end it is geometrically closer to. This is deliberately NOT a
--- separate "reselect" mode - there is only ever one thing a click does here, so nothing needs
--- cancelling to redo an end, and there is no ambiguity to guess between "replace" and "start over"
--- (see junction-crossing-detection-self-destructs in project memory for why a proximity GUESS
--- between two different actions is the wrong shape here).
function ADFlyoverEditor:moveSpanClick()
    if self.hoverId == nil then
        return
    end

    if self.moveSpanFromId == nil then
        self.moveSpanFromId = self.hoverId
        self.moveSpanToId, self.moveSpanIds = nil, nil
        ADFlyoverSettings.debugLog("[FlyoverEditor]: move span from id=%s; click the far end.", tostring(self.hoverId))
        return
    end

    if self.moveSpanToId == nil then
        if self.hoverId == self.moveSpanFromId then
            return
        end
        local span = self:runPathBetween(self.moveSpanFromId, self.hoverId)
        if span == nil then
            Logging.warning("[FlyoverEditor]: id=%s is not connected to id=%s, so they are not two ends of one span.",
                tostring(self.hoverId), tostring(self.moveSpanFromId))
            return
        end
        self.moveSpanToId = self.hoverId
        self.moveSpanIds = {}
        for _, id in ipairs(span) do self.moveSpanIds[id] = true end
        ADFlyoverSettings.debugLog("[FlyoverEditor]: move span of %d waypoint(s) picked. Grab and drag any point "
            .. "on it to move; click elsewhere on the network to replace whichever end is closer.", #span)
        return
    end

    -- Both ends exist - replace whichever end sits closer to this click. Used to refuse a click
    -- that landed on a member outright, back when onLeftPress guaranteed one could never reach
    -- here at all; onLeftRelease now deliberately routes a too-small-to-be-a-drag click on a
    -- member here too (2026-09-21 fix - shrinking a span never worked before this, only
    -- extending it), so a member landing here is expected, not a case to refuse. Re-picking the
    -- SAME end you clicked (or clicking the far end exactly) both resolve to a harmless no-op via
    -- the distance comparison below, so nothing special has to be done for those either.
    local wp = ADGraphManager:getWayPointById(self.hoverId)
    local fromWp = ADGraphManager:getWayPointById(self.moveSpanFromId)
    local toWp = ADGraphManager:getWayPointById(self.moveSpanToId)
    if wp == nil or fromWp == nil or toWp == nil then
        return
    end
    local dFrom = MathUtil.vector2Length(wp.x - fromWp.x, wp.z - fromWp.z)
    local dTo = MathUtil.vector2Length(wp.x - toWp.x, wp.z - toWp.z)
    local replacingFrom = dFrom <= dTo
    local newFromId = replacingFrom and self.hoverId or self.moveSpanFromId
    local newToId = replacingFrom and self.moveSpanToId or self.hoverId

    local span = self:runPathBetween(newFromId, newToId)
    if span == nil then
        Logging.warning("[FlyoverEditor]: id=%s is not connected to the other end, so the span was not changed.",
            tostring(self.hoverId))
        return
    end

    self.moveSpanFromId, self.moveSpanToId = newFromId, newToId
    self.moveSpanIds = {}
    for _, id in ipairs(span) do self.moveSpanIds[id] = true end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move span of %d waypoint(s) picked.", #span)
end

function ADFlyoverEditor:cancelMoveSpan()
    if self.moveSpanFromId ~= nil or self.moveSpanToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: move span cancelled.")
    end
    self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds = nil, nil, nil
    -- Nothing picked any more: a following drag is a single point again, and the indicator goes dark.
    self.moveSelectMode = self.MOVE_SELECT.POINT
    self.pickKind = nil
end

function ADFlyoverEditor:cycleMoveSelectMode()
    self.moveSelectMode = (self.moveSelectMode % #self.MOVE_SELECT_NAMES) + 1
    self:cancelMoveSpan()
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move picks %s.", self.MOVE_SELECT_NAMES[self.moveSelectMode])
    self:refreshActiveDrag()
end

function ADFlyoverEditor:toggleMoveFalloff()
    -- Guards (the card greys these): a tapered drag stays joined to the track it came from, so it cannot
    -- also be disconnected; and a selection always moves rigidly, so falloff means nothing with one.
    if not self.moveFalloffOn and (self.moveBreakOn or self.selectionCount > 0) then
        return
    end
    self.moveFalloffOn = not self.moveFalloffOn
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move falloff %s.", self.moveFalloffOn and "on" or "off")
    self:refreshActiveDrag()
end

--- Convert a completed move into a copy: every ORIGINAL point restores to where it started, and a
--- NEW waypoint is created at each one's final (already re-grounded) position instead. Internal
--- connections among the moved set are replicated onto the clones - walking only wp.out, so each
--- directed edge is reconstructed exactly once; a dual connection reconstructs itself naturally as
--- two separate directed edges when both directions were present, no special case needed. Nothing
--- connects a clone to anything OUTSIDE the moved set - it never had a link there, and a copy
--- being disconnected by default is the whole point of it (see move-tool-copy-and-break-spec in
--- project memory).
---
--- `record.members` is a plain list of { id, originalX, originalZ } - see finishDrag, which builds
--- it for every move (not just copies), and toggleMoveCopy, which is what lets a plain move already
--- released get turned into a copy afterward.
function ADFlyoverEditor:applyMoveAsCopy(record)
    if record == nil or record.members == nil then
        return
    end

    local movedSet = {}
    for _, m in ipairs(record.members) do
        movedSet[m.id] = true
    end

    local newIds = {}
    for _, m in ipairs(record.members) do
        local wp = ADGraphManager:getWayPointById(m.id)
        if wp ~= nil then
            -- Final position first - restoring the original below moves THIS waypoint, not the
            -- clone, so its current x/y/z has to be captured before that happens. Skipped
            -- entirely when breaking: the original is about to be deleted anyway, so there is no
            -- point writing it back to its start position first.
            --
            -- m.finalX/finalZ, when present, override reading wp's own live position - the frozen-
            -- copy path (dragFrozenCopy: copy was on before or during the drag, so the REAL
            -- waypoint never moved at all and is sitting at its original spot right now, not the
            -- drop point) records where the drag would have ended separately, since wp.x/z cannot
            -- tell us that anymore. The retroactive path (copy toggled on AFTER release) has no
            -- such override - wp really is sitting at its final dropped position, which is exactly
            -- what should be read live.
            local fx, fy, fz, flags = wp.x, wp.y, wp.z, wp.flags
            if m.finalX ~= nil then
                fx, fz = m.finalX, m.finalZ
                fy = AutoDrive:getTerrainHeightAtWorldPos(fx, fz, wp.y)
            end
            if not self.moveBreakOn then
                self:moveTo(m.id, m.originalX, m.originalZ)
            end

            local newWp = ADGraphManager:recordWayPoint(fx, fy, fz, false, false, false, nil, flags, false)
            if newWp ~= nil then
                newIds[m.id] = newWp.id
            end
        end
    end

    local edgeCount = 0
    for _, m in ipairs(record.members) do
        local wp = ADGraphManager:getWayPointById(m.id)
        local newFromId = newIds[m.id]
        if wp ~= nil and newFromId ~= nil then
            for _, otherId in pairs(wp.out or {}) do
                if movedSet[otherId] and newIds[otherId] ~= nil then
                    local newFrom = ADGraphManager:getWayPointById(newFromId)
                    local newTo = ADGraphManager:getWayPointById(newIds[otherId])
                    if newFrom ~= nil and newTo ~= nil then
                        ADGraphManager:toggleConnectionBetween(newFrom, newTo, false, false, false)
                        edgeCount = edgeCount + 1
                    end
                end
            end
        end
    end

    -- Break (item 4): delete every original NOW, after the clones exist and their internal edges
    -- are wired, but before anything reads the originals again. This is what turns a copy into a
    -- relocate - the clone is already disconnected by default (a fresh waypoint never inherited
    -- the source's links), so deleting the source leaves it moved and cleanly detached rather than
    -- leaving a stretched connection or a lost waypoint (see move-tool-copy-and-break-spec).
    if self.moveBreakOn then
        local toDelete = {}
        for _, m in ipairs(record.members) do
            table.insert(toDelete, m.id)
        end
        -- Same reasoning deleteSelection already relies on: descending order, so each pending id
        -- is still valid when its turn comes.
        table.sort(toDelete, function(a, b) return a > b end)
        for _, id in ipairs(toDelete) do
            ADGraphManager:removeWayPoint(id, false)
        end

        -- Every original has a LOWER id than every clone (clones are always appended strictly
        -- after this operation starts, never inserted below anything), so deleting #toDelete of
        -- them shifts every clone's id down by exactly that count - uniformly, regardless of
        -- which original happened to cause which shift.
        local shift = #toDelete
        for oldId, newId in pairs(newIds) do
            newIds[oldId] = newId - shift
        end
        self:invalidateIdReferences()
    end

    -- The clone becomes the new selection - the natural thing to act on next, the same way a
    -- freshly picked span or box leaves its own result selected. After invalidateIdReferences
    -- above (break only), which already cleared it - this still has to run either way, copy or
    -- break, so it is unconditional rather than duplicated into both branches.
    self:clearSelection()
    local finalIds = {}
    for _, newId in pairs(newIds) do
        self.selection[newId] = true
        self.selectionCount = self.selectionCount + 1
        table.insert(finalIds, newId)
    end

    -- The clone's own ends (item 6) - not the source's, which either still exists (plain copy) or
    -- is already gone (break). Using newIds' FINAL values here matters: they were already shifted
    -- above when breaking, so this checks the ids the clone actually has now.
    self:autoHookupEndpoints(finalIds)

    ADFlyoverSettings.debugLog("[FlyoverEditor]: %s %d waypoint(s), %d internal connection(s), now selected.",
        self.moveBreakOn and "broke off" or "copied", #record.members, edgeCount)
    ADGraphManager:markChanges()
end

--- Copy is a toggle sitting on top of whichever move just happened or is about to, not a mode of
--- its own - see move-tool-copy-and-break-spec in project memory for the two ways it applies:
---
---   1. Toggled on BEFORE or DURING a drag: finishDrag sees moveCopyOn and applies the copy
---      itself once the drag actually completes.
---   2. Toggled on AFTER a drag has already finished (self.dragId == nil): there is no pending
---      drag to wait for, so this converts the just-finished move right now, using the record
---      finishDrag already stashed in lastMoveRecord for exactly this case.
---
--- Auto-clears back to off once actually applied (case 2, and the mirror of it inside finishDrag)
--- rather than staying on for the next drag too - a defensible default given a copy creates new
--- waypoints, not just repositions existing ones, so leaving it silently armed risks a drag some
--- time later cloning when a plain move was intended.
function ADFlyoverEditor:toggleMoveCopy()
    self.moveCopyOn = not self.moveCopyOn

    -- An offset is live (dragging, or waiting for its right-click): copy freezes / unfreezes the original.
    if self.moveOffsetChainIds ~= nil then
        self:setMoveOffsetFrozen(self.moveCopyOn)
        ADFlyoverSettings.debugLog("[FlyoverEditor]: move copy %s (offset: original %s).", self.moveCopyOn and "on" or "off",
            self.moveCopyOn and "back in place, sliding a copy" or "follows the offset again")
        return
    end

    if self.moveCopyOn and self.dragId == nil and self.lastMoveRecord ~= nil then
        self:applyMoveAsCopy(self.lastMoveRecord)
        self.lastMoveRecord = nil
        self.moveCopyOn = false
        self.moveBreakOn = false
        return
    end

    -- Turned on WHILE a drag is already live: freeze the real waypoint(s) back at their pre-drag
    -- spot right now, same as beginDrag does when copy is already on at grab time - the original
    -- should never look like it "moved and then undid," it should just stop following the cursor
    -- from this frame on. finishDrag tracks where the drag would have ended separately (via the
    -- members' finalX/finalZ) so the eventual clone still lands wherever you actually release,
    -- even though the real point stopped moving here.
    if self.moveCopyOn and self.dragId ~= nil then
        for _, n in ipairs(self.dragNeighbours or {}) do
            self:moveTo(n.id, n.x, n.z)
        end
        if self.dragStartX ~= nil then
            self:moveTo(self.dragId, self.dragStartX, self.dragStartZ)
        end
        self.dragFrozenCopy = true
    elseif not self.moveCopyOn then
        self.dragFrozenCopy = false
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: move copy %s.", self.moveCopyOn and "on" or "off")
end

--- Disconnect (item 4, HUD label "disconnect") is independent of copy - decided 2026-09-21 after
--- copy being a prerequisite read as confusing (it isn't a copy modifier, it just happens to
--- BECOME one when copy is also on):
---
---   copy off, disconnect on:  standalone - finishDrag moves the set as normal, then severs its
---                              OUTSIDE connections in place (disconnectExternal). No clone.
---   copy on,  disconnect on:  same net result as before - applyMoveAsCopy clones, then deletes
---                              the originals instead of restoring them, leaving a disconnected
---                              clone at the drop spot.
---
--- So this toggle always applies; it no longer resets when copy turns off, and the HUD always
--- shows its row under Move (see move-tool-copy-and-break-spec in project memory for the older,
--- copy-gated history of this toggle).
function ADFlyoverEditor:toggleMoveBreak()
    -- Not with a taper, plain or offset (the card shows it greyed): tapered points stay joined to the track.
    if not self.moveBreakOn and ((self.moveOffsetOn and self.moveOffsetFalloffOn)
        or (not self.moveOffsetOn and self.moveFalloffOn)) then
        return
    end
    self.moveBreakOn = not self.moveBreakOn
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move disconnect %s.", self.moveBreakOn and "on" or "off")
end

function ADFlyoverEditor:toggleMoveAutoHookup()
    self.moveAutoHookupOn = not self.moveAutoHookupOn
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move auto-hookup %s.", self.moveAutoHookupOn and "on" or "off")
end

--- Item 6, widened 2026-09-21 (was total connections <= 1 only - resolveWholeRun's own "an end has
--- at most one inside connection" idea for a run's two ends). A genuine THROUGH point (one
--- incoming, one outgoing, to two DIFFERENT neighbours) is still excluded - that is a normal
--- interior point with both its connections, snapping it elsewhere would replace a link, not add
--- one. But a FORK where every remaining connection points the same logical way is now eligible
--- too, on request: "two two-way, or both one-ways leaving or entering should be eligible" - a
--- node that lost its one outside tie and kept two internal branches all flowing the same
--- direction (all out, all in, or all dual) still has an unambiguous single role to reconnect.
---
--- Returns (eligible, neighbourIdSet, role) - role is "isolated" (0 connections), "source" (only
--- outgoing - needs a new incoming link), "destination" (only incoming - needs a new outgoing
--- link), or "dual" (every neighbour is a two-way pair - the new link should be dual too).
local function isEndpoint(id)
    local wp = ADGraphManager:getWayPointById(id)
    if wp == nil then
        return false
    end
    local seen = {}
    for _, listName in ipairs(LINK_LISTS) do
        for _, other in pairs(linkList(wp, listName) or {}) do
            seen[other] = true
        end
    end

    local outCount, inCount = #(wp.out or {}), #(wp.incoming or {})
    if outCount == 0 and inCount == 0 then
        return true, seen, "isolated"
    end
    if outCount == 0 then
        return true, seen, "destination"
    end
    if inCount == 0 then
        return true, seen, "source"
    end

    -- Both lists non-empty: eligible only if EVERY neighbour appears in BOTH lists (all pairs
    -- genuinely dual) - otherwise this is a normal through-point (different neighbours in and
    -- out), not a fork, and stays excluded exactly as before.
    for other in pairs(seen) do
        if not (table.contains(wp.out or {}, other) and table.contains(wp.incoming or {}, other)) then
            return false
        end
    end
    return true, seen, "dual"
end

--- Auto-hookup for a moved or copied set of ids (item 6) - checked at the tail of finishDrag (a
--- plain move) and applyMoveAsCopy (copy/break), after positions are settled. Endpoints only (see
--- isEndpoint) - an interior point already has both its connections, and snapping it elsewhere
--- would mean REPLACING a link, not adding one; left for later if this ever extends past
--- endpoints, per move-tool-auto-hookup-spec.
---
--- One candidate per endpoint - the single NEAREST other waypoint within tolerance, excluding the
--- moved/copied set itself (reconnecting to something already there is the point; two ends of the
--- same set drifting near each other is not what this is for). Divergence is only checked when the
--- endpoint already has one neighbour to measure a heading from - a bare point (zero connections,
--- e.g. a lone copied point) has no heading to diverge from, so distance alone decides it.
function ADFlyoverEditor:autoHookupEndpoints(ids)
    if not self.moveAutoHookupOn or ids == nil then
        return 0
    end

    local movedSet = {}
    for _, id in ipairs(ids) do
        movedSet[id] = true
    end

    local maxDistance = ADFlyoverSettings.get("flyoverAutoHookupDistance") or 3.0
    local maxDivergence = ADFlyoverSettings.get("flyoverAutoHookupDivergence") or 15
    local wayPoints = ADGraphManager:getWayPoints()
    local hooked = 0

    for _, id in ipairs(ids) do
        local endpoint, neighbours, role = isEndpoint(id)
        if endpoint then
            local wp = ADGraphManager:getWayPointById(id)
            if wp ~= nil then
                -- Heading: the AVERAGE direction away from every surviving neighbour, not just
                -- one - a fork (role "source"/"destination"/"dual" with more than one neighbour,
                -- widened 2026-09-21) has several, and none of them alone says which way the
                -- candidate should roughly continue. "isolated" (a bare copied point) has none at
                -- all, so heading/divergence is skipped entirely for it, same as before.
                --
                -- Direction and dual-ness both come straight from role now instead of inspecting
                -- one neighbour's own lists: "source" (only outgoing survives) means wp used to be
                -- fed from outside, so the replacement should too (target->wp); "destination"
                -- (only incoming survives) means wp used to feed onward, so the replacement
                -- continues that (wp->target); "dual" (every neighbour two-way) makes the new link
                -- dual too. Got wpIsSource backwards on an earlier single-neighbour pass (reported
                -- 2026-09-21 as "one connection was the wrong direction") - role removes the need
                -- to infer it from an "inverse of the survivor" rule at all.
                local headingX, headingZ = nil, nil
                local hSumX, hSumZ, hCount = 0, 0, 0
                for otherId in pairs(neighbours) do
                    local ow = ADGraphManager:getWayPointById(otherId)
                    if ow ~= nil then
                        local hx, hz = wp.x - ow.x, wp.z - ow.z
                        local len = MathUtil.vector2Length(hx, hz)
                        if len > 1e-6 then
                            hSumX, hSumZ, hCount = hSumX + hx / len, hSumZ + hz / len, hCount + 1
                        end
                    end
                end
                if hCount > 0 then
                    local len = MathUtil.vector2Length(hSumX, hSumZ)
                    if len > 1e-6 then
                        headingX, headingZ = hSumX / len, hSumZ / len
                    end
                end
                local dual = (role == "dual")
                local wpIsSource = (role == "destination")

                local bestId, bestDist = nil, maxDistance
                for i = 1, #wayPoints do
                    local other = wayPoints[i]
                    if not movedSet[other.id] and not neighbours[other.id] then
                        local dx, dz = other.x - wp.x, other.z - wp.z
                        local dist = MathUtil.vector2Length(dx, dz)
                        if dist <= bestDist and dist > 1e-6 then
                            local ok = true
                            if headingX ~= nil then
                                local ux, uz = dx / dist, dz / dist
                                local cosAngle = math.max(-1, math.min(1, ux * headingX + uz * headingZ))
                                local angleDeg = math.deg(math.acos(cosAngle))
                                ok = angleDeg <= maxDivergence
                            end
                            if ok then
                                bestId, bestDist = other.id, dist
                            end
                        end
                    end
                end

                if bestId ~= nil then
                    local target = ADGraphManager:getWayPointById(bestId)
                    if target ~= nil then
                        -- Argument order carries the direction directly (rather than trusting the
                        -- exact sign convention of a reverseDirection flag): wp was a source, so
                        -- wp->target continues it; wp was a destination, so target->wp does.
                        if wpIsSource then
                            ADGraphManager:toggleConnectionBetween(wp, target, false, dual, false)
                        else
                            ADGraphManager:toggleConnectionBetween(target, wp, false, dual, false)
                        end
                        hooked = hooked + 1
                    end
                end
            end
        end
    end

    if hooked > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: auto-hookup connected %d endpoint(s).", hooked)
    end
    return hooked
end

--- Run/Span only - see gatherDragNeighbours/gatherOffsetChain. Blocked while an offset is already
--- pending (moveOffsetChainIds ~= nil): flipping the toggle off then would leave the panel saying
--- "off" while a chain is still live and awaiting its right-click commit, which is exactly the
--- kind of stale-looking-inactive-but-still-armed state the rest of this feature works to avoid.
function ADFlyoverEditor:toggleMoveOffset()
    if self.moveOffsetChainIds ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: an offset is still pending - right-click to finish it first.")
        return
    end
    self.moveOffsetOn = not self.moveOffsetOn
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move offset %s.", self.moveOffsetOn and "on" or "off")
end

--- Item requested 2026-09-21: taper the offset slide toward either end of the chain instead of
--- sliding it all rigidly - see applyMoveOffset for the actual blend. Live while a chain is
--- already pending too (unlike toggleMoveOffset itself), since flipping it mid-adjust is exactly
--- when you would want to see the effect.
function ADFlyoverEditor:toggleMoveOffsetFalloff()
    if not self.moveOffsetFalloffOn and self.moveBreakOn then
        return   -- disconnect is on: a taper cannot stay joined to a track it is cut from
    end
    self.moveOffsetFalloffOn = not self.moveOffsetFalloffOn
    -- An offset that tapers into the track it came from cannot also be cut loose from it.
    if self.moveOffsetFalloffOn then
        self.moveBreakOn = false
    end
    if self.moveOffsetChainIds ~= nil then
        self:applyMoveOffset()
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move offset falloff %s.", self.moveOffsetFalloffOn and "on" or "off")
end

--- Rotate's pivot choice (settled 2026-09-21): "click" rotates the moved set around the dragged
--- point's own start position, "centroid" around the average of the whole set's start positions.
--- Only takes effect on the NEXT grab (see beginDrag) - changing it mid-drag would yank the
--- pivot out from under an already-rotating shape.
function ADFlyoverEditor:cycleMoveRotatePivot()
    self.moveRotatePivotMode = (self.moveRotatePivotMode == "click") and "centroid" or "click"
    ADFlyoverSettings.debugLog("[FlyoverEditor]: move rotate pivot -> %s.", self.moveRotatePivotMode)
end

function ADFlyoverEditor:setMoveOffsetFalloffRadius(value)
    self.moveOffsetFalloffRadius = math.max(0, math.min(AutoDrive.FLYOVER_FALLOFF_MAX, value))
    if self.moveOffsetChainIds ~= nil then
        self:applyMoveOffset()
    end
end

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
            apply = function(value) return editor:applySettingValue(name, value) end,
            -- One click of a stepper (or one wheel notch over this field) moves to the next allowed
            -- value of the setting, the same steps typing snaps to.
            step = function(dir)
                local setting = ADFlyoverSettings.settings[name]
                if setting ~= nil and setting.values ~= nil then
                    local nextIndex = math.max(1, math.min(#setting.values, setting.current + dir))
                    if nextIndex ~= setting.current then
                        ADFlyoverSettings.setIndex(name, nextIndex)
                    end
                end
            end
        }
    end

    -- The wheel-driven tool values (a tolerance, a count, a distance) as typed fields, so they look
    -- and behave like every other number on a card: click to type, - / + to step, wheel over it.
    -- `bounds` clamps in both directions, `decimals` is how many places the card shows.
    local function fieldEntry(label, unit, decimals, key, lo, hi, stepBy, integer, onChange)
        local function set(value)
            value = math.max(lo, math.min(hi, value))
            if integer then value = math.floor(value + 0.5) end
            editor[key] = value
            if onChange ~= nil then onChange() end
            return editor[key]
        end
        return {
            label = label, unit = unit, decimals = decimals,
            get = function() return editor[key] end,
            apply = set,
            step = function(dir) set(editor[key] + dir * stepBy) end,
        }
    end
    local AD = AutoDrive
    if self.tool == self.TOOL.PARALLEL then
        return { fieldEntry("distance", "m", 1, "offsetDistance", AD.FLYOVER_OFFSET_MIN, AD.FLYOVER_OFFSET_MAX,
            AD.FLYOVER_OFFSET_STEP, false, function() editor.offsetCache = nil end) }
    elseif self.tool == self.TOOL.GROUND then
        return { fieldEntry("tolerance", "m", 1, "groundTolerance", AD.FLYOVER_GROUND_MIN, AD.FLYOVER_GROUND_MAX,
            AD.FLYOVER_GROUND_STEP, false) }
    elseif self.tool == self.TOOL.STRAIGHTEN then
        return { fieldEntry("tolerance", "m", 1, "straightenTolerance", AD.FLYOVER_STRAIGHTEN_MIN,
            AD.FLYOVER_STRAIGHTEN_MAX, AD.FLYOVER_STRAIGHTEN_STEP, false) }
    elseif self.tool == self.TOOL.DIVIDE then
        return { fieldEntry("points", "", 0, "divideCount", 0, AD.FLYOVER_DIVIDE_MAX, 1, true) }
    elseif self.tool == self.TOOL.SMOOTH and self.smoothMode ~= self.SMOOTH_MODE.REBUILD then
        return { fieldEntry("strength", "", 0, "smoothStrength", 0, AD.FLYOVER_SMOOTH_MAX, 1, true) }
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
        -- Grouped to match the toggle order above (detect custom field, then avoid obstacles),
        -- not the order these were added in: the shape of the ring itself first (margin, turning
        -- radius - neither toggle changes what these mean), then combo gap (only matters when
        -- "detect custom field" is on), then obstacle clearance/vehicle height (only matter when
        -- "avoid obstacles" is on) last, right where "avoid obstacles" - the last toggle before
        -- this list starts - sits closest to them.
        --
        -- Each toggle-owned number is also hidden entirely while its toggle is off, rather than
        -- shown but inert - a number that visibly does nothing is a worse tell than it being gone.
        local fields = {
            settingEntry("margin", "fieldLoopMargin"),
            settingEntry("turning radius", "fieldLoopTurningRadius"),
        }
        if ADFlyoverSettings.get("fieldLoopDetectCustomField") then
            table.insert(fields, settingEntry("combo gap", "fieldLoopMaxGap"))
        end
        if ADFlyoverSettings.get("fieldLoopAvoidObstacles") then
            table.insert(fields, settingEntry("obstacle clearance", "fieldLoopTreeClearance"))
            table.insert(fields, settingEntry("vehicle height", "fieldLoopVehicleHeight"))
        end
        return fields
    elseif self.tool == self.TOOL.SMOOTH and self.smoothMode == self.SMOOTH_MODE.REBUILD then
        return { {
            label = "max spacing",
            unit = "m",
            get = function() return editor.smoothSpacing end,
            apply = function(value)
                editor.smoothSpacing = math.max(AutoDrive.FLYOVER_SPACING_MIN,
                    math.min(AutoDrive.FLYOVER_SPACING_MAX, value))
                return editor.smoothSpacing
            end,
            step = function(dir)
                editor.smoothSpacing = math.max(AutoDrive.FLYOVER_SPACING_MIN,
                    math.min(AutoDrive.FLYOVER_SPACING_MAX,
                        editor.smoothSpacing + dir * AutoDrive.FLYOVER_SPACING_STEP))
            end
        } }
    elseif self.tool == self.TOOL.MERGE then
        return {
            settingEntry("merge distance", "flyoverMergeDistance"),
            settingEntry("divergence", "flyoverMergeDivergence")
        }
    elseif self.tool == self.TOOL.MOVE then
        local fields = {}

        -- A live offset chain owns this field while one is pending - it is a different value
        -- (signed distance, Run/Span only) from falloff's radius, and the two never apply at once
        -- (offset replaces the weighted-follower mechanism entirely - see gatherDragNeighbours).
        if self.moveOffsetChainIds ~= nil then
            table.insert(fields, {
                label = "sideways offset",
                unit = "m",
                get = function() return editor.moveOffsetDistance end,
                apply = function(value)
                    editor:setMoveOffsetDistance(value)
                    return editor.moveOffsetDistance
                end,
                step = function(dir)
                    editor:setMoveOffsetDistance(editor.moveOffsetDistance + dir * AutoDrive.FLYOVER_OFFSET_STEP)
                end
            })
        end

        if (self.moveOffsetOn or self.moveOffsetChainIds ~= nil) and self.moveOffsetFalloffOn then
            table.insert(fields, {
                label = "offset falloff",
                unit = "m",
                wheelReach = true,
                get = function() return editor.moveOffsetFalloffRadius end,
                apply = function(value)
                    editor:setMoveOffsetFalloffRadius(value)
                    return editor.moveOffsetFalloffRadius
                end,
                step = function(dir)
                    editor:setMoveOffsetFalloffRadius(editor.moveOffsetFalloffRadius + dir * AutoDrive.FLYOVER_FALLOFF_WHEEL_STEP)
                end
            })
        end

        -- Only Point has a settable reach. Run tapers to its own two ends automatically - there is
        -- no radius for it to set - so the field would just be a dead number sitting on the panel.
        if self.moveSelectMode == self.MOVE_SELECT.POINT and self.moveFalloffOn then
            table.insert(fields, {
                label = "falloff along track",
                unit = "m",
                -- Marks this field for handleWheel: a spatial REACH wants wheel-up to WIDEN it,
                -- the opposite of the global wheel-reversal every tolerance/count field uses (see
                -- handleWheel). `step`'s own `dir` still has to stay the RAW, unreversed sign here
                -- (matching what the +/- stepper buttons already send) - handleWheel is what flips
                -- the wheel's contribution before it ever reaches this function, not this function
                -- itself, since this same `step` also serves the buttons which must not be flipped.
                wheelReach = true,
                get = function() return editor.falloffRadius end,
                apply = function(value)
                    editor:setFalloffRadius(value)
                    return editor.falloffRadius
                end,
                step = function(dir)
                    editor:setFalloffRadius(editor.falloffRadius + dir * AutoDrive.FLYOVER_FALLOFF_WHEEL_STEP)
                end
            })
        end

        -- Persisted settings (unlike the two above, which are ephemeral per-drag state) - same
        -- settingEntry() shape MERGE already uses for its own distance/divergence pair.
        if self.moveAutoHookupOn then
            table.insert(fields, settingEntry("hookup distance", "flyoverAutoHookupDistance"))
            table.insert(fields, settingEntry("hookup divergence", "flyoverAutoHookupDivergence", "deg"))
        end

        return fields
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: editing '%s' (currently %s). Type a value, Enter to apply, Esc to cancel.",
        entry.label, tostring(current))
end

function ADFlyoverEditor:cancelEditNumber()
    self.editingWarned = false
    if self.editing ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: '%s' left unchanged.", self.editing.label)
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: '%s' set to %.2f%s - the nearest step to the %.2f typed.",
            edit.label, applied, edit.unit or "", typed)
    else
        ADFlyoverSettings.debugLog("[FlyoverEditor]: '%s' set to %.2f%s.", edit.label, applied, edit.unit or "")
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: typing into '%s' - the keyboard goes to this field until Enter or Esc, or a click elsewhere.",
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
        self:markEscHandled()
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

--- Toggle the junction tool's road-surface / corridor check. Off, a turn is still bounded by the
--- radius setting but is never shrunk or refused for leaving the road - see junctionSolveMovement.
function ADFlyoverEditor:toggleJunctionCheckSurface()
    self.junctionCheckSurface = not (self.junctionCheckSurface ~= false)
    self.junctionPreviewKey = nil        -- force a resolve so the change is visible immediately
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction road-surface check %s.",
        self.junctionCheckSurface and "on" or "off (turns only bounded by radius)")
end

--- Toggle the static-obstacle check (trees, buildings, fences/poles/signs via the physics world).
function ADFlyoverEditor:toggleJunctionCheckObstacles()
    self.junctionCheckObstacles = not (self.junctionCheckObstacles ~= false)
    self.junctionPreviewKey = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction obstacle check %s.",
        self.junctionCheckObstacles and "on" or "off (corridors may pass through obstacles)")
end

--- Toggle the connector curve engine between Dubins (radius-bounded pose-to-pose) and the biarc.
function ADFlyoverEditor:toggleJunctionCurveEngine()
    self.junctionUseDubins = not (self.junctionUseDubins ~= false)
    self.junctionPreviewKey = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction curve engine: %s.",
        self.junctionUseDubins and "Dubins (radius-bounded)" or "biarc (tangent fit)")
end

--- Toggle rebuilding of existing turn connectors: on, a placement REPLACES an existing connection
--- whose path leaves the road skeleton (deletes the old connector's interior nodes, lays a fresh
--- one); off (default), such connections are kept as "already there". Through roads are never
--- touched either way - their path IS the skeleton, so there is nothing to delete.
function ADFlyoverEditor:toggleJunctionRebuild()
    self.junctionRebuild = not (self.junctionRebuild == true)
    self.junctionPreviewKey = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction existing turns will be %s.",
        self.junctionRebuild and "REBUILT (old connectors replaced)" or "kept as they are")
end

--- Toggle whether a trimmed stem's tie-in may project past where the track actually ends. Off
--- restores the strict original behaviour (clamp at the trim); on (default) reaches the
--- geometrically correct tie-in point even when the visible track was cut back short of it.
function ADFlyoverEditor:toggleJunctionExtendTrim()
    self.junctionExtendTrim = not (self.junctionExtendTrim ~= false)
    self.junctionPreviewKey = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction trim/extend %s.",
        self.junctionExtendTrim and "on (projects past a trimmed stem)" or "off (clamps at the trim)")
end

function ADFlyoverEditor:toggleSnapToTerrain()
    self.snapToTerrain = not self.snapToTerrain
    ADFlyoverSettings.debugLog("[FlyoverEditor]: heights now snap to %s.",
        self.snapToTerrain and "the terrain, ignoring structures" or "whatever surface is there")
end

function ADFlyoverEditor:cycleDeleteScope()
    self.deleteScope = (self.deleteScope % #self.DELETE_SCOPE_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: delete removes %s.", self.DELETE_SCOPE_NAMES[self.deleteScope])
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
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
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

    ADFlyoverSettings.debugLog("[FlyoverEditor]: deleted a run of %d waypoint(s), stopping at %d junction(s), which were left in place.",
        #ids, junctionCount)
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:deleteAtCursor()
    -- With a selection built up, a left click does nothing: it is too easy to be the click that ENDS a
    -- Ctrl-selection. Right-click deletes the selection (stopCurrentAction), Esc clears it.
    if self.selectionCount > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: %d selected - right-click deletes them, Esc clears the selection.",
            self.selectionCount)
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: deleted waypoint id=%s at x=%.1f z=%.1f (%d left).",
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

    ADFlyoverSettings.debugLog("[FlyoverEditor]: deleted %d selected waypoint(s).", #ids)
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: height check - cursor y=%s, terrain y=%.2f (using terrain).",
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: placed waypoint id=%s at x=%.1f y=%.1f z=%.1f%s",
        tostring(newId), x, y, z, connectPrevious and " (connected to the previous one)" or "")
end

function ADFlyoverEditor:draw()
    if not self.active then
        return
    end

    -- A modal (the browsable manual or the settings dialog) owns the whole screen. Skip the world
    -- network entirely while one is up: its accent spheres and the on-foot fallback would otherwise
    -- draw behind the modal, and - more to the point - the proxy's copy of AutoDrive's editor draw
    -- (the waypoint labels, ids and the editor cursor) is queued as TEXT, which the engine composites
    -- in a pass no overlay background can cover. The proxy skips its own draw the same way (see
    -- ADFlyoverProxy.run) and the HUD draws only the modal, so the page/dialog reads clean instead of
    -- having the network's labels bleed through it.
    if not self:isModalOpen() then
        tryCall("drawNetwork", function() self:drawNetwork() end)
    end

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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: smooth mode -> %s.", self.SMOOTH_MODE_NAMES[self.smoothMode])
end

function ADFlyoverEditor:smoothClick()
    self:spanPickClick({
        getFrom = function() return self.smoothFromId end,
        getTo = function() return self.smoothToId end,
        setEnds = function(a, b)
            self.smoothFromId, self.smoothToId = a, b
            self.smoothPreview, self.smoothPinned = nil, nil
        end,
        onSpan = function(a, b)
            ADFlyoverSettings.debugLog("[FlyoverEditor]: smoothing id=%s..id=%s in %s mode. Wheel sets %s, right-click applies.",
                tostring(a), tostring(b), self.SMOOTH_MODE_NAMES[self.smoothMode],
                self.smoothMode == self.SMOOTH_MODE.REBUILD and "max spacing" or "strength")
        end,
    })
end

function ADFlyoverEditor:cancelSmooth()
    self.spanIds = nil
    if self.smoothFromId ~= nil or self.smoothToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: smooth cancelled.")
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
    local ids = self:spanBetween(self.smoothFromId, self.smoothToId)
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
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
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
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: relaxed %d of %d waypoint(s) at strength %d; %d pinned (junctions or ends).",
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
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: nothing to rebuild - the span is all anchors, or too short between them.")
        return
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: rebuilt %d piece(s) at %.1fm max spacing: %d point(s) -> %d, %d junction/marker anchor(s) kept in place.",
        piecesDone, maxSpacing, before, after, junctions)
end

--- Divide a span, splitting it at anchors the same way rebuild does.
---
--- The requested count is shared out between the pieces in proportion to their length, so asking
--- for N points across a span that happens to cross an intersection still gives roughly N points
--- overall and even spacing throughout - rather than refusing, which is what it did before.
--- The pieces of a span BETWEEN its anchors (its ends, junction-joined points and map markers), each as
--- the span's OWN route - the stretch of `ids` between two anchors - not a fresh shortest path.
---
--- Where two anchors are joined by more than one route (a siding beside the main line, a loop, a junction
--- cluster at a run's end), a path search takes the shorter one, and the tool then rebuilt a DIFFERENT
--- track from the one that was picked and previewed: Divide split the wrong route, Straighten replaced
--- junction points. Pieces are remembered as POSITIONS, because ids renumber as each piece is replaced,
--- and looked up again (exact match, a few centimetres) when their turn comes - back to front, so pieces
--- not yet reached are untouched. Returns anchorPositions, interiorAnchorCount, pieceFor(i) -> ids | nil.
function ADFlyoverEditor:ownRoutePieces(ids)
    local anchorPositions, anchors = self:collectSpanAnchors(ids)

    local piecePositions = {}
    local slicesOk = true
    do
        local anchorIndex, from = {}, 1
        for a = 1, #anchorPositions do
            local pos, found = anchorPositions[a], nil
            for k = from, #ids do
                local wp = ADGraphManager:getWayPointById(ids[k])
                if wp ~= nil and math.abs(wp.x - pos.x) < 0.03 and math.abs(wp.z - pos.z) < 0.03 then
                    found = k
                    break
                end
            end
            if found == nil then
                slicesOk = false
                break
            end
            anchorIndex[a], from = found, found
        end
        if slicesOk then
            for a = 1, #anchorPositions - 1 do
                local list = {}
                for k = anchorIndex[a], anchorIndex[a + 1] do
                    local wp = ADGraphManager:getWayPointById(ids[k])
                    if wp ~= nil then
                        list[#list + 1] = { x = wp.x, z = wp.z }
                    end
                end
                piecePositions[a] = list
            end
        end
    end

    local function pieceFor(i)
        if slicesOk and piecePositions[i] ~= nil then
            local out = {}
            for _, pos in ipairs(piecePositions[i]) do
                local id = self:findWayPointExact(pos)
                if id == nil then
                    out = nil
                    break
                end
                out[#out + 1] = id
            end
            if out ~= nil and #out >= 2 then
                return out, true
            end
        end
        -- Could not follow the span's own route: fall back to the path between the anchors.
        local startId = self:findWayPointAt(anchorPositions[i])
        local endId = self:findWayPointAt(anchorPositions[i + 1])
        if startId ~= nil and endId ~= nil and startId ~= endId then
            return self:runPathBetween(startId, endId), false
        end
        return nil, false
    end

    return anchorPositions, anchors, pieceFor
end

function ADFlyoverEditor:divideSpanInPieces(ids, totalCount)
    local anchorPositions, anchors, pieceFor = self:ownRoutePieces(ids)

    -- Measure every piece first, so the count can be shared out by length.
    local pieces, totalLength = {}, 0
    for i = 1, #anchorPositions - 1 do
        local piece = pieceFor(i)

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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: nothing to divide.")
        return
    end

    local placed, done = 0, 0

    -- Back to front, so a piece cannot renumber the anchors of one not yet reached.
    for i = #anchorPositions - 1, 1, -1 do
        local share = math.floor(totalCount * (pieces[i].length / totalLength) + 0.5)

        local piece = pieceFor(i)
        if piece ~= nil and #piece >= 2 then
            local newPoints = self:evenlySpacedAlong(piece, share)
            if newPoints ~= nil and self:replaceChainInterior(piece, newPoints, self:spanStyle(piece)) then
                placed = placed + share
                done = done + 1
            end
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: divided %d piece(s) into %d point(s) total, %d intersection anchor(s) kept in place.",
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
--- The waypoint sitting exactly at `pos` (within a few centimetres), or nil. Unlike findWayPointAt this
--- never snaps to a NEIGHBOUR: on a siding or a parallel lane, the nearest waypoint within the anchor
--- tolerance can belong to the other lane.
function ADFlyoverEditor:findWayPointExact(pos)
    local wayPoints = ADGraphManager:getWayPoints()
    for i = 1, #wayPoints do
        local wp = wayPoints[i]
        if math.abs(wp.x - pos.x) < 0.03 and math.abs(wp.z - pos.z) < 0.03 then
            return wp.id
        end
    end
    return nil
end

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
    -- Aim the open dialog at the clicked waypoint directly, not only through the class-level onOpen
    -- wrapper: without this the dialog can still open on the marker nearest the vehicle.
    if ADEnterTargetNameGui.applyFlyoverOverride ~= nil then
        local screen = g_gui.guis ~= nil and g_gui.guis["ADEnterTargetNameGui"] or nil
        local instance = screen ~= nil and (screen.target or screen) or nil
        local ok, err = pcall(ADEnterTargetNameGui.applyFlyoverOverride, instance)
        if not ok then
            Logging.warning("[FlyoverEditor]: could not aim the name dialog at the clicked waypoint: %s", tostring(err))
        end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: opened the name dialog for waypoint id=%s.", tostring(self.hoverId))
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
ADFlyoverEditor.CONNECTION_NAMES = { "one-way", "two-way", "reverse-way" }

function ADFlyoverEditor:cycleConnectionMode()
    self.connectionMode = (self.connectionMode % #self.CONNECTION_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: new connections are now %s.", self.CONNECTION_NAMES[self.connectionMode])
end

function ADFlyoverEditor:togglePriority()
    self.subPrio = not self.subPrio
    ADFlyoverSettings.debugLog("[FlyoverEditor]: new connections are now %s.", self.subPrio and "secondary" or "primary")
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
--- One localized guidance message for the current tool state, returned WHOLE (not pre-split). The
--- panel wraps it to width at render (see buildRows). Collapsing the old line pairs into one string is
--- what lets German - which wraps differently from English - read as a sentence rather than two halves
--- broken at the English line break. Format placeholders are kept inside the localized template so the
--- live value lands in the right place in either language.
function ADFlyoverEditor:getNextStepLines()
    local t = self.TOOL
    local function L(s) return ADFlyoverLocale ~= nil and ADFlyoverLocale.t(s) or s end
    local function side() return L(self:sideName()) end

    -- Circle-select is tool-agnostic (selection is a shared substrate, same as Ctrl+drag box), so
    -- this overrides whatever the current tool would otherwise say - the mid-drag state is what the
    -- player actually needs telling right now, regardless of which tool is active. No "armed" state
    -- to report any more - Alt+drag starts a circle in one motion, the same as Ctrl+drag does a box.
    if self.circleActive then
        return L("Release to select everything inside the circle.")
    end
    if self.freehandActive then
        return L("Release to select everything inside the traced area.")
    end
    if self.rotBoxDragging then
        return L("Release to set the box's edge (direction and length).")
    end
    if self.rotBoxActive then
        return L("Click to set the width and finish the box.")
    end

    if self.tool == t.NONE then
        return L("No tool selected. Pick one above, or press 1-9 / 0.")
    end

    if self.tool == t.DRAW then
        if self.lastWaypointId ~= nil then
            return L("Click ground to extend, or a waypoint to link. Right-click ends.")
        end
        return L("Click to start a run, or a waypoint to draw on from it.")
    elseif self.tool == t.MOVE then
        if self.moveOffsetChainIds ~= nil then
            if self.dragId ~= nil then
                return string.format(L("Dragging sets the offset (%.1fm). Release, then wheel to fine-tune."),
                    self.moveOffsetDistance)
            end
            return string.format(L("Offset %.1fm - wheel to adjust, right-click to finish."),
                self.moveOffsetDistance)
        end
        if self.dragId ~= nil then
            local verb = (self.moveCopyOn and self.moveBreakOn and L("disconnect"))
                or (self.moveCopyOn and L("copy"))
                or (self.moveBreakOn and L("drop and disconnect"))
                or L("drop")
            if self.moveSelectMode == self.MOVE_SELECT.POINT and self.moveFalloffOn then
                return string.format(L("Wheel changes falloff (%.1fm), live. Release to %s."), self.falloffRadius, verb)
            end
            return string.format(L("Release to %s."), verb)
        end
        if self.moveSelectMode == self.MOVE_SELECT.SPAN then
            if self.moveSpanFromId == nil then
                return L("Click a waypoint to start the span.")
            end
            if self.moveSpanToId == nil then
                return L("Click the far end of the span.")
            end
            if self.hoverId ~= nil and self.moveSpanIds ~= nil and self.moveSpanIds[self.hoverId] then
                return L("Drag the highlighted span.")
            end
            return L("Click to replace whichever end is closer, or drag the span.")
        end
        if self.hoverId ~= nil then
            return L("Drag the highlighted waypoint.")
        end
        return L("Point at a waypoint, then drag it.")
    elseif self.tool == t.DELETE then
        if self.selectionCount > 0 then
            return string.format(L("Click to delete %d selected."), self.selectionCount)
        end
        if self.deleteScope == self.DELETE_SCOPE.RUN then
            return L("Click a run to delete all of it, out to the junctions at each end.")
        end
        if self.hoverId ~= nil then
            return L("Click to delete the highlighted one.")
        end
        return L("Point at a waypoint to delete it.")
    elseif self.tool == t.SMOOTH then
        if self.smoothToId ~= nil then
            if self.smoothMode == self.SMOOTH_MODE.REBUILD then
                return string.format(L("Wheel sets max spacing (%.1fm). Curves stay denser."), self.smoothSpacing)
            end
            return string.format(L("Wheel sets strength (%d). Right-click applies it."), self.smoothStrength)
        end
        if self.smoothFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click one end of the span.")
    elseif self.tool == t.NAME then
        return L("Click a waypoint to name it.")
    elseif self.tool == t.SPLINE then
        if self.splineToId ~= nil then
            return L("Wheel adjusts the curve. Right-click places it.")
        end
        if self.splineFromId ~= nil then
            return L("Click the waypoint to curve to.")
        end
        return L("Click the waypoint to curve from.")
    elseif self.tool == t.FIELDLOOP then
        return L("Click inside a field to ring it. Uses the field loop settings.")
    elseif self.tool == t.SIDING then
        if self.sidingBlockedBy ~= nil then
            return L("Will not fit here. See the log for why.")
        end
        if self.sidingAnchorId ~= nil then
            return string.format(L("Wheel sets length (%.0fm, %s side). Flip the side on the panel. Right-click applies."),
                ADFlyoverSettings.get("sidingLength") or 30, side())
        end
        return L("Click where the siding should sit - the click is its centre.")
    elseif self.tool == t.PARALLEL then
        if self.offsetToId ~= nil then
            if self.offsetBlockedBy ~= nil then
                return L("Too tight to offset that far. Wheel it back, or swap sides.")
            end
            return string.format(L("Wheel sets offset (%.1fm %s). Flip the side on the panel. Right-click applies."),
                self.offsetDistance, side())
        end
        if self.offsetFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click one end of a span to run a track alongside it, or double-click for the whole run.")
    elseif self.tool == t.GROUND then
        if self.groundToId ~= nil or self.groundUsesSelection then
            local n = self.groundPreview ~= nil and #self.groundPreview or 0
            if n == 0 then
                return string.format(L("Nothing over %.1fm off the ground. Wheel the tolerance down to see more."), self.groundTolerance)
            end
            return string.format(L("%d of %d waypoint(s) off the ground. Right-click re-seats them."), n, self.groundChecked or 0)
        end
        if self.groundFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click a span or double-click a run, or select points (box, circle, Ctrl-click) - connected or not - to find waypoints off the ground.")
    elseif self.tool == t.STRAIGHTEN then
        if self.straightenToId ~= nil then
            return string.format(L("Wheel sets tolerance (%.2fm). Right-click straightens the span."), self.straightenTolerance)
        end
        if self.straightenFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click one end of a span to straighten it, or double-click for the whole run.")
    elseif self.tool == t.DIVIDE then
        if self.divideToId ~= nil then
            return string.format(L("Wheel sets the count (%d). Right-click applies it."), self.divideCount)
        end
        if self.divideFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click one end of the span to divide.")
    elseif self.tool == t.CONVERT then
        return string.format(L("Click to make it %s (%s)."),
            L(self.CONVERT_OP_NAMES[self.convertDirection]) .. ", " .. L(self.CONVERT_OP_NAMES[self.convertPriority]),
            self.convertScope == self.DELETE_SCOPE.RUN and L("whole run") or L("this waypoint"))
    elseif self.tool == t.MERGE then
        if self.mergeToId ~= nil then
            return L("Green marks what would be absorbed. Click the OTHER track to merge (right-click if it is the only one).")
        end
        if self.mergeFromId ~= nil then
            return L("Click the far end of the span, on the SAME track.")
        end
        return L("Click one end of the span to merge, or double-click for the whole run.")
    elseif self.tool == t.JUNCTION then
        local jp = self.junctionPreview
        local placeable = jp ~= nil and ((jp.nNew or 0) + (jp.nRebuild or 0)) or 0
        if self.junctionArmed ~= nil then
            if placeable > 0 then
                if (jp.nRebuild or 0) > 0 then
                    return string.format(L("Site locked: %d new, %d rebuilt. Right-click places; left-click moves the lock."),
                        jp.nNew, jp.nRebuild)
                end
                return string.format(L("Site locked: %d new turn(s). Right-click places; left-click moves the lock."),
                    jp.nNew)
            end
            return L("Site locked, nothing new to place. Right-click unlocks; left-click moves the lock.")
        end
        if placeable > 0 then
            return string.format(L("%d turn(s) to lay here. Left-click locks the site; wheel = scope."), placeable)
        end
        return L("Point at a crossing and left-click to lock it. Wheel = scope; right-click leaves the tool.")
    end

    return ""
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline endpoints are %s.", self.splineSwapEnds and "swapped" or "normal")
end

function ADFlyoverEditor:toggleSplineEndTangent()
    self.splineFlipEndTangent = not self.splineFlipEndTangent
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline end tangent %s.", self.splineFlipEndTangent and "flipped" or "auto")
end

function ADFlyoverEditor:toggleSplineStartTangent()
    self.splineFlipStartTangent = not self.splineFlipStartTangent
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline start tangent %s.", self.splineFlipStartTangent and "flipped" or "auto")
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
    ADFlyoverSettings.debugLog("[FlyoverEditor]: spline curvature %s.", self.CURVATURE_NAMES[self.curvatureIndex])
end

function ADFlyoverEditor:splineClick()
    if self.hoverId == nil then
        return
    end

    if self.splineFromId == nil then
        self.splineFromId = self.hoverId
        ADFlyoverSettings.debugLog("[FlyoverEditor]: spline from id=%s; click the waypoint to curve to.", tostring(self.splineFromId))
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: previewing a spline id=%s -> id=%s. Wheel adjusts curvature, right-click places it.",
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: spline preview discarded.")
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: no curve to place (curvature %.2f); connecting id=%s to id=%s directly.",
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

    ADFlyoverSettings.debugLog("[FlyoverEditor]: placed spline id=%s -> id=%s with %d point(s), curvature %.2f, %s%s%s.",
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
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
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
--- Order a collected run by WALKING it from `startId`, staying inside the set.
---
--- This deliberately does not use a path finder. Once a siding has been laid on a loop, the loop
--- carries two junctions, so the run between them is bounded correctly - but the path finder is
--- free to take the OTHER way round, through the siding, and hand back a seven-waypoint shortcut
--- that never touches the waypoint that was clicked. Walking the set cannot do that: every step is
--- a neighbour already inside the run, so the result is the run itself, in order.
---
--- Returns nil when the walk does not cover the whole set, which means the run branches.
local function walkRunFrom(run, count, startId)
    local ordered = { startId }
    local visited = { [startId] = true }
    local previous, current = nil, startId

    while true do
        local wp = ADGraphManager:getWayPointById(current)
        if wp == nil then
            break
        end
        local nextId = nil
        for _, listName in ipairs(LINK_LISTS) do
            for _, other in pairs(linkList(wp, listName) or {}) do
                if run[other] and other ~= previous and not visited[other] then
                    nextId = other
                    break
                end
            end
            if nextId ~= nil then
                break
            end
        end
        if nextId == nil then
            break
        end
        visited[nextId] = true
        ordered[#ordered + 1] = nextId
        previous, current = current, nextId
    end

    if count ~= nil and #ordered < count then
        return nil
    end
    return ordered
end

--- A closed run has no ends, so it is cut opposite the seed: walk it right round, then rotate so
--- the seed sits mid-chain. A field loop is exactly where a siding belongs - a passing place on the
--- loop - so this is the common case, not an oddity. Cutting opposite the click leaves the most
--- room either side of it for the merge tapers.
local function orderClosedRun(run, count, seedId)
    local ordered = walkRunFrom(run, count, seedId)
    local n = ordered ~= nil and #ordered or 0
    if n < 3 then
        return ordered
    end
    local half = math.floor(n / 2)
    local rotated = {}
    for i = n - half + 1, n do rotated[#rotated + 1] = ordered[i] end
    for i = 1, n - half do rotated[#rotated + 1] = ordered[i] end
    return rotated
end

function ADFlyoverEditor:orderedRunThrough(seedId)
    local a, b, found, why = self:runEnds(seedId)

    local run, count = self:collectRunBetweenJunctions(seedId)
    if run == nil or count == nil or count < 2 then
        return nil, nil, nil, why or string.format(
            "id=%s gives a run of %s waypoint(s).", tostring(seedId), tostring(count or 0))
    end

    local ids
    if a == nil and found == 0 then
        -- No ends at all: a closed loop, not a failure. Cut it opposite the seed and carry on.
        ids = count >= 3 and orderClosedRun(run, count, seedId) or nil
        if ids ~= nil and #ids >= 3 then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: that run is a closed loop of %d waypoint(s); using it "
                .. "cut opposite id=%s.", #ids, tostring(seedId))
        else
            return nil, nil, nil, why
        end
    elseif a == nil then
        return nil, nil, nil, why
    else
        ids = walkRunFrom(run, count, a)
        if ids == nil then
            return nil, nil, nil, string.format(
                "the run through id=%s branches - walking it from id=%s did not reach all %d "
                .. "waypoint(s). Pick a run that does not fork.",
                tostring(seedId), tostring(a), count)
        end
    end
    if #ids < 2 then
        return nil, nil, nil, string.format(
            "the run through id=%s ordered to %d waypoint(s).", tostring(seedId), #ids)
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
        self:pickSideFromCursor(seedPts)
    end
    local plan, err = self:sidingPlan()
    if plan == nil then
        Logging.warning("[FlyoverEditor]: %s", tostring(err))
        return
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: siding centred on id=%s - %.0fm long, %.1fm to the %s, merging "
        .. "over %.0fm at each end. Wheel changes the length, right-click applies.",
        tostring(self.sidingAnchorId), plan.length, plan.offset,
        self:sideName(), plan.merge)
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

    ADFlyoverSettings.debugLog("[FlyoverEditor]: laid a %.0fm siding %.1fm to the %s with %.0fm merges, %d track "
        .. "waypoint(s), attached at id=%s and id=%s.",
        plan.length, plan.offset, self:sideName(), plan.merge,
        #plan.track, tostring(aId), tostring(dId))

    self.sidingAnchorId, self.sidingPreview = nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelSiding()
    if self.sidingAnchorId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the siding.")
    end
    self.sidingAnchorId, self.sidingPreview, self.sidingBlockedBy = nil, nil, nil
end

function ADFlyoverEditor:offsetClick()
    self:spanPickClick({
        getFrom = function() return self.offsetFromId end,
        getTo = function() return self.offsetToId end,
        setEnds = function(a, b)
            self.offsetFromId, self.offsetToId = a, b
            self.offsetPreview, self.offsetCache = nil, nil
        end,
        onSpan = function(a, b, span)
            -- The side follows where the cursor is when the span is completed, whichever gesture made it.
            local seedPts = self:offsetSpanPoints()
            if seedPts ~= nil then
                self:pickSideFromCursor(seedPts)
            end
            ADFlyoverSettings.debugLog("[FlyoverEditor]: span of %d waypoint(s). Wheel sets the offset (%.1fm); the side "
                .. "follows the cursor. Right-click applies.", #span, self.offsetDistance)
            -- The actual route, not just its length. runPathBetween is a path FINDER: asked to get from a
            -- siding back to the main line it can leave along one merge taper and return along the other,
            -- which is a legitimate shortest path and a span that doubles back. Printing the ids is what
            -- tells that apart from a wrong offset without another screenshot to guess from.
            local ids = {}
            for i, id in ipairs(span) do
                ids[i] = tostring(id)
            end
            ADFlyoverSettings.debugLog("[FlyoverEditor]: span route: %s", table.concat(ids, " -> "))
        end,
    })
end

--- Where a chain turns back on itself, or nil when it does not.
---
--- "Alongside" is defined relative to the direction of travel, so one side - left, say - lands on
--- opposite sides of the world before and after a reversal. The offset track appears to leap across
--- the line it was following, which is exactly what a doubled-back span produces.
local function reversalIn(pts)
    for i = 2, #pts - 1 do
        local ax, az = pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z
        local bx, bz = pts[i + 1].x - pts[i].x, pts[i + 1].z - pts[i].z
        local la = MathUtil.vector2Length(ax, az)
        local lb = MathUtil.vector2Length(bx, bz)
        if la > 0.01 and lb > 0.01 then
            -- cos of the turn between consecutive segments: -1 is an about-turn, +1 straight on.
            local cosTurn = (ax * bx + az * bz) / (la * lb)
            if cosTurn < -0.86 then  -- sharper than about 150 degrees
                return pts[i].id or i
            end
        end
    end
    return nil
end

--- A route from `fromId` to `toId` that never turns back on itself.
---
--- runPathBetween is a path FINDER, and its answer is the shortest way through the graph. Where the
--- line carries a siding, the shortest way between two points on the main line can leave along one
--- merge taper and return along the other: fewer waypoints than staying on the line, and a route
--- that doubles back through the intersections. Correct as a path, useless as something to run a
--- track beside.
---
--- So this walks the graph instead, and at every junction takes the neighbour that best CONTINUES
--- the current heading, refusing any step that turns back. That is what "keep going straight on
--- through the intersection" means as an instruction to a graph, and it is what picks the main line
--- over the taper without needing to know which is which.
function ADFlyoverEditor:straightRouteBetween(fromId, toId)
    local first = ADGraphManager:getWayPointById(fromId)
    local target = ADGraphManager:getWayPointById(toId)
    if first == nil or target == nil then
        return nil
    end

    local route = { fromId }
    local visited = { [fromId] = true }
    local current = first
    -- No heading yet on the first step: aim at the destination, so the walk sets off the right way
    -- out of a junction rather than down whichever neighbour happens to be listed first.
    local hx, hz = target.x - first.x, target.z - first.z
    local hl = MathUtil.vector2Length(hx, hz)
    if hl < 0.01 then
        return nil
    end
    hx, hz = hx / hl, hz / hl

    for _ = 1, 4096 do
        local seen, best, bestScore = {}, nil, nil
        for _, listName in ipairs(LINK_LISTS) do
            for _, otherId in pairs(linkList(current, listName) or {}) do
                if not seen[otherId] and not visited[otherId] then
                    seen[otherId] = true
                    local wp = ADGraphManager:getWayPointById(otherId)
                    if wp ~= nil then
                        local dx, dz = wp.x - current.x, wp.z - current.z
                        local d = MathUtil.vector2Length(dx, dz)
                        if d > 0.01 then
                            -- How well this step continues the heading. Reaching the destination
                            -- wins outright, so a final short hop is never passed over for a
                            -- straighter step going somewhere else.
                            local score = (dx / d) * hx + (dz / d) * hz
                            if otherId == toId then
                                score = math.huge
                            end
                            if score > -0.86 and (bestScore == nil or score > bestScore) then
                                best, bestScore = otherId, score
                            end
                        end
                    end
                end
            end
        end
        if best == nil then
            return nil  -- ran into a dead end without reaching the far point
        end

        route[#route + 1] = best
        visited[best] = true
        if best == toId then
            return route
        end

        local wp = ADGraphManager:getWayPointById(best)
        local dx, dz = wp.x - current.x, wp.z - current.z
        local d = MathUtil.vector2Length(dx, dz)
        hx, hz = dx / d, dz / d
        current = wp
    end
    return nil
end

--- The route between two ids, honouring a run that has already been resolved by walking.
---
--- Every span tool goes through here rather than calling runPathBetween directly. Whole-run scope
--- resolves the route ONCE, by walking the collected run, and that decision has to survive: asking
--- the path finder again between the same two ends sends the answer down whichever branch is
--- shortest, which on a line carrying a siding is never the siding.
function ADFlyoverEditor:spanBetween(fromId, toId)
    local stored = self.spanIds
    if stored ~= nil and stored[1] == fromId and stored[#stored] == toId then
        return stored
    end
    return self:runPathBetween(fromId, toId)
end

--- Resolve the whole run through `seedId` in one click: its two ends, and the route between them.
---
--- Shared by every tool that works on a span, so "whole run" means the same thing everywhere and
--- picks the branch that was clicked in each of them. Returns nil when the run does not have two
--- clear ends - a junction, or a closed loop - and the caller falls back to asking for two clicks.
function ADFlyoverEditor:resolveWholeRun(seedId)
    local run, count = self:collectRunBetweenJunctions(seedId)
    if run == nil or count == nil or count < 2 then
        return nil
    end

    local ends = {}
    for id in pairs(run) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            local seen, inside = {}, 0
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
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
        return nil
    end

    -- Reach one further at each end, onto the junction itself: the run is what lies BETWEEN
    -- junctions, so its own ends stop a segment short of them.
    local function reachToJunction(endId)
        local wp = ADGraphManager:getWayPointById(endId)
        if wp == nil then
            return endId
        end
        local seen, outside, found = {}, 0, nil
        for _, listName in ipairs(LINK_LISTS) do
            for _, other in pairs(linkList(wp, listName) or {}) do
                if not run[other] and not seen[other] then
                    seen[other] = true
                    outside = outside + 1
                    found = other
                end
            end
        end
        return outside == 1 and found or endId
    end

    local fromId, toId = reachToJunction(ends[1]), reachToJunction(ends[2])
    -- Both ends reach the SAME junction: the run is a loop that leaves a junction and comes back to it
    -- (captured 2026-09-24: "the whole run: 66 waypoint(s), id=12458 to id=12458"). A span from a point to
    -- itself is not a span - Straighten collapsed it and the others went all the way around it - so it is
    -- refused like a closed loop, and the caller asks for two clicks on the part wanted instead.
    if fromId == toId then
        return nil
    end
    local ordered = walkRunFrom(run, count, ends[1])
    if ordered == nil then
        return nil
    end

    local ids = { fromId }
    for _, id in ipairs(ordered) do
        ids[#ids + 1] = id
    end
    if toId ~= ends[2] then
        ids[#ids + 1] = toId
    end
    return fromId, toId, ids
end

--- Points of the selected span, and the span itself.
function ADFlyoverEditor:offsetSpanPoints()
    if self.offsetFromId == nil or self.offsetToId == nil then
        return nil, nil
    end
    -- Whole-run scope has already decided the route by walking the collected run, and that decision
    -- has to survive: re-deriving it here would put the path finder back in charge and send a
    -- siding's offset down the main line.
    local span = self.spanIds or self:runPathBetween(self.offsetFromId, self.offsetToId)

    -- Only when the shortest path doubles back. On a plain span the path finder is right and
    -- cheaper, so it keeps the job; the straight walk is the answer to intersections specifically.
    if span ~= nil and #span >= 3 then
        local check = {}
        for i, id in ipairs(span) do
            local wp = ADGraphManager:getWayPointById(id)
            check[i] = wp ~= nil and { x = wp.x, z = wp.z, id = id } or nil
        end
        if #check == #span and reversalIn(check) ~= nil then
            local straight = self:straightRouteBetween(self.offsetFromId, self.offsetToId)
            if straight ~= nil and #straight >= 2 then
                ADFlyoverSettings.debugLog("[FlyoverEditor]: the shortest path doubled back through an "
                    .. "intersection; took the straight run instead (%d waypoint(s), was %d).",
                    #straight, #span)
                span = straight
            end
        end
    end

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
    return cross >= 0 and 1 or -1, a, b
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
---
--- `dual` may be a boolean for the whole chain, or a function(index) returning the mode for the
--- connection arriving at point `index`. A span is not necessarily uniform - a route can run one-way
--- along a stretch and two-way around a bend - and sampling it once turned every mixed span into a
--- track that was entirely one thing or entirely the other, silently.
function ADFlyoverEditor:createRunFrom(points, dual, flags)
    local perSegment = type(dual) == "function"
    local firstId, previousId = nil, nil
    for index, p in ipairs(points) do
        -- The ground tool's targeting, with the source point's height as the expected line - not
        -- resolveHeightAt. That one leaves anything more than half a metre above the terrain alone,
        -- assuming a bridge, and an offset track lands beside its source on ground that may be well
        -- below it: down an embankment the new points kept the source's height and hung in the air.
        -- Nearest surface to the source height drops them onto the slope, and still keeps a track
        -- that stays over a bridge deck on the deck.
        local sourceY = p.y or AutoDrive:getTerrainHeightAtWorldPos(p.x, p.z)
        local y = self:groundTargetAt(p.x, sourceY, p.z, sourceY, true)
            or self:resolveHeightAt(p.x, p.z, p.y)
        local segmentDual = perSegment and dual(index) or dual
        local wp = ADGraphManager:recordWayPoint(p.x, y, p.z, previousId ~= nil, segmentDual, false,
            previousId or 0, flags, false)
        previousId = (wp ~= nil and wp.id) or ADGraphManager:getWayPointsCount()
        firstId = firstId or previousId
    end
    return firstId, previousId
end

--- Ask the SOURCE span which mode applies at a point on the offset track.
---
--- The two chains are not the same length - offsetting the inside of a bend drops points that fold,
--- so a fifteen-point span can become an eight-point track - and there is no index that maps one to
--- the other. Nearest source segment by midpoint is the honest way across: the offset point came
--- from somewhere along the original, and that is the segment whose direction it should inherit.
function ADFlyoverEditor:sourceDualAt(span, x, z)
    local best, bestDistance = nil, math.huge
    for i = 1, #span - 1 do
        local a = ADGraphManager:getWayPointById(span[i])
        local b = ADGraphManager:getWayPointById(span[i + 1])
        if a ~= nil and b ~= nil then
            local mx, mz = (a.x + b.x) * 0.5, (a.z + b.z) * 0.5
            local d = MathUtil.vector2Length(x - mx, z - mz)
            if d < bestDistance then
                best, bestDistance = ADGraphManager:isDualRoad(a, b), d
            end
        end
    end
    return best
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
        clearSplineState()
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
    -- Built here, so cleared here. This is a one-shot connection, not a live preview: it borrows
    -- AutoDrive's interpolation state to shape the curve and is finished with it immediately.
    --
    -- Leaving it set costs the camera zoom. AutoDrive:handleSplineCurvature suppresses zooming for
    -- as long as an interpolation is valid, so a stale one silently owns the mouse wheel from then
    -- on - and it does not show up while a tool that claims the wheel itself is selected, only
    -- afterwards, which is a long way from the siding that actually caused it.
    clearSplineState()
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
ADFlyoverEditor.PARALLEL_FLOW_NAMES = { "same way", "opposite" }

function ADFlyoverEditor:cycleParallelFlow()
    self.parallelFlow = (self.parallelFlow % #self.PARALLEL_FLOW_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: a parallel track beside a one-way road runs %s.",
        self.PARALLEL_FLOW_NAMES[self.parallelFlow])
end

function ADFlyoverEditor:commitOffset()
    ADFlyoverSettings.debugLog("[FlyoverEditor]: commit %s: from=%s to=%s anchor=%s preview=%s",
        self.tool == self.TOOL.SIDING and "siding" or "parallel",
        tostring(self.offsetFromId), tostring(self.offsetToId), tostring(self.sidingAnchorId),
        self.offsetPreview ~= nil and tostring(#self.offsetPreview) or "nil")
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

    -- Survey the WHOLE span, not just its first pair. A route is not necessarily uniform: it can
    -- run one-way along a stretch and two-way around a bend, and sampling one segment turned every
    -- such span into a track that was entirely one thing - silently, with the log confidently
    -- reporting the mode it had guessed.
    local dualCount, oneWayCount = 0, 0
    for i = 1, #span - 1 do
        local a = ADGraphManager:getWayPointById(span[i])
        local b = ADGraphManager:getWayPointById(span[i + 1])
        if a ~= nil and b ~= nil then
            if ADGraphManager:isDualRoad(a, b) then
                dualCount = dualCount + 1
            else
                oneWayCount = oneWayCount + 1
            end
        end
    end
    local mixed = dualCount > 0 and oneWayCount > 0

    -- Whether to lay the track back to front is necessarily a decision for the whole run - a chain
    -- has one direction. Any one-way part is what settles it: those want a return lane, and the
    -- two-way parts are indifferent, so following the one-way parts costs the two-way ones nothing.
    -- Only when asked: a parallel track beside a one-way road used to be laid back to front every time
    -- (a return lane), which is a surprise as a default. parallelFlow chooses; same way is the default.
    local layReversed = oneWayCount > 0 and self.parallelFlow == 2

    local laying = newPoints
    if layReversed and not siding then
        local flipped = {}
        for i = #newPoints, 1, -1 do
            flipped[#flipped + 1] = newPoints[i]
        end
        laying = flipped
    end

    ADEditorHistory:snapshot(siding and "siding" or "parallel track")
    -- Each connection takes the mode of the source segment nearest to it. On a uniform span that is
    -- the same answer everywhere, so nothing changes there; on a mixed one the track now inherits
    -- the pattern instead of flattening it.
    local layingDual = dual
    if mixed and not siding then
        layingDual = function(index)
            local p = laying[index]
            local at = p ~= nil and self:sourceDualAt(span, p.x, p.z) or nil
            if at == nil then
                return dual
            end
            return at
        end
    end
    local firstNewId, lastNewId = self:createRunFrom(laying, layingDual, flags)

    if siding and firstNewId ~= nil and lastNewId ~= nil then
        self:splineConnectIds(span[1], firstNewId, dual, flags)
        self:splineConnectIds(lastNewId, span[#span], dual, flags)
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: laid a %s of %d waypoint(s) %.1fm to the %s%s.",
        siding and "siding" or "parallel track", #laying, self.offsetDistance,
        self:sideName(),
        siding and ", splined in at both ends"
            or (mixed and string.format(", mixed (%d two-way, %d one-way segment(s)), running %s",
                    dualCount, oneWayCount, layReversed and "opposite" or "the same way")
                or (dual and ", two-way" or (layReversed and ", running opposite" or ", running the same way"))))

    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
    self.spanIds = nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelOffset()
    if self.offsetFromId ~= nil or self.offsetToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the span.")
    end
    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
    self.spanIds = nil
end

-- ---------------------------------------------------------------------------------------------
-- GROUND
--
-- Waypoints drift off the ground. A spline interpolates heights between its ends, an offset carries
-- the source point's height sideways onto terrain that is not at the same level, a field loop
-- follows a boundary across a ditch - each is locally reasonable and each can leave a point hanging
-- in the air or buried under a slope. None of it is visible from above, which is the whole problem:
-- the network looks perfect in flyover and a vehicle drives into a hillside.
--
-- So the tool shows before it fixes. The preview marks every waypoint further from the ground than
-- the tolerance and draws a line from where it is to where it would land, and only then does
-- right-click move anything. A tool that silently re-seated a whole run would be the fastest way to
-- flatten a deliberately raised bridge.
-- ---------------------------------------------------------------------------------------------

-- The same collision the mod's own height lookup uses, so "the ground" means to this tool what it
-- means to AutoDrive when it drives the route.
local GROUND_MASK = nil
local groundHit = nil

local function groundRayCallback(_, hitObjectId, x, y, z, distance)
    if y ~= nil then
        groundHit = y
    end
end
local GroundRay = { callback = groundRayCallback }

--- The highest surface directly beneath (x, fromY, z), searching `length` metres down. Nil if none.
local function surfaceBelow(x, z, fromY, length)
    if raycastClosest == nil then
        return nil
    end
    if GROUND_MASK == nil then
        GROUND_MASK = CollisionFlag.DEFAULT + CollisionFlag.ROAD + CollisionFlag.TERRAIN
    end
    groundHit = nil
    -- raycastClosest calls back synchronously, which is what AutoDrive relies on as well.
    local ok = pcall(raycastClosest, x, fromY, z, 0, -1, 0, math.max(length, 0.5),
        "callback", GroundRay, GROUND_MASK)
    if not ok then
        return nil
    end
    return groundHit
end

--- Every surface in the column at (x, z), top down, from `topY` to the terrain.
---
--- Stepped with the one ray call already proven here: cast down, note the hit, cast again from just
--- beneath it, until the terrain. That finds a bridge deck AND the road under it, where a single
--- cast from anywhere finds only whichever it meets first - and which that is depends entirely on
--- where the cast starts, which is exactly the decision that has to be made on purpose.
local function columnSurfaces(x, z, topY, terrainY)
    local hits = {}
    local from = topY
    for _ = 1, 8 do
        local h = surfaceBelow(x, z, from, (from - terrainY) + 1)
        if h == nil then
            break
        end
        hits[#hits + 1] = h
        if h <= terrainY + 0.05 then
            break
        end
        from = h - 0.1
    end
    if #hits == 0 or hits[#hits] > terrainY + 0.05 then
        hits[#hits + 1] = terrainY
    end
    return hits
end

-- ---------------------------------------------------------------------------------------------
-- Road-surface probe, for junction clearance. "On the road" is either a road MESH under the point
-- (the ray hits something other than the terrain and it carries the ROAD collision group, bit 13 -
-- asphalt meshes, bridge decks) or terrain whose surface MATERIAL is a road one. The material comes
-- from the 5th return of getTerrainAttributesAtWorldPos - the same value the game's WheelPhysics
-- reads to pick tyre-track and surface-sound behaviour - and the base ids are fixed across the
-- Giants maps (data/maps/*/sounds/sounds.xml): 0 field, 1 dirt, 2 grass, 3 sand, 5 leaves,
-- 6 gravel, 7 asphalt, 97 railroad, 98/99 water. Names for the log come from
-- g_currentMission.surfaceSounds when a map remaps them. Everything is guarded: if a call is not
-- there, terrain counts as road - "unknown" is never a reason to refuse a turn.
-- ---------------------------------------------------------------------------------------------
local roadHitId, roadHitY = nil, nil
local function roadRayCallback(_, hitObjectId, x, y, z, distance)
    if y ~= nil then
        roadHitId, roadHitY = hitObjectId, y
    end
end
local RoadRay = { callback = roadRayCallback }
local ROAD_MATERIALS = { [1] = true, [6] = true, [7] = true }         -- dirt track, gravel, asphalt
local BASE_MATERIAL_NAMES = { [0] = "field", [1] = "dirt", [2] = "grass", [3] = "sand", [4] = "sound",
    [5] = "leaves", [6] = "gravel", [7] = "asphalt", [97] = "railroad", [98] = "mediumWater", [99] = "shallowWater" }
local roadProbeNoted = {}

local function roadNote(key, fmt, ...)
    if not roadProbeNoted[key] then
        roadProbeNoted[key] = true
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction clearance - " .. fmt, ...)
    end
end

local function materialName(id)
    local list = g_currentMission ~= nil and g_currentMission.surfaceSounds or nil
    if type(list) == "table" then
        for _, s in pairs(list) do
            if type(s) == "table" and s.materialId == id and s.type == "wheel" and s.name ~= nil then
                return s.name
            end
        end
    end
    return BASE_MATERIAL_NAMES[id] or ("material " .. tostring(id))
end

--- Is (x, z) on a drivable road surface?
local function isRoadAt(x, z)
    local terrain = g_currentMission ~= nil and g_currentMission.terrainRootNode or nil
    if terrain == nil or raycastClosest == nil then return true end
    local ty = getTerrainHeightAtWorldPos(terrain, x, 1, z) or 0
    if GROUND_MASK == nil then
        GROUND_MASK = CollisionFlag.DEFAULT + CollisionFlag.ROAD + CollisionFlag.TERRAIN
    end
    roadHitId, roadHitY = nil, nil
    pcall(raycastClosest, x, ty + 6, z, 0, -1, 0, 12, "callback", RoadRay, GROUND_MASK)
    if roadHitId ~= nil and roadHitId ~= 0 and roadHitId ~= terrain then
        local ok, group = pcall(getCollisionFilterGroup, roadHitId)
        if ok and type(group) == "number" and bit32 ~= nil then
            if bit32.band(group, CollisionFlag.ROAD) ~= 0 then
                roadNote("mesh", "road mesh under the turn (ROAD collision group)")
                return true
            end
            if CollisionFlag.VEHICLE ~= nil and bit32.band(group, CollisionFlag.VEHICLE) ~= 0 then
                return true                                -- something parked there is not the road's fault
            end
        end
        roadNote("object", "a static object (not a road mesh) sits over a probed spot; classed as not road")
        return false
    end
    local ok, _, _, _, _, mat = pcall(getTerrainAttributesAtWorldPos, terrain, x, ty, z, true, true, true, true, false)
    if ok and type(mat) == "number" then
        local id = math.floor(mat + 0.5)
        local road = ROAD_MATERIALS[id] == true
        roadNote("mat:" .. id, "terrain material %d ('%s') classed as %s", id, materialName(id), road and "ROAD" or "not road")
        return road
    end
    roadNote("nomat", "terrain material lookup unavailable; terrain is treated as road")
    return true
end

--- Where a waypoint at (x, y, z) belongs, for the ground tool specifically.
---
--- NOT resolveHeightAt, which is right for placing a new point and wrong here: in surface mode it
--- leaves anything more than half a metre up alone, assuming a bridge, so floating points were
--- never marked.
---
--- A point under a bridge and a point that belongs on it look identical by height alone. The span
--- says which: a route over a bridge has its ends up on the approaches, a road under one has them
--- down at road level. So `expectedY` - the height interpolated between the span's ends at this
--- point - picks the surface in the column nearest the span's own line. Ends on the approaches put
--- the line at deck height and the points go onto the deck; ends at road level keep them on the road.
---
--- "top surface" ignores the span and takes the highest surface, for a route drawn wholly at ground
--- level under a bridge it should be on - the one case the span line cannot tell apart.
function ADFlyoverEditor:groundTargetAt(x, y, z, expectedY, spanLineOnly, keepTolerance)
    local terrainY = nil
    if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        terrainY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 1, z)
    end
    if terrainY == nil then
        return nil
    end
    if self.snapToTerrain then
        return terrainY
    end

    local reference = expectedY or y
    -- High enough to include a deck the span passes over, not so high that it reaches for the
    -- canopy of a tree that happens to overhang the road.
    local topY = math.max(y, reference, terrainY) + 15
    local surfaces = columnSurfaces(x, z, topY, terrainY)

    -- The level toggle belongs to the ground tool. Other callers laying new track want the surface
    -- nearest the line they came from, whatever the ground tool happens to be set to.
    if not spanLineOnly and self.groundLevel == self.GROUND_LEVEL.TOP then
        return surfaces[1]
    end

    -- Keep the point on the surface it already sits on, so grounding never pulls a point down off a
    -- ramp or bridge deck it is correctly on; only points off EVERY surface fall through to the span
    -- line below. This is what stops a route over a placed ramp being flattened onto the terrain.
    if keepTolerance ~= nil then
        for _, h in ipairs(surfaces) do
            if math.abs(y - h) <= keepTolerance then
                return h
            end
        end
    end

    local best, bestGap = surfaces[#surfaces], math.huge
    for _, h in ipairs(surfaces) do
        local gap = math.abs(h - reference)
        if gap < bestGap then
            best, bestGap = h, gap
        end
    end
    return best
end

--- Every waypoint in the span that sits further off the ground than the tolerance.
function ADFlyoverEditor:updateGroundPreview()
    -- What is being checked: a picked span, or - when no span is
    -- pending and no other type is locked - whatever is selected (box, circle, freehand, Ctrl-click),
    -- connected or not. Ground only asks where each point sits against the ground, so it never needs a path.
    local span
    self.groundUsesSelection = false
    if self.groundFromId ~= nil and self.groundToId ~= nil then
        span = self:spanBetween(self.groundFromId, self.groundToId)
        if span == nil or #span < 1 then
            span = { self.groundFromId, self.groundToId }   -- defensive: an unresolved span is still just two points
        end
    elseif self.groundFromId == nil and self.selectionCount > 0
        and (self.pickFilter == nil or self.pickFilter == "set") then
        span = {}
        for id in pairs(self.selection) do span[#span + 1] = id end
        table.sort(span)
        self.groundUsesSelection = true
        self.pickKind = "set"
    else
        self.groundPreview = nil
        return
    end

    -- The span's own line: its two ends' heights, interpolated by distance along it. That is what
    -- tells a route over a bridge from a road beneath one - see groundTargetAt.
    local pts, along = {}, { 0 }
    for i, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        pts[i] = wp
        if i > 1 and wp ~= nil and pts[i - 1] ~= nil then
            along[i] = along[i - 1] + MathUtil.vector2Length(wp.x - pts[i - 1].x, wp.z - pts[i - 1].z)
        else
            along[i] = along[i - 1] or 0
        end
    end
    local firstWp, lastWp = pts[1], pts[#pts]
    local total = along[#along] or 0
    local function expectedAt(i)
        -- A selection has no span line to interpolate along: each point is judged on its own.
        if self.groundUsesSelection or firstWp == nil or lastWp == nil or total < 0.01 then
            return nil
        end
        local t = along[i] / total
        return firstWp.y + (lastWp.y - firstWp.y) * t
    end

    local offenders, checked = {}, 0
    for index, id in ipairs(span) do
        local wp = pts[index]
        if wp ~= nil then
            checked = checked + 1
            -- Its own lookup rather than resolveHeightAt's - see groundTargetAt for why. Bridges are
            -- kept by the downward cast finding the deck, not by refusing to look. keepTolerance =
            -- groundTolerance so a point already sitting on the ramp/bridge deck is left there rather
            -- than dragged down to the terrain the span line runs over.
            local targetY = self:groundTargetAt(wp.x, wp.y, wp.z, expectedAt(index), false, self.groundTolerance)
            if targetY ~= nil then
                local delta = wp.y - targetY
                if math.abs(delta) > self.groundTolerance then
                    offenders[#offenders + 1] =
                        { id = id, x = wp.x, y = wp.y, z = wp.z, targetY = targetY, delta = delta }
                end
            end
        end
    end

    self.groundChecked = checked
    self.groundPreview = #offenders > 0 and offenders or nil
    self.groundBlockedBy = nil
end

function ADFlyoverEditor:groundClick()
    if self.pickFilter == "set" then
        return   -- locked to selections: span clicks are ignored
    end
    self:spanPickClick({
        getFrom = function() return self.groundFromId end,
        getTo = function() return self.groundToId end,
        setEnds = function(a, b)
            self.groundFromId, self.groundToId = a, b
            self.groundPreview = nil
            -- Each new inspection starts from the default tolerance. The wheel adjusts it while a
            -- span is selected, and the wheel is also the zoom - so a value scrolled up by accident and
            -- carried over hid points two and three metres off the ground behind a five-metre tolerance.
            if b == nil then
                self.groundTolerance = AutoDrive.FLYOVER_GROUND_DEFAULT
            end
        end,
        onSpan = function(a, b, span)
            if self.pickKind == "run" then
                self.groundTolerance = AutoDrive.FLYOVER_GROUND_DEFAULT
            end
        end,
    })
end

function ADFlyoverEditor:commitGround()
    if self.groundPreview == nil or #self.groundPreview == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: nothing is further than %.1fm off the ground in that span "
            .. "(%d waypoint(s) checked).", self.groundTolerance, self.groundChecked or 0)
        self:cancelGround()
        return
    end

    ADEditorHistory:snapshot("ground")

    local moved, raised, lowered = 0, 0, 0
    for _, p in ipairs(self.groundPreview) do
        local wp = ADGraphManager:getWayPointById(p.id)
        -- Re-read rather than trusting the preview: it was built on an earlier frame, and an id can
        -- mean a different waypoint after any edit that removed one.
        if wp ~= nil and math.abs(wp.x - p.x) < 0.01 and math.abs(wp.z - p.z) < 0.01 then
            ADGraphManager:moveWayPoint(p.id, p.x, p.targetY, p.z, wp.flags, false)
            moved = moved + 1
            if p.delta > 0 then
                lowered = lowered + 1
            else
                raised = raised + 1
            end
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: re-seated %d waypoint(s) on the ground - %d lowered, %d raised "
        .. "(tolerance %.1fm).", moved, lowered, raised, self.groundTolerance)

    self.groundFromId, self.groundToId, self.groundPreview = nil, nil, nil
    self.spanIds = nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelGround()
    self.spanIds = nil
    if self.groundFromId ~= nil or self.groundToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the ground span.")
    end
    self.groundFromId, self.groundToId, self.groundPreview = nil, nil, nil
end

function ADFlyoverEditor:straightenClick()
    self:spanPickClick({
        getFrom = function() return self.straightenFromId end,
        getTo = function() return self.straightenToId end,
        setEnds = function(a, b)
            self.straightenFromId, self.straightenToId = a, b
            self.straightenPreview = nil
        end,
    })
end

--- Points of the current span, or nil.
function ADFlyoverEditor:straightenSpanPoints()
    if self.straightenFromId == nil or self.straightenToId == nil then
        return nil, nil
    end
    local span = self:spanBetween(self.straightenFromId, self.straightenToId)
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

--- Straighten a span, splitting it at any junction or marker so crossing routes survive - the same
--- split the smooth rebuild uses. Straightening the whole span through replaceChainInterior deleted
--- interior junctions and took the connections of the routes crossing there with them; each
--- junction-free piece is straightened on its own instead, and the anchors between pieces are left
--- untouched.
function ADFlyoverEditor:straightenSpanInPieces(ids)
    local anchorPositions, _, pieceFor = self:ownRoutePieces(ids)
    local piecesDone = 0
    -- Backwards, so a rebuilt piece cannot renumber the anchors of a piece not yet reached.
    for i = #anchorPositions - 1, 1, -1 do
        local piece, followedOwnRoute = pieceFor(i)
        if piece ~= nil and #piece > 2 then
            local pts = {}
            for j = 1, #piece do
                local wp = ADGraphManager:getWayPointById(piece[j])
                if wp ~= nil then
                    pts[#pts + 1] = { x = wp.x, y = wp.y, z = wp.z }
                end
            end
            local simplified = ADPolygonUtils.simplifyOpenChainRDP(pts, self.straightenTolerance)
            if simplified ~= nil and #simplified >= 2 then
                local result = respreadAlong(simplified, #pts - 2)
                if result ~= nil then
                    for k = 2, #result - 1 do
                        result[k].y = self:resolveHeightAt(result[k].x, result[k].z,
                            heightAlongChain(pts, result[k].x, result[k].z))
                    end
                    local a = ADGraphManager:getWayPointById(piece[1])
                    local b = ADGraphManager:getWayPointById(piece[2])
                    local dual = ADGraphManager:isDualRoad(a, b)
                    local flags = b.flags or AutoDrive.FLAG_NONE
                    -- A capture of exactly what is replaced, so a point that goes missing at a run's end can be
                    -- traced: the piece's end ids and how many points sat on it, and whether it was the span's
                    -- own route or the fallback path.
                    ADFlyoverSettings.debugLog("[FlyoverEditor]: straighten piece %d: ids %s -> %s (%d point(s)), %s, "
                        .. "keeps %d, replaces the %d between.", i, tostring(piece[1]), tostring(piece[#piece]),
                        #piece, followedOwnRoute and "own route" or "FALLBACK path", 2, #piece - 2)
                    if self:replaceChainInterior(piece, result, dual, flags) then
                        piecesDone = piecesDone + 1
                    end
                end
            end
        end
    end
    return piecesDone
end

function ADFlyoverEditor:commitStraighten()
    local pts, span = self:straightenSpanPoints()
    if pts == nil or span == nil or self.straightenPreview == nil then
        self:cancelStraighten()
        return
    end

    ADEditorHistory:snapshot("straighten span")
    local pieces = self:straightenSpanInPieces(span)

    ADFlyoverSettings.debugLog("[FlyoverEditor]: straightened a %d-point span in %d junction-free piece(s) at %.2fm tolerance.",
        #pts, pieces, self.straightenTolerance)

    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelStraighten()
    self.spanIds = nil
    if self.straightenFromId ~= nil or self.straightenToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: cancelled the straighten span.")
    end
    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
end

function ADFlyoverEditor:divideClick()
    self:spanPickClick({
        getFrom = function() return self.divideFromId end,
        getTo = function() return self.divideToId end,
        setEnds = function(a, b)
            self.divideFromId, self.divideToId = a, b
            self.dividePreview = nil
        end,
        onSpan = function(a, b, span)
            -- Start the wheel from what the span already has, so it adjusts from the current spacing
            -- rather than carrying a count over from the previous span (39 points wheeled up on a long
            -- span were once applied to a single segment).
            self.divideCount = math.max(0, #span - 2)
        end,
    })
end

--- How many waypoints currently sit between two ends, or 0 if they are not connected.
function ADFlyoverEditor:currentInteriorCount(fromId, toId)
    local span = self:runPathBetween(fromId, toId)
    if span == nil then
        return 0
    end
    return math.max(0, #span - 2)
end

-- ---------------------------------------------------------------------------------------------
-- Junction tool - V1: one-click intersection generator. Scope -> approaches -> movement matrix ->
-- track-tangent connectors, previewed live and committed on right-click. The wheel sizes the scope
-- circle, the primary disambiguation lever. See docs/junction-plan.md.
-- ---------------------------------------------------------------------------------------------

--- Smallest angle between two bearings, radians, 0..pi.
local function junctionAngDiff(a, b)
    local d = math.abs(a - b) % (2 * math.pi)
    if d > math.pi then d = 2 * math.pi - d end
    return d
end

-- Unit direction of a chain around index idx (lower index -> higher index).
local function junctionSegDir(chain, idx)
    local a = chain[math.max(1, idx - 1)]
    local b = chain[math.min(#chain, idx + 1)]
    local dx, dz = b.x - a.x, b.z - a.z
    local l = math.max(1e-6, math.sqrt(dx * dx + dz * dz))
    return dx / l, dz / l
end

--- Walk from chain[startIdx] toward index 1 (the boundary) by arc length `dist`, staying ON the chain
--- for as long as there IS chain. Returns the point (x,y,z) and the unit direction (lower->higher
--- index) of the segment it lands on. dist <= 0 returns chain[startIdx] itself.
--- Running OUT of chain before covering `dist` EXTRAPOLATES past the boundary node along its own
--- final segment direction, rather than clamping there - a stem trimmed back short of where the turn
--- geometry needs its tie-in still gets one at the geometrically correct point, in line with the
--- track, instead of a wrong one dragged in to wherever the trim happened to stop.
--- `allowExtend` (card toggle "trim/extend", default true) governs what happens when `dist` runs out
--- of chain: true extrapolates past the boundary node (see above); false clamps there, the original
--- behaviour, for when a stem SHOULD be left exactly where it ends rather than projected further.
local function junctionWalkBack(chain, startIdx, dist, allowExtend)
    if dist <= 0 or startIdx <= 1 then
        local p = chain[startIdx]
        local dx, dz = junctionSegDir(chain, startIdx)
        return p.x, p.y or 0, p.z, dx, dz
    end
    local remaining, i = dist, startIdx
    while i > 1 and remaining > 0 do
        local a, b = chain[i - 1], chain[i]
        local seglen = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        if seglen >= remaining and seglen > 1e-6 then
            local f = (seglen - remaining) / seglen
            return a.x + (b.x - a.x) * f, (a.y or 0) + ((b.y or 0) - (a.y or 0)) * f, a.z + (b.z - a.z) * f,
                (b.x - a.x) / seglen, (b.z - a.z) / seglen
        end
        remaining = remaining - seglen
        i = i - 1
    end
    local a = chain[1]
    local dx, dz = junctionSegDir(chain, 1)
    if not allowExtend then
        remaining = 0
    end
    return a.x - dx * remaining, a.y or 0, a.z - dz * remaining, dx, dz
end

--- Sample the circular arc that leaves P with unit tangent T and passes through Q. Appends points to
--- `out` from just past P up to and INCLUDING Q, and returns the arc's radius (math.huge when P->Q is
--- already straight along T). Point spacing is by a fixed sagitta, so a tight arc gets denser points
--- and a gentle one fewer - every arc stays equally smooth.
-- Max chord deviation from the true curve (sagitta): the waypoint tolerance of every laid arc.
-- Tightened 0.12 -> 0.05 (field feedback: curves read as chunky at small radii).
local JUNCTION_SAG = 0.05
local function junctionArcTo(out, px, pz, tx, tz, qx, qz, y0, y1)
    local dx, dz = qx - px, qz - pz
    local d2 = dx * dx + dz * dz
    local cross = tx * dz - tz * dx                    -- signed perpendicular reach of Q from T
    if d2 < 1e-6 then return math.huge end
    if math.abs(cross) < 1e-4 * math.sqrt(d2) then     -- straight: one chord
        out[#out + 1] = { x = qx, y = y1, z = qz }
        return math.huge
    end
    local nx, nz = -tz, tx                             -- left normal of T
    if cross < 0 then nx, nz = tz, -tx end             -- centre is on the side Q lies on
    local r = d2 / (2 * math.abs(cross))
    local cx, cz = px + r * nx, pz + r * nz
    local a0 = math.atan2(pz - cz, px - cx)
    local a1 = math.atan2(qz - cz, qx - cx)
    local da = math.atan2(math.sin(a1 - a0), math.cos(a1 - a0))
    local dth = 2 * math.acos(math.max(-1, math.min(1, 1 - JUNCTION_SAG / r)))
    local steps = math.max(2, math.ceil(math.abs(da) / math.max(dth, 1e-3)))
    for i = 1, steps do
        local u = i / steps
        local th = a0 + da * u
        out[#out + 1] = { x = cx + r * math.cos(th), y = y0 + (y1 - y0) * u, z = cz + r * math.sin(th) }
    end
    return r
end

--- Biarc from (P0, tangent T0) to (P1, tangent T1): two circular arcs meeting tangent-continuously at
--- a joint J, the classic equal-handle construction. Given the tie-in POINTS (on the real tracks) and
--- their LOCAL tangents, this is the smooth curve that honours both exactly; for a clean crossing with
--- tie-ins at t = R*tan(delta/2) it degenerates to the single radius-R fillet arc. Returns the
--- interior points (excluding P0 and P1) and the SMALLER of the two radii - the number to hold against
--- the turn-radius setting. nil when the tangents cannot be joined (they point away from each other).
local function junctionBiarc(p0x, p0z, t0x, t0z, p1x, p1z, t1x, t1z, y0, y1)
    local vx, vz = p1x - p0x, p1z - p0z
    local vv = vx * vx + vz * vz
    if vv < 1e-6 then return nil end
    local tt = t0x * t1x + t0z * t1z
    local vt = vx * (t0x + t1x) + vz * (t0z + t1z)
    local denom = 2 * (1 - tt)
    local alpha
    if math.abs(denom) < 1e-6 then                     -- parallel tangents
        local vt1 = vx * t1x + vz * t1z
        if math.abs(vt1) < 1e-6 then return nil end
        alpha = vv / (4 * vt1)
    else
        alpha = (-vt + math.sqrt(math.max(0, vt * vt + denom * vv))) / denom
    end
    if alpha <= 1e-4 then return nil end
    local jx = (p0x + alpha * t0x + p1x - alpha * t1x) / 2
    local jz = (p0z + alpha * t0z + p1z - alpha * t1z) / 2
    local ym = (y0 + y1) / 2
    local pts = {}
    local r1 = junctionArcTo(pts, p0x, p0z, t0x, t0z, jx, jz, y0, ym)
    -- Second arc, built backwards from P1 (tangent -T1) to J so it arrives along T1, then reversed.
    local back = {}
    local r2 = junctionArcTo(back, p1x, p1z, -t1x, -t1z, jx, jz, y1, ym)
    pts[#pts] = nil                                    -- drop J once; the back list (reversed) starts on it
    for i = #back, 1, -1 do pts[#pts + 1] = back[i] end
    -- Neither P0 nor P1 is in the list (junctionArcTo excludes its start point) - they are the tie-ins.
    return { points = pts, minRadius = math.min(r1, r2), jx = jx, jz = jz }
end

-- Deterministic link primitives - NOT toggles. AutoDrive's toggleConnectionBetween flips state (its
-- remove branch fires on an OR of two list checks and its insert never checks for duplicates), so
-- anything built on it can leave a link in a state nobody asked for when an operation re-enters the
-- same pair - a repeat placement over the same spot, an undo/redo interleave. That is the class of
-- bug that minted two-way ("blue") links on one-way roads. These two are idempotent and explicit:
-- calling them twice is the same as calling them once, and the resulting state is exactly what the
-- arguments say, regardless of what was there before.
local function junctionConnect(a, b, dual)
    if a == nil or b == nil or a.id == b.id then return end
    if not table.contains(a.out, b.id) then table.insert(a.out, b.id) end
    if not table.contains(b.incoming, a.id) then table.insert(b.incoming, a.id) end
    if dual then
        if not table.contains(b.out, a.id) then table.insert(b.out, a.id) end
        if not table.contains(a.incoming, b.id) then table.insert(a.incoming, b.id) end
    end
end

-- Remove every connection between a and b, both directions, unconditionally.
local function junctionDisconnect(a, b)
    if a == nil or b == nil then return end
    table.removeValue(a.out, b.id)
    table.removeValue(b.incoming, a.id)
    table.removeValue(b.out, a.id)
    table.removeValue(a.incoming, b.id)
end

--- The connector curve via AutoDrive's own ADDubins solver (scripts/Utils/Dubins.lua): the shortest
--- curvature-bounded path between two POSES - position + heading at each tie-in - with the minimum
--- turn radius guaranteed by construction. Where the biarc is pinned to bending directly between its
--- two tangents, Dubins solves over the whole pose space (LSL/RSR/LSR/RSL/RLR/LRL), so it can swing
--- OUT across the corridor before curving back - the wide, road-using shape sketched for the inside
--- corner - and it never produces a radius below the bound. Dubins convention here (matching
--- ADDubins.createWayPoints): plane X = world x, plane Y = -world z, theta = atan2(-dz, dx).
--- Returns { points (interior, ~1.5 m), minRadius, length } or nil (solver missing/failed, or the
--- path is an implausible loop - the caller falls back to the biarc).
local function junctionDubins(pax, paz, tAx, tAz, pbx, pbz, tBx, tBz, turnR, y0, y1)
    if ADDubins == nil or ADDubins.new == nil then return nil end
    local ok, result = pcall(function()
        local d = ADDubins:new()
        local q0 = { pax, -paz, math.atan2(-tAz, tAx) }
        local q1 = { pbx, -pbz, math.atan2(-tBz, tBx) }
        -- A FRESH path table: ADDubins.DubinsPath is a shared global template that other callers
        -- (the pathfinder) mutate in place.
        local path = { qi = {}, param = {}, rho = 0, type = 0 }
        if d:dubins_shortest_path(path, q0, q1, turnR) ~= ADDubins.EDUBOK then return nil end
        local len = d:dubins_path_length(path)
        if len == nil or len <= 0 then return nil end
        -- An awkward pose pair can make the shortest Dubins path a huge loop-around; the biarc is
        -- the better answer there. Plausibility: no longer than the direct run plus a few turns.
        local dist = math.sqrt((pbx - pax) ^ 2 + (pbz - paz) ^ 2)
        if len > dist * 2.5 + turnR * 7 then return nil end
        -- Sample step from the SAME sagitta tolerance the biarc uses: the chord whose deviation from
        -- a radius-turnR arc is JUNCTION_SAG - denser on tight radii, never chunky, bounded sane.
        local step = 2 * math.sqrt(math.max(0.01, 2 * turnR * JUNCTION_SAG - JUNCTION_SAG * JUNCTION_SAG))
        step = math.max(0.75, math.min(2.0, step))
        local pts, q, x = {}, {}, step
        while x < len - 0.25 do
            d:dubins_path_sample(path, x, q)
            pts[#pts + 1] = { x = q[1], y = y0 + (y1 - y0) * (x / len), z = -q[2] }
            x = x + step
        end
        return { points = pts, minRadius = turnR, length = len }
    end)
    if not ok then return nil end
    return result
end

-- Lay the connector chain NA -> points -> NB OURSELVES, one deterministic link at a time. This used
-- to be ADGraphManager:createSplineConnection, which wires every link through toggleConnectionBetween
-- - a state FLIP, not a set - so on a graph whose link lists carry any toggle-era corruption
-- (duplicates, one-sided entries) it could remove where it meant to add and double where it meant to
-- single. With this, EVERY link the junction tool creates goes through junctionConnect above, whose
-- result is exactly what its arguments say. Interior points carry `flags` from creation (no
-- after-the-fact re-flag pass over an id range). Returns true when the whole chain laid.
local function junctionLayChain(NA, points, NB, dual, flags)
    local prev = NA
    for _, p in ipairs(points) do
        local wp = ADGraphManager:recordWayPoint(p.x, p.y, p.z, false, false, false, 0,
            flags or AutoDrive.FLAG_NONE, false)
        if wp == nil then return false end
        junctionConnect(prev, wp, dual)
        prev = wp
    end
    junctionConnect(prev, NB, dual)
    return true
end

--- Recompute the junction preview around the cursor: the scope circle, the approaches it cuts, and
--- which entry->exit movements are new versus already connected. Stored on self.junctionPreview; nil
--- when there is nothing to show. Pure inspection - it changes no waypoints.
function ADFlyoverEditor:updateJunctionPreview()
    -- Armed: the site is locked where it was clicked and the preview stops following the cursor (the
    -- wheel and the turn radius still reshape it). Unarmed: it follows the cursor as a live scout.
    local cx, cz, cy
    if self.junctionArmed ~= nil then
        cx, cz, cy = self.junctionArmed.cx, self.junctionArmed.cz, self.junctionArmed.cy
    else
        if self.cursorX == nil then
            self.junctionPreview, self.junctionPreviewKey = nil, nil
            return
        end
        cx, cz, cy = self.cursorX, self.cursorZ, self.cursorY
    end
    local R = self.junctionRadius or 15
    -- NB: a DIFFERENT name from the scope radius R - shadowing it once made the scope circle render
    -- at the turn radius instead of the search radius.
    local turnR = self.junctionTurnRadius or 12
    -- The solve raycasts the road surface for every candidate radius of every turn, so it is only
    -- redone when something it depends on changed: the cursor (to half a metre), a setting, or the
    -- graph. Between those the last preview stands.
    local key = string.format("%d_%d_%d_%d_%s_%s_%s_%s_%d", math.floor(cx * 2), math.floor(cz * 2), R, turnR,
        tostring(self.junctionCheckSurface ~= false), tostring(self.junctionExtendTrim ~= false),
        tostring(self.junctionRebuild == true), tostring(self.junctionUseDubins ~= false)
            .. tostring(self.junctionCheckObstacles ~= false)
            .. string.format("_%d_%d", (self.junctionCorridor or 4) * 10, (self.junctionClearance or 5) * 10),
        ADGraphManager:getWayPointsCount())
    if key == self.junctionPreviewKey and self.junctionPreview ~= nil then
        return
    end
    self.junctionPreviewKey = key
    self.junctionPreview = nil
    local R2 = R * R

    -- Scope: waypoints inside the circle. While gathering, also establish the site's ONE structural
    -- fact about two-way-ness: does ANY link touching the scope run in both directions? If it does
    -- not, this site is one-way in, so it must be one-way out - the placement is HARD-gated on this
    -- (see applyJunction): with no two-way track coming in, nothing the tool lays may ever be two-way.
    local inside = {}
    local siteHasTwoWay = false
    local wps = ADGraphManager:getWayPoints()
    for _, wp in pairs(wps) do
        local dx, dz = wp.x - cx, wp.z - cz
        if dx * dx + dz * dz <= R2 then
            inside[wp.id] = wp
        end
    end
    for _, wp in pairs(inside) do
        for _, tid in pairs(wp.out or {}) do
            local t = ADGraphManager:getWayPointById(tid)
            if t ~= nil and table.contains(t.out or {}, wp.id) then
                siteHasTwoWay = true
                break
            end
        end
        if siteHasTwoWay then break end
    end

    -- Raw approaches: every edge the circle cuts (one end inside, one outside). An edge coming INTO the
    -- scope is an entry, one going OUT is an exit; a two-way lane yields both. Anchored at the inside
    -- boundary node; bearing is the direction of travel (atan2(dx, dz), the convention FS bearings use).
    local raw = {}
    for _, wp in pairs(inside) do
        for _, tid in pairs(wp.out or {}) do
            if inside[tid] == nil then
                local t = ADGraphManager:getWayPointById(tid)
                if t ~= nil then
                    raw[#raw + 1] = { wp = wp, dir = "out", bearing = math.atan2(t.x - wp.x, t.z - wp.z) }
                end
            end
        end
        for _, sid in pairs(wp.incoming or {}) do
            if inside[sid] == nil then
                local s = ADGraphManager:getWayPointById(sid)
                if s ~= nil then
                    raw[#raw + 1] = { wp = wp, dir = "in", bearing = math.atan2(wp.x - s.x, wp.z - s.z) }
                end
            end
        end
    end

    -- Group the raw approaches: same direction, similar bearing, and close together fold into ONE. This
    -- collapses the near-coincident, stacked one-way nodes the survey found (arms 0.4-0.9 m apart) so a
    -- crossing reads as a handful of approaches instead of a web. First step of "approach grouping".
    local approaches = {}
    local nIn, nOut = 0, 0
    for _, ap in ipairs(raw) do
        local into = nil
        for _, g in ipairs(approaches) do
            if g.dir == ap.dir and junctionAngDiff(g.bearing, ap.bearing) < math.rad(35)
                and (g.wp.x - ap.wp.x) ^ 2 + (g.wp.z - ap.wp.z) ^ 2 < 36 then
                into = g
                break
            end
        end
        if into ~= nil then
            into.count = into.count + 1
        else
            approaches[#approaches + 1] = { wp = ap.wp, dir = ap.dir, bearing = ap.bearing, count = 1 }
            if ap.dir == "in" then nIn = nIn + 1 else nOut = nOut + 1 end
        end
    end

    -- "Already connected" = a directed path from the entry's inside node to the exit's inside node,
    -- staying INSIDE the scope - so a road passing straight through is not re-proposed as a turn onto
    -- itself. Bounded to the (small) inside set, so cheap. Also returns THE path (as node ids, from
    -- entry to exit) - the rebuild option needs to know which nodes carry the old connection.
    local function connectedInside(fromId, toId)
        if fromId == toId then return true, { fromId } end
        local parent = { [fromId] = fromId }
        local stack = { fromId }
        while #stack > 0 do
            local id = table.remove(stack)
            local w = inside[id]
            if w ~= nil then
                for _, tid in pairs(w.out or {}) do
                    if tid == toId then
                        local path = { toId }
                        local cur = id
                        while cur ~= fromId do
                            table.insert(path, 1, cur)
                            cur = parent[cur]
                        end
                        table.insert(path, 1, fromId)
                        return true, path
                    end
                    if inside[tid] ~= nil and parent[tid] == nil then
                        parent[tid] = id
                        stack[#stack + 1] = tid
                    end
                end
            end
        end
        return false, nil
    end

    -- The road SKELETON: every node on any approach's own chain - the roads themselves, including
    -- spliced-in tie nodes from earlier placements. The rebuild option deletes an existing turn's old
    -- path nodes, and this set is what protects the roads: only path nodes OFF the skeleton (old
    -- connector interiors) are ever removed. A through-movement's path lies entirely ON the skeleton,
    -- so its "old path" is empty and it is left alone - rebuilding never duplicates a through road.
    local rebuildOn = (self.junctionRebuild == true)
    -- Skeleton = road nodes; roadLink = the LEGITIMATE links between them (consecutive along an
    -- approach chain, unordered). Rebuild needs both: an old connection between two skeleton nodes
    -- with no interior points (a short direct bridge) has no node to sweep - only the roadLink set
    -- can tell that link apart from the road itself.
    local skeleton, roadLink = {}, {}
    local function linkKey(a, b) return math.min(a, b) .. "_" .. math.max(a, b) end
    for _, ap in ipairs(approaches) do
        local ch = self:junctionChain(ap, cx, cz, R)
        for i, n in ipairs(ch) do
            skeleton[n.id] = true
            if i > 1 then roadLink[linkKey(ch[i - 1].id, n.id)] = true end
        end
    end
    -- The debris sweep reaches a third PAST the scope circle (for old arcs that bulge out), so the
    -- roads in that ring need skeleton protection too - without this, every road node just outside
    -- the circle was reachable-from-the-junction, off-skeleton, and got swept: placements were eating
    -- the roads AROUND the junction. Each approach's road is walked OUTWARD from its boundary node
    -- (an entry upstream, an exit downstream, bearing-continuous) out to the sweep's own reach, and
    -- those nodes and links are marked road exactly like the inside ones.
    if rebuildOn then
        local reach2 = (R * 1.3) ^ 2
        for _, ap in ipairs(approaches) do
            local useOut = (ap.dir == "out")
            local wdx, wdz = math.sin(ap.bearing), math.cos(ap.bearing)
            if not useOut then wdx, wdz = -wdx, -wdz end
            local node, cameFrom = ap.wp, nil
            for _ = 1, math.ceil(R) do
                local list = useOut and (node.out or {}) or (node.incoming or {})
                local nextId, bestDot = nil, -math.huge
                for _, nid in pairs(list) do
                    if nid ~= cameFrom then
                        local nx = ADGraphManager:getWayPointById(nid)
                        if nx ~= nil and (nx.x - cx) ^ 2 + (nx.z - cz) ^ 2 <= reach2 then
                            local dx, dz = nx.x - node.x, nx.z - node.z
                            local l = math.sqrt(dx * dx + dz * dz)
                            if l > 1e-6 then
                                local dot = (dx / l) * wdx + (dz / l) * wdz
                                if dot > bestDot then bestDot, nextId = dot, nid end
                            end
                        end
                    end
                end
                if nextId == nil then break end
                local nxt = ADGraphManager:getWayPointById(nextId)
                roadLink[linkKey(node.id, nxt.id)] = true
                cameFrom = node.id
                local dx, dz = nxt.x - node.x, nxt.z - node.z
                local l = math.sqrt(dx * dx + dz * dz)
                if l > 1e-6 then wdx, wdz = dx / l, dz / l end
                node = nxt
                skeleton[node.id] = true
            end
        end
    end

    -- Rebuild's DEBRIS set: every inside node that is wired to the junction (reachable from the road
    -- skeleton along inside links, either direction) but is not itself road. Per-movement old-path
    -- deletion missed plenty - duplicate old connectors, connectors of pairs the current matrix
    -- refuses, anything the single BFS path did not happen to run through. The complement of the
    -- skeleton is the honest definition of "old junction wiring": rebuild clears ALL of it and lays
    -- the fresh set. Roads (and anything crossing the scope circle, which becomes an approach and so
    -- skeleton) are untouchable by construction.
    local debris, staleLinks = {}, {}
    if rebuildOn then
        -- Reach extends a third past the scope circle: a big-radius old connector arc can bulge
        -- outside it, and sweeping only the inside portion left dangling fragments behind.
        local reach2 = (R * 1.3) ^ 2
        local seen, stack, staleSeen = {}, {}, {}
        for id in pairs(skeleton) do seen[id] = true; stack[#stack + 1] = id end
        while #stack > 0 do
            local id = table.remove(stack)
            local w = inside[id] or ADGraphManager:getWayPointById(id)
            if w ~= nil then
                -- Direct skeleton-to-skeleton links that are NOT the road (not chain-consecutive)
                -- are old wiring with no interior node to sweep - collected as links to sever.
                if skeleton[id] then
                    for _, nid in pairs(w.out or {}) do
                        if skeleton[nid] and not roadLink[linkKey(id, nid)]
                            and not staleSeen[linkKey(id, nid)] then
                            staleSeen[linkKey(id, nid)] = true
                            local o = ADGraphManager:getWayPointById(nid)
                            if o ~= nil then staleLinks[#staleLinks + 1] = { w, o } end
                        end
                    end
                end
                for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                    for _, nid in pairs(lst) do
                        if not seen[nid] then
                            local nx = ADGraphManager:getWayPointById(nid)
                            if nx ~= nil and (nx.x - cx) ^ 2 + (nx.z - cz) ^ 2 <= reach2 then
                                seen[nid] = true
                                stack[#stack + 1] = nid
                                if not skeleton[nid] then debris[#debris + 1] = nx end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Movement matrix: each entry -> each exit, dropping U-turns, tagged new vs already connected.
    -- nNew counts only movements that got a BUILDABLE connector - what actually places - so it never
    -- silently disagrees with what right-click lays. Every candidate that drops out gets its own
    -- bucket and, once the site is locked, its own log line with the angle, so nothing goes missing
    -- without a visible reason (see docs/junction-plan.md s5, "failing is a valid result").
    local movements = {}
    local nNew, nExisting, nTight, nOffRoad, nNoCurve, nUTurn, nFar, nRebuild, nBlocked = 0, 0, 0, 0, 0, 0, 0, 0, 0
    local usedMin, usedMax = nil, nil
    -- 150 deg turned out to be too tight on a real site - a legitimate sharp hook (a two-way point's
    -- "in" arm doubling back onto a nearby "out" arm) measured 152 deg and was silently dropped before
    -- this function had per-pair logging at all. 170 deg excludes only near-literal reversals; the
    -- radius/corridor solver is what actually gates drivability (visibly, as "tight"/"off road"), so
    -- this filter only needs to catch geometry that is not a turn at all.
    local uTurn = math.rad(170)
    local logSite = (self.junctionArmed ~= nil)
    for _, e in ipairs(approaches) do
        if e.dir == "in" then
            for _, x in ipairs(approaches) do
                if x.dir == "out" and x.wp.id ~= e.wp.id then
                    local angDiff = junctionAngDiff(e.bearing, x.bearing)
                    if angDiff > uTurn then
                        nUTurn = nUTurn + 1
                        if logSite then
                            roadNote(string.format("uturn:%d_%d", e.wp.id, x.wp.id),
                                "junction - entry id=%d -> exit id=%d skipped as a U-turn (%.0f deg > %.0f deg limit).",
                                e.wp.id, x.wp.id, math.deg(angDiff), math.deg(uTurn))
                        end
                    else
                        local exists, path = connectedInside(e.wp.id, x.wp.id)
                        -- Rebuild option: an existing connection whose path runs through nodes OFF
                        -- the road skeleton is an old connector. With rebuild on, that movement is
                        -- re-solved like a new one and its old off-skeleton nodes are queued for
                        -- deletion at place time. A path entirely ON the skeleton is the road itself
                        -- (a through) - nothing to rebuild, left alone.
                        local rebuild, oldPath = false, nil
                        if exists and rebuildOn and path ~= nil then
                            oldPath = {}
                            for _, pid in ipairs(path) do
                                if not skeleton[pid] and inside[pid] ~= nil then
                                    oldPath[#oldPath + 1] = inside[pid]
                                end
                            end
                            rebuild = #oldPath > 0
                        end
                        -- Solve the turn at the largest radius (setting first, stepping down) that both
                        -- holds the radius bound and keeps the vehicle corridor on the road. A turn that
                        -- fails even at the floor is kept with its refusal reason, drawn red, never laid.
                        local con, usedR, refused = nil, nil, nil
                        if not exists or rebuild then
                            con, usedR, refused = self:junctionSolveMovement(e, x, cx, cz, R, turnR)
                        end
                        movements[#movements + 1] = { from = e, to = x, exists = exists, connector = con,
                            usedRadius = usedR, refused = refused, rebuild = rebuild, oldPath = oldPath }
                        if rebuild and con ~= nil and refused == nil then
                            nRebuild = nRebuild + 1
                        elseif exists then
                            nExisting = nExisting + 1
                        elseif con ~= nil and refused == nil then
                            nNew = nNew + 1
                        elseif refused == "tight" then
                            nTight = nTight + 1
                        elseif refused == "offroad" then
                            nOffRoad = nOffRoad + 1
                        elseif refused == "blocked" then
                            nBlocked = nBlocked + 1
                            if logSite then
                                roadNote(string.format("blocked:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d blocked by a static obstacle at every radius down to the floor - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "far" then
                            nFar = nFar + 1
                            if logSite then
                                roadNote(string.format("far:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d never come close to each other (likely two separate crossings in one scope) - skipped.",
                                    e.wp.id, x.wp.id)
                            end
                        else
                            nNoCurve = nNoCurve + 1
                            if logSite then
                                roadNote(string.format("nocurve:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d has no joinable curve (near-collinear offset tangents).",
                                    e.wp.id, x.wp.id)
                            end
                        end
                        if con ~= nil and refused == nil and usedR ~= nil then
                            usedMin = math.min(usedMin or usedR, usedR)
                            usedMax = math.max(usedMax or usedR, usedR)
                        end
                    end
                end
            end
        end
    end
    if logSite then
        for _, ap in ipairs(approaches) do
            -- Keyed by id AND direction: a two-way point contributes an "in" AND an "out" approach
            -- under the SAME waypoint id, and a key by id alone hid whichever one logged second.
            roadNote(string.format("approach:%d:%s", ap.wp.id, ap.dir), "junction - approach id=%d %s, bearing %.0f deg.",
                ap.wp.id, ap.dir, math.deg(ap.bearing))
        end
    end

    -- Redundant-lane pass: two movements with a similar entry bearing AND a similar exit bearing are
    -- the SAME turn attempted from different lanes of the same two roads - a multi-lane road has
    -- several parallel "in" approaches and several parallel "out" ones, and the raw matrix pairs every
    -- lane with every lane, including an inner lane crossing to a far outer lane on the OTHER side of
    -- the intersection. Distance to the scope centre cannot tell those apart (the wrong pairing can sit
    -- just as close as the right one when the lanes themselves are only a few metres apart) - but the
    -- tracks' own closest-approach distance (meetDist, already computed while solving the connector)
    -- can: the CORRECT lane pairing is the one whose tracks actually come closest together. Within each
    -- bearing-matched cluster, keep only that one and refuse the rest as "lane" - visibly, not silently.
    local nLane = 0
    for i = 1, #movements do
        local mi = movements[i]
        if mi.connector ~= nil and mi.refused == nil and not mi.exists then
            for j = i + 1, #movements do
                local mj = movements[j]
                if mj.connector ~= nil and mj.refused == nil and not mj.exists
                    and junctionAngDiff(mi.from.bearing, mj.from.bearing) < math.rad(20)
                    and junctionAngDiff(mi.to.bearing, mj.to.bearing) < math.rad(20) then
                    local loser = (mi.connector.meetDist <= mj.connector.meetDist) and mj or mi
                    loser.refused = "lane"
                    nNew = nNew - 1
                    nLane = nLane + 1
                    if logSite then
                        roadNote(string.format("lane:%d_%d", loser.from.wp.id, loser.to.wp.id),
                            "junction - entry id=%d -> exit id=%d is a redundant lane pairing (a closer match exists for this turn) - skipped.",
                            loser.from.wp.id, loser.to.wp.id)
                    end
                end
            end
        end
    end

    -- Rough confidence (refined later): a clean crossing has a small, balanced set of approaches.
    local conf = 0
    if #approaches >= 2 then
        local balance = 1 - math.abs(nIn - nOut) / math.max(1, nIn + nOut)
        local tidy = (#approaches <= 8) and 1 or (8 / #approaches)
        conf = math.max(0, math.min(1, 0.5 * balance + 0.5 * tidy))
    end

    self.junctionPreview = {
        radius = R, turnRadius = turnR, cx = cx, cz = cz, cy = cy, armed = (self.junctionArmed ~= nil),
        approaches = approaches, movements = movements,
        nIn = nIn, nOut = nOut, nNew = nNew, nExisting = nExisting, nTight = nTight, nOffRoad = nOffRoad,
        nNoCurve = nNoCurve, nUTurn = nUTurn, nFar = nFar, nLane = nLane, nRebuild = nRebuild, nBlocked = nBlocked,
        debris = debris, staleLinks = staleLinks, siteHasTwoWay = siteHasTwoWay,
        usedMin = usedMin, usedMax = usedMax, confidence = conf,
    }
end

--- Build one movement's connector from the REAL track geometry (entry approach -> exit approach).
--- Two earlier versions each got half of it: a straight-line fillet respected the turn radius but put
--- its tangent points on straight extensions of the tracks (off a curved road, or floating in the gap
--- where a stem dead-ends short of the crossbar); an on-track Hermite stayed on the road but had no
--- radius control. This does both:
---   1. meeting region = the closest node pair between the two chains; the two LOCAL travel directions
---      there give the turn angle delta and the ideal corner V (where the local tangent lines cross);
---   2. the tie-in distance is the fillet's t = turnR*tan(delta/2), measured from the CORNER - so a stem
---      that stops short of the crossbar is not over-trimmed, and one that overshoots is trimmed back;
---   3. each tie-in is placed by walking that distance along the REAL chain (guaranteed on the road,
---      with the road's true local tangent), and the two are joined by a biarc - tangent-continuous at
---      both ends by construction. For a clean crossing the biarc IS the radius-turnR fillet arc; on a
---      curved or gapped site it flexes to stay on the road, and reports its smallest radius so a turn
---      tighter than the setting can be flagged instead of laid.
--- Returns { ax,ay,az, bx,by,bz, points, minRadius } or (nil, reason) when the tracks genuinely cannot
--- be joined into ONE turn. `reason` is "far" for the plausibility gate below, or nil for every other
--- failure (degenerate/opposed tangents; not a shallow angle - see the note on `delta`). Used by BOTH
--- preview and placement, so what is drawn is what is laid.
function ADFlyoverEditor:junctionTrackConnector(fromAp, toAp, cx, cz, radius, turnR)
    local chainA, deadEndA = self:junctionChain(fromAp, cx, cz, radius)
    local chainB, deadEndB = self:junctionChain(toAp, cx, cz, radius)
    if #chainA < 2 or #chainB < 2 then return nil end

    -- Meeting region: the closest node between the two chains (dense ~4 m nodes make node-to-node a good
    -- proxy for the true closest approach).
    local iA, iB, bestd = 1, 1, math.huge
    for a = 1, #chainA do
        for b = 1, #chainB do
            local d = (chainA[a].x - chainB[b].x) ^ 2 + (chainA[a].z - chainB[b].z) ^ 2
            if d < bestd then bestd, iA, iB = d, a, b end
        end
    end

    -- Local travel directions at the meeting: A toward the interior (lower->higher index), B out toward
    -- its boundary (the negated chain direction).
    local uAx, uAz = junctionSegDir(chainA, iA)
    local sbx, sbz = junctionSegDir(chainB, iB)
    local uBx, uBz = -sbx, -sbz
    local pA, pB = chainA[iA], chainB[iB]
    -- NO angle floor here: this network's own survey put the MEDIAN junction angle at 10 deg, and a
    -- shallow merge below that is a completely ordinary new connection to make, not a degenerate one.
    -- An earlier version dropped anything under 5 deg as "nothing to turn" - which silently ate real
    -- shallow merges (they were not counted as tight/off-road either, so nothing said why they were
    -- missing). The biarc below already reduces to a straight join in the limit as delta -> 0 (its
    -- parallel-tangent branch), so there is nothing to gate: let it solve.
    local delta = math.acos(math.max(-1, math.min(1, uAx * uBx + uAz * uBz)))
    local t = turnR * math.tan(delta / 2)

    -- The corner V where the two local tangent lines cross is used to measure how far each meeting
    -- node sits from it, signed along travel: sA = corner is this far ahead of A's node (a stem
    -- trimmed back short of the crossbar has a large positive sA), sB = B's node is this far past the
    -- corner. Also computed here, and used for the plausibility gate right below.
    local sA, sB = 0, 0
    local det = uBx * uAz - uAx * uBz
    if math.abs(det) > 1e-6 then
        local s = (uBx * (pB.z - pA.z) - uBz * (pB.x - pA.x)) / det
        local Vx, Vz = pA.x + s * uAx, pA.z + s * uAz
        sA = (Vx - pA.x) * uAx + (Vz - pA.z) * uAz
        sB = (pB.x - Vx) * uBx + (pB.z - Vz) * uBz
    end

    -- Plausibility gate: if the two tracks are not the same crossing, do not connect them - a wide
    -- scope catching two separate nearby junctions was pairing every entry with every exit regardless
    -- of distance, drawing connectors straight through the middle of the whole site instead of
    -- hugging one corner.
    --
    -- "Far apart" is NOT the same test as "far from the closest existing node": a stem trimmed back
    -- short of the true crossing (walkBack now extrapolates past it to reach the tie-in) makes the
    -- raw node-to-node distance look exactly like an unrelated, genuinely distant crossing would -
    -- both are "far" by that measure, but only one is real. What tells them apart is the CORNER: two
    -- tracks converging on one nearby point (sA, sB both small - or negative, meaning the stem already
    -- reaches past it) are the same crossing, however short they were trimmed; two tracks that would
    -- only meet an implausible distance away (or a projected corner outside the scope circle
    -- entirely) are not, however close their nearest surviving nodes happen to sit. That is checked
    -- when the corner is well-defined (the tangents actually cross); parallel/near-parallel tangents
    -- have no such corner, so those fall back to the original closest-node test - tracks that never
    -- converge at all should not be connected regardless of trimming.
    -- `junctionExtendTrim` (card toggle "trim/extend", default true) governs both this gate and the
    -- walk below: off, a trimmed stem is never projected past where it actually ends, so the corner
    -- test would be meaningless (the tie-in cannot reach the corner anyway) - fall back to the
    -- original closest-node test in that case too.
    local extend = self.junctionExtendTrim ~= false
    if not extend then
        local meetCap = math.max(radius * 0.5, turnR * 3, 15)
        if bestd > meetCap * meetCap then return nil, "far" end
    elseif math.abs(det) > 1e-6 then
        local farCap = math.max(radius, turnR * 6, 20)
        if sA > farCap or sB > farCap then return nil, "far" end
    else
        -- Parallel/near-parallel tangents (delta ~ 0) - the MOST common case, a straight-through
        -- continuation, and the corner test above does not apply (there is no corner). Colinearity
        -- IS the meeting signal here: two tracks lined up end to end are obviously the same road,
        -- however far apart their trimmed ends sit - and that gap is already bounded by both ends
        -- being inside the scope circle, so no extra distance cap is needed. What DOES matter is
        -- whether they are actually on the same line: gate on the perpendicular offset from B to A's
        -- line instead of the raw point distance - small offset is the same road; a real one is a
        -- genuinely different, merely parallel one (an adjacent lane a few lanes over, say).
        local perpDist = math.abs((pB.x - pA.x) * uAz - (pB.z - pA.z) * uAx)
        local perpCap = math.max(turnR, 6)
        if perpDist > perpCap then return nil, "far" end
    end

    -- Tie-ins: t back from the corner, walked along the real chains (a non-positive walk stays at the
    -- meeting node - e.g. a dead-end whose gap to the crossbar already exceeds t).
    -- Extension past the chain's end is only meaningful when the chain ends at a REAL dead end (a
    -- trimmed stem). A chain that merely ran out at the scope circle is a road that keeps going -
    -- projecting a tie-in past that boundary plants a spike node beside the real road (seen with a
    -- turn radius comparable to the scope radius). There the walk clamps at the boundary instead.
    local pax, pay, paz, tadx, tadz = junctionWalkBack(chainA, iA, t - sA, extend and deadEndA)
    local pbx, pby, pbz, tbdx, tbdz = junctionWalkBack(chainB, iB, t - sB, extend and deadEndB)
    -- A leaves along its chain direction (toward the interior); B is arrived at heading out (negated).
    -- BOTH curve engines solve and the SHORTER path wins. This is not indecision - it is the guard
    -- against Dubins' degenerate configuration: two poses on the SAME tangent circle, which is
    -- exactly where fillet tie-ins sit on a clean crossing, make ADDubins parameterize the quarter
    -- turn as a 450-degree loop (measured: 94 m where 19 m is right, on the same circle). The biarc
    -- IS the optimal answer there and wins on length automatically; where Dubins genuinely helps
    -- (offset poses, S-bends, hooks) it is shorter and wins instead. No tuned threshold to go stale.
    local function pathLen(c)
        if c == nil then return math.huge end
        local len, px, pz = 0, pax, paz
        for _, p in ipairs(c.points) do
            len = len + math.sqrt((p.x - px) ^ 2 + (p.z - pz) ^ 2)
            px, pz = p.x, p.z
        end
        return len + math.sqrt((pbx - px) ^ 2 + (pbz - pz) ^ 2)
    end
    local bia = junctionBiarc(pax, paz, tadx, tadz, pbx, pbz, -tbdx, -tbdz, pay, pby)
    local dub = nil
    if self.junctionUseDubins ~= false then
        dub = junctionDubins(pax, paz, tadx, tadz, pbx, pbz, -tbdx, -tbdz, turnR, pay, pby)
    end
    local bi = bia
    if dub ~= nil and pathLen(dub) < pathLen(bia) - 0.1 then bi = dub end
    if bi == nil then return nil end
    return { ax = pax, ay = pay, az = paz, bx = pbx, by = pby, bz = pbz,
        points = bi.points, minRadius = bi.minRadius, t = t, meetDist = math.sqrt(bestd) }
end

--- How many of a connector's corridor samples leave the road surface, and how many were taken. Every
--- curve point is probed at its centre and half a corridor width to each side of the local heading
--- (tractor width plus a trailer allowance - see FLYOVER_JUNCTION_CORRIDOR). The two tie-ins are
--- probed at the centre only: they sit on the existing track, whose edge situation is not this turn's
--- doing.
function ADFlyoverEditor:junctionCorridorOffRoad(con)
    local half = (self.junctionCorridor or AutoDrive.FLYOVER_JUNCTION_CORRIDOR or 4.0) / 2
    local pts = { { x = con.ax, z = con.az } }
    for _, p in ipairs(con.points) do pts[#pts + 1] = p end
    pts[#pts + 1] = { x = con.bx, z = con.bz }
    local off, total = 0, 0
    for i = 1, #pts do
        local p = pts[i]
        total = total + 1
        if not isRoadAt(p.x, p.z) then off = off + 1 end
        if i > 1 and i < #pts then
            local a, b = pts[i - 1], pts[i + 1]
            local dx, dz = b.x - a.x, b.z - a.z
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 1e-6 then
                local nx, nz = -dz / l, dx / l
                total = total + 2
                if not isRoadAt(p.x + nx * half, p.z + nz * half) then off = off + 1 end
                if not isRoadAt(p.x - nx * half, p.z - nz * half) then off = off + 1 end
            end
        end
    end
    return off, total
end

--- Solve one turn at the largest radius that both holds the radius bound and keeps the corridor on
--- the road: the setting first, then stepping down 1 m at a time to the turn-radius floor. Inside
--- turns at a sharp corner therefore come out tighter than outside ones, as real intersections are
--- laid out, without the global setting being tuned per site. Returns connector, radius used, nil on
--- success; on failure the last connector tried, the floor, and a reason ("tight" / "offroad" /
--- "nocurve" / "far") so the preview can still show what was refused and why.
-- Obstacle probe for junction connectors, using the SAME physics query AutoDrive's own pathfinder
-- uses for its cells (overlapBox returning a synchronous shape count; see PathFinderModule ~1221).
-- The mask is STATIC things a laid route must never pass through - trees, buildings, static objects
-- (fences, poles, signs are static objects or buildings) - and deliberately NOT vehicles/traffic:
-- something driving past while you place is not a reason to refuse a road. The box floats 0.6 m off
-- the terrain (pathfinder ignores the lowest 0.5 m the same way) so curbs and ground clutter do not
-- count, and reaches ~2.8 m up - trailer height.
local junctionObstacleMask = nil
local JunctionOverlapProbe = { cb = function() end }

--- Number of corridor boxes along `con` that overlap a static obstacle. Boxes are laid segment by
--- segment along the curve (half corridor width wide, segment-long), rotated to the local heading.
function ADFlyoverEditor:junctionObstacleHits(con)
    if overlapBox == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return 0
    end
    if junctionObstacleMask == nil then
        junctionObstacleMask = CollisionFlag.STATIC_OBJECT + CollisionFlag.TREE + CollisionFlag.BUILDING
    end
    local halfW = (self.junctionClearance or AutoDrive.FLYOVER_JUNCTION_CLEARANCE or 5.0) / 2
    local pts = { { x = con.ax, z = con.az } }
    for _, p in ipairs(con.points) do pts[#pts + 1] = p end
    pts[#pts + 1] = { x = con.bx, z = con.bz }
    local hits = 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 1e-3 then
            local mx, mz = (a.x + b.x) * 0.5, (a.z + b.z) * 0.5
            local gy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, mx, 1, mz) or 0
            local ry = math.atan2(dx, dz)
            local ok, shapes = pcall(overlapBox, mx, gy + 0.6 + 1.1, mz, 0, ry, 0,
                halfW, 1.1, l * 0.5, "cb", JunctionOverlapProbe, junctionObstacleMask, true, true, true, true)
            -- Proof-of-life notes, once each: a probe that errors would otherwise be a silent no-op
            -- behind this pcall, indistinguishable from "no obstacles anywhere".
            if not ok then
                roadNote("obsProbeErr", "obstacle probe FAILED: %s - obstacle check is inactive.", tostring(shapes))
            elseif type(shapes) ~= "number" then
                roadNote("obsProbeOdd", "obstacle probe returned %s (expected a count) - obstacle check is inactive.", type(shapes))
            else
                roadNote("obsProbeOk", "obstacle probe active (mask %d).", junctionObstacleMask)
                if shapes > 0 then
                    hits = hits + 1
                    roadNote("obsFirstHit", "obstacle probe FIRST HIT at %.1f, %.1f (%d shape(s)).", mx, mz, shapes)
                end
            end
        end
    end
    return hits
end

--- Is this connector's corridor off the road ENOUGH to refuse it? A single stray sample - one edge
--- probe clipping a narrow paved apron at a dirt/pavement seam, or a texture-boundary sliver - should
--- not kill an otherwise good turn; a corridor that is mostly off-road should. Tolerates up to 1 sample
--- or 15% of the samples taken, whichever is larger.
function ADFlyoverEditor:junctionCorridorTooOffRoad(con)
    local off, total = self:junctionCorridorOffRoad(con)
    local tolerance = math.max(1, math.ceil(total * 0.15))
    return off > tolerance
end

--- `junctionCheckSurface` (card toggle, default true) skips the road-surface raycast entirely - the
--- turn is still radius-bound but never refused/shrunk for leaving the road. For a map whose surface
--- reads wrong (see isRoadAt's logged classifications), or just to place fast on a site you already
--- know is clear, without waiting on a raycast per candidate radius per curve point.
function ADFlyoverEditor:junctionSolveMovement(fromAp, toAp, cx, cz, radius, turnR)
    local floor = AutoDrive.FLYOVER_JUNCTION_TURN_MIN or 4
    local checkSurface = self.junctionCheckSurface ~= false
    local checkObstacles = self.junctionCheckObstacles ~= false
    local last, lastReason = nil, nil
    local r = turnR
    while r >= floor - 1e-6 do
        local con, whyNil = self:junctionTrackConnector(fromAp, toAp, cx, cz, radius, r)
        if con == nil then
            -- "far" does not depend on the turn radius candidate - stepping r down cannot bring two
            -- tracks closer together, so stop instead of retrying it at every floor step.
            if whyNil == "far" then return nil, r, "far" end
            if last == nil then return nil, r, "nocurve" end
            return last, r + 1, lastReason
        end
        if con.minRadius < r * 0.7 then
            last, lastReason = con, "tight"
        elseif checkSurface and self:junctionCorridorTooOffRoad(con) then
            last, lastReason = con, "offroad"
        elseif checkObstacles and self:junctionObstacleHits(con) > 0 then
            -- A static obstacle in the corridor: a smaller radius swings a different line, so the
            -- same shrink search doubles as first-order avoidance; nothing clear down to the floor
            -- is a verbose red refusal, never a connector through a tree.
            last, lastReason = con, "blocked"
        else
            return con, r, nil
        end
        r = r - 1
    end
    return last, floor, lastReason
end

--- Place every NEW turn in the current preview: for each, lay OUR connector points between the entry
--- and exit lane nodes via junctionLayChain (deterministic links only; priority inherited from the
--- joined road), all under one undo snapshot. Existing turns and U-turns were already filtered out of
--- the matrix; radius/corridor refusals happened in the solve.
--- The lane chain from an approach's boundary node toward the intersection interior (out-edges for an
--- entry, incoming for an exit), boundary node first, staying within the scope. Also whether that lane
--- DEAD-ENDS inside the scope (no travel continuation) rather than passing through.
function ADFlyoverEditor:junctionChain(ap, cx, cz, radius)
    local useOut = (ap.dir == "in")
    local r2 = radius * radius
    local chain = { ap.wp }
    local node, cameFrom = ap.wp, nil
    -- The walk follows BEARING CONTINUITY: at a fork (a tie node whose neighbours include both the
    -- road's continuation and an old connector's first point), it takes whichever neighbour bends
    -- LEAST from the current walking direction - the road runs on, a connector departs at an angle.
    -- Taking the first listed neighbour instead could veer the "road chain" down a connector, which
    -- poisons everything downstream (meeting point, tangents, tie-ins). Initial direction: an entry
    -- is walked downstream (its travel bearing); an exit chain is walked UPSTREAM, so opposite.
    local wdx, wdz = math.sin(ap.bearing), math.cos(ap.bearing)
    if not useOut then wdx, wdz = -wdx, -wdz end
    -- Iteration bound scales with the scope: 16 was fine for small circles but left the MIDDLE of a
    -- long road unwalked at larger ones - unprotected by the skeleton, i.e. swept as debris.
    for _ = 1, math.max(16, math.ceil(radius)) do
        local list = useOut and (node.out or {}) or (node.incoming or {})
        local nextId, bestDot = nil, -math.huge
        for _, nid in pairs(list) do
            if nid ~= cameFrom then
                local nx = ADGraphManager:getWayPointById(nid)
                if nx ~= nil and (nx.x - cx) ^ 2 + (nx.z - cz) ^ 2 <= r2 then
                    local dx, dz = nx.x - node.x, nx.z - node.z
                    local l = math.sqrt(dx * dx + dz * dz)
                    if l > 1e-6 then
                        local dot = (dx / l) * wdx + (dz / l) * wdz
                        if dot > bestDot then bestDot, nextId = dot, nid end
                    end
                end
            end
        end
        if nextId == nil then break end
        cameFrom = node.id
        local nxt = ADGraphManager:getWayPointById(nextId)
        local dx, dz = nxt.x - node.x, nxt.z - node.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 1e-6 then wdx, wdz = dx / l, dz / l end
        node = nxt
        chain[#chain + 1] = node
    end
    local last = chain[#chain]
    local travelList = useOut and (last.out or {}) or (last.incoming or {})
    local continues = false
    for _, nid in pairs(travelList) do
        if nid ~= cameFrom then continues = true; break end
    end
    return chain, (not continues)
end

--- Create the tie-in node at the tangent point (Tx,Tz) on an approach's track and splice it in. A
--- through-road keeps both sides (insert). A dead-end keeps only the outer side and returns the stub
--- past the tie-in for the caller to consume (deleted LAST, since removeWayPoint renumbers ids). The
--- new node inherits the track's priority flags. Returns the node, its priority flags, the stub, and
--- whether the LOCAL track at the tie-in is itself two-way - the caller uses this (both ends must
--- agree) to decide whether the new connector should be dual too, instead of always one-way.
function ADFlyoverEditor:junctionTieIn(ap, Tx, Tz, cx, cz, radius)
    local chain, deadEnd = self:junctionChain(ap, cx, cz, radius)
    if #chain < 2 then
        -- Only the boundary node here; tie at it. Its own edge (to whatever it still connects to)
        -- tells us if this stub of track is two-way.
        local wp = ap.wp
        local nbrId = (ap.dir == "in") and (wp.incoming or {})[1] or (wp.out or {})[1]
        local dual = false
        if nbrId ~= nil then
            local nbr = ADGraphManager:getWayPointById(nbrId)
            if nbr ~= nil then
                -- Explicit if/else, not `cond and A or B`: that idiom falls through to B whenever A
                -- is false, and A false is the NORMAL one-way case (see segDual below).
                if ap.dir == "in" then
                    dual = table.contains(wp.out or {}, nbrId)
                else
                    dual = table.contains(nbr.out or {}, wp.id)
                end
            end
        end
        return wp, (wp.flags or AutoDrive.FLAG_NONE), {}, dual
    end
    local bestSeg, bestFrac, bestd = 1, 0, math.huge
    for i = 1, #chain - 1 do
        local a, b = chain[i], chain[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local len2 = dx * dx + dz * dz
        local f = (len2 > 1e-6) and math.max(0, math.min(1, ((Tx - a.x) * dx + (Tz - a.z) * dz) / len2)) or 0
        local px, pz = a.x + f * dx, a.z + f * dz
        local d = (px - Tx) ^ 2 + (pz - Tz) ^ 2
        if d < bestd then bestd, bestSeg, bestFrac = d, i, f end
    end
    local outer, inner = chain[bestSeg], chain[bestSeg + 1]
    local trackFlags = outer.flags or AutoDrive.FLAG_NONE
    -- Whether the immediate outer<->inner segment is two-way: does the link OPPOSITE the travel
    -- direction exist too? An explicit if/else, NOT `cond and A or B` - that idiom evaluates B
    -- whenever A is false, and here A false IS the normal one-way case, so it fell through to
    -- testing the forward link that always exists. Result: segDual was TRUE for every entry-side
    -- splice on every one-way road, and every entry tie node got spliced in two-way - the "blue"
    -- links the invariant tripwire kept catching.
    local segDual
    if ap.dir == "in" then
        segDual = table.contains(inner.out or {}, outer.id)   -- forward is outer->inner
    else
        segDual = table.contains(outer.out or {}, inner.id)   -- forward is inner->outer
    end

    -- If the tie-in lands ON an existing lane node (within 0.35 m), reuse that node rather than stacking
    -- a new one on top of it - the survey showed near-coincident points already clutter real junctions.
    -- A dead-end then consumes only what lies PAST the reused node (deleting those also drops its
    -- inward edge, so it becomes the new terminus with nothing extra to do).
    local hitIdx = (bestFrac < 0.5) and bestSeg or (bestSeg + 1)
    local hit = chain[hitIdx]
    if (hit.x - Tx) ^ 2 + (hit.z - Tz) ^ 2 < 0.35 ^ 2 then
        local stubs = {}
        if deadEnd then
            for i = hitIdx + 1, #chain do
                local w = chain[i]
                if #(w.out or {}) + #(w.incoming or {}) > 2 then break end
                stubs[#stubs + 1] = w
            end
        end
        return hit, (hit.flags or AutoDrive.FLAG_NONE), stubs, segDual
    end

    -- Decide the stub to consume BEFORE mutating (so degree checks see the original graph). Stop at
    -- anything that is not a plain lane node (degree > 2 = a junction / shared point), so we never
    -- eat into the rest of the network.
    local stubs = {}
    if deadEnd then
        for i = bestSeg + 1, #chain do
            local w = chain[i]
            if #(w.out or {}) + #(w.incoming or {}) > 2 then break end
            stubs[#stubs + 1] = w
        end
    end

    local ny = (outer.y or 0) + ((inner.y or 0) - (outer.y or 0)) * bestFrac
    local N = ADGraphManager:recordWayPoint(Tx, ny, Tz, false, false, false, 0, trackFlags, false)
    if N == nil then return ap.wp, trackFlags, {}, segDual end

    if ap.dir == "in" then
        junctionDisconnect(outer, inner)
        junctionConnect(outer, N, segDual)
        if not deadEnd then junctionConnect(N, inner, segDual) end
    else
        junctionDisconnect(inner, outer)
        junctionConnect(N, outer, segDual)
        if not deadEnd then junctionConnect(inner, N, segDual) end
    end
    return N, trackFlags, stubs, segDual
end

--- Left-click: lock the junction site at the cursor (arm), or move the lock if one is set. From here
--- the preview stays put while the wheel / turn radius reshape it, right-click places it, and a
--- right-click with nothing to place unlocks. Mirrors the pick-then-apply flow of the span tools, so
--- there is always a way out of the tool without laying anything.
function ADFlyoverEditor:junctionClick()
    if self.cursorX == nil then return end
    self.junctionArmed = { cx = self.cursorX, cz = self.cursorZ, cy = self.cursorY }
    self.junctionPreviewKey = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction site locked at %.1f, %.1f - wheel = scope, right-click places.",
        self.cursorX, self.cursorZ)
end

--- Place every NEW turn in the preview (behaviour A): tie in at each track's tangent point (insert on a
--- through-road, trim a dead-end back to it), lay the radius-R arc one-way from entry to exit, priority
--- matched to the joined (exit) road, all under one undo. Dead-end stubs are consumed at the very end.
function ADFlyoverEditor:applyJunction()
    local jp = self.junctionPreview
    if jp == nil then return end
    local newMoves = {}
    for _, m in ipairs(jp.movements) do
        if (not m.exists or m.rebuild) and m.connector ~= nil and m.refused == nil then
            newMoves[#newMoves + 1] = m
        end
    end
    -- Refusing a turn is a valid, verbose outcome (see docs/junction-plan.md s5): better unbuilt than
    -- undrivable. Loosen the turn radius, or widen the scope so a gentler tie-in is found, to force it.
    -- Every count below comes straight from the preview that was just looked at (armed, so it already
    -- logged the per-pair detail) - not recomputed here, so this summary can never disagree with it.
    if (jp.nTight or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - refused %d turn(s): tighter than the %.0f m turn radius even at the %.0f m floor.",
            jp.nTight, jp.turnRadius or 0, AutoDrive.FLYOVER_JUNCTION_TURN_MIN or 4)
    end
    if (jp.nOffRoad or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - refused %d turn(s): no radius down to %.0f m keeps a %.1f m corridor on the road.",
            jp.nOffRoad, AutoDrive.FLYOVER_JUNCTION_TURN_MIN or 4,
            self.junctionCorridor or AutoDrive.FLYOVER_JUNCTION_CORRIDOR or 4)
    end
    if (jp.nNoCurve or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d pair(s) had no joinable curve (see the id lines above) - not placed.",
            jp.nNoCurve)
    end
    if (jp.nUTurn or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d pair(s) skipped as U-turns (bearings over 170 deg apart, see above).",
            jp.nUTurn)
    end
    if (jp.nFar or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d pair(s) never came close to each other - likely two separate crossings caught by one scope; not placed.",
            jp.nFar)
    end
    if (jp.nLane or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d redundant lane pairing(s) skipped (a closer match exists for the same turn, see above).",
            jp.nLane)
    end
    if (jp.nBlocked or 0) > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - refused %d turn(s): a static obstacle sits in the corridor at every radius tried.",
            jp.nBlocked)
    end
    if #newMoves == 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - nothing new to connect here.")
        return
    end

    ADEditorHistory:snapshot("junction")
    local cx, cz, radius = jp.cx, jp.cz, jp.radius
    local allStubs = {}
    local placed = 0

    -- Rebuild: sever the stale skeleton-to-skeleton links FIRST (old direct bridges with no interior
    -- node - the node sweep cannot touch those). Before laying, so a fresh replacement over the same
    -- pair cannot be cut by its own cleanup, and the tie-in chain walks see a clean graph.
    local staleCut = 0
    if jp.staleLinks ~= nil then
        for _, pair in ipairs(jp.staleLinks) do
            local a, b = pair[1], pair[2]
            if a ~= nil and b ~= nil and a.id ~= nil and b.id ~= nil and a.id >= 0 and b.id >= 0 then
                junctionDisconnect(a, b)
                staleCut = staleCut + 1
            end
        end
    end
    if staleCut > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - severed %d stale direct link(s) between road nodes (rebuild).", staleCut)
    end
    -- A movement (e,x) and its MIRROR (e2,x2) with e2.wp.id==x.wp.id and x2.wp.id==e.wp.id can only
    -- both exist when BOTH boundary nodes carry traffic in and out of the scope - a genuine two-way
    -- point on each end (see the U-turn log's approach dump: a two-way node shows up as both an "in"
    -- AND an "out" approach under the same id). That is exactly the ONLY case where a connector should
    -- be dual - both directions were actually asked for. An earlier version instead asked each tie-in
    -- "is the LOCAL track here two-way", which is the wrong question (it can be true on both ends of a
    -- perfectly ordinary one-way turn, e.g. two different two-way roads meeting, with no request for
    -- the turn itself to run both ways) and coloured connectors dual for no real reason. Confirming
    -- the mirror ACTUALLY exists in this batch is the one signal that is never a false positive.
    local function pairKey(a, b)
        local lo, hi = math.min(a, b), math.max(a, b)
        return lo .. "_" .. hi
    end
    local mirrorOf = {}
    for _, m in ipairs(newMoves) do
        mirrorOf[pairKey(m.from.wp.id, m.to.wp.id)] = (mirrorOf[pairKey(m.from.wp.id, m.to.wp.id)] or 0) + 1
    end
    local dualPairPlaced = {}
    local dualPlaced, mirrorsSkipped, rebuiltPlaced = 0, 0, 0
    -- THE invariant (hard gate, not a heuristic): if no two-way track comes into this site
    -- (jp.siteHasTwoWay, established structurally while scoping), then NOTHING placed here may be
    -- two-way. The mirror-pair signal cannot fire without two-way boundary nodes anyway, but this
    -- gate makes the guarantee independent of that reasoning ever being wrong.
    local allowDual = (jp.siteHasTwoWay == true)
    local baseCount = ADGraphManager:getWayPointsCount()
    for _, m in ipairs(newMoves) do
        local key = pairKey(m.from.wp.id, m.to.wp.id)
        if dualPairPlaced[key] then
            mirrorsSkipped = mirrorsSkipped + 1
        else
        local c = m.connector
        local NA, _flagsA, stubsA = self:junctionTieIn(m.from, c.ax, c.az, cx, cz, radius)
        local NB, exitFlags, stubsB = self:junctionTieIn(m.to, c.bx, c.bz, cx, cz, radius)
        if NA ~= nil and NB ~= nil and NA.id ~= NB.id then
            local dual = allowDual and (mirrorOf[key] or 0) > 1
            -- Our own deterministic chain-layer - NOT createSplineConnection, whose links go through
            -- toggleConnectionBetween (a flip, not a set). Flags match the joined (exit) road and are
            -- set at creation.
            local ok, laid = tryCall("junction lay chain", function()
                return junctionLayChain(NA, c.points, NB, dual, exitFlags)
            end)
            ok = ok and laid == true
            if ok and dual then
                dualPlaced = dualPlaced + 1
                dualPairPlaced[key] = true
            end
            if ok then
                placed = placed + 1
                if m.rebuild then rebuiltPlaced = rebuiltPlaced + 1 end
            end
            for _, s in ipairs(stubsA) do allStubs[#allStubs + 1] = s end
            for _, s in ipairs(stubsB) do allStubs[#allStubs + 1] = s end
        end
        end
    end

    -- Tripwire for THE invariant, run BEFORE stub deletion renumbers ids: on a one-way site, no node
    -- this placement created may carry a two-way link. With deterministic primitives and the
    -- allowDual gate this cannot happen by construction - so if it EVER fires, a creation path has a
    -- real bug, and it says so loudly instead of quietly shipping a blue link. Where the intended
    -- direction is provable (both nodes new: createSplineConnection appends interior points in travel
    -- order, so lower id -> higher id IS the travel direction), it also repairs on the spot.
    if not allowDual then
        local total = ADGraphManager:getWayPointsCount()
        for id = baseCount + 1, total do
            local n = ADGraphManager:getWayPointById(id)
            if n ~= nil then
                for _, outId in pairs(n.out or {}) do
                    local o = ADGraphManager:getWayPointById(outId)
                    if o ~= nil and table.contains(o.out or {}, n.id) then
                        Logging.warning("[FlyoverEditor]: junction INVARIANT VIOLATION - two-way link %d<->%d created on a one-way site. Report this.",
                            n.id, o.id)
                        if outId > baseCount then
                            local keepFrom = math.min(n.id, o.id)
                            local keepTo = math.max(n.id, o.id)
                            local kf = ADGraphManager:getWayPointById(keepFrom)
                            local kt = ADGraphManager:getWayPointById(keepTo)
                            table.removeValue(kt.out, keepFrom)
                            table.removeValue(kf.incoming, keepTo)
                            Logging.warning("[FlyoverEditor]: junction - repaired to one-way %d -> %d (interior points run in travel order).",
                                keepFrom, keepTo)
                        end
                    end
                end
            end
        end
    end

    local stubSeen = {}
    for _, s in ipairs(allStubs) do
        if s ~= nil and not stubSeen[s] and s.id ~= nil and s.id >= 0
            and #(s.out or {}) + #(s.incoming or {}) <= 2 then
            stubSeen[s] = true
            tryCall("junction removeWayPoint", function() ADGraphManager:removeWayPoint(s.id, false) end)
        end
    end

    -- Rebuild's debris clearing, LAST of all and only once something actually placed: every old
    -- off-skeleton node wired to this junction goes, including duplicate connectors and connectors of
    -- pairs the matrix now refuses - the per-movement path deletion this replaces left those behind.
    -- No degree guard here: a degree-3 debris node is an old connector fork, not road (roads are
    -- skeleton and never in this list). Deleted by object reference, id re-read each time.
    local debrisCleared = 0
    if placed > 0 and jp.debris ~= nil then
        for _, s in ipairs(jp.debris) do
            if s ~= nil and not stubSeen[s] and s.id ~= nil and s.id >= 0 then
                stubSeen[s] = true
                if tryCall("junction clear debris", function() ADGraphManager:removeWayPoint(s.id, false) end) then
                    debrisCleared = debrisCleared + 1
                end
            end
        end
    end
    if debrisCleared > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - cleared %d old junction point(s) (rebuild).", debrisCleared)
    end

    if mirrorsSkipped > 0 then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction - %d mirrored one-way pair(s) folded into their dual connector (built once, not twice).",
            mirrorsSkipped)
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction placed %d connector(s) (%d dual, %d rebuilt over old ones), consumed %d stub point(s).",
        placed, dualPlaced, rebuiltPlaced, #allStubs)
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    self.junctionArmed, self.junctionPreview, self.junctionPreviewKey = nil, nil, nil
end

--- Wheel handler. Returns true when the wheel was consumed, which is what stops the camera zoom.
--- Apply one wheel step to the active tool's key setting, ignoring the "has a pending action" gates.
--- Shared by the gated handleWheel paths below and by wheeling directly over the tool card, where the
--- whole point is to dial a value in (move's falloff, a tolerance) before anything is selected.
--- Returns true if it changed a value.
function ADFlyoverEditor:applyWheelToActiveTool(step)
    local t = self.tool
    if t == self.TOOL.SIDING then
        -- Siding: the wheel is the LENGTH, the dimension that changes per site.
        local setting = ADFlyoverSettings.settings.sidingLength
        if setting ~= nil then
            local nextIndex = math.max(1, math.min(#setting.values, setting.current + step))
            if nextIndex ~= setting.current then
                ADFlyoverSettings.setIndex("sidingLength", nextIndex)
            end
        end
        return true
    elseif t == self.TOOL.PARALLEL then
        self.offsetDistance = math.max(AutoDrive.FLYOVER_OFFSET_MIN,
            math.min(AutoDrive.FLYOVER_OFFSET_MAX,
                self.offsetDistance + step * AutoDrive.FLYOVER_OFFSET_STEP))
        self.offsetCache = nil
        return true
    elseif t == self.TOOL.GROUND then
        self.groundTolerance = math.max(AutoDrive.FLYOVER_GROUND_MIN,
            math.min(AutoDrive.FLYOVER_GROUND_MAX,
                self.groundTolerance + step * AutoDrive.FLYOVER_GROUND_STEP))
        return true
    elseif t == self.TOOL.STRAIGHTEN then
        self.straightenTolerance = math.max(AutoDrive.FLYOVER_STRAIGHTEN_MIN,
            math.min(AutoDrive.FLYOVER_STRAIGHTEN_MAX,
                self.straightenTolerance + step * AutoDrive.FLYOVER_STRAIGHTEN_STEP))
        return true
    elseif t == self.TOOL.DIVIDE then
        self.divideCount = math.max(0, math.min(AutoDrive.FLYOVER_DIVIDE_MAX, self.divideCount + step))
        return true
    elseif t == self.TOOL.MOVE then
        -- R+wheel rotates the currently-dragged set live (settled 2026-09-21) - takes priority
        -- over falloff/offset whenever it applies, since holding R is a deliberate, active choice
        -- to rotate rather than just wheeling absent-mindedly. Only meaningful mid-drag (there is
        -- nothing to rotate once released) and does nothing for a frozen copy-preview drag (see
        -- updateDrag - out of scope for now, not handled).
        if self.rotateKeyHeld and self.dragId ~= nil then
            self.moveRotateAngle = self.moveRotateAngle - step * AutoDrive.FLYOVER_ROTATE_WHEEL_STEP
            self:updateDrag()
            ADFlyoverSettings.debugLog("[FlyoverEditor]: move rotate %.0f deg.", math.deg(self.moveRotateAngle))
            return true
        end
        -- A pending offset (released, awaiting its right-click commit) takes the wheel over
        -- falloff whenever both could apply - it is the thing actually awaiting input right now,
        -- and handleWheel also claims the wheel for it everywhere, not just over the card (see the
        -- MOVE branch of the pending-action list below), so this has to agree with that.
        if self.moveOffsetChainIds ~= nil then
            -- Same direction as every other number (no per-field exception; see handleWheel).
            self:setMoveOffsetDistance(self.moveOffsetDistance + step * AutoDrive.FLYOVER_OFFSET_STEP)
            return true
        end
        -- Falloff is a spatial reach, not a tolerance/count - wheel-up should WIDEN it, the
        -- opposite of the global reversal `step` already carries (see handleWheel), so this
        -- negates it back to the raw scroll direction. This is the one negation Move's wheel
        -- actually needs; an earlier attempt removed it entirely instead of scoping it to just
        -- this field, which is what made the wheel read backwards again.
        self:setFalloffRadius(self.falloffRadius + step * AutoDrive.FLYOVER_FALLOFF_WHEEL_STEP)
        return true
    elseif t == self.TOOL.SMOOTH then
        -- Each mode gets the number it actually uses; rebuild ignores strength.
        if self.smoothMode == self.SMOOTH_MODE.REBUILD then
            self.smoothSpacing = math.max(AutoDrive.FLYOVER_SPACING_MIN,
                math.min(AutoDrive.FLYOVER_SPACING_MAX,
                    self.smoothSpacing + step * AutoDrive.FLYOVER_SPACING_STEP))
        else
            self.smoothStrength = math.max(0, math.min(AutoDrive.FLYOVER_SMOOTH_MAX, self.smoothStrength + step))
        end
        return true
    elseif t == self.TOOL.JUNCTION then
        -- The wheel is the scope radius - the primary disambiguation lever for what the crossing is.
        self.junctionRadius = math.max(AutoDrive.FLYOVER_JUNCTION_RADIUS_MIN,
            math.min(AutoDrive.FLYOVER_JUNCTION_RADIUS_MAX,
                (self.junctionRadius or 15) + step * AutoDrive.FLYOVER_JUNCTION_RADIUS_STEP))
        return true
    end
    return false
end

function ADFlyoverEditor:handleWheel(offset)
    if offset == nil or offset == 0 then
        return false
    end
    -- Deliberately reversed: wheel-up now DECREASES / pages down, wheel-down the reverse. Every wheel
    -- the mod itself drives runs through here - the card's numeric fields, the tool settings, the
    -- settings-dialog fields, and the manual's page scroll - so one negation flips them all to match
    -- the direction players expected. The -/+ stepper BUTTONS are untouched (they call stepAction
    -- directly, not this), and so is spline curvature: that wheel never reaches here - it falls
    -- through to AutoDrive's handleSplineCurvature on the camera-zoom path (see updateSplinePreview),
    -- which is exactly the one control the player asked to leave alone.
    local step = offset > 0 and -1 or 1

    -- A modal owns the wheel while it is up, and consumes it so nothing zooms behind. In the manual
    -- the wheel pages; in the settings dialog it adjusts the field under the cursor (via dialogWheel).
    if self:isModalOpen() then
        if self.manualOpen then
            self:manualScrollBy(step)
        elseif ADFlyoverHud ~= nil then
            ADFlyoverHud:dialogWheel(self.mouseX, self.mouseY, step)
        end
        return true
    end

    -- The contextual help is non-modal, but the wheel scrolls it when the cursor is over it, so a long
    -- page (Select's, say) can be read without paging to the manual. Same reversed step and 0.06 notch
    -- as the manual, so the two scroll the same way.
    if self.helpOpen and ADFlyoverHud ~= nil and ADFlyoverHud:isMouseOverHelp(self.mouseX, self.mouseY) then
        self:helpScrollBy(step)
        return true
    end

    -- Move's falloff radius is a spatial REACH, and players expect wheel-up to WIDEN it - the opposite
    -- of the tolerances and counts the global reversal above suits. Two rounds of history here:
    --
    --   1. (2026-09-21, earlier) a `-step` negation for Move fought an unrelated second negation
    --      elsewhere and produced wheel-up NARROWING the reach - backwards. "Fixed" by deleting
    --      the negation entirely, so Move fell through to the same plain reversed `step` as every
    --      tolerance/count field.
    --   2. (2026-09-21, later) that "fix" was itself backwards: it removed the ONE negation Move
    --      actually needed (to counteract the global reversal, not to double it), so the wheel was
    --      reported backwards again. The negation is back, but scoped correctly this time - see
    --      applyWheelToActiveTool's MOVE branch and the `wheelReach` field flag below, not a
    --      standing local here. The -/+ steppers were never affected either way (they call
    --      stepAction directly with a raw, unreversed dir, not through here).
    local toolStep = step

    -- Any numeric field under the cursor takes the wheel: the floating card's fields, the settings
    -- fields in the corner block, and the armed popup. Only rows carrying a stepAction match, so a
    -- scroll over a plain button or empty space still falls through to the camera zoom below.
    if ADFlyoverHud ~= nil then
        local field = ADFlyoverHud:numberFieldAt(self.mouseX, self.mouseY)
        if field ~= nil and field.stepAction ~= nil then
            -- wheelReach fields (Move's falloff) want the raw, unreversed sign - see the field's
            -- own definition in getEditableNumbers for why.
            -- One rule for every number field: the wheel steps it the same way. Move's falloff and offset
            -- used to be exempt (wheelReach), which made them run backwards next to everything else.
            field.stepAction(step)
            return true
        end
    end

    -- Over the tool card but not on a specific field: adjust the active tool's setting anyway, so the
    -- card is a place you can dial a value in before you start (move's falloff without a point picked).
    if ADFlyoverHud ~= nil and ADFlyoverHud:isMouseOverToolCard(self.mouseX, self.mouseY) then
        if self:applyWheelToActiveTool(toolStep) then
            return true
        end
    end

    -- Otherwise a tool claims the wheel only while it has a pending action (a span picked, a drag in
    -- progress), so the camera zoom keeps the wheel the rest of the time. toolStep is the plain
    -- reversed step for every tool - Move's own falloff negation happens inside
    -- applyWheelToActiveTool, not here, since that is the one call site shared by both the
    -- mid-drag and hover-over-card cases.
    if self.tool == self.TOOL.SIDING and self.sidingAnchorId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.PARALLEL and self.offsetToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.GROUND and (self.groundToId ~= nil or self.groundUsesSelection) then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.STRAIGHTEN and self.straightenToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.DIVIDE and self.divideToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    -- Also claimed with a pending (released, not yet right-click-committed) offset - not just
    -- mid-drag - so the wheel adjusts it from anywhere in the view, not only over the card
    -- (requested 2026-09-21: it previously only worked while actually hovering the tool card).
    if self.tool == self.TOOL.MOVE and (self.dragId ~= nil or self.moveOffsetChainIds ~= nil) then
        return self:applyWheelToActiveTool(toolStep)
    end
    if self.tool == self.TOOL.SMOOTH and self.smoothToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    -- Junction claims the wheel whenever it is active (no pending action needed): the wheel IS the
    -- scope-radius lever, so it takes the wheel over the world too, not just over the card.
    if self.tool == self.TOOL.JUNCTION then return self:applyWheelToActiveTool(toolStep) end

    return false
end

-- ---------------------------------------------------------------------------------------------
-- Appearance: the in-editor SETTINGS controls drive ADFlyoverTheme (scale + palette) live. Each
-- call just forwards to the theme module, which clamps, resolves and persists.
-- ---------------------------------------------------------------------------------------------

function ADFlyoverEditor:toggleSettings()
    self.settingsOpen = not self.settingsOpen
    if not self.settingsOpen then
        -- Leaving the panel abandons a half-typed scale rather than stranding the number editor.
        self:cancelEditNumber()
    end
end

-- The standalone settings dialog: a modal, theme-independent popup (drawn and hit-tested by the HUD).
-- While it is open the editor routes every click, wheel and key to it (see mouseEvent/keyEvent/
-- handleWheel), so nothing leaks to the tools or the camera.

function ADFlyoverEditor:openSettingsDialog()
    self.dialogOpen = true
    self.manualOpen = false   -- the two modals are mutually exclusive
    self:cancelEditNumber()
end

function ADFlyoverEditor:closeSettingsDialog()
    self.dialogOpen = false
    self:cancelEditNumber()
end

function ADFlyoverEditor:toggleSettingsDialog()
    if self.dialogOpen then self:closeSettingsDialog() else self:openSettingsDialog() end
end

-- The browsable manual: a modal that pages through the General reference and every tool. It reuses
-- the dialog's modal input path (dialogClick / dialogWheel and the modal branches in mouseEvent /
-- keyEvent / handleWheel), so isModalOpen() is what those all gate on.

function ADFlyoverEditor:isModalOpen()
    return self.dialogOpen or self.manualOpen
end

--- The manual page (1-based) for a tool: page 1 is the General reference, pages 2.. are the tools in
--- ADFlyoverHelp.ORDER, so opening the manual lands on the tool you were holding.
function ADFlyoverEditor:manualPageForTool(tool)
    if ADFlyoverHelp == nil or ADFlyoverHelp.ORDER == nil then return 1 end
    local key = (tool == self.TOOL.NONE) and "select" or self.TOOL_NAMES[tool]
    for i, k in ipairs(ADFlyoverHelp.ORDER) do
        if k == key then return i + 1 end
    end
    return 1
end

function ADFlyoverEditor:openManual()
    self.manualOpen = true
    self.dialogOpen = false
    self.helpOpen = false   -- the contextual help would otherwise render under and clash with it
    self:cancelEditNumber()
    self.manualIndex = self:manualPageForTool(self.tool)
    self.manualScroll = 0
end

function ADFlyoverEditor:closeManual()
    self.manualOpen = false
end

--- Page forward (dir 1) or back (dir -1) through the manual, wrapping at the ends. A new page starts
--- scrolled to the top.
function ADFlyoverEditor:manualStep(dir)
    if ADFlyoverHelp == nil or ADFlyoverHelp.ORDER == nil then return end
    local n = #ADFlyoverHelp.ORDER + 1
    self.manualIndex = (((self.manualIndex or 1) - 1 + (dir >= 0 and 1 or -1)) % n) + 1
    self.manualScroll = 0
end

--- Scroll the current manual page. dir > 0 is wheel-up (toward the top). The upper bound is the page
--- length, which only the HUD knows, so it clamps manualScroll to the page each frame; here we just
--- move it and keep it off the negative side.
function ADFlyoverEditor:manualScrollBy(dir)
    self.manualScroll = math.max(0, (self.manualScroll or 0) - dir * 0.06)
end

function ADFlyoverEditor:applyThemeScale(v)
    if ADFlyoverTheme == nil then return nil end
    return ADFlyoverTheme:setScale(v)
end

function ADFlyoverEditor:stepThemeScale(dir)
    if ADFlyoverTheme == nil then return end
    ADFlyoverTheme:setScale(ADFlyoverTheme.scale + dir * ADFlyoverTheme.SCALE_STEP)
end

function ADFlyoverEditor:applyLineWeight(v)
    if ADFlyoverTheme == nil then return nil end
    return ADFlyoverTheme:setLineWeight(v)
end

function ADFlyoverEditor:stepLineWeight(dir)
    if ADFlyoverTheme == nil then return end
    ADFlyoverTheme:setLineWeight(ADFlyoverTheme.lineWeight + dir * ADFlyoverTheme.LINEWEIGHT_STEP)
end

function ADFlyoverEditor:cycleThemePreset(dir)
    if ADFlyoverTheme ~= nil then ADFlyoverTheme:cyclePreset(dir) end
end

function ADFlyoverEditor:cycleThemeAccent(dir)
    if ADFlyoverTheme ~= nil then ADFlyoverTheme:cycleAccent(dir) end
end

function ADFlyoverEditor:resetTheme()
    if ADFlyoverTheme ~= nil then ADFlyoverTheme:resetDefault() end
end

-- The advanced per-role colour editor: pick a role, then set its R/G/B (0-255, sRGB). Each write
-- becomes an override that layers on top of the preset + accent; clearing it reverts to those.

function ADFlyoverEditor:toggleAdvanced()
    self.advancedOpen = not self.advancedOpen
    self:cancelEditNumber()
end

--- Returns the currently-edited role's key and its label.
function ADFlyoverEditor:currentEditRole()
    if ADFlyoverTheme == nil then return nil end
    local list = ADFlyoverTheme.EDITABLE_ROLES
    local i = self.themeEditRole or 1
    if i < 1 or i > #list then i = 1 end
    return list[i][1], list[i][2]
end

function ADFlyoverEditor:cycleEditRole(dir)
    if ADFlyoverTheme == nil then return end
    local n = #ADFlyoverTheme.EDITABLE_ROLES
    self.themeEditRole = (((self.themeEditRole or 1) - 1 + (dir >= 0 and 1 or -1)) % n) + 1
    self:cancelEditNumber()   -- picking a new role abandons any half-typed channel
end

--- The edited role's channel (1=R, 2=G, 3=B) as an integer 0-255.
function ADFlyoverEditor:roleChannel255(ch)
    if ADFlyoverTheme == nil then return 0 end
    local role = self:currentEditRole()
    if role == nil then return 0 end
    local c = { ADFlyoverTheme:srgb(role) }
    return math.floor((c[ch] or 0) * 255 + 0.5)
end

function ADFlyoverEditor:setRoleChannel255(ch, v255)
    if ADFlyoverTheme == nil then return nil end
    local role = self:currentEditRole()
    if role == nil then return nil end
    local n = tonumber(v255) or 0
    n = math.max(0, math.min(255, math.floor(n + 0.5)))
    local r, g, b = ADFlyoverTheme:srgb(role)
    local c = { r, g, b }
    c[ch] = n / 255
    ADFlyoverTheme:setOverride(role, c[1], c[2], c[3])
    return n
end

function ADFlyoverEditor:stepRoleChannel(ch, dir)
    self:setRoleChannel255(ch, self:roleChannel255(ch) + dir * 5)
end

function ADFlyoverEditor:clearEditRole()
    if ADFlyoverTheme == nil then return end
    local role = self:currentEditRole()
    if role ~= nil then ADFlyoverTheme:clearOverride(role) end
end

--- Evenly spaced points along the span, by arc length.
function ADFlyoverEditor:updateDividePreview()
    if self.divideFromId == nil or self.divideToId == nil then
        self.dividePreview = nil
        return
    end

    local span = self:spanBetween(self.divideFromId, self.divideToId)
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
    self.spanIds = nil
    if self.divideFromId ~= nil or self.divideToId ~= nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: divide cancelled.")
    end
    self.divideFromId, self.divideToId, self.dividePreview = nil, nil, nil
    self.divideBlockedBy = nil
end

function ADFlyoverEditor:commitDivide()
    local span = self:spanBetween(self.divideFromId, self.divideToId)
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

-- REVERSE flips which way a one-way runs ("other way"); REVERSEROAD makes AutoDrive's reverse road - a
-- link vehicles drive in reverse gear (listed in the start's out, not the end's incoming).
ADFlyoverEditor.CONVERT_OP = { SECONDARY = 1, PRIMARY = 2, TWOWAY = 3, ONEWAY = 4, REVERSE = 5, REVERSEROAD = 6 }
ADFlyoverEditor.CONVERT_OP_NAMES = { "secondary", "primary", "two-way", "one-way", "other way", "reverse-way" }

function ADFlyoverEditor:cycleConvertOp()
    self.convertOp = (self.convertOp % #self.CONVERT_OP_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: convert will make it %s.", self.CONVERT_OP_NAMES[self.convertOp])
end

function ADFlyoverEditor:cycleConvertScope()
    self.convertScope = (self.convertScope % #self.DELETE_SCOPE_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: convert applies to %s.", self.DELETE_SCOPE_NAMES[self.convertScope])
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

--- The selection popup's conversions: change only the connections BETWEEN selected points (a link to a
--- point outside the selection is not part of it), or - for priority - the selected points themselves.
function ADFlyoverEditor:menuConvertSelection(op)
    if self.selectionCount == 0 then
        return
    end
    ADEditorHistory:snapshot("convert selection " .. self.CONVERT_OP_NAMES[op])
    local OP, changed = self.CONVERT_OP, 0
    if op == OP.PRIMARY or op == OP.SECONDARY then
        local flags = (op == OP.SECONDARY) and AutoDrive.FLAG_SUBPRIO or AutoDrive.FLAG_NONE
        for id in pairs(self.selection) do
            ADGraphManager:setWayPointFlags(id, flags, false)
            changed = changed + 1
        end
    else
        local done = {}
        for a in pairs(self.selection) do
            local aw = ADGraphManager:getWayPointById(a)
            local near = {}
            if aw ~= nil then
                for _, listName in ipairs(LINK_LISTS) do
                    for _, b in pairs(linkList(aw, listName) or {}) do
                        if self.selection[b] and b ~= a then near[b] = true end
                    end
                end
            end
            for b in pairs(near) do
                local key = math.min(a, b) .. ":" .. math.max(a, b)
                if not done[key] then
                    done[key] = true
                    local bw = ADGraphManager:getWayPointById(b)
                    local forward = table.contains(aw.out, b)
                    local backward = bw ~= nil and table.contains(bw.out, a)
                    if op == OP.TWOWAY and not (forward and backward) then
                        addLink(a, b); addLink(b, a); changed = changed + 1
                    elseif op == OP.ONEWAY and forward and backward then
                        removeLink(b, a); changed = changed + 1
                    elseif op == OP.REVERSE and forward ~= backward then
                        if forward then removeLink(a, b); addLink(b, a) else removeLink(b, a); addLink(a, b) end
                        changed = changed + 1
                    end
                end
            end
        end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: converted the selection to %s (%d change(s)).", self.CONVERT_OP_NAMES[op], changed)
    ADGraphManager:markChanges()
    self:closeMenu()
end

--- The Convert tool's click: set BOTH the direction and the priority the card is configured for, as one
--- action and one undo step. (The point/span/run popup's "make two-way" etc. stay single changes.)
function ADFlyoverEditor:convertToolClick()
    if self.hoverId == nil then
        return
    end
    ADEditorHistory:snapshot(string.format("convert %s + %s",
        self.CONVERT_OP_NAMES[self.convertDirection], self.CONVERT_OP_NAMES[self.convertPriority]))
    local saved = self.convertOp
    self.convertSkipSnapshot = true
    self.convertOp = self.convertDirection
    self:convertAtCursor()
    self.convertOp = self.convertPriority
    self:convertAtCursor()
    self.convertSkipSnapshot = false
    self.convertOp = saved
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
            for _, listName in ipairs(LINK_LISTS) do
                for _, other in pairs(linkList(wp, listName) or {}) do
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

    if not self.convertSkipSnapshot then
        ADEditorHistory:snapshot("convert " .. self.CONVERT_OP_NAMES[self.convertOp])
    end

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
                elseif op == self.CONVERT_OP.REVERSEROAD then
                    -- Keep the way it runs (a two-way or unlinked pair takes the walk direction), then make
                    -- the link a reverse road: in the start's out, NOT in the end's incoming.
                    local fromId, toId = a, b
                    if backward and not forward then
                        fromId, toId = b, a
                    end
                    local fw, tw = ADGraphManager:getWayPointById(fromId), ADGraphManager:getWayPointById(toId)
                    local already = table.contains(fw.out, toId) and not table.contains(tw.incoming, fromId)
                        and not table.contains(tw.out, fromId)
                    if not already then
                        removeLink(toId, fromId)
                        if not table.contains(fw.out, toId) then
                            table.insert(fw.out, toId)
                        end
                        table.removeValue(tw.incoming, fromId)
                        changed = changed + 1
                    end
                elseif op == self.CONVERT_OP.REVERSE then
                    if forward ~= backward then
                        local fromId, toId = a, b
                        if not forward then
                            fromId, toId = b, a
                        end
                        -- A reverse-way link (in the start's out, NOT the end's incoming) stays a reverse-way
                        -- link, just the other way round; an ordinary one-way stays ordinary.
                        local tw = ADGraphManager:getWayPointById(toId)
                        local wasReverse = tw ~= nil and not table.contains(tw.incoming or {}, fromId)
                        removeLink(fromId, toId)
                        if wasReverse then
                            if not table.contains(tw.out, fromId) then
                                table.insert(tw.out, fromId)
                            end
                        else
                            addLink(toId, fromId)
                        end
                        changed = changed + 1
                    end
                end
            end
        end
    end

    ADFlyoverSettings.debugLog("[FlyoverEditor]: converted %s to %s (%d change(s)).",
        (op == self.CONVERT_OP.SECONDARY or op == self.CONVERT_OP.PRIMARY)
            and string.format("%d waypoint(s)", #(flagIds or ordered))
            or string.format("%d connection(s) across %d waypoint(s), junctions at the ends included",
                #ordered - 1, #ordered),
        self.CONVERT_OP_NAMES[op], changed)
    if changed == 0 then
        ADFlyoverSettings.debugLog("[AD]   nothing to do - it was already %s.", self.CONVERT_OP_NAMES[op])
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
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
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
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
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

    local span = self:spanBetween(self.mergeFromId, endId)
    self.mergePreviewSpan = span
    self.mergePreviewOther = nil
    self.mergeNear = nil
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

    if self.mergeToId ~= nil then
        self.mergeNear = nearSpan
    end

    -- Once the span is locked, narrow the preview to the track under the cursor, which is what the
    -- confirming click will actually pick.
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

    -- Span picked and the click lands on a track running alongside it: that is the confirm - merge now.
    if self.mergeToId ~= nil and self.mergeNear ~= nil and self.mergeNear[self.hoverId] then
        local fromId, toId = self.mergeFromId, self.mergeToId
        self.mergeFromId, self.mergeToId = nil, nil
        self:mergeTracks(fromId, toId, self.hoverId)
        self.spanIds, self.mergeNear, self.mergePreviewQueryId = nil, nil, nil
        return
    end

    -- Otherwise it is the shared span pick: click / second click = span, double-click = whole run,
    -- another click replaces the nearer end.
    self:spanPickClick({
        getFrom = function() return self.mergeFromId end,
        getTo = function() return self.mergeToId end,
        setEnds = function(a, b)
            self.mergeFromId, self.mergeToId = a, b
            self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
        end,
    })
end

--- Right-click with a span picked and exactly ONE track running alongside it: merge with that, no
--- third click needed. Returns true when it merged.
function ADFlyoverEditor:mergeWithOnlyCandidate()
    if self.mergeFromId == nil or self.mergeToId == nil or self.mergeNear == nil then
        return false
    end
    local seed = nil
    for id in pairs(self.mergeNear) do
        seed = id
        break
    end
    if seed == nil then
        return false
    end
    local group = self:connectedWithin(seed, self.mergeNear)
    for id in pairs(self.mergeNear) do
        if not group[id] then
            return false   -- more than one candidate track: the player has to click the one they mean
        end
    end
    local fromId, toId = self.mergeFromId, self.mergeToId
    self.mergeFromId, self.mergeToId = nil, nil
    self:mergeTracks(fromId, toId, seed)
    self.spanIds, self.mergeNear, self.mergePreviewQueryId = nil, nil, nil
    return true
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
    local span = self:spanBetween(spanStartId, spanEndId)
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
        ADFlyoverSettings.debugLog("[FlyoverEditor]: no part of the %d-waypoint span runs within %.1fm of the other track. Closest they come is %s.",
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

    ADFlyoverSettings.debugLog("[FlyoverEditor]: merged %d of %d span waypoint(s) with %d from the other track, within %.1fm.",
        #aInside, #span, #bInside, mergeDistance)
    if nearestMiss < math.huge then
        ADFlyoverSettings.debugLog("[AD]   the rest of the span stays separate; nearest it came was %.2fm.", nearestMiss)
    end
    if bridged > 0 then
        ADFlyoverSettings.debugLog("[AD]   crossed %d waypoint(s) where the tracks pulled apart, within the %.0fm divergence tolerance, and picked the track up again on the far side.",
            bridged, divergence)
    end
    if countB < nearCount then
        ADFlyoverSettings.debugLog("[AD]   %d other waypoint(s) were also near the span but not connected to the one clicked, and were left alone.",
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
                for _, listName in ipairs(LINK_LISTS) do
                    for _, other in pairs(linkList(wp, listName) or {}) do
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
            local oldY = a.y
            a.x, a.z = target.x, target.z
            -- The same height rule as Move and Draw, following "snap to": terrain drops it on the ground,
            -- surface keeps it on a bridge or ramp deck it was already on.
            a.y = self:resolveHeightAt(a.x, a.z, oldY)
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

ADFlyoverEditor.FIELD_LOOP_DIR = { CW = 1, CCW = 2, TWOWAY = 3 }
ADFlyoverEditor.FIELD_LOOP_DIR_NAMES = { "clockwise", "counter-clockwise", "two-way" }

function ADFlyoverEditor:toggleFieldLoopPriority()
    self.fieldLoopSubPrio = not self.fieldLoopSubPrio
    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop track will be %s.", self.fieldLoopSubPrio and "secondary" or "primary")
end

function ADFlyoverEditor:cycleFieldLoopDirection()
    self.fieldLoopDirection = (self.fieldLoopDirection % #self.FIELD_LOOP_DIR_NAMES) + 1
    ADFlyoverSettings.debugLog("[FlyoverEditor]: field loop track will be %s.", self.FIELD_LOOP_DIR_NAMES[self.fieldLoopDirection])
end

-- COMPANION EDIT: the `or` fallbacks match what the merge reads already do. Without them a nil
-- margin becomes `-nil` inside the offset, which is a hard Lua error on the first click, on a path
-- with no pcall around it.
function ADFlyoverEditor:generateFieldLoopAtCursor()
    if g_server == nil then
        Logging.error("[FlyoverEditor]: field loops can only be generated on the server (host/singleplayer).")
        return
    end
    if self.cursorX == nil then
        return
    end

    local marginDistance = ADFlyoverSettings.get("fieldLoopMargin") or 1.25
    local treeClearance = ADFlyoverSettings.get("fieldLoopTreeClearance") or 1.25
    local turningRadius = ADFlyoverSettings.get("fieldLoopTurningRadius") or 8

    local flags = self.fieldLoopSubPrio and AutoDrive.FLAG_SUBPRIO or AutoDrive.FLAG_NONE
    local direction = ({ [self.FIELD_LOOP_DIR.CW] = "cw", [self.FIELD_LOOP_DIR.CCW] = "ccw",
        [self.FIELD_LOOP_DIR.TWOWAY] = "twoway" })[self.fieldLoopDirection] or "twoway"

    -- A field loop can add hundreds of waypoints in one click, which is exactly the kind of thing
    -- that wants to be undoable in one step. Auto-discovery of a lane-split field's other patches
    -- (AutoDrive:findConnectedFieldRegions) and combining them into one course
    -- (AutoDrive:spliceFieldLoopRings) both happen inside generateFieldLoopAt, so this one click
    -- covers all of it.
    ADEditorHistory:snapshot("field loop")

    local ok = AutoDrive:generateFieldLoopAt(self.cursorX, self.cursorZ,
        marginDistance, treeClearance, turningRadius, "ADFlyoverEditor field loop", flags, direction)

    if ok then
        self:invalidateIdReferences()
        ADGraphManager:markChanges()
    end
end
