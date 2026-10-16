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
    junctionRadius = nil,   -- nil until first read: junctionRadiusValue() pulls the PERSISTED setting
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
    -- The card's action row (doc 12): clear | build | clear + build, starting on clear + build. Clear +
    -- build is the clear mode with junctionThenBuild set: the right-click clears and then builds on the
    -- same lock (applyJunctionClearThenBuild), so every clear-mode test in the tool still holds for it.
    junctionMode = "clear",     -- "build" or "clear" - see setJunctionAction (place mode dropped in 1.0.3.0)
    junctionThenBuild = true,
    -- Build, when the pattern (junctionPattern, mod or smooth) won't fit the junction: "turns" lays it
    -- turn by turn, as the build always has; "refuse" builds nothing and says why. Under advanced.
    junctionNoFit = "turns",
    junctionAdvancedOpen = false, -- the card's "advanced" fold
    junctionLeaveThrough = true, -- clear mode: spare through wiring at a T / 4-way (see debris pass)
    -- Connector curve engine: Dubins (default - radius-bounded pose-to-pose via AutoDrive's own
    -- ADDubins) or the tangent biarc (also the automatic fallback when Dubins declines).
    junctionUseDubins = true,
    -- Place mode's shape (doc 07/08): "exact" = the mod's X or T fitted to the crossing, "smooth" = the
    -- same pattern with curves.
    junctionPattern = "exact",
    -- Static-obstacle check (trees, buildings, fences/poles/signs), on by default: a corridor that
    -- overlaps one shrinks its radius to swing clear, and refuses (red, "blocked") if nothing fits.
    junctionCheckObstacles = true,
    junctionSwept = true,
    -- Which rigs of the vehicle set (SweptSim.RIGS, plus a rig measured in game) a built turn must fit:
    -- the two tractor rigs by default, never the semi alone (decided 2026-10-07). Card toggles.
    junctionRigs = { small = true, big = true, semi = false, measured = true },
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
--- EVERY POINT THIS EDITOR MAKES IS OURS. AutoDrive marks the points it builds from the map's
--- traffic splines with FLAG_TRAFFIC_SYSTEM (and _CONNECTION), and new points used to copy their
--- flags from a neighbour - so by 2026 about 5,300 points laid later carried the map's mark and the
--- flag could no longer tell a map road from ours. New points keep every other flag (a low-priority
--- lane stays low-priority) and drop only those two. Global, so FieldLoopGenerator can use it too.
---
--- AUTODRIVE'S FIELD POINTS ARE THE EXCEPTION THAT IS KEPT (AutoDrive 3.0.1.4). Its editor lays a loop
--- round a field (Ctrl+Shift+F) and tags each point twice: a flag bit (FLAG_FIELD_POINT, 8) and the
--- field's number (wp.fieldID). Pressed again, it deletes the points carrying both and lays the loop
--- anew. A point that replaces or carries on one of those points - a smoothed or divided stretch, a
--- point put into a link - is still that field's loop, so `fieldID` (from ADFlyoverEditor.fieldOf) passes
--- the number on and the bit stays. Any other new point drops the bit: without the number it is one
--- AutoDrive can never find again, a stray when the loop is laid anew.
function ADFlyoverRecordWayPoint(x, y, z, connectPrevious, dual, reverse, previousId, flags, sendEvent, fieldID)
    local f = flags or 0
    if math.floor(f / 2) % 2 == 1 then f = f - 2 end   -- AutoDrive.FLAG_TRAFFIC_SYSTEM
    if math.floor(f / 4) % 2 == 1 then f = f - 4 end   -- AutoDrive.FLAG_TRAFFIC_SYSTEM_CONNECTION
    local fieldPoint = math.floor(f / 8) % 2 == 1       -- AutoDrive.FLAG_FIELD_POINT
    if fieldPoint and fieldID == nil then f = f - 8 end
    if fieldID ~= nil and not fieldPoint then f = f + 8 end
    local wp = ADGraphManager:recordWayPoint(x, y, z, connectPrevious, dual, reverse, previousId, f, sendEvent)
    if wp ~= nil and fieldID ~= nil then
        wp.fieldID = fieldID
    end
    return wp
end

--- The field number of one of AutoDrive's field points, to pass to ADFlyoverRecordWayPoint when a new
--- point replaces or carries on `wp`; nil for any other point (or a missing one).
function ADFlyoverEditor.fieldOf(wp)
    if wp ~= nil and wp.fieldID ~= nil and math.floor((wp.flags or 0) / 8) % 2 == 1 then
        return wp.fieldID
    end
    return nil
end

--- A new point's flags: the field point bit kept with a field number, dropped without one - the same
--- rule as ADFlyoverRecordWayPoint, for callers that hand flags to AutoDrive themselves. (main's helper,
--- used by the multi-point spline; it went missing at the 1.0.3.0 merge and broke the spline's
--- right-click: "Spline.lua:390: attempt to call a nil value".)
function ADFlyoverEditor.fieldFlags(flags, fieldID)
    local f = flags or 0
    local isField = math.floor(f / 8) % 2 == 1
    if isField and fieldID == nil then f = f - 8 end
    if fieldID ~= nil and not isField then f = f + 8 end
    return f
end

--- `flags` with only its priority bit (FLAG_SUBPRIO, 1) set as asked: what a priority change means.
--- Every other bit is AutoDrive's own mark and stays - the map's traffic system, a field point.
function ADFlyoverEditor.withPriority(flags, secondary)
    local f = flags or 0
    f = f - f % 2
    if secondary then
        f = f + AutoDrive.FLAG_SUBPRIO
    end
    return f
end

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
-- Sweep-wide reshape (docs/swept-path-spec.md §6): how far a connector may be pushed OUTWARD of its
-- fitted line so the design rig's cut-in lands back on the road - "swing left to make a wider right
-- turn". Tried in steps before the radius is ever stepped down; the corridor road check on the
-- shifted line is what bounds it to the outer road edge, this is only the search limit.
-- The WORK REGION: how far from the locked point the tool follows the selected tracks to do its
-- geometry - find where they meet, place tie-ins, run kickouts, recognise what is already connected,
-- clear old wiring on a rebuild. It is a fixed reach, deliberately NOT the wheel's search radius: the
-- wheel only decides WHICH tracks take part (the circle has to cut them); where the tool enters and
-- leaves those tracks is decided by the tracks and the rig, and must come out the same whatever size
-- the circle was when it found them. 60 m holds a 12 m turn's tie-ins (12 m from the corner) plus a
-- full early/late kickout (12 m before, ~19 m after) with room to spare, and a sharp hook's longer t.
AutoDrive.FLYOVER_JUNCTION_WORK_REACH = 60
-- OWNERSHIP: wiring belongs to THIS junction when some node of it lies inside the search circle plus
-- this tolerance. One rule, used three ways: a fork met while following a run outward is this
-- junction's own tie-in (walk on) or another junction (the run ends there); a rebuild clears a
-- cluster only if it is ours; and a connection only counts as "already there" if it passes through
-- here. It is what keeps tracks that diverge and reconverge up the road, and the junction next door,
-- out of this one's business - the wheel doing exactly its job of identifying or excluding.
AutoDrive.FLYOVER_JUNCTION_OWN_TOLERANCE = 5
AutoDrive.FLYOVER_JUNCTION_SWEEP_MAX = 3.0
AutoDrive.FLYOVER_JUNCTION_SWEEP_STEP = 1.0
-- The swept road gate probes the design rig's body edges (tow corners, trailer sides) once per THIS
-- MANY METRES of the tow's travel through a turn - by distance, so how fast the twin takes the
-- corner cannot change the share of probes that land off the road.
AutoDrive.FLYOVER_JUNCTION_SWEPT_PROBE_STEP = 1.0
-- ...and judges only the ground the TURN adds: a body edge within its half-width plus THIS MANY
-- METRES of the route line is where the rig would be driving the line exactly (the existing lanes,
-- or the connector's own strip, which the corridor check already covers), so it is neither probed
-- nor counted - the off-road share is taken over the turn's own ground alone.
AutoDrive.FLYOVER_JUNCTION_SWEPT_LINE_MARGIN = 0.3

-- After a clear, a lane that dead-ends at the junction is trimmed back or run forward so it stops
-- THIS FAR FROM THE EDGE OF THE ROAD IT MEETS, and any points added get the lane's own spacing.
-- Clearance from the nearest crossing TRACK, not a radius from a point: a tail should stop at the
-- edge of the road it joins, and where that road is a pair of tracks the near one is its edge. About
-- half a lane, so the stub stops just clear of the carriageway.
AutoDrive.FLYOVER_JUNCTION_TRACK_CLEARANCE = 2.5
-- How much of a lane the tidy may remove, in METRES. A node cap is the wrong unit: spacing runs
-- from 1.5 m on a laid curve to 12 m on a recorded road, so a cap of eight nodes bounded the
-- damage anywhere between 12 m and 90 m - and a clear that trimmed eight off each of three lanes
-- took 30 to 50 m of road. A tidy adjusts the last few metres of a lane; wanting more than this
-- means the boundary is wrong, and a ragged end is recoverable where a dug-up road is not.
-- Clear mode's own scope. It is NOT a setting: what belongs to a junction is a property of the
-- road, and a wheel that changed it only made the same click give different answers. Wide enough to
-- cut every arm of the junctions on a real map, and fixed so that it always cuts them in the same
-- place.
AutoDrive.FLYOVER_JUNCTION_CLEAR_SCOPE = 12
-- How far from a junction a click may be and still be taken as pointing AT it. Not the same
-- question as how much road belongs to the junction, which is a property of the road; this is only
-- about the cursor. It was 40 m, at which distance the click is no longer choosing anything - three
-- junctions sat inside that range at one site on the test map.
AutoDrive.FLYOVER_JUNCTION_SELECT_RADIUS = 20
-- How close two road-meeting points must be to count as ONE junction: 10 reads a staggered crossing
-- as two T's, 20 as one offset 4-way. See junctionCentres.
AutoDrive.FLYOVER_JUNCTION_MERGE = 10
-- An arm has to go SOMEWHERE for the thing it leaves to be a junction. Below this a third arm is a
-- field entrance, a lay-by or the stub of something long since removed, and clearing around it does
-- damage for no gain.
AutoDrive.FLYOVER_JUNCTION_MIN_ARM = 15
AutoDrive.FLYOVER_JUNCTION_TRIM_BUDGET = 8.0
-- After a clear, each approach is RE-SPACED over this many metres leading to the junction. Years of
-- tie-ins, re-laid ends and trims leave an approach with 0.9 m hops next to 12 m ones. The step is
-- a MAXIMUM: the respacing is the smooth tool's own rebuild, which puts points this far apart on
-- the straights and closer through bends. 0 switches it off.
AutoDrive.FLYOVER_JUNCTION_RESPACE_LEN = 50
AutoDrive.FLYOVER_JUNCTION_RESPACE_STEP = 5.0

-- Fallback for a lane with no crossing road to measure against at all: a plain radius from the
-- centre of the tracks. Wider, because with nothing to clear there is nothing to hug.
AutoDrive.FLYOVER_JUNCTION_STUB_GAP = 4.0

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
---
--- WHEN it runs matters. A tester lost the in-vehicle wheel zoom after an exit, and every such exit
--- showed the vehicle context gaining ~53 action events across the cycle - the HUD toggle appears to
--- make the vehicle re-register its bindings. The hide used to run with OUR context current and the
--- restore with VEHICLE current, so the two halves re-registered into different contexts.
--- "symmetric" (default) hides before the context push, so both halves run with the gameplay
--- context current; "legacy" is the 1.0.2.0 order, kept for an A/B test (FlyoverHudOrder).
ADFlyoverEditor.hudToggleOrder = "symmetric"

--- One line per toggle: which context was current, and which action events it added or removed.
function ADFlyoverEditor:logHudToggle(label, stateBefore, countsBefore)
    Logging.info("[FlyoverEditor]: whole-hud %s (order=%s) | before: %s | after: %s | events changed: %s",
        label, tostring(self.hudToggleOrder), stateBefore, self:describeInputState(),
        self:diffActionCounts(countsBefore, self:inputActionCounts()))
end

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
    local stateBefore, countsBefore = self:describeInputState(), self:inputActionCounts()
    local ok, err = pcall(hud.consoleCommandToggleVisibility, hud)
    local after = hud.isVisible
    Logging.info("[FlyoverEditor]: whole-hud hide: called consoleCommandToggleVisibility ok=%s err=%s isVisible %s -> %s",
        tostring(ok), tostring(err), tostring(before), tostring(after))
    self:logHudToggle("hide", stateBefore, countsBefore)
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
        local stateBefore, countsBefore = self:describeInputState(), self:inputActionCounts()
        local ok, err = pcall(hud.consoleCommandToggleVisibility, hud)
        Logging.info("[FlyoverEditor]: whole-hud restore: ok=%s err=%s isVisible=%s", tostring(ok), tostring(err), tostring(hud.isVisible))
        self:logHudToggle("restore", stateBefore, countsBefore)
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
        -- The stamp tools/build_zip.py writes into Prelude.lua (P.BUILD), the one the ARMED line shows.
        -- ADBuildInfo was the old deploy script's, and nothing writes it now: a packaged build of
        -- 058d9eb logged "build unknown" here while Prelude had just said which build it was.
        if ADFlyoverPrelude ~= nil and ADFlyoverPrelude.BUILD ~= nil then
            return "build " .. tostring(ADFlyoverPrelude.BUILD)
        end
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

--- Action events per action name, for the current context. The summary above only counts them,
--- and a count that goes UP says nothing about which bindings changed - the in-vehicle wheel zoom
--- died after an exit whose count rose by 53. Diffing by name shows whether the camera zoom
--- actions were among them. Nil if this build does not expose the events table.
function ADFlyoverEditor:inputActionCounts()
    local ok, counts = pcall(function()
        local result = {}
        for _, event in pairs(g_inputBinding.events or {}) do
            local name
            if type(event) == "table" then
                name = event.actionName
                if name == nil and type(event.action) == "table" then
                    name = event.action.name
                end
            end
            name = tostring(name or "?")
            result[name] = (result[name] or 0) + 1
        end
        return result
    end)
    return ok and counts or nil
end

--- "+CAMERA_ZOOM_IN x1, -AXIS_MOVE_SIDE_VEHICLE x2" style, sorted; "no change" when equal.
function ADFlyoverEditor:diffActionCounts(before, after)
    if before == nil or after == nil then
        return "not readable"
    end
    local names, seen = {}, {}
    for name in pairs(before) do seen[name] = true end
    for name in pairs(after) do seen[name] = true end
    for name in pairs(seen) do names[#names + 1] = name end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        local d = (after[name] or 0) - (before[name] or 0)
        if d ~= 0 then
            parts[#parts + 1] = string.format("%s%s x%d", d > 0 and "+" or "-", name, math.abs(d))
        end
    end
    return #parts == 0 and "no change" or table.concat(parts, ", ")
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
    -- SELF-WIRED POINTS GO ON THE WAY IN, EVERY TIME, WITHOUT BEING ASKED.
    --
    -- A point listing its own id among its links has no valid reading: no road leaves a point and
    -- arrives back at that same point without going anywhere. Nothing drives it, so removing it
    -- cannot change a route - there is no judgement to make and nothing to weigh up, which is
    -- exactly why it should not have needed a console command.
    --
    -- It DID need one, and only reached the junction being cleared otherwise: the integrity sweep
    -- is bounded to that site, and the 19 in this network were scattered across the whole map,
    -- nowhere near anything anyone would clear. They would have sat there for good. Worse, a repair
    -- the user has to remember to run is one undo away from being silently lost, which is what
    -- happened within the hour of it being written.
    --
    -- Cheap enough to do on every open - one pass over the waypoints, no geometry - and silent when
    -- there is nothing to do. It only ever says something when it found something.
    if self.repairSelfLinks ~= nil then
        local ok, found, fixed = pcall(function() return self:repairSelfLinks(true) end)
        if ok and (found or 0) > 0 then
            Logging.info("[FlyoverEditor]: %d point(s) were wired to themselves and have been unwired. Positions are above. Save to keep this.",
                fixed or 0)
        end
    end
    -- Before ANYTHING is touched. Compared against the line printed after teardown, this is the
    -- only pair that says whether a cycle put the input system back as it found it. Logging only
    -- after the push, as the first version did, made a clean cycle indistinguishable from a lossy
    -- one.
    self.inputStateOnEnter = self:describeInputState()
    self.inputActionsOnEnter = self:inputActionCounts()

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
    -- Kept for the exit: if the player is in another vehicle, or on foot, by then, the camera the
    -- flyover camera hands the screen back to is the wrong one (see restoreVehicleCamera).
    self.vehicleOnEnter = vehicle
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
    -- The whole-hud hide goes here, while the gameplay context is still current, so it mirrors the
    -- restore in disable() - which runs after revertContext, with that same context current again.
    if self.hudToggleOrder ~= "legacy" then
        self:suspendWholeHud()
    end

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
    if self.hudToggleOrder == "legacy" then
        self:suspendWholeHud()
    end

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
    -- The editor clock restarts at 0 on every open, so any timestamp taken against the old clock is
    -- meaningless now. A stale escHandledAt from the last session made every Esc look like a repeat
    -- (a negative difference is "< 400") until the new clock caught up - Esc did nothing after re-opening.
    self.escHandledAt = nil
    -- And the warning box's expiry: a message left from last time would otherwise hang on screen.
    self.warning = nil
    -- Same for the double-click memories: an old timestamp against the new clock reads as "just now",
    -- so a single click on the same point could count as a double-click.
    self.lastSelectId, self.lastSelectAt = nil, nil
    self.lastPickId, self.lastPickAt = nil, nil
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

--- After the flyover camera is gone: put the screen on the camera of the vehicle the player is in
--- now, not the one from entry.
---
--- GuiTopDownCamera:deactivate() restores the render camera it took over from, which is the entry
--- vehicle's. rnap84's log for issue 18 (docs/issue-18-wheel-zoom-log.md) has three sessions that
--- began in a vehicle and ended on foot; a vehicle change during a session leaves the player zooming
--- a camera that is not on screen until something re-activates it (Tab, C, a reload) - which is the
--- tester's own recovery recipe. setActiveCameraIndex is the game's own switch: its guard makes it a
--- no-op when the vehicle's camera is already the one rendering, and otherwise it deactivates and
--- re-activates that camera the way pressing C does (VehicleCamera:onActivate is what sets the render
--- camera). On foot the player camera is the game's to restore, so nothing is touched.
---
--- Nothing in the editor leaves or switches a vehicle, so a change is logged as a warning: the log
--- then says when it happened, which the issue's log could not.
function ADFlyoverEditor:restoreVehicleCamera()
    local okNow, vehicle = pcall(function() return AutoDrive.getControlledVehicle() end)
    vehicle = okNow and vehicle or nil
    local before = self.vehicleOnEnter
    self.vehicleOnEnter = nil

    local function describe(v)
        if v == nil then
            return "on foot"
        end
        local ok, name = pcall(function() return v:getName() end)
        return "in " .. (ok and tostring(name) or "a vehicle")
    end
    if vehicle ~= before then
        Logging.warning("[FlyoverEditor]: the player was %s when the editor opened and is %s now - the "
            .. "vehicle changed while the editor was open. Nothing in the editor does that; worth a report "
            .. "with the log, with what you pressed or clicked just before.", describe(before), describe(vehicle))
    end
    if vehicle == nil then
        return
    end

    local spec = vehicle.spec_enterable
    if spec == nil or spec.activeCamera == nil or spec.camIndex == nil or vehicle.setActiveCameraIndex == nil then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: exit: the vehicle has no active camera to put back.")
        return
    end
    local okRender, rendering = pcall(function() return g_cameraManager.activeCameraNode end)
    if not okRender then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: exit: the render camera is not readable on this build; leaving the cameras alone.")
        return
    end
    if rendering == spec.activeCamera.cameraNode then
        Logging.info("[FlyoverEditor]: exit: the screen is on the vehicle's camera.")
        return
    end
    Logging.warning("[FlyoverEditor]: exit: the screen was NOT on the vehicle's camera (this is the state "
        .. "that loses the wheel zoom) - re-activating it.")
    tryCall("vehicle:setActiveCameraIndex", function() vehicle:setActiveCameraIndex(spec.camIndex) end)
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
    -- The flyover camera gave the screen back to the camera it took it from at entry. Make sure the
    -- vehicle the player is in NOW is the one rendering, and say so if the vehicle changed meanwhile.
    self:restoreVehicleCamera()

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
    -- Which bindings the whole cycle changed, by name - the counts alone could not say whether the
    -- wheel-zoom actions were among the ones re-registered.
    Logging.info("[FlyoverEditor]: action events changed across the cycle (hud order=%s): %s",
        tostring(self.hudToggleOrder), self:diffActionCounts(self.inputActionsOnEnter, self:inputActionCounts()))
    self.inputActionsOnEnter = nil
    -- Report the next few in-vehicle wheel events (Wrappers.lua, wrapper 4). No lines at all after
    -- scrolling means the zoom action never fired - an input-binding problem; lines saying
    -- "swallowed" mean AutoDrive's own flags are holding the wheel.
    self.wheelProbeRemaining = 6
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
    if self.escHandledAt == nil then
        return false
    end
    local since = self:nowMs() - self.escHandledAt
    return since >= 0 and since < 400
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
    elseif t == T.SPLINE and self:multiSplinePending() then
        self:cancelMultiSpline()
    elseif t == T.SPLINE and (self.splineFromId ~= nil or self.splineToId ~= nil) then
        self:cancelSplinePreview()
    elseif t == T.DIVIDE and (self.divideFromId ~= nil or self.divideToId ~= nil) then
        self:cancelDivide()
    elseif t == T.MERGE and (self.mergeFromId ~= nil or self.mergeToId ~= nil) then
        self.mergeFromId, self.mergeToId = nil, nil
        self.mergePreviewSpan, self.mergePreviewOther, self.mergePreviewQueryId = nil, nil, nil
    elseif t == T.ROADRUNS and self.roadRuns ~= nil and self.roadRuns.sel ~= nil then
        self:roadRunsSelect(nil)
    elseif t == T.ROADRUNS and self.roadRuns ~= nil and #self.roadRuns.picks > 0 then
        self:roadRunsClearPicks()
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
--- The picker a menu-armed tool should step back to, or nil when there is nothing sensible to go back to:
--- a selection popup whose selection is gone (cleared by an earlier Esc, or by an undo) would reopen empty
--- and keep Esc going round in circles.
function ADFlyoverEditor:menuToReturnTo()
    local back = self.menuBackTo
    if back ~= nil and back.kind == "set" and self.selectionCount == 0 then
        return nil
    end
    return back
end

function ADFlyoverEditor:logEsc(what)
    ADFlyoverSettings.debugLog("[FlyoverEditor]: Esc: %s.", what)
end

function ADFlyoverEditor:escapeStep()
    if self.editing ~= nil then
        self:cancelEditNumber()
        self:logEsc("typed number cancelled")
        return true
    end
    if self:isModalOpen() then
        if self.manualOpen then self:closeManual() else self:closeSettingsDialog() end
        self:logEsc("dialog closed")
        return true
    end
    if self.ctxMenu ~= nil then
        self:logEsc("menu '" .. tostring(self.ctxMenu.kind) .. "' closed")
        if self.ctxMenu.kind == "armed" then
            -- Back to the picker the tool was chosen from (same selection, same spot), not to Select.
            local back = self:menuToReturnTo()
            self:menuCancelArmed()
            if back ~= nil then self.ctxMenu = back end
        else
            -- The selection popup IS the selection: one Esc closes it and drops the selection together.
            if self.ctxMenu.kind == "set" then
                self:clearSelection()
            end
            self:closeMenu()
        end
        return true
    end
    if self.helpOpen then
        self:toggleHelp()
        self:logEsc("help closed")
        return true
    end
    if self:cancelPendingAction() then
        self:logEsc("pending action cancelled")
        return true
    end
    if self.selectionCount > 0 then
        self:clearSelection()
        self:logEsc("selection cleared")
        return true
    end
    if self.tool ~= self.TOOL.NONE then
        local back = self:menuToReturnTo()
        self:setTool(self.TOOL.NONE)
        if back ~= nil then self.ctxMenu = back end
        self:logEsc(back ~= nil and "tool put away, back to its menu" or "tool put away")
        return true
    end
    self:logEsc("nothing left - leaving the editor")
    return false
end

function ADFlyoverEditor:onCancelAction(actionName)
    if not self.active or self:isGuiBlocking() then
        return
    end
    if self:escRecentlyHandled() then
        self:logEsc("repeat of the same press, ignored (" .. tostring(actionName) .. ")")
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
    -- Before anything else, so it happens whatever the editor is doing: see junctionCheckRecordOff.
    self:junctionCheckRecordOff()
    -- Also whether the editor is open or not: junction numbers and split decisions made before this
    -- career was first saved are written as soon as that first save makes the folder.
    self:junctionRegistrySaveWaiting(dt)
    -- And the file as it was when this game loaded, held so the game's own save can write it back
    -- (junctionRegistryOnGameSave): FS25 writes the savegame folder afresh, dropping files it did not.
    self:junctionRegistryKeepFile(dt)
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
        if self:splineIsMultiPoint() then
            self:updateMultiSpline()
        else
            self:updateSplinePreview()
        end
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
    elseif self.tool == self.TOOL.ROADRUNS then
        self:updateRoadRuns(overPanel)
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

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared = ADFlyoverEditor.shared or {}
ADFlyoverEditor.shared.LINK_LISTS = LINK_LISTS
ADFlyoverEditor.shared.clearSplineState = clearSplineState
ADFlyoverEditor.shared.disconnectExternal = disconnectExternal
ADFlyoverEditor.shared.isJunction = isJunction
ADFlyoverEditor.shared.linkList = linkList
ADFlyoverEditor.shared.tryCall = tryCall
-- MODSPLIT: end of the shared block
