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
    junctionMode = "build",     -- "build" (default) or "clear" - see toggleJunctionMode
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
function ADFlyoverRecordWayPoint(x, y, z, connectPrevious, dual, reverse, previousId, flags, sendEvent)
    local f = flags or 0
    if math.floor(f / 2) % 2 == 1 then f = f - 2 end   -- AutoDrive.FLAG_TRAFFIC_SYSTEM
    if math.floor(f / 4) % 2 == 1 then f = f - 4 end   -- AutoDrive.FLAG_TRAFFIC_SYSTEM_CONNECTION
    return ADGraphManager:recordWayPoint(x, y, z, connectPrevious, dual, reverse, previousId, f, sendEvent)
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
        local flags = (op == self.CONVERT_OP.SECONDARY) and AutoDrive.FLAG_SUBPRIO or AutoDrive.FLAG_NONE
        for _, id in ipairs(ordered) do
            ADGraphManager:setWayPointFlags(id, flags, false)
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

--- The falloff reach for a span / run drag: the falloff value for Move's own picks, nil (taper to the
--- span's own ends) for a span or run handed over by a popup's "move".
function ADFlyoverEditor:moveReach()
    -- Settled 2026-09-26: a span, run or run-shaped selection always tapers to its own two ends. The
    -- adjustable reach is what a POINT pick with falloff is for (it walks along the run).
    return nil
end

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
    self.movePickFromMenu = false
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
    self.movePickFromMenu = false
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
            -- A point clicked plainly first (its point menu is open) is the start of the selection: Ctrl-adding
            -- the next point keeps it, instead of silently dropping it.
            local m = self.ctxMenu
            if self.tool == self.TOOL.NONE and m ~= nil and m.kind == "point" and m.id ~= nil
                and m.id ~= self.hoverId and not self.selection[m.id] then
                self:toggleSelected(m.id)
            end
            self:toggleSelected(self.hoverId)
            -- In Select mode the selection popup takes over from whatever menu was open (a point menu from
            -- the first plain click), and follows the count; it closes when the last point is deselected.
            if self.tool == self.TOOL.NONE then
                if self.selectionCount >= 2 then
                    self:openSetMenu()
                elseif self.selectionCount == 1 then
                    -- One point left is a point pick, not a selection: show its point menu (a following
                    -- Ctrl-click picks it back up into a selection - see above).
                    local only = next(self.selection)
                    self:clearSelection()
                    self:openPointMenu(only, g_lastMousePosX or 0.5, g_lastMousePosY or 0.5)
                else
                    self:closeMenu()
                end
            end
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
            -- "nothing to place" and unlock instead of placing. Clear mode never has new/rebuild
            -- movements (the solve is skipped entirely) - its own work is a non-empty debris/stale-
            -- link set, filtered the same way applyJunctionClear will filter it.
            local hasWork
            if jp ~= nil and jp.placeMode then
                hasWork = jp.ok == true
            elseif jp ~= nil and jp.clearMode then
                local leave = self.junctionLeaveThrough ~= false
                local nodes = leave and jp.turnDebris or jp.debris
                local anySeverableLink = false
                if leave then
                    for _, pair in ipairs(jp.staleLinks or {}) do
                        if not pair.isThrough then anySeverableLink = true; break end
                    end
                else
                    anySeverableLink = (#(jp.staleLinks or {})) > 0
                end
                hasWork = (nodes ~= nil and #nodes > 0) or anySeverableLink
            else
                hasWork = jp ~= nil and ((jp.nNew or 0) + (jp.nRebuild or 0)) > 0
            end
            if hasWork then
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
        -- A selection that happens to be one connected run IS a span: with falloff on, it tapers to its own
        -- two ends exactly like a picked span, instead of always moving rigidly.
        local chain = self:selectionChain()
        if chain ~= nil and #chain >= 3 and self.moveFalloffOn then
            local set = {}
            for _, id in ipairs(chain) do set[id] = true end
            -- The falloff value is the reach along the selection from the grabbed point (0 = taper to its ends).
            self:gatherChainFollowers(chain[1], chain[#chain], set, false, nil)
            return
        end
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
        self:gatherChainFollowers(fromId, toId, run, true, self:moveReach())
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
        self:gatherChainFollowers(self.moveSpanFromId, self.moveSpanToId, self.moveSpanIds, false, self:moveReach())
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
function ADFlyoverEditor:gatherChainFollowers(fromId, toId, run, excludeJunctionEnds, maxReach)
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
                -- A set reach (the falloff value, for a run-shaped selection) tapers sooner than the ends.
                if maxReach ~= nil and maxReach > 0 then
                    reach = math.min(reach, maxReach)
                end
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

-- ONE FILE MAY HOLD ONLY 200 LOCAL NAMES AT ONCE (Lua 5.1). The local helpers from here to the
-- matching "end" are used nowhere after it, so they are scoped to this block and free their slots.
do
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

--- A span picked by two clicks must be the short, obvious way between them. When the only route found runs
--- a long way round (away through a junction and back, or down a different run), refuse it rather than
--- quietly take it: over ROUTE_MAX_RATIO times the straight distance AND more than ROUTE_MAX_EXTRA metres
--- longer than it. Returns ok, routeLength, straightLength.
ADFlyoverEditor.ROUTE_MAX_RATIO = 2.0
ADFlyoverEditor.ROUTE_MAX_EXTRA = 40
function ADFlyoverEditor:spanRouteIsDirect(span)
    if span == nil or #span < 2 then
        return true, 0, 0
    end
    local length, prev = 0, nil
    for _, id in ipairs(span) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            if prev ~= nil then
                length = length + MathUtil.vector2Length(wp.x - prev.x, wp.z - prev.z)
            end
            prev = wp
        end
    end
    local a = ADGraphManager:getWayPointById(span[1])
    local b = ADGraphManager:getWayPointById(span[#span])
    local straight = (a ~= nil and b ~= nil) and MathUtil.vector2Length(b.x - a.x, b.z - a.z) or 0
    local direct = not (length > straight * self.ROUTE_MAX_RATIO and length - straight > self.ROUTE_MAX_EXTRA)
    return direct, length, straight
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

    -- A plain click after a Ctrl-built chain drops the chain and starts a fresh pick, rather than
    -- stretching the chain's span to the clicked point.
    if self.selectionCount > 0 and self:toolNeedsChainSelection() then
        self:clearSelection()
        self.spanIds = nil
        cfg.setEnds(nil, nil, nil)
        ADFlyoverSettings.debugLog("[FlyoverEditor]: plain click - dropped the Ctrl chain, starting a new pick.")
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
        local direct, routeLength, straightLength = self:spanRouteIsDirect(span)
        if not direct then
            ADFlyoverSettings.debugLog("[FlyoverEditor]: refused span id=%s to id=%s: the route is %.0fm for %.0fm apart (%d waypoint(s)).",
                tostring(from), tostring(id), routeLength, straightLength, #span)
            self:warnPlayer("Those two points are only joined the long way round - pick points on the same stretch of track.")
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
    local direct, routeLength, straightLength = self:spanRouteIsDirect(span)
    if not direct then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: refused span end id=%s: the route is %.0fm for %.0fm apart (%d waypoint(s)).",
            tostring(id), routeLength, straightLength, #span)
        self:warnPlayer("That point is only joined to the span the long way round - the span was not changed.")
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
    if not self.moveFalloffOn and (self.moveBreakOn
        or (self.selectionCount > 0 and self:selectionChain() == nil)) then
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

            local newWp = ADFlyoverRecordWayPoint(fx, fy, fz, false, false, false, nil, flags, false)
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

end -- the block of local helpers opened above (Lua 5.1's 200-local limit)

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
        -- Not with a selection: a run-shaped one tapers to its own ends, a scattered one is rigid - no radius either way.
        -- One falloff value for every shape: a single point's reach, or - for a picked span / run or a
        -- run-shaped selection - the reach along it from the grabbed point (0 = taper to its own ends).
        -- Only a single point has a reach to set; spans, runs and selections taper to their own ends.
        if self.moveSelectMode == self.MOVE_SELECT.POINT and self.moveFalloffOn and self.moveOffsetChainIds == nil
            and self.selectionCount == 0 and self.moveSpanIds == nil then
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
function ADFlyoverEditor:toggleJunctionSwept()
    self.junctionSwept = not (self.junctionSwept ~= false)
    self.junctionPreviewKey = nil
    Logging.info("[FlyoverEditor]: junction swept-path prediction %s.",
        self.junctionSwept and "on (tow and trailer lines drawn on the locked site)" or "off")
end

function ADFlyoverEditor:toggleJunctionCheckObstacles()
    self.junctionCheckObstacles = not (self.junctionCheckObstacles ~= false)
    self.junctionPreviewKey = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction obstacle check %s.",
        self.junctionCheckObstacles and "on" or "off (corridors may pass through obstacles)")
end

--- Toggle the connector curve engine between Dubins (radius-bounded pose-to-pose) and the biarc.
function ADFlyoverEditor:toggleJunctionPattern()
    self.junctionPattern = (self.junctionPattern == "smooth") and "exact" or "smooth"
    self.junctionPreviewKey = nil
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction build layout: %s.", self.junctionPattern)
end

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
--- "build" lays new turns (the tool's original job); "clear" removes a junction's own wiring and
--- leaves the roads it joins in place - the tool's read of what belongs to the site (runs, lane
--- groups, the debris cluster) is identical either way, so this reuses it rather than being a
--- separate tool. Switching resets the preview key so the change takes effect immediately.
--- The junction radii, read through the PERSISTED setting so they survive a restart (see
--- Settings.lua). Editor state stays the live value; the setting is the thing that outlives the
--- session, and these two read/write it.
function ADFlyoverEditor:junctionRadiusValue()
    if self.junctionRadius == nil and ADFlyoverSettings ~= nil then
        self.junctionRadius = ADFlyoverSettings.get("junctionRadius") or 15
    end
    return self.junctionRadius or 15
end

function ADFlyoverEditor:setJunctionRadius(v)
    self.junctionRadius = math.max(AutoDrive.FLYOVER_JUNCTION_RADIUS_MIN,
        math.min(AutoDrive.FLYOVER_JUNCTION_RADIUS_MAX, v))
    if ADFlyoverSettings ~= nil then ADFlyoverSettings.setNearest("junctionRadius", self.junctionRadius) end
    self.junctionPreviewKey = nil
end

function ADFlyoverEditor:setJunctionTurnRadius(v)
    self.junctionTurnRadius = math.max(AutoDrive.FLYOVER_JUNCTION_TURN_MIN,
        math.min(AutoDrive.FLYOVER_JUNCTION_TURN_MAX, v))
    if ADFlyoverSettings ~= nil then ADFlyoverSettings.setNearest("junctionTurnRadius", self.junctionTurnRadius) end
    self.junctionPreviewKey = nil
end

function ADFlyoverEditor:toggleJunctionMode()
    -- build -> clear -> place (doc 08: place a whole X or T in one click) -> build.
    local nextMode = { build = "clear", clear = "place", place = "build" }
    self.junctionMode = nextMode[self.junctionMode or "build"] or "build"
    self.junctionPreviewKey = nil
    self.junctionPreview = nil
    local said = { build = "build (lays new turns)", clear = "clear (removes old wiring, leaves the roads)",
        place = "place (lays a whole X or T where roads cross)" }
    Logging.info("[FlyoverEditor]: junction tool set to %s.", said[self.junctionMode])
end

--- Clear mode only: at a T or a 4-way, the wiring that carries a road STRAIGHT THROUGH the crossing
--- is, structurally, exactly the same kind of "joins two different lanes" wiring as an actual turn -
--- the debris test alone cannot tell them apart. This spares it by BEARING: a cluster (or a direct
--- stale link) joining two lane groups whose approach bearings are within 40 deg of EACH OTHER (both
--- ends "heading the same way" - travel direction is recorded at both, so a road running straight
--- across shows near-identical bearings at its two ends) is continuing the road nearly straight, not
--- turning, and is left alone when this is on. Off clears
--- everything the site owns, the same as before this option existed.
--- Turn the debug capture on or off. Deliberately a toggle on the junction card rather than a
--- setting buried in a menu: it writes a copy of the whole network on every change, so it must be
--- obvious that it is running and obvious how to stop it.
function ADFlyoverEditor:toggleJunctionDebugCapture()
    AutoDrive.FLYOVER_DEBUG_CAPTURE = not (AutoDrive.FLYOVER_DEBUG_CAPTURE == true)
    -- Collecting starts HERE, not when a change starts, so the lock that leads to a change is in
    -- the same folder as the change.
    if AutoDrive.FLYOVER_DEBUG_CAPTURE then self:debugCaptureArm() else self:debugCaptureDisarm() end
    -- Asked of the capture itself, through a method, because everything it knows is a file-local
    -- declared further down this file - and a file-local named from above binds to a GLOBAL, which
    -- is a fault this file has already shipped once.
    local where, n = self:debugCaptureWhere()
    if AutoDrive.FLYOVER_DEBUG_CAPTURE then
        Logging.info("[FlyoverEditor]: debug capture ON. Every junction change writes the network before and after, plus this tool's log, into %s",
            where or "<nowhere yet>")
        if where == nil then
            Logging.warning("[FlyoverEditor]: debug capture - there is no savegame folder to write into yet. Save the game once, then it will record.")
        end
    else
        Logging.info("[FlyoverEditor]: debug capture OFF after %d change(s) recorded this session.", n or 0)
    end
end

function ADFlyoverEditor:toggleJunctionLeaveThrough()
    self.junctionLeaveThrough = not self.junctionLeaveThrough
    self.junctionPreviewKey = nil
    Logging.info("[FlyoverEditor]: junction clear will %s.",
        self.junctionLeaveThrough and "leave through paths in place" or "clear through paths too")
end

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
    local wp = ADFlyoverRecordWayPoint(
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

-- ONE FILE MAY HOLD ONLY 200 LOCAL NAMES AT ONCE (Lua 5.1). The local helpers from here to the
-- matching "end" are used nowhere after it, so they are scoped to this block and free their slots.
do
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
        local wp = ADFlyoverRecordWayPoint(p.x, y, p.z, true, dual, false, previousId, flags, false)
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
        if jp ~= nil and jp.clearMode then
            local leave = self.junctionLeaveThrough ~= false
            local nodes = (leave and jp.turnDebris or jp.debris) or {}
            local n = #nodes
            if self.junctionArmed ~= nil then
                if n > 0 then
                    return string.format(L("Site locked: will clear %d point(s). Right-click clears; left-click moves the lock."), n)
                end
                return L("Site locked, nothing here to clear. Right-click unlocks; left-click moves the lock.")
            end
            if n > 0 then
                return string.format(L("%d point(s) to clear here. Left-click locks the site; wheel = scope."), n)
            end
            return L("Point at a junction and left-click to lock it. Wheel = scope; right-click leaves the tool.")
        end
        if self.junctionMode == "place" then
            if jp ~= nil and jp.placeMode and jp.ok and jp.plan ~= nil then
                local what = string.format("%s %s", jp.plan.shape == "exact" and "mod" or tostring(jp.plan.shape),
                    tostring(jp.plan.kind))
                if self.junctionArmed ~= nil then
                    return string.format(L("Locked: right-click places the %s. Left-click moves the lock."), what)
                end
                return string.format(L("A %s goes here. Left-click locks it."), what)
            elseif jp ~= nil and jp.placeMode then
                return L("Nothing can be placed here - the card says why.")
            end
            return L("Point where roads cross and left-click to lock.")
        end
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
    local wp = ADFlyoverRecordWayPoint(position.x, y, position.z, true, dual, false, aId, flags, false)
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

end -- the block of local helpers opened above (Lua 5.1's 200-local limit)

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
        local wp = ADFlyoverRecordWayPoint(p.x, y, p.z, previousId ~= nil, segmentDual, false,
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

-- ROCK AND FIELDS ARE NOT ROAD. Road meshes on Riverbend are decoration with no collision, so nearly
-- every probe falls through to the paint below - and the paint's material is a tyre-SOUND class, not a
-- surface class. Material 7 (the asphalt sound) covers asphalt, concrete AND every rock paint; material
-- 1 (dirt) is also the dark mud painted under every field. So a turn across a rock face or a field
-- passed as road. The game's own AI drive-cost map tells them apart: it is built from each paint's
-- drive cost (asphalt and concrete 4, rock 12). Measured over the whole of Riverbend, 96% of asphalt and
-- concrete cells read under 150 (most 51; the rest are blocked by something standing there) and not one
-- rock cell does. The map exists on the server only, which is where edits run; without it, material 7
-- stays road as before. Fields come from the field layer, read the way the game's steering assist reads
-- it (AIAutomaticSteering.lua). See docs/junction-tool/03-data-sources.md.
local ROAD_DRIVE_COST_MAX = 150                                        -- on the map file's 0-255 scale

local function navigationCostAt(x, y, z)
    local ai = g_currentMission ~= nil and g_currentMission.aiSystem or nil
    if type(ai) ~= "table" or getVehicleNavigationMapCostAtWorldPos == nil then return nil end
    local navMap = ai.navigationMap
    if navMap == nil or navMap == 0 then return nil end
    local ok, cost, blocked = pcall(getVehicleNavigationMapCostAtWorldPos, navMap, x, y, z)
    if not ok or type(cost) ~= "number" then return nil end
    return cost, blocked == true
end

local function roadDriveCostMax()
    -- the engine's own scale, in case it is not the 0-255 the map file stores
    local scale = AISystem ~= nil and AISystem.COSTMAP_MAX_VALUE or nil
    if type(scale) == "number" and scale > 0 then
        return ROAD_DRIVE_COST_MAX * scale / 255
    end
    return ROAD_DRIVE_COST_MAX
end

local function isFieldAt(x, z)
    local detail = g_currentMission ~= nil and g_currentMission.terrainDetailId or nil
    if detail == nil or getDensityAtWorldPos == nil then return false end
    local ok, density = pcall(getDensityAtWorldPos, detail, x, 0, z)
    return ok and type(density) == "number" and density ~= 0
end
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
        if road and isFieldAt(x, z) then
            roadNote("field", "field ground under a probed spot; classed as not road")
            return false
        end
        if road and id == 7 then
            local cost, blocked = navigationCostAt(x, ty, z)
            if cost == nil then
                roadNote("nonav", "no drive-cost map (not the server?); asphalt-sound paint counts as road, rock included")
            elseif blocked then
                roadNote("blocked", "asphalt-sound paint marked blocked in the game's drive-cost map; classed as not road")
                return false
            elseif cost >= roadDriveCostMax() then
                roadNote("rock", "asphalt-sound paint with drive cost %d: rock, classed as not road", cost)
                return false
            end
        end
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
--- Index i of the chain segment (chain[i] -> chain[i+1]) that point (px,pz) lies on: the nearest
--- segment by true distance. Splitting a lane at a tie-in has to be done THIS way, by position
--- along the chain - not by testing each node with a dot product against its local direction. A
--- chain is long now and carries on through the junction and round whatever bends the road has on
--- the far side; out there a node can pass a "the tie-in is ahead of me" dot test again purely by
--- the way the road happens to point, and the assembled route then jumps to the far side and back.
local function junctionChainIndexNear(chain, px, pz)
    local bestI, bestD = 1, math.huge
    for i = 1, #chain - 1 do
        local a, b = chain[i], chain[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l2 = dx * dx + dz * dz
        local u = (l2 > 1e-9) and math.max(0, math.min(1, ((px - a.x) * dx + (pz - a.z) * dz) / l2)) or 0
        local d = (a.x + u * dx - px) ^ 2 + (a.z + u * dz - pz) ^ 2
        if d < bestD then bestD, bestI = d, i end
    end
    return bestI
end

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

--- A SET WALKED IN THE SAME ORDER EVERY TIME: by place on the map. pairs() over a set keyed by
--- point id comes back in an order set by the ids, and one keyed by the points themselves in an
--- order set by where they lie in memory. Every clear renumbers the points above each one it
--- removes, so clearing one junction changed the order at its neighbours - and wherever that order
--- picked a lane, a group's leader or the first of a list, the neighbour's clear came out
--- differently (clearing 30 and then 39 cut 39's road from the south). Keys are points or point
--- ids; each is placed by x, then z, then height, and two points on one spot by id. Any other key
--- (a string) sorts as itself after the points. Use in place of pairs() wherever the order can
--- reach a result; counting, summing and building another set need no order and keep pairs().
local function jxPlaceOf(k, v)
    if type(k) == "table" and k.x ~= nil then return k end
    if type(k) == "number" then
        if type(v) == "table" and v.x ~= nil and v.id == k then return v end
        return ADGraphManager:getWayPointById(k)
    end
    return nil
end
local function jxBeforeInPlace(a, b)
    if a.x ~= b.x then return a.x < b.x end
    if a.z ~= b.z then return a.z < b.z end
    if (a.y or 0) ~= (b.y or 0) then return (a.y or 0) < (b.y or 0) end
    return (a.id or 0) < (b.id or 0)
end
local function jxByPlace(t)
    local keys, at = {}, {}
    for k, v in pairs(t) do
        keys[#keys + 1] = k
        at[k] = jxPlaceOf(k, v) or false
    end
    table.sort(keys, function(a, b)
        local pa, pb = at[a], at[b]
        if pa and pb then
            if pa ~= pb then return jxBeforeInPlace(pa, pb) end
            return tostring(a) < tostring(b)
        end
        if pa then return true end
        if pb then return false end
        if type(a) == type(b) and (type(a) == "string" or type(a) == "number") then return a < b end
        return tostring(a) < tostring(b)
    end)
    -- A key emptied while the walk is under way is skipped, as pairs() would.
    local i = 0
    return function()
        while true do
            i = i + 1
            local k = keys[i]
            if k == nil then return nil end
            if t[k] ~= nil then return k, t[k] end
        end
    end
end

--- TWO LANES CROSSING, AT ONE POINT OR AT TWO. Where two lanes cross, a point of each can lie a few
--- cm from the other's, and folding such a pair (networkIntegritySweep's doubles) makes one point that
--- both lanes run through: two ways in, two ways out. Read as a fork, that point cut a turn in half
--- and moved 39's middle 3.4 m (the game's network had one, 0.23 m apart, folded before the session).
---
--- jxCrossingPairs(w): for a point with exactly two ways in and two ways out (none of them both), where
--- each way in carries straight on (30 degrees or less) to its own way out and the swapped pairing
--- would turn hard (45 or more), the way out for each way in, keyed by point. Otherwise nil: a real
--- fork, or a point too bent to say.
local function jxStraightTurn(a, w, b)
    local d = math.atan2(b.x - w.x, b.z - w.z) - math.atan2(w.x - a.x, w.z - a.z)
    while d > math.pi do d = d - 2 * math.pi end
    while d < -math.pi do d = d + 2 * math.pi end
    return math.abs(d)
end
local function jxCrossingPairs(w)
    if w == nil then return nil end
    local ins, outs, isIn = {}, {}, {}
    for _, id in ipairs(w.incoming or {}) do
        local v = ADGraphManager:getWayPointById(id)
        if v ~= nil and v ~= w and not isIn[v] then isIn[v] = true ins[#ins + 1] = v end
    end
    for _, id in ipairs(w.out or {}) do
        local v = ADGraphManager:getWayPointById(id)
        if v ~= nil and v ~= w then
            if isIn[v] then return nil end
            if outs[1] ~= v and outs[2] ~= v then outs[#outs + 1] = v end
        end
    end
    if #ins ~= 2 or #outs ~= 2 then return nil end
    local s11, s22 = jxStraightTurn(ins[1], w, outs[1]), jxStraightTurn(ins[2], w, outs[2])
    local s12, s21 = jxStraightTurn(ins[1], w, outs[2]), jxStraightTurn(ins[2], w, outs[1])
    local STRAIGHT, HARD = math.rad(30), math.rad(45)
    if math.max(s11, s22) <= STRAIGHT and math.min(s12, s21) >= HARD then
        return { [ins[1]] = outs[1], [ins[2]] = outs[2] }
    elseif math.max(s12, s21) <= STRAIGHT and math.min(s11, s22) >= HARD then
        return { [ins[1]] = outs[2], [ins[2]] = outs[1] }
    end
    return nil
end
--- jxLanesCross(a, b): a and b each carry one lane straight through (one way in, one way out, 30
--- degrees or less), are not wired to each other or to a shared neighbour, and their lanes lie on
--- lines 30 degrees or more apart - two lanes crossing, not one point laid twice. A lane end lying on a
--- lane, or a lane laid twice along itself, is not this, and still folds.
local function jxLanesCross(a, b)
    local function pass(w)
        local i, o = w.incoming or {}, w.out or {}
        if #i ~= 1 or #o ~= 1 or i[1] == o[1] then return nil end
        local p, q = ADGraphManager:getWayPointById(i[1]), ADGraphManager:getWayPointById(o[1])
        if p == nil or q == nil or jxStraightTurn(p, w, q) > math.rad(30) then return nil end
        return p, q
    end
    local pa, qa = pass(a)
    local pb, qb = pass(b)
    if pa == nil or pb == nil then return false end
    if pa == b or qa == b or pb == a or qb == a or pa == pb or qa == qb or pa == qb or qa == pb then
        return false
    end
    local d = math.atan2(qa.x - pa.x, qa.z - pa.z) - math.atan2(qb.x - pb.x, qb.z - pb.z)
    d = math.abs(d) % math.pi
    if d > math.pi / 2 then d = math.pi - d end
    return d >= math.rad(30)
end

--- How far a way on from a fork has TURNED by the time it next meets something, in radians.
---
--- The branch is followed from `first`, straightest way on at each node, until it reaches the next
--- FORK (a node with three or more distinct neighbours), a dead end, or `reach` metres; the heading
--- it arrives on is compared with the heading (hx, hz) the lane had coming into the fork.
---
--- A lane's own road arrives at the next tie node still going the lane's way. A turn connector
--- arrives at ITS next tie node - where it joins the other road - going that road's way: turned by
--- the whole angle of the turn, however gently it set off. That matters because the tool lays its
--- connectors tangent-continuous and starts its kickouts early, so AT the fork a connector and the
--- road cannot be told apart by bearing; where they next join something, they cannot be confused.
--- Stopping at the next fork also keeps the verdict LOCAL: a road that carries on to a T and then
--- has to turn is not judged by what happens at the T.
local function junctionBranchTurn(from, first, useOut, hx, hz, reach)
    local function degree(w)
        local seen, n = {}, 0
        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, id in pairs(lst) do
                if not seen[id] then seen[id] = true n = n + 1 end
            end
        end
        return n
    end
    local prev, node = from, first
    local dx, dz = first.x - from.x, first.z - from.z
    local run = math.sqrt(dx * dx + dz * dz)
    if run < 1e-6 then return 0 end
    local tx, tz = dx / run, dz / run
    for _ = 1, 200 do
        if run >= reach or degree(node) >= 3 then break end
        local list = useOut and (node.out or {}) or (node.incoming or {})
        local best, bestDot = nil, -math.huge
        for _, nid in pairs(list) do
            if nid ~= prev.id then
                local nx = ADGraphManager:getWayPointById(nid)
                if nx ~= nil then
                    local ex, ez = nx.x - node.x, nx.z - node.z
                    local el = math.sqrt(ex * ex + ez * ez)
                    if el > 1e-6 then
                        local dot = (ex / el) * tx + (ez / el) * tz
                        if dot > bestDot then bestDot, best = dot, nx end
                    end
                end
            end
        end
        if best == nil then break end
        local ex, ez = best.x - node.x, best.z - node.z
        local el = math.sqrt(ex * ex + ez * ez)
        tx, tz = ex / el, ez / el
        run = run + el
        prev, node = node, best
    end
    return math.acos(math.max(-1, math.min(1, tx * hx + tz * hz)))
end

-- Deterministic link primitives - NOT toggles. AutoDrive's toggleConnectionBetween flips state (its
-- remove branch fires on an OR of two list checks and its insert never checks for duplicates), so
-- anything built on it can leave a link in a state nobody asked for when an operation re-enters the
-- same pair - a repeat placement over the same spot, an undo/redo interleave. That is the class of
-- bug that minted two-way ("blue") links on one-way roads. These two are idempotent and explicit:
-- calling them twice is the same as calling them once, and the resulting state is exactly what the
-- arguments say, regardless of what was there before.
-- WHERE THE JUNCTION ENDS, IN ONE PLACE. Every deletion a clear makes goes through jxRemove, and
-- jxRemove is the only thing that decides whether a point belongs to the junction being worked on.
--
-- Before this there were fourteen places that removed a waypoint, at three different stages, each
-- with its own idea of how far the junction reached - which is why the reach came out at 12, 45, 50
-- or 75 m depending which one was asked, and why a clear at one site took thirty points out to 73 m.
--
-- The bound is not a radius. A junction is not round: its arms reach different distances, and a
-- circle big enough for the longest one swallows the neighbours of the shortest. So each ARM is
-- allowed out to its own first fork - that is where the next junction starts, and nothing past it
-- was ever this junction's to take - with a cap for an arm that runs on across the map, and a core
-- around the middle that is always allowed so the box itself is never gated.
local jxBound, jxBlocked, jxTook, jxFarthest = nil, 0, 0, 0
local jxWired = 0
-- THE JUNCTION TOOL'S STATE THAT IS ASSIGNED AGAIN AFTER ITS DECLARATION (docs/editor-modules-spec.md,
-- phase 1). These were file-level locals. Once the editor is split into modules, a file can't assign
-- another file's local, and an alias would keep the old value, so each is a field of this one table,
-- under its old name.
local jxState = {}
jxState.jxWhy = {}   -- per reason: how many taken, and the farthest of them
-- WAS IT ALREADY LOOSE, AND DID WE CUT IT ON PURPOSE. Two things the clear knows exactly, and
-- between them they say which loose ends are its business. No distance can answer this: a junction
-- cleared earlier keeps no forks to be recognised by, and its branches sit well inside any radius
-- wide enough to be useful.
jxState.jxWasLoose, jxState.jxCut, jxState.jxExisted = nil, nil, nil
local jxForeignForks   -- defined below, used by jxBegin
-- WHICH KEPT THROUGH ROAD EACH POINT IS ON, while a clear with through roads kept is running (nil
-- otherwise): point -> the number of its road in the preview's through routes. The integrity sweep
-- folds two points closer than 0.3 m into one, and where two kept roads cross that fold joins them:
-- at 16 the crossing points of the two roads already lay 0.06-0.26 m apart, at 30 the respacing
-- drew two of them to 0.28 m - and each fold let a lane in on one road drive out on the other.
-- The user's default is that kept roads pass through each other without sharing a point.
jxState.jxKeptRoad = nil
-- HOW FAR PAST THE BOUND A TURN TAKEN WHOLE MAY REACH: every point of it outside the bound must lie
-- within this many metres of one of its own points inside. A turn is taken whole so that its ends
-- go with it (36: ends 13-15 m out, a few metres past the bound), but taking it whole skips the
-- bound's own limits, so this keeps a long piece from running on out along a road unchecked. The
-- check after a clear uses the same figure, so it still reports a piece that reached further.
local JX_WHOLE_PIECE_REACH = 8
-- ANOTHER PART'S TURN, LEFT WORKING (split junctions; the user's rules of 2026-10-03, doc 04, "Split
-- junctions: clearing one part"). While the clear of a part of a split the user saved is running:
-- every point of another part's turn that lies in this part's area, the points where it leaves and
-- joins the road, and the stretch of that road kept for it (junctionTwinTurns, junctionTidyByPaths). The
-- one remover, jxRemove, refuses them, as the bound refuses a point outside the junction; nil
-- otherwise. jxTwinHeld counts what it refused.
jxState.jxTwinKeep, jxState.jxTwinHeld = nil, 0
-- How far before another part's turn the cut lane starts again (or after it, ends): enough road for
-- a vehicle to be on the lane before it turns off. Metres; less where this part's middle is nearer.
local JX_TWIN_LEAD = 5
local function jxKeptRoadsOf(jp, leave)
    if not leave or jp == nil or jp.pathRoutes == nil then return nil end
    local m = {}
    for i, nodes in ipairs(jp.pathRoutes.through or {}) do
        for _, n in ipairs(nodes) do
            if m[n] == nil then m[n] = i end
        end
    end
    return m
end

-- THE CLEAR'S OWN RECORD OF WHAT IT CHANGED, one entry per edit, in the order it made them. The
-- check that runs after a clear compares the network before and after, and every difference has to
-- be one of these: a change nobody recorded is a change no stage meant to make. Comparing alone
-- could only say THAT something changed; the record says which stage did it, so a stage that
-- reaches too far can be named. Only ever written to while a clear is running (jxJournal is nil
-- otherwise), and only ever read by the check - nothing in the clear decides anything from it.
-- Entries: op = "add" / "remove" / "move" / "out+" / "out-" / "in+" / "in-", a = the point, b =
-- the other end of a link, stage = which part of the clear, x/y/z = where the point stood when the
-- entry was made: where it was laid, where it was removed from, or - for a move - where it stands
-- AFTER the move (the check replays the moves in order, so each one is measured from the last).
jxState.jxJournal, jxState.jxStage = nil, nil
-- True while the respacing is rebuilding a run, whichever stage called it: the respacing has a reach
-- of its own (FLYOVER_JUNCTION_RESPACE_LEN), and the tidy calls it too, to smooth a through road.
jxState.jxInRespace = false
-- The stretch the respacing is rebuilding at the moment: where its points stood, and how far along
-- its lane from the lane's end it starts. Lets the check tell a stretch running out of the junction
-- (allowed: it ends on the first point past the edge) from one lying wholly outside it (not).
jxState.jxRespaceRun = nil

local function jxNote(op, a, b, why)
    if jxState.jxJournal == nil or a == nil then return end
    jxState.jxJournal[#jxState.jxJournal + 1] = { op = op, a = a, b = b, stage = jxState.jxStage or "?", why = why,
        respace = jxState.jxInRespace, run = jxState.jxRespaceRun, x = a.x, y = a.y, z = a.z }
end

--- A point the clear has just laid. Nil-safe, so it can follow any creation call unguarded.
--- The points the current BUILD has created, as a set of point tables (ids shift when stubs are
--- removed, tables do not). Nil outside a build. Filled here so every way a build adds a point -
--- laying a turn, splicing a tie-in, sharing a crossing - is counted without each having to remember.
jxState.jxBuildNew = nil
--- Every link that existed when the current build started, as oldLinks[from][to] = true on point
--- tables. A build can lay a turn straight between two existing points, so "has a new end" is not
--- the same as "is new". Nil outside a build.
local jxBuildOldLinks = nil

--- The one point every left turn of the current build runs through (see junctionTrackConnector's
--- left turns through the centre). Made by the first left turn laid, reused by the rest.
jxState.jxCentreNode = nil
--- What each point the current build laid is part of, for the harness's route study: "L90" / "R90"
--- (a left or right turn of that many degrees), "tie" (a tie-in spliced into a lane), "x" (a shared
--- crossing). jxLayLabel is the label of the turn being laid at the moment. Report only.
jxState.jxNodeLabel, jxState.jxLayLabel = nil, nil
--- The same for each LINK the build laid, jxLinkLabel[from][to] = label: a link spliced at a crossing keeps
--- the label of the link it was cut from, so the study can tell which turn a driver is on. Report only.
jxState.jxLinkLabel = nil
jxState.jxLaySeq = 0   -- numbers each turn of a build, so two turns of the same shape are told apart

local function jxBuildBegin()
    jxState.jxBuildNew, jxBuildOldLinks = {}, {}
    jxState.jxCentreNode = nil
    jxState.jxNodeLabel, jxState.jxLayLabel, jxState.jxLinkLabel = {}, nil, {}
    jxState.jxLaySeq = 0
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if a ~= nil and a.id ~= nil and #(a.out or {}) > 0 then
            local s = {}
            for _, bid in ipairs(a.out) do
                local b = ADGraphManager:getWayPointById(bid)
                if b ~= nil then s[b] = true end
            end
            jxBuildOldLinks[a] = s
        end
    end
end

local function jxBuildEnd()
    jxState.jxBuildNew, jxBuildOldLinks, jxState.jxCentreNode = nil, nil, nil
    jxState.jxNodeLabel, jxState.jxLayLabel, jxState.jxLinkLabel = nil, nil, nil
end

--- "L90" / "R45" for a connector: which way it turns and by how much, from its first and last legs.
local function jxTurnLabel(c)
    local pts = c.points or {}
    if #pts == 0 then return "S" end
    local ux, uz = pts[1].x - c.ax, pts[1].z - c.az
    local vx, vz = c.bx - pts[#pts].x, c.bz - pts[#pts].z
    local nu, nv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
    if nu < 1e-6 or nv < 1e-6 then return "S" end
    local ang = math.deg(math.acos(math.max(-1, math.min(1, (ux * vx + uz * vz) / (nu * nv)))))
    if ang < 20 then return "S" end
    return string.format("%s%.0f", ((ux * vz - uz * vx) < 0) and "L" or "R", ang)
end

local function jxIsNewLink(a, b)
    if jxBuildOldLinks == nil then return false end
    local s = jxBuildOldLinks[a]
    return s == nil or s[b] ~= true
end

local function jxNoteAdded(w)
    if w ~= nil then jxNote("add", w) end
    if w ~= nil and jxState.jxBuildNew ~= nil then jxState.jxBuildNew[w] = true end
    if w ~= nil and jxState.jxNodeLabel ~= nil and jxState.jxNodeLabel[w] == nil then jxState.jxNodeLabel[w] = jxState.jxLayLabel or "tie" end
end

--- A point the clear has just moved, recorded where it now stands.
local function jxNoteMoved(w)
    if w ~= nil then jxNote("move", w) end
end

--- A clear runs start to finish inside one call, so a record still open when the next frame starts
--- belongs to a clear that stopped with an error before it could close it (applyJunction calls the
--- clear unguarded). Closed from the editor's update, so the edits of whatever tool comes next are
--- not piled into it until the next clear resets it. Memory only: nothing reads the record outside
--- a clear's own check.
function ADFlyoverEditor:junctionCheckRecordOff()
    if jxState.jxJournal ~= nil then
        jxState.jxJournal, jxState.jxStage, jxState.jxInRespace, jxState.jxRespaceRun = nil, nil, false, nil
    end
end

--- The whole network as it stands: where every point is and what it is linked to, held by the
--- points themselves, because every removal reissues the ids above it. The whole network and not a
--- circle round the site, so a change made anywhere is seen. Only the check after a clear reads it.
local function jxSnapshot()
    local snap = {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil then
            local out, inn = {}, {}
            for _, id in ipairs(w.out or {}) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil then out[#out + 1] = t end
            end
            for _, id in ipairs(w.incoming or {}) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil then inn[#inn + 1] = t end
            end
            snap[w] = { x = w.x, y = w.y, z = w.z, out = out, inn = inn }
        end
    end
    return snap
end

--- The through roads the clear found, as lines on the map, read before any of them is cut or
--- respaced, with the points each one starts and ends at.
local function jxRouteLines(jp)
    local lines = {}
    local through = (jp ~= nil and jp.pathRoutes ~= nil) and jp.pathRoutes.through or nil
    for _, nodes in ipairs(through or {}) do
        local pts = {}
        for _, n in ipairs(nodes) do pts[#pts + 1] = { x = n.x, z = n.z } end
        if #pts >= 2 then lines[#lines + 1] = { pts = pts, first = nodes[1], last = nodes[#nodes] } end
    end
    return lines
end

--- AUTODRIVE'S OWN RIGHT-OF-WAY RULE, the teal dot: a point two or more roads lead into and at least
--- one leads out of, less three shapes that only change road type. Copied from AutoDrive 3.0.1.2
--- (Specialization.lua, getWayPointsInRange). It found 24 links our own counts had called cleared.
local function jxRightOfWayLists(out, inc)
    if #out < 1 or #inc < 2 then return false end
    local singleIn, singleOut, dual = 0, 0, 0
    for _, i in pairs(inc) do
        if table.contains(out, i) then dual = dual + 1 else singleIn = singleIn + 1 end
    end
    for _, o in pairs(out) do
        if not table.contains(inc, o) then singleOut = singleOut + 1 end
    end
    if dual == 1 and singleIn == 1 and singleOut == 0 then return false end
    if dual == 1 and singleIn == 0 and singleOut == 1 then return false end
    if dual == 2 and singleIn == 0 and singleOut == 0 then return false end
    return true
end

local function jxRightOfWay(w)
    return jxRightOfWayLists(w.out or {}, w.incoming or {})
end

--- One-ended: something leads in and nothing out, or the other way about.
local function jxLoose(w)
    local nOut, nIn = #(w.out or {}), #(w.incoming or {})
    return (nOut == 0) ~= (nIn == 0)
end

--- Mark a point as having been cut FROM something on purpose. Rejoining it would undo the work.
local function jxMarkCut(w)
    if jxState.jxCut ~= nil and w ~= nil then jxState.jxCut[w] = true end
end

--- Begin a clear: nothing may be deleted outside `site` until jxEnd.
local function jxBegin(site)
    jxBound, jxBlocked, jxTook, jxFarthest, jxWired = site, 0, 0, 0, 0
    jxState.jxTwinKeep, jxState.jxTwinHeld = nil, 0
    jxState.jxWhy = {}
    jxForeignForks(site)
    -- Everything already hanging loose before this clear touched anything. Whatever left these ends
    -- this way - a clear done an hour ago, a route half drawn by hand - it was not us, so it is not
    -- ours to put back.
    jxState.jxWasLoose, jxState.jxCut, jxState.jxExisted = {}, {}, {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil then
            jxState.jxExisted[w] = true
            if jxLoose(w) then jxState.jxWasLoose[w] = true end
        end
    end
end

--- End a clear, and say how much was held back. Anything blocked is worth knowing about: it is
--- either the bound doing its job, or the bound being wrong, and both want looking at.
--- Returns what was held back, what was actually taken, and how far out the farthest one was.
--- COUNTED HERE BECAUSE NOWHERE ELSE CAN COUNT IT. Comparing the graph before and against after
--- cannot: asking whether an id still points at the same node counts survivors as deleted, because
--- every removal renumbers the ids above it; and asking whether anything still stands in a node's
--- old place counts points the respacing MOVED. Both were tried, and both put the reach of a clear
--- at 75 m where the truth is a couple of dozen points inside the junction. This is the one place a
--- deletion happens, so it is the one place the number is real.
local function jxEnd()
    local held, took, far = jxBlocked, jxTook, jxFarthest
    jxBound, jxBlocked, jxTook, jxFarthest = nil, 0, 0, 0
    jxState.jxTwinKeep = nil
    return held, took, far
end

--- Does (x, z) belong to `site`? The bound itself, for any site: the check after a clear asks it of
--- the site that was cleared, after jxEnd has let go of jxBound.
local function jxSiteHas(site, x, z)
    -- No site means this is not a bounded clear (build mode, the console, a tool that never had a
    -- site). Unbounded, exactly as before - this gate only ever tightens a clear.
    if site == nil or site.roads == nil or #site.roads == 0 then return true end
    local dx, dz = x - site.x, z - site.z
    local d2 = dx * dx + dz * dz
    local core = AutoDrive.FLYOVER_JUNCTION_CLEAR_SCOPE or 12
    if d2 <= core * core then return true end
    local d = math.sqrt(d2)
    -- The arm this point lies along, and how far that arm runs before the next junction.
    local b = math.deg(math.atan2(dx, dz)) % 360
    local best, bestSep = nil, math.huge
    for _, r in ipairs(site.roads) do
        local rb = math.deg(r.bearing) % 360
        local s = math.abs(b - rb) % 360
        if s > 180 then s = 360 - s end
        if s < bestSep then bestSep, best = s, r end
    end
    -- Nowhere near any arm of this junction: not ours.
    if best == nil or bestSep > 60 then return false end
    -- WHERE THE ARM RAN INTO ANOTHER JUNCTION, STOP SHORT OF IT. The walk reports the distance TO
    -- that fork, and a margin on top of it reaches past the fork and into the junction beyond - which
    -- is how clearing one of a close pair took the other one's points while reporting that it had
    -- held nothing back. The margin is only for an arm that ran out of walk without meeting
    -- anything: there a road's far lane really does sit off the arm's bearing and wants the room.
    local lim = best.len or 0
    if best.fork then lim = math.max(0, lim - 2) else lim = lim + 4 end
    return d <= lim
end

local function jxMayDelete(x, z) return jxSiteHas(jxBound, x, z) end

--- Does this point belong to the junction being worked on? The same question the deletions ask,
--- asked by anything else that must not wander into the junction next door.
local function jxInSite(x, z) return jxMayDelete(x, z) end

--- Did THIS clear cut this point off from something? The gate marks every point it severs on
--- purpose, so anything else lying loose nearby was already like that when the clear began.
local function jxWasCutByUs(w)
    return jxState.jxCut ~= nil and w ~= nil and jxState.jxCut[w] == true
end

--- The one way a clear removes a waypoint. Takes an id or the node itself; the node is safer, since
--- every removal renumbers the ids above it. `whole` is for a piece of turn wiring the caller has
--- already found reaches into the junction and ends at the lane forks: it is taken whole, even the
--- part lying past the bound (see the removal of turn wiring in applyJunctionClear).
local function jxRemove(which, why, whole)
    local w = which
    if type(w) ~= "table" then w = ADGraphManager:getWayPointById(which) end
    if w == nil or w.id == nil then return false end
    if not whole and not jxMayDelete(w.x, w.z) then
        jxBlocked = jxBlocked + 1
        return false
    end
    -- Another part's turn left working, and the road it needs (jxTwinKeep): never, whole or not.
    if jxState.jxTwinKeep ~= nil and jxState.jxTwinKeep[w] then
        jxState.jxTwinHeld = jxState.jxTwinHeld + 1
        return false
    end
    local site = jxBound
    if site ~= nil then
        local d = math.sqrt((w.x - site.x) ^ 2 + (w.z - site.z) ^ 2)
        if d > jxFarthest then jxFarthest = d end
        local e = jxState.jxWhy[why or "?"] or { n = 0, far = 0 }
        e.n = e.n + 1
        if d > e.far then e.far = d end
        jxState.jxWhy[why or "?"] = e
    end
    jxTook = jxTook + 1
    -- Whatever this point was joined to is now an end, and on purpose.
    for _, id in ipairs(w.out or {}) do jxMarkCut(ADGraphManager:getWayPointById(id)) end
    for _, id in ipairs(w.incoming or {}) do jxMarkCut(ADGraphManager:getWayPointById(id)) end
    jxNote("remove", w, nil, why)
    return tryCall(why or "junction remove", function()
        ADGraphManager:removeWayPoint(w.id, false)
    end) == true
end

--- NO CLEAR MAY WIRE UP A JUNCTION THAT IS NOT THE ONE IT WAS ASKED TO WORK ON. Several stages make
--- links - a chain being tied back to the road, two doubled points being folded together, a lane end
--- run out to the box, the respacing bridging over what it removes - and NONE of them can tell a
--- deliberate cut from damage. At a junction already cleared, every severed branch looks like
--- something to join up, so clearing one of a close pair put the other one back together. Fixing
--- those stages one at a time fixed nothing: there was always another one.
---
--- So link-making is gated in one place, exactly as deleting is. During a clear, no link may be made
--- at a point belonging to ANOTHER junction - that junction's wiring is not this one's business.
local jxForeign = nil
--- Were these two already joined, by a run of plain road? Then a link between them is a BRIDGE -
--- what the respacing lays over the points it is about to take out - and adds nothing that was not
--- there before.
local function jxAlreadyJoined(a, b)
    for _, dir in ipairs({ "out", "incoming" }) do
        local cur, seen = a, { [a] = true }
        for _ = 1, 16 do
            local nxt = nil
            for _, id in ipairs(cur[dir] or {}) do
                local w = ADGraphManager:getWayPointById(id)
                if w == b then return true end
                if w ~= nil and not seen[w] and nxt == nil then nxt = w end
            end
            if nxt == nil then break end
            seen[nxt] = true
            cur = nxt
        end
    end
    return false
end

local function jxMayLink(a, b)
    if true then return true end   -- gate retired: it cut lanes in half two different ways
    if jxBound == nil or jxForeign == nil then return true end
    -- A BRIDGE IS NOT NEW WIRING. This gate exists to stop a clear joining something ONTO a
    -- neighbouring junction, and it was also refusing the respacing's bridges where a lane runs up
    -- to the neighbour's tie node: the bridge was refused, the points it was to replace were taken
    -- out regardless, and the lane between two junctions was left cut in half - in game, the road
    -- between a pair of junctions, severed one node short of the second.
    if jxAlreadyJoined(a, b) then return true end
    -- Tight on purpose. This has to catch a link being made ONTO a neighbouring junction's own
    -- points, not every link that passes near one: at a site whose neighbours sit close by, a
    -- generous radius refused the lane links the clear itself needed and left ten links running
    -- across its box.
    local R = AutoDrive.FLYOVER_JUNCTION_LINK_GATE_R or 3
    for _, f in ipairs(jxForeign) do
        if (f.x - a.x) ^ 2 + (f.z - a.z) ^ 2 <= R * R
            or (f.x - b.x) ^ 2 + (f.z - b.z) ^ 2 <= R * R then
            jxWired = (jxWired or 0) + 1
            return false
        end
    end
    return true
end

--- The fork points near this site that are NOT its own: the junctions next door. Worked out once per
--- clear, from the site's own fork list, so it does not depend on how the survey happens to group
--- them - it numbers a close pair as one, which is exactly the case this has to tell apart.
function jxForeignForks(site)
    jxForeign = {}
    if AutoDrive.FLYOVER_JUNCTION_LINK_GATE == false then jxForeign = nil return end
    if site == nil or site.forks == nil then return end
    local mine = {}
    for _, f in ipairs(site.forks) do mine[f] = true end
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and not mine[w] and (w.x - site.x) ^ 2 + (w.z - site.z) ^ 2 <= 80 * 80 then
            local nb, deg = {}, 0
            for _, t in ipairs(w.out or {}) do nb[t] = true end
            for _, fid in ipairs(w.incoming or {}) do nb[fid] = true end
            for _ in pairs(nb) do deg = deg + 1 end
            -- far enough from this junction's middle that it cannot be one of its own tie points
            if deg >= 3 and (w.x - site.x) ^ 2 + (w.z - site.z) ^ 2 > 13 * 13 then
                jxForeign[#jxForeign + 1] = { x = w.x, z = w.z }
            end
        end
    end
end

local function junctionConnect(a, b, dual)
    if a ~= nil and b ~= nil and not jxMayLink(a, b) then return end
    if a == nil or b == nil or a.id == b.id then return end
    if not table.contains(a.out, b.id) then table.insert(a.out, b.id) jxNote("out+", a, b) end
    if not table.contains(b.incoming, a.id) then table.insert(b.incoming, a.id) jxNote("in+", b, a) end
    if jxState.jxLinkLabel ~= nil and jxState.jxLayLabel ~= nil and jxState.jxLayLabel ~= "x" then
        jxState.jxLinkLabel[a] = jxState.jxLinkLabel[a] or {}
        jxState.jxLinkLabel[a][b] = jxState.jxLayLabel
        if dual then
            jxState.jxLinkLabel[b] = jxState.jxLinkLabel[b] or {}
            jxState.jxLinkLabel[b][a] = jxState.jxLayLabel
        end
    end
    if dual then
        if not table.contains(b.out, a.id) then table.insert(b.out, a.id) jxNote("out+", b, a) end
        if not table.contains(a.incoming, b.id) then table.insert(a.incoming, b.id) jxNote("in+", a, b) end
    end
end

-- Remove every connection between a and b, both directions, unconditionally.
local function junctionDisconnect(a, b)
    if a == nil or b == nil then return end
    jxMarkCut(a)
    jxMarkCut(b)
    -- Recorded only where there was something to remove, so the record says what changed.
    if jxState.jxJournal ~= nil then
        if table.contains(a.out, b.id) then jxNote("out-", a, b) end
        if table.contains(b.incoming, a.id) then jxNote("in-", b, a) end
        if table.contains(b.out, a.id) then jxNote("out-", b, a) end
        if table.contains(a.incoming, b.id) then jxNote("in-", a, b) end
    end
    table.removeValue(a.out, b.id)
    table.removeValue(b.incoming, a.id)
    table.removeValue(b.out, a.id)
    table.removeValue(a.incoming, b.id)
    if jxState.jxLinkLabel ~= nil then
        if jxState.jxLinkLabel[a] ~= nil then jxState.jxLinkLabel[a][b] = nil end
        if jxState.jxLinkLabel[b] ~= nil then jxState.jxLinkLabel[b][a] = nil end
    end
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
        local wp
        -- A left turn's centre point is the SAME point for every left turn of this build: that one
        -- shared point is what makes AutoDrive take left turns one at a time, and the 90 degrees
        -- between their headings there is what stops it hopping from one to another.
        if p.centre and jxState.jxCentreNode ~= nil and jxState.jxCentreNode.id ~= nil
            and ADGraphManager:getWayPointById(jxState.jxCentreNode.id) == jxState.jxCentreNode then
            wp = jxState.jxCentreNode
        else
            wp = ADFlyoverRecordWayPoint(p.x, p.y, p.z, false, false, false, 0,
                flags or AutoDrive.FLAG_NONE, false)
            jxNoteAdded(wp)
            if wp == nil then return false end
            if p.centre and jxState.jxBuildNew ~= nil then jxState.jxCentreNode = wp end
        end
        junctionConnect(prev, wp, dual)
        prev = wp
    end
    junctionConnect(prev, NB, dual)
    return true
end

-- EVERY CROSSING IS A SHARED POINT (docs/junction-tool/06-one-click-build.md, layout rule 1).
-- AutoDrive only makes a driver wait where two routes share a point (CollisionDetectionModule:
-- detectAdTrafficOnRoute matches point ids), so two paths that cross in open space are invisible to
-- it. After a build has laid its turns, every place where one of its new links crosses another link
-- near the junction gets one point that both links run through.
--   * A crossing within SNAP of an existing end of either link reuses that point instead of stacking
--     a new one beside it.
--   * Links more than 2 m apart in height where they cross are left alone: a road over a bridge is
--     not a crossing.
--   * One crossing is resolved at a time and the search starts again, since every splice changes the
--     links around it.
-- Returns how many crossings it joined.
jxState.jxShallowJoins = 0

-- SQUARE UP A SHALLOW CROSSING. AutoDrive refuses to switch paths at a shared point only where the
-- bend is over 80 degrees, so two paths crossing at 55 degrees let a driver hop from one to the other.
-- Here the NEW path (p -> N -> q) gets a small S-bend: one extra point either side of N, up to a metre
-- out, on the line square to the path it crosses. It then meets that path at 90 degrees (a two-way
-- path counts both ways round, so it must sit near 90 from both sides). The line moves well under a
-- metre; road lanes are never bent, since only a path this build laid comes here.
-- sq = { p, N, q, dual = our path two-way, vx, vz = the crossed path's direction, otherDual }
jxState.jxSquaredJoins = 0
-- Points the squaring made or moved this build. They never move (again): a moved point's other link can
-- cross something new, and moving the next one along would walk a chain of moves across the junction.
local jxSquareMade = {}
-- Points the sharing slid onto a crossing this build. They never slide again.
local jxSlid = {}

--- A point this build laid on one of its own paths with nothing else joined to it: one link each way (or
--- a two-way link to each of the same two neighbours). Such a point can move without touching anything
--- but its own path.
local function jxPlainOurs(s)
    if jxState.jxBuildNew == nil or not jxState.jxBuildNew[s] or s == jxState.jxCentreNode or jxSquareMade[s] or jxSlid[s] then return false end
    local nb = {}
    for _, id in ipairs(s.out or {}) do nb[id] = true end
    for _, id in ipairs(s.incoming or {}) do nb[id] = true end
    local n = 0
    for _ in pairs(nb) do n = n + 1 end
    local o, i = #(s.out or {}), #(s.incoming or {})
    return n == 2 and o == i and (o == 1 or o == 2)
end

local function junctionSquareUp(sq)
    local p, N, q = sq.p, sq.N, sq.q
    if p == nil or q == nil or N == nil or p == N or q == N or p == q then return false end
    local ux, uz = q.x - p.x, q.z - p.z
    local nu = math.sqrt(ux * ux + uz * uz)
    local nv = math.sqrt(sq.vx * sq.vx + sq.vz * sq.vz)
    if nu < 1e-6 or nv < 1e-6 then return false end
    ux, uz = ux / nu, uz / nu
    local vx, vz = sq.vx / nv, sq.vz / nv
    local ang = math.deg(math.acos(math.max(-1, math.min(1, ux * vx + uz * vz))))
    -- Nearly parallel paths are left alone: turning ours square across one would zigzag it over the
    -- other again and again.
    if ang < 30 or ang > 150 then return false end
    -- The bends a driver would really take at N, switching between our path and any other link there.
    -- A snap through a point beside the crossing bends our own path, so the crossing angle alone can
    -- say 85 where the switch is 55. 5 degrees of margin on AutoDrive's 80.
    local function bend(a, b, c)
        local x1, z1, x2, z2 = b.x - a.x, b.z - a.z, c.x - b.x, c.z - b.z
        local n1, n2 = math.sqrt(x1 * x1 + z1 * z1), math.sqrt(x2 * x2 + z2 * z2)
        if n1 < 1e-6 or n2 < 1e-6 then return 180 end
        return math.deg(math.acos(math.max(-1, math.min(1, (x1 * x2 + z1 * z2) / (n1 * n2)))))
    end
    local function others(list)
        local t = {}
        for _, id in ipairs(list or {}) do
            local w = ADGraphManager:getWayPointById(id)
            if w ~= nil and w ~= p and w ~= q then t[#t + 1] = w end
        end
        return t
    end
    local ins, outs = others(N.incoming), others(N.out)
    local shallow = false
    for _, o in ipairs(outs) do
        if bend(p, N, o) <= 85 or (sq.dual and bend(q, N, o) <= 85) then shallow = true end
    end
    for _, i in ipairs(ins) do
        if bend(i, N, q) <= 85 or (sq.dual and bend(i, N, p) <= 85) then shallow = true end
    end
    if not shallow then return false end
    -- The crossed path bends a little at N too when it is a curve: square to the average of its way
    -- in and way out, so both switches come out near 90, not one at 81.
    if #ins == 1 and #outs == 1 and ins[1] ~= outs[1] then
        local i, o = ins[1], outs[1]
        local ax, az = N.x - i.x, N.z - i.z
        local bx, bz = o.x - N.x, o.z - N.z
        local na, nb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
        if na > 1e-6 and nb > 1e-6 then
            local mx, mz = ax / na + bx / nb, az / na + bz / nb
            local nm = math.sqrt(mx * mx + mz * mz)
            if nm > 1e-6 then vx, vz = mx / nm, mz / nm end
        end
    end
    -- Square to the crossed path, on the side our path already runs.
    local sx, sz = -vz, vx
    if sx * ux + sz * uz < 0 then sx, sz = -sx, -sz end
    local flags = N.flags or AutoDrive.FLAG_NONE
    if jxState.jxBuildNew[p] then flags = p.flags elseif jxState.jxBuildNew[q] then flags = q.flags end
    local label = nil
    if jxState.jxLinkLabel ~= nil then label = (jxState.jxLinkLabel[p] or {})[N] or (jxState.jxLinkLabel[N] or {})[q] end
    local bent = false
    -- A point of our own path with nothing else joined to it: one link each way (both to the same two
    -- neighbours when the path is two-way). Such a point can simply move.
    local function plain(s)
        if not jxState.jxBuildNew[s] or s == jxState.jxCentreNode or jxSquareMade[s] or jxSquareMade[N] then return false end
        local nb = {}
        for _, id in ipairs(s.out or {}) do nb[id] = true end
        for _, id in ipairs(s.incoming or {}) do nb[id] = true end
        local n = 0
        for _ in pairs(nb) do n = n + 1 end
        return n == 2 and #(s.out or {}) == (sq.dual and 2 or 1) and #(s.incoming or {}) == (sq.dual and 2 or 1)
    end
    local function bendSide(s, sign)
        local ds = math.sqrt((s.x - N.x) ^ 2 + (s.z - N.z) ^ 2)
        local d = math.min(1.0, 0.5 * ds)
        if d < 0.3 then
            -- Too close to put a point between: swing the neighbour itself onto the square line, at
            -- the same distance.
            if ds < 0.1 or not plain(s) then return end
            ADGraphManager:moveWayPoint(s.id, N.x + sign * ds * sx, s.y, N.z + sign * ds * sz, s.flags, false)
            jxNoteMoved(s)
            jxSquareMade[s] = true
            bent = true
            return
        end
        local wp = ADFlyoverRecordWayPoint(N.x + sign * d * sx, N.y + (s.y - N.y) * (d / ds),
            N.z + sign * d * sz, false, false, false, 0, flags or AutoDrive.FLAG_NONE, false)
        jxState.jxLayLabel = label
        jxNoteAdded(wp)
        if wp == nil then jxState.jxLayLabel = nil return end
        jxSquareMade[wp] = true
        if sign < 0 then
            junctionDisconnect(s, N)
            junctionConnect(s, wp, sq.dual)
            junctionConnect(wp, N, sq.dual)
        else
            junctionDisconnect(N, s)
            junctionConnect(N, wp, sq.dual)
            junctionConnect(wp, s, sq.dual)
        end
        jxState.jxLayLabel = nil
        bent = true
    end
    bendSide(p, -1)
    bendSide(q, 1)
    return bent
end

local function junctionShareCrossings(cx, cz, reach)
    if jxState.jxBuildNew == nil then return 0 end
    jxState.jxShallowJoins = 0
    jxState.jxSquaredJoins = 0
    jxSquareMade = {}
    jxSlid = {}
    -- EDGE only keeps out crossings AT a link's end (two links meeting at a point already share it);
    -- a crossing merely near an end is handled by SNAP, through that end.
    local SNAP, EDGE, MAXH = AutoDrive.FLYOVER_JUNCTION_SHARE_SNAP or 0.75, 1e-4, 2.0
    -- Where to look: the junction's own circle, widened to take in every point the build added (a
    -- turn's tie-in can land well up a road), plus a margin for the links running on from there.
    local R2 = (reach + 15) ^ 2
    local minX, maxX, minZ, maxZ = cx, cx, cz, cz
    for w in pairs(jxState.jxBuildNew) do
        if w.x ~= nil then
            minX, maxX = math.min(minX, w.x), math.max(maxX, w.x)
            minZ, maxZ = math.min(minZ, w.z), math.max(maxZ, w.z)
        end
    end
    minX, maxX, minZ, maxZ = minX - 20, maxX + 20, minZ - 20, maxZ + 20
    local function inRegion(w)
        return (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= R2
            or (w.x >= minX and w.x <= maxX and w.z >= minZ and w.z <= maxZ)
    end
    local function splice(a, b, dual, N)
        local was = jxState.jxLayLabel
        jxState.jxLayLabel = jxState.jxLinkLabel ~= nil and ((jxState.jxLinkLabel[a] or {})[b] or (jxState.jxLinkLabel[b] or {})[a]) or nil
        junctionDisconnect(a, b)
        junctionConnect(a, N, dual)
        junctionConnect(N, b, dual)
        jxState.jxLayLabel = was
    end
    local joined = 0
    -- A pair of links met before is not joined again: in a tangle of points a metre apart, running one
    -- link through an existing point can make new links that cross the same pair again, and the
    -- search would go round in circles. Such a site is left with the crossing, and said so.
    local tried = {}
    local function pairKey(L1, L2)
        return tostring(L1.a) .. tostring(L1.b) .. "|" .. tostring(L2.a) .. tostring(L2.b)
    end
    local settled = false
    for _ = 1, 400 do
        -- Every link with both ends in the region, a two-way link once.
        local links = {}
        for _, a in pairs(ADGraphManager:getWayPoints()) do
            if a ~= nil and a.id ~= nil and inRegion(a) then
                for _, bid in ipairs(a.out or {}) do
                    local b = ADGraphManager:getWayPointById(bid)
                    if b ~= nil and b ~= a and inRegion(b) then
                        local dual = table.contains(b.out or {}, a.id)
                        if not dual or a.id < b.id then
                            links[#links + 1] = { a = a, b = b, dual = dual,
                                new = jxIsNewLink(a, b) or (dual and jxIsNewLink(b, a)) }
                        end
                    end
                end
            end
        end
        -- In a fixed order, so the same network always shares the same crossings first.
        table.sort(links, function(p, q)
            if p.a.x ~= q.a.x then return p.a.x < q.a.x end
            if p.a.z ~= q.a.z then return p.a.z < q.a.z end
            if p.b.x ~= q.b.x then return p.b.x < q.b.x end
            return p.b.z < q.b.z
        end)
        local found = nil
        for i = 1, #links do
            local L1 = links[i]
            if L1.new then
                for j = 1, #links do
                    local L2 = links[j]
                    if j ~= i and L1.a ~= L2.a and L1.a ~= L2.b and L1.b ~= L2.a and L1.b ~= L2.b
                        and not tried[pairKey(L1, L2)] then
                        local ax, az, bx, bz = L1.a.x, L1.a.z, L1.b.x, L1.b.z
                        local qx, qz, rx, rz = L2.a.x, L2.a.z, L2.b.x, L2.b.z
                        local den = (bx - ax) * (rz - qz) - (bz - az) * (rx - qx)
                        if math.abs(den) > 1e-9 then
                            local t = ((qx - ax) * (rz - qz) - (qz - az) * (rx - qx)) / den
                            local u = ((qx - ax) * (bz - az) - (qz - az) * (bx - ax)) / den
                            if t > EDGE and t < 1 - EDGE and u > EDGE and u < 1 - EDGE then
                                local y1 = (L1.a.y or 0) + ((L1.b.y or 0) - (L1.a.y or 0)) * t
                                local y2 = (L2.a.y or 0) + ((L2.b.y or 0) - (L2.a.y or 0)) * u
                                if math.abs(y1 - y2) <= MAXH then
                                    found = { L1 = L1, L2 = L2, x = ax + t * (bx - ax), z = az + t * (bz - az), y = (y1 + y2) / 2 }
                                    break
                                end
                            end
                        end
                    end
                end
            end
            if found ~= nil then break end
        end
        if found == nil then
            settled = true
            break
        end
        local L1, L2 = found.L1, found.L2
        local function near(w) return (w.x - found.x) ^ 2 + (w.z - found.z) ^ 2 <= SNAP * SNAP end
        tried[pairKey(L1, L2)] = true
        -- A crossing at 80 degrees or less lets AutoDrive switch between the two paths here (the route
        -- check then shows what that opens). Counted, so the build log says how many there were.
        do
            local ux, uz = L1.b.x - L1.a.x, L1.b.z - L1.a.z
            local vx, vz = L2.b.x - L2.a.x, L2.b.z - L2.a.z
            local nu, nv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
            if nu > 1e-6 and nv > 1e-6 then
                local ang = math.deg(math.acos(math.max(-1, math.min(1, (ux * vx + uz * vz) / (nu * nv)))))
                -- A two-way link runs both ways, so either direction can make the shallow side.
                if ang <= 80 or ((L1.dual or L2.dual) and ang >= 100) then
                    jxState.jxShallowJoins = (jxState.jxShallowJoins or 0) + 1
                end
            end
        end
        -- WHERE THE SHARED POINT GOES. A path run through a point BESIDE the crossing is bent there: a
        -- turn snapped through a point 0.7 m to its side bent 50-88 degrees, and AutoDrive crawls at
        -- 3 km/h past 50 (DrivePathModule.getMaxSpeedForAngle). Road lanes are never bent at all. So:
        --   1. one of OUR points near the crossing, with nothing else joined to it, SLIDES onto the
        --      crossing - the crossing lies on its own link, so our turn keeps its line - and the other
        --      path runs through it;
        --   2. an existing point near the crossing is shared as it stands only where running the other
        --      path through it bends that path 10 degrees or less;
        --   3. otherwise the crossing gets its own point, exactly where the two cross.
        local function dirOf(L) return L.b.x - L.a.x, L.b.z - L.a.z end
        local function bendVia(L, M)
            local x1, z1, x2, z2 = M.x - L.a.x, M.z - L.a.z, L.b.x - M.x, L.b.z - M.z
            local n1, n2 = math.sqrt(x1 * x1 + z1 * z1), math.sqrt(x2 * x2 + z2 * z2)
            if n1 < 1e-6 or n2 < 1e-6 then return 180 end
            return math.deg(math.acos(math.max(-1, math.min(1, (x1 * x2 + z1 * z2) / (n1 * n2)))))
        end
        -- N = the shared point, own = the link N is an end of, through = the link spliced through N.
        local N, own, through = nil, nil, nil
        local ownP, ownQ = nil, nil   -- own path's points either side of N, for squaring it up
        for _, c in ipairs({ { L1.a, L1, L2 }, { L1.b, L1, L2 }, { L2.a, L2, L1 }, { L2.b, L2, L1 } }) do
            local M = c[1]
            if N == nil and c[2].new and near(M) and jxPlainOurs(M) then
                local far = (M == c[2].a) and c[2].b or c[2].a
                local beyond = nil
                for _, id in ipairs(M.out or {}) do
                    local w = ADGraphManager:getWayPointById(id)
                    if w ~= nil and w ~= far then beyond = w end
                end
                for _, id in ipairs(M.incoming or {}) do
                    local w = ADGraphManager:getWayPointById(id)
                    if w ~= nil and w ~= far then beyond = w end
                end
                ADGraphManager:moveWayPoint(M.id, found.x, M.y, found.z, M.flags, false)
                jxNoteMoved(M)
                jxSlid[M] = true
                N, own, through = M, c[2], c[3]
                if M == c[2].b then ownP, ownQ = c[2].a, beyond else ownP, ownQ = beyond, c[2].b end
            end
        end
        if N == nil then
            for _, c in ipairs({ { L2.a, L2, L1 }, { L2.b, L2, L1 }, { L1.a, L1, L2 }, { L1.b, L1, L2 } }) do
                local M = c[1]
                if N == nil and near(M) and bendVia(c[3], M) <= 10 then N, own, through = M, c[2], c[3] end
            end
        end
        local sq = nil
        if N ~= nil then
            splice(through.a, through.b, through.dual, N)
            if through.new then
                local vx, vz = dirOf(own)
                sq = { p = through.a, N = N, q = through.b, dual = through.dual, vx = vx, vz = vz, otherDual = own.dual }
            elseif ownP ~= nil and ownQ ~= nil then
                local vx, vz = dirOf(through)
                sq = { p = ownP, N = N, q = ownQ, dual = own.dual, vx = vx, vz = vz, otherDual = through.dual }
            end
        else
            -- The existing road's flags, so a crossing point on it keeps the road's priority.
            local road = L2.new and L1 or L2
            N = ADFlyoverRecordWayPoint(found.x, found.y, found.z, false, false, false, 0,
                road.a.flags or AutoDrive.FLAG_NONE, false)
            jxState.jxLayLabel = "x"
            jxNoteAdded(N)
            jxState.jxLayLabel = nil
            if N == nil then break end
            splice(L1.a, L1.b, L1.dual, N)
            splice(L2.a, L2.b, L2.dual, N)
            local vx, vz = dirOf(L2)
            sq = { p = L1.a, N = N, q = L1.b, dual = L1.dual, vx = vx, vz = vz, otherDual = L2.dual }
        end
        -- OFF by default: once the shared point slides instead of snapping, it saved 1 extra route of 18 and
        -- put 20 sharp bends (12 or 3 km/h) into our turns (offline, 2026-10-02).
        if sq ~= nil and AutoDrive.FLYOVER_JUNCTION_SQUARE_CROSSINGS == true then
            if junctionSquareUp(sq) then jxState.jxSquaredJoins = jxState.jxSquaredJoins + 1 end
        end
        joined = joined + 1
    end
    if not settled then
        Logging.warning("[FlyoverEditor]: junction - the crossings here did not settle after %d joins (a tangle of points too close together); some may be left without a shared point.",
            joined)
    end
    return joined
end

-- Shared by the fitted pattern and the plain piece (doc 08): lanes near a point, and a point on a lane.
local function jxpLinksNear(px, pz, r)
    local t = {}
    for _, a in pairs(ADGraphManager:getWayPoints()) do
        if a ~= nil and a.id ~= nil and (a.x - px) ^ 2 + (a.z - pz) ^ 2 <= r * r then
            for _, bid in ipairs(a.out or {}) do
                local b = ADGraphManager:getWayPointById(bid)
                if b ~= nil and b ~= a then t[#t + 1] = { a = a, b = b } end
            end
        end
    end
    table.sort(t, function(p, q)
        if p.a.id ~= q.a.id then return p.a.id < q.a.id end
        return p.b.id < q.b.id
    end)
    return t
end
local function jxpUnit(x, z)
    local n = math.sqrt(x * x + z * z)
    if n < 1e-9 then return 0, 0 end
    return x / n, z / n
end

local function jxpGroundY(x, z, fallback)
    local y = nil
    if getTerrainHeightAtWorldPos ~= nil and g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
        local ok, v = pcall(getTerrainHeightAtWorldPos, g_currentMission.terrainRootNode, x, 1, z)
        if ok then y = v end
    end
    -- A junction on a bridge: the ground is far below the road, keep the road's height.
    if y == nil or (fallback ~= nil and math.abs(y - fallback) > 2) then return fallback end
    return y
end

-- A POINT ON A LANE: the lane running in direction (dx, dz) that passes nearest (px, pz). An end
-- of that link within 0.3 m is used as it is; otherwise a point is spliced in. `through` runs the
-- lane through a given point instead (a corner the other lane already has). dry only says whether
-- there is such a lane. A lane may bend a little past the junction: up to 1.5 m off the frame's
-- straight line and 30 degrees off its direction still counts, and the turn ends on the real lane.
local function jxpOnLane(px, pz, dx, dz, through, dry)
    local best, bd, bt = nil, 1.5, 0
    for _, l in ipairs(jxpLinksNear(px, pz, 20)) do
        local sx, sz = l.b.x - l.a.x, l.b.z - l.a.z
        local len2 = sx * sx + sz * sz
        if len2 > 1e-6 then
            local lx, lz = jxpUnit(sx, sz)
            if lx * dx + lz * dz > 0.87 then
                local t = ((px - l.a.x) * sx + (pz - l.a.z) * sz) / len2
                if t >= 0 and t <= 1 then
                    local d = math.abs((px - l.a.x) * lz - (pz - l.a.z) * lx)
                    if d < bd then best, bd, bt = l, d, t end
                end
            end
        end
    end
    if best == nil then return nil end
    if dry then return true end
    local a, b = best.a, best.b
    if through ~= nil then
        if through == a or through == b then return through end
        local dual = table.contains(b.out or {}, a.id)
        junctionDisconnect(a, b)
        junctionConnect(a, through, dual)
        junctionConnect(through, b, dual)
        return through
    end
    local slen = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
    if bt * slen <= 0.3 then return a end
    if (1 - bt) * slen <= 0.3 then return b end
    local x, z = a.x + bt * (b.x - a.x), a.z + bt * (b.z - a.z)
    local y = (a.y or 0) + bt * ((b.y or 0) - (a.y or 0))
    local N = ADFlyoverRecordWayPoint(x, y, z, false, false, false, 0, a.flags or AutoDrive.FLAG_NONE, false)
    jxNoteAdded(N)
    if N == nil then return nil end
    local dual = table.contains(b.out or {}, a.id)
    junctionDisconnect(a, b)
    junctionConnect(a, N, dual)
    junctionConnect(N, b, dual)
    return N
end

-- THE PATTERN (docs/junction-tool/07-pattern-build.md). Instead of fitting one curve per turn, place the
-- X we studied in the mod (doc 05), fitted to this junction:
--   * the FRAME comes from the kept through lanes: they cross at four inner corners; the middle of those
--     is the centre, their spacing the lane gap L, the lane directions the axes;
--   * "exact" lays the mod's own shape: a shared point at each inner corner, a short 45-degree cut for
--     each right turn, and every left turn through one centre point on two-way spokes;
--   * "smooth" lays the same pattern with curves: rights of 1.5 L hugging each corner, lefts of 1.71 L,
--     the size at which all four pass exactly through the one centre point.
-- Sizes come from the lane gap for now (decided 2026-10-02). Version 1 is a square X on one-way lanes;
-- anything else returns nil with the reason, and the caller builds turn by turn as before.
-- Mod frame: +x along one through lane; +z is +x turned a quarter to the right (FS25 x east, z south), so
-- with right-hand traffic the +x lane runs at z = +0.5 L. Returns { shape, kind, turns, L } or nil, why,
-- wired. dry (place mode's preview) only works out what would be placed and changes nothing.
-- THE PLAIN PIECE (docs/junction-tool/08-place-junction.md). Where the crossing doesn't fit the pattern,
-- the mod's own square X or T is placed anyway, lined up with the main road at the cursor: never refused,
-- never the old builder. Each of its points that lands on a lane running its way joins that lane; the
-- rest are laid free, and any of the piece's arm ends left free is a LOOSE END, listed on the card, to
-- join by hand. The pieces in doc 05's numbering, in lane gaps (the T's side road to +z).
local JX_PLAIN = {
    X = {
        nodes = { [1] = { 0, 0 }, [2] = { -0.5, 0.5 }, [3] = { -0.75, 0.5 }, [4] = { -1.5, 0.5 }, [5] = { -0.5, 0.75 },
            [6] = { -0.5, 1.5 }, [7] = { 0.5, 1.5 }, [8] = { 0.5, 0.75 }, [9] = { 0.5, 0.5 }, [10] = { 0.75, 0.5 },
            [11] = { 1.5, 0.5 }, [12] = { 1.5, -0.5 }, [13] = { 0.75, -0.5 }, [14] = { 0.5, -0.5 }, [15] = { 0.5, -0.75 },
            [16] = { 0.5, -1.5 }, [17] = { -0.5, -1.5 }, [18] = { -0.5, -0.75 }, [19] = { -0.5, -0.5 }, [20] = { -0.75, -0.5 },
            [21] = { -1.5, -0.5 } },
        links = { { 1, 2 }, { 2, 1 }, { 1, 9 }, { 9, 1 }, { 1, 14 }, { 14, 1 }, { 1, 19 }, { 19, 1 }, { 2, 5 }, { 2, 9 },
            { 3, 2 }, { 3, 5 }, { 4, 3 }, { 5, 6 }, { 7, 8 }, { 8, 9 }, { 8, 10 }, { 9, 10 }, { 9, 14 }, { 10, 11 },
            { 12, 13 }, { 13, 14 }, { 13, 15 }, { 14, 15 }, { 14, 19 }, { 15, 16 }, { 17, 18 }, { 18, 19 }, { 18, 20 },
            { 19, 20 }, { 19, 2 }, { 20, 21 } },
    },
    T = {
        nodes = { [1] = { 0, 0 }, [2] = { -0.5, 0.5 }, [3] = { -0.75, 0.5 }, [4] = { -1.5, 0.5 }, [5] = { -0.5, 0.75 },
            [6] = { -0.5, 1.5 }, [7] = { 0.5, 1.5 }, [8] = { 0.5, 0.75 }, [9] = { 0.5, 0.5 }, [10] = { 0.75, 0.5 },
            [11] = { 1.5, 0.5 }, [12] = { 1.5, -0.5 }, [13] = { -1.5, -0.5 } },
        links = { { 1, 2 }, { 1, 13 }, { 2, 5 }, { 2, 9 }, { 3, 2 }, { 3, 5 }, { 4, 3 }, { 5, 6 }, { 7, 8 }, { 8, 9 },
            { 8, 10 }, { 9, 10 }, { 9, 1 }, { 10, 11 }, { 12, 13 }, { 12, 1 } },
    },
}

local JX_PATTERN_RIGHT, JX_PATTERN_LEFT = 1.5, 1.71
local function junctionPlaceFitted(cx, cz, reach, shape, dry)
    local R = math.max(reach or 15, 15)
    local function near(w, r) return (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= r * r end
    local linksNear, unit = jxpLinksNear, jxpUnit

    -- 1. INNER CORNERS: two lanes crossing at a real angle near the site, either in open space or at a
    -- point they already share.
    local corners = {}
    local function addCorner(x, z, u1x, u1z, u2x, u2z)
        if not near({ x = x, z = z }, 12) then return end
        for _, c in ipairs(corners) do
            if (c.x - x) ^ 2 + (c.z - z) ^ 2 < 0.25 then return end
        end
        corners[#corners + 1] = { x = x, z = z, dirs = { { u1x, u1z }, { u2x, u2z } } }
    end
    local L0 = linksNear(cx, cz, R + 10)
    for i = 1, #L0 do
        for j = i + 1, #L0 do
            local p, q = L0[i], L0[j]
            if p.a ~= q.a and p.a ~= q.b and p.b ~= q.a and p.b ~= q.b then
                local ax, az, bx, bz = p.a.x, p.a.z, p.b.x, p.b.z
                local qx, qz, rx, rz = q.a.x, q.a.z, q.b.x, q.b.z
                local den = (bx - ax) * (rz - qz) - (bz - az) * (rx - qx)
                if math.abs(den) > 1e-9 then
                    local t = ((qx - ax) * (rz - qz) - (qz - az) * (rx - qx)) / den
                    local u = ((qx - ax) * (bz - az) - (qz - az) * (bx - ax)) / den
                    if t > 0 and t < 1 and u > 0 and u < 1 then
                        local u1x, u1z = unit(bx - ax, bz - az)
                        local u2x, u2z = unit(rx - qx, rz - qz)
                        if math.abs(u1x * u2x + u1z * u2z) < 0.5 then
                            addCorner(ax + t * (bx - ax), az + t * (bz - az), u1x, u1z, u2x, u2z)
                        end
                    end
                end
            end
        end
    end
    -- Lanes that already share a point where they cross: two straight runs through one point.
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil and near(w, 12) and #(w.incoming or {}) >= 2 and #(w.out or {}) >= 2 then
            local runs = {}
            for _, iid in ipairs(w.incoming) do
                local i = ADGraphManager:getWayPointById(iid)
                for _, oid in ipairs(w.out) do
                    local o = ADGraphManager:getWayPointById(oid)
                    if i ~= nil and o ~= nil and i ~= o then
                        local ax, az = unit(w.x - i.x, w.z - i.z)
                        local bx, bz = unit(o.x - w.x, o.z - w.z)
                        if ax * bx + az * bz > 0.94 then runs[#runs + 1] = { ax, az } end
                    end
                end
            end
            for a = 1, #runs do
                for b = a + 1, #runs do
                    if math.abs(runs[a][1] * runs[b][1] + runs[a][2] * runs[b][2]) < 0.5 then
                        addCorner(w.x, w.z, runs[a][1], runs[a][2], runs[b][1], runs[b][2])
                    end
                end
            end
        end
    end
    -- 2. THE FRAME. An X: from its four inner corners. A T: from where the side road's two lanes end,
    -- and the main road's two lanes, which run straight past.
    -- SKEW (doc 08, 2026-10-05): the frame has two directions of its own, E1 along the main road and E2
    -- along the cross or side road, so a road meeting off square gets the pattern leant to its real angle.
    -- Straight paths stay straight and curves stay tangent to the lanes they join. How far off square is
    -- set by AutoDrive's 80-degree bend limit on the mod's shape: an X to 35 (its lefts run corner - centre -
    -- corner, worst bend 73), a T to 50 (worst 72; at 55 its sharp left would bend 81).
    local kind, ox, oz, ux, uz, vx, vz, L = nil, 0, 0, nil, nil, nil, nil, 0
    local e1x, e1z, e2x, e2z = nil, nil, nil, nil
    local sideIn, sideOut = nil, nil
    local twoWaySide = nil      -- a T whose side road is one two-way road: its end
    if #corners == 4 then
        kind = "X"
        for _, c in ipairs(corners) do ox, oz = ox + c.x / 4, oz + c.z / 4 end
        local ex = nil
        for _, c in ipairs(corners) do
            for _, d in ipairs(c.dirs) do
                -- +z is +x turned a quarter to the right; the +x lane must run on the +z side of the centre.
                local zx, zz = -d[2], d[1]
                if ex == nil and (c.x - ox) * zx + (c.z - oz) * zz > 0 then ex = d end
            end
        end
        if ex == nil then return nil, "could not tell the lane directions apart" end
        ux, uz = ex[1], ex[2]
        vx, vz = -uz, ux
        -- The corners by quarter, in the first guess at the frame: (+x, +z), (+x, -z), (-x, +z), (-x, -z).
        local q = {}
        for _, c in ipairs(corners) do
            local lx, lz = (c.x - ox) * ux + (c.z - oz) * uz, (c.x - ox) * vx + (c.z - oz) * vz
            local key = (lx > 0 and "+" or "-") .. (lz > 0 and "+" or "-")
            if q[key] ~= nil then return nil, "the lanes do not cross in a four-cornered box" end
            q[key] = c
        end
        if not (q["++"] and q["+-"] and q["-+"] and q["--"]) then
            return nil, "the lanes do not cross in a four-cornered box"
        end
        e1x = (q["++"].x + q["+-"].x - q["-+"].x - q["--"].x) / 2
        e1z = (q["++"].z + q["+-"].z - q["-+"].z - q["--"].z) / 2
        e2x = (q["++"].x + q["-+"].x - q["+-"].x - q["--"].x) / 2
        e2z = (q["++"].z + q["-+"].z - q["+-"].z - q["--"].z) / 2
        local n1, n2 = math.sqrt(e1x * e1x + e1z * e1z), math.sqrt(e2x * e2x + e2z * e2z)
        if n1 < 1e-3 or n2 < 1e-3 then return nil, "the lanes do not cross in a four-cornered box" end
        ux, uz = e1x / n1, e1z / n1
        vx, vz = -uz, ux
        L = math.abs(e2x * vx + e2z * vz)      -- the main road's lane gap, square across it
        if math.abs((e1x * e2x + e1z * e2z) / (n1 * n2)) > 0.574 then
            return nil, "the roads cross more than 35 degrees off square"
        end
        for key, c in pairs(q) do
            local sx = key:sub(1, 1) == "+" and 0.5 or -0.5
            local sz = key:sub(2, 2) == "+" and 0.5 or -0.5
            local px, pz = ox + sx * e1x + sz * e2x, oz + sx * e1z + sz * e2z
            if math.sqrt((px - c.x) ^ 2 + (pz - c.z) ^ 2) > 0.25 * math.min(n1, n2) then
                return nil, "the lanes do not cross in an even box (a lane bends between the corners)"
            end
        end    else
        kind = "T"
        -- The side road: one lane in that stops near the main road, one lane out that starts there.
        local ends, starts = {}, {}
        for _, w in pairs(ADGraphManager:getWayPoints()) do
            if w ~= nil and w.id ~= nil and near(w, 14) then
                local nin, nout = #(w.incoming or {}), #(w.out or {})
                if nout == 0 and nin >= 1 then ends[#ends + 1] = w end
                if nin == 0 and nout >= 1 then starts[#starts + 1] = w end
            end
        end
        -- The side road is a PAIR: a lane in and a lane out running opposite ways, a lane gap apart.
        -- Another end the clear left nearby is not part of it (in game j3 had one), so the pair nearest the
        -- middle is taken and any stray is ignored.
        local bestPair, bestD = nil, nil
        if #corners == 0 then
            for _, e in ipairs(ends) do
                local p = ADGraphManager:getWayPointById(e.incoming[1])
                for _, s in ipairs(starts) do
                    local q = ADGraphManager:getWayPointById(s.out[1])
                    if p ~= nil and q ~= nil then
                        local ax, az = unit(e.x - p.x, e.z - p.z)
                        local bx, bz = unit(q.x - s.x, q.z - s.z)
                        local gap = math.sqrt((e.x - s.x) ^ 2 + (e.z - s.z) ^ 2)
                        if ax * bx + az * bz < -0.94 and gap > 1.5 and gap < 14 then
                            local d = ((e.x + s.x) / 2 - cx) ^ 2 + ((e.z + s.z) / 2 - cz) ^ 2
                            if bestD == nil or d < bestD then bestPair, bestD = { e, s }, d end
                        end
                    end
                end
            end
        end
        -- A SIDE ROAD THAT IS ONE TWO-WAY ROAD: its end (one neighbour, joined both ways) stands for both
        -- lanes. The piece's two side lanes split from it at the mouth: lane out -> road end -> lane in.
        if bestPair == nil and #corners == 0 then
            local bd2 = nil
            for _, w in pairs(ADGraphManager:getWayPoints()) do
                if w ~= nil and w.id ~= nil and near(w, 14) then
                    local nb, n, only = {}, 0, nil
                    for _, id in ipairs(w.out or {}) do if not nb[id] then nb[id] = true n = n + 1 only = id end end
                    for _, id in ipairs(w.incoming or {}) do if not nb[id] then nb[id] = true n = n + 1 only = id end end
                    if n == 1 and table.contains(w.out or {}, only) and table.contains(w.incoming or {}, only) then
                        local d = (w.x - cx) ^ 2 + (w.z - cz) ^ 2
                        if bd2 == nil or d < bd2 then bestPair, bd2, twoWaySide = { w, w, only }, d, w end
                    end
                end
            end
        end
        if bestPair == nil then
            return nil, string.format("not an X (%d lane crossings) and no side road found (%d lane ends, %d lane starts near the middle)",
                #corners, #ends, #starts)
        end
        sideIn, sideOut = bestPair[1], bestPair[2]
        local p = ADGraphManager:getWayPointById(sideIn.incoming[1])
        local q = ADGraphManager:getWayPointById(sideOut.out[1])
        if twoWaySide ~= nil then p = ADGraphManager:getWayPointById(bestPair[3]) q = p end
        if p == nil or q == nil then return nil, "lost the side road's lanes" end
        local dix, diz = unit(sideIn.x - p.x, sideIn.z - p.z)      -- heading in, towards the main road
        local dox, doz = unit(q.x - sideOut.x, q.z - sideOut.z)    -- heading out, away from it
        if twoWaySide ~= nil then dox, doz = -dix, -diz end
        if dix * dox + diz * doz > -0.94 then return nil, "the side road's two lanes do not run opposite ways" end
        -- First guess: square to the side road. Then the main road's own lanes at the mouth set +x, and
        -- the side road may sit up to 50 degrees off square to them.
        vx, vz = -dix, -diz      -- +z runs down the side road
        ux, uz = vz, -vx         -- +x is +z turned a quarter back to the left
        local xOut, xm, east, west
        local function pickMain(minAlong)
            -- Where the side road's lanes sit across it: in at x = 0 (from sideIn), out at about -L.
            xOut = (sideOut.x - sideIn.x) * ux + (sideOut.z - sideIn.z) * uz
            xm = xOut / 2
            -- The main road's two lanes passing the mouth: the +x one nearer, the -x one next beyond it.
            -- Positions measured along +z from sideIn.
            local cand = {}
            for _, l in ipairs(linksNear(sideIn.x, sideIn.z, 25)) do
                local lx, lz = unit(l.b.x - l.a.x, l.b.z - l.a.z)
                local along = lx * ux + lz * uz
                local ua = (l.a.x - sideIn.x) * ux + (l.a.z - sideIn.z) * uz
                local ub = (l.b.x - sideIn.x) * ux + (l.b.z - sideIn.z) * uz
                if math.abs(along) > minAlong and math.min(ua, ub) <= xm and math.max(ua, ub) >= xm then
                    local tt = (xm - ua) / (ub - ua)
                    local zl = ((l.a.x + tt * (l.b.x - l.a.x)) - sideIn.x) * vx + ((l.a.z + tt * (l.b.z - l.a.z)) - sideIn.z) * vz
                    if zl < 0 then cand[#cand + 1] = { zl = zl, dir = along > 0 and 1 or -1, dx = lx, dz = lz } end
                end
            end
            local e, w = nil, nil
            for _, c in ipairs(cand) do
                if c.dir > 0 and (e == nil or c.zl > e.zl) then e = c end
            end
            if e == nil then return nil, "no main-road lane runs past the side road the right way" end
            for _, c in ipairs(cand) do
                if c.dir < 0 and c.zl < e.zl - 0.5 and (w == nil or c.zl > w.zl) then w = c end
            end
            if w == nil then return nil, "no second main-road lane beyond the first" end
            return e, w
        end
        local e, w = pickMain(0.5)
        if e == nil then return nil, w end
        ux, uz = unit(e.dx - w.dx, e.dz - w.dz)
        vx, vz = -uz, ux
        -- The side road's own direction, away from the main road: the average of its two lanes.
        local sdx, sdz = unit(dox - dix, doz - diz)
        local cosS = sdx * vx + sdz * vz
        if cosS < 0.643 then
            return nil, "the side road meets the main road more than 50 degrees off square"
        end
        e, w = pickMain(0.966)
        if e == nil then return nil, w end
        east, west = e.zl, w.zl
        L = east - west
        -- Each side lane, followed along the side road to the main road's centre line (zm, measured
        -- along +z from sideIn): the lane in crosses it at x = +0.5, the lane out at x = -0.5.
        local zm = (east + west) / 2
        local zOut = (sideOut.x - sideIn.x) * vx + (sideOut.z - sideIn.z) * vz
        local tIn, tOut = zm / cosS, (zm - zOut) / cosS
        local pix, piz = sideIn.x + tIn * sdx, sideIn.z + tIn * sdz
        local pox, poz = sideOut.x + tOut * sdx, sideOut.z + tOut * sdz
        ox, oz = (pix + pox) / 2, (piz + poz) / 2
        e1x, e1z = pix - pox, piz - poz
        -- One two-way road: its line is the side road's middle; the piece's side lanes go a lane gap apart.
        if twoWaySide ~= nil then e1x, e1z = L * ux, L * uz end
        local n1 = math.sqrt(e1x * e1x + e1z * e1z)
        if n1 < 0.6 * L or n1 > 1.6 * L then
            return nil, string.format("the side road's lanes are %.1f m apart, not like the main road's %.1f m", n1, L)
        end
        e2x, e2z = L * sdx / cosS, L * sdz / cosS
    end    if L < 2 or L > 12 then return nil, string.format("lane gap %.1f m is outside 2-12 m", L) end
    local skew = math.deg(math.acos(math.max(-1, math.min(1, math.abs(e2x * vx + e2z * vz)
        / math.max(1e-6, math.sqrt(e2x * e2x + e2z * e2z))))))
    if not dry then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction pattern - frame: %s, centre %.1f, %.1f, lane gap %.1f m, +x heading %.2f, %.2f, %.0f deg off square.",
            kind, ox, oz, L, ux, uz, skew)
    end
    local function W(mx, mz) return ox + mx * e1x + mz * e2x, oz + mx * e1z + mz * e2z end
    local function D(mx, mz) return unit(mx * e1x + mz * e2x, mx * e1z + mz * e2z) end
    -- Curves are sampled by the longer of the two directions.
    local Lscale = math.max(math.sqrt(e1x * e1x + e1z * e1z), math.sqrt(e2x * e2x + e2z * e2z))
    -- The mod's corner cut starts and ends a quarter lane gap from the corner. Measured in METRES along
    -- each lane, not in the frame's units, so on a leaning piece the cut still splits the turn into two
    -- equal bends (two of 67 degrees at 45 off square, where frame units would give 45 and 90).
    local f1 = 0.25 * L / math.max(1e-6, math.sqrt(e1x * e1x + e1z * e1z))
    local f2 = 0.25 * L / math.max(1e-6, math.sqrt(e2x * e2x + e2z * e2z))
    local function cutAt(k)   -- the corner cut of approach k: start on its lane in, end on the lane out
        local fa, fb = f1, f2
        if k % 2 == 1 then fa, fb = f2, f1 end
        local ax, az, bx, bz = -0.5 - fa, 0.5, -0.5, 0.5 + fb
        for _ = 1, k do ax, az = -az, ax bx, bz = -bz, bx end   -- turned k quarters (as rot, defined below)
        return ax, az, bx, bz
    end
    local function rot(x, z, k)
        for _ = 1, k do x, z = -z, x end
        return x, z
    end
    local groundY, onLane = jxpGroundY, jxpOnLane

    -- A POINT THE PATTERN NEEDS on the lane running (ddx, ddz) in the mod frame. In a T the side road's
    -- lanes stop short of the main road; a point between a lane's end and the main road extends that
    -- lane to it (in: lane end -> point; out: point -> lane start). `dry` only says whether it can.
    local function lanePoint(mx, mz, ddx, ddz, dry)
        local px, pz = W(mx, mz)
        local dx, dz = D(ddx, ddz)
        local sidePoint = kind == "T" and math.abs(ddx) <= 0.5
        local r = nil
        if not (sidePoint and twoWaySide ~= nil) then r = onLane(px, pz, dx, dz, nil, dry) end
        if r ~= nil then return r end
        if kind ~= "T" or math.abs(ddx) > 0.5 then return nil end
        local stub, forward = sideOut, false
        if ddz < 0 then stub, forward = sideIn, true end
        local ahead = (px - stub.x) * dx + (pz - stub.z) * dz
        if (forward and ahead <= 0.3) or (not forward and ahead >= -0.3) then return nil end
        if math.sqrt((px - stub.x) ^ 2 + (pz - stub.z) ^ 2) > 2.5 * L then return nil end
        if dry then return true end
        local N = ADFlyoverRecordWayPoint(px, groundY(px, pz, stub.y or 0), pz, false, false, false, 0,
            stub.flags or AutoDrive.FLAG_NONE, false)
        jxNoteAdded(N)
        if N == nil then return nil end
        if forward then junctionConnect(stub, N, false) else junctionConnect(N, stub, false) end
        return N
    end

    -- THE TURNS OF EACH SHAPE, in the mod frame (doc 05's node numbers in the comments).
    -- Smooth: a right of approach k (the +x lane turned k quarters) runs on a circle centred
    -- (-0.5 - r, 0.5 + r), a left on one centred (0.5 - r, 0.5 - r) through the centre.
    local RR, LR = JX_PATTERN_RIGHT, JX_PATTERN_LEFT
    local function smoothRight(k)
        local ax, az = rot(-0.5 - RR, 0.5, k)
        local bx, bz = rot(-0.5, 0.5 + RR, k)
        local d1x, d1z = rot(1, 0, k)
        local d2x, d2z = rot(0, 1, k)
        return { a = { ax, az, d1x, d1z, "right turn start" }, b = { bx, bz, d2x, d2z, "right turn end" },
                 arc = { -0.5 - RR, 0.5 + RR, RR, -math.pi / 2, 0, k, false }, kind = "R90" }
    end
    local function smoothLeft(k)
        local ax, az = rot(0.5 - LR, 0.5, k)
        local bx, bz = rot(0.5, 0.5 - LR, k)
        local d1x, d1z = rot(1, 0, k)
        local d3x, d3z = rot(0, -1, k)
        return { a = { ax, az, d1x, d1z, "left turn start" }, b = { bx, bz, d3x, d3z, "left turn end" },
                 arc = { 0.5 - LR, 0.5 - LR, LR, math.pi / 2, 0, k, true }, kind = "L90" }
    end
    -- A T keeps only the turns that exist: the side road is to the +z side. Rights: +x into the side
    -- road (k 0), the side road into +x (k 3). Lefts: -x into the side road (k 2), the side road into -x (k 3).
    local function smoothTurns()
        local t = {}
        if kind == "X" then
            for k = 0, 3 do t[#t + 1] = smoothRight(k) t[#t + 1] = smoothLeft(k) end
        else
            t = { smoothRight(0), smoothRight(3), smoothLeft(2), smoothLeft(3) }
        end
        return t
    end
    -- The mod's T: points on the +x lane 3 (-0.75), 2 (-0.5), 9 (0.5), 10 (0.75); on the -x lane 12 (1.5)
    -- and 13 (-1.5); the side road's out lane at 5 (-0.5, 0.75), its in lane at 8 (0.5, 0.75).
    local T_EXACT = {
        n3 = { -0.5 - f1, 0.5, 1, 0, "right turn start" }, n2 = { -0.5, 0.5, 1, 0, "inner corner" },
        n9 = { 0.5, 0.5, 1, 0, "inner corner" }, n10 = { 0.5 + f1, 0.5, 1, 0, "right turn end" },
        n12 = { 1.5, -0.5, -1, 0, "left turn start" }, n13 = { -1.5, -0.5, -1, 0, "left turn end" },
        n5 = { -0.5, 0.5 + f2, 0, 1, "side road's lane out" }, n8 = { 0.5, 0.5 + f2, 0, -1, "side road's lane in" },
    }
    local T_ORDER = { "n3", "n2", "n9", "n10", "n12", "n13", "n5", "n8" }

    -- ALL OR NOTHING: every point the shape needs must have its lane before anything is laid. The smooth
    -- turns end further out (2 L), where a lane may already have bent away; the mod's shape stays within
    -- about 0.75 L of the centre (1.5 L along a T's main road), so where smooth does not fit, the mod's
    -- shape is placed instead.
    local function needs(sh)
        local t = {}
        if kind == "X" then
            for k = 0, 3 do
                local cx1, cz1 = rot(-0.5, 0.5, k)
                local d1x, d1z = rot(1, 0, k)
                local d2x, d2z = rot(0, 1, k)
                t[#t + 1] = { cx1, cz1, d1x, d1z, "inner corner" }
                t[#t + 1] = { cx1, cz1, d2x, d2z, "inner corner" }
                if sh == "exact" then
                    local ax, az, bx, bz = cutAt(k)
                    t[#t + 1] = { ax, az, d1x, d1z, "right turn start" }
                    t[#t + 1] = { bx, bz, d2x, d2z, "right turn end" }
                end
            end
        elseif sh == "exact" then
            for _, key in ipairs(T_ORDER) do t[#t + 1] = T_EXACT[key] end
        end
        if sh ~= "exact" then
            for _, turn in ipairs(smoothTurns()) do t[#t + 1] = turn.a t[#t + 1] = turn.b end
        end
        return t
    end
    local function fits(sh)
        if twoWaySide ~= nil and sh ~= "exact" then
            return false, "the side road is one two-way road, and the smooth shape needs two side lanes"
        end
        for _, n in ipairs(needs(sh)) do
            if not lanePoint(n[1], n[2], n[3], n[4], true) then
                local x, z = W(n[1], n[2])
                return false, string.format("no lane under the %s at %.1f, %.1f", n[5], x, z)
            end
        end
        return true
    end
    local okFit, whyNot = fits(shape)
    if not okFit and shape == "smooth" and fits("exact") then
        ADFlyoverSettings.debugLog("[FlyoverEditor]: junction pattern - the smooth %s does not fit here (%s); placing the mod's %s instead.",
            kind, whyNot, kind)
        shape = "exact"
    elseif not okFit then
        return nil, whyNot
    end
    if dry then
        -- What the preview draws: each new path as a line through world points, and the shared points.
        local lines, marks = {}, {}
        local function P(mx, mz) local x, z = W(mx, mz) return { x = x, z = z } end
        local piece = JX_PLAIN[kind]
        -- The corner cuts where they are really laid (see cutAt).
        local pos = {}
        for n, p in pairs(piece.nodes) do pos[n] = p end
        if kind == "X" then
            for k, pair in pairs({ [0] = { 3, 5 }, [1] = { 18, 20 }, [2] = { 13, 15 }, [3] = { 8, 10 } }) do
                local ax, az, bx, bz = cutAt(k)
                pos[pair[1]], pos[pair[2]] = { ax, az }, { bx, bz }
            end
        else
            pos[3], pos[5] = { T_EXACT.n3[1], T_EXACT.n3[2] }, { T_EXACT.n5[1], T_EXACT.n5[2] }
            pos[8], pos[10] = { T_EXACT.n8[1], T_EXACT.n8[2] }, { T_EXACT.n10[1], T_EXACT.n10[2] }
        end
        if shape == "exact" then
            local new = (kind == "X")
                and { { 1, 2, true }, { 1, 9, true }, { 1, 14, true }, { 1, 19, true },
                      { 3, 5 }, { 8, 10 }, { 13, 15 }, { 18, 20 } }
                or { { 3, 5 }, { 8, 10 }, { 12, 1 }, { 1, 2 }, { 2, 5 }, { 8, 9 }, { 9, 1 }, { 1, 13 } }
            for _, l in ipairs(new) do
                local a, b = pos[l[1]], pos[l[2]]
                lines[#lines + 1] = { pts = { P(a[1], a[2]), P(b[1], b[2]) }, dual = l[3] == true }
            end
            local shared = (kind == "X") and { 1, 2, 9, 14, 19, 5, 10, 15, 20 } or { 1, 2, 9, 5, 10, 13 }
            for _, n in ipairs(shared) do marks[#marks + 1] = P(pos[n][1], pos[n][2]) end
        else
            for _, turn in ipairs(smoothTurns()) do
                local c = turn.arc
                local pts = { P(turn.a[1], turn.a[2]) }
                for i = 1, 11 do
                    local a = c[4] + (c[5] - c[4]) * i / 12
                    pts[#pts + 1] = P(rot(c[1] + c[3] * math.cos(a), c[2] + c[3] * math.sin(a), c[6]))
                end
                pts[#pts + 1] = P(turn.b[1], turn.b[2])
                lines[#lines + 1] = { pts = pts }
            end
            marks[#marks + 1] = P(0, 0)
        end
        return { shape = shape, kind = kind, L = L, ox = ox, oz = oz, ux = ux, uz = uz, turns = 0,
                 lines = lines, marks = marks }
    end

    -- 4. LAYING.
    local turns = 0
    local function label(k)
        jxState.jxLaySeq = jxState.jxLaySeq + 1
        jxState.jxLayLabel = k .. "#" .. jxState.jxLaySeq
    end
    local function lay(A, pts, B, k)
        if A == nil or B == nil or A == B then return false end
        label(k)
        local ok, laid = tryCall("junction pattern lay", function()
            return junctionLayChain(A, pts, B, false, B.flags or AutoDrive.FLAG_NONE)
        end)
        jxState.jxLayLabel = nil
        if ok and laid == true then turns = turns + 1 return true end
        return false
    end
    -- Interior points of an arc in mod units, about every 2 m, as world points; with centreMid the
    -- middle sample is the junction's centre (the lefts' shared point).
    local function arcPoints(acx, acz, r, a0, a1, k, centreMid, y0, y1)
        local len = math.abs(a1 - a0) * r * Lscale
        local n = math.max(2, math.floor(len / 2 + 0.5))
        if centreMid and n % 2 == 1 then n = n + 1 end
        local pts = {}
        for i = 1, n - 1 do
            local a = a0 + (a1 - a0) * i / n
            local mx, mz = rot(acx + r * math.cos(a), acz + r * math.sin(a), k)
            local x, z = W(mx, mz)
            local fy = y0 + (y1 - y0) * i / n
            pts[#pts + 1] = { x = x, z = z, y = groundY(x, z, fy), centre = (centreMid and i == n / 2) or nil }
        end
        return pts
    end
    local function newCentre(flags, y)
        local cxw, czw = W(0, 0)
        local O = ADFlyoverRecordWayPoint(cxw, groundY(cxw, czw, y), czw, false, false, false, 0,
            flags or AutoDrive.FLAG_NONE, false)
        jxState.jxLayLabel = "centre"
        jxNoteAdded(O)
        jxState.jxLayLabel = nil
        return O
    end

    -- An X's inner corners, shared by both lanes. Corner k sits at (-0.5, 0.5) turned k quarters: where
    -- the +x lane (turned k) crosses the +z lane (turned k).
    local cornerNode = {}
    if kind == "X" then
        for k = 0, 3 do
            local mx, mz = rot(-0.5, 0.5, k)
            local px, pz = W(mx, mz)
            local d2x, d2z = D(rot(0, 1, k))
            local d1mx, d1mz = rot(1, 0, k)
            local N = lanePoint(mx, mz, d1mx, d1mz)
            if N == nil then return nil, "lost a lane at an inner corner" end
            if onLane(px, pz, d2x, d2z, N) == nil then return nil, "lost a lane at an inner corner" end
            cornerNode[k] = N
        end
    end

    if shape == "exact" and kind == "X" then
        local cy = 0
        for k = 0, 3 do cy = cy + (cornerNode[k].y or 0) / 4 end
        local O = newCentre(cornerNode[0].flags, cy)
        if O == nil then return nil, "could not add the centre point" end
        -- The spokes: every left turn goes corner -> centre -> corner, so each spoke runs both ways.
        label("L-spokes")
        for k = 0, 3 do junctionConnect(O, cornerNode[k], true) end
        jxState.jxLayLabel = nil
        turns = turns + 4
        for k = 0, 3 do
            local ax, az, bx, bz = cutAt(k)
            local d1x, d1z = rot(1, 0, k)
            local d2x, d2z = rot(0, 1, k)
            lay(lanePoint(ax, az, d1x, d1z), {}, lanePoint(bx, bz, d2x, d2z), "R45")
        end
    elseif shape == "exact" then
        -- The mod's T (doc 05): every path one-way. The left from -x into the side road runs 12 ->
        -- centre -> 2 -> 5; the left out of the side road 8 -> 9 -> centre -> 13; they take turns at the
        -- centre. The rights are the short cuts 3 -> 5 and 8 -> 10.
        local n = {}
        for _, key in ipairs(T_ORDER) do
            local s = T_EXACT[key]
            n[key] = lanePoint(s[1], s[2], s[3], s[4])
            if n[key] == nil then return nil, "lost the lane under the " .. s[5] end
        end
        local O = newCentre(n.n2.flags, ((n.n2.y or 0) + (n.n9.y or 0)) / 2)
        if O == nil then return nil, "could not add the centre point" end
        lay(n.n3, {}, n.n5, "R45")
        lay(n.n8, {}, n.n10, "R45")
        label("L-in")
        junctionConnect(n.n12, O, false)
        junctionConnect(O, n.n2, false)
        junctionConnect(n.n2, n.n5, false)
        jxState.jxLayLabel = nil
        label("L-out")
        junctionConnect(n.n8, n.n9, false)
        junctionConnect(n.n9, O, false)
        junctionConnect(O, n.n13, false)
        jxState.jxLayLabel = nil
        turns = turns + 2
    else
        for _, turn in ipairs(smoothTurns()) do
            local A = lanePoint(turn.a[1], turn.a[2], turn.a[3], turn.a[4])
            local B = lanePoint(turn.b[1], turn.b[2], turn.b[3], turn.b[4])
            if A ~= nil and B ~= nil then
                local c = turn.arc
                lay(A, arcPoints(c[1], c[2], c[3], c[4], c[5], c[6], c[7], A.y or 0, B.y or 0), B, turn.kind)
            end
        end
    end

    -- A T's side lanes may now run on past the turns towards the main road, to an end nothing uses:
    -- take those bits back to the first point a turn uses.
    if kind == "T" then
        local function tidy(w, back)
            for _ = 1, 30 do
                if w == nil or w.id == nil or ADGraphManager:getWayPointById(w.id) ~= w then return end
                local nout, nin = #(w.out or {}), #(w.incoming or {})
                local nextW = nil
                if back and nout == 0 and nin == 1 then
                    nextW = ADGraphManager:getWayPointById(w.incoming[1])
                elseif not back and nin == 0 and nout == 1 then
                    nextW = ADGraphManager:getWayPointById(w.out[1])
                else
                    return
                end
                jxRemove(w, "junction pattern unused lane end", true)
                w = nextW
            end
        end
        tidy(sideIn, true)
        tidy(sideOut, false)
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction pattern (%s) placed: %s, lane gap %.1f m, centre %.1f, %.1f, %d turn piece(s).",
        shape, kind, L, ox, oz, turns)
    return { shape = shape, kind = kind, turns = turns, L = L, ox = ox, oz = oz, ux = ux, uz = uz }
end

local function junctionPlacePlain(cx, cz, dry)
    local unit = jxpUnit
    -- THE MAIN ROAD: the lane nearest the cursor that runs on past it, and its partner running the other
    -- way beside it. A lane that ends within 20 m of the cursor is a side road or a stub, never the main road.
    local function endsNear(l)
        for _, dir in ipairs({ "out", "incoming" }) do
            local prev, cur = (dir == "out") and l.a or l.b, (dir == "out") and l.b or l.a
            for _ = 1, 40 do
                if (cur.x - cx) ^ 2 + (cur.z - cz) ^ 2 > 20 * 20 then break end
                local nextW = nil
                for _, id in ipairs(cur[dir] or {}) do
                    local w = ADGraphManager:getWayPointById(id)
                    if w ~= nil and w ~= prev and nextW == nil then nextW = w end
                end
                if nextW == nil then return true end
                prev, cur = cur, nextW
            end
        end
        return false
    end
    -- Lanes that end near the cursor are a last resort: never refused (doc 08), so with nothing else
    -- the nearest lane serves.
    local best, bd = nil, 15
    for pass = 1, 2 do
    if best == nil then
    bd = 15
    for _, l in ipairs(jxpLinksNear(cx, cz, 30)) do
        local sx, sz = l.b.x - l.a.x, l.b.z - l.a.z
        local len2 = sx * sx + sz * sz
        if len2 > 1e-6 and (pass == 2 or not endsNear(l)) then
            local t = math.max(0, math.min(1, ((cx - l.a.x) * sx + (cz - l.a.z) * sz) / len2))
            local px, pz = l.a.x + t * sx, l.a.z + t * sz
            local d = math.sqrt((cx - px) ^ 2 + (cz - pz) ^ 2)
            if d < bd then best, bd = { l = l, px = px, pz = pz, y = (l.a.y or 0) + t * ((l.b.y or 0) - (l.a.y or 0)) }, d end
        end
    end
    end
    end
    if best == nil then return nil, "no road here to line a junction up with" end
    local dx, dz = unit(best.l.b.x - best.l.a.x, best.l.b.z - best.l.a.z)
    local rx, rz = -dz, dx                          -- right of the nearest lane
    local L, partner, pd = nil, false, nil
    for _, l in ipairs(jxpLinksNear(best.px, best.pz, 25)) do
        local lx, lz = unit(l.b.x - l.a.x, l.b.z - l.a.z)
        if lx * dx + lz * dz < -0.94 then
            -- Measured to the nearest point of that link, not its start: on a bending road the start can sit
            -- well round the bend and read short.
            local sx2, sz2 = l.b.x - l.a.x, l.b.z - l.a.z
            local len2 = math.max(1e-6, sx2 * sx2 + sz2 * sz2)
            local tt = math.max(0, math.min(1, ((best.px - l.a.x) * sx2 + (best.pz - l.a.z) * sz2) / len2))
            local qx, qz = l.a.x + tt * sx2, l.a.z + tt * sz2
            local off = (qx - best.px) * rx + (qz - best.pz) * rz
            local along = (qx - best.px) * dx + (qz - best.pz) * dz
            -- With right-hand traffic the lane the other way runs on the left (negative offset).
            -- The partner is the opposite lane NEAREST in a straight line: on a bending road a stretch further
            -- along can sit closer across but is not the lane beside this point.
            local dist = math.sqrt((qx - best.px) ^ 2 + (qz - best.pz) ^ 2)
            if off < -1.5 and off > -12 and math.abs(along) < 25 and (pd == nil or dist < pd) then
                L, partner, pd = -off, true, dist
            end
        end
    end
    L = L or 4
    if not dry then ADFlyoverSettings.debugLog("[FlyoverEditor]: junction plain - main lane %.1f, %.1f -> %.1f, %.1f (cursor %.1f m off), lane gap %.1f m%s.",
        best.l.a.x, best.l.a.z, best.l.b.x, best.l.b.z, bd, L, partner and "" or " (no partner)") end

    -- WHICH PIECE, and which way round: side-road lanes stopping near the cursor make it a T with its side
    -- road towards them; lanes crossing near it make an X; nothing else to go by, an X.
    local ends = {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= 14 * 14 then
            -- A lane end: a point with only one neighbour (a two-way road's end has a link each way).
            local nb, n = {}, 0
            for _, id in ipairs(w.out or {}) do if not nb[id] then nb[id] = true n = n + 1 end end
            for _, id in ipairs(w.incoming or {}) do if not nb[id] then nb[id] = true n = n + 1 end end
            if n == 1 then ends[#ends + 1] = w end
        end
    end
    -- Lane ends on BOTH sides of the main road are a cross road the clear cut in two: an X.
    local kind, sx, sz = "X", nil, nil
    if #ends > 0 then
        local left, right = false, false
        sx, sz = 0, 0
        for _, w in ipairs(ends) do
            sx, sz = sx + w.x / #ends, sz + w.z / #ends
            local off = (w.x - best.px) * rx + (w.z - best.pz) * rz
            if off > 0.5 then right = true elseif off < -(L + 0.5) then left = true end
        end
        kind = (left and right) and "X" or "T"
    end
    -- The frame: +z (to the right of +x) points at the side road on a T. The nearest lane is the +x lane
    -- (at +0.5 L) when +x is its own direction, the -x lane (at -0.5 L) when +x runs against it.
    local ux, uz = dx, dz
    if kind == "T" then
        local side = (sx - best.px) * rx + (sz - best.pz) * rz
        -- Right of the nearest lane is away from its partner; if the side road is not that way, the
        -- nearest lane is the -x one.
        if side < 0 then ux, uz = -dx, -dz end
    end
    local vx, vz = -uz, ux
    local laneZ = (ux == dx and uz == dz) and 0.5 or -0.5
    local ox, oz = best.px - laneZ * L * vx, best.pz - laneZ * L * vz
    -- Along the road: the side road's middle on a T, else the cursor.
    local tx, tz = cx, cz
    if sx ~= nil then tx, tz = sx, sz end
    local along = (tx - ox) * ux + (tz - oz) * uz
    ox, oz = ox + along * ux, oz + along * uz
    -- SKEW: the side (or cross) road's own direction, from how its lanes run away from their ends. The
    -- piece's side arm leans to it (an X to 35 degrees off square, a T to 50); past that it stays square.
    local s2x, s2z = vx, vz
    if sx ~= nil then
        local ax, az, n = 0, 0, 0
        for _, w in ipairs(ends) do
            local nbId = (w.out ~= nil and w.out[1]) or (w.incoming ~= nil and w.incoming[1]) or nil
            local nb = nbId ~= nil and ADGraphManager:getWayPointById(nbId) or nil
            if nb ~= nil then
                local ex, ez = unit(nb.x - w.x, nb.z - w.z)      -- away from the main road
                -- Ends across the road (an X cut in two) run the other way: fold them onto +z. An end running
                -- along the main road (a stray) says nothing about the side road's angle: left out.
                if ex * vx + ez * vz < 0 then ex, ez = -ex, -ez end
                if ex * vx + ez * vz >= 0.5 then ax, az, n = ax + ex, az + ez, n + 1 end
            end
        end
        if n > 0 then
            local mx2, mz2 = unit(ax, az)
            -- As far as the mod's shape stays drivable: an X to 35 degrees off square, a T to 50.
            if mx2 * vx + mz2 * vz >= ((kind == "X") and 0.819 or 0.643) then s2x, s2z = mx2, mz2 end
        end
        -- The centre: where the side road's middle line meets the main road's.
        local c = s2x * vx + s2z * vz
        local t = ((ox - sx) * vx + (oz - sz) * vz) / c
        ox, oz = sx + t * s2x, sz + t * s2z
    end
    local cosS = s2x * vx + s2z * vz
    local e1x, e1z = L * ux, L * uz
    local e2x, e2z = L * s2x / cosS, L * s2z / cosS
    local function W(mx, mz) return ox + mx * e1x + mz * e2x, oz + mx * e1z + mz * e2z end
    local function D(mx, mz) return unit(mx * e1x + mz * e2x, mx * e1z + mz * e2z) end
    -- The corner cuts a quarter lane gap from each corner in METRES along each lane, so on a leaning
    -- piece the two bends of a cut stay equal (as in the fitted pattern's cutAt).
    local f1 = 0.25 * L / math.sqrt(e1x * e1x + e1z * e1z)
    local f2 = 0.25 * L / math.sqrt(e2x * e2x + e2z * e2z)
    local nodePos = {}
    for n, p in pairs(JX_PLAIN[kind].nodes) do nodePos[n] = p end
    local cuts = (kind == "X") and { [0] = { 3, 5 }, [1] = { 18, 20 }, [2] = { 13, 15 }, [3] = { 8, 10 } }
        or { [0] = { 3, 5 }, [3] = { 8, 10 } }
    for k, pair in pairs(cuts) do
        local fa, fb = f1, f2
        if k % 2 == 1 then fa, fb = f2, f1 end
        local ax, az, bx, bz = -0.5 - fa, 0.5, -0.5, 0.5 + fb
        for _ = 1, k do ax, az = -az, ax bx, bz = -bz, bx end
        nodePos[pair[1]], nodePos[pair[2]] = { ax, az }, { bx, bz }
    end
    local function roles(p)
        local r = {}
        if math.abs(p[2] - 0.5) < 1e-6 then r[#r + 1] = { 1, 0 } end
        if math.abs(p[2] + 0.5) < 1e-6 then r[#r + 1] = { -1, 0 } end
        if math.abs(p[1] + 0.5) < 1e-6 then r[#r + 1] = { 0, 1 } end
        if math.abs(p[1] - 0.5) < 1e-6 then r[#r + 1] = { 0, -1 } end
        return r
    end
    local piece = JX_PLAIN[kind]
    local ids = {}
    for n in pairs(piece.nodes) do ids[#ids + 1] = n end
    table.sort(ids)

    -- What would join and what would be left loose, worked out the same way dry or not.
    local loose = {}
    local function isArmEnd(p) return math.abs(p[1]) > 1.4 or math.abs(p[2]) > 1.4 end
    -- A TWO-WAY SIDE ROAD ending by the side arms (in game j66): its end takes both of them, lane out ->
    -- road end -> lane in, so they aren't left loose.
    local twoWayEnd = nil
    if kind == "T" then
        local mx0, mz0 = W(0, 1.5)
        local bd2 = (2 * L + 2) ^ 2
        for _, w in ipairs(ends) do
            local only = w.out ~= nil and w.out[1] or nil
            if only ~= nil and #w.out == 1 and #(w.incoming or {}) == 1 and w.incoming[1] == only then
                local d = (w.x - mx0) ^ 2 + (w.z - mz0) ^ 2
                if d < bd2 then twoWayEnd, bd2 = w, d end
            end
        end
    end
    -- Only where AutoDrive can drive it: every bend on lane out -> road end and road end -> lane in under
    -- 80 degrees. A road meeting far off square (j66, a Y) would double back; its arms stay loose instead.
    if twoWayEnd ~= nil then
        local function bend(ax, az, bx, bz)
            local n1, n2 = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
            if n1 < 1e-6 or n2 < 1e-6 then return 180 end
            return math.deg(math.acos(math.max(-1, math.min(1, (ax * bx + az * bz) / (n1 * n2)))))
        end
        local nb = ADGraphManager:getWayPointById(twoWayEnd.out[1])
        local p5x, p5z = W(nodePos[5][1], nodePos[5][2])
        local p6x, p6z = W(nodePos[6][1], nodePos[6][2])
        local p7x, p7z = W(nodePos[7][1], nodePos[7][2])
        local p8x, p8z = W(nodePos[8][1], nodePos[8][2])
        local wx, wz = twoWayEnd.x, twoWayEnd.z
        local ok = nb ~= nil
            and bend(p6x - p5x, p6z - p5z, wx - p6x, wz - p6z) < 80              -- out arm into the join
            and bend(wx - p6x, wz - p6z, nb.x - wx, nb.z - wz) < 80              -- join onto the road
            and bend(wx - nb.x, wz - nb.z, p7x - wx, p7z - wz) < 80              -- road into the join
            and bend(p7x - wx, p7z - wz, p8x - p7x, p8z - p7z) < 80              -- join into the in arm
        if not ok then twoWayEnd = nil end
    end
    if dry then
        for _, n in ipairs(ids) do
            local p = nodePos[n]
            local joined = false
            for _, r in ipairs(roles(p)) do
                local px, pz = W(p[1], p[2])
                local ddx, ddz = D(r[1], r[2])
                if jxpOnLane(px, pz, ddx, ddz, nil, true) then joined = true end
            end
            if not joined and isArmEnd(p) then
                local px, pz = W(p[1], p[2])
                loose[#loose + 1] = { x = px, z = pz, n = n }
            end
        end
        local lines = {}
        local l6, l7 = nil, nil
        for i, e in ipairs(loose) do if e.n == 6 then l6 = i elseif e.n == 7 then l7 = i end end
        if twoWayEnd ~= nil and l6 ~= nil and l7 ~= nil then
            local a6, a7 = loose[l6], loose[l7]
            lines[#lines + 1] = { pts = { { x = a6.x, z = a6.z }, { x = twoWayEnd.x, z = twoWayEnd.z } } }
            lines[#lines + 1] = { pts = { { x = twoWayEnd.x, z = twoWayEnd.z }, { x = a7.x, z = a7.z } } }
            table.remove(loose, math.max(l6, l7))
            table.remove(loose, math.min(l6, l7))
        end
        local set = {}
        for _, l in ipairs(piece.links) do set[l[1] .. ">" .. l[2]] = true end
        for _, l in ipairs(piece.links) do
            local dual = set[l[2] .. ">" .. l[1]] == true
            if not (dual and l[1] > l[2]) then
                local a, b = nodePos[l[1]], nodePos[l[2]]
                local ax, az = W(a[1], a[2])
                local bx, bz = W(b[1], b[2])
                lines[#lines + 1] = { pts = { { x = ax, z = az }, { x = bx, z = bz } }, dual = dual }
            end
        end
        return { shape = "plain", kind = kind, L = L, ox = ox, oz = oz, ux = ux, uz = uz, turns = 0,
                 loose = loose, partner = partner, lines = lines, marks = {} }
    end

    local node, onRole = {}, {}
    for _, n in ipairs(ids) do
        local p = nodePos[n]
        local px, pz = W(p[1], p[2])
        onRole[n] = {}
        for _, r in ipairs(roles(p)) do
            local ddx, ddz = D(r[1], r[2])
            local key = r[1] .. "," .. r[2]
            if node[n] == nil then
                local N = jxpOnLane(px, pz, ddx, ddz)
                if N ~= nil then node[n], onRole[n][key] = N, true end
            elseif jxpOnLane(px, pz, ddx, ddz, node[n]) ~= nil then
                onRole[n][key] = true
            end
        end
        if node[n] == nil then
            jxState.jxLayLabel = "plain"
            local N = ADFlyoverRecordWayPoint(px, jxpGroundY(px, pz, best.y), pz, false, false, false, 0,
                best.l.a.flags or AutoDrive.FLAG_NONE, false)
            jxNoteAdded(N)
            jxState.jxLayLabel = nil
            if N == nil then return nil, "could not add a point of the piece" end
            node[n] = N
            if isArmEnd(p) then loose[#loose + 1] = { x = px, z = pz, node = N, n = n } end
        end
    end
    local set = {}
    for _, l in ipairs(piece.links) do set[l[1] .. ">" .. l[2]] = true end
    local laid = 0
    for _, l in ipairs(piece.links) do
        local a, b = l[1], l[2]
        local dual = set[b .. ">" .. a] == true
        local onSameLane = false
        for k in pairs(onRole[a]) do if onRole[b][k] then onSameLane = true end end
        if not onSameLane and not (dual and a > b) and node[a] ~= node[b] then
            jxState.jxLaySeq = jxState.jxLaySeq + 1
            jxState.jxLayLabel = "plain#" .. jxState.jxLaySeq
            junctionConnect(node[a], node[b], dual)
            jxState.jxLayLabel = nil
            laid = laid + 1
        end
    end
    do
        local l6, l7 = nil, nil
        for i, e in ipairs(loose) do if e.n == 6 then l6 = i elseif e.n == 7 then l7 = i end end
        if twoWayEnd ~= nil and l6 ~= nil and l7 ~= nil then
            jxState.jxLaySeq = jxState.jxLaySeq + 1
            jxState.jxLayLabel = "plain#" .. jxState.jxLaySeq
            junctionConnect(node[6], twoWayEnd, false)
            junctionConnect(twoWayEnd, node[7], false)
            jxState.jxLayLabel = nil
            laid = laid + 2
            table.remove(loose, math.max(l6, l7))
            table.remove(loose, math.min(l6, l7))
            ADFlyoverSettings.debugLog("[FlyoverEditor]: junction plain - side arms joined to the two-way road's end at %.1f, %.1f.",
                twoWayEnd.x, twoWayEnd.z)
        end
    end
    ADFlyoverSettings.debugLog("[FlyoverEditor]: junction plain %s placed: lane gap %.1f m%s, centre %.1f, %.1f, %d link(s), %d loose end(s).",
        kind, L, partner and "" or " (no second lane found, 4 m used)", ox, oz, laid, #loose)
    for _, e in ipairs(loose) do
        ADFlyoverSettings.debugLog("[FlyoverEditor]:   loose end at %.1f, %.1f - join it by hand.", e.x, e.z)
    end
    return { shape = "plain", kind = kind, L = L, ox = ox, oz = oz, ux = ux, uz = uz, turns = laid,
             loose = loose, partner = partner }
end

-- PLACE (doc 08): the pattern fitted to the crossing where it fits, the plain piece everywhere else.
-- Only turn wiring still there, or no road at all, stops it.
local function junctionPlacePattern(cx, cz, reach, shape, dry)
    -- TWO-WAY ROADS ARE TABLED (decided 2026-10-05): a junction where any road running both ways meets is
    -- refused, fitted or plain, until there has been time to research how they should join. The two-way
    -- side road code below (twoWaySide in the fitted T, twoWayEnd in the plain piece) stays, switched off;
    -- FLYOVER_JUNCTION_PLACE_TWO_WAY = true brings it back.
    if AutoDrive.FLYOVER_JUNCTION_PLACE_TWO_WAY ~= true then
        for _, a in pairs(ADGraphManager:getWayPoints()) do
            if a ~= nil and a.id ~= nil and (a.x - cx) ^ 2 + (a.z - cz) ^ 2 <= 14 * 14 then
                for _, bid in ipairs(a.out or {}) do
                    local b = ADGraphManager:getWayPointById(bid)
                    if b ~= nil and table.contains(b.out or {}, a.id) then
                        return nil, "a two-way road meets here - two-way roads aren't handled yet"
                    end
                end
            end
        end
    end
    local res, why, wired = nil, "forced plain (test switch)", nil
    -- Test switch (harness): always the plain piece, without trying the fit at all.
    if AutoDrive.FLYOVER_JUNCTION_PLACE_FORCE_PLAIN ~= true then
        res, why, wired = junctionPlaceFitted(cx, cz, reach, shape, dry)
    end
    if res ~= nil or wired then return res, why, wired end
    local p, pwhy = junctionPlacePlain(cx, cz, dry)
    if p == nil then return nil, pwhy end
    p.fitWhy = why
    return p
end


-- THE ROUTE CHECK (docs/junction-tool/06-one-click-build.md, layout rule 7). A shared point lets
-- AutoDrive switch from one path to another wherever the bend there is 80 degrees or less
-- (GraphManager.prepareWayPoints), so two paths crossing at a shallow angle can open a route nobody
-- laid - a U-turn among them. From every lane in, this follows every route AutoDrive could take under
-- that rule until it reaches a lane out, and compares each lane-in/lane-out pair it finds with the
-- turns meant to be there: movements that already existed, and those this build laid. Anything else -
-- a pair skipped as a U-turn, refused as undrivable, or never asked for - is an extra route, but only
-- when it runs over at least one link this build laid: a route the roads already offered is not the
-- build's doing.
-- Returns { routes = <pairs found>, extra = { { from = <in node>, to = <out node>, why = ... } } }.
local function junctionRouteCheck(jp, placedSet, cx, cz, reach)
    local ins, outAt = {}, {}
    local function alive(w) return w ~= nil and w.id ~= nil and ADGraphManager:getWayPointById(w.id) == w end
    for _, ap in ipairs(jp.approaches or {}) do
        if alive(ap.wp) then
            if ap.dir == "in" then ins[#ins + 1] = ap else outAt[ap.wp] = true end
        end
    end
    -- What is meant: every movement that existed, and every one this build laid, by its two nodes.
    local meant, why = {}, {}
    local function key(a, b) return tostring(a) .. ">" .. tostring(b) end
    for _, m in ipairs(jp.movements or {}) do
        local k = key(m.from.wp, m.to.wp)
        -- "lane": skipped only because a closer lane makes the same turn - driving it is the same turn.
        -- "far": the two lanes belong to two separate crossings in one scope - a route between them runs
        -- through both junctions, and is neither junction's turn to judge.
        if m.exists or placedSet[m] or m.refused == "lane" or m.refused == "far" then
            meant[k] = true
        elseif why[k] == nil then
            why[k] = (m.refused ~= nil) and ("refused: " .. tostring(m.refused)) or "planned but not laid"
        end
    end
    local R2 = (reach + 10) ^ 2
    local function inRegion(w) return (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= R2 or outAt[w] ~= nil end
    local function bend(a, b, c)
        local ux, uz, vx, vz = b.x - a.x, b.z - a.z, c.x - b.x, c.z - b.z
        local nu, nv = math.sqrt(ux * ux + uz * uz), math.sqrt(vx * vx + vz * vz)
        if nu < 1e-6 or nv < 1e-6 then return 0 end
        return math.deg(math.acos(math.max(-1, math.min(1, (ux * vx + uz * vz) / (nu * nv)))))
    end
    local found, nRoutes, extra = {}, 0, {}
    for _, e in ipairs(ins) do
        local start = e.wp
        -- Seeded from every link into the lane's first point, so its first bend is judged too.
        local stack, seen = {}, {}
        for _, pid in ipairs(start.incoming or {}) do
            local p = ADGraphManager:getWayPointById(pid)
            if p ~= nil then stack[#stack + 1] = { p, start, false, { start } } end
        end
        if #stack == 0 then stack[1] = { nil, start, false, { start } } end
        while #stack > 0 do
            local top = table.remove(stack)
            local prev, cur, usedNew, path = top[1], top[2], top[3], top[4]
            local sk = tostring(prev) .. ">" .. tostring(cur) .. (usedNew and "+" or "")
            if not seen[sk] then
                seen[sk] = true
                if cur ~= start and outAt[cur] then
                    local k = key(start, cur)
                    if not found[k] then
                        found[k] = true
                        nRoutes = nRoutes + 1
                    end
                    if not meant[k] and usedNew and not found["x" .. k] then
                        found["x" .. k] = true
                        extra[#extra + 1] = { from = start, to = cur, why = why[k] or "no such turn was planned", path = path }
                    end
                else
                    for _, nid in ipairs(cur.out or {}) do
                        local nx = ADGraphManager:getWayPointById(nid)
                        if nx ~= nil and nx ~= prev and inRegion(nx)
                            and (prev == nil or bend(prev, cur, nx) <= 80) then
                            local np = {}
                            for i = 1, #path do np[i] = path[i] end
                            np[#np + 1] = nx
                            stack[#stack + 1] = { cur, nx, usedNew or jxIsNewLink(cur, nx), np }
                        end
                    end
                end
            end
        end
    end
    -- In a fixed order, so the log reads the same every run.
    table.sort(extra, function(p, q)
        if p.from.x ~= q.from.x then return p.from.x < q.from.x end
        if p.from.z ~= q.from.z then return p.from.z < q.from.z end
        if p.to.x ~= q.to.x then return p.to.x < q.to.x end
        return p.to.z < q.to.z
    end)
    -- And the other way round: a turn this build laid that no route can actually drive (a piece that
    -- did not join, or a bend over 80 degrees on the way).
    local missing = {}
    for _, m in ipairs(jp.movements or {}) do
        if placedSet[m] and alive(m.from.wp) and alive(m.to.wp) then
            local k = key(m.from.wp, m.to.wp)
            if not found[k] and not found["m" .. k] then
                found["m" .. k] = true
                missing[#missing + 1] = { from = m.from.wp, to = m.to.wp }
            end
        end
    end
    return { routes = nRoutes, extra = extra, missing = missing }
end

-- How far a fork may sit from the middle of its group and still belong to it, for the SELECTION's
-- fork clusters. Named, and up here, because the registry below has to hold lane ends away from
-- exactly the same clusters the selection does: two copies of a 12 would drift apart the first time
-- one of them was tuned, and the two would then disagree about which lane ends are loose.
local JUNCTION_FORK_LINK = 12

-- Group points by CENTROID linkage: a point joins a group while it lies within `link` of the
-- group's running middle, and the group is swept again whenever it grows, because its middle has
-- moved. Returns { x, z, nodes } per group, in the order their first members were met - so the
-- same list in the same order always comes back as the same groups.
local function junctionCentroidClusters(list, link)
    local used, out = {}, {}
    for i = 1, #list do
        if not used[i] then
            used[i] = true
            local grp, sx, sz, grew = { list[i] }, list[i].x, list[i].z, true
            while grew do
                grew = false
                for j = 1, #list do
                    if not used[j] then
                        local mx, mz = sx / #grp, sz / #grp
                        if (list[j].x - mx) ^ 2 + (list[j].z - mz) ^ 2 <= link * link then
                            used[j] = true
                            grp[#grp + 1] = list[j]
                            sx, sz, grew = sx + list[j].x, sz + list[j].z, true
                        end
                    end
                end
            end
            out[#out + 1] = { x = sx / #grp, z = sz / #grp, nodes = grp }
        end
    end
    return out
end

-- THE VIRGIN FORM OF A JUNCTION, found ONE way for everyone who asks. The selection needs it to
-- lock onto a cleared junction and the registry needs it to keep that junction's name, and if the
-- two each had their own idea of it, the card would sooner or later name a site the tool refuses
-- to lock, or lock one it cannot name.
--
-- Lane ends only form clusters of their OWN, away from any fork cluster - an end dangling beside a
-- wired junction is that junction's debris, not a second junction - and it takes three of them,
-- since two lane ends facing each other is a gap in a road. `forkSites` are centroid clusters of
-- forks (JUNCTION_FORK_LINK); `ends` are the points with exactly one neighbour.
local function junctionVirginSites(forkSites, ends)
    local loose = {}
    for _, e in ipairs(ends) do
        local nearFork = false
        for _, s in ipairs(forkSites) do
            if (s.x - e.x) ^ 2 + (s.z - e.z) ^ 2 <= 15 * 15 then nearFork = true break end
        end
        if not nearFork then loose[#loose + 1] = e end
    end
    local out = {}
    for _, s in ipairs(junctionCentroidClusters(loose, 14)) do
        if #s.nodes >= 3 then
            s.virgin = true
            out[#out + 1] = s
        end
    end
    return out
end

--- WHICH NETWORK A KEPT ANSWER WAS WORKED OUT ON. junctionCentres, junctionVirginCentres and
--- junctionRegistry keep their last answer while the number of points is unchanged. But undo and
--- redo put back a COPY of the whole network (EditorHistory's restore), with the same number of
--- points as before the clear, and the kept answer then named point tables that were no longer the
--- network's - moved by the clear that was undone, and renumbered by it. At 24, cleared in game right
--- after 16 had been cleared and undone, its forks were such dead points: the arms were walked from
--- the wrong live points, the bound read the two-way west road as not this junction's beyond 12 m,
--- and the tidy laid the road's new end one way only, the wrong way for traffic leaving. At 65,
--- cleared again after an undo, the check read its middle out to 30 m instead of 12. Point 1 stands
--- for the whole network: an edit in place keeps that table (or changes the count), and a swap of the
--- whole network - undo, redo, a route loaded - replaces it. Not the list table itself: the harness
--- makes a new list on every removal, and AutoDrive does not, so the two would stop agreeing.
--- Still not seen: an edit that moves points or links without changing the count (the move tool).
local function jxNetworkMark() return ADGraphManager:getWayPointById(1) end
local function jxSameNetwork(mark) return mark == ADGraphManager:getWayPointById(1) end

--- WHERE THE ROADS MEET, found from the roads and not from the forks. A cluster of forks is where
--- CONNECTORS START, and at a wide junction the tie forks sit 15-20 m out along every arm: clustering
--- them finds several "junctions" around one, puts the chosen one's middle on one end of it, and
--- leaves every later step - scope, arms, box, whose wiring is whose - working from the wrong place.
---
--- A turn connector bends from one road into another, so its two END TANGENTS, carried on, meet at
--- the corner it cuts - which is where those two roads cross. Every connector of a junction points
--- at the same spot, a kickout that starts 20 m up an arm included, so a junction's own far tie
--- forks need no rule to be recognised as its own; and a genuine neighbour is a different spot.
--- Checked against 34 hand labels of "separate junction" / "part of this one": all 34.
---
--- FLYOVER_JUNCTION_MERGE is how close two meeting points must be to count as ONE junction, and
--- it is the whole of the difference between reading a staggered crossing as two T's (10 m) or as
--- one offset 4-way (20 m).
---
--- It cannot see a junction with no connectors (a cleared one - the ring of lane ends finds those)
--- nor a shallow merge, whose branches leave at 15 degrees and cut no corner. Where it finds
--- nothing the selection falls back to the fork clusters, exactly as before.
--- WHERE A JUNCTION USED TO BE. A cleared junction has no connectors left to point at its middle,
--- so junctionCentres cannot see it - and everything around it then belongs to whatever wired
--- junction is nearest, which at a close pair is its neighbour. Clearing one of a pair and then the
--- other therefore ate the first one's road. What a cleared junction DOES have is a ring of lane
--- ends facing each other across where the roads met, and that ring is as good a marker as the
--- connectors were. Three or more, away from any fork, and their middle is the junction.
function ADFlyoverEditor:junctionVirginCentres()
    local count = ADGraphManager:getWayPointsCount()
    if self._jxVirgin ~= nil and self._jxVirginCount == count and jxSameNetwork(self._jxVirginNet) then
        return self._jxVirgin
    end
    local forks, ends = {}, {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil then
            local s2, d = {}, 0
            for _, id in ipairs(w.out or {}) do if not s2[id] then s2[id] = true d = d + 1 end end
            for _, id in ipairs(w.incoming or {}) do if not s2[id] then s2[id] = true d = d + 1 end end
            if d >= 3 then forks[#forks + 1] = w elseif d == 1 then ends[#ends + 1] = w end
        end
    end
    local loose = {}
    for _, e in ipairs(ends) do
        -- Only a fork that is NOT itself a cut lane end's neighbour counts as "this end belongs to a
        -- wired junction": at a close pair the cleared branch's ends sit a few metres from the other
        -- junction's forks, and excluding them left the cleared junction invisible.
        local nearFork = false
        for _, f in ipairs(forks) do
            if (f.x - e.x) ^ 2 + (f.z - e.z) ^ 2 <= 4 * 4 then nearFork = true break end
        end
        if not nearFork then loose[#loose + 1] = e end
    end
    local used, out = {}, {}
    for i = 1, #loose do
        if not used[i] then
            used[i] = true
            local grp, sx, sz, grew = { loose[i] }, loose[i].x, loose[i].z, true
            while grew do
                grew = false
                for j = 1, #loose do
                    if not used[j] then
                        local mx, mz = sx / #grp, sz / #grp
                        if (loose[j].x - mx) ^ 2 + (loose[j].z - mz) ^ 2 <= 14 * 14 then
                            used[j] = true
                            grp[#grp + 1] = loose[j]
                            sx, sz, grew = sx + loose[j].x, sz + loose[j].z, true
                        end
                    end
                end
            end
            -- TWO IS ENOUGH TO OWN A ROAD. A junction cleared with through paths kept loses only its
            -- branch, so it shows just the two ends of that branch - not the three or more a fully
            -- cleared one shows. For SELECTION that is too little to call a junction; for saying
            -- whose road is whose it is plenty, and without it a cleared neighbour owns nothing and
            -- its road is eaten by the next clear along.
            if #grp >= 2 then
                out[#out + 1] = { x = sx / #grp, z = sz / #grp, n = #grp, virgin = true }
            end
        end
    end
    self._jxVirgin, self._jxVirginCount, self._jxVirginNet = out, count, jxNetworkMark()
    return out
end

function ADFlyoverEditor:junctionCentres()
    local count = ADGraphManager:getWayPointsCount()
    local merge = AutoDrive.FLYOVER_JUNCTION_MERGE or 10
    if self._jxCentres ~= nil and self._jxCentresCount == count and self._jxCentresMerge == merge
        and jxSameNetwork(self._jxCentresNet) then
        return self._jxCentres
    end
    local wps = ADGraphManager:getWayPoints()
    local deg = {}
    for _, w in pairs(wps) do
        if w ~= nil and w.id ~= nil then
            local s, n = {}, 0
            for _, id in ipairs(w.out or {}) do if not s[id] then s[id] = true n = n + 1 end end
            for _, id in ipairs(w.incoming or {}) do if not s[id] then s[id] = true n = n + 1 end end
            deg[w] = n
        end
    end
    local function wrap(d)
        while d > math.pi do d = d - 2 * math.pi end
        while d < -math.pi do d = d + 2 * math.pi end
        return d
    end
    -- TWO LANES CROSSING ARE NOT A FORK (39, in the game). Two turns crossing inside 39 had a point
    -- each 0.23 m apart, folded into one before the session (jxCrossingPairs). That point has two ways
    -- in and two ways out and read as a fork: it cut a 22 m turn in half, the half-turn's corner
    -- started 39's group early and let a stray corner in, and 39's middle moved 3.4 m. Its circle then
    -- cut the roads inside their bends, and the main road was no longer read as running through - cut
    -- at (0.9, -13.6). Each lane is walked straight through such a point, and it starts no chain.
    local passOn = {}
    for _, w in pairs(wps) do
        if w ~= nil and deg[w] == 4 then passOn[w] = jxCrossingPairs(w) end
    end
    for w in pairs(passOn) do deg[w] = 2 end
    local corners = {}
    for _, f in pairs(wps) do
        if f ~= nil and (deg[f] or 0) >= 3 then
            for _, oid in ipairs(f.out or {}) do
                local o = ADGraphManager:getWayPointById(oid)
                if o ~= nil then
                    local chain, prev, cur, len = { f, o }, f, o, math.sqrt((o.x - f.x) ^ 2 + (o.z - f.z) ^ 2)
                    while (deg[cur] or 0) == 2 and #chain < 200 and len <= 60 do
                        local nxt = passOn[cur] and passOn[cur][prev] or nil
                        if passOn[cur] == nil then
                            for _, nid in ipairs(cur.out or {}) do
                                local w = ADGraphManager:getWayPointById(nid)
                                if w ~= nil and w ~= prev then nxt = w break end
                            end
                        end
                        if nxt == nil then break end
                        len = len + math.sqrt((nxt.x - cur.x) ^ 2 + (nxt.z - cur.z) ^ 2)
                        prev, cur = cur, nxt
                        chain[#chain + 1] = cur
                    end
                    local last = chain[#chain]
                    if #chain >= 3 and (deg[last] or 0) >= 3 and len <= 60 then
                        local a0 = math.atan2(chain[2].x - chain[1].x, chain[2].z - chain[1].z)
                        local a1 = math.atan2(last.x - chain[#chain - 1].x, last.z - chain[#chain - 1].z)
                        local turn = math.abs(wrap(a1 - a0))
                        if turn >= math.rad(30) and turn <= math.rad(150) then
                            local d1x, d1z, d2x, d2z = math.sin(a0), math.cos(a0), math.sin(a1), math.cos(a1)
                            local den = d1x * d2z - d1z * d2x
                            if math.abs(den) > 1e-6 then
                                local t = ((last.x - f.x) * d2z - (last.z - f.z) * d2x) / den
                                local px, pz = f.x + d1x * t, f.z + d1z * t
                                if (px - f.x) ^ 2 + (pz - f.z) ^ 2 <= 60 * 60 then
                                    corners[#corners + 1] = { x = px, z = pz, chain = chain }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local groups = {}
    for _, c in ipairs(corners) do
        local hit = nil
        for _, g in ipairs(groups) do
            if (c.x - g.x) ^ 2 + (c.z - g.z) ^ 2 <= merge * merge then hit = g break end
        end
        if hit == nil then
            hit = { x = c.x, z = c.z, sx = 0, sz = 0, n = 0, forks = {}, wiring = {} }
            groups[#groups + 1] = hit
        end
        hit.sx, hit.sz, hit.n = hit.sx + c.x, hit.sz + c.z, hit.n + 1
        hit.x, hit.z = hit.sx / hit.n, hit.sz / hit.n
        hit.forks[c.chain[1]] = true
        hit.forks[c.chain[#c.chain]] = true
        for i = 2, #c.chain - 1 do hit.wiring[c.chain[i]] = true end
    end
    local out = {}
    for _, g in ipairs(groups) do
        if g.n >= 2 then out[#out + 1] = g end
    end
    self._jxCentres, self._jxCentresCount, self._jxCentresMerge = out, count, merge
    self._jxCentresNet = jxNetworkMark()
    return out
end

--- STEP 1 OF A CLEAR: pick ONE junction from a click, and say whether it is a junction at all.
---
--- The cluster of forks nearest the cursor is the site. What it does NOT do is decide how much road
--- belongs to that site - that is a property of the road, settled later by walking each arm out to
--- the next fork - so two crossings a few metres apart may well land in one cluster here and still
--- be worked on separately afterwards.
---
--- REAL OR FAUX. A junction is where roads meet, so it needs at least three arms that actually go
--- somewhere. Counted by BEARING, not by lane, or a plain T with two lanes on each of its roads
--- reads as six arms; and measured by how far each one runs before it forks again or simply stops.
--- A field entrance, a lay-by, and the stub of a connector whose junction was removed years ago all
--- present as a third arm a few metres long, and clearing around one does damage for no gain.
---
--- Returns a site table, or nil and a reason - and a reason is meant to be shown, not swallowed:
--- refusing without saying why is indistinguishable from the tool being broken.
function ADFlyoverEditor:junctionSelect(cx, cz)
    if cx == nil or cz == nil then return nil, "no cursor" end
    local SELECT = AutoDrive.FLYOVER_JUNCTION_SELECT_RADIUS or 20
    local MINARM = AutoDrive.FLYOVER_JUNCTION_MIN_ARM or 15
    local GATHER, LINK = 70, JUNCTION_FORK_LINK
    local WALK = 40

    local function neighbours(w)
        local s, n = {}, 0
        for _, id in ipairs(w.out or {}) do
            if not s[id] then s[id] = true n = n + 1 end
        end
        for _, id in ipairs(w.incoming or {}) do
            if not s[id] then s[id] = true n = n + 1 end
        end
        return s, n
    end

    -- A JUNCTION COMES IN TWO FORMS, and both are junctions. WIRED: its roads are joined by turn
    -- connectors, and it shows as a cluster of forks. VIRGIN: cleared, or never built - the roads
    -- cross but nothing joins them, and it shows as a ring of LANE ENDS facing each other across the
    -- crossing. The virgin form is the one a build starts from, and if anything it is the easier to
    -- recognise; a selection that only knew forks could not see a junction the moment it had been
    -- cleared.
    local forks, ends = {}, {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= GATHER * GATHER then
            local _, deg = neighbours(w)
            if deg >= 3 then forks[#forks + 1] = w
            elseif deg == 1 then ends[#ends + 1] = w end
        end
    end

    -- Forks are clustered exactly as they always were, so a wired junction is found just where it
    -- was found before. The virgin sites come from the helper the registry shares (above), which
    -- holds the rule for them: clusters of lane ends, away from every fork cluster, three or more.
    local sites = junctionCentroidClusters(forks, LINK)
    for _, s in ipairs(junctionVirginSites(sites, ends)) do
        sites[#sites + 1] = s
    end
    if #sites == 0 then return nil, "no junction near the cursor" end

    for _, s in ipairs(sites) do s.d2 = (s.x - cx) ^ 2 + (s.z - cz) ^ 2 end
    table.sort(sites, function(a, b) return a.d2 < b.d2 end)
    if sites[1].d2 > SELECT * SELECT then
        return nil, string.format("the nearest junction is %.0f m away - click closer to it",
            math.sqrt(sites[1].d2))
    end

    -- REAL OR FAUX, asked of each candidate in turn from the nearest outwards: the first that passes
    -- is the site. Taking the nearest and stopping there let a stray cluster beside a real junction
    -- - three lane ends at a field gate - be picked, fail, and refuse the click outright with the
    -- real junction a few metres further on.
    local function evaluate(best)
        local inCluster = {}
        for _, f in ipairs(best.nodes) do inCluster[f.id] = true end
        local arms = {}
        for _, f in ipairs(best.nodes) do
            local nb = neighbours(f)
            for id in jxByPlace(nb) do
                if not inCluster[id] then
                    local w = ADGraphManager:getWayPointById(id)
                    -- a way on that is one of this junction's own connectors is not an arm of it
                    if w ~= nil and best.wiring ~= nil and best.wiring[w] then w = nil end
                    if w ~= nil then
                        local len, prev, cur, hitFork = 0, f, w, false
                        local seen = { [f.id] = true }
                        local walked = {}
                        while cur ~= nil and len < WALK do
                            len = len + math.sqrt((cur.x - prev.x) ^ 2 + (cur.z - prev.z) ^ 2)
                            seen[cur.id] = true
                            walked[#walked + 1] = cur
                            local cnb, cdeg = neighbours(cur)
                            if cdeg >= 3 then hitFork = true break end
                            local nxt = nil
                            for nid in jxByPlace(cnb) do
                                if not seen[nid] then nxt = ADGraphManager:getWayPointById(nid) break end
                            end
                            if nxt == nil then break end
                            prev, cur = cur, nxt
                        end
                        arms[#arms + 1] = {
                            bearing = math.atan2(w.x - best.x, w.z - best.z),
                            -- Clamped, because the walk adds a whole segment before it re-tests the
                            -- cap: a 10 m hop at the end of a 39 m arm had the arm reported as 49 m,
                            -- and the bound is only ever as tight as the arm it is told about.
                            len = math.min(len, WALK), node = w, fork = hitFork,
                            stop = hitFork and cur or nil,
                            deadEnd = (not hitFork and len < WALK) and cur or nil,
                            walked = walked,
                        }
                    end
                end
            end
        end

        -- Fold the lanes of one road together: same bearing, so a two-lane road counts once. The arm
        -- keeps the LONGEST of its lanes - one lane of a road being stubbed does not shorten the road.
        local roads = {}
        for _, a in ipairs(arms) do
            local joined = nil
            for _, r in ipairs(roads) do
                local d = math.abs(a.bearing - r.bearing) % (2 * math.pi)
                if d > math.pi then d = 2 * math.pi - d end
                if d <= math.rad(30) then joined = r break end
            end
            if joined == nil then
                joined = { bearing = a.bearing, len = a.len, n = 1, fork = a.fork, stops = {}, deadEnds = {} }
                roads[#roads + 1] = joined
            else
                joined.n = joined.n + 1
                if a.len > joined.len then joined.len, joined.fork = a.len, a.fork end
            end
            if a.stop ~= nil then joined.stops[#joined.stops + 1] = a.stop end
            if a.deadEnd ~= nil then joined.deadEnds[#joined.deadEnds + 1] = a.deadEnd end
            joined.walked = joined.walked or {}
            for _, wn in ipairs(a.walked or {}) do joined.walked[wn] = true end
        end

        -- A CLEARED PART BESIDE ITS TWIN: an arm that runs into the twin's forks goes somewhere,
        -- however short. With the user's split saved and through roads off, a part's clear keeps
        -- the road its twin's turn leaves and stops short of it, so the arm from cleared 26s towards
        -- 26n ends 5 m out, at the fork 26n's left turn leaves the road from (best.partOf: the site
        -- found below, "A CLEARED PART OF A SPLIT JUNCTION").
        local inOther = {}
        if best.partOf then
            for _, s2 in ipairs(sites) do
                if s2 ~= best and not s2.virgin and s2.nodes ~= nil and #s2.nodes >= 2 then
                    for _, fk in ipairs(s2.nodes) do inOther[fk] = true end
                end
            end
        end
        local going = 0
        for _, r in ipairs(roads) do
            local toTwin = false
            if best.partOf then
                for _, st in ipairs(r.stops or {}) do
                    if inOther[st] and not inCluster[st.id] then toTwin = true end
                end
            end
            if r.len >= MINARM or toTwin then going = going + 1 end
        end
        if #roads < 3 then
            return nil, string.format("only %d road%s meets here - not a junction",
                #roads, #roads == 1 and "" or "s")
        end
        -- The arm-length test polices STRAYS - a lone fork, a field gate, a lay-by. A proper cluster
        -- of forks is a junction by the survey's own definition and is not asked to prove it: at a
        -- close pair, once the neighbour is cleared, the arm towards it ends at the neighbour's box
        -- 13 m away, and a junction with seven forks of wiring in it was refused as "a turning or
        -- an entrance" for having only two long arms.
        local proper = ((not best.virgin) and #best.nodes >= 4) or best.fromRoads == true
        if going < 3 and not proper then
            return nil, string.format("%d of the %d arms here go anywhere (the rest stop within %d m) - a turning or an entrance, not a junction",
                going, #roads, MINARM)
        end
        return { x = best.x, z = best.z, forks = best.nodes, roads = roads, nArms = #roads,
                 virgin = (best.virgin == true), fromRoads = (best.fromRoads == true) }
    end

    -- ...BUT NEVER PAST A REAL JUNCTION. Trying the next candidate is for stepping over a stray -
    -- three lane ends at a field gate. When the nearest candidate is itself a proper cluster of
    -- forks, that IS what was clicked on, and its verdict stands whether it passes or not: carrying
    -- on past it answered a click on a wired junction with the state of the one next door, 17 m
    -- away and already cleared - "this junction is already clear", said of a junction with seven
    -- forks still in it.
    -- A CLEARED PART OF A SPLIT JUNCTION, BESIDE ITS TWIN STILL WIRED. A cleared junction is found by
    -- its ring of lane ends, held 15 m clear of every fork - an end beside a wired junction is that
    -- junction's. The parts of a split can be closer than that: 26n and 26s are 12 m apart, and
    -- once 26s is cleared with through roads off and 26n left working (the user's rules of
    -- 2026-10-03), every lane end of 26s lies within 15 m of 26n's forks, no ring is found, and a
    -- click on cleared 26s locked 26n. So where the click is on a part the user saved (within 5 m,
    -- JX_PART_AT, which is declared further down), no place where roads meet lies within 8 m of it
    -- (it has no wiring of its own), another part of the same junction is still wired, and three or
    -- more lane ends lie within 15 m of it, those ends are that part's cleared site, asked the same
    -- questions as any other - but only where the usual selection below would lock a site 8 m or
    -- more from the part (its twin) or nothing at all: at 20, cleared 20s is found by its ring as
    -- before. Never where both parts are cleared (72, 73): the usual ring finds their shared middle.
    -- Read from the registry as it was last built (self._jxReg), never by building it: the registry
    -- asks this selection about every cleared site while it is being built.
    -- AutoDrive.FLYOVER_JUNCTION_PART_ROAD = false turns this off, with the road between parts.
    local onPart, partSite = nil, nil
    if self._jxReg ~= nil and AutoDrive.FLYOVER_JUNCTION_PART_ROAD ~= false then
        local centres = nil
        local function wiredAt(q)
            centres = centres or (self:junctionCentres() or {})
            for _, c in ipairs(centres) do
                if (c.x - q.x) ^ 2 + (c.z - q.z) ^ 2 <= 8 * 8 then return true end
            end
            for _, s2 in ipairs(sites) do
                if not s2.virgin and s2.nodes ~= nil and #s2.nodes >= 4
                    and (s2.x - q.x) ^ 2 + (s2.z - q.z) ^ 2 <= 8 * 8 then return true end
            end
            return false
        end
        for _, f in ipairs(self._jxReg) do
            if onPart == nil and f.decision == "split" and f.parts ~= nil then
                for _, p in ipairs(f.parts) do
                    if onPart == nil and (p.x - cx) ^ 2 + (p.z - cz) ^ 2 <= 5 * 5 and not wiredAt(p) then
                        local twinWired = false
                        for _, q in ipairs(f.parts) do
                            if q ~= p and wiredAt(q) then twinWired = true end
                        end
                        if twinWired then onPart = p end
                    end
                end
            end
        end
    end
    -- The cleared part's own site, tried only where the usual answer is its twin or nothing.
    local function partSiteFor(site)
        if onPart == nil then return site end
        if site ~= nil and (site.x - onPart.x) ^ 2 + (site.z - onPart.z) ^ 2 < 8 * 8 then return site end
        if partSite == nil then
            local own, sx, sz = {}, 0, 0
            for _, e in ipairs(ends) do
                if (e.x - onPart.x) ^ 2 + (e.z - onPart.z) ^ 2 <= 15 * 15 then
                    own[#own + 1] = e
                    sx, sz = sx + e.x, sz + e.z
                end
            end
            partSite = false
            if #own >= 3 then
                table.sort(own, jxBeforeInPlace)
                partSite = evaluate({ x = sx / #own, z = sz / #own, nodes = own, virgin = true, partOf = true }) or false
            end
        end
        if partSite then return partSite end
        return site
    end
    -- ROADS FIRST. Where the roads themselves say there is a junction near the click, that is the
    -- junction: its middle is where they meet, and its forks are the ends of the connectors that
    -- point there - however far up the arms those sit. The fork clusters below are only the
    -- fallback, for what the roads cannot show: a cleared junction (no connectors left to point
    -- anywhere) and a shallow merge (no corner cut). A cleared junction that is NEARER the click
    -- than any wired one still wins, so a virgin site beside a wired one can be picked.
    if AutoDrive.FLYOVER_JUNCTION_ROADS_FIRST ~= false then
        local bestC, bd = nil, SELECT * SELECT
        for _, c in ipairs(self:junctionCentres() or {}) do
            local d = (c.x - cx) ^ 2 + (c.z - cz) ^ 2
            if d < bd then bd, bestC = d, c end
        end
        local virginNearer = false
        for _, s in ipairs(sites) do
            if s.virgin and s.d2 < bd then virginNearer = true break end
        end
        if bestC ~= nil and not virginNearer then
            -- IN A FIXED ORDER. `forks` is a set keyed by the node TABLES, and Lua hashes a table
            -- key by its address, so pairs() walks it in whatever order the memory happened to fall
            -- in - a different order in every process. That order reaches the arms, and through them
            -- the box and what gets cleared: the same clear on the same network took 43 points
            -- reaching 43 m four runs out of five, and 42 points reaching 17 m on the fifth.
            --
            -- Sorted by POSITION, not by id, because ids are reissued by every removal while a
            -- point's place on the map is its own.
            local nodes = {}
            for fk in pairs(bestC.forks) do
                if fk.id ~= nil then nodes[#nodes + 1] = fk end
            end
            table.sort(nodes, function(a, b)
                if a.x ~= b.x then return a.x < b.x end
                if a.z ~= b.z then return a.z < b.z end
                return (a.y or 0) < (b.y or 0)
            end)
            local site = evaluate({ x = bestC.x, z = bestC.z, nodes = nodes, wiring = bestC.wiring, fromRoads = true })
            if site ~= nil then return partSiteFor(site) end
        end
    end
    local firstWhy = nil
    for _, s in ipairs(sites) do
        if s.d2 > SELECT * SELECT then break end
        local site, why = evaluate(s)
        if site ~= nil then return partSiteFor(site) end
        firstWhy = firstWhy or why
        if not s.virgin and #s.nodes >= 4 then break end
    end
    local ps = partSiteFor(nil)
    if ps ~= nil then return ps end
    return nil, firstWhy or "no junction near the cursor"
end

-- Where the numbers live between sessions: beside AutoDrive's own route file, in the savegame's
-- folder, because they name the junctions of THIS network and a second savegame on the same map
-- carries a different one. The folder is worked out the way AutoDrive works out its own
-- (XML.lua, getXMLFile_new), so the two files cannot end up in different places.
local JUNCTION_REGISTRY_FILE = "ADFlyoverEditor_junctions.xml"

local function junctionRegistryFolder()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if info == nil then return nil end
    if info.savegameDirectory ~= nil then return info.savegameDirectory .. "/" end
    if info.savegameIndex ~= nil and getUserProfileAppPath ~= nil then
        return getUserProfileAppPath() .. "savegame" .. info.savegameIndex .. "/"
    end
    return nil
end

-- WHOSE NUMBERS THEY ARE. The numbers and decisions in memory belong to the game they were read in
-- and the folder they were read from (the registry's "home"), and are only ever written back there.
-- This table outlives a mission: leave to the menu and load another savegame, and the old editor
-- keeps getting update() until its files are sourced again - and the folder, worked out afresh at
-- write time, was by then the other career's. A decision waiting for a career's first save was
-- written into the next career loaded, over that career's own numbers and decisions.
--
-- A folder compared as a folder: one slash kind, no doubled or trailing slash, any case (Windows).
-- A career's first save sets savegameDirectory, where the folder was worked out from the slot
-- number until then - the same folder, the same key.
local function jxFolderKey(folder)
    if folder == nil then return nil end
    return (folder:gsub("\\", "/"):gsub("/+", "/"):gsub("/$", ""):lower())
end

--- The game loaded now and its folder: what a registry read now belongs to.
local function jxHomeNow()
    local folder = junctionRegistryFolder()
    return { mission = g_currentMission, folder = folder, key = jxFolderKey(folder) }
end

--- Is `home` still the game loaded now, with the same folder?
local function jxHomeIsHere(home)
    if home == nil or g_currentMission == nil or home.mission ~= g_currentMission then return false end
    local folder = junctionRegistryFolder()
    if folder == home.folder then return true end
    return jxFolderKey(folder) == home.key
end

-- ONE FILE MAY HOLD ONLY 200 LOCAL NAMES AT ONCE (Lua 5.1). The local helpers from here to the
-- matching "end" are used nowhere after it, so they are scoped to this block and free their slots.
do
-- ---------------------------------------------------------------------------------------------
-- DEBUG CAPTURE: THE NETWORK EITHER SIDE OF EVERY CHANGE, PLUS WHAT THE TOOL SAID WHILE MAKING IT.
--
-- A fault you can see on your screen and I cannot reproduce on mine is the expensive kind. A whole
-- day went into one: four offline tests all came back clean because my copy of the network was not
-- the one the fault was in, and the junction had been renumbered in between, so we were not even
-- discussing the same crossing. What finally settled it in a single step was a pair of hand-saved
-- networks from either side of one clear. This does that automatically.
--
-- Each change writes a numbered folder under the savegame:
--
--     flyoverDebug/0007_clear_j60_-921.9_-46.9/
--         meta.txt   build, tool, settings, where it was locked, what it was called
--         pre.xml    the network before
--         post.xml   the network after
--         tool.log   every line this tool logged while doing it
--
-- The number leads: click through a sequence and the folders read in the order you did them, so a
-- fault that only appears when one thing follows another can be followed the same way.
--
-- pre.xml and post.xml are AutoDrive's OWN route format, written by AutoDrive's own writer. Nothing
-- new to parse and nothing new to get wrong: the game will load either one straight back in, and it
-- is the same format as the routes saved by hand that solved this in the first place.
--
-- Off unless switched on, and never on by accident - the toggle is on the junction card, it says so
-- while it is on, and it costs nothing at all while it is off.
local FLYOVER_DEBUG_DIR = "flyoverDebug/"
local jxDebugSeq = 0

--- EVERY LINE THE TOOL SAYS WHILE A CAPTURE IS RUNNING, taken at the source.
---
--- The first version read log.txt instead - remembering how long it was at the start and taking
--- whatever had been added by the end. It came back empty every time: FS25 buffers that file, so at
--- the moment a clear finishes none of its lines have reached the disk yet. The capture wrote a
--- one-byte tool.log beside two perfectly good network snapshots.
---
--- So the lines are taken where they are made. Logging is wrapped for the length of the capture and
--- put back afterwards, and each call is passed straight through - nothing is swallowed, and the
--- game's own log is unchanged.
local jxDebugLines = nil
local jxDebugSaved = nil
local jxDebugWritten = 0          -- how many lines a previous capture has already taken
local JX_DEBUG_KEEP = 4000

--- EVERYTHING THE TOOL SAID, FROM THE MOMENT CAPTURE WAS SWITCHED ON.
---
--- Capture used to begin when a change began, and a junction is worked out BEFORE that: which
--- crossing was picked, how the arms read, which turns were refused, what kind of junction it was
--- called. All of that happens at lock time and none of it was in the folder - so the capture could
--- say a site had been read as a 4-way offset but not why, and answering that meant going to the
--- game's own log, which is overwritten on every launch and holds every other mod's output too.
---
--- So the wrap goes on when capture is switched ON and stays on, collecting into a ring buffer. Each
--- capture then writes everything logged since the PREVIOUS capture: the lock that led to it, the
--- change itself, and anything in between. One folder, whole story, nothing to fetch separately.
local function jxDebugLogArm()
    if Logging == nil or jxDebugSaved ~= nil then return end
    jxDebugLines, jxDebugWritten = {}, 0
    jxDebugSaved = { info = Logging.info, warning = Logging.warning, error = Logging.error }
    local function wrap(level, original)
        return function(fmt, ...)
            if jxDebugLines ~= nil then
                local ok, line = pcall(string.format, fmt, ...)
                jxDebugLines[#jxDebugLines + 1] = level .. (ok and line or tostring(fmt))
                -- Bounded, so a long session cannot grow without limit. Trimming loses the oldest
                -- lines, so the count already written is pulled back with it.
                if #jxDebugLines > JX_DEBUG_KEEP then
                    local drop = #jxDebugLines - JX_DEBUG_KEEP
                    local keep = {}
                    for i = drop + 1, #jxDebugLines do keep[#keep + 1] = jxDebugLines[i] end
                    jxDebugLines = keep
                    jxDebugWritten = math.max(0, jxDebugWritten - drop)
                end
            end
            if original ~= nil then return original(fmt, ...) end
        end
    end
    Logging.info = wrap("", jxDebugSaved.info)
    Logging.warning = wrap("WARNING: ", jxDebugSaved.warning)
    Logging.error = wrap("ERROR: ", jxDebugSaved.error)
end

--- Put Logging back. Always restores, even if nothing was collected.
local function jxDebugLogDisarm()
    if jxDebugSaved ~= nil and Logging ~= nil then
        Logging.info, Logging.warning, Logging.error =
            jxDebugSaved.info, jxDebugSaved.warning, jxDebugSaved.error
    end
    jxDebugSaved, jxDebugLines, jxDebugWritten = nil, nil, 0
end

--- Everything logged since the last capture took its share, and mark it taken.
local function jxDebugLogTake()
    local out = {}
    for i = jxDebugWritten + 1, #(jxDebugLines or {}) do out[#out + 1] = jxDebugLines[i] end
    jxDebugWritten = #(jxDebugLines or {})
    return out
end

--- Write the whole network, as AutoDrive writes its routes. True when the file is there.
local function jxDebugWriteGraph(path)
    if createXMLFile == nil or AutoDrive == nil or AutoDrive.writeGraphToXml == nil then return false end
    local ok = pcall(function()
        local xml = createXMLFile("flyoverDebug_xml", path, "routeExport")
        if xml == nil or xml == -1 then return end
        AutoDrive.writeGraphToXml(xml, "routeExport", ADGraphManager:getWayPoints(),
            ADGraphManager:getMapMarkers(), ADGraphManager:getGroups())
        saveXMLFile(xml)
        delete(xml)
    end)
    return ok == true
end

--- THE MAP'S OWN ROADS, SAVED FOR THE HARNESS. The traffic splines are the lines the game's AI
--- traffic drives, and what AutoDrive builds a map's network from when it scans it. They are the
--- map maker's roads, independent of any flag on a waypoint, so they say which lanes lie on a real
--- road. Written to <savegame>/ADFlyoverEditor_roadSplines.xml, one entry per spline: its length and
--- its centre-line sampled every `step` metres as "x,z;x,z;...". Returns the count and the path.
function ADFlyoverEditor:dumpRoadSplines(step)
    step = step or 2
    local ai = g_currentMission ~= nil and g_currentMission.aiSystem or nil
    local splines = ai ~= nil and ai.roadSplines or nil
    if splines == nil then return nil, "this map has no traffic splines the game has loaded" end
    local root = junctionRegistryFolder()
    if root == nil then return nil, "no savegame folder yet - save the game once first" end
    local path = root .. "ADFlyoverEditor_roadSplines.xml"
    local xml = createXMLFile("flyoverRoadSplines", path, "roadSplines")
    if xml == nil or xml == -1 then return nil, "could not create " .. path end
    local n = 0
    for _, spline in pairs(splines) do
        local len = getSplineLength(spline) or 0
        if len > 0 then
            local pts, k = {}, math.max(1, math.floor(len / step))
            for i = 0, k do
                local x, _, z = getSplinePosition(spline, i / k)
                if x ~= nil then pts[#pts + 1] = string.format("%.2f,%.2f", x, z) end
            end
            local key = string.format("roadSplines.spline(%d)", n)
            setXMLString(xml, key .. "#name", tostring(getName(spline) or ""))
            setXMLFloat(xml, key .. "#length", len)
            setXMLString(xml, key .. "#points", table.concat(pts, ";"))
            n = n + 1
        end
    end
    saveXMLFile(xml)
    delete(xml)
    return n, path
end

--- Start and stop collecting, for the toggle. Methods, because the toggle sits well above these
--- file-locals and a file-local named from above binds to a global instead.
function ADFlyoverEditor:debugCaptureArm() jxDebugLogArm() end
function ADFlyoverEditor:debugCaptureDisarm() jxDebugLogDisarm() end

--- Where captures are being written, and how many have been written this session. A method, so the
--- card and the toggle can ask without reaching for file-locals declared below them.
function ADFlyoverEditor:debugCaptureWhere()
    local root = junctionRegistryFolder()
    if root == nil then return nil, jxDebugSeq end
    return root .. FLYOVER_DEBUG_DIR, jxDebugSeq
end

--- Begin capturing one change. `what` names the operation ("clear", "build"), `site` is where it
--- was locked and may be nil. Returns the folder it will write into, or nil when capture is off or
--- there is nowhere to write - and everything after it then does nothing, so no caller needs to ask
--- whether capture is on.
---
--- The pre-state is written HERE, before the change, because there is no getting it back afterwards.
---
--- `jname` is what the junction is called (jp.junctionName: "j39se" once the user has split 39),
--- worked out from where the selection locked it. Without it the number is looked up from `site`,
--- which by now is the box's middle - and at 26 that is nearer the other half.
function ADFlyoverEditor:debugCaptureBegin(what, site, extra, jname)
    if AutoDrive.FLYOVER_DEBUG_CAPTURE ~= true then return nil end
    local root = junctionRegistryFolder()
    if root == nil then return nil end

    jxDebugSeq = jxDebugSeq + 1
    local name
    if site ~= nil and site.x ~= nil then
        -- The number is in the folder name so a sequence can be talked about, and the COORDINATE is
        -- in it too because the number is only good for this session - clearing junctions reshuffles
        -- them, and a capture read back tomorrow would otherwise name a different crossing.
        local n = self:junctionNumberAt(site.x, site.z)
        local label = jname
        if label == nil and n ~= nil then label = string.format("j%02d", n) end
        name = string.format("%04d_%s_%s%.1f_%.1f", jxDebugSeq, what or "op",
            label ~= nil and (label .. "_") or "", site.x, site.z)
        site = { x = site.x, z = site.z, n = n, name = label }
    else
        name = string.format("%04d_%s", jxDebugSeq, what or "op")
    end
    local dir = root .. FLYOVER_DEBUG_DIR .. name .. "/"
    if createFolder ~= nil then
        pcall(createFolder, root .. FLYOVER_DEBUG_DIR)
        pcall(createFolder, dir)
    end

    local cap = {
        dir = dir, what = what, site = site, extra = extra,
        t0 = getDate ~= nil and getDate("%H:%M:%S") or "",
    }
    jxDebugLogArm()
    if not jxDebugWriteGraph(dir .. "pre.xml") then
        -- Put Logging back before leaving. Bailing out with it still wrapped would have left every
        -- line the game logs for the rest of the session going into a buffer nothing ever reads.
        Logging.warning("[FlyoverEditor]: debug capture - could not write the network into %s. Capture is on but this change will not be recorded.", dir)
        return nil
    end
    Logging.info("[FlyoverEditor]: debug capture %04d - recording this %s into %s", jxDebugSeq, what or "change", dir)
    return cap
end

--- Finish a capture: the network as it now is, and everything the tool said while changing it.
function ADFlyoverEditor:debugCaptureEnd(cap)
    if cap == nil then return end
    jxDebugWriteGraph(cap.dir .. "post.xml")

    local meta = {
        -- Both versions, the way the card reports them: if the Lua and the modDesc disagree, the
        -- game was reloaded without a restart, and a capture that did not say so would have someone
        -- reading it against the wrong source.
        string.format("build          %s", (ADFlyoverPrelude ~= nil and ADFlyoverPrelude.BUILD) or "?"),
        string.format("modDesc        %s", (ADFlyoverPrelude ~= nil and ADFlyoverPrelude.MODDESC_VERSION) or "?"),
        string.format("tool           %s", tostring(cap.what)),
        string.format("started        %s", tostring(cap.t0)),
        string.format("finished       %s", getDate ~= nil and getDate("%H:%M:%S") or ""),
        string.format("waypoints now  %d", ADGraphManager:getWayPointsCount()),
    }
    if cap.site ~= nil then
        meta[#meta + 1] = string.format("locked at      %.2f, %.2f", cap.site.x or 0, cap.site.z or 0)
        if cap.site.name ~= nil then meta[#meta + 1] = string.format("junction       %s", cap.site.name) end
    end
    for _, line in ipairs(cap.extra or {}) do meta[#meta + 1] = line end

    -- EVERY SETTING THE CLEAR COULD HAVE READ, as it stood at the moment of the clear.
    --
    -- The harness runs on the constants' defaults; the game runs on whatever is persisted, and two
    -- of the junction values are saved between sessions on purpose. That is enough to make the same
    -- code on the same network give a different answer in each - which it did: one lane finished
    -- 18.5 m from the middle in game and 5.6 m offline, from the very same pre.xml.
    --
    -- Enumerated rather than listed by hand, so a setting added later cannot quietly go unrecorded.
    -- With these in the capture, a replay can be set up to match the game exactly instead of being
    -- assumed to.
    -- WHAT IT WAS RUNNING ON. A drop that needs a second question answered before it can be read
    -- is not a drop. Game build, AutoDrive's version, the map, the savegame, and every mod loaded -
    -- because "it does this for me and not for you" is usually one of those and nothing else.
    meta[#meta + 1] = ""
    meta[#meta + 1] = "-- what it was running on --"
    meta[#meta + 1] = string.format("%-46s %s", "game",
        (g_gameVersionDisplay ~= nil and tostring(g_gameVersionDisplay))
        or (getVersionString ~= nil and tostring(getVersionString())) or "?")
    meta[#meta + 1] = string.format("%-46s %s", "AutoDrive",
        (AutoDrive ~= nil and AutoDrive.version ~= nil) and tostring(AutoDrive.version) or "?")
    meta[#meta + 1] = string.format("%-46s %s", "map",
        (AutoDrive ~= nil and AutoDrive.loadedMap ~= nil) and tostring(AutoDrive.loadedMap) or "?")
    do
        local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
        meta[#meta + 1] = string.format("%-46s %s", "savegame",
            (info ~= nil and info.savegameIndex ~= nil) and tostring(info.savegameIndex) or "?")
        meta[#meta + 1] = string.format("%-46s %s", "multiplayer",
            (g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil)
            and tostring(g_currentMission.missionDynamicInfo.isMultiplayer) or "?")
    end
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        local ok, mods = pcall(function() return g_modManager:getActiveMods() end)
        if ok and type(mods) == "table" then
            meta[#meta + 1] = ""
            meta[#meta + 1] = "-- mods loaded --"
            local names = {}
            for _, m in pairs(mods) do
                if type(m) == "table" and m.modName ~= nil then
                    names[#names + 1] = string.format("%s %s", tostring(m.modName), tostring(m.version or ""))
                end
            end
            table.sort(names)
            for _, n in ipairs(names) do meta[#meta + 1] = "  " .. n end
        end
    end

    meta[#meta + 1] = ""
    meta[#meta + 1] = "-- settings as they stood --"
    do
        local names = {}
        for k, v in pairs(AutoDrive or {}) do
            if type(k) == "string" and k:sub(1, 8) == "FLYOVER_"
                and (type(v) == "number" or type(v) == "boolean" or type(v) == "string") then
                names[#names + 1] = k
            end
        end
        table.sort(names)
        for _, k in ipairs(names) do
            meta[#meta + 1] = string.format("%-46s %s", k, tostring(AutoDrive[k]))
        end
        for _, k in ipairs({ "junctionRadius", "junctionTurnRadius", "junctionLeaveThrough",
                             "junctionMode", "fieldLoopDirection", "connectionMode", "subPrio" }) do
            meta[#meta + 1] = string.format("%-46s %s", "editor." .. k, tostring(self[k]))
        end
    end
    -- Positions, never ids: every removal reissues the ids above it, so an id written here would
    -- name a different point by the time anyone read it back.
    meta[#meta + 1] = ""
    meta[#meta + 1] = "pre.xml and post.xml are AutoDrive route exports - loadable in game, and"
    meta[#meta + 1] = "readable by the offline harness. Points are matched by position, not by id."

    local f = io.open(cap.dir .. "meta.txt", "w")
    if f ~= nil then f:write(table.concat(meta, "\n") .. "\n") f:close() end
    local lines = jxDebugLogTake()
    local l = io.open(cap.dir .. "tool.log", "w")
    if l ~= nil then l:write(table.concat(lines, "\n") .. "\n") l:close() end
    Logging.info("[FlyoverEditor]: debug capture %04d - written, %d log line(s). %s",
        jxDebugSeq, #lines, cap.dir)
end

end -- the block of local helpers opened above (Lua 5.1's 200-local limit)

-- THE PARTS OF A SPLIT JUNCTION, AS THE USER NAMED THEM (split_decisions.txt in the harness). The
-- number never changes; each part carries an 8-point compass letter after it, or none - the middle
-- one of three keeps the bare number (39, 39se, 39nw). This is the order a junction's parts are
-- written and listed in: the bare number first, then clockwise from north. A fixed order, so two
-- saves of the same decisions are the same file.
local JX_PART_LETTERS = { "", "n", "ne", "e", "se", "s", "sw", "w", "nw" }
local JX_PART_RANK = {}
for i, l in ipairs(JX_PART_LETTERS) do JX_PART_RANK[l] = i end

local function jxSortParts(parts)
    table.sort(parts, function(a, b) return JX_PART_RANK[a.letter] < JX_PART_RANK[b.letter] end)
end

-- How far out a CLEARED site's lanes are read for its kind and its parts, from the site's middle.
-- Fixed, not the build's search radius: build cuts the lanes where the wheel's circle crosses them,
-- and read from there the answer moved with the wheel - at 18 m it suggested splitting 71, which
-- the user keeps whole; at 12 and 14 it lost 73's split; at 30 it swapped 72's two kinds. 15 is the
-- wheel's own default, the radius every cleared site on the survey map was read at when the user
-- made the split decisions (split_decisions.txt in the harness).
-- Up here, not beside junctionVirginReading where it is mostly used, because naming a locked site
-- (junctionNameAt, below) uses it too: a file-local is only seen by code written after it.
local JUNCTION_CLEARED_READ_R = 15

-- HOW NEAR A SAVED PART, in two steps. Where the user's parts sit and what lands near them was
-- measured on the survey map with the user's decisions loaded (both through-road settings, every
-- part cleared on its own and in pairs):
--   - a lock ON a part lands within 0.2 m of where it was saved while it is wired, and a cleared
--     part's middle within 4.8 m (39, cleared together with 39se; most within 3.8 m); what is left
--     of a part after a clear is found by the numbering within 3.7 m of it (14se 2.6 m, cleared 20s
--     3.2 m, cleared 20n 3.7 m);
--   - the nearest site of ANOTHER junction to any saved part is 13.7 m off: the Y beside 39se that
--     belongs to 30 (the user's j30.1, its own tie forks).
-- JX_PART_AT: a lock this near a part IS that part. Under half the distance between the two closest
-- parts the user has split (72w and 72e, 10.8 m), so one lock can never be at two.
local JX_PART_AT = 5
-- JX_PART_NEAR: a site this near a part belongs to that part's junction - it takes that number, and
-- the numbering never hands it a number of its own. Room for a part's middle to drift after a clear,
-- and well short of the Y beside 39se, which stays 30's.
local JX_PART_NEAR = 8

--- READ A JUNCTION FILE: the numbers and, for each, the user's decision on splitting it. Returns a
--- list of { n, x, z, decision, parts, partsAside } - decision "split", "whole" or nil (not
--- decided); parts only on a split, each { letter, x, z } in JX_PART_LETTERS order; partsAside the
--- same, on a junction that is not split now but was, with the names its parts had then - or nil and
--- why it could not be read. A plain function, not a method, so the offline harness reads and writes
--- exactly as the game does (split_registry.lua). The file is trusted no further than it has to be:
--- anything that is not whole is left out with one warning, and the rest is still read.
---
--- The parts are written the same way whatever the decision: `decision="split"` puts them in use,
--- `decision="whole"` or none sets them aside for a later split (junctionDecide).
function ADFlyoverEditor.junctionRegistryReadFile(path)
    local list, seen = {}, {}
    local ok, err = pcall(function()
        local xml = loadXMLFile("ADFlyoverJunctions", path)
        local i = 0
        while true do
            local key = string.format("flyoverEditor.junctions.junction(%d)", i)
            if not hasXMLProperty(xml, key) then break end
            local n = getXMLInt(xml, key .. "#n")
            local x, z = getXMLFloat(xml, key .. "#x"), getXMLFloat(xml, key .. "#z")
            -- Skip an entry that is not whole rather than trusting the file: a number with no
            -- position can never be matched, so it would sit on that number for good; and the same
            -- number twice would put one name on two junctions, which is the very thing the file
            -- exists to prevent. The first one read wins.
            if n ~= nil and n >= 1 and x ~= nil and z ~= nil and not seen[n] then
                seen[n] = true
                local f = { n = n, x = x, z = z }
                local decision = getXMLString(xml, key .. "#decision")
                -- A part is kept only if its name is this number and a compass letter (or the bare
                -- number), it has a place, and no other part has its name: a part named twice would
                -- put one name on two places, and that is what the names are for telling apart.
                local parts, have, k = {}, {}, 0
                while true do
                    local pk = string.format("%s.part(%d)", key, k)
                    if not hasXMLProperty(xml, pk) then break end
                    local name = getXMLString(xml, pk .. "#name")
                    local px, pz = getXMLFloat(xml, pk .. "#x"), getXMLFloat(xml, pk .. "#z")
                    local num, letter = nil, nil
                    if name ~= nil then num, letter = name:match("^(%d+)(%a*)$") end
                    local bad = nil
                    if num ~= tostring(n) or JX_PART_RANK[letter] == nil then
                        bad = "its name is not this junction's number with a compass letter"
                    elseif px == nil or pz == nil then
                        bad = "it has no position"
                    elseif have[letter] then
                        bad = "another part already has that name"
                    end
                    if bad ~= nil then
                        Logging.warning("[FlyoverEditor]: junction j%02d - a saved part (%s) is left out: %s. (%s)",
                            n, tostring(name), bad, path)
                    else
                        have[letter] = true
                        parts[#parts + 1] = { letter = letter, x = px, z = pz }
                    end
                    k = k + 1
                end
                jxSortParts(parts)
                if decision == "split" then
                    if #parts >= 2 then
                        f.decision, f.parts = "split", parts
                    else
                        Logging.warning("[FlyoverEditor]: junction j%02d is saved as split, but fewer than two of its parts could be read - taken as not decided. (%s)",
                            n, path)
                    end
                else
                    if decision == "whole" then
                        f.decision = "whole"
                    elseif decision ~= nil then
                        Logging.warning("[FlyoverEditor]: junction j%02d has a decision this version does not know (%s) - taken as not decided. (%s)",
                            n, tostring(decision), path)
                    end
                    -- Not split now: the names its parts had when it was, set aside for a split.
                    if #parts >= 2 then
                        f.partsAside = parts
                    elseif k > 0 then
                        Logging.warning("[FlyoverEditor]: junction j%02d - fewer than two of the part names set aside for a later split could be read - they are left out. (%s)",
                            n, path)
                    end
                end
                list[#list + 1] = f
            end
            i = i + 1
        end
        delete(xml)
    end)
    if not ok then return nil, err end
    return list
end

--- WRITE A JUNCTION FILE: every numbered junction in `reg`, in number order, each with its decision
--- and its parts - in use on a split, set aside (partsAside) otherwise. True when written; false and
--- why when not. Like the reader, a plain function the harness uses too. Nothing here decides WHERE:
--- the caller has checked the folder.
---
--- n, x and z stay first on each junction, in that order: the harness's scripts read the numbers
--- with a grep for exactly that. A part has no n of its own, so no such grep can take a part for a
--- junction, and its name is never empty (39, not ""), so nothing rests on how an empty value reads.
function ADFlyoverEditor.junctionRegistryWriteFile(path, reg)
    local byNumber = {}
    for _, f in ipairs(reg or {}) do
        if f.n ~= nil then byNumber[#byNumber + 1] = f end
    end
    -- In number order, so the file reads as the survey does and two saves of the same registry
    -- are the same file.
    table.sort(byNumber, function(a, b) return a.n < b.n end)
    local ok, err = pcall(function()
        local xml = createXMLFile("ADFlyoverJunctions", path, "flyoverEditor")
        for i, f in ipairs(byNumber) do
            local key = string.format("flyoverEditor.junctions.junction(%d)", i - 1)
            setXMLInt(xml, key .. "#n", f.n)
            setXMLFloat(xml, key .. "#x", f.x)
            setXMLFloat(xml, key .. "#z", f.z)
            local saved = nil
            if f.decision == "whole" then
                setXMLString(xml, key .. "#decision", "whole")
            elseif f.decision == "split" and f.parts ~= nil and #f.parts >= 2 then
                setXMLString(xml, key .. "#decision", "split")
                saved = f.parts
            end
            if f.decision ~= "split" and f.partsAside ~= nil and #f.partsAside >= 2 then saved = f.partsAside end
            if saved ~= nil then
                local parts = {}
                for _, p in ipairs(saved) do parts[#parts + 1] = p end
                jxSortParts(parts)
                for k, p in ipairs(parts) do
                    local pk = string.format("%s.part(%d)", key, k - 1)
                    setXMLString(xml, pk .. "#name", string.format("%d%s", f.n, p.letter))
                    setXMLFloat(xml, pk .. "#x", p.x)
                    setXMLFloat(xml, pk .. "#z", p.z)
                end
            end
        end
        saveXMLFile(xml)
        delete(xml)
    end)
    if not ok then return false, err end
    return true
end

--- The numbers as they were last written: the list junctionRegistryReadFile gives and the path it
--- came from, or nil when this savegame has no file yet or it cannot be read. Only number, position
--- and the user's split decision are kept, because position is all a junction can be recognised by
--- after a restart - its node ids are reissued by every removal, and a clear replaces the nodes
--- outright. `home` (jxHomeNow) is the game and folder they are read for.
local function junctionRegistryLoad(home)
    local folder = home ~= nil and home.folder or nil
    if folder == nil or fileExists == nil then return nil end
    local path = folder .. JUNCTION_REGISTRY_FILE
    if not fileExists(path) then return nil end
    local list, err = ADFlyoverEditor.junctionRegistryReadFile(path)
    if list == nil then
        Logging.warning("[FlyoverEditor]: junction - could not read the saved numbers (%s): %s",
            path, tostring(err))
        return nil
    end
    return list, path
end

--- Write every numbered junction, found or not: the ones the scan no longer sees are exactly the
--- ones whose numbers would otherwise be handed out again after a restart. Returns true and the
--- path when the file was written.
---
--- ONLY INTO THE FOLDER THEY WERE READ FROM (`home`, the registry's), and only while that game is
--- still the one loaded: anywhere else they would replace another career's numbers and decisions
--- with these.
local function junctionRegistrySave(reg, home)
    if not jxHomeIsHere(home) then return false end
    local folder = home.folder
    if folder == nil or createXMLFile == nil or fileExists == nil then return false end
    -- A career that has never been saved has no folder yet, and making one here would leave a
    -- savegame slot holding nothing but this file for the game to trip over. The numbers stay in
    -- memory, the registry stays marked unsaved, and junctionRegistrySaveWaiting writes them once
    -- the game's first save has made the folder.
    if not fileExists(folder .. "careerSavegame.xml") then return false end
    local path = folder .. JUNCTION_REGISTRY_FILE
    local ok, err = ADFlyoverEditor.junctionRegistryWriteFile(path, reg)
    if not ok then
        Logging.warning("[FlyoverEditor]: junction - could not save the numbers (%s): %s",
            path, tostring(err))
        return false
    end
    return true, path
end

--- EVERY JUNCTION ON THE MAP, NUMBERED, so a site can be named out loud. Without a number, talking
--- about a particular junction means quoting coordinates at each other and hoping we mean the same
--- one, and a survey done on Tuesday cannot be compared with a run done on Thursday.
---
--- The rules for a WIRED junction are the ones the survey was built with: a fork is a point with
--- three or more neighbours, forks within 15 m of each other are one junction, and it takes four of
--- them to count - which is what a junction of two two-lane roads comes to. Deliberately NOT the
--- same test the clear uses to decide whether to work on a site: this one only has to name things,
--- and a name that changes when the rule is tuned is worse than no name.
---
--- Numbers are carried over from the last build by POSITION, so adding a junction does not renumber
--- the ones already there - a new one takes the next free number and is logged, so it can be added
--- to the survey rather than silently shifting everything by one.
--- THE JUNCTION'S SITUATION - what stands on its arms. Shape says what a junction IS (T, Y, 4-way);
--- situation says what it is NEXT TO, and the right rule for clearing it depends on both: merging a
--- second crossing into this one is correct where that crossing is this junction's own kickout, and
--- wipes out a neighbour where it is the other half of a close pair. One rule for every junction
--- was tuned four times in a day to fit one of those and broke the other each time.
---
--- This only CLASSIFIES. Nothing branches on it yet; it is shown and logged so it can be checked
--- against the map before any rule is allowed to depend on it.
---
---   isolated             - nothing else on any arm within the walk
---   close pair           - another wired junction, with a road of its own, stands on an arm
---   neighbour cleared    - an arm ends at the box of a junction that has already been cleared
---   own far tie forks    - a cluster of forks up one of the arms, all of whose long roads are
---                          this junction's own roads running on: a kickout merge, not a junction
function ADFlyoverEditor:junctionSituation(site)
    if site == nil or site.roads == nil then return nil end
    local function sep(a, b)
        local d = math.abs(a - b) % (2 * math.pi)
        if d > math.pi then d = 2 * math.pi - d end
        return d
    end
    local found = {}
    for _, r in ipairs(site.roads) do
        local probes = {}
        for _, st in ipairs(r.stops or {}) do probes[#probes + 1] = st end
        for _, de in ipairs(r.deadEnds or {}) do probes[#probes + 1] = de end
        for _, p in ipairs(probes) do
            local other = self:junctionSelect(p.x, p.z)
            -- beyond the arm walk it is just the next junction down the road, not this one's situation
            if other ~= nil and (other.x - site.x) ^ 2 + (other.z - site.z) ^ 2 > 8 * 8
                and (other.x - site.x) ^ 2 + (other.z - site.z) ^ 2 <= 45 * 45 then
                local dist = math.sqrt((other.x - site.x) ^ 2 + (other.z - site.z) ^ 2)
                local kind
                if other.virgin then
                    kind = "neighbour cleared"
                else
                    -- A road of its OWN: long, and not PHYSICALLY one of this junction's roads -
                    -- asked of the nodes, not the bearings. Two T's on one road have side roads
                    -- that point the same way, and by bearing a genuine neighbour's side road read
                    -- as "one of mine" and the pair as a kickout.
                    local myNodes = {}
                    for _, fk in ipairs(site.forks or {}) do myNodes[fk] = true end
                    for _, m in ipairs(site.roads) do
                        for wn in pairs(m.walked or {}) do myNodes[wn] = true end
                    end
                    local own = 0
                    for _, o in ipairs(other.roads or {}) do
                        if o.len >= 15 then
                            local shared, total = 0, 0
                            for wn in pairs(o.walked or {}) do
                                total = total + 1
                                if myNodes[wn] then shared = shared + 1 end
                            end
                            if total > 0 and shared == 0 then own = own + 1 end
                        end
                    end
                    kind = (own >= 1) and "close pair" or "own far tie forks"
                end
                local dup = false
                for _, f in ipairs(found) do
                    if (f.x - other.x) ^ 2 + (f.z - other.z) ^ 2 <= 8 * 8 then dup = true break end
                end
                if not dup then found[#found + 1] = { kind = kind, dist = dist, x = other.x, z = other.z } end
            end
        end
    end
    if #found == 0 then return "isolated", found end
    table.sort(found, function(a, b) return a.dist < b.dist end)
    local parts = {}
    for _, f in ipairs(found) do parts[#parts + 1] = string.format("%s %.0f m", f.kind, f.dist) end
    return table.concat(parts, "; "), found
end

--- THE NUMBERS IN MEMORY, ONLY WHILE THEY ARE THIS GAME'S. Another game loaded since they were read
--- (back to the menu, another savegame), or this game's folder no longer the one they were read from:
--- they are dropped - with anything still waiting for a first save, said once - and read afresh
--- from the folder of the game loaded now. True when they are this game's (or there are none).
function ADFlyoverEditor:junctionRegistryCheckHome()
    if self._jxReg == nil or jxHomeIsHere(self._jxRegHome) then return true end
    if self._jxRegUnsaved then
        local home = self._jxRegHome
        Logging.info("[FlyoverEditor]: junction - another savegame is loaded now: the junction numbers and decisions still waiting to be written to %s are dropped, not written into this one.",
            tostring(home ~= nil and home.folder or "an earlier game"))
    end
    self._jxReg, self._jxRegCount, self._jxRegHome, self._jxRegNet = nil, nil, nil, nil
    self._jxRegUnsaved, self._jxRegWaitMs = false, 0
    return false
end

function ADFlyoverEditor:junctionRegistry()
    self:junctionRegistryCheckHome()
    local count = ADGraphManager:getWayPointsCount()
    if self._jxReg ~= nil and self._jxRegCount == count and jxSameNetwork(self._jxRegNet) then return self._jxReg end

    local wps = ADGraphManager:getWayPoints()
    -- By id, so the order is the graph's own and two builds of the same map agree.
    local ids = {}
    for _, w in pairs(wps) do
        if w ~= nil and w.id ~= nil then ids[#ids + 1] = w.id end
    end
    table.sort(ids)

    local forks, ends = {}, {}
    for _, id in ipairs(ids) do
        local w = ADGraphManager:getWayPointById(id)
        if w ~= nil then
            local nb, deg = {}, 0
            for _, t in ipairs(w.out or {}) do nb[t] = true end
            for _, f in ipairs(w.incoming or {}) do nb[f] = true end
            for _ in pairs(nb) do deg = deg + 1 end
            if deg >= 3 then forks[#forks + 1] = w
            elseif deg == 1 then ends[#ends + 1] = w end
        end
    end

    local used, found = {}, {}
    for i = 1, #forks do
        if not used[i] then
            used[i] = true
            local grp, stack = {}, { i }
            while #stack > 0 do
                local k = table.remove(stack)
                grp[#grp + 1] = forks[k]
                for j = 1, #forks do
                    if not used[j]
                        and (forks[j].x - forks[k].x) ^ 2 + (forks[j].z - forks[k].z) ^ 2 < 15 * 15 then
                        used[j] = true
                        stack[#stack + 1] = j
                    end
                end
            end
            if #grp >= 4 then
                local sx, sz = 0, 0
                for _, g in ipairs(grp) do sx, sz = sx + g.x, sz + g.z end
                local mx, mz = sx / #grp, sz / #grp
                local dup = false
                for _, f in ipairs(found) do
                    if (f.x - mx) ^ 2 + (f.z - mz) ^ 2 <= 15 * 15 then dup = true break end
                end
                if not dup then found[#found + 1] = { x = mx, z = mz, forks = #grp } end
            end
        end
    end
    -- The virgin ones, after every wired one. Lane ends are held away from the SELECTION's fork
    -- clusters (centroid linkage, any size), not from the four-fork groups above: a lone fork at a
    -- field entrance is enough to make the ends beside it that entrance's debris, and the point is
    -- to see a virgin junction exactly where a click would lock one.
    -- ...AND ONLY IF A CLICK WOULD ACTUALLY LOCK IT. A ring of lane ends says something was cleared
    -- here; it does not say a junction was. Three ends facing each other across a GAP in a road is a
    -- ring too, and the selection refuses it outright - "only 2 roads meet here". Naming a site the
    -- tool then declines to work on is worse than leaving it unnamed: the number is a promise that
    -- there is something there to clear. One such site on the survey map, at (7.5, -212.3), read as
    -- a junction by the ring rule alone.
    for _, s in ipairs(junctionVirginSites(junctionCentroidClusters(forks, JUNCTION_FORK_LINK), ends)) do
        if self:junctionSelect(s.x, s.z) ~= nil then
            found[#found + 1] = { x = s.x, z = s.z, ends = #s.nodes, virgin = true }
        end
    end

    -- What was numbered before: the last build, or - the first time in a session - the file.
    -- The file is the one in the folder of the game loaded now, and that folder is the only one these
    -- numbers are ever written back to (junctionRegistrySave).
    local prev, fromFile = self._jxReg, nil
    if prev == nil then
        self._jxRegHome = jxHomeNow()
        prev, fromFile = junctionRegistryLoad(self._jxRegHome)
        prev = prev or {}
    end

    -- Carry the numbers across, NEAREST PAIR FIRST. Taking the first old entry within reach was
    -- good enough while the old entries were last build's and in the same order; read from a file,
    -- against a scan whose order a clear has reshuffled, it is not - two junctions closer together
    -- than the reach (j55 and j56 are 28 m apart, and two T's on one road can sit closer still)
    -- are each inside the other's circle, and whichever was scanned first would take the other's
    -- number. Closest pairs settle first, so each keeps its own.
    local MATCH = 20
    local pairings = {}
    for fi, f in ipairs(found) do
        for pi, p in ipairs(prev) do
            if p.n ~= nil then
                local d2 = (p.x - f.x) ^ 2 + (p.z - f.z) ^ 2
                if d2 <= MATCH * MATCH then
                    pairings[#pairings + 1] = { f = f, p = p, d2 = d2, fi = fi, pi = pi }
                end
            end
        end
    end
    -- Ties broken by list order, so the same two lists always pair the same way.
    table.sort(pairings, function(a, b)
        if a.d2 ~= b.d2 then return a.d2 < b.d2 end
        if a.fi ~= b.fi then return a.fi < b.fi end
        return a.pi < b.pi
    end)
    local taken, added, nKept = {}, {}, 0
    for _, m in ipairs(pairings) do
        if m.f.n == nil and not taken[m.p.n] then
            m.f.n = m.p.n
            -- THE USER'S SPLIT DECISION GOES WITH THE NUMBER, parts and all, exactly as saved. The
            -- parts are never lettered again from what the scan sees now: a three-part junction
            -- that lost a part to a clear would be lettered by the two-part rule, and 39nw would
            -- come back as 39w - the very shuffle the saved names are there to stop. The same for
            -- the names set aside by "keep whole" or "not decided", which a split brings back.
            m.f.decision, m.f.parts, m.f.partsAside = m.p.decision, m.p.parts, m.p.partsAside
            taken[m.p.n] = true
        end
    end
    -- A JUNCTION THE SCAN HAS LOST KEEPS ITS NUMBER. The scan knows both forms now, but a junction
    -- can still drop out of it: cleared with its through road left in, all that remains is the side
    -- road's two lane ends, and two lane ends are a gap in a road, not a junction. Dropping it here
    -- would hand its number to the next new one. Whatever was numbered before and was not found
    -- again is carried forward as it stood - and written to the file with the rest.
    for _, p in ipairs(prev) do
        if p.n ~= nil and not taken[p.n] then
            found[#found + 1] = { x = p.x, z = p.z, forks = p.forks, ends = p.ends, n = p.n,
                                  cleared = true, decision = p.decision, parts = p.parts,
                                  partsAside = p.partsAside }
            taken[p.n] = true
            nKept = nKept + 1
        end
    end
    -- A SAVED PART NEVER BECOMES A NEW NUMBER. Anything the scan found that has no number yet and
    -- lies within JX_PART_NEAR of a part the user has named is what is left of that part, so it is
    -- not numbered at all: a part 27 m from its number's own point (39se) is outside the 20 m the
    -- numbers are carried over by, and what is left of it after a clear would otherwise come back
    -- as a new number. No further than JX_PART_NEAR: at 15 m this also swallowed the Y beside 39se
    -- that belongs to 30 (13.7 m off), so if that Y were ever found as a junction of its own it would
    -- have been dropped without a word instead of being numbered and logged. With no split saved
    -- anywhere nothing here changes. A part set aside ("keep whole", "not decided") holds the same:
    -- it is still the user's word on where that junction's parts are, and a number handed out on it
    -- would sit on the place a split brings that part back to.
    local PART_HOLD = JX_PART_NEAR
    local held = {}
    for _, g in ipairs(found) do
        if g.n ~= nil then
            for _, p in ipairs(g.parts or g.partsAside or {}) do held[#held + 1] = p end
        end
    end
    if #held > 0 then
        local keep = {}
        for _, f in ipairs(found) do
            local isPart = false
            if f.n == nil then
                for _, p in ipairs(held) do
                    if (p.x - f.x) ^ 2 + (p.z - f.z) ^ 2 <= PART_HOLD * PART_HOLD then isPart = true break end
                end
            end
            if not isPart then keep[#keep + 1] = f end
        end
        found = keep
    end
    local next_, gained = 1, false
    for _, f in ipairs(found) do
        if f.n == nil then
            while taken[next_] do next_ = next_ + 1 end
            f.n, taken[next_] = next_, true
            gained = true
            if #prev > 0 then added[#added + 1] = f end
        end
    end

    for _, f in ipairs(added) do
        if f.virgin then
            Logging.info("[FlyoverEditor]: junction j%02d is new, at %.1f, %.1f (%d lane ends, nothing joining them). Worth adding to the survey.",
                f.n, f.x, f.z, f.ends)
        else
            Logging.info("[FlyoverEditor]: junction j%02d is new, at %.1f, %.1f (%d fork points). Worth adding to the survey.",
                f.n, f.x, f.z, f.forks)
        end
    end
    if #prev == 0 then
        Logging.info("[FlyoverEditor]: junction - %d junction(s) on this map, numbered j01 to j%02d.",
            #found, #found)
    elseif fromFile ~= nil then
        -- Said once a session, and with the path: when a number on the card looks wrong, the first
        -- question is whether the file was read at all, and from which savegame.
        Logging.info("[FlyoverEditor]: junction - %d number(s) read from %s: %d found on the map, %d not found and kept, %d new.",
            #prev, fromFile, #found - nKept - #added, nKept, #added)
    end

    -- Saved when the registry GAINS a number, and only then: a number is the one thing that cannot
    -- be worked out again after a restart. Positions drift a little as a junction is cleared and
    -- rebuilt, but every form of it sits round the same crossing, well inside the match radius of
    -- where it was first written, so they are not worth a write. A save that fails (a career not
    -- yet saved has no folder) leaves the registry marked, and junctionRegistrySaveWaiting writes it
    -- once the folder is there.
    if gained then self._jxRegUnsaved = true end
    if self._jxRegUnsaved and junctionRegistrySave(found, self._jxRegHome) then
        self._jxRegUnsaved = false
    end

    self._jxReg, self._jxRegCount, self._jxRegNet = found, count, jxNetworkMark()
    return found
end

--- The registry entry of the junction at (x, z): the one with a saved part within JX_PART_NEAR of it,
--- if any; otherwise the one whose own point is nearest, within 30 m; nil when there is none.
---
--- A SAVED PART CLAIMS ONLY WHAT IS NEAR IT. 39se is 27 m from 39's own point, so a lock on 39se
--- that drifted a few metres further out would fall outside the 30 m and lose its number - the
--- part's claim keeps it. But counted out to 30 m like a junction's own point, a part took sites
--- that are not it: 39se is nearer than 30's own point to the Y that belongs to 30 (13.7 m against
--- 21.3 m), so that Y was called j39 and the card offered 39's decision buttons on it, where one
--- click would have undone 39's split. With no split saved this is the plain nearest point, as it
--- always was. A part set aside by "keep whole" or "not decided" claims the same - a lock there is
--- still that junction's, named by its bare number, and its card is the one that can split it back.
function ADFlyoverEditor:junctionEntryAt(x, z)
    if x == nil or z == nil then return nil end
    local reg = self:junctionRegistry() or {}
    -- In the registry's own order, and only a strictly nearer one replaces the best: a tie always
    -- goes the same way.
    local best, bestD = nil, JX_PART_NEAR * JX_PART_NEAR
    for _, f in ipairs(reg) do
        for _, p in ipairs(f.parts or f.partsAside or {}) do
            local d = (p.x - x) ^ 2 + (p.z - z) ^ 2
            if d < bestD then bestD, best = d, f end
        end
    end
    if best ~= nil then return best end
    bestD = 30 * 30
    for _, f in ipairs(reg) do
        local d = (f.x - x) ^ 2 + (f.z - z) ^ 2
        if d < bestD then bestD, best = d, f end
    end
    return best
end

--- The number of the junction nearest (x, z), or nil when there is none close enough to name.
function ADFlyoverEditor:junctionNumberAt(x, z)
    local f = self:junctionEntryAt(x, z)
    if f == nil then return nil end
    return f.n
end

--- The registry entry with number n, or nil.
function ADFlyoverEditor:junctionEntryOf(n)
    if n == nil then return nil end
    for _, f in ipairs(self:junctionRegistry() or {}) do
        if f.n == n then return f end
    end
    return nil
end

--- The parts of junction n as names ("j39nw", "j39", "j39se"), in map order: west to east where they
--- lie more east-west, north to south where they lie more north-south - the order the card lists
--- them in, whatever order they are saved in.
local function jxPartNames(n, parts)
    local list = {}
    for _, p in ipairs(parts or {}) do list[#list + 1] = p end
    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(list) do
        x0, x1 = math.min(x0, p.x), math.max(x1, p.x)
        z0, z1 = math.min(z0, p.z), math.max(z1, p.z)
    end
    local byX = (x1 - x0) >= (z1 - z0)
    table.sort(list, function(a, b)
        if byX then
            if a.x ~= b.x then return a.x < b.x end
            return a.z < b.z
        end
        if a.z ~= b.z then return a.z < b.z end
        return a.x < b.x
    end)
    local names = {}
    for _, p in ipairs(list) do names[#names + 1] = string.format("j%02d%s", n, p.letter or "") end
    return names
end

--- "a and b", "a, b and c".
local function jxAndList(names)
    if #names <= 1 then return names[1] or "" end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

--- WHAT TO CALL A LOCKED SITE. (x, z) is where the selection locked it; virgin says it is a cleared
--- site. Returns the name ("j39se", or "j39" - also for every junction that is not split), the
--- number, the saved part it is (or nil), the saved parts the lock covers, and a note for the card
--- when the lock is not on exactly one part. Nil when no junction is close enough to name.
---
--- Only a SAVED split names a part. A suggestion is only a suggestion: until the user splits a
--- junction its parts have no names to give.
---
--- THE PART A LOCK IS AT is the nearest one, if it is within JX_PART_AT. A WIRED lock is only ever
--- that part, or none.
---
--- A CLEARED lock can also stand for other parts: where both halves were cleared together they
--- share one middle (72, 73 - 2.6 m from one half and 8.7 m from the other), and a click on either
--- half locks that one middle. So a cleared lock also covers each other part that is within the
--- radius a cleared site's lanes are read out to (JUNCTION_CLEARED_READ_R) AND where a click on the
--- part itself locks this same cleared site. Distance alone was not enough: 26n's saved point sits
--- 15.06 m from cleared 26s's middle, so 6 cm decided between "j26s" and "covers j26n and j26s" -
--- and decided it the same way whether 26n was still wired or had gone with 26s's clear. A part
--- that is still wired, or has a cleared site of its own, locks something else when clicked, so it
--- is never covered by a neighbour's clear however close it is; one that went with the clear is
--- covered whenever it is inside the radius.
function ADFlyoverEditor:junctionNameAt(x, z, virgin)
    local f = self:junctionEntryAt(x, z)
    if f == nil then return nil end
    local base = string.format("j%02d", f.n)
    if f.decision ~= "split" or f.parts == nil then return base, f.n, nil, {}, nil end
    -- f.parts is in its fixed saved order, and only a strictly nearer part replaces the best, so a
    -- tie always goes the same way.
    local at, atD = nil, math.huge
    for _, p in ipairs(f.parts) do
        local d = (p.x - x) ^ 2 + (p.z - z) ^ 2
        if d < atD then atD, at = d, p end
    end
    if atD > JX_PART_AT * JX_PART_AT then at = nil end
    local covers = {}
    for _, p in ipairs(f.parts) do
        local inside = (p == at)
        if not inside and virgin
            and (p.x - x) ^ 2 + (p.z - z) ^ 2 <= JUNCTION_CLEARED_READ_R * JUNCTION_CLEARED_READ_R then
            -- the selection a click on the part would make, asked of the network as it is now
            local s = self:junctionSelect(p.x, p.z)
            inside = (s ~= nil and s.virgin == true and (s.x - x) ^ 2 + (s.z - z) ^ 2 <= 1)
        end
        if inside then covers[#covers + 1] = p end
    end
    if #covers == 1 then return base .. covers[1].letter, f.n, covers[1], covers, nil end
    if #covers == 0 then
        return base, f.n, nil, covers, string.format("not at one of %s's parts", base)
    end
    -- Two or more: a cleared site whose halves share one middle (72, 73). Which half is meant can
    -- only be said by a click on it, and that is not built yet - so it is named by its number and
    -- the card says what it covers.
    return base, f.n, nil, covers, "covers " .. jxAndList(jxPartNames(f.n, covers))
end

--- Name the site jp was locked on (jp.lockedAt, jp.lockedVirgin, set by the preview) and say what the
--- user has decided about it: sets jp.junctionName, junctionPart, junctionCovers, junctionNameNote,
--- junctionDecision, on a split junctionSplitNames, and otherwise junctionNamesAside when it has
--- names set aside. Cheap - a look in the registry, and on a cleared lock of a split junction at most
--- one selection a part - so it is run again straight after a decision without solving the preview
--- again.
function ADFlyoverEditor:junctionNameSite(jp)
    if jp == nil then return end
    jp.junctionName, jp.junctionPart, jp.junctionCovers, jp.junctionNameNote = nil, nil, nil, nil
    jp.junctionDecision, jp.junctionSplitNames, jp.junctionNamesAside = nil, nil, nil
    local at = jp.lockedAt
    if at == nil then return end
    local name, n, part, covers, note = self:junctionNameAt(at.x, at.z, jp.lockedVirgin == true)
    jp.junctionName, jp.junctionPart, jp.junctionCovers, jp.junctionNameNote = name, part, covers, note
    local f = self:junctionEntryOf(n)
    if f ~= nil then
        jp.junctionDecision = f.decision
        if f.decision == "split" then jp.junctionSplitNames = jxPartNames(f.n, f.parts) end
        -- the names a split would bring back (set aside by "keep whole" or "not decided")
        if f.decision ~= "split" and f.partsAside ~= nil then
            jp.junctionNamesAside = jxPartNames(f.n, f.partsAside)
        end
    end
end

--- A decision taken: saved at once, beside the numbers, and said in the log. Where the career has
--- never been saved there is no folder to save into, so it is kept in memory and written as soon as
--- the first save makes the folder (junctionRegistrySaveWaiting). The card is named again.
local function jxDecisionTaken(self, n, said)
    local ok, path = junctionRegistrySave(self:junctionRegistry() or {}, self._jxRegHome)
    if ok then
        Logging.info("[FlyoverEditor]: junction j%02d - %s, saved to %s", n, said, tostring(path))
    else
        self._jxRegUnsaved = true
        Logging.info("[FlyoverEditor]: junction j%02d - %s, kept until the game is saved once", n, said)
    end
    if self.junctionPreview ~= nil then
        tryCall("junction name", function() self:junctionNameSite(self.junctionPreview) end)
    end
    -- AND THE PREVIEW IS WORKED OUT AGAIN. A split changes what the clear does, not only what the
    -- card calls the site: a lane from one part's side road to another part's is a connector, not a
    -- through road ("A LANE FROM THIS PART'S SIDE ROAD TO ANOTHER PART'S", in updateJunctionPreview).
    -- The preview is only redone when its key changes, and the key knows nothing of decisions; the
    -- buttons only show once a click has locked the site, so the usual order is lock, split, clear -
    -- and that clear used the through roads read before the split. At j39 it came out right only
    -- because the clear's own cleaning happened to change the site and force a new reading.
    self.junctionPreviewKey = nil
end

--- THE USER'S DECISION ON SPLITTING JUNCTION n: "split", "whole", or nil for not decided (which is
--- how a decision is undone). Returns true when the decision was taken.
---
--- THE PARTS' NAMES ARE NEVER LOST BY A CHANGE OF MIND. "Keep whole" and "not decided" set a split's
--- parts aside (f.partsAside, saved in the file with them) instead of throwing them away, and a split
--- brings them back exactly as they were - the same names on the same places. Thrown away, one click
--- erased the saved parts on disk for good, and splitting again lettered the places the roads meet
--- NOW: with 39se cleared that is two places, lettered by the two-part rule, so the user's "j39se"
--- landed on what had been j39. Only junctionForgetParts lets them go.
---
--- With no parts set aside, a split takes the parts the card offered for the locked site
--- (jp.junctionOffer) with the names it showed. A junction already split stays as it is: its parts
--- are only ever moved on purpose (not decided, forget the names, then split).
function ADFlyoverEditor:junctionDecide(n, decision)
    local f = self:junctionEntryOf(n)
    if f == nil then return false end
    local said
    if decision == "split" then
        if f.decision == "split" then
            Logging.info("[FlyoverEditor]: junction j%02d - already split into %s; nothing changed.",
                n, table.concat(jxPartNames(n, f.parts), ", "))
            return false
        end
        local parts
        if f.partsAside ~= nil and #f.partsAside >= 2 then
            parts = f.partsAside
            said = "split again into " .. table.concat(jxPartNames(n, parts), ", ") .. ", the names it had before"
        else
            local jp = self.junctionPreview
            local offer = nil
            if jp ~= nil and jp.junctionNumber == n then offer = jp.junctionOffer end
            if offer == nil or offer.parts == nil or #offer.parts < 2 then
                Logging.info("[FlyoverEditor]: junction j%02d - not split: the card has no named parts to split it into.", n)
                return false
            end
            parts = {}
            for _, p in ipairs(offer.parts) do parts[#parts + 1] = { letter = p.letter, x = p.x, z = p.z } end
            jxSortParts(parts)
            said = "split into " .. table.concat(jxPartNames(n, parts), ", ")
        end
        f.decision, f.parts, f.partsAside = "split", parts, nil
    else
        if f.decision == "split" and f.parts ~= nil and #f.parts >= 2 then f.partsAside = f.parts end
        if decision == "whole" then
            f.decision, said = "whole", "kept whole"
        else
            f.decision, said = nil, "not decided (any earlier decision undone)"
        end
        f.parts = nil
        if f.partsAside ~= nil then
            said = said .. "; the names " .. table.concat(jxPartNames(n, f.partsAside), ", ")
                .. " are kept, for if it is split again"
        end
    end
    jxDecisionTaken(self, n, said)
    return true
end

--- FORGET THE NAMES junction n's parts had (the parts set aside by "keep whole" or "not decided"):
--- the one deliberate way to let them go, so the next split names the parts afresh from the card.
--- Not while it is split - those parts are in use. Returns true when they were forgotten.
function ADFlyoverEditor:junctionForgetParts(n)
    local f = self:junctionEntryOf(n)
    if f == nil or f.decision == "split" or f.partsAside == nil then return false end
    local names = jxPartNames(n, f.partsAside)
    f.partsAside = nil
    jxDecisionTaken(self, n, "the names " .. table.concat(names, ", ") .. " forgotten; a split names its parts afresh")
    return true
end

--- NUMBERS AND DECISIONS STILL WAITING FOR A FOLDER: a career that has never been saved has none,
--- so the registry stays marked unsaved. It used to be tried again only when the registry was built
--- again, which happens only when the network changes - so a decision made, the game saved and the
--- game quit without another edit was lost, although the card had said it would be kept until the
--- game was saved. Called from update() every frame, editor open or not; looks every 2 s, and only
--- while something is waiting.
---
--- ONLY FOR THE GAME IT WAS MADE IN. update() goes on reaching this table after the player has left
--- to the menu and loaded another savegame, until the editor files are sourced again; written then,
--- into whatever folder the game loaded NOW has, one career's numbers and decisions replaced
--- another's. So what is waiting is written only into the folder the numbers were read from, while
--- that game is still loaded, and is dropped the moment another game is (junctionRegistryCheckHome).
function ADFlyoverEditor:junctionRegistrySaveWaiting(dt)
    if not self._jxRegUnsaved or self._jxReg == nil then return end
    if not self:junctionRegistryCheckHome() then return end
    self._jxRegWaitMs = (self._jxRegWaitMs or 0) + (dt or 0)
    if self._jxRegWaitMs < 2000 then return end
    self._jxRegWaitMs = 0
    local ok, path = junctionRegistrySave(self._jxReg, self._jxRegHome)
    if ok then
        self._jxRegUnsaved = false
        Logging.info("[FlyoverEditor]: junction - numbers and split decisions saved to %s, now that the game has been saved once.",
            tostring(path))
    end
end

--- Recompute the junction preview around the cursor: the scope circle, the approaches it cuts, and
--- which entry->exit movements are new versus already connected. Stored on self.junctionPreview; nil
--- when there is nothing to show. Pure inspection - it changes no waypoints.
--- PLACE MODE (docs/junction-tool/08-place-junction.md): point at roads that cross and the card says what
--- would go there. The pattern is worked out dry - nothing changes until the right-click.
function ADFlyoverEditor:updatePlacePreview()
    local cx, cz
    if self.junctionArmed ~= nil then
        cx, cz = self.junctionArmed.cx, self.junctionArmed.cz
    elseif self.cursorX ~= nil then
        cx, cz = self.cursorX, self.cursorZ
    else
        self.junctionPreview, self.junctionPreviewKey = nil, nil
        return
    end
    local shape = self.junctionPattern or "exact"
    -- ONLY ON A JUNCTION (in-game test 2026-10-05): place works on junctions the clear knows, picked the
    -- clear's way. Anywhere else it does nothing and says so - no piece sliding about under the cursor,
    -- and nothing worked out at every step of the mouse. The pick itself is remembered per 2 m of cursor
    -- travel, so pointing around inside one junction costs nothing.
    local selKey = string.format("%d_%d_%d", math.floor(cx / 2), math.floor(cz / 2), ADGraphManager:getWayPointsCount())
    local site = nil
    if self.placeSelectKey == selKey then
        site = self.placeSelectSite
    else
        tryCall("junction place: which junction", function() site = self:junctionSelect(cx, cz) end)
        -- A cleared junction the clear's finder no longer sees (an X cleared with its through roads kept has
        -- no lane ends at all): the numbered list keeps every junction's place, and that anchors it.
        if site == nil then
            tryCall("junction place: numbered list", function()
                local bd = 15 * 15
                for _, e in ipairs(self:junctionRegistry() or {}) do
                    local d = (e.x - cx) ^ 2 + (e.z - cz) ^ 2
                    if d < bd then site, bd = { x = e.x, z = e.z, virgin = true, n = e.n }, d end
                end
            end)
        end
        self.placeSelectKey, self.placeSelectSite = selKey, site
    end
    if site == nil or site.x == nil then
        self.junctionPreview = { placeMode = true, cx = cx, cz = cz, cy = self.cursorY or 0, shape = shape, ok = false,
            why = "point at a junction - place works on junctions the clear knows" }
        self.junctionPreviewKey = nil
        return
    end
    -- THE CLICK PICKS THE JUNCTION, as in the clear: pointing anywhere on it, the piece is worked out from
    -- the junction's own centre, so where you click and how the camera looks at it can't change what is
    -- placed (in game j3 gave different answers from different clicks).
    cx, cz = site.x, site.z
    -- TURN WIRING STILL HERE: place never deletes anything, so it refuses exactly where the clear would
    -- find something to take out - the clear's own finder decides, so the two always agree. (A fork alone
    -- is no sign of it: a two-way road splitting into its two lanes is a fork too.)
    if not site.virgin then
        self.junctionPreview = { placeMode = true, cx = cx, cz = cz, shape = shape, ok = false, wired = true,
            cy = AutoDrive:getTerrainHeightAtWorldPos(cx, cz) or 0,
            why = "turn wiring is still here - clear the junction first" }
        self.junctionPreviewKey = nil
        return
    end
    local key = string.format("place_%.1f_%.1f_%s_%s_%d", cx, cz, shape,
        tostring(self.junctionArmed ~= nil), ADGraphManager:getWayPointsCount())
    if key == self.junctionPreviewKey and self.junctionPreview ~= nil then return end
    self.junctionPreviewKey = key    local okCall, res, why, wired = tryCall("junction place preview", function()
        return junctionPlacePattern(cx, cz, 15, shape, true)
    end)
    -- Ground heights for the drawing, once per preview rather than every frame.
    local function ground(p) p.y = AutoDrive:getTerrainHeightAtWorldPos(p.x, p.z) or 0 end
    if okCall and res ~= nil then
        for _, line in ipairs(res.lines or {}) do for _, p in ipairs(line.pts) do ground(p) end end
        for _, p in ipairs(res.marks or {}) do ground(p) end
        for _, p in ipairs(res.loose or {}) do ground(p) end
    end
    self.junctionPreview = {
        placeMode = true, cx = cx, cz = cz, cy = AutoDrive:getTerrainHeightAtWorldPos(cx, cz) or 0, shape = shape,
        ok = okCall and res ~= nil, plan = res,
        why = (not okCall) and "it failed - see the log" or why, wired = wired == true,
    }
end

-- MODSPLIT: SHARED WITH THE FILES LOADED AFTER THIS ONE (tools/modsplit/split.py writes this block)
ADFlyoverEditor.shared = ADFlyoverEditor.shared or {}
ADFlyoverEditor.shared.JUNCTION_CLEARED_READ_R = JUNCTION_CLEARED_READ_R
ADFlyoverEditor.shared.JX_PART_AT = JX_PART_AT
ADFlyoverEditor.shared.JX_PART_NEAR = JX_PART_NEAR
ADFlyoverEditor.shared.JX_TWIN_LEAD = JX_TWIN_LEAD
ADFlyoverEditor.shared.JX_WHOLE_PIECE_REACH = JX_WHOLE_PIECE_REACH
ADFlyoverEditor.shared.LINK_LISTS = LINK_LISTS
ADFlyoverEditor.shared.addLink = addLink
ADFlyoverEditor.shared.heightAlongChain = heightAlongChain
ADFlyoverEditor.shared.isRoadAt = isRoadAt
ADFlyoverEditor.shared.junctionAngDiff = junctionAngDiff
ADFlyoverEditor.shared.junctionBiarc = junctionBiarc
ADFlyoverEditor.shared.junctionBranchTurn = junctionBranchTurn
ADFlyoverEditor.shared.junctionChainIndexNear = junctionChainIndexNear
ADFlyoverEditor.shared.junctionConnect = junctionConnect
ADFlyoverEditor.shared.junctionDisconnect = junctionDisconnect
ADFlyoverEditor.shared.junctionDubins = junctionDubins
ADFlyoverEditor.shared.junctionLayChain = junctionLayChain
ADFlyoverEditor.shared.junctionPlacePattern = junctionPlacePattern
ADFlyoverEditor.shared.junctionRouteCheck = junctionRouteCheck
ADFlyoverEditor.shared.junctionSegDir = junctionSegDir
ADFlyoverEditor.shared.junctionShareCrossings = junctionShareCrossings
ADFlyoverEditor.shared.junctionWalkBack = junctionWalkBack
ADFlyoverEditor.shared.jxBeforeInPlace = jxBeforeInPlace
ADFlyoverEditor.shared.jxBegin = jxBegin
ADFlyoverEditor.shared.jxBuildBegin = jxBuildBegin
ADFlyoverEditor.shared.jxBuildEnd = jxBuildEnd
ADFlyoverEditor.shared.jxByPlace = jxByPlace
ADFlyoverEditor.shared.jxEnd = jxEnd
ADFlyoverEditor.shared.jxInSite = jxInSite
ADFlyoverEditor.shared.jxKeptRoadsOf = jxKeptRoadsOf
ADFlyoverEditor.shared.jxLanesCross = jxLanesCross
ADFlyoverEditor.shared.jxMayDelete = jxMayDelete
ADFlyoverEditor.shared.jxNote = jxNote
ADFlyoverEditor.shared.jxNoteAdded = jxNoteAdded
ADFlyoverEditor.shared.jxNoteMoved = jxNoteMoved
ADFlyoverEditor.shared.jxPartNames = jxPartNames
ADFlyoverEditor.shared.jxRemove = jxRemove
ADFlyoverEditor.shared.jxRightOfWay = jxRightOfWay
ADFlyoverEditor.shared.jxRightOfWayLists = jxRightOfWayLists
ADFlyoverEditor.shared.jxRouteLines = jxRouteLines
ADFlyoverEditor.shared.jxSiteHas = jxSiteHas
ADFlyoverEditor.shared.jxSnapshot = jxSnapshot
ADFlyoverEditor.shared.jxSortParts = jxSortParts
ADFlyoverEditor.shared.jxState = jxState
ADFlyoverEditor.shared.jxTurnLabel = jxTurnLabel
ADFlyoverEditor.shared.jxWasCutByUs = jxWasCutByUs
ADFlyoverEditor.shared.jxpUnit = jxpUnit
ADFlyoverEditor.shared.linkList = linkList
ADFlyoverEditor.shared.removeLink = removeLink
ADFlyoverEditor.shared.roadNote = roadNote
ADFlyoverEditor.shared.roadProbeNoted = roadProbeNoted
ADFlyoverEditor.shared.tryCall = tryCall
-- MODSPLIT: end of the shared block
