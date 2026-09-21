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
    Logging.info("[FlyoverEditor]: ground level -> %s.", self.GROUND_LEVEL_NAMES[self.groundLevel])
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
        Logging.info("[FlyoverEditor]: PROBE no g_currentMission.hud")
        return
    end

    local help = hud.inputHelp
    Logging.info("[FlyoverEditor]: PROBE hud.inputHelp = %s isVisible=%s",
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
        Logging.info("[FlyoverEditor]: PROBE inputHelp methods: %s",
            #names > 0 and table.concat(names, ", ") or "(none directly on the table)")
    end
end

function ADFlyoverEditor:hideInputHelp()
    self:probeInputHelp()

    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    local help = hud ~= nil and hud.inputHelp or nil
    if help == nil then
        self.inputHelpWasVisible = nil
        Logging.info("[FlyoverEditor]: no input-help display found to hide.")
        return
    end
    -- Read the flag rather than assume it was on: someone who had already turned the help off must
    -- not have it handed back to them on exit.
    self.inputHelpWasVisible = rawget(help, "isVisible")
    local ok, err = self:setInputHelpVisible(false)
    -- Logged either way. Reporting only success is what left the first attempt unexplained.
    Logging.info("[FlyoverEditor]: hide key-binding help: ok=%s was=%s%s",
        tostring(ok), tostring(self.inputHelpWasVisible), err ~= nil and (" err=" .. err) or "")
end

function ADFlyoverEditor:restoreInputHelp()
    if self.inputHelpWasVisible == nil then
        return
    end
    self:setInputHelpVisible(self.inputHelpWasVisible ~= false)
    self.inputHelpWasVisible = nil
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

--- Give the mouse wheel back to the cameras: collapse any expanded AutoDrive pull-down list (the one
--- state that keeps re-asserting mouseWheelActive) and clear the flag. Used on enable and disable.
function ADFlyoverEditor:releaseAutoDriveWheel()
    local hud = AutoDrive.Hud
    local vehicle = AutoDrive.getControlledVehicle and AutoDrive.getControlledVehicle() or nil
    if hud ~= nil and hud.closeAllPullDownLists ~= nil and (AutoDrive.pullDownListExpanded or 0) ~= 0 then
        local ok, err = pcall(hud.closeAllPullDownLists, hud, vehicle)
        if ok then
            Logging.info("[FlyoverEditor]: collapsed an expanded AutoDrive pull-down list (it was holding the mouse wheel).")
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
        Logging.info("[FlyoverEditor]: already active.")
        return
    end

    if not self:isAvailable() then
        Logging.error("[FlyoverEditor]: GuiTopDownCamera=%s GuiTopDownCursor=%s - the base game did not expose these, so the flyover editor cannot use this approach.",
            tostring(GuiTopDownCamera), tostring(GuiTopDownCursor))
        return
    end
    Logging.info("[FlyoverEditor]: GuiTopDownCamera and GuiTopDownCursor are both present.")
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

    self:hideInputHelp()

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
        Logging.info("[FlyoverEditor]: network changed while closed (%s -> %d waypoints); cleared the undo history.",
            tostring(self.historyGuardCount), wpCount)
    elseif ADEditorHistory:canUndo() or ADEditorHistory:canRedo() then
        Logging.info("[FlyoverEditor]: kept the undo history from before (%d undo, %d redo).",
            ADEditorHistory:depth(), ADEditorHistory:redoDepth())
    end
    Logging.info("[FlyoverEditor]: ACTIVE - %s", self:describeBuild())
end

function ADFlyoverEditor:disable()
    if not self.active then
        Logging.info("[FlyoverEditor]: not active.")
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

    self:restoreInputHelp()

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

    -- A modal (settings dialog or browsable manual) is up: Esc closes it, the arrow keys page the
    -- manual, and every other key is swallowed (no tool numbers, no undo). handleEditKey ran first
    -- above, so typing into a dialog field, and Esc to cancel that edit, both still work before this.
    if self:isModalOpen() then
        if isKey("KEY_esc") then
            if self.manualOpen then self:closeManual() else self:closeSettingsDialog() end
        elseif self.manualOpen and isKey("KEY_left") then
            self:manualStep(-1)
        elseif self.manualOpen and isKey("KEY_right") then
            self:manualStep(1)
        end
        return
    end

    if isKey("KEY_esc") then
        Logging.info("[FlyoverEditor]: escape observed via keyEvent (fallback path).")
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
    Logging.info("[FlyoverEditor]: span menu for id=%s..id=%s (%d waypoints).",
        tostring(fromId), tostring(toId), #ids)
end

function ADFlyoverEditor:openRunMenu(seedId, sx, sy)
    local run, count = self:collectRunBetweenJunctions(seedId)
    -- fromId/toId/ids are the run's two ends and the ordered route between them, for the span-shaped
    -- actions (straighten, smooth). nil when the run has no clear two ends (a junction seed or a
    -- closed loop); those actions then simply have nothing to act on.
    local fromId, toId, ids = self:resolveWholeRun(seedId)
    self.ctxMenu = { kind = "run", seedId = seedId, count = count or 0, runSet = run,
        fromId = fromId, toId = toId, ids = ids, sx = sx, sy = sy }
    Logging.info("[FlyoverEditor]: run menu through id=%s (%d waypoints).", tostring(seedId), count or 0)
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
    Logging.info("[FlyoverEditor]: (menu) deleted waypoint id=%s at x=%.1f z=%.1f (%d left).",
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
    Logging.info("[FlyoverEditor]: deleted a span of %d waypoint(s).", #ids)
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
    Logging.info("[FlyoverEditor]: span direction -> %s, %d link(s) changed.",
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
    Logging.info("[FlyoverEditor]: move armed; drag waypoint id=%s.", tostring(id))
end

function ADFlyoverEditor:menuArmDraw()
    local id = self:menuTarget()
    if id == nil then return end
    self:setTool(self.TOOL.DRAW)
    self.lastWaypointId = id
    Logging.info("[FlyoverEditor]: draw armed from id=%s; click the next waypoint to connect.", tostring(id))
end

function ADFlyoverEditor:menuArmSpline()
    local id = self:menuTarget()
    if id == nil then return end
    self:setTool(self.TOOL.SPLINE)
    self.splineFromId = id
    Logging.info("[FlyoverEditor]: spline armed from id=%s; click the waypoint to curve to.", tostring(id))
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
    self.straightenFromId, self.straightenToId, self.straightenPreview = from, to, nil
    self:setArmedMenu(sx, sy)
    Logging.info("[FlyoverEditor]: straighten armed on a %d-point span.", #ids)
end

function ADFlyoverEditor:menuArmSmooth()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, sx, sy = m.fromId, m.toId, m.ids, m.sx, m.sy
    self:setTool(self.TOOL.SMOOTH)
    self.spanIds = ids
    self.smoothFromId, self.smoothToId = from, to
    self.smoothPreview, self.smoothPinned, self.smoothBlockedBy = nil, nil, nil
    self:setArmedMenu(sx, sy)
    Logging.info("[FlyoverEditor]: smooth armed on a %d-point span.", #ids)
end

function ADFlyoverEditor:menuArmDivide()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, sx, sy = m.fromId, m.toId, m.ids, m.sx, m.sy
    self:setTool(self.TOOL.DIVIDE)
    self.spanIds = ids
    self.divideFromId, self.divideToId = from, to
    self.dividePreview = nil
    self.divideCount = math.max(0, #ids - 2)
    self:setArmedMenu(sx, sy)
    Logging.info("[FlyoverEditor]: divide armed on a %d-point span.", #ids)
end

function ADFlyoverEditor:menuArmGround()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, isRun, sx, sy = m.fromId, m.toId, m.ids, (m.kind == "run"), m.sx, m.sy
    self:setTool(self.TOOL.GROUND)
    self.offsetScope = isRun and self.OFFSET_SCOPE.RUN or self.OFFSET_SCOPE.SPAN
    self.spanIds = ids
    self.groundFromId, self.groundToId = from, to
    self.groundPreview = nil
    self.groundTolerance = AutoDrive.FLYOVER_GROUND_DEFAULT
    self:setArmedMenu(sx, sy)
    Logging.info("[FlyoverEditor]: ground armed on a %d-point span.", #ids)
end

function ADFlyoverEditor:menuArmParallel()
    local m = self.ctxMenu
    if m == nil or m.fromId == nil or m.toId == nil or m.ids == nil then return end
    local from, to, ids, isRun, sx, sy = m.fromId, m.toId, m.ids, (m.kind == "run"), m.sx, m.sy
    self:setTool(self.TOOL.PARALLEL)
    self.offsetScope = isRun and self.OFFSET_SCOPE.RUN or self.OFFSET_SCOPE.SPAN
    self.spanIds = ids
    self.offsetFromId, self.offsetToId = from, to
    self.offsetPreview, self.offsetCache = nil, nil
    local seedPts = self:offsetSpanPoints()
    if seedPts ~= nil then
        self.offsetSide = self:offsetSideFromCursor(seedPts)
    end
    self:setArmedMenu(sx, sy)
    Logging.info("[FlyoverEditor]: parallel armed on a %d-point span.", #ids)
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
    self.junctionArmed, self.junctionPreview, self.junctionPreviewKey = nil, nil, nil
    self.dragId = nil
    self.boxActive = false
    self.ctxMenu = nil
    -- A dragged card stays dragged ACROSS tool switches now, not per tool: field reports kept saying
    -- the card was in the way, and re-jumping it on every tool change undid the player's own
    -- placement. Once you put it somewhere, it stays there for the whole editor session; the
    -- jump-out-beside-the-click only serves players who never placed it themselves.
    self.moveFocusId = nil
    -- Picking a tool always brings its card back: middle-click hides the CURRENT tool's card to work
    -- under it, but switching tools should not carry that hidden state onto the next one.
    self.cardHidden = false
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
            ADDrawingManager:addSphereTask(wp.x, wp.y + 0.5, wp.z, 2, 1, 0.8, 0, 0.5)
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

    -- Move falloff preview: the waypoints the falloff would carry, measured ALONG THE TRACK (not a
    -- circle - the reach follows the run through junctions, so a ring would lie about it). The centre
    -- is the point being dragged, or the last one pointed at, so wheeling the radius over the tool
    -- card shows its reach live. Sized and brightened by how far each point would actually move.
    if self.tool == self.TOOL.MOVE then
        local centreId = self.dragId or self.moveFocusId
        local radius = self.falloffRadius or 0
        if centreId ~= nil and radius > 0 then
            local c = ADGraphManager:getWayPointById(centreId)
            if c ~= nil then
                ADDrawingManager:addSphereTask(c.x, c.y + 0.7, c.z, 4.5, 1, 0.8, 0.15, 0.95)
                local reached = self:collectAlongTrack(centreId, radius)
                for otherId, d in pairs(reached) do
                    if otherId ~= centreId then
                        local wp = ADGraphManager:getWayPointById(otherId)
                        if wp ~= nil then
                            local w = 0.5 * (1 + math.cos(math.pi * math.min(d, radius) / radius))
                            ADDrawingManager:addSphereTask(wp.x, wp.y + 0.7, wp.z,
                                2 + 3 * w, 1, 0.82, 0.2, 0.35 + 0.55 * w)
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
                pinned and 1 or 0, pinned and 0.5 or 1, pinned and 0 or 0.4, 0.8)
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
            ADDrawingManager:addSphereTask(p.x, py, p.z, 2.5, 0.2, 0.8, 1, 0.6)
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
            ADDrawingManager:addSphereTask(p.x, py, p.z, 2.5, 1, 0.6, 0.1, 0.6)
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
            ADDrawingManager:addSphereTask(p.x, p.y + 0.4, p.z, 3, r, g, b, 0.8)
            ADDrawingManager:addSphereTask(p.x, p.targetY + 0.4, p.z, 2, r, g, b, 0.4)
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
                ADDrawingManager:addSphereTask(c.ax, (c.ay or baseY) + 0.5, c.az, 1.8, cr, cg, cb, 1)
                ADDrawingManager:addSphereTask(c.bx, (c.by or baseY) + 0.5, c.bz, 1.8, cr, cg, cb, 1)
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
            ADDrawingManager:addSphereTask(w.x, gy + 4, w.z, 2.5, r, g, b, 1)
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
            ADDrawingManager:addSphereTask(p.x, py, p.z, 2.5, 0.4, 1, 0.4, 0.6)
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
            ADDrawingManager:addSphereTask(p.x, (p.y or cursorGroundY) + 0.6, p.z, 3, 0, 1, 0.4, 0.7)
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
        local x0, z0 = self.boxStartX, self.boxStartZ
        local x1, z1 = self.cursorX, self.cursorZ
        local corners = { { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } }
        for i = 1, 4 do
            local a, b = corners[i], corners[(i % 4) + 1]
            ADDrawingManager:addLineTask(
                a[1], AutoDrive:getTerrainHeightAtWorldPos(a[1], a[2]) + 0.5, a[2],
                b[1], AutoDrive:getTerrainHeightAtWorldPos(b[1], b[2]) + 0.5, b[2],
                lw, 0, 1, 0.2)
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
        Logging.info("[FlyoverEditor]: click button=%s active=%s camera=%s cursor=%s guiBlocking=%s",
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
    Logging.info("[FlyoverEditor]: tool card %s.", self.cardHidden and "hidden" or "shown")
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
    -- Jump the floating card out to a fixed offset from the FIRST click of an action - never right on
    -- top of the point you just clicked, which is what made it feel like it was always in the way. It
    -- can then be dragged (by its header) whever you actually want it, and it stays there - through
    -- the rest of the action and every action after, in every tool - until the NEXT tool's first
    -- click jumps it again. self.toolCardDragged (set by the drag itself) skips the jump once the
    -- player has taken control of it, so a deliberate placement is never overridden.
    if not self:toolHasPendingStart() and not self.toolCardDragged and g_lastMousePosX ~= nil then
        local offX, offY = 0.10, 0.08
        local ox = (g_lastMousePosX < 0.55) and offX or -offX     -- offset AWAY from screen centre,
        local oy = (g_lastMousePosY < 0.55) and offY or -offY     -- so it lands on-screen, not clipped
        self.toolCardX = math.max(0, math.min(1, g_lastMousePosX + ox))
        self.toolCardY = math.max(0, math.min(1, g_lastMousePosY + oy))
    end

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
    -- An armed popup owns interaction: a left click anywhere but on the popup (which the panel has
    -- already consumed) cancels back to Select, rather than letting the armed tool re-pick endpoints
    -- from the world. Apply is a right-click or the popup's own apply row.
    if self.ctxMenu ~= nil and self.ctxMenu.kind == "armed" then
        self:menuCancelArmed()
        Logging.info("[FlyoverEditor]: armed tool cancelled (clicked away).")
        return
    end

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
            Logging.info("[FlyoverEditor]: armed tool applied (right-click).")
        else
            self:closeMenu()
            Logging.info("[FlyoverEditor]: context menu closed (right-click).")
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
    elseif tool == self.TOOL.GROUND then
        if self.groundToId ~= nil then
            self:commitGround()
            return true
        elseif self.groundFromId ~= nil then
            self:cancelGround()
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
            if jp ~= nil and jp.clearMode then
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
                Logging.info("[FlyoverEditor]: junction site unlocked (nothing to place).")
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
            self:regroundTo(n.id, wp.x, wp.z, wp.y)
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

--- Which tools offer the picked-span / whole-run choice: everything that works on a span between
--- two points. Delete and convert have their own point-vs-run scope, which means something else.
function ADFlyoverEditor:toolTakesSpanScope()
    return self.tool == self.TOOL.PARALLEL
        or self.tool == self.TOOL.SMOOTH
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
    Logging.info("[FlyoverEditor]: %s covers the whole run: %d waypoint(s), id=%s to id=%s.",
        self.TOOL_NAMES[self.tool] or "tool", #ids, tostring(fromId), tostring(toId))
    return true
end

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
    self.spanIds = nil
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
        return { {
            label = "falloff along track",
            unit = "m",
            get = function() return editor.falloffRadius end,
            apply = function(value)
                editor:setFalloffRadius(value)
                return editor.falloffRadius
            end,
            step = function(dir)
                editor:setFalloffRadius(editor.falloffRadius + dir * AutoDrive.FLYOVER_FALLOFF_WHEEL_STEP)
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

--- Toggle the junction tool's road-surface / corridor check. Off, a turn is still bounded by the
--- radius setting but is never shrunk or refused for leaving the road - see junctionSolveMovement.
function ADFlyoverEditor:toggleJunctionCheckSurface()
    self.junctionCheckSurface = not (self.junctionCheckSurface ~= false)
    self.junctionPreviewKey = nil        -- force a resolve so the change is visible immediately
    Logging.info("[FlyoverEditor]: junction road-surface check %s.",
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
    Logging.info("[FlyoverEditor]: junction obstacle check %s.",
        self.junctionCheckObstacles and "on" or "off (corridors may pass through obstacles)")
end

--- Toggle the connector curve engine between Dubins (radius-bounded pose-to-pose) and the biarc.
function ADFlyoverEditor:toggleJunctionCurveEngine()
    self.junctionUseDubins = not (self.junctionUseDubins ~= false)
    self.junctionPreviewKey = nil
    Logging.info("[FlyoverEditor]: junction curve engine: %s.",
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
    self.junctionMode = (self.junctionMode == "clear") and "build" or "clear"
    self.junctionPreviewKey = nil
    Logging.info("[FlyoverEditor]: junction tool set to %s.",
        self.junctionMode == "clear" and "clear (removes old wiring, leaves the roads)" or "build (lays new turns)")
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
    Logging.info("[FlyoverEditor]: junction existing turns will be %s.",
        self.junctionRebuild and "REBUILT (old connectors replaced)" or "kept as they are")
end

--- Toggle whether a trimmed stem's tie-in may project past where the track actually ends. Off
--- restores the strict original behaviour (clamp at the trim); on (default) reaches the
--- geometrically correct tie-in point even when the visible track was cut back short of it.
function ADFlyoverEditor:toggleJunctionExtendTrim()
    self.junctionExtendTrim = not (self.junctionExtendTrim ~= false)
    self.junctionPreviewKey = nil
    Logging.info("[FlyoverEditor]: junction trim/extend %s.",
        self.junctionExtendTrim and "on (projects past a trimmed stem)" or "off (clamps at the trim)")
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
    Logging.info("[FlyoverEditor]: smooth mode -> %s.", self.SMOOTH_MODE_NAMES[self.smoothMode])
end

function ADFlyoverEditor:smoothClick()
    if self.hoverId == nil then
        return
    end

    if self:claimWholeRunClick(function(a, b)
            self.smoothFromId, self.smoothToId = a, b
            self.smoothPreview, self.smoothPinned = nil, nil
        end) then
        return
    end

    if self.smoothFromId == nil then
        self.spanIds = nil
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
    self.spanIds = nil
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
--- One localized guidance message for the current tool state, returned WHOLE (not pre-split). The
--- panel wraps it to width at render (see buildRows). Collapsing the old line pairs into one string is
--- what lets German - which wraps differently from English - read as a sentence rather than two halves
--- broken at the English line break. Format placeholders are kept inside the localized template so the
--- live value lands in the right place in either language.
function ADFlyoverEditor:getNextStepLines()
    local t = self.TOOL
    local function L(s) return ADFlyoverLocale ~= nil and ADFlyoverLocale.t(s) or s end
    local function side() return (self.offsetSide or 1) >= 0 and L("left") or L("right") end

    if self.tool == t.NONE then
        return L("No tool selected. Pick one above, or press 1-9 / 0.")
    end

    if self.tool == t.DRAW then
        if self.lastWaypointId ~= nil then
            return L("Click ground to extend, or a waypoint to link. Right-click ends.")
        end
        return L("Click to start a run, or a waypoint to draw on from it.")
    elseif self.tool == t.MOVE then
        if self.dragId ~= nil then
            return string.format(L("Wheel changes falloff (%.1fm), live. Release to drop."), self.falloffRadius)
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
        if self.offsetScope == self.OFFSET_SCOPE.RUN then
            return L("Click a run to offset the whole thing, junction to junction.")
        end
        return L("Click one end of a span to run a track alongside it.")
    elseif self.tool == t.GROUND then
        if self.groundToId ~= nil then
            local n = self.groundPreview ~= nil and #self.groundPreview or 0
            if n == 0 then
                return string.format(L("Nothing over %.1fm off the ground. Wheel the tolerance down to see more."), self.groundTolerance)
            end
            return string.format(L("%d of %d waypoint(s) off the ground. Right-click re-seats them."), n, self.groundChecked or 0)
        end
        if self.groundFromId ~= nil then
            return L("Click the far end of the span.")
        end
        if self.offsetScope == self.OFFSET_SCOPE.RUN then
            return L("Click a run to check the whole thing for waypoints off the ground.")
        end
        return L("Click one end of a span to find waypoints off the ground.")
    elseif self.tool == t.STRAIGHTEN then
        if self.straightenToId ~= nil then
            return string.format(L("Wheel sets tolerance (%.2fm). Right-click straightens the span."), self.straightenTolerance)
        end
        if self.straightenFromId ~= nil then
            return L("Click the far end of the span.")
        end
        return L("Click one end of a span to straighten it.")
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
            L(self.CONVERT_OP_NAMES[self.convertOp]),
            self.convertScope == self.DELETE_SCOPE.RUN and L("whole run") or L("this waypoint"))
    elseif self.tool == t.MERGE then
        if self.mergeToId ~= nil then
            return L("Green marks what would be absorbed. Click a point on the OTHER track.")
        end
        if self.mergeFromId ~= nil then
            return L("Click the far end of the span, on the SAME track.")
        end
        return L("Click one end of the span to merge.")
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
        for _, listName in ipairs({ "out", "incoming" }) do
            for _, other in pairs(wp[listName] or {}) do
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
            Logging.info("[FlyoverEditor]: that run is a closed loop of %d waypoint(s); using it "
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

    -- Whole-run scope needs one click, not two. The resolution is shared with smooth, divide and
    -- straighten: the run's ends are extended onto the junctions it stopped before, and the route
    -- between them is kept from walking the collected run rather than re-derived. This tool is
    -- where all three of those lessons were learned, so it has no business keeping its own copy.
    if self.offsetScope == self.OFFSET_SCOPE.RUN then
        if self:claimWholeRunClick(function(a, b)
                self.offsetFromId, self.offsetToId = a, b
                self.offsetPreview, self.offsetCache = nil, nil
            end) then
            -- Seed the side from where the cursor is, exactly as the two-click path does.
            local seedPts = self:offsetSpanPoints()
            if seedPts ~= nil then
                self.offsetSide = self:offsetSideFromCursor(seedPts)
            end
        end
        return
    end

    if self.offsetFromId == nil then
        self.offsetFromId = self.hoverId
        self.spanIds = nil
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
    -- The actual route, not just its length. runPathBetween is a path FINDER: asked to get from a
    -- siding back to the main line it can leave along one merge taper and return along the other,
    -- which is a legitimate shortest path and a span that doubles back. The offset then copies that
    -- shape faithfully, so the track looks wrong while the offset itself was right. Printing the
    -- ids is what tells those two apart without another screenshot to guess from.
    local ids = {}
    for i, id in ipairs(span) do
        ids[i] = tostring(id)
    end
    Logging.info("[FlyoverEditor]: span route: %s", table.concat(ids, " -> "))
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
        for _, listName in ipairs({ "out", "incoming" }) do
            for _, otherId in pairs(current[listName] or {}) do
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
        for _, listName in ipairs({ "out", "incoming" }) do
            for _, other in pairs(wp[listName] or {}) do
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
                Logging.info("[FlyoverEditor]: the shortest path doubled back through an "
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
function ADFlyoverEditor:commitOffset()
    Logging.info("[FlyoverEditor]: commit %s: from=%s to=%s anchor=%s preview=%s",
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
    local layReversed = oneWayCount > 0

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

    Logging.info("[FlyoverEditor]: laid a %s of %d waypoint(s) %.1fm to the %s%s.",
        siding and "siding" or "parallel track", #laying, self.offsetDistance,
        (self.offsetSide or 1) >= 0 and "left" or "right",
        siding and ", splined in at both ends"
            or (mixed and string.format(", mixed (%d two-way, %d one-way segment(s)), running opposite",
                    dualCount, oneWayCount)
                or (dual and ", two-way" or ", running opposite")))

    self.offsetFromId, self.offsetToId, self.offsetPreview, self.offsetCache = nil, nil, nil, nil
    self.spanIds = nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelOffset()
    if self.offsetFromId ~= nil or self.offsetToId ~= nil then
        Logging.info("[FlyoverEditor]: cancelled the span.")
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
        Logging.info("[FlyoverEditor]: junction clearance - " .. fmt, ...)
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
    if self.groundFromId == nil or self.groundToId == nil then
        self.groundPreview = nil
        return
    end

    local span = self:spanBetween(self.groundFromId, self.groundToId)
    if span == nil or #span < 1 then
        self.groundPreview, self.groundBlockedBy = nil, "those two points are not two ends of one span."
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
        if firstWp == nil or lastWp == nil or total < 0.01 then
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
    if self.hoverId == nil then
        return
    end

    -- Each new inspection starts from the default tolerance. The wheel adjusts it while a span is
    -- selected, and the wheel is also the zoom - so a value scrolled up by accident and carried over
    -- hid points two and three metres off the ground behind a five-metre tolerance.
    if self:claimWholeRunClick(function(a, b)
            self.groundFromId, self.groundToId = a, b
            self.groundPreview = nil
            self.groundTolerance = AutoDrive.FLYOVER_GROUND_DEFAULT
        end) then
        return
    end

    if self.groundFromId == nil then
        self.spanIds = nil
        self.groundTolerance = AutoDrive.FLYOVER_GROUND_DEFAULT
        self.groundFromId = self.hoverId
        Logging.info("[FlyoverEditor]: grounding from id=%s; click the far end of the span.",
            tostring(self.groundFromId))
        return
    end

    if self.hoverId == self.groundFromId then
        return
    end

    self.groundToId = self.hoverId
    self.groundPreview = nil
    Logging.info("[FlyoverEditor]: ground span set, id=%s to id=%s. Wheel sets the tolerance "
        .. "(%.1fm). Right-click re-seats what is marked.",
        tostring(self.groundFromId), tostring(self.groundToId), self.groundTolerance)
end

function ADFlyoverEditor:commitGround()
    if self.groundPreview == nil or #self.groundPreview == 0 then
        Logging.info("[FlyoverEditor]: nothing is further than %.1fm off the ground in that span "
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

    Logging.info("[FlyoverEditor]: re-seated %d waypoint(s) on the ground - %d lowered, %d raised "
        .. "(tolerance %.1fm).", moved, lowered, raised, self.groundTolerance)

    self.groundFromId, self.groundToId, self.groundPreview = nil, nil, nil
    self.spanIds = nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelGround()
    self.spanIds = nil
    if self.groundFromId ~= nil or self.groundToId ~= nil then
        Logging.info("[FlyoverEditor]: cancelled the ground span.")
    end
    self.groundFromId, self.groundToId, self.groundPreview = nil, nil, nil
end

function ADFlyoverEditor:straightenClick()
    if self.hoverId == nil then
        return
    end

    if self:claimWholeRunClick(function(a, b)
            self.straightenFromId, self.straightenToId = a, b
            self.straightenPreview = nil
        end) then
        return
    end

    if self.straightenFromId == nil then
        self.spanIds = nil
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
    local anchorPositions = self:collectSpanAnchors(ids)
    local piecesDone = 0
    -- Backwards, so a rebuilt piece cannot renumber the anchors of a piece not yet reached.
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
                        if self:replaceChainInterior(piece, result, dual, flags) then
                            piecesDone = piecesDone + 1
                        end
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

    Logging.info("[FlyoverEditor]: straightened a %d-point span in %d junction-free piece(s) at %.2fm tolerance.",
        #pts, pieces, self.straightenTolerance)

    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
end

function ADFlyoverEditor:cancelStraighten()
    self.spanIds = nil
    if self.straightenFromId ~= nil or self.straightenToId ~= nil then
        Logging.info("[FlyoverEditor]: cancelled the straighten span.")
    end
    self.straightenFromId, self.straightenToId, self.straightenPreview = nil, nil, nil
end

function ADFlyoverEditor:divideClick()
    if self.hoverId == nil then
        return
    end

    if self:claimWholeRunClick(function(a, b)
            self.divideFromId, self.divideToId = a, b
            self.dividePreview = nil
        end) then
        return
    end

    if self.divideFromId == nil then
        self.spanIds = nil
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
local jxWhy = {}   -- per reason: how many taken, and the farthest of them
-- WAS IT ALREADY LOOSE, AND DID WE CUT IT ON PURPOSE. Two things the clear knows exactly, and
-- between them they say which loose ends are its business. No distance can answer this: a junction
-- cleared earlier keeps no forks to be recognised by, and its branches sit well inside any radius
-- wide enough to be useful.
local jxWasLoose, jxCut, jxExisted = nil, nil, nil
local jxForeignForks   -- defined below, used by jxBegin

--- One-ended: something leads in and nothing out, or the other way about.
local function jxLoose(w)
    local nOut, nIn = #(w.out or {}), #(w.incoming or {})
    return (nOut == 0) ~= (nIn == 0)
end

--- Mark a point as having been cut FROM something on purpose. Rejoining it would undo the work.
local function jxMarkCut(w)
    if jxCut ~= nil and w ~= nil then jxCut[w] = true end
end

--- Begin a clear: nothing may be deleted outside `site` until jxEnd.
local function jxBegin(site)
    jxBound, jxBlocked, jxTook, jxFarthest, jxWired = site, 0, 0, 0, 0
    jxWhy = {}
    jxForeignForks(site)
    -- Everything already hanging loose before this clear touched anything. Whatever left these ends
    -- this way - a clear done an hour ago, a route half drawn by hand - it was not us, so it is not
    -- ours to put back.
    jxWasLoose, jxCut, jxExisted = {}, {}, {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil then
            jxExisted[w] = true
            if jxLoose(w) then jxWasLoose[w] = true end
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
    return held, took, far
end

local function jxMayDelete(x, z)
    local site = jxBound
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

--- Does this point belong to the junction being worked on? The same question the deletions ask,
--- asked by anything else that must not wander into the junction next door.
local function jxInSite(x, z) return jxMayDelete(x, z) end

--- Did THIS clear cut this point off from something? The gate marks every point it severs on
--- purpose, so anything else lying loose nearby was already like that when the clear began.
local function jxWasCutByUs(w)
    return jxCut ~= nil and w ~= nil and jxCut[w] == true
end

--- The one way a clear removes a waypoint. Takes an id or the node itself; the node is safer, since
--- every removal renumbers the ids above it.
local function jxRemove(which, why)
    local w = which
    if type(w) ~= "table" then w = ADGraphManager:getWayPointById(which) end
    if w == nil or w.id == nil then return false end
    if not jxMayDelete(w.x, w.z) then
        jxBlocked = jxBlocked + 1
        return false
    end
    local site = jxBound
    if site ~= nil then
        local d = math.sqrt((w.x - site.x) ^ 2 + (w.z - site.z) ^ 2)
        if d > jxFarthest then jxFarthest = d end
        local e = jxWhy[why or "?"] or { n = 0, far = 0 }
        e.n = e.n + 1
        if d > e.far then e.far = d end
        jxWhy[why or "?"] = e
    end
    jxTook = jxTook + 1
    -- Whatever this point was joined to is now an end, and on purpose.
    for _, id in ipairs(w.out or {}) do jxMarkCut(ADGraphManager:getWayPointById(id)) end
    for _, id in ipairs(w.incoming or {}) do jxMarkCut(ADGraphManager:getWayPointById(id)) end
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
    jxMarkCut(a)
    jxMarkCut(b)
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
    if self._jxVirgin ~= nil and self._jxVirginCount == count then return self._jxVirgin end
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
    self._jxVirgin, self._jxVirginCount = out, count
    return out
end

function ADFlyoverEditor:junctionCentres()
    local count = ADGraphManager:getWayPointsCount()
    local merge = AutoDrive.FLYOVER_JUNCTION_MERGE or 10
    if self._jxCentres ~= nil and self._jxCentresCount == count and self._jxCentresMerge == merge then
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
    local corners = {}
    for _, f in pairs(wps) do
        if f ~= nil and (deg[f] or 0) >= 3 then
            for _, oid in ipairs(f.out or {}) do
                local o = ADGraphManager:getWayPointById(oid)
                if o ~= nil then
                    local chain, prev, cur, len = { f, o }, f, o, math.sqrt((o.x - f.x) ^ 2 + (o.z - f.z) ^ 2)
                    while (deg[cur] or 0) == 2 and #chain < 200 and len <= 60 do
                        local nxt = nil
                        for _, nid in ipairs(cur.out or {}) do
                            local w = ADGraphManager:getWayPointById(nid)
                            if w ~= nil and w ~= prev then nxt = w break end
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
            for id in pairs(nb) do
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
                            for nid in pairs(cnb) do
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

        local going = 0
        for _, r in ipairs(roads) do
            if r.len >= MINARM then going = going + 1 end
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
            if site ~= nil then return site end
        end
    end
    local firstWhy = nil
    for _, s in ipairs(sites) do
        if s.d2 > SELECT * SELECT then break end
        local site, why = evaluate(s)
        if site ~= nil then return site end
        firstWhy = firstWhy or why
        if not s.virgin and #s.nodes >= 4 then break end
    end
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

local function jxDebugLogStart()
    if Logging == nil or jxDebugSaved ~= nil then return end
    jxDebugLines = {}
    jxDebugSaved = { info = Logging.info, warning = Logging.warning, error = Logging.error }
    local function wrap(level, original)
        return function(fmt, ...)
            if jxDebugLines ~= nil and #jxDebugLines < 5000 then
                local ok, line = pcall(string.format, fmt, ...)
                jxDebugLines[#jxDebugLines + 1] = level .. (ok and line or tostring(fmt))
            end
            if original ~= nil then return original(fmt, ...) end
        end
    end
    Logging.info = wrap("", jxDebugSaved.info)
    Logging.warning = wrap("WARNING: ", jxDebugSaved.warning)
    Logging.error = wrap("ERROR: ", jxDebugSaved.error)
end

--- Put Logging back and hand over what was said. Always restores, even if nothing was captured.
local function jxDebugLogStop()
    local lines = jxDebugLines or {}
    if jxDebugSaved ~= nil and Logging ~= nil then
        Logging.info, Logging.warning, Logging.error =
            jxDebugSaved.info, jxDebugSaved.warning, jxDebugSaved.error
    end
    jxDebugSaved, jxDebugLines = nil, nil
    return lines
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
function ADFlyoverEditor:debugCaptureBegin(what, site, extra)
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
        name = string.format("%04d_%s_%s%.1f_%.1f", jxDebugSeq, what or "op",
            n ~= nil and string.format("j%02d_", n) or "", site.x, site.z)
        site = { x = site.x, z = site.z, n = n }
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
    jxDebugLogStart()
    if not jxDebugWriteGraph(dir .. "pre.xml") then
        -- Put Logging back before leaving. Bailing out with it still wrapped would have left every
        -- line the game logs for the rest of the session going into a buffer nothing ever reads.
        jxDebugLogStop()
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
        if cap.site.n ~= nil then meta[#meta + 1] = string.format("junction       j%02d", cap.site.n) end
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
    local lines = jxDebugLogStop()
    local l = io.open(cap.dir .. "tool.log", "w")
    if l ~= nil then l:write(table.concat(lines, "\n") .. "\n") l:close() end
    Logging.info("[FlyoverEditor]: debug capture %04d - written, %d log line(s). %s",
        jxDebugSeq, #lines, cap.dir)
end

--- The numbers as they were last written: a list of { n, x, z } and the path it came from, or nil
--- when this savegame has no file yet or it cannot be read. Only number and position are kept,
--- because position is all a junction can be recognised by after a restart - its node ids are
--- reissued by every removal, and a clear replaces the nodes outright.
local function junctionRegistryLoad()
    local folder = junctionRegistryFolder()
    if folder == nil or fileExists == nil then return nil end
    local path = folder .. JUNCTION_REGISTRY_FILE
    if not fileExists(path) then return nil end
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
                list[#list + 1] = { n = n, x = x, z = z }
            end
            i = i + 1
        end
        delete(xml)
    end)
    if not ok then
        Logging.warning("[FlyoverEditor]: junction - could not read the saved numbers (%s): %s",
            path, tostring(err))
        return nil
    end
    return list, path
end

--- Write every numbered junction, found or not: the ones the scan no longer sees are exactly the
--- ones whose numbers would otherwise be handed out again after a restart. Returns true when the
--- file was written.
local function junctionRegistrySave(reg)
    local folder = junctionRegistryFolder()
    if folder == nil or createXMLFile == nil or fileExists == nil then return false end
    -- A career that has never been saved has no folder yet, and making one here would leave a
    -- savegame slot holding nothing but this file for the game to trip over. The numbers stay in
    -- memory, the registry stays marked unsaved, and the next build tries again.
    if not fileExists(folder .. "careerSavegame.xml") then return false end
    local path = folder .. JUNCTION_REGISTRY_FILE
    local byNumber = {}
    for _, f in ipairs(reg) do
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
        end
        saveXMLFile(xml)
        delete(xml)
    end)
    if not ok then
        Logging.warning("[FlyoverEditor]: junction - could not save the numbers (%s): %s",
            path, tostring(err))
        return false
    end
    return true
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

function ADFlyoverEditor:junctionRegistry()
    local count = ADGraphManager:getWayPointsCount()
    if self._jxReg ~= nil and self._jxRegCount == count then return self._jxReg end

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
    local prev, fromFile = self._jxReg, nil
    if prev == nil then
        prev, fromFile = junctionRegistryLoad()
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
                                  cleared = true }
            taken[p.n] = true
            nKept = nKept + 1
        end
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
    -- yet saved has no folder) leaves the registry marked, and the next build tries again.
    if gained then self._jxRegUnsaved = true end
    if self._jxRegUnsaved and junctionRegistrySave(found) then
        self._jxRegUnsaved = false
    end

    self._jxReg, self._jxRegCount = found, count
    return found
end

--- The number of the junction nearest (x, z), or nil when there is none close enough to name.
function ADFlyoverEditor:junctionNumberAt(x, z)
    if x == nil or z == nil then return nil end
    local best, bestD = nil, 30 * 30
    for _, f in ipairs(self:junctionRegistry() or {}) do
        local d = (f.x - x) ^ 2 + (f.z - z) ^ 2
        if d < bestD then bestD, best = d, f end
    end
    return best and best.n or nil
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
    local clearMode0 = (self.junctionMode == "clear")
    local R = self:junctionRadiusValue()
    -- NB: a DIFFERENT name from the scope radius R - shadowing it once made the scope circle render
    -- at the turn radius instead of the search radius.
    local turnR = self.junctionTurnRadius or 12

    -- THE CLICK PICKS THE JUNCTION, AND THEN IT IS DONE WITH.
    --
    -- Everything below used to be measured from wherever the cursor happened to be: the circle that
    -- selects the tracks sat on it, so each click cut every track at a different waypoint and handed
    -- the whole solve a different set of bearings. Five clicks within two and a half metres of one
    -- junction produced five different clears - at one of them the point count swung by fifteen.
    -- That is not a tolerance, it is the tool doing a different job each time it is asked.
    --
    -- So the click is used once, to say WHICH junction is meant, and from there the junction's own
    -- middle is the origin for all of it. Two clicks that pick the same junction now run identical
    -- arithmetic. The scope radius goes with it: it was the other thing the answer moved with, and
    -- clear mode has no use for it - what belongs to a junction is a property of the road, not of a
    -- number on a wheel.
    local clickX, clickZ = cx, cz
    if clearMode0 then
        -- STEP 1: ONE junction, or none. The cursor stops standing for itself the moment it is
        -- pointing at a junction - what belongs to that junction is a property of the road, not of
        -- where inside it the click landed - and where it is pointing at nothing, the clear REFUSES
        -- and says why rather than working on whatever happens to be nearby.
        local site, why = self:junctionSelect(cx, cz)
        -- ALREADY CLEAR IS A REFUSAL TOO. A virgin junction - lane ends facing each other, nothing
        -- joining them - has no wiring to take out, and what a second clear finds to remove there is
        -- the lanes' own rebuilt ends. It used to be refused by accident, because the selection
        -- could not see a junction once it had been cleared; now that it can, it says so on purpose.
        if site ~= nil and site.virgin then
            site, why = nil, "this junction is already clear - nothing is wired here (build can start from it)"
        end
        if site == nil then
            self.junctionSite = nil
            self.junctionRefused = why
            self.junctionPreview, self.junctionPreviewKey = nil, nil
            return
        end
        self.junctionSite, self.junctionRefused = site, nil
        cx, cz = site.x, site.z
        R = AutoDrive.FLYOVER_JUNCTION_CLEAR_SCOPE or 14
    else
        -- BUILD MODE TAKES THE SAME FRONT END. The click is resolved to a junction and the solve is
        -- centred on the junction, not on wherever inside it the cursor landed - the same click-
        -- independence the clear has. Where the selection finds nothing build carries on from the
        -- cursor exactly as it always did: it is a construction tool and may have business at a
        -- site that is not a junction yet, so here a refusal is a note on the card, not a stop.
        local site, why = self:junctionSelect(cx, cz)
        if site ~= nil then
            self.junctionSite, self.junctionRefused = site, nil
            cx, cz = site.x, site.z
        else
            self.junctionSite, self.junctionRefused = nil, why
        end
    end
    -- The solve raycasts the road surface for every candidate radius of every turn, so it is only
    -- redone when something it depends on changed: the cursor (to half a metre), a setting, or the
    -- graph. Between those the last preview stands.
    local key = string.format("%d_%d_%d_%d_%s_%s_%s_%s_%d", math.floor(cx * 2), math.floor(cz * 2), R, turnR,
        tostring(self.junctionCheckSurface ~= false), tostring(self.junctionExtendTrim ~= false),
        tostring(self.junctionRebuild == true), tostring(self.junctionUseDubins ~= false)
            .. tostring(self.junctionCheckObstacles ~= false)
            .. string.format("_%d_%d", (self.junctionCorridor or 4) * 10, (self.junctionClearance or 5) * 10)
            -- The swept-path prediction runs only on a LOCKED site (see below), so locking must
            -- refresh the preview; and a newly captured rig changes every predicted line.
            .. "_" .. tostring(self.junctionSwept ~= false) .. "_" .. tostring(self.junctionArmed ~= nil)
            .. "_" .. tostring(ADFlyoverSweptPath and ADFlyoverSweptPath.rig and ADFlyoverSweptPath.rig.name or "-"),
        ADGraphManager:getWayPointsCount())
    if key == self.junctionPreviewKey and self.junctionPreview ~= nil then
        return
    end
    self.junctionPreviewKey = key
    self.junctionPreview = nil
    self.junctionChainCache = {}
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

    -- AN ARM THAT ENDS INSIDE THE CIRCLE IS STILL AN ARM. Approaches were only ever the lanes the
    -- circle CUTS, and between a close pair that misses a whole road: once the neighbour is cleared,
    -- the lanes towards it stop at the neighbour's box, a few metres away and well inside this
    -- junction's circle, so they cross nothing. The junction was then read with an arm missing - a T
    -- as two roads meeting at a corner, its box laid across the wrong pair. A lane END inside the
    -- circle is taken as an approach just as a cut lane is: where travel stops it is an exit, where
    -- travel starts it is an entry.
    if clearMode0 then
        -- A loose end in the junction's own wiring is not an arm. What marks a real lane end is
        -- that it is the OUTER end of a stub of plain road leading INTO the junction: followed
        -- inward it runs as a plain chain for a few metres and arrives at a fork that lies nearer
        -- the middle than the end itself does.
        local function stubInto(wp, dir)
            local prev, cur, run = nil, wp, 0
            for _ = 1, 12 do
                local lst = cur[dir] or {}
                if #lst ~= 1 then return false end
                local nxt = ADGraphManager:getWayPointById(lst[1])
                if nxt == nil or inside[nxt.id] == nil then return false end
                run = run + math.sqrt((nxt.x - cur.x) ^ 2 + (nxt.z - cur.z) ^ 2)
                local s2, d = {}, 0
                for _, l2 in ipairs({ nxt.out or {}, nxt.incoming or {} }) do
                    for _, id in pairs(l2) do if not s2[id] then s2[id] = true d = d + 1 end end
                end
                if d >= 3 then
                    local dEnd = (wp.x - cx) ^ 2 + (wp.z - cz) ^ 2
                    local dFork = (nxt.x - cx) ^ 2 + (nxt.z - cz) ^ 2
                    return run >= 3 and dFork < dEnd
                end
                prev, cur = cur, nxt
            end
            return false
        end
        for _, wp in pairs(inside) do
            local nOut, nIn = #(wp.out or {}), #(wp.incoming or {})
            if nOut == 0 and nIn == 1 and stubInto(wp, "incoming") then
                local p = ADGraphManager:getWayPointById(wp.incoming[1])
                raw[#raw + 1] = { wp = wp, dir = "out", bearing = math.atan2(wp.x - p.x, wp.z - p.z), laneEnd = true }
            elseif nIn == 0 and nOut == 1 and stubInto(wp, "out") then
                local t = ADGraphManager:getWayPointById(wp.out[1])
                raw[#raw + 1] = { wp = wp, dir = "in", bearing = math.atan2(t.x - wp.x, t.z - wp.z), laneEnd = true }
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

    -- ---------------------------------------------------------------------------------------------
    -- From here on the WHEEL IS DONE. The search circle has said which tracks take part; everything
    -- that follows - where the tracks meet, where the tool ties into them, kickouts, what is already
    -- connected, what a rebuild clears - works in the fixed WORK REGION and comes out the same
    -- whatever size the circle was. (It used to all run inside the circle: tie-ins clamped at its
    -- edge, a turn radius near the scope radius could not be laid, and a kickout needed the circle
    -- widened to fit - the wheel was quietly an intersection-geometry control.)
    --
    -- Each selected track is RE-ANCHORED: followed away from the junction (an entry upstream, an
    -- exit downstream, bearing-continuous) to the edge of the work region, and that far node becomes
    -- the approach's anchor - the start of its lane chain. The node where the circle cut the track is
    -- kept as selWp (the preview's pillar stands there) and ap.bearing stays the bearing AT the cut,
    -- near the junction, for the turn-angle decisions. Two selections that re-anchor to the same node
    -- are the same lane and fold into one - which is also what absorbs an existing kickout that
    -- happens to cross the circle beside its lane: followed outward it rejoins the lane and lands on
    -- the lane's own anchor.
    -- How far a run is followed OUTWARD from where the circle cut it, as LENGTH ALONG THE RUN: what a
    -- turn can need - a tie-in up to ~1.5 turn radii back from the corner, then the kickout's late
    -- return (look-ahead + trailer length) - plus a margin. Need-based, so it is tens of metres, not
    -- a big blanket region; and it is a length along the track, not a radius from the click.
    local reachRig = (ADFlyoverSweptPath ~= nil and ADFlyoverSweptPath.rig) or (SweptSim ~= nil and SweptSim.EXAMPLE_RIG) or {}
    local runReach = turnR * 1.5 + ((reachRig.lookAhead or 8) + (reachRig.trailerLength or 0)) + 10
    -- The node INDEX the rest of the solve searches in: generous enough to hold every followed run.
    -- Only an index bound - nothing geometric is measured against it.
    local W = math.max(AutoDrive.FLYOVER_JUNCTION_WORK_REACH or 60, R + runReach + 10)
    local W2 = W * W
    local work = {}
    for _, wp in pairs(wps) do
        local dx, dz = wp.x - cx, wp.z - cz
        if dx * dx + dz * dz <= W2 then work[wp.id] = wp end
    end
    local ownR2 = (R + (AutoDrive.FLYOVER_JUNCTION_OWN_TOLERANCE or 5)) ^ 2
    self.junctionOwn = { cx = cx, cz = cz, r2 = ownR2 }
    local function isOwn(wp) return (wp.x - cx) ^ 2 + (wp.z - cz) ^ 2 <= ownR2 end
    -- Does the wiring hanging off `fromId` through `startId` reach the search circle (+ tolerance)?
    -- A bounded flood that may not pass back through `fromId` - so it cannot cheat by running down
    -- our own lane into the circle.
    local function branchIsOurs(startId, fromId)
        local seenB, stackB, n = { [fromId] = true, [startId] = true }, { startId }, 0
        while #stackB > 0 and n < 200 do
            local id = table.remove(stackB)
            local w = work[id]
            n = n + 1
            if w ~= nil then
                if isOwn(w) then return true end
                for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                    for _, x in pairs(lst) do
                        if not seenB[x] and work[x] ~= nil then
                            seenB[x] = true
                            stackB[#stackB + 1] = x
                        end
                    end
                end
            end
        end
        return false
    end
    do
        local merged, byAnchor = {}, {}
        for _, ap in ipairs(approaches) do
            local useOut = (ap.dir == "out")
            local wdx, wdz = math.sin(ap.bearing), math.cos(ap.bearing)
            if not useOut then wdx, wdz = -wdx, -wdz end
            local node, cameFrom = ap.wp, nil
            local tbx, tbz = math.sin(ap.bearing), math.cos(ap.bearing)   -- travel direction at the anchor
            local run, endedAt = 0, nil
            -- The way the run was followed, cut node first: the lane walk prefers it on the way back.
            local runPath = { ap.wp }
            for _ = 1, 400 do
                local list = useOut and (node.out or {}) or (node.incoming or {})
                local nextId, bestDot = nil, -math.huge
                -- THE LANE'S OWN ROAD CAN END BEFORE THE REACH DOES. Going outward, a node with two
                -- ways on is where this lane is FED from (or splits into) two places - and if each of
                -- them arrives turned more than 35 degrees, they are another junction's turn
                -- connectors and this lane begins right here. Following one of them carried the run
                -- round the neighbour's corner and anchored a 4-way's arm on the crossbar of the T
                -- 37 m down it; the lane walk back from there went straight on along the crossbar,
                -- never reached the 4-way at all, and the arm's real lane - road nobody had claimed -
                -- was cleared as wiring. (The test below for "another junction" asks whether the side
                -- branch can reach the circle, and through a junction everything can.)
                local turnsAway = nil
                if cameFrom ~= nil then
                    local nWays, nTurns, verdict = 0, 0, {}
                    for _, nid in pairs(list) do
                        if nid ~= cameFrom and work[nid] ~= nil and verdict[nid] == nil then
                            nWays = nWays + 1
                            verdict[nid] = junctionBranchTurn(node, work[nid], useOut, wdx, wdz, 60) > math.rad(35)
                            if verdict[nid] then nTurns = nTurns + 1 end
                        end
                    end
                    if nWays >= 2 then
                        if nTurns == nWays then
                            endedAt = "the lane's own road ends here - every way on is another junction's turn"
                            break
                        end
                        turnsAway = verdict
                    end
                end
                for _, nid in pairs(list) do
                    if nid ~= cameFrom and work[nid] ~= nil and not (turnsAway ~= nil and turnsAway[nid]) then
                        local nx = work[nid]
                        local dx, dz = nx.x - node.x, nx.z - node.z
                        local l = math.sqrt(dx * dx + dz * dz)
                        if l > 1e-6 then
                            local dot = (dx / l) * wdx + (dz / l) * wdz
                            if nextId == nil or dot > bestDot + 0.15 or (dot > bestDot - 0.15 and nid < nextId) then
                                bestDot, nextId = math.max(dot, bestDot), nid
                            end
                        end
                    end
                end
                -- Never walk back on ourselves, and never round a sharp corner onto another road.
                if nextId == nil or bestDot < 0.3 then endedAt = "end of track"; break end
                -- A FORK outside the circle: is the side branch this junction's own wiring (an
                -- earlier tie-in or kickout - it reaches the circle) or ANOTHER junction? At another
                -- junction the run ENDS: tying in or kicking out upstream of it would run our wiring
                -- through its crossing - across its conflict points, and into the hands of its
                -- rebuild, which would see our kickout as its own old wiring and delete it.
                if not isOwn(node) then
                    local foreign = false
                    for _, lst in ipairs({ node.out or {}, node.incoming or {} }) do
                        for _, b in pairs(lst) do
                            if b ~= cameFrom and b ~= nextId and work[b] ~= nil and not branchIsOurs(b, node.id) then
                                foreign = true
                            end
                        end
                    end
                    if foreign then endedAt = "another junction"; break end
                end
                local nxt = work[nextId]
                local dx, dz = nxt.x - node.x, nxt.z - node.z
                local l = math.sqrt(dx * dx + dz * dz)
                if l > 1e-6 then
                    wdx, wdz = dx / l, dz / l
                    -- walking an entry goes UPSTREAM, so travel direction is the reverse of the walk
                    if useOut then tbx, tbz = wdx, wdz else tbx, tbz = -wdx, -wdz end
                end
                cameFrom = node.id
                node = nxt
                runPath[#runPath + 1] = node
                run = run + l
                if run >= runReach then break end
            end
            ap.selWp = ap.wp
            ap.wp = node
            ap.runPath = runPath
            ap.chainBearing = math.atan2(tbx, tbz)
            ap.runLength, ap.runEnded = run, endedAt
            local k = ap.dir .. "_" .. node.id
            if byAnchor[k] == nil then
                byAnchor[k] = ap
                merged[#merged + 1] = ap
            else
                byAnchor[k].count = (byAnchor[k].count or 1) + (ap.count or 1)
            end
        end
        approaches = merged
        nIn, nOut = 0, 0
        for _, ap in ipairs(approaches) do
            if ap.dir == "in" then nIn = nIn + 1 else nOut = nOut + 1 end
        end
    end
    -- Downstream code reads `inside` and `R` as "the region the junction lives in": that is now the
    -- work region. The selection circle keeps its own radius for the key, the draw and the card.
    self.junctionWalkApproaches = approaches
    local selectR = R
    inside = work
    R = W

    -- "Already connected" = a directed path from the entry's inside node to the exit's inside node,
    -- staying INSIDE the scope - so a road passing straight through is not re-proposed as a turn onto
    -- itself. Bounded to the (small) inside set, so cheap. Also returns THE path (as node ids, from
    -- entry to exit) - the rebuild option needs to know which nodes carry the old connection.
    local function connectedInside(fromId, toId)
        if fromId == toId then return true, { fromId } end
        -- BREADTH-first (a queue, not a stack): the FIRST path found is then the fewest-hops one.
        -- That matters now that the region is 60 m: the two tracks may also be joined the long way
        -- round - through a neighbouring junction, around a block - and a depth-first search could
        -- return that detour, or return it for a pair this junction does not connect at all.
        local parent = { [fromId] = fromId }
        local queue, head = { fromId }, 1
        while head <= #queue do
            local id = queue[head]
            head = head + 1
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
                        -- A connection THROUGH THIS JUNCTION is about as long as anchor -> locked
                        -- point -> anchor. One much longer than that is a detour via somewhere else:
                        -- not this junction's turn, so the turn is still to be laid.
                        local len = 0
                        for i = 2, #path do
                            local a, b = inside[path[i - 1]], inside[path[i]]
                            if a ~= nil and b ~= nil then
                                len = len + math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
                            end
                        end
                        -- ...and it has to pass through THIS crossing at all (ownership rule).
                        local touches = false
                        for _, pid in ipairs(path) do
                            local pw = inside[pid]
                            if pw ~= nil and isOwn(pw) then touches = true; break end
                        end
                        if not touches then return false, nil end
                        local f, t = inside[fromId], inside[toId]
                        if f ~= nil and t ~= nil then
                            local via = math.sqrt((f.x - cx) ^ 2 + (f.z - cz) ^ 2) + math.sqrt((t.x - cx) ^ 2 + (t.z - cz) ^ 2)
                            if len > via * 1.5 + 20 then return false, nil end
                        end
                        return true, path
                    end
                    if inside[tid] ~= nil and parent[tid] == nil then
                        parent[tid] = id
                        queue[#queue + 1] = tid
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
    -- Clear mode always needs the debris cluster (that IS its job), whatever "existing turns" says.
    local clearMode = (self.junctionMode == "clear")
    local rebuildOn = (self.junctionRebuild == true) or clearMode
    -- Same condition as `logSite` below (declared later, after this runs) - named separately rather
    -- than moved, to touch as little of the tested code above this point as possible.
    local logSite2 = (self.junctionArmed ~= nil)
    -- Skeleton = road nodes; roadLink = the LEGITIMATE links between them (consecutive along an
    -- approach chain, unordered). Rebuild needs both: an old connection between two skeleton nodes
    -- with no interior points (a short direct bridge) has no node to sweep - only the roadLink set
    -- can tell that link apart from the road itself.
    local skeleton, roadLink = {}, {}
    -- A subset of the skeleton: the part of each lane that is unambiguously PARENT ROAD. Kept apart
    -- from the skeleton because the two answer different questions - the skeleton is "is this road
    -- for group detection", which has to reach the crossing, while this is "would clearing this eat
    -- someone's road", which must not.
    local runNode, runNodeOf = {}, {}
    local function linkKey(a, b) return math.min(a, b) .. "_" .. math.max(a, b) end
    -- LANE GROUPS: approaches whose chains share a node are the same physical lane (a through
    -- road's entry and its exit walk the same nodes from opposite ends; a two-way track's four
    -- approaches all do). A turn connector is, by definition, wiring between two DIFFERENT groups -
    -- which is what lets rebuild tell old junction wiring from a siding or a parking bay that hangs
    -- off one lane (see the debris pass below).
    local groupOf, owner = {}, {}
    local function findGroup(i)
        while groupOf[i] ~= i do
            groupOf[i] = groupOf[groupOf[i]]
            i = groupOf[i]
        end
        return i
    end
    -- So: find the crossings in the region (nodes with 3+ distinct neighbours, single-link clustered
    -- at 12 m so one junction's many tie-in forks count once), take the one nearest the lock as the
    -- one being cleared, and assign every node to its nearest crossing. Wiring is cleared only where
    -- the lock's crossing is the nearest one - a Voronoi boundary. A tight pair 20 m apart splits down
    -- the middle; an isolated sprawling junction keeps everything that is closer to it than to
    -- anything else, with no tuning either way.
    local crossings = {}
    do
        -- Scanned at a FIXED reach, deliberately NOT the work region (which is sized from the search
        -- radius). Sizing it from the radius made the tool's answer depend on the circle: at r=20 it
        -- saw 3 crossings, at r=40 it saw 8, so a WIDER search cleared LESS - the extra crossings
        -- carved the locked one's Voronoi cell smaller. Which junctions exist near a point is a fact
        -- about the network, not about how big the user set the circle.
        local CROSSING_SCAN = 70
        local scan2 = CROSSING_SCAN * CROSSING_SCAN
        local cand = {}
        for _, w in pairs(ADGraphManager:getWayPoints()) do
            if w ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= scan2 then
            local nb, deg = {}, 0
            for _, t in ipairs(w.out or {}) do nb[t] = true end
            for _, f in ipairs(w.incoming or {}) do nb[f] = true end
            for _ in pairs(nb) do deg = deg + 1 end
            if deg >= 3 then cand[#cand + 1] = w end
            end
        end
        local used = {}
        for i, w in ipairs(cand) do
            if not used[i] then
                used[i] = true
                local sx, sz, n = w.x, w.z, 1
                local grew = true
                while grew do
                    grew = false
                    for j, v in ipairs(cand) do
                        if not used[j] then
                            local ax, az = sx / n, sz / n
                            if (v.x - ax) ^ 2 + (v.z - az) ^ 2 <= 144 then
                                used[j] = true
                                sx, sz, n = sx + v.x, sz + v.z, n + 1
                                grew = true
                            end
                        end
                    end
                end
                crossings[#crossings + 1] = { x = sx / n, z = sz / n, n = n }
            end
        end
        -- THE CROSSINGS ARE WHERE THE ROADS MEET, where the roads can say. Fork clusters stand in
        -- for junctions badly: one wide junction makes several, and the cluster a kickout makes
        -- 13 m up a side road was taken for the junction next door - its lane was handed to it and
        -- both connectors joining that lane were spared as "that junction's wiring". With the
        -- road-meeting points as the crossings every fork simply goes to the nearest place roads
        -- actually meet, and a junction's far tie forks are its own without any rule saying so.
        -- A fork cluster survives as a crossing only where no meeting point accounts for it - a
        -- shallow merge, which cuts no corner for the roads-first finder to see.
        if AutoDrive.FLYOVER_JUNCTION_ROADS_FIRST ~= false then
            local byRoads = {}
            for _, c in ipairs(self:junctionCentres() or {}) do
                if (c.x - cx) ^ 2 + (c.z - cz) ^ 2 <= scan2 then
                    byRoads[#byRoads + 1] = { x = c.x, z = c.z, n = c.n }
                end
            end
            -- ...and a junction that has already been cleared still owns its road.
            for _, c in ipairs(self:junctionVirginCentres() or {}) do
                if (c.x - cx) ^ 2 + (c.z - cz) ^ 2 <= scan2 then
                    local dup = false
                    for _, b in ipairs(byRoads) do
                        if (b.x - c.x) ^ 2 + (b.z - c.z) ^ 2 <= 12 * 12 then dup = true break end
                    end
                    if not dup then byRoads[#byRoads + 1] = { x = c.x, z = c.z, n = c.n } end
                end
            end
            if #byRoads > 0 then
                for _, old in ipairs(crossings) do
                    local claimed = false
                    for _, c in ipairs(byRoads) do
                        if (c.x - old.x) ^ 2 + (c.z - old.z) ^ 2 <= 25 * 25 then claimed = true break end
                    end
                    if not claimed then byRoads[#byRoads + 1] = old end
                end
                crossings = byRoads
            end
        end
    end
    local lockedCrossing, bestLockD = nil, math.huge
    for _, c in ipairs(crossings) do
        local d = (c.x - cx) ^ 2 + (c.z - cz) ^ 2
        if d < bestLockD then bestLockD, lockedCrossing = d, c end
    end

    local apIndex = {}
    -- Where a lane's road ENDS, for the lanes that end near here: a side road stops at its junction,
    -- a through road runs on out of the region. Used below to tell a second junction from a
    -- fragment of this one.
    local laneTips, laneTipOf = {}, {}
    for ai, ap in ipairs(approaches) do
        groupOf[ai] = ai
        apIndex[ap] = ai
        local ch = self:junctionChain(ap, cx, cz, R)
        -- SKELETON STOPS AT THE CROSSING. The chain itself runs the whole way and stays complete -
        -- build geometry needs it for tie-ins and for finding where two tracks meet. But only the
        -- part from the anchor up to where this lane comes CLOSEST to the locked point is this lane's
        -- ROAD. Past that closest point the walk is on the far side of the crossing, travelling over
        -- whatever wiring carries traffic across it - and marking that as road makes it skeleton,
        -- which makes it permanently unclearable.
        --
        -- That is what kept the T connected through every clear: the tool's own connectors are laid
        -- tangent-continuous, so the walk ran straight through the middle and out the other side.
        -- A surviving route was traced entirely over nodes 1.7-8 m from the lock, every one of them
        -- marked skeleton by this loop. Stopping at the closest approach is exact - no tolerance to
        -- tune, and a lane that merely bends is unaffected because its closest point is still the
        -- point nearest the junction.
        -- MEASURED FROM THE CROSSING, not from the click. This boundary decides how much of a
        -- lane counts as road, and a connector laid tangent-continuous onto that lane sits right
        -- at it - so when it moved with the cursor, so did the amount of connector swallowed as
        -- road. Four clicks within 6 m of each other, all identifying the same crossing, trimmed
        -- 0, 1, 1 and 4 points: one tidied the tail, the next did not. The crossing is a property
        -- of the network, so the answer is now the same wherever inside the junction you click.
        local ax, az = cx, cz
        if lockedCrossing ~= nil then ax, az = lockedCrossing.x, lockedCrossing.z end
        local closest, bestD2 = #ch, math.huge
        for i, n in ipairs(ch) do
            local d2 = (n.x - ax) ^ 2 + (n.z - az) ^ 2
            if d2 < bestD2 then bestD2, closest = d2, i end
        end
        -- A lane that ENDS near here, as opposed to one that comes through and ends somewhere
        -- else. The arm of a 4-way can be the side road of a T 37 m further on: its lane does end,
        -- within reach, at a fork - but it ends THERE, having passed straight through HERE first,
        -- and calling it "a side road of the other junction" disowned every connector this 4-way
        -- has onto it. A lane ends at the junction where it stops getting any closer to this one:
        -- its tip is its nearest point (give or take how far off-centre a crossing can sit).
        do
            local tipN = ch[#ch]
            if tipN ~= nil and #ch >= 2 and (tipN.x - cx) ^ 2 + (tipN.z - cz) ^ 2 <= 35 * 35 then
                local dTip = math.sqrt((tipN.x - ax) ^ 2 + (tipN.z - az) ^ 2)
                if dTip <= math.sqrt(bestD2) + 6 then
                    laneTips[#laneTips + 1] = tipN
                    laneTipOf[ai] = tipN
                end
            end
        end
        -- NOTE: an earlier version also refused to call anything inside the SEARCH CIRCLE road, to
        -- catch the connector "tails" this rule still leaves behind (the walk steps a little way onto
        -- a connector before reaching its closest point, and those nodes survive a clear). That went
        -- badly: with no road inside the circle the junction's whole interior became a single cluster
        -- that no longer touched two distinguishable lanes, the "joins two lane groups" test failed,
        -- and a junction locked dead-centre cleared NOTHING (30 points sitting 1.5 m from the lock,
        -- all rejected as a siding). Group detection needs the lanes to stay road up to the crossing.
        for i = 1, closest do
            local n = ch[i]
            skeleton[n.id] = true
            if owner[n.id] == nil then
                owner[n.id] = ai
            else
                local a, b = findGroup(ai), findGroup(owner[n.id])
                if a ~= b then groupOf[a] = b end
            end
            if i > 1 then roadLink[linkKey(ch[i - 1].id, n.id)] = true end
        end
        -- THE RUN: from the anchor in to the LAST node that forks before the closest approach. A
        -- plain road node has exactly two distinct neighbours; one with three is a tie node, where
        -- something joins the lane. The walk can only have left the road onto a connector AT a fork,
        -- so everything up to the last one is road it stayed on, and only past that can it be tail.
        -- Structural, so there is no distance to tune and nothing that moves with the search radius.
        --
        -- The first fork is the wrong boundary even though it sounds safer: kickouts are laid to
        -- start early and end late deliberately, so their tie nodes sit 16-29 m out, and stopping
        -- there hands the sweep most of the lane again - the very thing this is here to prevent.
        --
        -- The crossing's extent sweep spares these, which is what stops a clear eating a T's stem.
        -- Whatever it does take past the last fork is wiring or tail, and the lane-end tidy trims the
        -- run back to the gap afterwards.
        local runEnd = 1
        for i = 2, closest do
            local n = ch[i]
            local seen, deg = {}, 0
            for _, lst in ipairs({ n.out or {}, n.incoming or {} }) do
                for _, nid in pairs(lst) do
                    if not seen[nid] then seen[nid] = true deg = deg + 1 end
                end
            end
            if deg >= 3 then runEnd = i end
        end
        if runEnd == 1 then runEnd = closest end
        -- By id for the extent sweep, which runs before anything is deleted; by OBJECT for the
        -- lane-end tidy, which runs after - removeWayPoint renumbers every id above the one it
        -- takes, so an id held across a deletion quietly comes to mean a different node.
        for i = 1, runEnd do
            runNode[ch[i].id] = true
            runNodeOf[ch[i]] = true
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
        for ai, ap in ipairs(approaches) do
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
    -- WHAT MUST SURVIVE A CLEAR: the nodes carrying a route that currently runs THROUGH this junction.
    --
    -- This replaces classifying each debris cluster by bearing. That approach kept finding new ways to
    -- be wrong, because it asked an indirect question ("do these two lane groups point the same way?")
    -- whose inputs were unstable - first the choice of representative approach for a merged group
    -- (flapped 13 -> 82 -> 79 deg for one connector across near-identical locks), then the composition
    -- of the clusters themselves, which changes after a clear renumbers ids, so a second pass over the
    -- same junction classified differently and deleted the through road it had just spared.
    --
    -- The property actually wanted is connectivity: do not sever a road that currently runs through
    -- here. So ask that directly. For every entry->exit approach pair whose bearings are within 40 deg
    -- of each other (the same straight-on test the U-turn filter uses from the other end, and measured
    -- per MOVEMENT on the approaches' own bearings - no representative to pick, nothing to go stale),
    -- take the route that currently connects them and protect every node on it. A cluster holding any
    -- protected node is through wiring and is spared whole.
    --
    -- Erring: a cluster that mixes a through route with turn wiring is spared ENTIRELY. That leaves
    -- some turn wiring behind, which is the safe direction to be wrong in - leftover connectors can be
    -- cleared by hand, a severed road cannot be un-severed without rebuilding it.
    local protectedNodes = {}
    local protectedOf = {}   -- the same set by object, for anything that runs after a deletion
    if clearMode then
        -- Traced whichever way the toggle is set, because the routes are also what the PARENT ROADS
        -- are read from (see roadLine below). They are only PROTECTED when they are being kept.
        local keepThrough = self.junctionLeaveThrough ~= false
        local nProtected, nRoutes = 0, 0
        -- WHICH LANES RUN THROUGH, AND OVER WHAT.
        --
        -- First by the lanes themselves: an entry whose own walk - bearing-continuous, never taking
        -- a way on that turns away - arrives at an exit's anchor IS that exit's lane, and the walk
        -- is the route. Nothing is measured, so nothing can be measured in the wrong place.
        --
        -- The bearing test below it is the older rule and only decides lanes the walks could not
        -- pair. On its own it compares the two bearings where the SEARCH CIRCLE cuts each track,
        -- and a road that bends just outside a junction is cut inside its bend: one through lane
        -- read 120 degrees there against its own exit's 56, was refused as a through route, and
        -- was matched instead with the side road's exit at 146 - a right turn, 26 degrees "off
        -- straight". That turn connector then counted as the lane's parent road: its line bent the
        -- side road's claim round the corner, and with through paths kept it was protected.
        local routes, paired = {}, {}
        -- A SIDE ROAD DOES NOT GET THE MAIN ROAD'S EXIT. At a skewed T the side road's turn bends
        -- only 30 degrees, so its walk runs on down the main road and reaches the main exit's
        -- anchor just as the main entry's does. It is refused when the two headings, taken far out
        -- at the anchors, differ by more than 20 degrees AND some other free entry lines up with
        -- that exit better. A main road that itself bends has no such rival and keeps its exit.
        local function sameRoad(e, x)
            local mine = junctionAngDiff(e.chainBearing or e.bearing, x.chainBearing or x.bearing)
            if mine <= math.rad(20) then return true end
            for _, e2 in ipairs(approaches) do
                if e2.dir == "in" and e2 ~= e and not paired[e2]
                    and junctionAngDiff(e2.chainBearing or e2.bearing, x.chainBearing or x.bearing) < mine - math.rad(5) then
                    return false
                end
            end
            return true
        end
        for _, e in ipairs(approaches) do
            if e.dir == "in" then
                local ch = self:junctionChain(e, cx, cz, R)
                for _, x in ipairs(approaches) do
                    if x.dir == "out" and x.wp.id ~= e.wp.id and not paired[x] then
                        for i, n in ipairs(ch) do
                            if n == x.wp and sameRoad(e, x) then
                                local path = {}
                                for k = 1, i do path[k] = ch[k].id end
                                routes[#routes + 1] = { e = e, x = x, path = path, ang = 0 }
                                paired[e], paired[x] = true, true
                                break
                            end
                        end
                    end
                end
            end
        end
        -- The same from the exit's side: its walk runs upstream, so the route is that walk reversed.
        for _, x in ipairs(approaches) do
            if x.dir == "out" and not paired[x] then
                local ch = self:junctionChain(x, cx, cz, R)
                for _, e in ipairs(approaches) do
                    if e.dir == "in" and e.wp.id ~= x.wp.id and not paired[e] and not paired[x] then
                        for i, n in ipairs(ch) do
                            if n == e.wp and sameRoad(e, x) then
                                local path = {}
                                for k = i, 1, -1 do path[#path + 1] = ch[k].id end
                                routes[#routes + 1] = { e = e, x = x, path = path, ang = 0 }
                                paired[e], paired[x] = true, true
                                break
                            end
                        end
                    end
                end
            end
        end
        for _, e in ipairs(approaches) do
            if e.dir == "in" and not paired[e] then
                for _, x in ipairs(approaches) do
                    if x.dir == "out" and x.wp.id ~= e.wp.id and not paired[x]
                        and junctionAngDiff(e.bearing, x.bearing) < math.rad(40) then
                        local connected, path = connectedInside(e.wp.id, x.wp.id)
                        if connected and path ~= nil then
                            routes[#routes + 1] = { e = e, x = x, path = path,
                                ang = junctionAngDiff(e.bearing, x.bearing) }
                        end
                    end
                end
            end
        end
        -- THE SAME-ROAD RULE. A route is a THROUGH route only if it joins the two ends of ONE road,
        -- and a road has two ends: each arm of the junction pairs with at most one other arm. Judging
        -- lane against lane by bearing let one arm be "through" to two others at once - where the main
        -- road bends through a T, the side road lines up with the far arm nearly as well as the main
        -- road does, so a right turn counted as a through path, a T read as a Y, and the turn was
        -- protected with through paths on and the wrong links cut with them off. So the ARMS are
        -- paired first - best continuation first, each arm used once - and a lane route only counts
        -- when its two arms are partners.
        if AutoDrive.FLYOVER_JUNCTION_SAME_ROAD ~= false then
            local arms = {}
            local function outward(ap)
                local b = ap.chainBearing or ap.bearing
                if ap.dir == "in" then b = b + math.pi end
                return b
            end
            local armOf = {}
            for _, ap in ipairs(approaches) do
                local b, hit = outward(ap), nil
                for _, a in ipairs(arms) do
                    if junctionAngDiff(b, a.b) <= math.rad(35) then hit = a break end
                end
                if hit == nil then
                    hit = { b = b, sx = 0, sz = 0 }
                    arms[#arms + 1] = hit
                end
                hit.sx, hit.sz = hit.sx + math.sin(b), hit.sz + math.cos(b)
                hit.b = math.atan2(hit.sx, hit.sz)
                armOf[ap] = hit
            end
            -- PAIRED ON THE LANES' OWN EVIDENCE, NOT ON HOW STRAIGHT THE ARMS LOOK. A main road can
            -- bend 53 degrees through a T while its side road runs nearly dead straight into the far
            -- arm; pairing by straightness there gave the side road the main road's partner and
            -- threw the real through routes away. What says two arms are one road is that lanes RUN
            -- between them - the walks that pair an entry with an exit without ever turning away -
            -- and the more of them, and in both directions, the surer. Straightness only settles a
            -- tie.
            local cand = {}
            for i = 1, #arms do
                for j = i + 1, #arms do
                    local walks, other = 0, 0
                    for _, rt in ipairs(routes) do
                        local ae, ax = armOf[rt.e], armOf[rt.x]
                        if (ae == arms[i] and ax == arms[j]) or (ae == arms[j] and ax == arms[i]) then
                            if (rt.ang or 0) == 0 then walks = walks + 1 else other = other + 1 end
                        end
                    end
                    if walks + other > 0 then
                        cand[#cand + 1] = { a = arms[i], b = arms[j], score = walks * 10 + other,
                            dev = math.abs(math.pi - junctionAngDiff(arms[i].b, arms[j].b)) }
                    end
                end
            end
            table.sort(cand, function(p, q)
                if p.score ~= q.score then return p.score > q.score end
                return p.dev < q.dev
            end)
            for _, c in ipairs(cand) do
                if c.a.partner == nil and c.b.partner == nil then c.a.partner, c.b.partner = c.b, c.a end
            end
            if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                for i, a in ipairs(arms) do
                    Logging.info("[FlyoverEditor]: ARM %d outward %.0f deg, partner %s", i, math.deg(a.b) % 360,
                        a.partner and string.format("%.0f deg", math.deg(a.partner.b) % 360) or "none")
                end
                for _, rt in ipairs(routes) do
                    Logging.info("[FlyoverEditor]: ROUTE in-arm %.0f -> out-arm %.0f", math.deg(armOf[rt.e].b) % 360, math.deg(armOf[rt.x].b) % 360)
                end
            end
            local kept = {}
            for _, rt in ipairs(routes) do
                local ae, ax = armOf[rt.e], armOf[rt.x]
                if ae ~= nil and ax ~= nil and ae ~= ax and ae.partner == ax then kept[#kept + 1] = rt end
            end
            routes = kept
        end
        self._jxRoutes = routes
        for _, rt in ipairs(routes) do
            local e, x, path, ang = rt.e, rt.x, rt.path, rt.ang
            -- The straightest route each lane takes part in is that lane's road.
            if e.throughAng == nil or ang < e.throughAng then e.throughAng, e.throughPath = ang, path end
            if x.throughAng == nil or ang < x.throughAng then x.throughAng, x.throughPath = ang, path end
            if keepThrough then
                nRoutes = nRoutes + 1
                for _, pid in ipairs(path) do
                    if not protectedNodes[pid] then
                        protectedNodes[pid] = true
                        local pw = inside[pid] or ADGraphManager:getWayPointById(pid)
                        if pw ~= nil then protectedOf[pw] = true end
                        nProtected = nProtected + 1
                    end
                end
            end
        end
        if logSite2 and keepThrough then
            roadNote(string.format("clearProtect:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
                "junction clear - %d through route(s) run through this site; %d point(s) on them are protected from clearing.",
                nRoutes, nProtected)
        end
        -- THE PARENT ROAD, AS IT ACTUALLY RUNS. A road that goes through the junction is real
        -- geometry right across it, so its line is simply its own through route - positions copied
        -- now, before the clear removes any of it. Nothing is extrapolated: carrying a road across a
        -- junction on a fitted arc put the box in the wrong place wherever the road bends near the
        -- middle, and reading it off the lane's tip picked up old tie-in kinks instead. Only a road
        -- that ENDS here - a T's stem - has no through route, and the tidy carries that one across.
        for _, ap in ipairs(approaches) do
            ap.roadLine = nil
            if ap.throughPath ~= nil then
                local line = {}
                for _, pid in ipairs(ap.throughPath) do
                    local pw = inside[pid] or ADGraphManager:getWayPointById(pid)
                    if pw ~= nil and (pw.x - cx) ^ 2 + (pw.z - cz) ^ 2 <= 60 * 60 then
                        line[#line + 1] = { x = pw.x, z = pw.z }
                    end
                end
                if #line >= 3 then ap.roadLine = line end
            end
            ap.throughAng, ap.throughPath = nil, nil
        end
    end
    -- OWNERSHIP FOR CLEARING is wider than `isOwn` (search circle + 5 m). The tool lays wiring for one
    -- junction out to runReach - a tie-in at ~1.5 turn radii plus a kickout's late tail - which is
    -- routinely 35-40 m from the middle, far outside a 15 m scope circle. Judging that wiring by the
    -- circle meant the tool built connectors it then refused to recognise as its own, and they survived
    -- every clear ("5 point(s) ... nearest 25.1 m ... no node inside the search circle + tolerance").
    -- The tight `isOwn` stays in use for run-following, where it is what stops a run walking into the
    -- junction next door.
    -- OWNERSHIP FOR CLEARING, by NEAREST CROSSING rather than by any radius.
    --
    -- A radius cannot answer "which junction does this wiring belong to". Tried at the lay reach
    -- (45 m) it destroyed the junction 20 m away; tried at the search circle it destroyed it AND broke
    -- group detection; tried at 12 m it was safe but cleared only a fifth of a junction locked dead
    -- centre. Same knob, three wrong answers, because the right question is not "how far" but "closer
    -- to WHICH crossing".
    --
    -- Fallback only if the region somehow holds no crossing at all: the old core radius.
    -- With no wheel, this is no longer the user dialling a clear down: ownership (nearest crossing,
    -- and whose side road the wiring joins) is what keeps a clear off its neighbour, and this only
    -- decides how far out the junction's OWN wiring is followed. Held back to the wheel's old value
    -- it left tails behind that then read as loose points once the box was emptied.
    local clearReach = math.max(12, selectR)
    -- WHERE THE JUNCTION WAS FOUND FROM ITS ROADS, OWNERSHIP IS THE WHOLE TEST. This radius was the
    -- last distance gate on a junction's OWN wiring: a kickout that leaves the through lane 14 m
    -- back belonged to the junction, lay within reach, and was refused for starting 2 m outside a
    -- 12 m circle - with a message telling the user to turn a wheel that clear mode ignores. Whose
    -- wiring it is now comes from where the roads meet, and what may be deleted is bounded arm by
    -- arm at the gate, so the circle has nothing left to decide.
    if clearMode and self.junctionSite ~= nil and self.junctionSite.fromRoads then
        clearReach = math.max(clearReach, runReach)
    end
    local coreR = math.max(8, selectR * 0.6)
    local function crossingOf(wp)
        local best, bestC = math.huge, nil
        for _, c in ipairs(crossings) do
            local d = (wp.x - c.x) ^ 2 + (wp.z - c.z) ^ 2
            if d < best then best, bestC = d, c end
        end
        return bestC
    end
    -- A FRAGMENT OF THIS JUNCTION IS NOT ANOTHER JUNCTION.
    --
    -- Crossings are clusters of fork nodes, and a junction this tool built has forks all over it:
    -- tie nodes 5 m out on the side road, 15 m out on the main road, 25 m out where a kickout ends.
    -- The clustering is deliberately tight so that two junctions 18 m apart stay two - and the
    -- price was that ONE junction regularly came back as two or three. Everything nearer the
    -- "other" crossing was then left to it: at one T the two connectors on its west side were
    -- refused as "nearer another crossing" - which was that junction's own pair of tie nodes 13 m
    -- from its other four.
    --
    -- What makes a crossing a junction in its own right is a road of its own: wiring that joins
    -- these lanes AND runs on out of the region along something that is not one of them. A crossing
    -- whose wiring is all CLOSED - every cluster attached to it begins and ends on this junction's
    -- own lanes - has no such road. It is part of this junction, however far its forks sit from
    -- the rest. (A driveway or a siding beside it does not count against it: that touches one lane
    -- only, is never cleared whoever owns it, and needs no protecting.)
    --
    -- One more thing makes a junction: a road that ENDS at it. Two T's 18 m apart on the same main
    -- road can both fall inside the search circle, and then the neighbour's side road is one of
    -- these lanes too and all its wiring reads as closed. But its side road ends THERE and this
    -- junction's ends HERE, and one junction does not have side roads ending in two places - so
    -- where both crossings have lanes ending at them, they stay two.
    if clearMode and lockedCrossing ~= nil and #crossings > 1 then
        local attached = {}
        local function note(c, open2)
            if c == nil then return end
            local a = attached[c]
            if a == nil then a = { closed = 0, open = 0 } attached[c] = a end
            if open2 then a.open = a.open + 1 else a.closed = a.closed + 1 end
        end
        local reach2 = runReach * runReach
        local seenF = {}
        for id in pairs(skeleton) do
            local w = inside[id] or ADGraphManager:getWayPointById(id)
            if w ~= nil then
                for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                    for _, startId in pairs(lst) do
                        if not skeleton[startId] and not seenF[startId] and inside[startId] ~= nil then
                            local open, count = false, 0
                            local touched, groups, nGroups = {}, {}, 0
                            local stack = { startId }
                            seenF[startId] = true
                            while #stack > 0 do
                                local cid = table.remove(stack)
                                local cw = inside[cid]
                                count = count + 1
                                if count > 400 then open = true end
                                touched[crossingOf(cw) or false] = true
                                for _, clst in ipairs({ cw.out or {}, cw.incoming or {} }) do
                                    for _, x in pairs(clst) do
                                        if skeleton[x] then
                                            local sw = inside[x] or ADGraphManager:getWayPointById(x)
                                            if sw ~= nil then touched[crossingOf(sw) or false] = true end
                                            local g = owner[x] and findGroup(owner[x]) or nil
                                            if g ~= nil and not groups[g] then groups[g] = true nGroups = nGroups + 1 end
                                        elseif inside[x] == nil then
                                            open = true
                                        elseif (inside[x].x - cx) ^ 2 + (inside[x].z - cz) ^ 2 > reach2 then
                                            open = true
                                        elseif not seenF[x] then
                                            seenF[x] = true
                                            stack[#stack + 1] = x
                                        end
                                    end
                                end
                            end
                            -- Only wiring that joins two of these lanes says anything about whose
                            -- junction this is; a spur off one lane is nobody's.
                            if nGroups >= 2 then
                                for c in pairs(touched) do
                                    if c ~= false then note(c, open) end
                                end
                            end
                        end
                    end
                end
            end
        end
        local endsAt = {}
        for _, t in ipairs(laneTips) do
            local c = crossingOf(t)
            if c ~= nil then endsAt[c] = true end
        end
        local nMerged = 0
        for _, c in ipairs(crossings) do
            local a = attached[c]
            if c ~= lockedCrossing and a ~= nil and a.open == 0 and a.closed > 0
                and not (endsAt[c] and endsAt[lockedCrossing]) then
                c.partOfLocked = true
                nMerged = nMerged + 1
            end
        end
        if nMerged > 0 then
            -- The junction's middle is the middle of ALL its forks, not of whichever handful the
            -- clustering happened to start from.
            local sx, sz, n = lockedCrossing.x * lockedCrossing.n, lockedCrossing.z * lockedCrossing.n, lockedCrossing.n
            for _, c in ipairs(crossings) do
                if c.partOfLocked then sx, sz, n = sx + c.x * c.n, sz + c.z * c.n, n + c.n end
            end
            lockedCrossing.mergedX, lockedCrossing.mergedZ = sx / n, sz / n
            if logSite2 then
                roadNote(string.format("clearMerged:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
                    "junction clear - %d of the other crossing(s) are this junction's own tie nodes (all their wiring begins and ends on these lanes) and are cleared with it; its middle is %.1f, %.1f.",
                    nMerged, lockedCrossing.mergedX, lockedCrossing.mergedZ)
            end
        end
    end
    local function isOwnForClear(wp)
        if lockedCrossing == nil then
            return (wp.x - cx) ^ 2 + (wp.z - cz) ^ 2 <= coreR * coreR
        end
        local bestC = crossingOf(wp)
        return bestC == lockedCrossing or (bestC ~= nil and bestC.partOfLocked == true)
    end
    -- WHOSE SIDE ROAD IS IT. A lane that ends near here ends AT a junction, and wiring that joins
    -- that lane to anything is that junction's wiring - all of it, wherever its points happen to
    -- lie. Nearest-crossing alone split such a connector down the middle: a neighbour's wide left
    -- turn, tailing off past the halfway mark between two T's 18 m apart, lost its far end to
    -- whichever of the two was cleared first, and the neighbour lost the movement.
    local groupTip = {}
    if lockedCrossing ~= nil then
        for ai, tipN in pairs(laneTipOf) do
            local c = crossingOf(tipN)
            if c ~= nil then
                groupTip[findGroup(ai)] = (c == lockedCrossing or c.partOfLocked == true) and "ours" or "theirs"
            end
        end
    end
    -- Another junction's wiring, by object: nothing later in this clear may take it either.
    local foreignWiring = {}
    if logSite2 and clearMode then
        roadNote(string.format("clearVoronoi:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
            "junction clear - %d crossing(s) in the region; clearing the one at %.1f, %.1f (wiring nearer another crossing is left to it).",
            #crossings, lockedCrossing and lockedCrossing.x or cx, lockedCrossing and lockedCrossing.z or cz)
    end
    -- The flood stops at the SAME lay reach. Set wider than this (it was runReach + R) it never binds
    -- before the work-region edge, so a cluster that runs off down an unselected road to the next
    -- junction still 'leaks' and is discarded whole - taking with it the part sitting on this crossing
    -- (measured: 28-node cluster, 18 of them within reach, nearest 19.6 m, all left behind). Stopping
    -- at the reach makes that near part its own cluster, which then qualifies and clears.
    -- Flood boundary: stops a runaway walk down a road, nothing more. Ownership is decided by
    -- nearest crossing (isOwnForClear), not by this.
    local reachR2 = runReach * runReach
    local debris, staleLinks = {}, {}
    -- Split of `debris` by clear mode's through/turn test (see below); declared here so it survives
    -- past the `if rebuildOn` block that fills it.
    local turnDebris, throughDebris = {}, {}
    if rebuildOn then
        -- STRUCTURAL, not a radius flood. The work region is a fixed 60 m - big enough to hold a
        -- neighbouring junction, a siding, a yard entrance - so "everything off the road skeleton
        -- within reach" (the old rule, at 1.3x the search circle) would now eat all of those. Old
        -- junction wiring is instead recognised by what it IS: a connected cluster of off-skeleton
        -- nodes that
        --   * touches road nodes of at least TWO different lane groups (it joins one lane to another
        --     - a siding or a bay hangs off a single lane and is left alone), and
        --   * never LEAKS - no node of it links to anything outside the work region, and it is not
        --     so large that it is plainly a road network rather than a handful of connectors
        --     (a neighbouring junction's connector runs on into that junction's other roads, which
        --     carry on out of the region, so its cluster leaks and is left alone).
        -- Direct road-to-road bridges with no interior node are collected as stale links the same
        -- way: only between nodes of two DIFFERENT groups, never along one lane.
        -- THROUGH vs TURN is decided by CONNECTIVITY, not geometry: a cluster is through wiring iff it
        -- carries part of a route that currently runs through this junction (protectedNodes, computed
        -- above). `debris`/`staleLinks` stay the full set (every existing rebuild caller is
        -- unaffected); `turnDebris`/`throughDebris` split it for clear mode alone.
        local seen, staleSeen = {}, {}
        for id in pairs(skeleton) do
            local w = inside[id] or ADGraphManager:getWayPointById(id)
            if w ~= nil then
                local gHere = owner[id] and findGroup(owner[id]) or nil
                for _, nid in pairs(w.out or {}) do
                    if skeleton[nid] and not roadLink[linkKey(id, nid)] and not staleSeen[linkKey(id, nid)] then
                        local gThere = owner[nid] and findGroup(owner[nid]) or nil
                        local o0 = ADGraphManager:getWayPointById(nid)
                        if gHere ~= nil and gThere ~= nil and gHere ~= gThere
                            and (isOwnForClear(w) or (o0 ~= nil and isOwnForClear(o0))) then
                            staleSeen[linkKey(id, nid)] = true
                            local o = ADGraphManager:getWayPointById(nid)
                            if o ~= nil then
                                -- THROUGH = the two approach bearings point the SAME way (both
                                -- "heading west" through a T, say), not opposite - travel direction
                                -- is recorded at both ends (entry: direction INTO the circle; exit:
                                -- direction OUT of it), so a road running straight across shows near-
                                -- identical bearings at its two ends, and a genuine turn a large one.
                                -- A direct bridge both of whose ends carry a protected through route is
                                -- part of that route: severing it is exactly what must not happen.
                                local isThrough = protectedNodes[id] == true and protectedNodes[nid] == true
                                staleLinks[#staleLinks + 1] = { w, o, isThrough = isThrough }
                            end
                        end
                    end
                end
                for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                    for _, startId in pairs(lst) do
                        if not skeleton[startId] and not seen[startId] and inside[startId] ~= nil then
                            -- Flood this off-skeleton cluster.
                            local cluster, groups, groupRepAi, groupTouchNode, nGroups, leaks, ours = {}, {}, {}, {}, 0, false, false
                            local nearest = math.huge   -- squared until the flood finishes
                            local ranOn = false         -- the flood was stopped at the lay reach: this is not a closed piece of wiring
                            local stack = { startId }
                            seen[startId] = true
                            while #stack > 0 do
                                local cid = table.remove(stack)
                                local cw = inside[cid]
                                cluster[#cluster + 1] = cw
                                local d2 = (cw.x - cx) ^ 2 + (cw.z - cz) ^ 2
                                if d2 < nearest then nearest = d2 end
                                if #cluster > 400 then leaks = true end
                                if isOwnForClear(cw) then ours = true end
                                for _, clst in ipairs({ cw.out or {}, cw.incoming or {} }) do
                                    for _, x in pairs(clst) do
                                        if skeleton[x] then
                                            local g = owner[x] and findGroup(owner[x]) or nil
                                            if g ~= nil and not groups[g] then
                                                groups[g] = true
                                                groupRepAi[g] = owner[x]
                                                groupTouchNode[g] = x
                                                nGroups = nGroups + 1
                                            end
                                        elseif inside[x] == nil then
                                            leaks = true
                                        elseif (inside[x].x - cx) ^ 2 + (inside[x].z - cz) ^ 2 > reachR2 then
                                            ranOn = true
                                            -- BOUNDARY, not a leak. This tool never lays wiring for one
                                            -- junction further out than runReach (tie-in distance plus a
                                            -- kickout's tail), so anything past that is not ours and the
                                            -- flood simply stops - it does not condemn the whole cluster.
                                            -- Rejecting wholesale is what left connectors behind: an
                                            -- unselected road leaving the site is not skeleton, so the
                                            -- flood walked down it to the NEXT junction, and the 28-node
                                            -- cluster that produced was thrown away along with the four
                                            -- of its nodes that were sitting on this crossing.
                                        elseif not seen[x] then
                                            seen[x] = true
                                            stack[#stack + 1] = x
                                        end
                                    end
                                end
                            end
                            -- OURS: some node of the cluster lies in the search circle (+ tolerance). Wiring
                            -- between two of these runs further up the road - where tracks diverge and
                            -- reconverge, or at the junction next door - never enters the circle and is
                            -- not this rebuild's to clear. A cluster that IS ours goes whole, kickout
                            -- tails beyond the circle included.
                            -- THE SEARCH RADIUS NOW BOUNDS THE CLEAR, not just the selection. It used
                            -- to pick which tracks counted as approaches and nothing more: ownership
                            -- then decided what to take across the whole 60 m work region, so a wheel
                            -- set to 10 still cleared wiring 25 m out and turning it down changed
                            -- nothing. A cluster has to REACH the lock to be this site's to clear.
                            nearest = (nearest < math.huge) and math.sqrt(nearest) or -1
                            -- By its ARMS first: wiring onto a side road belongs to the junction that
                            -- side road ends at. Only wiring between lanes that all run THROUGH is left
                            -- to be shared out by nearest crossing.
                            local armOurs, armTheirs = false, false
                            for g in pairs(groups) do
                                if groupTip[g] == "ours" then armOurs = true
                                elseif groupTip[g] == "theirs" then armTheirs = true end
                            end
                            -- ONLY A CLOSED CLUSTER IS TAKEN WHOLE. "Whole" means every node goes however
                            -- far from this crossing it lies, and that is only safe for something that
                            -- begins and ends on these lanes - a connector. A cluster the flood had to be
                            -- STOPPED in is running on down a road: where a lane's run ends at the next
                            -- junction, the lane beyond that point is nobody's chain, and this junction's
                            -- kickout tail, that stretch of lane, the neighbour's connectors and the
                            -- neighbour's side road all flood together into one cluster. Taken whole, a
                            -- T's clear deleted 15 points of the road and junction 25-34 m up from it.
                            -- Shared out node by node instead, each junction keeps what is nearest it.
                            local whole = false
                            if armTheirs and not armOurs then
                                ours = false
                                for _, cw in ipairs(cluster) do foreignWiring[cw] = true end
                            elseif armOurs and not armTheirs and not ranOn and not leaks then
                                ours, whole = true, true
                            end
                            if logSite2 and not (not leaks and ours and nGroups >= 2 and nearest <= clearReach) then
                                -- A cluster that DID NOT qualify: log why, once per cluster (keyed by its
                                -- first node, which is stable across re-locks at the same spot). This is
                                -- what a "some connections aren't clearing" report needs - the accepted
                                -- ones are visible as red spheres already, the REJECTED ones are not
                                -- visible at all otherwise.
                                local mx, mz, mcount = 0, 0, 0
                                -- Also: how many of this cluster's nodes are INSIDE the circle, and how
                                -- close the nearest one gets. The average position alone is misleading -
                                -- a cluster stretching from THIS junction out to a neighbour averages to
                                -- somewhere in between and reads as "far away", while its near end is
                                -- sitting right on the crossing the user is trying to clear.
                                local nInside = 0
                                for _, cw in ipairs(cluster) do
                                    mx, mz, mcount = mx + cw.x, mz + cw.z, mcount + 1
                                    if isOwnForClear(cw) then nInside = nInside + 1 end
                                end
                                if mcount > 0 then mx, mz = mx / mcount, mz / mcount end
                                local why
                                if leaks then why = "leaks outside the work region (too large, or wired to something the circle did not select)"
                                elseif armTheirs and not armOurs then why = "it joins a side road that ends at another junction - that junction's wiring; lock onto that one instead"
                                elseif not ours then why = "every node of it is nearer another crossing - it belongs to that junction; lock onto that one instead"
                                elseif nGroups < 2 then why = string.format("touches only %d lane group - looks like a siding or a dead stub, not turn wiring", nGroups)
                                elseif nearest > clearReach then why = string.format("nearest point is %.0f m from the lock, outside the %.0f m search radius - turn the wheel up to take it", nearest, clearReach)
                                else why = "rejected" end
                                roadNote(string.format("clearReject:%d", cluster[1] and cluster[1].id or 0),
                                    "junction clear - %d point(s) near %.1f, %.1f (%d of them within lay reach, nearest %.1f m) NOT cleared: %s.",
                                    #cluster, mx, mz, nInside, nearest, why)
                            end
                            if not leaks and ours and nGroups >= 2 and nearest <= clearReach then
                                -- Protection is PER NODE, not per cluster. Sparing a whole cluster the
                                -- moment any part of it carried a through route was too coarse: once
                                -- the junction's interior is treated as one region (skeleton stops at
                                -- the search circle), its turn wiring and its through wiring are
                                -- frequently the SAME connected cluster, and sparing all of it cleared
                                -- almost nothing. Sparing exactly the nodes that carry a through route
                                -- leaves those routes whole and takes the rest.
                                local nProt = 0
                                for _, cw in ipairs(cluster) do
                                    if protectedNodes[cw.id] then nProt = nProt + 1 end
                                end
                                local diagWhy = string.format("%d group(s), %d of its %d point(s) carry a through route (spared individually)",
                                    nGroups, nProt, #cluster)
                                if logSite2 then
                                    local mx, mz, mcount = 0, 0, 0
                                    for _, cw in ipairs(cluster) do mx, mz, mcount = mx + cw.x, mz + cw.z, mcount + 1 end
                                    if mcount > 0 then mx, mz = mx / mcount, mz / mcount end
                                    roadNote(string.format("clearAccept:%.0f:%.0f", mx, mz),
                                        "junction clear - %d point(s) near %.1f, %.1f: %s -> %d cleared, %d spared.",
                                        #cluster, mx, mz, diagWhy, #cluster - nProt, nProt)
                                end
                                -- Node level: spare what carries a through route, spare what belongs to
                                -- another crossing, clear the rest. A cluster straddling two junctions
                                -- is therefore split between them instead of going wholly to whichever
                                -- was locked first.
                                --
                                -- OWNERSHIP IS NOT NEGOTIABLE. A node nearer another crossing belongs
                                -- to that junction and is never cleared from here, whatever "leave
                                -- through paths" is set to - so it goes in NEITHER list. It used to be
                                -- put in debris and merely kept out of turnDebris, which meant turning
                                -- that toggle off (debris, not turnDebris) deleted the neighbour's
                                -- wiring: the "we killed another junction" failure, back through a
                                -- different door. The toggle governs through ROUTES, not ownership.
                                for _, cw in ipairs(cluster) do
                                    if whole or isOwnForClear(cw) then
                                        debris[#debris + 1] = cw
                                        if protectedNodes[cw.id] then
                                            throughDebris[#throughDebris + 1] = cw
                                        else
                                            turnDebris[#turnDebris + 1] = cw
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- THE THROUGH ROUTE'S OWN LINKS, for "leave through paths" to cut.
    --
    -- Turning that toggle off means no route should survive ACROSS this junction. It used to mean
    -- "delete every node on those routes", which is far more: where two junctions sit close
    -- together the route between them IS the road joining them, so clearing one took out the road
    -- to its neighbour - 5 of the 19 points on it, at a pair 18 m apart.
    --
    -- Cutting the links leaves every node where it is and simply stops traffic crossing. The
    -- lane-end tidy then trims the ends back to the box, so what is left reads as a clean gap
    -- rather than a severed road.
    local throughLinks = {}
    if clearMode and lockedCrossing ~= nil then
        local extent2 = math.max(12, turnR * 1.5) ^ 2
        local seenLink = {}
        for id in pairs(protectedNodes) do
            local w = inside[id] or ADGraphManager:getWayPointById(id)
            if w ~= nil then
                for _, nid in pairs(w.out or {}) do
                    if protectedNodes[nid] and not seenLink[id .. ":" .. nid] then
                        local o = inside[nid] or ADGraphManager:getWayPointById(nid)
                        if o ~= nil then
                            local dw = (w.x - lockedCrossing.x) ^ 2 + (w.z - lockedCrossing.z) ^ 2
                            local doo = (o.x - lockedCrossing.x) ^ 2 + (o.z - lockedCrossing.z) ^ 2
                            if dw <= extent2 or doo <= extent2 then
                                seenLink[id .. ":" .. nid] = true
                                throughLinks[#throughLinks + 1] = { w, o }
                            end
                        end
                    end
                end
            end
        end
    end

    -- THE CROSSING'S OWN WIRING, whatever it is labelled. The cluster pass can only offer up nodes
    -- the lane chains did not already claim as road - and at a junction the chains walk right up to
    -- the crossing, so most of its wiring is claimed and only a handful ever reach the debris set
    -- (measured: 6, at a junction holding ~30 nodes of wiring). Clearing therefore also takes every
    -- node in the LOCKED crossing's Voronoi cell, within the crossing's own extent, that is not
    -- carrying a route through the junction AND IS NOT ON A RUN.
    --
    -- That last condition is what keeps the parent roads. This sweep is a distance rule, and a
    -- distance rule cannot tell a T's stem from a connector: the stem is on no through route (it only
    -- ever connects by turning), so without the run test its road was eaten out to the full extent -
    -- 16 to 29 m of it, measured. Note it is the RUN that is spared and not the whole skeleton:
    -- skeleton reaches past the fork and onto the connector tails, which are exactly what this sweep
    -- is here to take. Sparing all of it leaves turns joined.
    if clearMode and lockedCrossing ~= nil then
        -- BOUNDED BY THE WHEEL AS WELL AS THE TURN RADIUS. Ownership is meant to stop this sweep
        -- at a neighbour, but clearing a junction DESTROYS the degree-3 nodes it was detected by,
        -- so its neighbour can no longer see it and the next clear owns everything up to and past
        -- it. The search radius is the one reach the user controls, so it bounds this too.
        local extentR2 = math.min(math.max(12, turnR * 1.5), clearReach) ^ 2
        local already = {}
        for _, w in ipairs(turnDebris) do already[w.id] = true end
        for _, w in ipairs(throughDebris) do already[w.id] = true end
        local extra = 0
        for _, w in pairs(work) do
            if not already[w.id] and not protectedNodes[w.id] and not runNode[w.id]
                and not foreignWiring[w]
                and (w.x - lockedCrossing.x) ^ 2 + (w.z - lockedCrossing.z) ^ 2 <= extentR2
                and isOwnForClear(w) then
                turnDebris[#turnDebris + 1] = w
                debris[#debris + 1] = w
                extra = extra + 1
            end
        end
        if logSite2 and extra > 0 then
            roadNote(string.format("clearExtent:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
                "junction clear - %d further point(s) inside the crossing's own extent (%.0f m) and not on a through route.",
                extra, math.sqrt(extentR2))
        end
    end

    -- Movement matrix: each entry -> each exit, dropping U-turns, tagged new vs already connected.
    -- nNew counts only movements that got a BUILDABLE connector - what actually places - so it never
    -- silently disagrees with what right-click lays. Every candidate that drops out gets its own
    -- bucket and, once the site is locked, its own log line with the angle, so nothing goes missing
    -- without a visible reason (see docs/junction-plan.md s5, "failing is a valid result").
    local movements = {}
    local nNew, nExisting, nTight, nOffRoad, nNoCurve, nUTurn, nFar, nRebuild, nBlocked = 0, 0, 0, 0, 0, 0, 0, 0, 0
    local nTrailerRoad, nTrailerHit = 0, 0
    local usedMin, usedMax = nil, nil
    -- The design rig for the swept-path gate: only on a LOCKED site with the toggle on (a simulation
    -- per candidate radius per turn is too much for the scouting preview that re-solves on every
    -- half-metre of cursor travel). Unlocked, the solve is the line-only one as before.
    local sweptRig = nil
    if self.junctionSwept ~= false and self.junctionArmed ~= nil and SweptSim ~= nil then
        sweptRig = (ADFlyoverSweptPath ~= nil and ADFlyoverSweptPath.rig) or SweptSim.EXAMPLE_RIG
    end
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
                        -- Entry and exit on the SAME lane (their chains share nodes - one lane group)
                        -- is that lane running through: a through movement, there by definition,
                        -- however the path search judged it (a lane that doubles back inside the
                        -- region reads as a "detour"). Without this the solver is asked to join a
                        -- lane to itself and refuses it as "neither curve engine fit (delta 0)".
                        if not exists and apIndex[e] ~= nil and apIndex[x] ~= nil
                            and findGroup(apIndex[e]) == findGroup(apIndex[x]) then
                            exists, path = true, nil
                        end
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
                            -- Clear mode never builds anything - the (expensive, per-radius-candidate,
                            -- swept-simulated) solve would be pure waste on a preview that re-runs on
                            -- every half-metre of cursor travel. debris/staleLinks (clear mode's actual
                            -- output) were already computed above, independent of this loop.
                            if not clearMode then
                                con, usedR, refused = self:junctionSolveMovement(e, x, cx, cz, R, turnR, sweptRig)
                            end
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
                            if logSite then
                                roadNote(string.format("tight:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d tighter than the turn radius (or the rig's full lock) at every radius down to the floor - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "offroad" then
                            nOffRoad = nOffRoad + 1
                            if logSite then
                                roadNote(string.format("offroad:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d leaves the road surface at every radius down to the floor - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "blocked" then
                            nBlocked = nBlocked + 1
                            if logSite then
                                roadNote(string.format("blocked:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d blocked by a static obstacle at every radius down to the floor - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "trailerRoad" then
                            nTrailerRoad = nTrailerRoad + 1
                            if logSite then
                                roadNote(string.format("trailerRoad:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d: the design rig's body leaves the road at every radius (swept-path gate) - refused.",
                                    e.wp.id, x.wp.id)
                            end
                        elseif refused == "trailerHit" then
                            nTrailerHit = nTrailerHit + 1
                            if logSite then
                                roadNote(string.format("trailerHit:%d_%d", e.wp.id, x.wp.id),
                                    "junction - entry id=%d -> exit id=%d: the design rig's body sweeps through a static obstacle at every radius (swept-path gate) - refused.",
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
            -- Logged with where the RUN was followed to and why it stopped: a run cut short by another
            -- junction is the usual reason a kickout comes out shortened or a turn steps its radius down.
            roadNote(string.format("approach:%d:%s:%d", ap.wp.id, ap.dir, math.floor(ap.runLength or 0)),
                "junction - %s track cut by the circle at id=%d (bearing %.0f deg), run followed %.0f m outward to id=%d%s.",
                (ap.dir == "in") and "entry" or "exit", (ap.selWp or ap.wp).id, math.deg(ap.bearing),
                ap.runLength or 0, ap.wp.id,
                ap.runEnded and (" - stopped at " .. ap.runEnded) or "")
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

    -- Swept-path prediction (docs/swept-path-spec.md §5-6, phase 5 step 1: VISUALISE). On a locked
    -- site only - it is a per-turn simulation and the scouting preview already re-solves on every
    -- half-metre of cursor travel - drive the design rig along each placeable connector with the
    -- stock-driver model and keep the predicted tow and trailer tracks for the preview to draw, plus
    -- the trailer's worst inside cut-in for the card. No gate yet: this is the step where the model's
    -- claims are made visible before anything is allowed to refuse on them.
    local sweptMax, nSweptWide = nil, 0
    local nSweep, sweepMax = 0, nil
    if self.junctionSwept ~= false and self.junctionArmed ~= nil and SweptSim ~= nil then
        local rig = (ADFlyoverSweptPath ~= nil and ADFlyoverSweptPath.rig) or SweptSim.EXAMPLE_RIG
        local halfCorr = (self.junctionCorridor or AutoDrive.FLYOVER_JUNCTION_CORRIDOR or 4.0) / 2
        for _, m in ipairs(movements) do
            -- Refused turns too: their red connector is exactly where seeing the predicted bodies
            -- explains the refusal. The solve already ran the prediction on the connector it kept.
            if m.connector ~= nil and (not m.exists or m.rebuild) then
                local ok, sw = true, m.connector.swept
                if sw == nil then
                    ok, sw = pcall(function() return self:junctionSweptPredict(m.from, m.to, m.connector, cx, cz, R, rig) end)
                end
                if ok and sw ~= nil then
                    m.swept = sw
                    -- Inside trailer EDGE beyond the corridor half-width = the turn the trailer clips.
                    local edge = sw.trailerIn + (rig.trailerWidth or 2.5) / 2
                    sw.wide = edge > halfCorr
                    if sw.wide then nSweptWide = nSweptWide + 1 end
                    sweptMax = math.max(sweptMax or 0, sw.trailerIn)
                    if m.connector.sweep ~= nil and m.refused == nil then
                        nSweep = nSweep + 1
                        sweepMax = math.max(sweepMax or 0, m.connector.sweep)
                        if m.connector.kickEarly ~= nil then
                            Logging.info("[FlyoverEditor]: swept - entry id=%d -> exit id=%d laid with a %.1f m KICKOUT (starts %.0f m before the curve, returns %.0f m after it) so the rig stays on the road / clear.",
                                m.from.wp.id, m.to.wp.id, m.connector.sweep, m.connector.kickEarly, m.connector.kickLate)
                        else
                            Logging.info("[FlyoverEditor]: swept - entry id=%d -> exit id=%d laid %.1f m WIDE inside the curve (no room for a kickout) so the rig stays on the road / clear.",
                                m.from.wp.id, m.to.wp.id, m.connector.sweep)
                        end
                    end
                    Logging.info("[FlyoverEditor]: swept - entry id=%d -> exit id=%d (%s turn): tow cuts %.2f m inside, trailer axle %.2f m inside / %.2f m outside the connector; inside edge %.2f m vs corridor half-width %.1f m -> %s (rig: %s).",
                        m.from.wp.id, m.to.wp.id, sw.leftTurn and "left" or "right", sw.towIn, sw.trailerIn,
                        sw.trailerOut, edge, halfCorr, sw.wide and "PAST CORRIDOR" or "fits", rig.name or "?")
                elseif ok and sw == nil then
                    Logging.info("[FlyoverEditor]: swept - entry id=%d -> exit id=%d: no prediction (geometry unusable for a run-in/run-out).",
                        m.from.wp.id, m.to.wp.id)
                elseif not ok then
                    roadNote("sweptErr", "swept-path prediction failed: %s", tostring(sw))
                end
            end
        end
    end

    -- The LANE GROUP each approach ended up in, now the union-find has settled. Two tracks the clear
    -- decided are the same road - the two directions of a carriageway, most often - share a group.
    -- The lane-end tidy groups tracks into roads by this rather than by guessing from headings: a
    -- geometric test could not tell a shallow-angle crossing from a parallel neighbour, and got both
    -- wrong at once, while this is the tool's own answer to the same question, already computed.
    for ai, ap in ipairs(approaches) do ap.laneGroup = findGroup(ai) end

    -- THE CENTRE OF THE TRACKS coming and going, which is what the lane ends get tidied against. The
    -- lock is only wherever the cursor happened to be; this is the middle of the junction itself -
    -- the crossing cluster's centroid, the nodes where tracks actually meet. Failing that (no crossing
    -- found), the mean of the points where the search circle cut each track. Captured HERE, at preview
    -- time, because the clear is about to delete most of the nodes it is measured from.
    local tracksCentre
    if lockedCrossing ~= nil then
        tracksCentre = { x = lockedCrossing.mergedX or lockedCrossing.x, z = lockedCrossing.mergedZ or lockedCrossing.z }
    elseif #approaches > 0 then
        local sx, sz = 0, 0
        for _, ap in ipairs(approaches) do
            local w = ap.selWp or ap.wp
            sx, sz = sx + w.x, sz + w.z
        end
        tracksCentre = { x = sx / #approaches, z = sz / #approaches }
    end

    -- Rough confidence (refined later): a clean crossing has a small, balanced set of approaches.
    local conf = 0
    if #approaches >= 2 then
        local balance = 1 - math.abs(nIn - nOut) / math.max(1, nIn + nOut)
        local tidy = (#approaches <= 8) and 1 or (8 / #approaches)
        conf = math.max(0, math.min(1, 0.5 * balance + 0.5 * tidy))
    end

    self.junctionPreview = {
        radius = selectR, workRadius = R, turnRadius = turnR, cx = cx, cz = cz, cy = cy, armed = (self.junctionArmed ~= nil),
        approaches = approaches, movements = movements,
        nIn = nIn, nOut = nOut, nNew = nNew, nExisting = nExisting, nTight = nTight, nOffRoad = nOffRoad,
        nNoCurve = nNoCurve, nUTurn = nUTurn, nFar = nFar, nLane = nLane, nRebuild = nRebuild, nBlocked = nBlocked,
        debris = debris, staleLinks = staleLinks, siteHasTwoWay = siteHasTwoWay,
        turnDebris = turnDebris, throughDebris = throughDebris, clearMode = clearMode,
        tracksCentre = tracksCentre, runNodes = runNodeOf, throughLinks = throughLinks,
        foreignWiring = foreignWiring,
        pathRoutes = (function()
            local out, has = {}, {}
            for _, rt in ipairs(self._jxRoutes or {}) do
                local nodes = {}
                for _, pid in ipairs(rt.path) do
                    local w = ADGraphManager:getWayPointById(pid)
                    if w ~= nil then nodes[#nodes + 1] = w end
                end
                if #nodes >= 3 then out[#out + 1] = nodes end
                has[rt.e], has[rt.x] = true, true
            end
            local side = {}
            for _, ap in ipairs(approaches) do
                if not has[ap] then
                    local ch = self:junctionChain(ap, cx, cz, R)
                    local nodes = {}
                    for _, n in ipairs(ch) do nodes[#nodes + 1] = n end
                    -- WHERE THE CONNECTOR STARTS, read now while the wiring is still there. The first
                    -- fork on the way in is either a TIE NODE (on the side road: the lane ends there)
                    -- or, where one lane sweeps straight into the main road, the MERGE (on the main
                    -- road). For a merge, walk BACK from it point by point reading the turn at each:
                    -- on the sweep every point turns; the connector starts where two points in a
                    -- row have stopped turning.
                    local cutAt = nil
                    local function deg3(w)
                        local seen, d = {}, 0
                        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                            for _, id in pairs(lst) do if not seen[id] then seen[id] = true d = d + 1 end end
                        end
                        return d >= 3
                    end
                    local function turnAt(i)
                        local a, b, c = nodes[i - 1], nodes[i], nodes[i + 1]
                        if a == nil or c == nil then return 0 end
                        local h1 = math.atan2(b.x - a.x, b.z - a.z)
                        local h2 = math.atan2(c.x - b.x, c.z - b.z)
                        local d = h2 - h1
                        while d > math.pi do d = d - 2 * math.pi end
                        while d < -math.pi do d = d + 2 * math.pi end
                        return d
                    end
                    -- THE TIE NODE HAS TO BE ONE OF THIS JUNCTION'S OWN FORKS. It used to be "the first
                    -- fork along the lane within 45 m of the centre" - and the lane is walked from its
                    -- OUTER end inward, so the first fork it meets is the one FARTHEST from this
                    -- junction: at a close pair, the neighbour's tie node, 24 m away and well inside
                    -- 45. The lane was cut there, and everything from there in was dug up - the whole
                    -- run between two junctions, 8 points out to 36 m, in game. Which forks belong to
                    -- this junction is something the selection already knows exactly.
                    -- Whose fork it is comes from the ownership the clear already works out for the
                    -- wiring: each fork goes to its nearest crossing, and a crossing whose wiring all
                    -- begins and ends on these lanes is this junction's own tie node however far out
                    -- it sits. (The selection's fork cluster is too tight for this - real tie nodes
                    -- sit 15-18 m out, beyond it - and testing against the cluster alone left lanes
                    -- with no tie node at all and their old connectors standing.)
                    -- ...AND ITS BRANCH HAS TO BE A CONNECTOR INTO THIS JUNCTION. Ownership goes by the
                    -- nearest crossing, and once a neighbouring junction has been cleared its crossing
                    -- is gone: a fork 31 m up a side road - a field entrance, nothing to do with this
                    -- junction - was then the nearest crossing's, passed as the lane's tie node, and
                    -- everything inward of it was dug up and re-laid on a straight line that missed the
                    -- road. What makes a fork a TIE node is what hangs off it: the branch that leaves
                    -- the lane there is followed, and it must run through the junction.
                    local onLane = {}
                    for _, n in ipairs(nodes) do onLane[n] = true end
                    local function leadsIn(fk)
                        for _, lst in ipairs({ fk.out or {}, fk.incoming or {} }) do
                            for _, id in pairs(lst) do
                                local b = ADGraphManager:getWayPointById(id)
                                if b ~= nil and not onLane[b] then
                                    local prev, cur = fk, b
                                    for _ = 1, 40 do
                                        if (cur.x - cx) ^ 2 + (cur.z - cz) ^ 2 <= R * R then return true end
                                        local nxt, cnt = nil, 0
                                        for _, l2 in ipairs({ cur.out or {}, cur.incoming or {} }) do
                                            for _, id2 in pairs(l2) do
                                                local o = ADGraphManager:getWayPointById(id2)
                                                if o ~= nil and o ~= prev and o ~= cur then
                                                    cnt = cnt + 1
                                                    nxt = nxt or o
                                                end
                                            end
                                        end
                                        if nxt == nil or cnt > 2 then break end
                                        prev, cur = cur, nxt
                                    end
                                end
                            end
                        end
                        return false
                    end
                    local f = nil
                    for i = 2, #nodes do
                        if deg3(nodes[i]) then
                            if clearMode then
                                if isOwnForClear(nodes[i]) and leadsIn(nodes[i]) then f = i break end
                            elseif (nodes[i].x - cx) ^ 2 + (nodes[i].z - cz) ^ 2 <= 45 * 45 then
                                f = i break
                            end
                        end
                    end
                    -- A FORK ON THE FAR SIDE OF THE JUNCTION IS NOT THIS LANE'S TIE NODE. A lane that
                    -- sweeps straight into the through road has no tie fork of its own: the first fork
                    -- on its list is where it MERGES, beyond the middle of the junction. Taking that
                    -- for the tie node and then hunting back up the road for where "the swing" began
                    -- cut the lane 16 to 30 m out and re-laid it - while the very same lane, met
                    -- after the junction next door had already cut it off at the box, was simply
                    -- run to the junction and ended there, which is right, and is what the user
                    -- picked out as the one correct result of six. So that is the rule for all six:
                    -- with no tie fork BEFORE the junction, the lane runs to the junction and ends.
                    if f ~= nil then
                        local k, kd = 1, math.huge
                        for i = 1, #nodes do
                            local d = (nodes[i].x - cx) ^ 2 + (nodes[i].z - cz) ^ 2
                            if d < kd then kd, k = d, i end
                        end
                        if f > k then
                            cutAt = k
                            for i = 2, k do
                                if (nodes[i].x - cx) ^ 2 + (nodes[i].z - cz) ^ 2 <= 4.5 * 4.5 then cutAt = i break end
                            end
                            f = nil
                        end
                    end
                    if f ~= nil then
                        -- TURNING IS MEASURED AGAINST THE ROAD'S OWN STEADY CURVE, NOT AGAINST ZERO. A
                        -- side road that bends all the way in turns a little at every node; counted
                        -- from zero that added up to "has swung" and no node ever read as quiet, so
                        -- the search for where the swing began ran back up the road until it happened
                        -- on a straight bit - 31 m out at one T, and everything inward was dug up and
                        -- re-laid straight across the bend. The road's steady turn per node is the
                        -- middle of its readings; a kickout is what departs from THAT.
                        local base = 0
                        do
                            local ts = {}
                            for i = 2, f - 1 do ts[#ts + 1] = turnAt(i) end
                            if #ts >= 3 then
                                table.sort(ts)
                                base = ts[math.floor((#ts + 1) / 2)]
                            end
                        end
                        local rawTurnAt = turnAt
                        turnAt = function(i) return rawTurnAt(i) - base end
                        -- how far the lane has turned by the time it reaches that fork
                        local total = 0
                        for i = 2, f - 1 do total = total + turnAt(i) end
                        if f == #nodes or math.abs(total) < math.rad(20) then
                            cutAt = f
                        else
                            local quiet = 0
                            for i = f - 1, 2, -1 do
                                if math.abs(turnAt(i)) < math.rad(2.5) then
                                    quiet = quiet + 1
                                    if quiet >= 2 then cutAt = i + 1 break end
                                else
                                    quiet = 0
                                end
                            end
                        end
                    end
                    -- A SIDE LANE OF THIS JUNCTION ENDS AT THIS JUNCTION. The scope circle also cuts
                    -- lanes that are only passing on their way to the junction next door, and one of
                    -- those was being tidied as this junction's own: cut 31 m out, down by the
                    -- neighbour, and carried off towards a box it never reached - a dangling line, a
                    -- lane trimmed far short, and an arm count of seven on a T. Whose lane it is
                    -- comes from the same ownership the wiring uses, asked of the lane's own end.
                    -- Asked at the lane's CLOSEST APPROACH to the junction, not at the end of its list:
                    -- with through paths kept the list runs on round the connector and away down the
                    -- next road, so its last node can be 40 m off and somebody else's while the lane
                    -- is plainly this junction's. Testing the last node dropped such a lane from the
                    -- tidy and left its remains to the loose-end sweep - cut 30 m out, never carried.
                    local mine = true
                    if clearMode and lockedCrossing ~= nil and #nodes >= 1 then
                        local nb, nd = nodes[1], math.huge
                        for _, n in ipairs(nodes) do
                            local d = (n.x - cx) ^ 2 + (n.z - cz) ^ 2
                            if d < nd then nd, nb = d, n end
                        end
                        mine = isOwnForClear(nb)
                    end
                    if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG and clearMode then
                        for i = 2, #nodes do
                            if deg3(nodes[i]) then
                                Logging.info("[FlyoverEditor]: FORKONLANE lane of %d: #%d (%.1f, %.1f) %.0f m from centre, own=%s leadsIn=%s",
                                    #nodes, i, nodes[i].x, nodes[i].z, math.sqrt((nodes[i].x - cx) ^ 2 + (nodes[i].z - cz) ^ 2),
                                    tostring(isOwnForClear(nodes[i])), tostring(leadsIn(nodes[i])))
                            end
                        end
                    end
                    if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG and f ~= nil then
                        local tot = 0
                        for i = 2, f - 1 do tot = tot + turnAt(i) end
                        Logging.info("[FlyoverEditor]: CUTAT lane of %d: own fork #%d at (%.1f, %.1f), turn before it %.1f deg (relative to the road's curve) -> cut at #%s",
                            #nodes, f, nodes[f].x, nodes[f].z, math.deg(tot), tostring(cutAt))
                    end
                    if #nodes >= 2 and mine then
                        side[#side + 1] = { nodes = nodes, useOut = (ap.dir == "in"), cutNode = cutAt and nodes[cutAt] or nil }
                    end
                end
            end
            return { through = out, side = side }
        end)(),
        protectedOf = protectedOf,
        usedMin = usedMin, usedMax = usedMax, confidence = conf,
        sweptMax = sweptMax, nSweptWide = nSweptWide, nTrailerRoad = nTrailerRoad, nTrailerHit = nTrailerHit,
        nSweep = nSweep, sweepMax = sweepMax,
    }
    -- Run the lane-end tidy in DRY mode and keep what it says: where each end would land, and the
    -- claim bands it measured against. Drawn below, so the site can be judged on screen before
    -- right-clicking instead of inferred afterwards from a log. It mutates nothing.
    if clearMode then
        tryCall("junction tidy preview", function()
            local ends, bands, swept, roadsOut, boxCentre = self:junctionTidyLaneEnds(self.junctionPreview, true)
            self.junctionPreview.tidyEnds, self.junctionPreview.tidyBands = ends, bands
            self.junctionPreview.boxSweep, self.junctionPreview.tidyRoads = swept, roadsOut
            self.junctionPreview.boxCentre = boxCentre
            -- THE MIDDLE OF A JUNCTION IS WHERE ITS ROADS CROSS, and that is what gets shown. The
            -- selection finds the junction by its forks, and their centroid sits a few metres off
            -- the crossing - 3.3 m at one T, where the lock was visibly not on the intersection.
            -- This is not the old re-aim: nothing is solved again and the selection is not
            -- reconsidered. The crossing only says where the middle of the chosen junction is.
            if boxCentre ~= nil then
                self.junctionPreview.cx, self.junctionPreview.cz = boxCentre.x, boxCentre.z
            end
        end)
        -- Named on the card before anything is applied: which junction this is, and what kind.
        tryCall("junction classify", function()
            self.junctionPreview.junctionType = self:junctionClassify(self.junctionPreview)
        end)
        tryCall("junction number", function()
            self.junctionPreview.junctionNumber = self:junctionNumberAt(cx, cz)
        end)
        tryCall("junction situation", function()
            self.junctionPreview.junctionSituation = self:junctionSituation(self.junctionSite)
        end)
    elseif self.junctionPreview ~= nil then
        tryCall("junction situation", function()
            self.junctionPreview.junctionSituation = self:junctionSituation(self.junctionSite)
        end)
        tryCall("junction number", function()
            self.junctionPreview.junctionNumber = self:junctionNumberAt(cx, cz)
        end)
        -- Spelled out, not `a and nil or b`: that idiom falls through to b whenever the middle
        -- value is nil, so it indexed the very site it had just found to be missing - an error on
        -- every frame build mode was pointed at open ground.
        local st = self.junctionSite
        if st ~= nil then
            self.junctionPreview.junctionState = st.virgin and "virgin - ready to build" or "wired"
        else
            self.junctionPreview.junctionState = nil
        end
    end

    -- Skeleton INSIDE the circle: if a run-following walk ever diverts off the road and down a
    -- connector, that connector's nodes are marked road and become permanently unclearable - and it
    -- leaves no rejection line at all, because it is never even considered as debris. Listing them is
    -- how that shows up: a survivor whose id appears here is protected-as-road, not rejected.
    if clearMode and logSite2 then
        local ids, n = {}, 0
        for id in pairs(skeleton) do
            local w = inside[id] or ADGraphManager:getWayPointById(id)
            if w ~= nil and isOwn(w) then
                n = n + 1
                if #ids < 40 then ids[#ids + 1] = tostring(id) end
            end
        end
        roadNote(string.format("clearSkel:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
            "junction clear - %d road/skeleton point(s) inside the circle (never clearable): %s%s.",
            n, table.concat(ids, " "), (n > #ids) and " ..." or "")
    end
    -- Clear mode's own summary, on every lock: the card shows the same three numbers, but they are
    -- not otherwise in the log, and "check the log" is how this tool gets debugged. Keyed by the
    -- locked point (rounded) so moving the lock prints a fresh line instead of staying silent.
    if clearMode and logSite2 then
        roadNote(string.format("clearSummary:%d:%d", math.floor(cx * 2), math.floor(cz * 2)),
            -- These have to be the numbers for the CURRENT toggle, not always the leave-on pair. They
            -- were the latter, so with through paths set to clear the log read "51 will clear, 29
            -- spared" while the apply took all 80 - the line naming as spared the very points it was
            -- about to delete. That is how a through road died with nothing in the log to show it.
            "junction clear - %d approach(es) found, %d point(s) will clear, %d through-path point(s) spared.",
            #approaches,
            (self.junctionLeaveThrough ~= false) and #turnDebris or #debris,
            (self.junctionLeaveThrough ~= false) and #throughDebris or 0)
    end
end

--- Drive the design rig through one movement with the stock-driver twin (SweptSim) and return the
--- predicted tracks and the trailer's worst inside cut-in relative to the connector. The simulated
--- route is: a 40 m straight run-in (extrapolated back along the entry lane), the entry lane's real
--- nodes up to the tie-in, the connector as it would be laid, the exit lane's real nodes from its
--- tie-in outward, and a 40 m straight run-out - the transitions are where the cut-in happens, so the
--- rig has to arrive already settled on the straight. Returns nil when the geometry is unusable.
function ADFlyoverEditor:junctionSweptPredict(fromAp, toAp, c, cx, cz, radius, rig)
    local chainA = self:junctionChain(fromAp, cx, cz, radius)
    local chainB = self:junctionChain(toAp, cx, cz, radius)
    local path = {}
    -- Entry lane: chain[1] is the boundary, increasing toward the interior; keep the nodes the tie-in
    -- lies AHEAD of (those the rig drives over before the connector starts).
    for k = 1, math.min(#chainA, junctionChainIndexNear(chainA, c.ax, c.az)) do
        local n = chainA[k]
        local dx, dz = junctionSegDir(chainA, k)
        if (c.ax - n.x) * dx + (c.az - n.z) * dz > 0.3 then
            path[#path + 1] = { x = n.x, y = n.y, z = n.z }
        end
    end
    path[#path + 1] = { x = c.ax, y = c.ay, z = c.az }
    for _, p in ipairs(c.points) do path[#path + 1] = { x = p.x, y = p.y, z = p.z } end
    local firstConnector = #path - #c.points     -- index of the tie-in A in `path`
    path[#path + 1] = { x = c.bx, y = c.by, z = c.bz }
    local lastConnector = #path
    -- Exit lane: walked from the boundary inward, so travel is index-DEcreasing; keep the nodes that
    -- lie beyond the tie-in in the outward direction, interior first.
    for k = math.min(#chainB, junctionChainIndexNear(chainB, c.bx, c.bz)), 1, -1 do
        local n = chainB[k]
        local dx, dz = junctionSegDir(chainB, k)
        if (n.x - c.bx) * -dx + (n.z - c.bz) * -dz > 0.3 then
            path[#path + 1] = { x = n.x, y = n.y, z = n.z }
        end
    end
    if #path < 3 then return nil end
    -- Straight run-in / run-out along the first / last real segment.
    local function unit(ax, az, bx, bz)
        local dx, dz = bx - ax, bz - az
        local l = math.sqrt(dx * dx + dz * dz)
        if l < 1e-6 then return nil end
        return dx / l, dz / l
    end
    local ux, uz = unit(path[1].x, path[1].z, path[2].x, path[2].z)
    local vx, vz = unit(path[#path - 1].x, path[#path - 1].z, path[#path].x, path[#path].z)
    if ux == nil or vx == nil then return nil end
    table.insert(path, 1, { x = path[1].x - ux * 40, y = path[1].y, z = path[1].z - uz * 40 })
    path[#path + 1] = { x = path[#path].x + vx * 40, y = path[#path].y, z = path[#path].z + vz * 40 }
    firstConnector, lastConnector = firstConnector + 1, lastConnector + 1

    local heading = math.atan2(ux, uz)
    local sim = SweptSim.simulate(path, rig, SweptSim.STOCK_DRIVER,
        { x = path[1].x, z = path[1].z, heading = heading, trailerHeading = heading, speed = 30, rot = 0 },
        { dt = 0.02, maxTime = 60, speedLimitKmh = 40 })
    if #sim < 10 then return nil end

    -- Cut-in is measured against the CONNECTOR only (its inside is the corner), for the steps whose
    -- trailer axle projects inside it. Turn sense from the connector's end tangents: with forward =
    -- (sin h, cos h) and left = (cos h, -sin h), a left turn has a NEGATIVE cross of entry x exit.
    local con = {}
    for k = firstConnector, lastConnector do con[#con + 1] = path[k] end
    local cross = ux * vz - uz * vx
    local leftTurn = cross < 0
    local trailerIn, towIn, trailerOut = 0, 0, 0
    local a, b = con[1], con[#con]
    local function insideConnector(px, pz)
        local inA = (px - a.x) * (con[2].x - a.x) + (pz - a.z) * (con[2].z - a.z) > 0
        local inB = (px - b.x) * (con[#con - 1].x - b.x) + (pz - b.z) * (con[#con - 1].z - b.z) > 0
        return inA and inB
    end
    -- The TURN EVENT: from the tow's rear axle entering the connector until the trailer axle has
    -- left it. The envelope probes below (road surface, obstacles) cover exactly this window - the
    -- trailer is still cutting inside after the tow is back on the exit road, and that cut is this
    -- turn's doing; whatever happens on the plain straights before and after is not.
    local started, ended = false, false
    local edges = {}          -- body-edge points to probe the road surface at
    local towTrack, trlTrack = {}, {}  -- axle tracks to probe obstacles along (within the window)
    local halfTow, halfTrl = (rig.towWidth or 2.5) / 2, (rig.trailerWidth or 2.5) / 2
    -- Past the exit tie-in B, in the direction of travel out of the connector.
    local function pastB(px, pz)
        return (px - b.x) * (b.x - con[#con - 1].x) + (pz - b.z) * (b.z - con[#con - 1].z) > 0
    end
    local trailerPt = (rig.trailerLength or 0) > 0
    -- Offsets are measured against the part of the route the rig is ACTUALLY ON, found from its
    -- progress along it - not against the nearest segment anywhere. The simulated route is long now
    -- (lane - connector - lane, ~47 m each way) and on a left turn its two legs pass close to each
    -- other near the crossing: nearest-segment picked the OTHER leg and reported nonsense (a tow
    -- "3 m inside", a trailer "2.6 m outside" on a turn that fits).
    local cumP = { 0 }
    for i = 2, #path do
        cumP[i] = cumP[i - 1] + math.sqrt((path[i].x - path[i - 1].x) ^ 2 + (path[i].z - path[i - 1].z) ^ 2)
    end
    local function offsetNear(px, pz, sLo, sHi)
        local best, signed = math.huge, 0
        for k = 1, #path - 1 do
            if cumP[k + 1] >= sLo and cumP[k] <= sHi then
                local a2, b2 = path[k], path[k + 1]
                local dx, dz = b2.x - a2.x, b2.z - a2.z
                local l2 = dx * dx + dz * dz
                if l2 > 1e-9 then
                    local u = math.max(0, math.min(1, ((px - a2.x) * dx + (pz - a2.z) * dz) / l2))
                    local qx, qz = a2.x + u * dx, a2.z + u * dz
                    local d = math.sqrt((px - qx) ^ 2 + (pz - qz) ^ 2)
                    if d < best then
                        best = d
                        signed = (((px - qx) * dz - (pz - qz) * dx) >= 0) and d or -d
                    end
                end
            end
        end
        return signed
    end
    local rigLen = (rig.trailerLength or 0) + math.abs(rig.hitchOffset or 0)
    for _, s in ipairs(sim) do
        local wpi = math.max(1, math.min(#path, s.wp or 1))
        local sTow = cumP[wpi] - math.sqrt((s.sx - path[wpi].x) ^ 2 + (s.sz - path[wpi].z) ^ 2)
        -- Starts a look-ahead distance BEFORE tie-in A: that is where the driver begins steering for
        -- the curve (so where the entry cut-in begins), and it does not depend on the tow ever
        -- entering the wedge between the tie-ins, which a hard shortcut can skip entirely.
        if not started then
            local tx, tz = con[2].x - a.x, con[2].z - a.z
            local tl = math.sqrt(tx * tx + tz * tz)
            if tl > 1e-6 and ((s.x - a.x) * tx + (s.z - a.z) * tz) / tl > -(rig.lookAhead or 6) then
                started = true
            end
        end
        if started and not ended then
            -- Cut-in is measured against the WHOLE simulated route (lane - connector - lane), not
            -- only while the axle sits in the wedge between the two tie-ins: on a tight turn the
            -- trailer shortcuts the corner so hard that it goes from "not yet past A" straight to
            -- "already past B" and never enters that wedge - every tight right turn reported 0.00 m.
            if trailerPt then
                local o = offsetNear(s.ax, s.az, sTow - rigLen - 10, sTow + 2)
                local inside = leftTurn and o or -o
                if inside > trailerIn then trailerIn = inside end
                if -inside > trailerOut then trailerOut = -inside end
            end
            -- The event ends when the LAST body - the trailer axle, or the tow's rear axle when
            -- there is no trailer - is past the exit tie-in. Closing it when the tow left the
            -- connector cut short right-turn quadrants before the trailer (9 m behind) had even
            -- entered: every right turn measured "0.00 m inside" and went unprobed.
            if trailerPt then
                if pastB(s.ax, s.az) and #trlTrack > 5 then ended = true end
            elseif pastB(s.x, s.z) and #towTrack > 5 then
                ended = true
            end
            do
                local ot = offsetNear(s.x, s.z, sTow - 8, sTow + 4)
                local insideT = leftTurn and ot or -ot
                if insideT > towIn then towIn = insideT end
            end
            if not ended then
                towTrack[#towTrack + 1] = { x = s.x, z = s.z }
                trlTrack[#trlTrack + 1] = { x = s.ax, z = s.az }
                -- Body edges: rear and front axle of the tow, and the trailer axle, each +-half width
                -- along the body's LEFT vector (cos h, -sin h).
                local lx, lz = math.cos(s.heading), -math.sin(s.heading)
                local fx, fz = math.sin(s.heading), math.cos(s.heading)
                local frx, frz = s.x + fx * rig.wheelbase, s.z + fz * rig.wheelbase
                local tlx, tlz = math.cos(s.trailerHeading), -math.sin(s.trailerHeading)
                edges[#edges + 1] = { x = s.x + lx * halfTow, z = s.z + lz * halfTow }
                edges[#edges + 1] = { x = s.x - lx * halfTow, z = s.z - lz * halfTow }
                edges[#edges + 1] = { x = frx + lx * halfTow, z = frz + lz * halfTow }
                edges[#edges + 1] = { x = frx - lx * halfTow, z = frz - lz * halfTow }
                if (rig.trailerLength or 0) > 0 then
                    edges[#edges + 1] = { x = s.ax + tlx * halfTrl, z = s.az + tlz * halfTrl }
                    edges[#edges + 1] = { x = s.ax - tlx * halfTrl, z = s.az - tlz * halfTrl }
                end
            end
        end
    end
    -- Thin the full tracks for drawing: every 4th step is ~0.1-0.3 m apart at the speeds involved.
    local tow, trailer = {}, {}
    for k = 1, #sim, 4 do
        local s = sim[k]
        tow[#tow + 1] = { x = s.x, z = s.z }
        trailer[#trailer + 1] = { x = s.ax, z = s.az }
    end
    -- Thin the probe sets the same way: a probe every ~0.5 m of travel is plenty for a raycast.
    local function thin(pts, every)
        local out = {}
        for k = 1, #pts, every do out[#out + 1] = pts[k] end
        if #pts > 0 and (#pts - 1) % every ~= 0 then out[#out + 1] = pts[#pts] end
        return out
    end
    return { tow = tow, trailer = trailer, trailerIn = trailerIn, towIn = towIn, trailerOut = trailerOut,
             leftTurn = leftTurn, edges = thin(edges, 6 * 3), towTrack = thin(towTrack, 6), trlTrack = thin(trlTrack, 6) }
end

--- Do the design rig's BODY EDGES leave the road during the turn? Same tolerance rule as the
--- connector's corridor check (one stray sample, or 15%, whichever is larger), applied to where
--- the tow and the trailer would actually be rather than to the waypoint line.
function ADFlyoverEditor:junctionSweptOffRoad(sw)
    local off, total = 0, 0
    for _, p in ipairs(sw.edges or {}) do
        total = total + 1
        if not isRoadAt(p.x, p.z) then off = off + 1 end
    end
    if total == 0 then return false, 0, 0 end
    local tolerance = math.max(1, math.ceil(total * 0.15))
    return off > tolerance, off, total
end

--- Static obstacles under the rig's predicted bodies during the turn: the tow's track at the tow's
--- width, the trailer's at the trailer's.
function ADFlyoverEditor:junctionSweptHits(sw, rig)
    local hits = self:junctionObstacleHitsAlong(sw.towTrack or {}, (rig.towWidth or 2.5) / 2)
    if (rig.trailerLength or 0) > 0 then
        hits = hits + self:junctionObstacleHitsAlong(sw.trlTrack or {}, (rig.trailerWidth or 2.5) / 2)
    end
    return hits
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
    -- A ONE-node chain is a stem whose only in-scope node is its tip (trimmed back to, or just inside,
    -- the scope circle) - seen on two-way stems at a T, where every turn through the stem was refused
    -- as "no joinable curve". The geometry below only needs the chain for a DIRECTION and a point to
    -- walk back from, and the approach's bearing already gives the direction (an entry walks
    -- downstream, an exit upstream - the same convention junctionChain starts its walk with). So
    -- extend a lone node with a virtual second one a few metres along that bearing, for GEOMETRY ONLY:
    -- placement re-walks the real chain itself (junctionTieIn) and never sees this point.
    local function withVirtual(chain, ap)
        if #chain >= 2 then return chain end
        local cb = ap.chainBearing or ap.bearing
        local wdx, wdz = math.sin(cb), math.cos(cb)
        if ap.dir ~= "in" then wdx, wdz = -wdx, -wdz end
        local p = chain[1]
        return { p, { x = p.x + wdx * 4, y = p.y, z = p.z + wdz * 4, id = p.id, virtual = true } }
    end
    if #chainA < 1 or #chainB < 1 then
        roadNote(string.format("chain:%d_%d", fromAp.wp.id, toAp.wp.id),
            "junction - entry id=%d -> exit id=%d: no lane chain at all (entry %d, exit %d) - refused.",
            fromAp.wp.id, toAp.wp.id, #chainA, #chainB)
        return nil, "chain"
    end
    chainA, chainB = withVirtual(chainA, fromAp), withVirtual(chainB, toAp)

    -- Meeting region: the closest node between the two chains (dense ~4 m nodes make node-to-node a good
    -- proxy for the true closest approach).
    local iA, iB, bestd = 1, 1, math.huge
    -- The meeting is looked for INSIDE THE SEARCH CIRCLE (+ tolerance) first: which crossing this is,
    -- is exactly what the circle is for. The chains run ~47 m out each way and on through the
    -- junction, and two such lanes can come closer to each other somewhere else entirely (two lanes of
    -- one road running side by side up the street) than they do at the crossing the user pointed at -
    -- the tangents there are near-parallel, the projected corner lands 100 m away, and the pair is
    -- thrown out as "never come close". Only if neither chain has a node in the circle does the
    -- search fall back to the whole chains.
    local own = self.junctionOwn
    local function inCircle(n)
        return own == nil or ((n.x - own.cx) ^ 2 + (n.z - own.cz) ^ 2 <= own.r2)
    end
    for pass = 1, 2 do
        for a = 1, #chainA do
            for b = 1, #chainB do
                -- Virtual direction nodes (see withVirtual) never host the meeting: a tie-in walked
                -- back from one could land ON it, i.e. 4 m into thin air past the real stem tip.
                if not chainA[a].virtual and not chainB[b].virtual
                    and (pass == 2 or (inCircle(chainA[a]) and inCircle(chainB[b]))) then
                    local d = (chainA[a].x - chainB[b].x) ^ 2 + (chainA[a].z - chainB[b].z) ^ 2
                    if d < bestd then bestd, iA, iB = d, a, b end
                end
            end
        end
        if bestd < math.huge then break end
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
        local meetCap = math.max(turnR * 3, 15)   -- the turn's own scale, not the search radius
        if bestd > meetCap * meetCap then return nil, "far" end
    elseif math.abs(det) > 1e-6 then
        local farCap = math.max(turnR * 6, 20)    -- the turn's own scale, not the search radius
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
    if bi == nil then
        roadNote(string.format("nofit:%d_%d", fromAp.wp.id, toAp.wp.id),
            "junction - entry id=%d -> exit id=%d: neither curve engine fit (delta %.0f deg, t %.1f, sA %.1f, sB %.1f, tie-ins %.1f m apart) - refused.",
            fromAp.wp.id, toAp.wp.id, math.deg(delta), t, sA, sB, math.sqrt((pbx - pax) ^ 2 + (pbz - paz) ^ 2))
        return nil, "nofit"
    end
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
-- The overlap callback collects WHAT it hit (shape name, split-shape flag, rigid body type) so a
-- refusal can be traced to an actual object in the log rather than a count. A tree's canopy over
-- a road is the suspected false positive; the names will say.
local JunctionOverlapProbe = { hits = {} }
function JunctionOverlapProbe.cb(self, transformId)
    if transformId ~= nil and transformId ~= 0 and transformId ~= g_currentMission.terrainRootNode then
        -- The mask now includes DYNAMIC objects (knock-over signs and props are dynamic bodies), so
        -- the things that are dynamic but NOT part of the road's furniture have to be dropped here:
        -- vehicles and implements (parked or passing), bales, pallets. Anything the mission maps to
        -- an object with wheels, a root vehicle, or bale/pallet traits is ignored.
        local obj = g_currentMission.nodeToObject ~= nil and g_currentMission.nodeToObject[transformId] or nil
        if obj ~= nil and (obj.rootVehicle ~= nil or obj.spec_wheels ~= nil or obj.getRootVehicle ~= nil
            or obj.isRoundbale ~= nil or obj.baleDiameter ~= nil or obj.spec_pallet ~= nil) then
            return true
        end
        local ok, desc = pcall(function()
            local name = getName(transformId) or "?"
            local split = (getHasClassId ~= nil and ClassIds ~= nil and ClassIds.SHAPE ~= nil
                and getSplitType ~= nil and getSplitType(transformId) ~= 0) and " tree(split)" or ""
            local rb = (getRigidBodyType ~= nil) and tostring(getRigidBodyType(transformId)) or "?"
            local mask = (getCollisionFilterGroup ~= nil) and tostring(getCollisionFilterGroup(transformId)) or "?"
            return string.format("%s%s rb=%s group=%s", name, split, rb, mask)
        end)
        self.hits[#self.hits + 1] = ok and desc or ("? (" .. tostring(desc) .. ")")
    end
    return true
end

--- Number of corridor boxes along `con` that overlap a static obstacle. Boxes are laid segment by
--- segment along the curve (half corridor width wide, segment-long), rotated to the local heading.
function ADFlyoverEditor:junctionObstacleHits(con)
    local halfW = (self.junctionClearance or AutoDrive.FLYOVER_JUNCTION_CLEARANCE or 5.0) / 2
    local pts = { { x = con.ax, z = con.az } }
    for _, p in ipairs(con.points) do pts[#pts + 1] = p end
    pts[#pts + 1] = { x = con.bx, z = con.bz }
    return self:junctionObstacleHitsAlong(pts, halfW)
end

--- The probe itself, along any polyline at any half-width: boxes segment by segment, rotated to the
--- local heading. Shared by the connector corridor and the swept-path body tracks.
function ADFlyoverEditor:junctionObstacleHitsAlong(pts, halfW)
    if overlapBox == nil or g_currentMission == nil or g_currentMission.terrainRootNode == nil then
        return 0
    end
    if junctionObstacleMask == nil then
        -- AutoDrive's OWN object-sensor mask (Sensors/CollSensorSplit.lua maskObjects), minus
        -- TERRAIN_DELTA (a flat probe box on a slope would hit the terrain it stands on). The first
        -- mask was static + tree + building only: a trailer clipped something the gate had judged
        -- clear, with the prediction within a metre of the recorded track - i.e. the object was
        -- simply not in the mask. Map furniture is very often left in the DEFAULT group, and
        -- knock-over signs are DYNAMIC bodies; both are what AutoDrive's sensors stop for.
        junctionObstacleMask = (CollisionFlag.DEFAULT or 0) + CollisionFlag.STATIC_OBJECT
            + (CollisionFlag.DYNAMIC_OBJECT or 0) + CollisionFlag.TREE + CollisionFlag.BUILDING
    end
    local hits = 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        if l > 1e-3 then
            local mx, mz = (a.x + b.x) * 0.5, (a.z + b.z) * 0.5
            local gy = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, mx, 1, mz) or 0
            local ry = math.atan2(dx, dz)
            JunctionOverlapProbe.hits = {}
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
                -- Count what SURVIVED the callback's filter (vehicles, bales, pallets dropped), not
                -- the raw shape count, which includes them.
                shapes = #JunctionOverlapProbe.hits
                if shapes > 0 then
                    hits = hits + 1
                    roadNote("obsFirstHit", "obstacle probe FIRST HIT at %.1f, %.1f (%d shape(s)).", mx, mz, shapes)
                    -- Name every distinct object hit, once each, with where.
                    for _, desc in ipairs(JunctionOverlapProbe.hits) do
                        -- Keyed by name AND place (4 m grid): "col"/"collision" are generic shape
                        -- names, and keying on the name alone logged the first one on the map and
                        -- then stayed silent at every other site.
                        roadNote(string.format("obsHit:%s:%d:%d", desc, math.floor(mx / 4), math.floor(mz / 4)),
                            "obstacle probe hit %s at %.1f, %.1f (box half-width %.2f m).", desc, mx, mz, halfW)
                    end
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
--- The sweep-wide reshape: a copy of connector `con` with its interior points pushed `d` metres
--- toward the OUTSIDE of the turn, perpendicular to the local heading. The push tapers over the first
--- and last fifth of the curve so the tie-ins stay exactly on their tracks and the curve leaves and
--- rejoins them smoothly. An outward offset only ever increases the radius, so minRadius stands as a
--- conservative bound.
local function junctionSweepWide(con, d, leftTurn)
    local pts = { { x = con.ax, y = con.ay, z = con.az } }
    for _, p in ipairs(con.points) do pts[#pts + 1] = p end
    pts[#pts + 1] = { x = con.bx, y = con.by, z = con.bz }
    local cum, total = { 0 }, 0
    for i = 2, #pts do
        total = total + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].z - pts[i - 1].z) ^ 2)
        cum[i] = total
    end
    if total < 1e-3 then return nil end
    -- A sideways push needs LENGTH to blend in. The first version tapered over a fixed fifth of
    -- the curve: on a ~16 m connector a 2 m sweep was taken up in ~3 m, i.e. 30-degree kinks at
    -- both ends (recorded on the first swept turn that was driven). The blend now runs over at
    -- least 4 m per metre of sweep at each end, eased with a cosine, and a connector too short to
    -- carry the sweep at all (the two blends would overlap) is not swept - the radius search
    -- steps down instead.
    local blend = math.max(0.2, (4 * d) / total)
    if blend > 0.5 then return nil end
    local out = {}
    for i = 2, #pts - 1 do
        local a, b = pts[i - 1], pts[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        local p = pts[i]
        if l > 1e-6 then
            -- forward = (dx,dz)/l ; LEFT = (fz, -fx) in this file's convention (forward = (sin h,
            -- cos h), left = (cos h, -sin h)). Outside of a left turn is the RIGHT, and vice versa.
            local lx, lz = dz / l, -dx / l
            local ox, oz = lx, lz
            if leftTurn then ox, oz = -lx, -lz end
            local u = cum[i] / total
            local e = math.min(1, u / blend, (1 - u) / blend)
            local w = 0.5 - 0.5 * math.cos(math.pi * e)
            out[#out + 1] = { x = p.x + ox * d * w, y = p.y, z = p.z + oz * d * w }
        else
            out[#out + 1] = { x = p.x, y = p.y, z = p.z }
        end
    end
    return { ax = con.ax, ay = con.ay, az = con.az, bx = con.bx, by = con.by, bz = con.bz,
        points = out, minRadius = con.minRadius, t = con.t, meetDist = con.meetDist, sweep = d }
end

--- The KICKOUT (docs/swept-path-spec.md §6, "Kickout shape"): the sweep-wide reshape in the form that
--- actually works - it starts EARLY on the entry lane and ends LATE on the exit lane, and it is
--- asymmetric (the return is longer than the setup, because the trailer is still cutting inside a
--- rig-length after the tow has left the curve). Offline it recovers ~3x the trailer clearance per
--- metre of push that an inside-the-curve blend does, with no kinks.
---
--- Construction: the composite route  lane(A' -> A) + connector + lane(B -> B')  is offset toward the
--- OUTSIDE of the turn by `d`, eased in with a cosine over the entry stretch, held through the curve,
--- eased out over the exit stretch. The lane stretches follow the lanes' real shape (a straight
--- S-bend would cut across a curved approach), resampled at 2 m so the ease is smooth. The ease
--- length is bounded below by  pi * sqrt(d * turnR / 2)  - the length at which a cosine lane-change
--- of `d` peaks at exactly the turn radius - so the kickout never bends tighter than the turn itself.
---
--- It lives INSIDE the scope circle by design: the new tie-ins A' and B' must sit on the lane chains
--- within the scope, so the junction stays one self-contained site for approach detection, the
--- already-connected test and rebuild. A cramped scope shortens the kickout, and below the ease
--- bound refuses it (returns nil, "scope") - the fix is a bigger scope, which the log says. A side
--- whose lane DEAD-ENDS inside the scope is not kicked out either (its tie-in trims the stem, and
--- an early tie-in would trim away the other turns' tie-ins): returns nil, "deadend".
function ADFlyoverEditor:junctionKickout(fromAp, toAp, con, d, leftTurn, rig, cx, cz, radius, turnR)
    local chainA, deadEndA = self:junctionChain(fromAp, cx, cz, radius)
    local chainB, deadEndB = self:junctionChain(toAp, cx, cz, radius)
    if deadEndA or deadEndB then return nil, "deadend" end
    local early = (rig.lookAhead or 8) + 2
    local late = (rig.lookAhead or 8) + (rig.trailerLength or 0)
    local minBlend = math.pi * math.sqrt(d * turnR / 2)
    early, late = math.max(early, minBlend), math.max(late, minBlend)

    -- Travel-ordered lane points: entry = boundary ... A ; exit = B ... boundary.
    local entry = {}
    for k = 1, math.min(#chainA, junctionChainIndexNear(chainA, con.ax, con.az)) do
        local n = chainA[k]
        local dx, dz = junctionSegDir(chainA, k)
        if (con.ax - n.x) * dx + (con.az - n.z) * dz > 0.3 then
            entry[#entry + 1] = { x = n.x, y = n.y or 0, z = n.z }
        end
    end
    entry[#entry + 1] = { x = con.ax, y = con.ay or 0, z = con.az }
    local exit = { { x = con.bx, y = con.by or 0, z = con.bz } }
    for k = math.min(#chainB, junctionChainIndexNear(chainB, con.bx, con.bz)), 1, -1 do
        local n = chainB[k]
        local dx, dz = junctionSegDir(chainB, k)
        if (n.x - con.bx) * -dx + (n.z - con.bz) * -dz > 0.3 then
            exit[#exit + 1] = { x = n.x, y = n.y or 0, z = n.z }
        end
    end

    -- Take `want` metres off one end of a polyline (fromEnd: the LAST `want` metres, else the first),
    -- resampled at ~2 m, in travel order. Returns the points and the length actually available.
    local function stretch(poly, want, fromEnd)
        local src = poly
        if fromEnd then
            src = {}
            for i = #poly, 1, -1 do src[#src + 1] = poly[i] end
        end
        local cum = { 0 }
        for i = 2, #src do
            cum[i] = cum[i - 1] + math.sqrt((src[i].x - src[i - 1].x) ^ 2 + (src[i].z - src[i - 1].z) ^ 2)
        end
        local avail = math.min(want, cum[#src])
        local function at(s)
            for i = 2, #src do
                if cum[i] >= s - 1e-9 then
                    local l = cum[i] - cum[i - 1]
                    local f = (l > 1e-9) and (s - cum[i - 1]) / l or 0
                    local a, b = src[i - 1], src[i]
                    return { x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f, z = a.z + (b.z - a.z) * f }
                end
            end
            local e = src[#src]
            return { x = e.x, y = e.y, z = e.z }
        end
        local out, s = {}, 0
        while s < avail - 0.5 do
            out[#out + 1] = at(s)
            s = s + 2
        end
        out[#out + 1] = at(avail)
        if fromEnd then
            local rev = {}
            for i = #out, 1, -1 do rev[#rev + 1] = out[i] end
            out = rev
        end
        return out, avail
    end
    local entryPart, earlyGot = stretch(entry, early, true)     -- A' ... A
    local exitPart, lateGot = stretch(exit, late, false)        -- B ... B'
    if earlyGot < minBlend - 1e-6 or lateGot < minBlend - 1e-6 then
        return nil, "scope", earlyGot, lateGot, minBlend
    end

    -- Composite route and its arc-length marks.
    local P = {}
    for _, p in ipairs(entryPart) do P[#P + 1] = p end                 -- ends with A
    for _, p in ipairs(con.points) do P[#P + 1] = { x = p.x, y = p.y or 0, z = p.z } end
    for _, p in ipairs(exitPart) do P[#P + 1] = p end                  -- starts with B
    local iA, iB = #entryPart, #entryPart + #con.points + 1
    local cum = { 0 }
    for i = 2, #P do cum[i] = cum[i - 1] + math.sqrt((P[i].x - P[i - 1].x) ^ 2 + (P[i].z - P[i - 1].z) ^ 2) end
    local sA, sB, total = cum[iA], cum[iB], cum[#P]
    if sA < 1e-3 or total - sB < 1e-3 then return nil, "scope", earlyGot, lateGot, minBlend end

    local pts = {}
    for i = 2, #P - 1 do
        local s = cum[i]
        local w
        if s < sA then w = 0.5 - 0.5 * math.cos(math.pi * s / sA)
        elseif s > sB then w = 0.5 - 0.5 * math.cos(math.pi * (total - s) / (total - sB))
        else w = 1 end
        local a, b = P[i - 1], P[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local l = math.sqrt(dx * dx + dz * dz)
        local ox, oz = 0, 0
        if l > 1e-6 then
            local lx, lz = dz / l, -dx / l          -- LEFT of travel (see junctionSweepWide)
            ox, oz = lx, lz
            if leftTurn then ox, oz = -lx, -lz end  -- outside of a left turn is the right
        end
        pts[#pts + 1] = { x = P[i].x + ox * d * w, y = P[i].y, z = P[i].z + oz * d * w }
    end
    return { ax = P[1].x, ay = P[1].y, az = P[1].z, bx = P[#P].x, by = P[#P].y, bz = P[#P].z,
        points = pts, minRadius = con.minRadius, t = con.t, meetDist = con.meetDist,
        sweep = d, kickEarly = earlyGot, kickLate = lateGot }
end

function ADFlyoverEditor:junctionSolveMovement(fromAp, toAp, cx, cz, radius, turnR, rig)
    local floor = AutoDrive.FLYOVER_JUNCTION_TURN_MIN or 4
    local checkSurface = self.junctionCheckSurface ~= false
    local checkObstacles = self.junctionCheckObstacles ~= false
    local last, lastReason = nil, nil
    -- The design vehicle's own floor (docs/swept-path-spec.md §6, gate 1): a connector tighter than
    -- its full-lock radius is one the driver would understeer straight through, whatever the setting
    -- says. Candidates below it are not even tried.
    local rigFloor = (rig ~= nil and rig.minTurnRadius) or 0
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
        if con.minRadius < math.max(r * 0.7, rigFloor) then
            last, lastReason = con, "tight"
        elseif checkSurface and self:junctionCorridorTooOffRoad(con) then
            last, lastReason = con, "offroad"
        elseif checkObstacles and self:junctionObstacleHits(con) > 0 then
            -- A static obstacle in the corridor: a smaller radius swings a different line, so the
            -- same shrink search doubles as first-order avoidance; nothing clear down to the floor
            -- is a verbose red refusal, never a connector through a tree.
            last, lastReason = con, "blocked"
        else
            -- Swept-path gate (spec §6, gates 2-3), only with a design rig (locked site, toggle on):
            -- drive the rig through this candidate and probe the road and the obstacles under where
            -- its bodies actually go. The prediction rides on the connector so the preview draws it
            -- without a second simulation.
            local sw = nil
            if rig ~= nil and SweptSim ~= nil then
                local ok, res = pcall(function() return self:junctionSweptPredict(fromAp, toAp, con, cx, cz, radius, rig) end)
                if ok then sw = res else roadNote("sweptErr", "swept-path prediction failed: %s", tostring(res)) end
                con.swept = sw
            end
            local function sweptVerdict(s)
                if s == nil then return nil end
                if checkSurface and self:junctionSweptOffRoad(s) then return "trailerRoad" end
                if checkObstacles and self:junctionSweptHits(s, rig) > 0 then return "trailerHit" end
                return nil
            end
            local verdict = sweptVerdict(sw)
            if verdict == nil then
                return con, r, nil
            end
            -- SWEEP WIDE before giving up on this radius: push the curve outward in steps and
            -- re-judge. A wider line at the SAME radius beats a tighter radius - the rig cuts in
            -- from wherever the line is, so moving the line out moves the bodies back onto the road
            -- and away from whatever stands on the inside. Each shifted line must itself stay on the
            -- road (corridor) and clear of obstacles - that is the outer-edge bound.
            local accepted = nil
            if sw ~= nil then
                local d = AutoDrive.FLYOVER_JUNCTION_SWEEP_STEP or 1.0
                while d <= (AutoDrive.FLYOVER_JUNCTION_SWEEP_MAX or 3.0) + 1e-6 do
                    -- The early/late KICKOUT first; the inside-the-curve blend only when the
                    -- kickout cannot fit (cramped scope, or a dead-end stem) - it recovers about a
                    -- third as much, but it is better than refusing.
                    local wide, why, gotE, gotL, need = self:junctionKickout(fromAp, toAp, con, d, sw.leftTurn, rig, cx, cz, radius, r)
                    if wide == nil then
                        if why == "scope" then
                            roadNote(string.format("kickScope:%d_%d", fromAp.wp.id, toAp.wp.id),
                                "junction - entry id=%d -> exit id=%d: not enough lane for an early/late kickout (%.0f m of lane before / %.0f m after the curve inside the work region, %.0f m needed for a %.0f m kickout) - using the inside-the-curve blend instead.",
                                fromAp.wp.id, toAp.wp.id, gotE or 0, gotL or 0, need or 0, d)
                        end
                        wide = junctionSweepWide(con, d, sw.leftTurn)
                    end
                    if wide == nil then break end
                    local lineOk = not (checkSurface and self:junctionCorridorTooOffRoad(wide))
                        and not (checkObstacles and self:junctionObstacleHits(wide) > 0)
                    if lineOk then
                        local ok, res = pcall(function() return self:junctionSweptPredict(fromAp, toAp, wide, cx, cz, radius, rig) end)
                        if ok and res ~= nil then
                            wide.swept = res
                            if sweptVerdict(res) == nil then accepted = wide; break end
                        end
                    end
                    d = d + (AutoDrive.FLYOVER_JUNCTION_SWEEP_STEP or 1.0)
                end
            end
            if accepted ~= nil then
                return accepted, r, nil
            end
            last, lastReason = con, verdict
        end
        r = r - 1
        if r < rigFloor - 1e-6 and r >= floor - 1e-6 then
            -- Nothing below the rig's floor can pass gate 1; report the last real attempt.
            break
        end
    end
    return last, math.max(floor, r + 1), lastReason
end

--- Place every NEW turn in the current preview: for each, lay OUR connector points between the entry
--- and exit lane nodes via junctionLayChain (deterministic links only; priority inherited from the
--- joined road), all under one undo snapshot. Existing turns and U-turns were already filtered out of
--- the matrix; radius/corridor refusals happened in the solve.
--- The lane chain from an approach's boundary node toward the intersection interior (out-edges for an
--- entry, incoming for an exit), boundary node first, staying within the scope. Also whether that lane
--- DEAD-ENDS inside the scope (no travel continuation) rather than passing through.
function ADFlyoverEditor:junctionChain(ap, cx, cz, radius, fresh)
    -- Chains are long now (the work region, not the search circle) and the solve asks for the same
    -- one for every candidate radius of every turn, so they are cached for the life of one preview
    -- solve (cleared at the top of updateJunctionPreview). PLACEMENT passes fresh = true: it splices
    -- tie nodes into the lanes as it goes, so every walk there must see the graph as it is now.
    local cache = self.junctionChainCache
    if not fresh and cache ~= nil and cache[ap] ~= nil then
        return cache[ap][1], cache[ap][2]
    end
    local chain, deadEnd = self:junctionChainWalk(ap, cx, cz, radius)
    if not fresh and cache ~= nil then cache[ap] = { chain, deadEnd } end
    return chain, deadEnd
end

function ADFlyoverEditor:junctionChainWalk(ap, cx, cz, radius)
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
    -- The chain starts at the approach's ANCHOR (its node at the edge of the work region), whose own
    -- travel bearing is chainBearing; ap.bearing stays the bearing where the search circle cut the
    -- track - near the junction - which is what the turn-angle decisions want.
    local cb = ap.chainBearing or ap.bearing
    local wdx, wdz = math.sin(cb), math.cos(cb)
    if not useOut then wdx, wdz = -wdx, -wdz end
    -- Iteration bound scales with the region: the tool's own laid curves are ~1 m apart, so a lane
    -- crossing a 60 m work region can be a couple of hundred nodes.
    -- CLEAR MODE ONLY: build mode keeps the walk it has always had - its tie-in and meeting-point
    -- geometry was tuned against it.
    local lookAhead = (self.junctionMode == "clear")
    -- A SIDE ROAD IS HELD TO A TIGHTER TEST. A lane with no opposite-direction lane on its own
    -- heading (taken far out, at the anchors) has no road to carry on along, so anything it could
    -- walk onto past a fork is a turn - even the 30 degree one at a skewed T, which under the
    -- general 35 was taken for road, marked never-clearable, and left the side road joined.
    local turnLimit = math.rad(35)
    if lookAhead then
        local mineB, partner = ap.chainBearing or ap.bearing, false
        for _, o in ipairs(self.junctionWalkApproaches or {}) do
            if o ~= ap and o.dir ~= ap.dir
                and junctionAngDiff(mineB, o.chainBearing or o.bearing) <= math.rad(20) then
                partner = true break
            end
        end
        if not partner then turnLimit = math.rad(15) end
    end
    local endedAtFork = false
    -- THE WAY BACK IN IS ALREADY KNOWN. The anchor was reached by following this lane outward from
    -- where the circle cut it, and a run long enough (it grows with the design rig's trailer) goes
    -- past the next junction up the road - round its connector, where there is only one way on, and
    -- out along another road. Walking back by "straightest on" then sails past that connector and
    -- never returns: the lane the circle cut was claimed by nobody and was cleared as wiring (a T
    -- lost one whole lane of its main road that way). So where the run's own next step is on
    -- offer it is taken - but only as a PREFERENCE among ways on the look-ahead has not called a
    -- turn, because when the circle cuts a connector the run begins ON that connector, and
    -- retracing it blindly would walk the lane straight back onto it.
    local prefer = {}
    if lookAhead and ap.runPath ~= nil and ap.runPath[#ap.runPath] == ap.wp then
        for i = #ap.runPath, 2, -1 do prefer[ap.runPath[i]] = ap.runPath[i - 1] end
    end
    for _ = 1, math.max(64, math.ceil(radius) * 4) do
        local list = useOut and (node.out or {}) or (node.incoming or {})
        local nextId, bestDot = nil, -math.huge
        -- WHERE THE ROAD ENDS AND THE WIRING BEGINS. At a fork, each way on is followed to the next
        -- thing it joins, and one that gets there turned more than 35 degrees from the lane's
        -- heading is a TURN, not the road - it is never walked as road. If EVERY way on is a turn,
        -- the lane's road ends at this node. That is the normal state of a built T's stem: the tool
        -- consumed the stem's road past its tie-in, so the only ways on from the tie node ARE the
        -- two turn connectors - and the walk, having to go somewhere, used to pick one and mark it
        -- road, which put it beyond the reach of every clear and left the stem's lanes ending on
        -- connector points the tidy could make nothing of.
        --
        -- Only at forks (a plain bend has one way on and is followed however sharp it is), and only
        -- near the junction: further out than this a fork belongs to something else - a field
        -- entrance, the next junction's kickout - and the lane must not be cut short there on the
        -- strength of a bend in the road beyond it.
        local turnsAway = nil
        if lookAhead and #chain > 1 and (node.x - cx) ^ 2 + (node.z - cz) ^ 2 <= 35 * 35 then
            local nWays, nTurns = 0, 0
            local verdict = {}
            for _, nid in pairs(list) do
                if nid ~= cameFrom and verdict[nid] == nil then
                    local nx = ADGraphManager:getWayPointById(nid)
                    if nx ~= nil then
                        nWays = nWays + 1
                        verdict[nid] = junctionBranchTurn(node, nx, useOut, wdx, wdz, 60) > turnLimit
                        if verdict[nid] then nTurns = nTurns + 1 end
                    end
                end
            end
            if nWays >= 2 then
                if nTurns == nWays then
                    endedAtFork = true
                    break
                end
                turnsAway = verdict
            end
        end
        for _, nid in pairs(list) do
            if nid ~= cameFrom and not (turnsAway ~= nil and turnsAway[nid]) then
                local nx = ADGraphManager:getWayPointById(nid)
                if nx ~= nil and (nx.x - cx) ^ 2 + (nx.z - cz) ^ 2 <= r2 then
                    local dx, dz = nx.x - node.x, nx.z - node.z
                    local l = math.sqrt(dx * dx + dz * dz)
                    if l > 1e-6 then
                        local dot = (dx / l) * wdx + (dz / l) * wdz
                        -- Fork tie-break: a KICKOUT leaves its lane almost tangentially (that is the
                        -- point of it), so at its tie node the lane's continuation and the kickout's
                        -- first point can be within a degree or two of each other - and on a gently
                        -- curving lane the kickout can even be the straighter. Waypoint ids are
                        -- handed out in creation order and deletion compacts them without reordering,
                        -- so the OLDER node (lower id) is the road and the newer one the wiring laid
                        -- onto it: within a small margin, the lower id wins.
                        -- The band is 0.15 (about 30 degrees at small angles): wide enough that a
                        -- connector carrying STRAIGHT on where the lane itself bends a little at the
                        -- tie node still loses to the lane; narrow enough that a real fork of two
                        -- old roads, one clearly straighter, is still decided by bearing.
                        if dot > bestDot + 0.15 or (dot > bestDot - 0.15 and nextId ~= nil and nid < nextId) then
                            bestDot, nextId = math.max(dot, bestDot), nid
                        elseif nextId == nil then
                            bestDot, nextId = dot, nid
                        end
                    end
                end
            end
        end
        -- A lane does not turn through 70 degrees at one node. Where the only way on does, this
        -- track has ENDED against another road (a stem meeting its crossbar with a direct link) and
        -- walking on would follow that other road - merging two lanes into one lane group and
        -- putting the meeting point, tangents and tie-ins on the wrong track.
        local want = prefer[node]
        if want ~= nil and want.id ~= nil and want.id ~= cameFrom and table.contains(list, want.id)
            and ADGraphManager:getWayPointById(want.id) == want
            and not (turnsAway ~= nil and turnsAway[want.id])
            and (want.x - cx) ^ 2 + (want.z - cz) ^ 2 <= r2 then
            nextId, bestDot = want.id, 1
        end
        if nextId == nil or (#chain > 1 and bestDot < 0.3) then break end
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
    -- A lane the look-ahead ended has nowhere to go AS ROAD, whatever wiring still hangs off it.
    if endedAtFork then continues = false end
    return chain, (not continues)
end

--- Create the tie-in node at the tangent point (Tx,Tz) on an approach's track and splice it in. A
--- through-road keeps both sides (insert). A dead-end keeps only the outer side and returns the stub
--- past the tie-in for the caller to consume (deleted LAST, since removeWayPoint renumbers ids). The
--- new node inherits the track's priority flags. Returns the node, its priority flags, the stub, and
--- whether the LOCAL track at the tie-in is itself two-way - the caller uses this (both ends must
--- agree) to decide whether the new connector should be dual too, instead of always one-way.
function ADFlyoverEditor:junctionTieIn(ap, Tx, Tz, cx, cz, radius)
    local chain, deadEnd = self:junctionChain(ap, cx, cz, radius, true)
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
    -- A lock is a fresh report: the once-per-key notes start over, so locking the same crossing a
    -- second time (a different circle, a changed setting) logs every track, refusal and kickout
    -- again instead of only what differs from the last time.
    for k in pairs(roadProbeNoted) do roadProbeNoted[k] = nil end
    -- The radius is in this line because "I set it to 20" and "the solve behaved like 15" are
    -- otherwise indistinguishable in a log, and that ambiguity cost a whole test cycle.
    Logging.info("[FlyoverEditor]: junction site locked at %.1f, %.1f - %s, turn radius %.0f m, mode %s. Right-click %s.",
        self.cursorX, self.cursorZ,
        (self.junctionMode == "clear")
            and string.format("scope %.0f m (fixed: the junction sets it, not the wheel)",
                AutoDrive.FLYOVER_JUNCTION_CLEAR_SCOPE or 14)
            or string.format("search radius %.0f m, wheel = scope", self:junctionRadiusValue()),
        self.junctionTurnRadius or 12,
        self.junctionMode or "build", (self.junctionMode == "clear") and "clears" or "places")
end

--- Place every NEW turn in the preview (behaviour A): tie in at each track's tangent point (insert on a
--- through-road, trim a dead-end back to it), lay the radius-R arc one-way from entry to exit, priority
--- matched to the joined (exit) road, all under one undo. Dead-end stubs are consumed at the very end.
--- Clear mode's placement: sever this junction's stale direct links and remove its debris cluster -
--- filtered to turns only when "leave through paths" is on - and lay NOTHING. The roads themselves
--- (skeleton) are never touched by construction (see the debris pass in updateJunctionPreview); this
--- only ever removes nodes/links that pass were already the debris test.
--- Tidy the lane ends after a clear: every lane that now DEAD-ENDS at the junction is trimmed back or
--- run forward so it stops FLYOVER_JUNCTION_STUB_GAP from the centre of the tracks, with anything
--- added laid at that lane's own spacing and landing exactly on the gap. A cleared T then reads as
--- three tidy stubs around an even gap instead of three ragged ends at whatever distance the debris
--- happened to reach.
---
--- A lane still running THROUGH the junction does not dead-end, so it is skipped - which is why this
--- needs no switch of its own. With "leave through paths" on, the through road is left exactly as it
--- was; turn it off and it dead-ends too, and is tidied like the stem.
---
--- Only genuine dangling ends are touched: if the walk stops because the lane turns hard into another
--- road that it is still LINKED to, that end still "continues" and is left alone. Trimming there
--- would cut a live connection, not tidy a stub.
--- Returns points trimmed, points added, lanes touched.
--- With `dry` set, changes nothing and instead returns where every end WOULD land, plus the claim
--- bands they are measured against, for the preview to draw. Same code path either way - the preview
--- cannot drift from the apply, which is where most of this feature's confusion came from. In dry
--- mode the walk treats the debris as already gone, because that is the graph the real tidy sees.
function ADFlyoverEditor:junctionTidyLaneEnds(jp, dry)
    local skip, cut = {}, {}
    if dry then
        local leave = self.junctionLeaveThrough ~= false
        -- Exactly what the apply will delete, no more: the turn wiring, plus - with through paths
        -- set to clear - the through route's wiring but NOT its road. Skipping all of debris here
        -- had the preview walking a graph with the road removed, which the apply never produces.
        for _, w in ipairs(jp.turnDebris or {}) do skip[w.id] = true end
        if not leave then
            local keep = jp.runNodes or {}
            for _, w in ipairs(jp.throughDebris or {}) do
                if not keep[w] then skip[w.id] = true end
            end
        end
        -- The apply severs the stale links BEFORE it deletes anything, so a dry run that ignores
        -- them walks over joins that will not be there. Both directions: severing is unconditional.
        for _, pair in ipairs(jp.staleLinks or {}) do
            local a, b = pair[1], pair[2]
            if a ~= nil and b ~= nil and not (leave and pair.isThrough) then
                cut[a.id * 100000 + b.id] = true
                cut[b.id * 100000 + a.id] = true
            end
        end
        -- The through-route cuts too, when that toggle is off. Modelling only the stale links would
        -- leave the preview walking over joins the apply is about to sever.
        if not leave then
            for _, pair in ipairs(jp.throughLinks or {}) do
                local a, b = pair[1], pair[2]
                if a ~= nil and b ~= nil then
                    cut[a.id * 100000 + b.id] = true
                    cut[b.id * 100000 + a.id] = true
                end
            end
        end
    end
    local centre = jp.tracksCentre
    -- The early return has to answer in the SHAPE the caller expects: a dry run is handed two
    -- tables and a real one three counts. Returning counts to a dry caller put a number where the
    -- drawing expected a list, and the preview threw on every frame.
    if centre == nil then
        if dry then return {}, {}, {}, {} end
        return 0, 0, 0
    end
    local gap = AutoDrive.FLYOVER_JUNCTION_STUB_GAP or 4
    local function dist(w) return math.sqrt((w.x - centre.x) ^ 2 + (w.z - centre.z) ^ 2) end
    -- Ids are renumbered by every removal, so a held id can silently come to mean a DIFFERENT node.
    -- Identity is the object; the id is only how the graph is asked for it.
    -- In a dry run "removed" means "in the skip set": nothing is really deleted, so a node this
    -- run has already trimmed has to read as gone or the next lane sharing it behaves differently
    -- from the real thing. Two approaches that share a tail did exactly that - the real run tidied
    -- the tail once and skipped the second lane, the preview tidied it twice and promised an end
    -- that never appeared.
    local function alive(w)
        return w ~= nil and w.id ~= nil and w.id >= 0 and not skip[w.id]
            and ADGraphManager:getWayPointById(w.id) == w
    end
    -- Arc-length sampling along a captured alignment, so the run-in can be re-laid at even spacing
    -- ALONG THE ROAD rather than along a chord across it.
    local function cumulative(pts)
        local cum = { 0 }
        for i = 2, #pts do
            local a, b = pts[i - 1], pts[i]
            cum[i] = cum[i - 1] + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        end
        return cum
    end
    local function atArc(pts, cum, s)
        if s <= 0 then return pts[1] end
        if s >= cum[#cum] then return pts[#pts] end
        for i = 2, #pts do
            if cum[i] >= s then
                local a, b = pts[i - 1], pts[i]
                local t = (s - cum[i - 1]) / math.max(1e-6, cum[i] - cum[i - 1])
                return { x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t,
                    y = (a.y or 0) + ((b.y or 0) - (a.y or 0)) * t }
            end
        end
        return pts[#pts]
    end
    -- The arc the lane was ALREADY DESCRIBING, as a polyline out of the tip: its heading there, bent
    -- at the curvature measured over the last ~20 m of real road. Following the lane's own captured
    -- geometry instead would be tempting and exact, but past the run's end that geometry IS the
    -- junction wiring - it would run the lane down a connector and onto another road. Twenty metres
    -- is long enough to average out waypoint jitter and short enough to still be the corner the lane
    -- is actually in.
    -- The arc the lane was ALREADY DESCRIBING, as a polyline out of its end.
    --
    -- Curvature is read from THREE POINTS spanning about 10 m, and then read again from triples
    -- further back, so the RATE of change is known too. A road entering a bend is on a transition
    -- spiral - its curvature is still growing - and continuing at whatever it happened to be at the
    -- last node either undershoots the bend or overshoots the straight. Extrapolating the rate
    -- follows the road in; a single triple assumes the curve has already settled.
    --
    -- Following the lane's own captured geometry instead would be exact, but past the end of the
    -- road that geometry IS the junction wiring - it would run the lane down a connector and onto
    -- another road.
    local ARC_SPAN = 10
    local function laneArc(seq, tip, prev, grade, straight)
        local hx, hz = tip.x - prev.x, tip.z - prev.z
        local hl = math.sqrt(hx * hx + hz * hz)
        if hl < 1e-3 then return nil end
        hx, hz = hx / hl, hz / hl

        -- Arc length back from the end, so triples can be taken at real distances rather than at
        -- whatever spacing this lane happens to use.
        local back = { [#seq] = 0 }
        for i = #seq - 1, 1, -1 do
            back[i] = back[i + 1] + math.sqrt((seq[i + 1].x - seq[i].x) ^ 2
                + (seq[i + 1].z - seq[i].z) ^ 2)
        end
        local function atBack(d)
            for i = #seq, 1, -1 do
                if back[i] >= d then return seq[i] end
            end
            return nil
        end
        -- Signed curvature of the circle through three points: twice the triangle's area over the
        -- product of its sides.
        local function triple(d)
            local c, b, a = atBack(d), atBack(d + ARC_SPAN * 0.5), atBack(d + ARC_SPAN)
            if a == nil or b == nil or c == nil then return nil end
            local ax, az = b.x - a.x, b.z - a.z
            local bx, bz = c.x - b.x, c.z - b.z
            local cx2, cz2 = c.x - a.x, c.z - a.z
            local la = math.sqrt(ax * ax + az * az)
            local lb = math.sqrt(bx * bx + bz * bz)
            local lc = math.sqrt(cx2 * cx2 + cz2 * cz2)
            if la < 1e-3 or lb < 1e-3 or lc < 1e-3 then return nil end
            return 2 * (ax * bz - az * bx) / (la * lb * lc)
        end

        local LIMIT = 1 / 12   -- a road does not turn tighter than a 12 m radius on its own
        local k0 = triple(0)
        if k0 == nil then k0 = 0 end
        k0 = math.max(-LIMIT, math.min(LIMIT, k0))
        -- THE CHORD IS NOT THE TANGENT. The heading above is the direction from `prev` to `tip`,
        -- which on a curving road is where the road pointed HALFWAY between them, not where it
        -- points at `tip`. The arc then sets off along a line the road has already turned away
        -- from, and since this line becomes the road's claim band, the box turns with it: at one
        -- T the side road's band came out 19 degrees off and the whole box sat up the road from
        -- where the two roads actually meet.
        --
        -- For an arc the correction is exact and already to hand: turn the chord on by half the
        -- angle the arc covers over it. A straight road has k0 = 0 and is untouched.
        if k0 ~= 0 then
            local half = k0 * hl * 0.5
            local cs, sn = math.cos(half), math.sin(half)
            hx, hz = hx * cs - hz * sn, hx * sn + hz * cs
        end
        -- Carried STRAIGHT when asked: a side road with no through partner keeps its own heading.
        if straight then k0 = 0 end
        -- Is the bend tightening or easing? Read two more triples further back and take the trend
        -- per metre. Only trusted when both agree in sign with the step between them, so noise in a
        -- single reading cannot invent a spiral.
        local rate = 0
        local k1, k2 = triple(ARC_SPAN * 0.5), triple(ARC_SPAN)
        if k1 ~= nil and k2 ~= nil then
            local d1 = (k0 - k1) / (ARC_SPAN * 0.5)
            local d2 = (k1 - k2) / (ARC_SPAN * 0.5)
            if d1 * d2 > 0 and not straight then
                rate = (math.abs(d1) < math.abs(d2)) and d1 or d2
                rate = math.max(-LIMIT / 20, math.min(LIMIT / 20, rate))
            end
        end

        local pts = { { x = tip.x, y = tip.y or 0, z = tip.z } }
        local px, pz, ds = tip.x, tip.z, 0.25
        for i = 1, math.floor(30 / ds) do
            local s = i * ds
            local k = math.max(-LIMIT, math.min(LIMIT, k0 + rate * s))
            local dth = k * ds
            local cs, sn = math.cos(dth), math.sin(dth)
            hx, hz = hx * cs - hz * sn, hx * sn + hz * cs
            px, pz = px + hx * ds, pz + hz * ds
            pts[#pts + 1] = { x = px, y = (tip.y or 0) + grade * s, z = pz }
        end
        return pts
    end

    -- Walk a lane in from its outer anchor on bearing continuity, the same way the chain walk does,
    -- so a fork at an old tie node takes the ROAD on and not some surviving scrap of wiring.
    local gateCentre = nil
    local function walkLane(ap)
        local useOut = (ap.dir == "in")
        local node = ap.wp
        local cb = ap.chainBearing or ap.bearing or 0
        local wdx, wdz = math.sin(cb), math.cos(cb)
        if not useOut then wdx, wdz = -wdx, -wdz end
        local seq, cameFrom = { node }, nil
        for _ = 1, 400 do
            local list = useOut and (node.out or {}) or (node.incoming or {})
            local nextNode, bestDot = nil, -math.huge
            for _, nid in pairs(list) do
                -- `skip` is empty for the real run and holds the debris for a dry one, so the
                -- preview walks the graph the clear is ABOUT to leave rather than the one in front
                -- of it. Without this the walk crosses the junction over nodes that are about to go.
                if nid ~= cameFrom and not skip[nid] and not cut[node.id * 100000 + nid] then
                    local nx = ADGraphManager:getWayPointById(nid)
                    if nx ~= nil then
                        local dx, dz = nx.x - node.x, nx.z - node.z
                        local l = math.sqrt(dx * dx + dz * dz)
                        if l > 1e-6 then
                            local dot = (dx / l) * wdx + (dz / l) * wdz
                            if dot > bestDot then bestDot, nextNode = dot, nx end
                        end
                    end
                end
            end
            if nextNode == nil then break end
            if #seq > 1 and bestDot < 0.3 then break end
            cameFrom = node.id
            local dx, dz = nextNode.x - node.x, nextNode.z - node.z
            local l = math.sqrt(dx * dx + dz * dz)
            if l > 1e-6 then wdx, wdz = dx / l, dz / l end
            node = nextNode
            seq[#seq + 1] = node
        end
        -- DOES THIS LANE STILL RUN THROUGH? Asked structurally: can the walk go anywhere from
        -- here that is not where it came from and not about to be cleared. A lane that runs through
        -- always can; one that now dead-ends at the junction cannot, and that end is what gets
        -- tidied.
        --
        -- This used to be a proxy - "distance to the centre started increasing while within 16 m" -
        -- and on a curving approach it tripped about 10 m out, before the lane ever reached the
        -- junction. Worse, it gave DIFFERENT answers before and after the deletion: the real apply
        -- walked a graph where the lane genuinely ended first, so it never tripped, while the same
        -- code run as a preview rejected 7 of 8 lanes. A structural test cannot drift that way.
        local onward = useOut and (seq[#seq].out or {}) or (seq[#seq].incoming or {})
        local continues = false
        for _, nid in pairs(onward) do
            if nid ~= cameFrom and not skip[nid]
                and not cut[seq[#seq].id * 100000 + nid] then continues = true break end
        end
        -- AND THE END HAS TO BE AT THIS JUNCTION. The walk runs from the far anchor inward and
        -- tidies wherever it stops - but if a NEIGHBOURING junction has already been cleared, the
        -- lane now dead-ends at that neighbour's gap, the walk stops there, and the tidy trims the
        -- neighbour's mouth instead of this one's. Nothing else notices, because a dead end is a
        -- dead end wherever it is.
        local tip = seq[#seq]
        -- Measured from the BOX centre once it is known: the locked centre can sit 12 m to one
        -- side of a skewed junction, which put the far arm's ends 27 m "away" and outside this gate,
        -- so they were never brought in.
        local gc = gateCentre or centre
        local atThis = (tip.x - gc.x) ^ 2 + (tip.z - gc.z) ^ 2 <= 25 * 25
        return { ap = ap, seq = seq, useOut = useOut, cameFrom = cameFrom,
            tidy = (not continues) and #seq >= 2 and atThis,
            reference = continues }
    end

    -- PASS 1: walk every lane and sort them into those still running THROUGH the junction and those
    -- that now dead-end at it. Nothing is changed yet, because the through lanes are the reference
    -- the dead-ends get measured against and it has to be read before anything moves.
    local walked = {}
    for _, ap in ipairs(jp.approaches or {}) do
        if alive(ap.wp) and not skip[ap.wp.id] then walked[#walked + 1] = walkLane(ap) end
    end

    -- WHAT A TAIL STOPS AT: the other lanes' centrelines, each carried ACROSS the junction on its
    -- own arc. The surviving road stops short of the middle, so measuring only to what is left would
    -- have a tail chase the far side's stub and run straight through where the road used to be.
    -- Continuing each road over the gap on the curve it was already describing puts the reference
    -- back where the carriageway actually is.
    -- Each lane's line is fitted to its PARENT ROAD only, then carried on across the junction by the
    -- arc that road was already describing. The run set is the tool's own answer to "which of these
    -- nodes are road" - anchor in to the last fork - so the tie-ins and laid curves past it are
    -- excluded. Fitting the raw walk instead picked up the connectors: with through paths kept, a
    -- lane that runs through does so over the tool's OWN laid curve rather than over road, and that
    -- curve's geometry ended up defining where the road supposedly was.
    local runSet = jp.runNodes or {}
    for _, w in ipairs(walked) do
        if w.ap.roadLine ~= nil then w.line, w.realLine = w.ap.roadLine, true end
    end
    for _, w in ipairs(walked) do
        local road, k = {}, 0
        for i, n in ipairs(w.seq) do
            if runSet[n] then k = i end
        end
        if k < 2 then k = math.min(#w.seq, 2) end
        -- A LANE WITH NO THROUGH PARTNER ENDS AT ITS FIRST FORK NEAR THE JUNCTION. At a skewed T the
        -- side road's turn onto the main road bends only 30 degrees, the walk takes it for road,
        -- and the side road's "line" ran on down the main road - bending its box round the corner.
        -- Its road is what comes BEFORE the wiring starts; from there it is carried straight.
        local straightCarry = (w.line == nil)   -- no through partner: carried on its own heading, preview and apply alike
        if w.line == nil then
            for i = 2, k do
                local n = w.seq[i]
                if (n.x - centre.x) ^ 2 + (n.z - centre.z) ^ 2 <= 25 * 25 then
                    local seen, deg = {}, 0
                    for _, lst in ipairs({ n.out or {}, n.incoming or {} }) do
                        for _, id in pairs(lst) do if not seen[id] then seen[id] = true deg = deg + 1 end end
                    end
                    if deg >= 3 then k = i straightCarry = true break end
                end
            end
        end
        -- Only reached by a road that ENDS at this junction - a through road has its real line
        -- already. It has to be carried across, and it is carried from its CLEAN stretch: the last
        -- few metres of a lane are where old tie-ins and re-laid ends bend things, and reading the
        -- heading off that tip gave one T's stem a band at 162 degrees where the stem runs at 110.
        -- So the line stops 8 m short of the junction and its heading is taken over the ten metres
        -- before that, not over one segment.
        while k > 2 and (w.seq[k].x - centre.x) ^ 2 + (w.seq[k].z - centre.z) ^ 2 < 8 * 8 do
            k = k - 1
        end
        for i = 1, k do
            local n = w.seq[i]
            if (n.x - centre.x) ^ 2 + (n.z - centre.z) ^ 2 <= 35 * 35 then
                road[#road + 1] = { x = n.x, z = n.z }
            end
        end
        if k >= 2 then
            local sub = {}
            for i = 1, k do sub[i] = w.seq[i] end
            local base, run = k - 1, 0
            while base > 1 and run < 10 do
                run = run + math.sqrt((sub[base + 1].x - sub[base].x) ^ 2 + (sub[base + 1].z - sub[base].z) ^ 2)
                if run < 10 then base = base - 1 end
            end
            local arc = laneArc(sub, sub[k], sub[base], 0, straightCarry)
            for i = 2, (arc ~= nil) and #arc or 0 do
                if (arc[i].x - centre.x) ^ 2 + (arc[i].z - centre.z) ^ 2 <= 35 * 35 then
                    road[#road + 1] = { x = arc[i].x, z = arc[i].z }
                end
            end
        end
        if w.line == nil and #road >= 2 then w.line = road end
    end
    -- ONE SET OF ROAD LINES, MEASURED ONCE. The preview reads each lane's line off the junction as
    -- it stands; the apply used to read them again AFTER the clear had deleted half the wiring, and
    -- got different lines - a side road's claim that ran on down the main road because its turn
    -- connector happened to still be there. The box the ends were brought to was then not the box
    -- the preview had drawn. The preview's lines are kept and the apply lays its ends against
    -- exactly those.
    if dry then
        jp._tidyLines = {}
        for _, w in ipairs(walked) do
            jp._tidyLines[w.ap] = { line = w.line, real = w.realLine }
        end
    elseif jp._tidyLines ~= nil then
        for _, w in ipairs(walked) do
            local kept = jp._tidyLines[w.ap]
            if kept ~= nil and kept.line ~= nil then w.line, w.realLine = kept.line, kept.real end
        end
    end


    local function nearestOn(line, px, pz)
        local bx, bz, best = nil, nil, math.huge
        for k = 2, #line do
            local ax, az = line[k - 1].x, line[k - 1].z
            local vx, vz = line[k].x - ax, line[k].z - az
            local L2 = vx * vx + vz * vz
            if L2 > 1e-9 then
                local t = math.max(0, math.min(1, ((px - ax) * vx + (pz - az) * vz) / L2))
                local qx, qz = ax + vx * t, az + vz * t
                local d = (px - qx) ^ 2 + (pz - qz) ^ 2
                if d < best then best, bx, bz = d, qx, qz end
            end
        end
        if bx == nil then return nil, math.huge end
        return { x = bx, z = bz }, math.sqrt(best)
    end
    local function lineDist(line, px, pz)
        local _, d = nearestOn(line, px, pz)
        return d
    end
    local function lineDir(line)
        local a, b = line[1], line[#line]
        local vx, vz = b.x - a.x, b.z - a.z
        local l = math.sqrt(vx * vx + vz * vz)
        if l < 1e-6 then return nil end
        return vx / l, vz / l
    end

    -- THE PARENT ROADS, AND THE BOX THEY MAKE.
    --
    -- A road through a junction is normally a PAIR of parallel tracks, one per direction. Pair them,
    -- measure how far apart they are, and merge them into one line: that merged line is the centre of
    -- the road. The box is then simply that centre offset either side by the distance the tracks were
    -- apart. The road states its own width, so there is no margin to tune and nothing that has to be
    -- told what kind of junction this is.
    --
    -- A road with a single track has no separation to measure, so it takes a fixed offset.
    local SINGLE = AutoDrive.FLYOVER_JUNCTION_TRACK_CLEARANCE or 2.5
    -- Each track is compared AT THE JUNCTION - the point on it nearest the centre of the tracks, and
    -- the way it runs there. Comparing whole lines instead compares them at their outer anchors 45 m
    -- out, where two tracks of one road have long since diverged, and one road comes back as several.
    for _, w in ipairs(walked) do
        if w.line ~= nil and #w.line >= 2 then
            local bi, bd = nil, math.huge
            for k, pt in ipairs(w.line) do
                local d = (pt.x - centre.x) ^ 2 + (pt.z - centre.z) ^ 2
                if d < bd then bd, bi = d, k end
            end
            -- Over about 8 m either side. Three indices either side is 1.5 m on an arc sampled at
            -- 0.25 m and could be 30 m on a recorded road - either way not a heading to trust.
            local function reach(from, step)
                local i, run = from, 0
                while run < 8 do
                    local j = i + step
                    if j < 1 or j > #w.line then break end
                    run = run + math.sqrt((w.line[j].x - w.line[i].x) ^ 2 + (w.line[j].z - w.line[i].z) ^ 2)
                    i = j
                end
                return w.line[i]
            end
            local a, b = reach(bi, -1), reach(bi, 1)
            local vx, vz = b.x - a.x, b.z - a.z
            local l = math.sqrt(vx * vx + vz * vz)
            if l > 1e-6 then
                w.at, w.hx, w.hz = w.line[bi], vx / l, vz / l
            end
        end
    end

    local roads = {}
    for _, w in ipairs(walked) do
        if w.at ~= nil then
            local joined = nil
            for _, r in ipairs(roads) do
                -- Same road: running the same way, or the opposite way, which is the other direction
                -- of the same carriageway. Abreast of each other rather than nose to tail.
                if math.abs(r.hx * w.hx + r.hz * w.hz) > 0.85 then
                    local ox, oz = w.at.x - r.at.x, w.at.z - r.at.z
                    if math.abs(ox * -r.hz + oz * r.hx) < 12
                        and math.abs(ox * r.hx + oz * r.hz) < 12 then
                        joined = r break
                    end
                end
            end
            if joined == nil then
                roads[#roads + 1] = { hx = w.hx, hz = w.hz, at = w.at, real = (w.realLine == true),
                    members = { w.line }, tracks = { w }, lanes = { [w] = true } }
            else
                joined.members[#joined.members + 1] = w.line
                joined.tracks[#joined.tracks + 1] = w
                joined.lanes[w] = true
            end
        end
    end

    -- Merge each road's tracks into one line, and take the offset from HOW FAR APART THEY ARE: the
    -- widest gap across the road. The max and not the mean, because a road entered from both ends
    -- contributes the same track twice and those duplicates sit on top of each other - averaging
    -- them in drags the width towards nothing.
    --
    -- MEASURED ALONG THE ROAD, NOT AT THE JUNCTION. One sample, taken where the track meets the
    -- junction, is taken at the one place a road is not its own width: the lanes are already
    -- pinching together or flaring apart for the turns. Measured out to 25 m, every road on the test
    -- map holds its width to within a few centimetres from 3 m out to 30 m - except where the single
    -- sample landed in a pinch and called a 3.9 m road 3.06 m wide, which is what tilted the box and
    -- pushed the cut off to one side. The same road read 2.50 m one way and 4.23 m the other.
    --
    -- So it is sampled at intervals along the road and the MIDDLE reading is kept. The middle, not
    -- the average: a pinch at one end drags an average, and cannot move the middle.
    local WNEAR, WFAR = 8, 30
    local jctX, jctZ = centre.x, centre.z
    for _, r in ipairs(roads) do
        -- The road's own first track is the spine. Every OTHER track is measured against it, at each
        -- of its vertices that lies between WNEAR and WFAR from the junction - so the reading follows
        -- the road round its bends instead of marching off a straight heading, which on a curving
        -- road walks clean off the track within a few metres.
        local spine = r.members[1]
        local reads = {}
        if spine ~= nil and #r.members >= 2 then
            for _, p in ipairs(spine) do
                -- MEASURED OUT FROM THE MIDDLE OF THE JUNCTION, not from the road's anchor. A road's
                -- line runs THROUGH the junction, so "4 to 25 m from the anchor" also catches the
                -- stretch on the far side of it - and near the middle the lanes converge into their
                -- connectors. Half of one road's 95 readings fell below 2.5 m that way and its width
                -- came out on the single-track floor, giving a box far too narrow for a two-lane road.
                local dj = math.sqrt((p.x - jctX) ^ 2 + (p.z - jctZ) ^ 2)
                if dj >= WNEAR and dj <= WFAR then
                    local widestHere = 0
                    for k = 2, #r.members do
                        local line = r.members[k]
                        local bd = math.huge
                        for i2 = 1, #line - 1 do
                            local a, b = line[i2], line[i2 + 1]
                            local ax, az = b.x - a.x, b.z - a.z
                            local L = ax * ax + az * az
                            local u = (L > 0) and ((p.x - a.x) * ax + (p.z - a.z) * az) / L or 0
                            u = math.max(0, math.min(1, u))
                            local ex, ez = a.x + ax * u - p.x, a.z + az * u - p.z
                            local dd = ex * ex + ez * ez
                            if dd < bd then bd = dd end
                        end
                        bd = math.sqrt(bd)
                        if bd > widestHere then widestHere = bd end
                    end
                    if widestHere > 0 then reads[#reads + 1] = widestHere end
                end
            end
        end
        local widest = 0
        if #reads >= 3 then
            -- HIGH UP THE READINGS, NOT THE MIDDLE OF THEM. A road's line runs both ways from the
            -- junction and the two halves need not be the same road: at one site it is two lanes
            -- 3.8 m apart to the south-east and a pair merging into one - 2.3 m, then 1.4 m - to the
            -- north-west. The middle of all of them came out on the single-track floor and the box
            -- was built far too narrow for the lanes it had to cover. The claim band has to cover
            -- the road where it is WIDEST near the junction, so the reading four fifths of the way
            -- up is taken: a merging half cannot drag it down, and one wide stray cannot lift it.
            table.sort(reads)
            widest = reads[math.max(1, math.floor(#reads * 0.8))]
        else
            for _, t in ipairs(r.tracks) do
                local ox, oz = t.at.x - r.at.x, t.at.z - r.at.z
                local perp = math.abs(ox * -r.hz + oz * r.hx)
                if perp > widest then widest = perp end
            end
        end
        r.offset = math.max(SINGLE, widest)
        if #r.members == 1 then
            r.centre = r.members[1]
        else
            local base, merged = r.members[1], {}
            for _, pt in ipairs(base) do
                local sx, sz, c = pt.x, pt.z, 1
                local votes = {}
                for k = 2, #r.members do
                    local q, d = nearestOn(r.members[k], pt.x, pt.z)
                    -- ONE VOTE PER TRACK. A road entered from both ends hands in the same
                    -- track twice (its entry and its exit walk the same lane), and averaging the
                    -- duplicate in pulled the "centre" half a metre towards that lane - so one
                    -- track of every through road was laid 0.5 m inside its own line and the
                    -- other 0.5 m outside: a sideways kick on the end of each.
                    if q ~= nil and d < 25 then
                        local dup = (d < 0.75)
                        for _, v in ipairs(votes) do
                            if (v.x - q.x) ^ 2 + (v.z - q.z) ^ 2 < 0.75 * 0.75 then dup = true break end
                        end
                        if not dup then
                            votes[#votes + 1] = q
                            sx, sz, c = sx + q.x, sz + q.z, c + 1
                        end
                    end
                end
                merged[#merged + 1] = { x = sx / c, z = sz / c }
            end
            r.centre = (#merged >= 2) and merged or base
        end
    end

    -- THE JUNCTION IS WHERE THE ROADS CROSS, not where the tie nodes happen to cluster.
    --
    -- `centre` is the locked crossing: a centroid of fork nodes. At a 4-way those sit all round the
    -- middle and the centroid is the middle. At a built T they can be just the STEM'S two tie nodes -
    -- and then the "centre" sits at the stem's tip, 10 m short of the road it meets. Everything that
    -- looks for the box from there found nothing: the box-edge search starts from the point nearest
    -- the centre and asks whether it is inside the other road's claim (it was not, by 5 m), the box
    -- sweep reached 10 m from the wrong place, and the stem was never brought up to the road.
    --
    -- The roads are known by now, each as a centre line carried across the junction, so the middle
    -- of the box is simply where two of them that are not parallel cross - the crossing nearest the
    -- locked point, since two roads can meet again further out.
    local boxCentre = centre
    -- The two roads whose crossing IS this junction. Only their claims make its box.
    local boxRoadA, boxRoadB = nil, nil
    do
        local best, bestD = nil, math.huge
        for i = 1, #roads do
            for j = i + 1, #roads do
                local a, b = roads[i], roads[j]
                if a.centre ~= nil and b.centre ~= nil and #a.centre >= 2 and #b.centre >= 2
                    and math.abs(a.hx * b.hx + a.hz * b.hz) <= 0.85 then
                    local cum = cumulative(a.centre)
                    local at = 0
                    while at <= cum[#cum] do
                        local pt = atArc(a.centre, cum, at)
                        local dc = (pt.x - centre.x) ^ 2 + (pt.z - centre.z) ^ 2
                        if dc < bestD and lineDist(b.centre, pt.x, pt.z) <= 0.5 then
                            bestD, best = dc, pt
                            boxRoadA, boxRoadB = a, b
                        end
                        at = at + 0.25
                    end
                end
            end
        end
        if best ~= nil and bestD <= 25 * 25 then boxCentre = { x = best.x, z = best.z } end
        gateCentre = boxCentre
        -- The lanes were walked before the box was known; judge their ends again from its middle.
        for _, w in ipairs(walked) do
            local tip = w.seq[#w.seq]
            if tip ~= nil and not w.reference and #w.seq >= 2 then
                w.tidy = (tip.x - boxCentre.x) ^ 2 + (tip.z - boxCentre.z) ^ 2 <= 25 * 25
            end
        end
    end

    -- Inside the box: within its own road's offset of that road's centre. A lane never measures
    -- against the road it is itself part of.
    local function insideBox(px, pz, self_)
        -- The lane's own road, so a road running alongside it can be told from one it meets.
        local own = nil
        for _, r in ipairs(roads) do if r.lanes[self_] then own = r break end end
        for _, r in ipairs(roads) do
            local parallel = own ~= nil and math.abs(r.hx * own.hx + r.hz * own.hz) > 0.85
            if not r.lanes[self_] and not parallel and lineDist(r.centre, px, pz) <= r.offset then
                return true
            end
        end
        return false
    end

    -- WHERE THE TURN STARTS. Walking a lane in from its anchor, the parent road holds a steady
    -- curvature, or one that changes slowly; a turn leaves it, and its curvature departs sharply.
    -- The index where that departure begins is the start of the turn, and everything from there
    -- inward is junction wiring whatever it happens to be labelled.
    --
    -- This is what finally removes a connector the clear left behind. Identifying wiring node by
    -- node never worked: a connector is laid tangent-continuous onto its lane, so the chain walk runs
    -- straight onto it and marks it road, and from then on it is protected from clearing. Cutting the
    -- lane back past the departure and re-laying the road into the box sidesteps the identification
    -- problem entirely - whatever was inward of the cut is gone, connector or not.
    --
    -- The threshold adapts: a road that is itself curving has a spread of its own, so a departure has
    -- to stand out from THAT rather than from zero, or every bend would read as a turn.
    local function turnStart(seq)
        if #seq < 4 then return #seq end
        local back = { [#seq] = 0 }
        for i = #seq - 1, 1, -1 do
            back[i] = back[i + 1] + math.sqrt((seq[i + 1].x - seq[i].x) ^ 2
                + (seq[i + 1].z - seq[i].z) ^ 2)
        end
        local function atBack(d, from)
            for i = from, 1, -1 do
                if back[i] - back[from] >= d then return seq[i] end
            end
            return nil
        end
        -- Signed curvature at each node, read over about 10 m of lane behind it.
        local k = {}
        for i = 3, #seq do
            local c = seq[i]
            local b = atBack(5, i)
            local a = atBack(10, i)
            if a ~= nil and b ~= nil then
                local ax, az = b.x - a.x, b.z - a.z
                local bx, bz = c.x - b.x, c.z - b.z
                local cx2, cz2 = c.x - a.x, c.z - a.z
                local la = math.sqrt(ax * ax + az * az)
                local lb = math.sqrt(bx * bx + bz * bz)
                local lc = math.sqrt(cx2 * cx2 + cz2 * cz2)
                if la > 1e-3 and lb > 1e-3 and lc > 1e-3 then
                    k[i] = 2 * (ax * bz - az * bx) / (la * lb * lc)
                end
            end
        end
        -- The road's own curvature, taken from the OUTER half of the lane where no junction wiring
        -- can reach. Median and median deviation, so one odd node cannot set the baseline.
        local outer = {}
        for i = 3, #seq do
            if k[i] ~= nil and back[i] > back[1] * 0.5 then outer[#outer + 1] = k[i] end
        end
        if #outer < 3 then return #seq end
        table.sort(outer)
        local kRoad = outer[math.ceil(#outer / 2)]
        local devs = {}
        for _, v in ipairs(outer) do devs[#devs + 1] = math.abs(v - kRoad) end
        table.sort(devs)
        local spread = devs[math.ceil(#devs / 2)]
        local limit = math.max(0.02, spread * 4)
        -- First departure, walking inward. Two nodes in a row must exceed it, so a single noisy
        -- reading cannot cut a lane in half.
        for i = 3, #seq - 1 do
            if k[i] ~= nil and k[i + 1] ~= nil
                and math.abs(k[i] - kRoad) > limit and math.abs(k[i + 1] - kRoad) > limit then
                return math.max(2, i - 1)
            end
        end
        return #seq
    end

    -- THE BOX INTERIOR IS JUNCTION, NOT ROAD - whatever the walk called it.
    --
    -- Inside the box nothing is parent road by definition: the box is where the roads' own offset
    -- lines cross, and what lies within it is the junction's wiring - through paths, tie nodes,
    -- connector tails. The chain walk cannot be trusted to say so. A connector is laid
    -- tangent-continuous, so the walk runs straight onto it and marks it road, and at a built 4-way
    -- that put dozens of laid nodes on the never-clearable list and left the interior behind as
    -- fragments whenever through paths were cleared. Asking WHERE a node is instead of what the walk
    -- thought of it needs no such judgement.
    --
    -- Through paths kept: everything in the box goes EXCEPT the kept routes. Through paths cleared:
    -- everything in the box goes. Either way the lanes are then walked again, because they end
    -- somewhere else now, and the per-road pass below brings each end to the box edge.
    --
    -- Bounded to the box that contains this junction's centre. Two of these roads may well cross
    -- again further out, or one may cross a road belonging to the junction next door.
    local swept, severed = {}, 0
    if #roads >= 2 then
        local keptThrough = (self.junctionLeaveThrough ~= false) and (jp.protectedOf or {}) or {}
        -- Kept: the through routes being left, and ANOTHER junction's wiring whichever way that
        -- toggle is set. A neighbour's connector can tail off right into this box; it is still the
        -- neighbour's.
        local theirs = jp.foreignWiring or {}
        local kept = setmetatable({}, { __index = function(_, k) return keptThrough[k] or theirs[k] end })
        local maxOff = 0
        for _, r in ipairs(roads) do if r.offset > maxOff then maxOff = r.offset end end
        local reach = maxOff * 1.5 + 2
        local reach2 = reach ^ 2
        -- In the box: inside the claims of two roads that are not parallel, near the box's middle.
        local function inBox(x, z)
            if (x - boxCentre.x) ^ 2 + (z - boxCentre.z) ^ 2 > reach2 then return false end
            -- THIS junction's box is the overlap of the two roads that cross HERE. Where a second
            -- side road joins 18 m along, its claim crosses the main road's too and makes a second
            -- box - the neighbour's - and sweeping that as well cut the main road at both T's; the
            -- stretch left between them was then a short dead stub, and the stub sweep took it.
            if boxRoadA ~= nil then
                return lineDist(boxRoadA.centre, x, z) <= boxRoadA.offset
                    and lineDist(boxRoadB.centre, x, z) <= boxRoadB.offset
            end
            local first = nil
            for _, r in ipairs(roads) do
                if lineDist(r.centre, x, z) <= r.offset then
                    if first == nil then
                        first = r
                    elseif math.abs(first.hx * r.hx + first.hz * r.hz) <= 0.85 then
                        return true
                    end
                end
            end
            return false
        end
        local sweptSet = {}
        for _, n in pairs(ADGraphManager:getWayPoints()) do
            if n ~= nil and n.id ~= nil and not skip[n.id] and not kept[n] and inBox(n.x, n.z) then
                swept[#swept + 1] = n
                sweptSet[n] = true
            end
        end
        -- AND THE LINKS THAT CROSS IT. A box is only 7-10 m across and a road's nodes can be 13 m
        -- apart, so a lane can run clean through the box without a single node inside it: nothing
        -- to sweep, and the junction stayed joined. That is how a T cleared with through paths off
        -- kept its through road running, and how a connector's long last segment survived a clear.
        -- A link whose line passes through the box is junction wiring exactly as a node in it is.
        -- Kept through routes are spared link by link, the same way their nodes are.
        local crossing = {}
        local far2 = (reach + 30) ^ 2
        for _, n in pairs(ADGraphManager:getWayPoints()) do
            if n ~= nil and n.id ~= nil and not skip[n.id] and not sweptSet[n]
                and (n.x - boxCentre.x) ^ 2 + (n.z - boxCentre.z) ^ 2 <= far2 then
                for _, oid in pairs(n.out or {}) do
                    local o = ADGraphManager:getWayPointById(oid)
                    if o ~= nil and not skip[oid] and not sweptSet[o] and not (kept[n] and kept[o])
                        and not cut[n.id * 100000 + oid] then
                        local vx, vz = o.x - n.x, o.z - n.z
                        local len = math.sqrt(vx * vx + vz * vz)
                        local steps = math.floor(len / 0.5)
                        for k = 1, steps - 1 do
                            local t = k / steps
                            if inBox(n.x + vx * t, n.z + vz * t) then
                                crossing[#crossing + 1] = { n, o }
                                break
                            end
                        end
                    end
                end
            end
        end
        for _, pr in ipairs(crossing) do
            if dry then
                cut[pr[1].id * 100000 + pr[2].id] = true
                cut[pr[2].id * 100000 + pr[1].id] = true
            else
                junctionDisconnect(pr[1], pr[2])
            end
            severed = severed + 1
        end
        if #swept > 0 or severed > 0 then
            if dry then
                for _, n in ipairs(swept) do skip[n.id] = true end
            else
                local ids = {}
                for _, n in ipairs(swept) do if alive(n) then ids[#ids + 1] = n.id end end
                -- Highest id first: every removal renumbers the ids above it.
                table.sort(ids, function(a, b) return a > b end)
                for _, id in ipairs(ids) do
                    jxRemove(id, "junction box sweep")
                end
            end
            for _, w in ipairs(walked) do
                if alive(w.ap.wp) and not skip[w.ap.wp.id] then
                    local nw = walkLane(w.ap)
                    w.seq, w.cameFrom, w.tidy, w.reference = nw.seq, nw.cameFrom, nw.tidy, nw.reference
                else
                    w.tidy = false
                end
            end
        end
    end

    -- THE EDGE OF *THIS* JUNCTION'S BOX along a path, as an arc length - or nil if the path never
    -- enters it.
    --
    -- Found from the INSIDE OUT: go to where the path comes closest to the junction, confirm that
    -- point lies inside another road's claim, then walk back out along the path until it does not.
    -- The scan used to run from the far end inward and stop at the FIRST claim it met. A lane is
    -- walked from 45 m out, and if there is another junction within that distance the first claim
    -- it meets belongs to THAT junction - so the lane was trimmed back to clear a box 24 m away,
    -- and the ends at this junction were left stranded 11 to 16 m out. Same root as the tidy
    -- "trimming stuff at another intersection": a first-match scan has no idea which junction it
    -- is looking at.
    local function boxEdgeAlong(sample, total, inside)
        local sC, dC, sx = nil, math.huge, 0
        while sx <= total do
            local pt = sample(sx)
            local d = (pt.x - boxCentre.x) ^ 2 + (pt.z - boxCentre.z) ^ 2
            if d < dC then dC, sC = d, sx end
            sx = sx + 0.25
        end
        if sC == nil then return nil end
        local pc = sample(sC)
        if not inside(pc.x, pc.z) then return nil end
        while sC >= 0.25 do
            local pt = sample(sC - 0.25)
            if not inside(pt.x, pt.z) then break end
            sC = sC - 0.25
        end
        return sC
    end

    -- PASS 2: TIDY PER ROAD, NOT PER LANE.
    --
    -- "The tracks stay parallel to the parent road" is a constraint BETWEEN the two tracks of a
    -- road, and a per-lane loop has nowhere to express it. Each track got its own walk, its own
    -- fitted arc and its own run-in, so they drifted apart over the few metres they were laid
    -- across: a road running at a constant 3.9 m opened to 6.4 m at the junction mouth, which puts
    -- the tracks off the road surface. Every attempt to fix that from inside the per-lane loop was
    -- one track reaching sideways for information about its partner, and each one broke something
    -- else - 8.9 m one way, a 0.6 m pinch the other.
    --
    -- So a road is tidied as one object. Its centre and width are read from the pair OUT WHERE IT IS
    -- CLEAN - far enough that the junction's old wiring has not splayed them - the centre is carried
    -- in to the box once, and both tracks are laid along it at half that width. Parallel by
    -- construction, and the width is an input rather than an outcome.
    local CLEAN_AT = 15

    -- Which other road's claim this one stops at.
    -- A ROAD RUNNING ALONGSIDE IS NOT A ROAD YOU STOP AT. Two roads a few degrees apart that were
    -- not merged into one still overlap each other's claims further out from the junction, and the
    -- scan took that overlap for the box edge - 25 m up the road - and trimmed the lane back to it.
    -- The same parallel test that decides whether two tracks are ONE road decides this: if it is
    -- parallel enough that it could have been my own carriageway, it is not my crossing. Anything
    -- meeting at a real angle, however shallow, still counts.
    local function insideOther(px, pz, self_)
        for _, rr in ipairs(roads) do
            if rr ~= self_ and math.abs(rr.hx * self_.hx + rr.hz * self_.hz) <= 0.85
                and lineDist(rr.centre, px, pz) <= rr.offset then
                return true
            end
        end
        return false
    end
    -- A point on a track's surviving nodes at a given distance from the junction.
    local function onTrackAt(w, d)
        local best, bd = nil, math.huge
        for _, n in ipairs(w.seq) do
            local e = math.abs(math.sqrt((n.x - boxCentre.x) ^ 2 + (n.z - boxCentre.z) ^ 2) - d)
            if e < bd then bd, best = e, n end
        end
        -- From the BOX centre, and tolerant of a sparse road: a lane with 13 m between its points
        -- has nothing within 5 m of any given ring, and a road that could not be measured was
        -- silently skipped - its ends left wherever the clear dropped them.
        return (bd < 9) and best or nil
    end
    -- The local direction of a polyline at index k, and the left normal.
    local function dirAtIndex(line, k)
        local a = line[math.max(1, k - 1)]
        local b = line[math.min(#line, k + 1)]
        local vx, vz = b.x - a.x, b.z - a.z
        local l = math.sqrt(vx * vx + vz * vz)
        if l < 1e-6 then return nil end
        return vx / l, vz / l
    end

    local ends = dry and {} or nil
    local handled = {}
    local trimmed, added, lanes = 0, 0, 0
    -- WHAT HAPPENED TO EACH LANE, SAID OUT LOUD. A lane whose path never meets the box was skipped
    -- in silence: no trim, no extension, no mention - so a road left stopping fifteen metres short
    -- looked exactly like a road the tool had decided to leave. One lane at j33 ended 18.5 m from
    -- the middle while its partner reached 5.1 m, and nothing in the log said which pass had
    -- declined it or why. Every lane now reports its outcome, and the capture picks these up with
    -- everything else, so the game answers the question without the offline harness in the loop.
    local laneReport = {}
    -- A ROAD THROUGH A JUNCTION ARRIVES FROM BOTH ENDS, and each end is tidied on its own.
    --
    -- Everything below measures along one centreline, running in from one end of the road. Tracks
    -- arriving from the FAR end sit past the box on that measure, so they read as having overshot it
    -- by the width of the whole junction - 14 to 16 m at a 4-way - and were trimmed AWAY from the
    -- junction instead of being brought to their own edge of the box. Half the ends at any junction
    -- cleared with through paths off finished 9-11 m out because of it. A lane's walk always runs
    -- anchor-inward whichever way it is driven, so its last segment points at the junction, and two
    -- lanes on the same side of it point the same way.
    local units = {}
    for _, r in ipairs(roads) do
        local bySide = {}
        for _, w in ipairs(walked) do
            if r.lanes[w] and w.tidy and alive(w.seq[#w.seq]) and #w.seq >= 2 then
                local a, b = w.seq[#w.seq - 1], w.seq[#w.seq]
                local hx, hz = b.x - a.x, b.z - a.z
                local placed = false
                for _, sd in ipairs(bySide) do
                    if sd.hx * hx + sd.hz * hz > 0 then
                        sd.list[#sd.list + 1] = w
                        placed = true
                        break
                    end
                end
                if not placed then bySide[#bySide + 1] = { hx = hx, hz = hz, list = { w } } end
            end
        end
        for _, sd in ipairs(bySide) do
            units[#units + 1] = { r = r, todo = sd.list, hx = sd.hx, hz = sd.hz }
        end
    end
    for _, u in ipairs(units) do
        local r, todo = u.r, u.todo
        if #todo > 0 then
            -- Pair the road up and measure it where it is clean.
            local A = todo[1]
            local a0 = onTrackAt(A, CLEAN_AT)
            local B, width = nil, nil
            if a0 ~= nil then
                for _, w in ipairs(walked) do
                    local sameSide = false
                    if #w.seq >= 2 then
                        local pa, pb = w.seq[#w.seq - 1], w.seq[#w.seq]
                        sameSide = (u.hx * (pb.x - pa.x) + u.hz * (pb.z - pa.z)) > 0
                    end
                    if r.lanes[w] and w ~= A and sameSide then
                        -- PERPENDICULAR to the other track, not point to point. Two nodes that each
                        -- sit 15 m from the junction can be well offset ALONG the road, and the
                        -- straight line between them then overstates the gap - one road running at
                        -- 3.9 m measured 7.6 m that way, and the tracks were held that far apart.
                        local bl = {}
                        for _, n in ipairs(w.seq) do bl[#bl + 1] = { x = n.x, z = n.z } end
                        local _, g = nearestOn(bl, a0.x, a0.z)
                        if g ~= nil and g > 1.0 and g < 12 and (width == nil or g < width) then
                            B, width = w, g
                        end
                    end
                end
            end

            -- The road's centre: the midline of the pair, built from their own nodes, then carried
            -- on across the junction by the curve it was already describing.
            local full, fc = nil, nil
            if B ~= nil and r.real and r.centre ~= nil and #r.centre >= 3 then
                -- A THROUGH ROAD'S TRACKS FOLLOW ITS REAL CENTRE. The merged through routes already
                -- run right across the junction, so there is nothing to extrapolate: orient that line
                -- the way this side of the road approaches, and the tracks are laid parallel to the
                -- parent road because they are offsets of the parent road.
                local c1, cN = r.centre[1], r.centre[#r.centre]
                local fwd = ((cN.x - c1.x) * u.hx + (cN.z - c1.z) * u.hz) >= 0
                local raw = {}
                for i = 1, #r.centre do
                    local q = r.centre[fwd and i or (#r.centre + 1 - i)]
                    raw[#raw + 1] = { x = q.x, z = q.z }
                end
                -- Resampled every quarter metre. The real centre only has points where the road has
                -- nodes - anything from 1 to 13 m apart - and everything downstream finds the box
                -- edge by stepping along this line, so at node spacing the "first point inside the
                -- box" landed up to a whole segment past the edge: every end at a 4-way overshot by
                -- about 2 m.
                local rc = cumulative(raw)
                full = {}
                local at = 0
                while at <= rc[#rc] do
                    local q = atArc(raw, rc, at)
                    full[#full + 1] = { x = q.x, z = q.z }
                    at = at + 0.25
                end
                fc = cumulative(full)
            elseif B ~= nil then
                local bl = {}
                for _, n in ipairs(B.seq) do bl[#bl + 1] = { x = n.x, z = n.z } end
                local mid = {}
                for _, n in ipairs(A.seq) do
                    local q = nearestOn(bl, n.x, n.z)
                    if q ~= nil then
                        mid[#mid + 1] = { x = (n.x + q.x) * 0.5, y = n.y or 0, z = (n.z + q.z) * 0.5 }
                    end
                end
                if #mid >= 3 then
                    -- A side road's centre is carried across from its CLEAN stretch and STRAIGHT: the
                    -- last 18 m of its lanes is where old kickouts swing out, and a midline built
                    -- through them bent the whole run-in the way the turn used to go.
                    while #mid > 3 and (mid[#mid].x - boxCentre.x) ^ 2 + (mid[#mid].z - boxCentre.z) ^ 2 < 18 * 18 do
                        mid[#mid] = nil
                    end
                    local mb, mrun = #mid - 1, 0
                    while mb > 1 and mrun < 10 do
                        mrun = mrun + math.sqrt((mid[mb + 1].x - mid[mb].x) ^ 2 + (mid[mb + 1].z - mid[mb].z) ^ 2)
                        if mrun < 10 then mb = mb - 1 end
                    end
                    local ext = laneArc(mid, mid[#mid], mid[mb], 0, true)
                    full = {}
                    for _, q in ipairs(mid) do full[#full + 1] = q end
                    for i = 2, (ext ~= nil) and #ext or 0 do full[#full + 1] = ext[i] end
                    fc = cumulative(full)
                end
            end

            if full ~= nil then
                -- Where the road's centre meets the box. One answer for the whole road, so both
                -- tracks stop abreast instead of each finding its own boundary.
                local target = boxEdgeAlong(
                    function(at) return atArc(full, fc, at) end, fc[#fc],
                    function(x, z) return insideOther(x, z, r) end)

                -- Sanity: the pair must straddle the centre. Both tracks on one side means the
                -- midline is not where the road actually is, and laying them on it would collapse
                -- them together - measured 0.0 m apart at one T, with 17 points of road trimmed
                -- away chasing a boundary that was never in the right place.
                local straddles = true
                if target ~= nil and width ~= nil and #todo >= 2 then
                    local seenSign = nil
                    for _, w in ipairs(todo) do
                        local tip = w.seq[#w.seq]
                        local q = nearestOn(full, tip.x, tip.z)
                        local bi, bd = 1, math.huge
                        for k, ptc in ipairs(full) do
                            local d = (ptc.x - (q and q.x or tip.x)) ^ 2
                                + (ptc.z - (q and q.z or tip.z)) ^ 2
                            if d < bd then bd, bi = d, k end
                        end
                        local ux, uz = dirAtIndex(full, bi)
                        if ux == nil then straddles = false break end
                        local sg = (((tip.x - full[bi].x) * -uz + (tip.z - full[bi].z) * ux) >= 0)
                            and 1 or -1
                        if seenSign == nil then seenSign = sg
                        elseif sg ~= seenSign then seenSign = 0 end
                    end
                    if seenSign ~= 0 then straddles = false end
                end
                if target ~= nil and width ~= nil and straddles then
                    for _, w in ipairs(todo) do
                        handled[w] = true
                        local seq, useOut = w.seq, w.useOut
                        -- Which side of the centre this track runs, and how far along it the track
                        -- currently ends.
                        local tip = seq[#seq]
                        local q = nearestOn(full, tip.x, tip.z)
                        local bi, bd = 1, math.huge
                        for k, ptc in ipairs(full) do
                            local d = (ptc.x - (q and q.x or tip.x)) ^ 2 + (ptc.z - (q and q.z or tip.z)) ^ 2
                            if d < bd then bd, bi = d, k end
                        end
                        local ux, uz = dirAtIndex(full, bi)
                        if ux ~= nil then
                            local sgn = (((tip.x - full[bi].x) * -uz + (tip.z - full[bi].z) * ux) >= 0)
                                and 1 or -1
                            local side = sgn * width * 0.5
                            -- A TRACK THAT IS NOT ON ITS OFFSET LINE IS NOT DRAGGED ONTO IT. The run-in
                            -- is laid along the road's centre offset by half its width, which assumes
                            -- the track already sits there. Beside a hairpin it does not: the lane
                            -- comes out of the bend a couple of metres off that line, and a run-in
                            -- only 3 m long then had to cross the whole gap - a 60 degree hook on the
                            -- end of the lane. Where the end is more than a metre off, the run-in is
                            -- laid through the END instead: still an offset of the parent road, so
                            -- still parallel to it and still stopping on the box edge, just on the
                            -- line the track is actually on.
                            local lat = (tip.x - full[bi].x) * -uz + (tip.z - full[bi].z) * ux
                            -- Only when the lane is STEADY there. The end can also be a tie node an old kickout
                            -- left a little off the lane, and taking that one node's word moved a straight road's
                            -- run-in sideways instead - a hook the other way. The node before it has to sit on the
                            -- same line, to half a metre.
                            local lat2 = nil
                            if #seq >= 2 then
                                local pn = seq[#seq - 1]
                                local q2 = nearestOn(full, pn.x, pn.z)
                                if q2 ~= nil then lat2 = (pn.x - q2.x) * -uz + (pn.z - q2.z) * ux end
                            end
                            if math.abs(lat - side) > 1.0 and lat2 ~= nil and math.abs(lat2 - lat) <= 0.5 then side = lat end
                            -- A side road's centre is only a construction (there is no real road line
                            -- across the junction to offset from), so its tracks are never moved onto
                            -- it: each is carried in along ITS OWN line, read two nodes back from the
                            -- end so an old kickout's first swing does not set it.
                            if not r.real and #seq >= 3 then
                                local pn = onTrackAt(w, 18) or seq[#seq - 2]
                                local q3 = nearestOn(full, pn.x, pn.z)
                                if q3 ~= nil then side = (pn.x - q3.x) * -uz + (pn.z - q3.z) * ux end
                            end
                            -- This track's own line: the centre, offset to its side.
                            local off = {}
                            for k = 1, #full do
                                local vx, vz = dirAtIndex(full, k)
                                if vx ~= nil then
                                    off[#off + 1] = { x = full[k].x + -vz * side, y = full[k].y,
                                        z = full[k].z + vx * side, s = fc[k] }
                                end
                            end
                            -- A THROUGH LANE IS ITS OWN ORIGINAL THROUGH PATH, TRIMMED TO THE BOX. The path
                            -- this lane ran on before the clear is real geometry right across the
                            -- junction, so nothing needs constructing: no centre to find, no width to
                            -- measure, no offset to lay - which is where the half-metre kicks, the
                            -- wrong widths and the wiggles all came from. The lane is brought to the
                            -- box ALONG THAT PATH, and the respacing that follows is the smooth tool's
                            -- rebuild, which irons out what old tie-ins left in it.
                            if w.realLine and w.line ~= nil and #w.line >= 3 then
                                local own = {}
                                local a1, aN = w.line[1], w.line[#w.line]
                                local anchor = seq[1]
                                local fwd = ((a1.x - anchor.x) ^ 2 + (a1.z - anchor.z) ^ 2)
                                    <= ((aN.x - anchor.x) ^ 2 + (aN.z - anchor.z) ^ 2)
                                for i = 1, #w.line do
                                    local q = w.line[fwd and i or (#w.line + 1 - i)]
                                    own[#own + 1] = { x = q.x, z = q.z }
                                end
                                local oc = cumulative(own)
                                local fine, at = {}, 0
                                while at <= oc[#oc] do
                                    local q = atArc(own, oc, at)
                                    fine[#fine + 1] = { x = q.x, y = tip.y, z = q.z, s = at }
                                    at = at + 0.25
                                end
                                if #fine >= 3 then off = fine end
                            end
                            -- A SIDE-ROAD LANE FOLLOWS ITS OWN LINE, the same principle. There is no through
                            -- path to follow - building the junction consumed it - but the lane itself
                            -- is still there further back, clean: its line is read between 30 m and
                            -- 18 m out, behind where any kickout began, and carried straight to the box.
                            -- Not paired with its partner, not moved onto a centre: every attempt to
                            -- construct one bent the lane's end towards it.
                            if not r.real then
                                -- The last node still 16 m or more from the box, and one at least 8 m
                                -- behind it: by the lane's own nodes, however sparse they are.
                                local far, near = nil, nil
                                for i = #seq, 1, -1 do
                                    local n = seq[i]
                                    if (n.x - boxCentre.x) ^ 2 + (n.z - boxCentre.z) ^ 2 >= 16 * 16 then
                                        near = n
                                        for j = i - 1, 1, -1 do
                                            local m = seq[j]
                                            if (m.x - n.x) ^ 2 + (m.z - n.z) ^ 2 >= 8 * 8 then far = m break end
                                        end
                                        break
                                    end
                                end
                                if far ~= nil and near ~= nil and far ~= near then
                                    local hx2, hz2 = near.x - far.x, near.z - far.z
                                    local hl = math.sqrt(hx2 * hx2 + hz2 * hz2)
                                    if hl > 1 then
                                        hx2, hz2 = hx2 / hl, hz2 / hl
                                        local ray = {}
                                        for i = 0, 200 do
                                            local d = i * 0.25
                                            ray[#ray + 1] = { x = near.x + hx2 * d, y = near.y or tip.y,
                                                z = near.z + hz2 * d, s = d }
                                        end
                                        off = ray
                                    end
                                end
                            end
                            if #off >= 3 then
                                -- EACH TRACK STOPS ON THE BOX EDGE ITSELF, not at a point shared
                                -- with its partner. The box edge is an offset of the PARENT road, so
                                -- ends that each land on it line up parallel to the parent road by
                                -- construction. One stopping point for the whole road - measured
                                -- along the stem's own centre - cut the pair off square to the
                                -- STEM instead, which is skewed at any junction that does not meet
                                -- at a right angle. The tracks still run parallel to their road's
                                -- centre at its width; only where each one ends is its own.
                                local target = target
                                do
                                    -- Same inside-out search, over this track's own offset line.
                                    local kC, dC = nil, math.huge
                                    for k, o in ipairs(off) do
                                        local d = (o.x - boxCentre.x) ^ 2 + (o.z - boxCentre.z) ^ 2
                                        if d < dC then dC, kC = d, k end
                                    end
                                    if kC ~= nil and insideOther(off[kC].x, off[kC].z, r) then
                                        while kC > 1 and insideOther(off[kC - 1].x, off[kC - 1].z, r) do
                                            kC = kC - 1
                                        end
                                        target = off[kC].s
                                    end
                                end
                                -- Spacing: the lane's own, from the segments it already has.
                                local sum, cnt = 0, 0
                                for i = math.max(2, #seq - 5), #seq do
                                    local a, b = seq[i - 1], seq[i]
                                    sum = sum + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
                                    cnt = cnt + 1
                                end
                                local spacing = math.max(1.5, math.min(12,
                                    (cnt > 0 and sum > 0) and (sum / cnt) or 4))

                                -- How far along the road each surviving node sits, so "past the
                                -- box" is judged on the road's own measure rather than on a
                                -- straight-line distance that a bend would distort.
                                local function along(n)
                                    local best, bs = math.huge, 0
                                    for _, o in ipairs(off) do
                                        local d = (o.x - n.x) ^ 2 + (o.z - n.z) ^ 2
                                        if d < best then best, bs = d, o.s end
                                    end
                                    return bs
                                end
                                local touched = false
                                local budget = AutoDrive.FLYOVER_JUNCTION_TRIM_BUDGET or 8
                                -- Old kickouts start well back from the junction; taking their remains off a
                                -- lane end is allowed further than an ordinary trim.
                                local strayBudget = 20
                                -- How far a node sits OFF this track's own line.
                                local function astray(n)
                                    local best = math.huge
                                    for _, q in ipairs(off) do
                                        local d = (q.x - n.x) ^ 2 + (q.z - n.z) ^ 2
                                        if d < best then best = d end
                                    end
                                    return math.sqrt(best)
                                end
                                while #seq > 2 and (along(seq[#seq]) > target + 0.5
                                    -- ...or the lane's last nodes have already LEFT its line: the first
                                    -- few metres of an old kickout, still on the lane's end, swinging
                                    -- out for a turn that no longer exists. Running in from there put
                                    -- a sideways step in the lane. Same budget as any other trim.
                                    or (strayBudget > 0 and astray(seq[#seq]) > 0.5)) do
                                    local back = seq[#seq - 1]
                                    local step = math.sqrt((seq[#seq].x - back.x) ^ 2
                                        + (seq[#seq].z - back.z) ^ 2)
                                    local overBox = along(seq[#seq]) > target + 0.5
                                    if not overBox then
                                        if step > strayBudget then break end
                                        strayBudget = strayBudget - step
                                    elseif step > budget then break end
                                    if overBox then budget = budget - step end
                                    local doomed = seq[#seq]
                                    if not alive(doomed) then break end
                                    if dry then
                                        skip[doomed.id] = true
                                        seq[#seq] = nil
                                    else
                                        if not jxRemove(doomed, "junction tidy trim") then break end
                                        seq[#seq] = nil
                                        trimmed = trimmed + 1
                                    end
                                    touched = true
                                end

                                local from = along(seq[#seq])
                                local travel = target - from
                                if dry then
                                    -- Where it will ACTUALLY finish, which is the target only if the
                                    -- trim could reach it. Where the budget ran out first the end
                                    -- stays where the trim left it, and reporting the target instead
                                    -- had the preview promising ends 3.8 m from where they landed.
                                    local landed = nil
                                    if travel > 0.5 then
                                        for _, o in ipairs(off) do
                                            if o.s >= target then landed = o break end
                                        end
                                    else
                                        local tipNow = seq[#seq]
                                        landed = { x = tipNow.x, y = tipNow.y or 0, z = tipNow.z }
                                    end
                                    if landed ~= nil then
                                        ends[#ends + 1] = { x = landed.x, y = landed.y or 0,
                                            z = landed.z, dir = w.ap.dir, moved = math.abs(travel) }
                                    end
                                elseif travel > 0.5 then
                                    local last, back = seq[#seq], seq[#seq - 1]
                                    local segDual = (alive(last) and back ~= nil and alive(back)
                                        and table.contains(last.out or {}, back.id)
                                        and table.contains(back.out or {}, last.id)) or false
                                    local n = math.min(12, math.max(1,
                                        math.floor(travel / spacing + 0.5)))
                                    for i = 1, n do
                                        local want = from + (travel / n) * i
                                        local pt = off[#off]
                                        for _, o in ipairs(off) do
                                            if o.s >= want then pt = o break end
                                        end
                                        local made
                                        if not tryCall("junction tidy extend", function()
                                            made = ADGraphManager:recordWayPoint(pt.x, pt.y or last.y or 0,
                                                pt.z, false, false, false, 0,
                                                last.flags or AutoDrive.FLAG_NONE, false)
                                        end) or made == nil then break end
                                        if useOut then junctionConnect(seq[#seq], made, segDual)
                                        else junctionConnect(made, seq[#seq], segDual) end
                                        seq[#seq + 1] = made
                                        added, touched = added + 1, true
                                    end
                                end
                                if touched and not dry then lanes = lanes + 1 end
                            end
                        end
                    end
                end
            end
        end
    end


    -- FALLBACK: lanes the per-road pass could not take.
    --
    -- Holding two tracks parallel needs a road that IS a clean pair - one found at about 15 m out,
    -- straddling its own centre. A lone track, a two-way road carried on a single track, or a pair
    -- whose midline cannot be trusted has nothing to hold a width against, and forcing it collapsed
    -- both tracks onto one side. Those lanes keep the older treatment: each runs in on the curve it
    -- was already describing. It does not hold the road's width, but it does not invent one either.
    for _, w in ipairs(walked) do
        local ap, seq, useOut = w.ap, w.seq, w.useOut
        if w.tidy and not handled[w] and alive(seq[#seq]) then
            -- "Normal spacing" is the lane's OWN spacing, read off the segments it already has, not
            -- a constant: a hand-recorded road at 8 m and a laid curve at 1.5 m each keep their look.
            local sum, cnt = 0, 0
            for i = math.max(2, #seq - 5), #seq do
                local a, b = seq[i - 1], seq[i]
                sum = sum + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
                cnt = cnt + 1
            end
            local spacing = math.max(1.5, math.min(12, (cnt > 0 and sum > 0) and (sum / cnt) or 4))

            -- The path: the road that is there, then the arc carrying it on across the junction.
            local tip, prev = seq[#seq], seq[#seq - 1]
            local vx, vz = tip.x - prev.x, tip.z - prev.z
            local segLen = math.sqrt(vx * vx + vz * vz)
            local grade = (segLen > 1e-3)
                and math.max(-0.15, math.min(0.15, ((tip.y or 0) - (prev.y or 0)) / segLen)) or 0
            local path = {}
            for _, n in ipairs(seq) do path[#path + 1] = { x = n.x, y = n.y or 0, z = n.z } end
            local arc = (segLen > 1e-3) and laneArc(seq, tip, prev, grade) or nil
            for i = 2, (arc ~= nil) and #arc or 0 do path[#path + 1] = arc[i] end
            local cum = cumulative(path)

            -- CUT BACK PAST THE TURN before anything else, so whatever the clear left of a
            -- connector goes with it. The box then decides where the rebuilt road stops.
            local ts = turnStart(seq)
            -- Capped like every other cut here. This one counts a curvature departure as the start
            -- of a turn and takes everything inward of it, and where that reading is wrong it takes
            -- the lane instead: 61 points at one site, 77 across another clear. A tidy trims a tail.
            local budget = AutoDrive.FLYOVER_JUNCTION_TRIM_BUDGET or 8
            while #seq > 2 and #seq > ts do
                local back = seq[#seq - 1]
                local step = math.sqrt((seq[#seq].x - back.x) ^ 2 + (seq[#seq].z - back.z) ^ 2)
                if step > budget then break end
                budget = budget - step
                local doomed = seq[#seq]
                if not alive(doomed) then break end
                if dry then
                    skip[doomed.id] = true
                    seq[#seq] = nil
                else
                    if not jxRemove(doomed, "junction tidy cut") then break end
                    seq[#seq] = nil
                    trimmed = trimmed + 1
                end
            end
            -- The cut never goes below two nodes, so the lane always keeps a direction.
            tip, prev = seq[#seq], seq[#seq - 1]
            vx, vz = tip.x - prev.x, tip.z - prev.z
            segLen = math.sqrt(vx * vx + vz * vz)
            grade = (segLen > 1e-3)
                and math.max(-0.15, math.min(0.15, ((tip.y or 0) - (prev.y or 0)) / segLen)) or 0
            path = {}
            for _, n in ipairs(seq) do path[#path + 1] = { x = n.x, y = n.y or 0, z = n.z } end
            arc = (segLen > 1e-3) and laneArc(seq, tip, prev, grade) or nil
            for i = 2, (arc ~= nil) and #arc or 0 do path[#path + 1] = arc[i] end
            cum = cumulative(path)

            -- Where that path first enters the box. Scanned from 30 m back, so a lane already poking
            -- into the junction is caught too - its entry point is behind its current end.
            local atNode = cum[#seq]
            local target = boxEdgeAlong(
                function(at) return atArc(path, cum, at) end, cum[#cum],
                function(x, z) return insideBox(x, z, w) end)

            if target ~= nil and dry then
                -- Walk the same trim the apply will, so the preview is bounded by the same budget.
                -- Reporting the target outright had it promising ends 3.8 m from where they landed,
                -- on lanes whose trim ran out of budget before it got there.
                local n, spend = #seq, AutoDrive.FLYOVER_JUNCTION_TRIM_BUDGET or 8
                while n > 2 and cum[n] > target + 0.5 do
                    local step = math.sqrt((seq[n].x - seq[n - 1].x) ^ 2
                        + (seq[n].z - seq[n - 1].z) ^ 2)
                    if step > spend then break end
                    spend = spend - step
                    skip[seq[n].id] = true
                    n = n - 1
                end
                local pt
                if cum[n] <= target + 0.5 then
                    pt = atArc(path, cum, target)
                else
                    pt = { x = seq[n].x, y = seq[n].y or 0, z = seq[n].z }
                end
                ends[#ends + 1] = { x = pt.x, y = pt.y or 0, z = pt.z, dir = ap.dir,
                    moved = math.abs(target - atNode) }
            elseif target ~= nil then
                local touched = false
                -- Drop whatever is past the boundary. Never below two nodes - a lane with one left
                -- has no direction and nothing could tie into it - and never more than a handful.
                --
                -- A TIDY TRIMS A TAIL; IT DOES NOT DIG UP A ROAD. Uncapped, this reached 77 points
                -- in one clear across five lanes, and 61 at another site: fifteen nodes of road per
                -- lane, chasing a boundary that was in the wrong place. Past a handful the answer
                -- is wrong, and stopping leaves a ragged end, which is recoverable. Carrying on is
                -- not. The per-road path above carries the same cap for the same reason.
                local budget = AutoDrive.FLYOVER_JUNCTION_TRIM_BUDGET or 8
                while #seq > 2 and cum[#seq] > target + 0.5 do
                    local back = seq[#seq - 1]
                    local step = math.sqrt((seq[#seq].x - back.x) ^ 2 + (seq[#seq].z - back.z) ^ 2)
                    if step > budget then break end
                    budget = budget - step
                    local doomed = seq[#seq]
                    if not alive(doomed) then break end
                    if not jxRemove(doomed, "junction tidy trim") then break end
                    seq[#seq] = nil
                    trimmed, touched = trimmed + 1, true
                end
                -- Then run up to it, in even steps that land exactly on the boundary.
                local travel = target - cum[#seq]
                if travel > 0.5 then
                    -- Read two-wayness off the segment that is STILL THERE: the trim above may have
                    -- taken the node this was originally measured against.
                    local last, back = seq[#seq], seq[#seq - 1]
                    local segDual = (alive(last) and back ~= nil and alive(back)
                        and table.contains(last.out or {}, back.id)
                        and table.contains(back.out or {}, last.id)) or false
                    local n = math.min(12, math.max(1, math.floor(travel / spacing + 0.5)))
                    for i = 1, n do
                        local pt = atArc(path, cum, cum[#seq] + (travel / n) * i)
                        local made
                        if not tryCall("junction tidy extend", function()
                            made = ADGraphManager:recordWayPoint(pt.x, pt.y or 0, pt.z, false, false,
                                false, 0, last.flags or AutoDrive.FLAG_NONE, false)
                        end) or made == nil then break end
                        if useOut then junctionConnect(seq[#seq], made, segDual)
                        else junctionConnect(made, seq[#seq], segDual) end
                        seq[#seq + 1] = made
                        added, touched = added + 1, true
                    end
                end
                if touched then lanes = lanes + 1 end
                if centre ~= nil then
                    local tip = seq[#seq]
                    laneReport[#laneReport + 1] = string.format(
                        "%s lane on bearing %3.0f: %d trimmed, %d added, now ends %.1f m from the middle",
                        tostring(ap.dir), math.deg(math.atan2(tip.x - centre.x, -(tip.z - centre.z))) % 360,
                        trimmed, added, math.sqrt((tip.x - centre.x) ^ 2 + (tip.z - centre.z) ^ 2))
                end
            elseif centre ~= nil and seq ~= nil and #seq > 0 then
                -- target is nil: this lane's path never crosses the box edge, so there is nothing to
                -- trim back to and nothing to run out to. Left exactly as it is - which is the right
                -- thing to do and the wrong thing to do quietly.
                local tip = seq[#seq]
                laneReport[#laneReport + 1] = string.format(
                    "%s lane on bearing %3.0f: LEFT ALONE - its path does not reach the box edge; nearest point is %.1f m from the middle",
                    tostring(ap.dir), math.deg(math.atan2(tip.x - centre.x, -(tip.z - centre.z))) % 360,
                    math.sqrt((tip.x - centre.x) ^ 2 + (tip.z - centre.z) ^ 2))
            end
        end
    end
    for _, line in ipairs(laneReport) do
        Logging.info("[FlyoverEditor]: junction - %s", line)
    end

    if dry then
        local roadsOut = {}
        -- THE BOX, FOR THE PREVIEW: each road's two offset lines, over the stretch near the junction.
        -- These are the lines the ends are brought to, so what is drawn is what was measured against.
        local bands = {}
        for _, r in ipairs(roads) do
            local line = {}
            for _, q in ipairs(r.centre or {}) do line[#line + 1] = { x = q.x, z = q.z } end
            roadsOut[#roadsOut + 1] = { centre = line, offset = r.offset, tracks = #r.members }
            for _, side in ipairs({ 1, -1 }) do
                local prev = nil
                for k = 1, #line do
                    local vx, vz = dirAtIndex(line, k)
                    local q = line[k]
                    if vx ~= nil and (q.x - boxCentre.x) ^ 2 + (q.z - boxCentre.z) ^ 2 <= 30 * 30 then
                        local pt = { x = q.x + -vz * r.offset * side, z = q.z + vx * r.offset * side }
                        if prev ~= nil and ((pt.x - prev.x) ^ 2 + (pt.z - prev.z) ^ 2) >= 1 then
                            bands[#bands + 1] = { ax = prev.x, az = prev.z, bx = pt.x, bz = pt.z }
                            prev = pt
                        elseif prev == nil then
                            prev = pt
                        end
                    else
                        prev = nil
                    end
                end
            end
        end
        if boxRoadA ~= nil then
            jp._box = { centre = boxCentre,
                a = { centre = boxRoadA.centre, offset = boxRoadA.offset, tracks = boxRoadA.tracks },
                b = { centre = boxRoadB.centre, offset = boxRoadB.offset, tracks = boxRoadB.tracks } }
        else
            jp._box = nil
        end
        return ends, bands, swept, roadsOut, boxCentre
    end
    -- What the lanes finally run over, for the stub sweep that follows: it must never mistake a lane
    -- for a spur, and these walks are the tool's best answer to which is which.
    local laneNodes = {}
    for _, w in ipairs(walked) do
        for _, n in ipairs(w.seq or {}) do laneNodes[n] = true end
    end
    jp._laneNodes = laneNodes
    -- And the lanes themselves, anchor to end, for the respacing that follows.
    -- A lane that was TIDIED ends at the junction, and its approach is the stretch up to that end.
    -- A lane that still RUNS THROUGH was not touched by the tidy, but its approach wants evening out
    -- just the same: for that one the approach is the stretch up to where it passes closest to the
    -- junction. The entry side and the exit side of a through road each stop at that point, so
    -- between them the road is respaced right across the junction, and the node nearest the middle
    -- is the one fixed point they share. A road that merely passes nearby is not this junction's.
    local laneSeqs = {}
    for _, w in ipairs(walked) do
        if w.seq ~= nil and #w.seq >= 3 then
            if w.tidy then
                laneSeqs[#laneSeqs + 1] = { seq = w.seq, useOut = w.useOut }
            else
                local iC, dC = nil, math.huge
                for i, n in ipairs(w.seq) do
                    local d = (n.x - centre.x) ^ 2 + (n.z - centre.z) ^ 2
                    if d < dC then dC, iC = d, i end
                end
                if iC ~= nil and iC >= 3 and dC <= 12 * 12 then
                    local sub = {}
                    for i = 1, iC do sub[i] = w.seq[i] end
                    laneSeqs[#laneSeqs + 1] = { seq = sub, useOut = w.useOut }
                end
            end
        end
    end
    jp._laneSeqs = laneSeqs
    jp._boxCentre = boxCentre
    return trimmed, added, lanes, #swept, severed
end

--- Remove the STUBS a clear leaves hanging off the lanes: the remains of connectors that the
--- chain walk marked as road and so could never clear.
---
--- A connector is laid tangent-continuous onto its lane, so the walk runs straight from road onto
--- connector without ever bending sharply enough to notice, and marks the whole thing skeleton.
--- Skeleton is road, road is never cleared, and the tail sits there through every clear after. Four
--- attempts to spot it while walking the lane all failed for the same reason: from ON the lane it
--- looks exactly like the lane.
---
--- It is obvious from beside the lane though. Whatever is left of a connector is a SHORT SPUR that
--- leaves a lane near the junction and stops - it joins nothing, because the clear already took the
--- far end. So: step off each surviving lane node onto any neighbour the lane does not use, follow
--- it, and if it dies within a few metres without reaching anything, it was wiring.
---
--- A real siding is a spur too, which is why this only looks close to the junction and only takes
--- ones that are genuinely short and genuinely dead.
function ADFlyoverEditor:junctionClearStubs(jp)
    local centre = jp.tracksCentre
    if centre == nil then return 0 end
    local REACH = 25      -- only near the junction; a spur further out is someone else's business
    local MAX_NODES = 10  -- longer than any connector remnant, shorter than a real road
    local MAX_LEN = 18

    -- Everything the lanes themselves run over: never a stub, however it looks from the side. The
    -- tidy's bearing-continuity walks are used where they exist; the crude walk below is only a
    -- fallback, because at a fork it takes the first neighbour listed and can wander off the lane.
    local onLane = {}
    local fromTidy = type(jp._laneNodes) == "table" and next(jp._laneNodes) ~= nil
    if fromTidy then
        for n in pairs(jp._laneNodes) do onLane[n] = true end
    end
    for _, ap in ipairs(fromTidy and {} or (jp.approaches or {})) do
        local w, guard = ap.wp, 0
        local useOut = (ap.dir == "in")
        local cameFrom = nil
        while w ~= nil and guard < 400 do
            guard = guard + 1
            onLane[w] = true
            local list = useOut and (w.out or {}) or (w.incoming or {})
            local nextW = nil
            for _, nid in pairs(list) do
                if nid ~= cameFrom then
                    local nx = ADGraphManager:getWayPointById(nid)
                    if nx ~= nil and not onLane[nx] then nextW = nx break end
                end
            end
            cameFrom = w.id
            w = nextW
        end
    end

    local doomed, seen = {}, {}
    for node in pairs(onLane) do
        if (node.x - centre.x) ^ 2 + (node.z - centre.z) ^ 2 <= REACH * REACH then
            for _, lst in ipairs({ node.out or {}, node.incoming or {} }) do
                for _, nid in pairs(lst) do
                    local first = ADGraphManager:getWayPointById(nid)
                    if first ~= nil and not onLane[first] and not seen[first] then
                        -- Follow this branch. It is a stub only if it ENDS without rejoining
                        -- anything, and does so soon.
                        local chain, walk, prev, len, dead = {}, first, node, 0, false
                        for _ = 1, MAX_NODES do
                            seen[walk] = true
                            chain[#chain + 1] = walk
                            local nxt = nil
                            for _, l2 in ipairs({ walk.out or {}, walk.incoming or {} }) do
                                for _, n2 in pairs(l2) do
                                    local cand = ADGraphManager:getWayPointById(n2)
                                    if cand ~= nil and cand ~= prev and cand ~= walk then
                                        if onLane[cand] then nxt = "rejoins" break end
                                        nxt = cand
                                    end
                                end
                                if nxt == "rejoins" then break end
                            end
                            if nxt == "rejoins" then dead = false break end
                            if nxt == nil then dead = true break end
                            len = len + math.sqrt((nxt.x - walk.x) ^ 2 + (nxt.z - walk.z) ^ 2)
                            if len > MAX_LEN then break end
                            prev, walk = walk, nxt
                        end
                        -- And it has to LOOK LAID. A parking spur or a siding is a short dead
                        -- branch near a junction too, and deleting one of those is not a tidy-up.
                        -- The tool lays its curves at about 1.5 m between points; recorded roads
                        -- run 4 to 13 m. A spur whose points average more than 3 m apart was driven,
                        -- not laid, and is left alone whatever else it looks like.
                        local laid = false
                        if dead and #chain > 0 then
                            local span = math.sqrt((chain[1].x - node.x) ^ 2 + (chain[1].z - node.z) ^ 2)
                            for k = 2, #chain do
                                span = span + math.sqrt((chain[k].x - chain[k - 1].x) ^ 2
                                    + (chain[k].z - chain[k - 1].z) ^ 2)
                            end
                            laid = (span / #chain) <= 3.0
                        end
                        if dead and laid then
                            for _, c in ipairs(chain) do doomed[#doomed + 1] = c end
                        end
                    end
                end
            end
        end
    end

    if #doomed == 0 then return 0 end
    local ids = {}
    for _, w in ipairs(doomed) do
        if w.id ~= nil and w.id >= 0 then ids[#ids + 1] = w.id end
    end
    -- Highest id first: every removal renumbers the ids above it.
    table.sort(ids, function(a, b) return a > b end)
    local gone = 0
    for _, id in ipairs(ids) do
        if jxRemove(id, "junction clear stub") then gone = gone + 1 end
    end
    return gone
end

--- Re-space each approach over the last stretch leading to the junction.
---
--- THE SMOOTH TOOL'S REBUILD, run over each stretch: corners smoothed, points re-spaced BY CURVATURE
--- - the maximum spacing on the straights, closer together through a bend - then one relaxing pass.
--- The same three calls the smooth tool makes in its max-spacing mode, so an approach comes out
--- exactly as it would if that tool had been dragged along it by hand.
---
--- It replaced a flat re-spacing at one fixed step, which evened the straights nicely and wrecked
--- the bends: a laid corner of 1-2 m points 25 m from one junction came back as 5 m chords, up to
--- 0.7 m off the line it had been given. How closely points need to sit depends on how hard the
--- road is turning, and a single number cannot know that.
---
--- Some nodes are never moved or removed, and the respacing works in the runs between them:
---   * the lane END, which the tidy has just put on the box edge;
---   * any FORK - something else joins the lane there, and moving it would bend that something;
---   * a node a MAP MARKER points at;
---   * the outer end of the stretch, so the lane beyond it is untouched;
---   * anything an earlier lane already respaced (two approaches can share a tail).
--- Existing nodes are MOVED where the count allows, so ids survive wherever they can; only the
--- surplus is deleted and only the shortfall created. A run whose links are not uniform (one-way
--- for part of it, two-way for the rest) is left exactly as it is.
function ADFlyoverEditor:junctionRespaceApproaches(jp)
    local LEN = AutoDrive.FLYOVER_JUNCTION_RESPACE_LEN or 50
    local STEP = AutoDrive.FLYOVER_JUNCTION_RESPACE_STEP or 5
    if LEN <= 0 or STEP <= 0 then return 0, 0, 0 end

    local function live(w)
        return w ~= nil and w.id ~= nil and w.id >= 0 and ADGraphManager:getWayPointById(w.id) == w
    end
    local function neighbours(w)
        local seen, n = {}, 0
        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, id in pairs(lst) do
                if not seen[id] then seen[id] = true n = n + 1 end
            end
        end
        return n
    end
    local function gap(a, b) return math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) end

    local marker = {}
    if ADGraphManager.getMapMarkers ~= nil then
        for _, m in pairs(ADGraphManager:getMapMarkers() or {}) do
            if m ~= nil and m.id ~= nil then
                local w = ADGraphManager:getWayPointById(m.id)
                if w ~= nil then marker[w] = true end
            end
        end
    end

    local moved, removed, created = 0, 0, 0
    local done = {}

    -- One run: fixed node A, interior nodes, fixed node B - all consecutive on the lane.
    local function respaceRun(nodes)
        local A, B = nodes[1], nodes[#nodes]
        local interior = {}
        for i = 2, #nodes - 1 do interior[#interior + 1] = nodes[i] end
        local L = 0
        for i = 2, #nodes do L = L + gap(nodes[i - 1], nodes[i]) end
        if L < 0.5 then return end
        -- The run has to be linked the same way all along, or it is not a plain stretch of lane.
        local f0, r0 = nil, nil
        for i = 2, #nodes do
            local u, v = nodes[i - 1], nodes[i]
            local f = table.contains(u.out or {}, v.id)
            local r = table.contains(v.out or {}, u.id)
            if f0 == nil then f0, r0 = f, r elseif f ~= f0 or r ~= r0 then return end
        end
        if not f0 and not r0 then return end
        for _, w in ipairs(interior) do
            if neighbours(w) ~= 2 or marker[w] then return end
        end
        local function link(u, v)
            if f0 and r0 then junctionConnect(u, v, true)
            elseif f0 then junctionConnect(u, v, false)
            else junctionConnect(v, u, false) end
        end

        -- Where the points belong: the smooth tool's rebuild of this stretch. Two points make a
        -- straight line with nothing to smooth, and that is simply divided.
        local pts = {}
        for i, w in ipairs(nodes) do pts[i] = { x = w.x, y = w.y or 0, z = w.z } end
        local final = nil
        if #pts >= 3 and ADOffsetGeometry ~= nil and ADOffsetGeometry.resampleOpenChainByCurvature ~= nil then
            local minSpacing = math.max(AutoDrive.FIELD_LOOP_ADAPTIVE_MIN_SPACING or 1, STEP * 0.25)
            local smoothed = ADOffsetGeometry.smoothOpenChain(pts, 2,
                AutoDrive.FIELD_LOOP_MAX_WAYPOINT_TURN_DEG or 5, 180)
            local resampled = ADOffsetGeometry.resampleOpenChainByCurvature(smoothed, minSpacing, STEP,
                AutoDrive.FIELD_LOOP_ADAPTIVE_TOLERANCE or 0.01)
            final = ADOffsetGeometry.relaxOpenChain(resampled, 1, {})
        end
        if final == nil or #final < 2 then
            local nSeg = math.max(1, math.floor(L / STEP + 0.5))
            final = { pts[1] }
            for j = 1, nSeg - 1 do
                local t = j / nSeg
                final[#final + 1] = { x = A.x + (B.x - A.x) * t, z = A.z + (B.z - A.z) * t }
            end
            final[#final + 1] = pts[#pts]
        end
        local targets = {}
        for j = 2, #final - 1 do
            local q = final[j]
            -- The rebuild is 2D. Height comes off the ORIGINAL stretch, so a run on a ramp or a
            -- bridge stays on it; where the terrain can be asked, it is, the same way the smooth
            -- tool asks.
            local y = heightAlongChain(pts, q.x, q.z) or A.y or 0
            if g_currentMission ~= nil and g_currentMission.terrainRootNode ~= nil then
                local ok, ry = pcall(function() return self:resolveHeightAt(q.x, q.z, y) end)
                if ok and ry ~= nil then y = ry end
            end
            targets[#targets + 1] = { x = q.x, y = y, z = q.z }
        end
        local want = #targets
        -- Already as the rebuild would leave it? Then leave it: no churn for nothing.
        if #interior == want then
            local worst = 0
            for j = 1, want do
                local d = math.sqrt((interior[j].x - targets[j].x) ^ 2 + (interior[j].z - targets[j].z) ^ 2)
                if d > worst then worst = d end
            end
            if worst <= 0.3 then return end
        end
        local flags = (interior[1] or A).flags or AutoDrive.FLAG_NONE

        -- WHOLE RUN OR NONE OF IT - CHECKED BEFORE A SINGLE POINT MOVES.
        --
        -- A rebuild moves the points it keeps and removes the ones it does not need. Removing is not
        -- its decision to make: jxRemove refuses anything outside this junction's own arms, and the
        -- surplus at the far end of a long run sits exactly where that bound runs out.
        --
        -- This check existed already, but it sat INSIDE the surplus branch, after the moves. So it
        -- did its job - refused the deletions, refused the bridge - on a run whose points had
        -- already been moved, which is the one outcome it was written to prevent. A point slid down
        -- to 0.42 m from the neighbour it was meant to replace, and that neighbour then stayed: two
        -- points on top of each other 48 m from the junction, which is what "lots of short dense
        -- points" looked like on screen.
        --
        -- Nothing is touched until the whole run is known to be ours. A run half-rebuilt is worse
        -- than a run left at its old spacing.
        if #interior > want then
            for j = want + 1, #interior do
                if live(interior[j]) and not jxMayDelete(interior[j].x, interior[j].z) then return end
            end
        end

        -- Move what can be moved, so ids survive wherever they can.
        local keepN = math.min(#interior, want)
        for j = 1, keepN do
            local w, t = interior[j], targets[j]
            ADGraphManager:moveWayPoint(w.id, t.x, t.y, t.z, w.flags, false)
            moved = moved + 1
        end
        local last = (keepN > 0) and interior[keepN] or A
        if #interior > want then
            -- Surplus: bridge over it first, then take it out. Objects, not ids - every removal
            -- renumbers the ids above it.
            link(last, B)
            for j = #interior, want + 1, -1 do
                local w = interior[j]
                if live(w) and jxRemove(w, "junction respace surplus") then
                    removed = removed + 1
                end
            end
        elseif #interior < want then
            -- Shortfall: open the last link and chain the new points into it.
            junctionDisconnect(last, B)
            local prev = last
            for j = keepN + 1, want do
                local t = targets[j]
                local made = ADGraphManager:recordWayPoint(t.x, t.y, t.z, false, false, false, 0, flags, false)
                if made == nil then break end
                link(prev, made)
                prev = made
                created = created + 1
            end
            link(prev, B)
        end
    end

    local STEP0 = STEP
    for _, lane in ipairs(jp._laneSeqs or {}) do
        -- A lane may bring its own maximum spacing (read off the span itself); otherwise the default.
        STEP = lane.step or STEP0
        local seq = lane.seq
        local n = #seq
        while n > 0 and not live(seq[n]) do n = n - 1 end
        if n >= 3 then
            -- SMOOTH BACK TO THE NEXT JUNCTION, AND NOT ONE POINT PAST IT. The walk used to run a
            -- flat 50 m regardless of what it passed through. Where the next junction is nearer than
            -- that - 24 m away at one pair on the test map - it resampled straight through the
            -- neighbour and out the other side, moving its points and bridging links across it: the
            -- road far from the junction visibly changing, and clearing one of the pair wiring up the
            -- other. A fork is where this road stops being this junction's approach, so the walk
            -- stops there.
            local i0, acc = n, 0
            while i0 > 1 and acc < (lane.len or LEN) and live(seq[i0 - 1])
                and neighbours(seq[i0 - 1]) < 3 do
                acc = acc + gap(seq[i0], seq[i0 - 1])
                i0 = i0 - 1
            end
            local a = i0
            for b = i0 + 1, n do
                local w = seq[b]
                -- WHERE THIS JUNCTION'S REACH RUNS OUT IS A RUN BOUNDARY, exactly like a fork.
                --
                -- A run is broken at every point that must not move: the far end, a fork, anything
                -- already handled. The edge of the junction's own arms belongs on that list. Without
                -- it a run would start at the box and end 50 m away, and since the rebuild is all or
                -- nothing it was thrown away whole - so the points it was entitled to tidy, the ones
                -- a few metres from the box, were left exactly as the old junction had them: pairs
                -- 1 to 2 m apart on a road otherwise spaced at 5.
                --
                -- Clipped here instead, the near part is a run of its own and is rebuilt properly,
                -- and the far part is simply not this junction's to touch. Neither abandoned nor
                -- half-done.
                local fixed = (b == n) or neighbours(w) >= 3 or marker[w] or done[w]
                    or not jxMayDelete(w.x, w.z)
                if fixed then
                    -- A run is only worth touching if none of it was handled already.
                    local fresh = not (done[seq[a]] and done[w])
                    if fresh and b - a >= 1 then
                        local nodes = {}
                        for i = a, b do nodes[#nodes + 1] = seq[i] end
                        local ok = true
                        for _, q in ipairs(nodes) do if not live(q) then ok = false break end end
                        if ok then tryCall("junction respace run", respaceRun, nodes) end
                    end
                    a = b
                end
            end
            for i = i0, n do done[seq[i]] = true end
        end
    end
    return moved, removed, created
end

--- THE LANE-END TIDY, BY PATHS. Nothing is constructed.
---
--- A through road already HAS a line across its junction: the path it ran on. So each through path
--- is smoothed whole with the smooth tool's rebuild - by now its old tie-in nodes are plain points, so
--- nothing is pinned and what they left in it irons out - and then, when through paths are being
--- cleared, it is CUT where it enters and leaves the box: a point put exactly on each edge, and
--- what lies between removed. A side-road lane has no path across (building the junction consumed
--- it), so it is smoothed and then carried on its own heading, read from its clean stretch, to the
--- main road's offset line. No centres, no widths, no run-ins laid onto lane ends.
---
--- The box still comes from the road centrelines (the dry run works it out); it only says where to cut.
function ADFlyoverEditor:junctionTidyByPaths(jp)
    local box = jp._box
    local routes = jp.pathRoutes
    if box == nil or routes == nil then return nil end
    local leave = self.junctionLeaveThrough ~= false
    local STEP = AutoDrive.FLYOVER_JUNCTION_RESPACE_STEP or 5

    local function live(w) return w ~= nil and w.id ~= nil and ADGraphManager:getWayPointById(w.id) == w end
    local function distLine(line, x, z)
        local best = math.huge
        for k = 2, #line do
            local ax, az = line[k - 1].x, line[k - 1].z
            local vx, vz = line[k].x - ax, line[k].z - az
            local L2 = vx * vx + vz * vz
            if L2 > 1e-9 then
                local t = math.max(0, math.min(1, ((x - ax) * vx + (z - az) * vz) / L2))
                local d = (x - (ax + vx * t)) ^ 2 + (z - (az + vz * t)) ^ 2
                if d < best then best = d end
            end
        end
        return math.sqrt(best)
    end
    local reach2 = (math.max(box.a.offset, box.b.offset) * 1.5 + 2) ^ 2
    local function inBox(x, z)
        if (x - box.centre.x) ^ 2 + (z - box.centre.z) ^ 2 > reach2 then return false end
        return distLine(box.a.centre, x, z) <= box.a.offset and distLine(box.b.centre, x, z) <= box.b.offset
    end
    -- In the claim of the road a side lane MEETS: whichever of the two it is not running along.
    local function inOther(x, z, hx, hz)
        local function along(r)
            local c = r.centre
            local bi, bd = 1, math.huge
            for k = 1, #c do
                local d = (c[k].x - box.centre.x) ^ 2 + (c[k].z - box.centre.z) ^ 2
                if d < bd then bd, bi = d, k end
            end
            local a, b = c[math.max(1, bi - 2)], c[math.min(#c, bi + 2)]
            local vx, vz = b.x - a.x, b.z - a.z
            local l = math.sqrt(vx * vx + vz * vz)
            if l < 1e-6 then return 0 end
            return math.abs((vx / l) * hx + (vz / l) * hz)
        end
        local other = (along(box.a) < along(box.b)) and box.a or box.b
        if (x - box.centre.x) ^ 2 + (z - box.centre.z) ^ 2 > 40 * 40 then return false end
        return distLine(other.centre, x, z) <= other.offset
    end
    local function dualOf(a, b)
        return table.contains(a.out or {}, b.id) and table.contains(b.out or {}, a.id)
    end

    -- Smooth a whole lane with the respacing (the smooth tool's rebuild), then hand back the lane as
    -- it now is: walked from its first node along travel links, hugging the old polyline.
    --
    -- `lastStep` is the spacing the LAST lane smoothed was rebuilt at - read off that lane's own
    -- points, not a constant - and the legs cut at the box edge are rebuilt at the same spacing so a
    -- road comes back looking like itself. It has to be declared HERE, above the function that
    -- writes it: declared below, `lastStep = own` inside smoothLane bound to a global instead, the
    -- local stayed nil for the whole clear, and every leg was respaced at the default spacing.
    local n0 = nil
    local lastStep = nil
    local function smoothLane(nodes, useOut)
        -- ONLY AS FAR AS THE FIRST FORK. Smoothing deletes and re-creates the points between the
        -- nodes it pins, and over 50 m of road that reaches into whatever else is tied in along the
        -- way - which is how a clear came to break a neighbouring junction's connection. A fork is
        -- where something else joins, so the fairing stops there; it is also pinned, so where a fork
        -- sits right against the box (nothing would be smoothed at all) the span carries on past it
        -- to a MINIMUM of 15 m and the fork itself still never moves.
        local live0 = {}
        for _, n in ipairs(nodes) do if live(n) then live0[#live0 + 1] = n end end
        if #live0 < 3 then return live0 end
        local function isFork(w)
            local seen, d = {}, 0
            for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                for _, id in pairs(lst) do if not seen[id] then seen[id] = true d = d + 1 end end
            end
            return d >= 3
        end
        local mid, md = 1, math.huge
        for i, n in ipairs(live0) do
            local d = (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2
            if d < md then md, mid = d, i end
        end
        local function reach(from, step)
            local i, run = from, 0
            while true do
                local j = i + step
                if j < 1 or j > #live0 then return i end
                run = run + math.sqrt((live0[j].x - live0[i].x) ^ 2 + (live0[j].z - live0[i].z) ^ 2)
                i = j
                if run >= 50 then return i end
                if isFork(live0[i]) and run >= 15 then return i end
            end
        end
        local lo, hi = reach(mid, -1), reach(mid, 1)
        local seq = {}
        for i = lo, hi do seq[#seq + 1] = live0[i] end
        if #seq < 3 then return seq end
        local old = {}
        for i, n in ipairs(seq) do old[i] = { x = n.x, z = n.z } end
        local first, last = seq[1], seq[#seq]
        -- THE MAXIMUM SPACING IS THE SPAN'S OWN. A road recorded at 13 m and one laid at 5 m should
        -- each come back looking like themselves, so the rebuild's max spacing is read off the span:
        -- the upper-quartile gap between its points as they were (the straights set it; the dense
        -- bits of old wiring do not drag it down), kept within sane bounds.
        local gaps = {}
        for i = 2, #seq do
            gaps[#gaps + 1] = math.sqrt((seq[i].x - seq[i - 1].x) ^ 2 + (seq[i].z - seq[i - 1].z) ^ 2)
        end
        table.sort(gaps)
        local own = gaps[math.max(1, math.ceil(#gaps * 0.75))] or STEP
        own = math.max(4, math.min(15, own))
        lastStep = own
        jp._laneSeqs = { { seq = seq, useOut = useOut, len = 1e9, step = own } }
        tryCall("junction smooth path", function() self:junctionRespaceApproaches(jp) end)
        n0 = #seq
        local out, node, came = { first }, first, nil
        for _ = 1, 600 do
            if node == last then break end
            local list = useOut and (node.out or {}) or (node.incoming or {})
            local best, bd = nil, math.huge
            for _, id in pairs(list) do
                local nx = ADGraphManager:getWayPointById(id)
                if nx ~= nil and nx ~= came then
                    local d = distLine(old, nx.x, nx.z)
                    if d < bd then bd, best = d, nx end
                end
            end
            if best == nil or bd > 3 then break end
            came, node = node, best
            out[#out + 1] = node
        end
        return out
    end

    local made, cutN, removed = 0, 0, 0
    local ends = {}
    local keep = {}

    -- Put a point at (x, z) between a and b (a before b along `fwd` travel), and return it.
    local function splitAt(a, b, x, z, fwdAB)
        local dual = dualOf(a, b)
        local y = (a.y or 0) + ((b.y or 0) - (a.y or 0)) * 0.5
        local n = ADGraphManager:recordWayPoint(x, y, z, false, false, false, 0, a.flags or AutoDrive.FLAG_NONE, false)
        if n == nil then return nil end
        junctionDisconnect(a, b)
        if fwdAB then junctionConnect(a, n, dual) junctionConnect(n, b, dual)
        else junctionConnect(n, a, dual) junctionConnect(b, n, dual) end
        made = made + 1
        return n
    end

    local afterCut = {}
    -- THROUGH PATHS
    -- Points per metre of a run of positions.
    local function density(list)
        if #list < 2 then return nil end
        local L = 0
        for i = 2, #list do L = L + math.sqrt((list[i].x - list[i - 1].x) ^ 2 + (list[i].z - list[i - 1].z) ^ 2) end
        if L < 1 then return nil end
        return (#list - 1) / L
    end
    local function segCrosses(a, b)
        local vx, vz = b.x - a.x, b.z - a.z
        local len = math.sqrt(vx * vx + vz * vz)
        for k = 1, math.floor(len / 0.5) do
            local t = k * 0.5 / len
            if inBox(a.x + vx * t, a.z + vz * t) then return true end
        end
        return false
    end
    for _, nodes in ipairs(routes.through or {}) do
        -- THE ORIGINAL DENSITY OF EACH LEG, read before anything moves: the path's own points on the
        -- way in to the box and on the way out of it, within 50 m.
        local before, after, passed = {}, {}, false
        local prevN = nil
        for _, n in ipairs(nodes) do
            if live(n) and (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2 <= 50 * 50 then
                local inside = inBox(n.x, n.z)
                if not passed and (inside or (prevN ~= nil and segCrosses(prevN, n))) then passed = true end
                if not inside then
                    if passed then after[#after + 1] = { x = n.x, z = n.z }
                    else before[#before + 1] = { x = n.x, z = n.z } end
                end
                prevN = n
            end
        end
        local densIn, densOut = density(before), density(after)
        local lane = smoothLane(nodes, true)
        for _, n in ipairs(lane) do keep[n] = true end
        if not leave and #lane >= 2 then
            -- where it enters and leaves the box, to a quarter metre
            local i = 1
            while i < #lane do
                local a, b = lane[i], lane[i + 1]
                local ina, inb = inBox(a.x, a.z), inBox(b.x, b.z)
                if ina ~= inb then
                    local lo, hi = 0, 1
                    for _ = 1, 12 do
                        local t = (lo + hi) * 0.5
                        local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
                        if inBox(x, z) == ina then lo = t else hi = t end
                    end
                    local t = ina and hi or lo   -- the point just OUTSIDE the box
                    local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
                    local outside = ina and b or a
                    if (outside.x - x) ^ 2 + (outside.z - z) ^ 2 > 0.75 ^ 2 then
                        local n = splitAt(a, b, x, z, true)
                        if n ~= nil then
                            keep[n] = true
                            table.insert(lane, i + 1, n)
                            ends[#ends + 1] = n
                            -- n sits outside; the inside neighbour is cut off from it
                            if ina then junctionDisconnect(a, n) else junctionDisconnect(n, b) end
                            cutN = cutN + 1
                            i = i + 1
                        end
                    else
                        ends[#ends + 1] = outside
                        junctionDisconnect(a, b)
                        cutN = cutN + 1
                    end
                elseif not ina and not inb then
                    -- a long link can cross the box with both ends outside it
                    local vx, vz = b.x - a.x, b.z - a.z
                    local len = math.sqrt(vx * vx + vz * vz)
                    local t0, t1 = nil, nil
                    for k = 1, math.floor(len / 0.25) do
                        local t = (k * 0.25) / len
                        if inBox(a.x + vx * t, a.z + vz * t) then
                            if t0 == nil then t0 = t end
                            t1 = t
                        end
                    end
                    if t0 ~= nil then
                        local n1 = splitAt(a, b, a.x + vx * math.max(0, t0 - 0.25 / len), a.z + vz * math.max(0, t0 - 0.25 / len), true)
                        if n1 ~= nil then
                            local n2 = splitAt(n1, b, a.x + vx * math.min(1, t1 + 0.25 / len), a.z + vz * math.min(1, t1 + 0.25 / len), true)
                            if n2 ~= nil then
                                junctionDisconnect(n1, n2)
                                keep[n1], keep[n2] = true, true
                                ends[#ends + 1] = n1
                                ends[#ends + 1] = n2
                                table.insert(lane, i + 1, n1)
                                table.insert(lane, i + 2, n2)
                                cutN = cutN + 1
                                i = i + 2
                            end
                        end
                    end
                end
                i = i + 1
            end
        end

        -- AND EACH APPROACH REBUILT AT THE DENSITY IT HAD - WHETHER THE THROUGH PATHS WERE CUT OR
        -- LEFT. This decides the spacing on the run into the junction, and it used to sit inside the
        -- "not leave" branch above purely because it was written alongside the trimming. It does not
        -- depend on the trimming: it splits the lane where it meets the box and rebuilds each side
        -- at the density that side had before anything moved, which is as true of a lane left whole
        -- as of one cut in two.
        --
        -- Left where it was, a clear with through paths kept never restored the density of a through
        -- approach at all - those roads came back with whatever spacing the old junction's connector
        -- hookups had left them, which is the pairs a metre or two apart still sitting a few metres
        -- off the box after everything else had been tidied.
        if #lane >= 2 then
            local half, nHalves = {}, 0
            for _, n in ipairs(lane) do
                if live(n) and not inBox(n.x, n.z) then
                    half[#half + 1] = n
                elseif #half > 0 then
                    -- the entry side: runs outer end -> box, the way the lane is travelled
                    afterCut[#afterCut + 1] = { seq = half, useOut = true, step = lastStep, len = 1e9, dens = densIn }
                    nHalves = nHalves + 1
                    half = {}
                end
            end
            if #half > 0 and nHalves > 0 then
                -- the exit side: box -> outer end as travelled, so reversed to end on the box too
                local rev = {}
                for k = #half, 1, -1 do rev[#rev + 1] = half[k] end
                afterCut[#afterCut + 1] = { seq = rev, useOut = false, step = lastStep, len = 1e9, dens = densOut }
            end
        end
    end

    local function cleanPair(sl, lane)
        local near, far, ni = nil, nil, nil
        if sl.cutNode ~= nil then
            for i, n in ipairs(lane) do if n == sl.cutNode then ni = i break end end
            -- The tie node was spliced in by the build and can sit a little off the lane; the
            -- point BEFORE it is original road, so the lane ends there and is laid fresh from it.
            if ni ~= nil and ni >= 3 then ni = ni - 1 end
            if ni ~= nil and ni >= 2 then
                near = lane[ni]
                for j = ni - 1, 1, -1 do
                    local m = lane[j]
                    -- A SHORT baseline, 8 m. The tie node is already out of it (that was what
                    -- tilted a short baseline before), and on a road that bends steadily all the
                    -- way in, a long chord points where the road WAS: 25 m read the heading
                    -- 10 degrees behind the road's heading at its end, and the carry drifted off.
                    if (m.x - near.x) ^ 2 + (m.z - near.z) ^ 2 >= 8 * 8 then far = m break end
                end
                if far == nil then far = lane[1] end
                if far == near then near, far, ni = nil, nil, nil end
            else
                ni = nil
            end
        end
        for i = #lane, 1, -1 do
            if near ~= nil then break end
            local n = lane[i]
            if (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2 >= 22 * 22 then
                near, ni = n, i
                for j = i - 1, 1, -1 do
                    local m = lane[j]
                    if (m.x - n.x) ^ 2 + (m.z - n.z) ^ 2 >= 15 * 15 then far = m break end
                end
                break
            end
        end
        return near, far, ni
    end

    -- ONE HEADING PER ROAD, NOT ONE PER LANE. Each side lane used to be carried to the box on a
    -- heading read off its own last few metres, and two lanes of one road never read quite the same:
    -- a degree apart is 30 cm over the carry, so the pair converged or spread on the way in, and
    -- where both leaned the same way the whole branch drifted off its road. The lanes of one road are
    -- parallel by definition, so the road gets ONE heading - the mean of its lanes' inward headings,
    -- every lane's list running outer end first whichever way it is driven - and each lane is carried
    -- on that from its own clean node. Parallel by construction: the width at the clean nodes is the
    -- width at the box.
    local sharedHeading = {}
    do
        local reads = {}
        for _, sl in ipairs(routes.side or {}) do
            local lane = {}
            for _, n in ipairs(sl.nodes) do if live(n) then lane[#lane + 1] = n end end
            if #lane >= 2 then
                local near, far = cleanPair(sl, lane)
                if near ~= nil and far ~= nil then
                    local hx, hz = near.x - far.x, near.z - far.z
                    local hl = math.sqrt(hx * hx + hz * hz)
                    if hl > 0.5 then reads[#reads + 1] = { sl = sl, hx = hx / hl, hz = hz / hl, x = near.x, z = near.z, near = near, lane = lane } end
                end
            end
        end
        local used = {}
        for i, r in ipairs(reads) do
            if not used[i] then
                local grp, sx, sz = { r }, r.hx, r.hz
                used[i] = true
                for j = i + 1, #reads do
                    local q = reads[j]
                    -- same road: heading within 20 degrees, and no more than a road's width apart sideways
                    if not used[j] and (q.hx * r.hx + q.hz * r.hz) >= math.cos(math.rad(20)) then
                        local side = math.abs((q.x - r.x) * -r.hz + (q.z - r.z) * r.hx)
                        if side <= 12 then
                            used[j] = true
                            grp[#grp + 1] = q
                            sx, sz = sx + q.hx, sz + q.hz
                        end
                    end
                end
                local l = math.sqrt(sx * sx + sz * sz)
                if #grp >= 2 and l > 0 then
                    -- THE HEADING OF THE LANE CUT NEAREST THE JUNCTION, NOT THE MEAN. Headings read at
                    -- different stations on a bend are not the same quantity: one lane read 106
                    -- degrees 11 m out, its partner 98 degrees 30 m back where the road still
                    -- pointed that way, and their mean - 102 - was wrong for both. Both lanes were
                    -- carried 4 degrees off and arrived 1.2 m to one side of their box. The mean
                    -- is kept only where the lanes were read at about the same place.
                    local gx, gz = sx / l, sz / l
                    local nearG, nearD, farD = nil, math.huge, 0
                    for _, g in ipairs(grp) do
                        local d = math.sqrt((g.near.x - box.centre.x) ^ 2 + (g.near.z - box.centre.z) ^ 2)
                        if d < nearD then nearD, nearG = d, g end
                        if d > farD then farD = d end
                    end
                    if nearG ~= nil and farD - nearD > 5 then gx, gz = nearG.hx, nearG.hz end
                    for _, g in ipairs(grp) do sharedHeading[g.sl] = { hx = gx, hz = gz } end
                    -- THE LANES OF ONE ROAD ARE CUT AT THE SAME PLACE. Each lane finds its own clean
                    -- node, and on a bend they disagree wildly: one lane of a side road had a plain
                    -- tie node 11 m out while the search for where its partner's swing began ran back
                    -- up the curve to 30 m - eight points of road dug up and re-laid as an arc beside
                    -- a lane left almost untouched, and the pair 0.6 m wider at the box than up the
                    -- road. The lane cut NEAREST the junction is the evidence that the road is clean
                    -- from there, so its station is every lane's station.
                    local nearest = math.huge
                    for _, g in ipairs(grp) do
                        local d = math.sqrt((g.near.x - box.centre.x) ^ 2 + (g.near.z - box.centre.z) ^ 2)
                        if d < nearest then nearest = d end
                    end
                    local grpState = { width = nil }
                    for _, g in ipairs(grp) do
                        local sh = sharedHeading[g.sl]
                        sh.station = math.sqrt((g.near.x - box.centre.x) ^ 2 + (g.near.z - box.centre.z) ^ 2)
                        sh.nearest, sh.group = nearest, grpState
                    end
                end
                -- AND THE ROAD'S OWN WIDTH, FROM WHERE IT STILL HAS IT. The node before a tie node is
                -- already on the flare - the lanes spread for their turns before the connectors
                -- leave them - so a carry that is merely parallel preserves the flare all the way
                -- to the box: 4.2 m apart at the clean nodes of a road that is 4.0 m wide. The width
                -- is read well back up the branch (the middle of the readings, as for the box),
                -- and each lane's carry runs along the centreline offset by half of it. The clean
                -- node is eased onto that line, a few decimetres at most.
                if #grp == 2 and l > 0 then
                    local A, B = grp[1], grp[2]
                    local hx, hz = sx / l, sz / l
                    local reads2 = {}
                    for _, p in ipairs(A.lane) do
                        local db = (p.x - box.centre.x) ^ 2 + (p.z - box.centre.z) ^ 2
                        if db >= 14 * 14 and db <= 40 * 40 then
                            local best = math.huge
                            for k = 1, #B.lane - 1 do
                                local u, v = B.lane[k], B.lane[k + 1]
                                local dx, dz = v.x - u.x, v.z - u.z
                                local L = dx * dx + dz * dz
                                local t = (L > 0) and math.max(0, math.min(1, ((p.x - u.x) * dx + (p.z - u.z) * dz) / L)) or 0
                                local d = math.sqrt((u.x + dx * t - p.x) ^ 2 + (u.z + dz * t - p.z) ^ 2)
                                if d < best then best = d end
                            end
                            if best < 12 then reads2[#reads2 + 1] = best end
                        end
                    end
                    if #reads2 >= 2 then
                        table.sort(reads2)
                        local w = reads2[math.floor((#reads2 + 1) / 2)]
                        local mx, mz = (A.near.x + B.near.x) / 2, (A.near.z + B.near.z) / 2
                        local px, pz = -hz, hx
                        for _, g in ipairs(grp) do
                            local lat = (g.near.x - mx) * px + (g.near.z - mz) * pz
                            local want = (lat >= 0 and 1 or -1) * w / 2
                            local delta = want - lat
                            if math.abs(delta) <= 0.6 then
                                sharedHeading[g.sl].dx, sharedHeading[g.sl].dz = px * delta, pz * delta
                            end
                        end
                    end
                end
            end
        end
    end

    -- SIDE-ROAD LANES - the lane cut nearest the junction first: it is the clean one, and its
    -- finished line is what its partner is laid beside.
    local sideOrder = {}
    for _, sl in ipairs(routes.side or {}) do sideOrder[#sideOrder + 1] = sl end
    table.sort(sideOrder, function(p, q)
        local a1 = sharedHeading[p] and sharedHeading[p].station or math.huge
        local b1 = sharedHeading[q] and sharedHeading[q].station or math.huge
        return a1 < b1
    end)
    for _, sl in ipairs(sideOrder) do
        -- TRIM AND CARRY FIRST, SMOOTH LAST. Smoothing a lane that still has the first swing of an old
        -- kickout on its end bakes that swing into the lane; the clean line has to be read off the
        -- lane as it was recorded, and the off-line nodes gone, before anything is smoothed.
        local lane = {}
        for _, n in ipairs(sl.nodes) do if live(n) then lane[#lane + 1] = n end end
        if #lane >= 2 then
            -- its own heading, from its clean stretch: the last node 22 m or more from the box (an old
            -- kickout can begin 16-20 m out) and one at least 15 m behind it, so one node's wobble
            -- cannot set the heading
            local near, far, ni = cleanPair(sl, lane)
            if near ~= nil and far ~= nil then
                local hx, hz = near.x - far.x, near.z - far.z
                local hl = math.sqrt(hx * hx + hz * hz)
                hx, hz = hx / hl, hz / hl
                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                    Logging.info("[FlyoverEditor]: CARRY lane of %d: own heading %.1f deg, shared %s, clean node #%d (%.1f, %.1f) %.1f m from box, tip %.1f m",
                        #lane, math.deg(math.atan2(hx, hz)),
                        sharedHeading[sl] and string.format("%.1f deg", math.deg(math.atan2(sharedHeading[sl].hx, sharedHeading[sl].hz))) or "none",
                        ni, near.x, near.z, math.sqrt((near.x - box.centre.x) ^ 2 + (near.z - box.centre.z) ^ 2),
                        math.sqrt((lane[#lane].x - box.centre.x) ^ 2 + (lane[#lane].z - box.centre.z) ^ 2))
                end
                if sharedHeading[sl] ~= nil and AutoDrive.FLYOVER_JUNCTION_SHARED_HEADING ~= false then
                    hx, hz = sharedHeading[sl].hx, sharedHeading[sl].hz
                    local sh = sharedHeading[sl]
                    if sh.dx ~= nil and live(near) then
                        tryCall("junction ease clean node", function()
                            ADGraphManager:moveWayPoint(near.id, near.x + sh.dx, near.y, near.z + sh.dz, near.flags, false)
                        end)
                    end
                end
                -- A CHORD POINTS WHERE THE ROAD WAS HALFWAY ALONG IT, NOT WHERE IT IS POINTING AT THE
                -- END. On a side road that curves into its junction that is a large error - eleven
                -- metres of chord came in 19 degrees off the road's real heading at the tie node, and
                -- since this heading sets the road's claim band, the whole box rotated with it and
                -- sat up the road from where the two roads actually meet.
                --
                -- The correction is exact for an arc and needs no fit: turn the chord on by HALF the
                -- angle the road turns across it, which is read straight off the lane's own points.
                -- A straight road turns zero and is unaffected.
                do
                    local turn, pv = 0, nil
                    local started = false
                    for j = 1, ni do
                        local m = lane[j]
                        if m == far then started = true end
                        if started and pv ~= nil then
                            local a = math.atan2(m.x - pv.x, m.z - pv.z)
                            if pv.prevAng ~= nil then
                                local d = a - pv.prevAng
                                while d > math.pi do d = d - 2 * math.pi end
                                while d < -math.pi do d = d + 2 * math.pi end
                                turn = turn + d
                            end
                            m.prevAng = a
                        end
                        if started then pv = m end
                    end
                    for j = 1, ni do lane[j].prevAng = nil end
                    -- AND HERE IT IS NOT APPLIED. laneArc's chord spans ten metres of a bending
                    -- road, where the gap between chord and tangent is real and worth correcting.
                    -- This one is read over a short span at the lane's own clean end, where the two
                    -- have barely diverged - correcting it only over-rotates. Measured: it pushed
                    -- the two tracks of one side road from 1.20 m apart within their claim band to
                    -- 1.75 m, and changed nothing whatever at the junction next door. The turn is
                    -- still worked out above because it is what says whether there is anything to
                    -- correct; acting on it here is what was wrong.
                    -- ...AND NOW IT IS APPLIED AGAIN. What over-rotated was each lane correcting its
                    -- OWN heading, so the pair splayed. Both lanes now take the heading of the lane
                    -- cut nearest the junction, and on a road that keeps bending in, that chord
                    -- lags the road by a few degrees over the last 11 m - both lanes arrived 1.2 m
                    -- to one side of their box. Corrected, they arrive within 0.3 m; at junctions
                    -- that were already right it costs 0.15 m at most.
                    if AutoDrive.FLYOVER_JUNCTION_CARRY_TANGENT == false then turn = 0 end
                    local half = turn * 0.5
                    local cs, sn = math.cos(half), math.sin(half)
                    hx, hz = hx * cs - hz * sn, hx * sn + hz * cs
                end
                -- THE ROAD'S OWN CURVE, from the clean stretch. A side road that bends gently on its
                -- way in came back STRAIGHT over its last 22 m when it was carried on a heading alone,
                -- which left it pointing off its road. Curvature is read from three clean points - the
                -- clean node, the baseline node, and one as far behind that again - and the carry is
                -- an arc of that curvature, leaving the clean node on the arc's own tangent. A road
                -- that is straight reads as (nearly) zero and is carried straight, as before.
                local kCurve = 0
                -- THE ROAD'S OWN BEND, BUT ONLY WHERE THE CARRY IS LONG ENOUGH TO NEED IT. A short
                -- carry is straight to within a few centimetres whatever the road does, and bending
                -- it on a curvature read from three points made every short one worse. A long one -
                -- 20 m at a skew T, whose tie nodes sit far back - leaves a bending road altogether
                -- if it is laid straight. There the bend is read from the WHOLE clean stretch: the
                -- heading change between its first and last segments over the length between them,
                -- which one wobbling node cannot swing the way it swings a three-point circle.
                do
                    local carryLen = math.sqrt((near.x - box.centre.x) ^ 2 + (near.z - box.centre.z) ^ 2)
                    local MODE = AutoDrive.FLYOVER_JUNCTION_CARRY_CURVE
                    if MODE ~= false and carryLen >= (AutoDrive.FLYOVER_JUNCTION_CARRY_CURVE_MIN or 15) then
                        -- segments of the clean stretch, walking back from the clean node up to 45 m
                        local segs, acc = {}, 0
                        for j = ni, 2, -1 do
                            local p, q = lane[j - 1], lane[j]
                            local L = math.sqrt((q.x - p.x) ^ 2 + (q.z - p.z) ^ 2)
                            if L > 0.5 then
                                segs[#segs + 1] = { ang = math.atan2(q.x - p.x, q.z - p.z), mid = acc + L / 2, len = L }
                            end
                            acc = acc + L
                            if acc >= 45 then break end
                        end
                        if #segs >= 3 then
                            local first, last = segs[#segs], segs[1]   -- farthest back, nearest the node
                            local d = last.ang - first.ang
                            while d > math.pi do d = d - 2 * math.pi end
                            while d < -math.pi do d = d + 2 * math.pi end
                            local span = first.mid - last.mid
                            if span > 8 then
                                kCurve = math.max(-1 / 40, math.min(1 / 40, d / span))
                                -- leave the clean node on the arc's own tangent: the last segment's
                                -- heading, turned on by the half segment between its middle and the node
                                local t = last.ang + kCurve * last.len * 0.5
                                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                                    Logging.info("[FlyoverEditor]: CURVE carry %.0f m: turn %.1f deg over %.0f m -> radius %.0f m; heading %.1f -> %.1f deg",
                                        carryLen, math.deg(d), span, kCurve ~= 0 and math.abs(1 / kCurve) or 0,
                                        math.deg(math.atan2(hx, hz)), math.deg(t))
                                end
                                hx, hz = math.sin(t), math.cos(t)
                            end
                        end
                    end
                end
                -- points along the carry, every quarter metre from the clean node
                local arc = { { x = near.x, z = near.z } }
                do
                    local px, pz, ax2, az2 = near.x, near.z, hx, hz
                    for _ = 1, 320 do
                        local dth = kCurve * 0.25
                        local cs, sn = math.cos(dth), math.sin(dth)
                        ax2, az2 = ax2 * cs - az2 * sn, ax2 * sn + az2 * cs
                        px, pz = px + ax2 * 0.25, pz + az2 * 0.25
                        arc[#arc + 1] = { x = px, z = pz }
                    end
                end
                -- A LANE CUT FAR BACK IS LAID BESIDE ITS PARTNER, NOT ON A GUESS. On a bend the two
                -- lanes of a road find very different clean nodes - one a plain tie node 11 m out,
                -- the other 30 m back, because its last 20 m already carry the old kickout's swing.
                -- Carrying that one 30 m on a heading or a fitted arc is a guess at a road whose
                -- true line is lying right beside it: the partner, already finished. So it is laid
                -- as that line moved sideways by the road's own width - parallel by construction,
                -- round whatever bend the road makes.
                do
                    local sh = sharedHeading[sl]
                    local gs = sh and sh.group or nil
                    if gs ~= nil and gs.refLine ~= nil and sh.station > (sh.nearest or 0) + 5
                        and AutoDrive.FLYOVER_JUNCTION_SHARED_HEADING ~= false then
                        local ref = gs.refLine
                        -- WHERE THIS LANE'S SWEEP BEGINS IS WHERE IT STOPS RUNNING PARALLEL TO ITS
                        -- PARTNER. Reading it off the lane's own turning fails on a road whose
                        -- curve changes - it put the start 30 m out, and a second attempt 48 m.
                        -- Two lanes of one road keep their distance whatever the road does, so the
                        -- lane is clean for as long as its distance to the partner's line holds,
                        -- and the clean node is the last point where it still does.
                        local function toRef(px, pz)
                            local best = math.huge
                            for i = 1, #ref - 1 do
                                local u, v = ref[i], ref[i + 1]
                                local dx, dz = v.x - u.x, v.z - u.z
                                local L = dx * dx + dz * dz
                                local t = (L > 0) and math.max(0, math.min(1, ((px - u.x) * dx + (pz - u.z) * dz) / L)) or 0
                                local d = math.sqrt((u.x + dx * t - px) ^ 2 + (u.z + dz * t - pz) ^ 2)
                                if d < best then best = d end
                            end
                            return best
                        end
                        local ws = {}
                        for i = 1, ni do ws[#ws + 1] = toRef(lane[i].x, lane[i].z) end
                        if #ws >= 2 then
                            local sorted = {}
                            for _, v in ipairs(ws) do sorted[#sorted + 1] = v end
                            table.sort(sorted)
                            local w0 = sorted[math.floor((#sorted + 1) / 2)]
                            local lastPar = ni
                            for i = ni + 1, #lane do
                                local dv = toRef(lane[i].x, lane[i].z) - w0
                                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                                    Logging.info("[FlyoverEditor]: PARALLEL #%d (%.1f, %.1f): %.2f m from partner, road width %.2f -> off by %+.2f",
                                        i, lane[i].x, lane[i].z, dv + w0, w0, dv)
                                end
                                if math.abs(dv) <= 0.4 then lastPar = i else break end
                            end
                            if lastPar > ni then
                                ni, near = lastPar, lane[lastPar]
                                arc = { { x = near.x, z = near.z } }
                            end
                        end
                        -- which side of the partner this lane lies on, and how far, read where this
                        -- lane is still clean
                        local bi, bd = 1, math.huge
                        for i = 1, #ref do
                            local d = (ref[i].x - near.x) ^ 2 + (ref[i].z - near.z) ^ 2
                            if d < bd then bd, bi = d, i end
                        end
                        local i2 = math.min(#ref, bi + 1)
                        local i1 = math.max(1, i2 - 1)
                        local tx, tz = ref[i2].x - ref[i1].x, ref[i2].z - ref[i1].z
                        local tl = math.sqrt(tx * tx + tz * tz)
                        if tl > 0.01 then
                            tx, tz = tx / tl, tz / tl
                            local lat = (near.x - ref[bi].x) * -tz + (near.z - ref[bi].z) * tx
                            local off = {}
                            for i = bi, #ref do
                                local j2 = math.min(#ref, i + 1)
                                local j1 = math.max(1, j2 - 1)
                                local ux, uz = ref[j2].x - ref[j1].x, ref[j2].z - ref[j1].z
                                local ul = math.sqrt(ux * ux + uz * uz)
                                if ul > 0.01 then
                                    ux, uz = ux / ul, uz / ul
                                    off[#off + 1] = { x = ref[i].x + -uz * lat, z = ref[i].z + ux * lat }
                                end
                            end
                            if #off >= 2 then
                                -- resampled every quarter metre, and run on straight past the end
                                local fine = { { x = near.x, z = near.z } }
                                for i = 1, #off do
                                    local p = fine[#fine]
                                    local dx, dz = off[i].x - p.x, off[i].z - p.z
                                    local L = math.sqrt(dx * dx + dz * dz)
                                    local n = math.floor(L / 0.25)
                                    for k = 1, n do fine[#fine + 1] = { x = p.x + dx * k / n, z = p.z + dz * k / n } end
                                end
                                local p, q = fine[#fine - 1] or fine[#fine], fine[#fine]
                                local ex, ez = q.x - p.x, q.z - p.z
                                local el = math.sqrt(ex * ex + ez * ez)
                                if el > 0.001 then
                                    ex, ez = ex / el, ez / el
                                    for k = 1, 120 do fine[#fine + 1] = { x = q.x + ex * 0.25 * k, z = q.z + ez * 0.25 * k } end
                                end
                                arc = fine
                            end
                        end
                    end
                end
                -- NOTHING PAST THE CLEAN NODE SURVIVES. Keeping the nodes that still sat "on the line"
                -- (to 0.4 m) kept the first degrees of the old kickout with them: each was within
                -- tolerance, together they leaned the lane's end the way the turn used to go. The
                -- last 16 m is laid fresh along the clean heading instead.
                local lastOn = ni
                -- THE LANE'S LIST DOES NOT ALWAYS END AT THE JUNCTION. With through paths kept, the
                -- walk that builds it carries on past the connector and away down the main road -
                -- one lane came back 32 nodes long with its "tip" 69 m beyond the box - and "nothing
                -- past the clean node survives" then took the connector, which is right, and went on
                -- to take the parent road the user had asked to keep: 13 points out to 34 m, in game,
                -- at a junction 12 m across. What lies past the clean node is this lane's only as far
                -- as its connector runs, and a connector ends where it JOINS something: at the first
                -- fork, or the first point of a protected through route. From there on it is another
                -- road, and is dropped from this lane's list altogether so nothing below touches it.
                do
                    local prot = jp.protectedOf or {}
                    local stop = nil
                    for i = ni + 1, #lane do
                        local n = lane[i]
                        local seen, d = {}, 0
                        for _, lst in ipairs({ n.out or {}, n.incoming or {} }) do
                            for _, id in pairs(lst) do
                                if not seen[id] then seen[id] = true d = d + 1 end
                            end
                        end
                        if d >= 3 or prot[n] then stop = i break end
                    end
                    if stop ~= nil then
                        for i = #lane, stop, -1 do lane[i] = nil end
                    end
                    -- AND A LANE ENDS AT THE JUNCTION. By the time this runs the clear has usually cut
                    -- the connector's far link, so there is no fork left to stop at, and the list
                    -- carries straight on down the road the connector used to join: in from the
                    -- west, round the connector, and away to the south for 40 m, every point of it
                    -- plain two-link road. So the list is cut at its own closest approach to the
                    -- middle of the box. Up to there it is coming IN, and is this lane's; past there
                    -- it is going OUT, and is some other road's. No distance is involved - only
                    -- which way the lane is heading.
                    local kBest, dBest = nil, math.huge
                    for i = ni, #lane do
                        local d = (lane[i].x - box.centre.x) ^ 2 + (lane[i].z - box.centre.z) ^ 2
                        if d < dBest then dBest, kBest = d, i end
                    end
                    if kBest ~= nil and kBest < #lane then
                        for i = #lane, kBest + 1, -1 do lane[i] = nil end
                    end
                end
                -- PAST A TIE NODE THE LANE IS STILL THE LANE. A tie node is a fork ON the lane: the
                -- connector peels off there and the lane itself runs on to the junction. Those
                -- onward points are the only record of what the road does over its last stretch,
                -- and at a skew T - tie nodes 22 m out - throwing them away replaced 20 m of road
                -- with a straight guess that sat a metre off it. They are kept, and the carry runs
                -- from the lane's own end. (With NO tie node there is no telling lane from
                -- connector, and the old rule stands.)
                -- ...PROVIDED IT RUNS STRAIGHT ON. Where the side road ENDS at the junction, what lies
                -- past its tie node is not lane at all but one of its connectors, swinging away for
                -- its turn - and keeping that left a stub of old connector hanging beside the fresh
                -- lane end. A lane that continues holds its heading; a connector does not. The turn
                -- from the clean node to the tip is added up, and only a run that stays within a few
                -- degrees of straight is kept.
                local straightOn = false
                if sl.cutNode ~= nil and #lane > ni + 1 then
                    local cum, prevAng, worst = 0, nil, 0
                    for i = ni + 1, #lane do
                        local a = math.atan2(lane[i].x - lane[i - 1].x, lane[i].z - lane[i - 1].z)
                        if prevAng ~= nil then
                            local d = a - prevAng
                            while d > math.pi do d = d - 2 * math.pi end
                            while d < -math.pi do d = d + 2 * math.pi end
                            cum = cum + d
                            if math.abs(cum) > worst then worst = math.abs(cum) end
                        end
                        prevAng = a
                    end
                    -- and against the clean heading itself, so a lane that leaves at an angle from
                    -- the very first step does not pass for having no turn between its own steps
                    local a0 = math.atan2(lane[ni + 1].x - lane[ni].x, lane[ni + 1].z - lane[ni].z)
                    local d0 = a0 - math.atan2(hx, hz)
                    while d0 > math.pi do d0 = d0 - 2 * math.pi end
                    while d0 < -math.pi do d0 = d0 + 2 * math.pi end
                    straightOn = (worst <= math.rad(10)) and (math.abs(d0) <= math.rad(10))
                end
                if AutoDrive.FLYOVER_JUNCTION_KEEP_PAST_TIE ~= false and straightOn then
                    lastOn = #lane
                    near = lane[#lane]
                    arc = { { x = near.x, z = near.z } }
                    local px2, pz2 = near.x, near.z
                    for _ = 1, 320 do
                        px2, pz2 = px2 + hx * 0.25, pz2 + hz * 0.25
                        arc[#arc + 1] = { x = px2, z = pz2 }
                    end
                end
                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG and #lane - ni > 4 then
                    for i = 1, #lane do
                        local n = lane[i]
                        local seen, d = {}, 0
                        for _, lst in ipairs({ n.out or {}, n.incoming or {} }) do
                            for _, id in pairs(lst) do if not seen[id] then seen[id] = true d = d + 1 end end
                        end
                        Logging.info("[FlyoverEditor]: LANE #%02d id=%d (%.1f, %.1f) %.0f m from box, deg %d%s%s",
                            i, n.id, n.x, n.z, math.sqrt((n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2), d,
                            (jp.protectedOf or {})[n] and " PROTECTED" or "", i == ni and "  <-- clean node" or "")
                    end
                end
                if AutoDrive.FLYOVER_JUNCTION_TRIM_DEBUG then
                    local tipD = math.sqrt((lane[#lane].x - box.centre.x) ^ 2 + (lane[#lane].z - box.centre.z) ^ 2)
                    local nearD = math.sqrt((near.x - box.centre.x) ^ 2 + (near.z - box.centre.z) ^ 2)
                    Logging.info("[FlyoverEditor]: SIDETRIM lane of %d: %s, clean node #%d at %.0f m, tip at %.0f m, keeping to #%d -> removing %d",
                        #lane, sl.cutNode ~= nil and "TIE NODE path" or "fallback path",
                        ni, nearD, tipD, lastOn, #lane - lastOn)
                end
                for i = #lane, lastOn + 1, -1 do
                    local n = lane[i]
                    if live(n) then
                        jxRemove(n.id, "junction side trim")
                        removed = removed + 1
                    end
                    lane[i] = nil
                end
                -- carry on along the heading to the main road's offset line
                local tip = lane[#lane]
                local hit, s0 = nil, 0
                for k = 2, #arc do
                    if inOther(arc[k].x, arc[k].z, hx, hz) then hit = (k - 2) * 0.25 break end
                end
                if hit ~= nil and hit > 0.5 then
                    local back = lane[#lane - 1]
                    local dual = (back ~= nil) and dualOf(back, tip) or false
                    local n = math.max(1, math.floor(hit / STEP + 0.5))
                    local prev = tip
                    for k = 1, n do
                        local q = arc[math.min(#arc, math.floor((hit * k / n) / 0.25 + 0.5) + 1)]
                        local made1 = ADGraphManager:recordWayPoint(q.x, tip.y or 0, q.z,
                            false, false, false, 0, tip.flags or AutoDrive.FLAG_NONE, false)
                        if made1 == nil then break end
                        if sl.useOut then junctionConnect(prev, made1, dual) else junctionConnect(made1, prev, dual) end
                        prev = made1
                        lane[#lane + 1] = made1
                        made = made + 1
                    end
                end
                ends[#ends + 1] = lane[#lane]
                do
                    local sh = sharedHeading[sl]
                    if sh ~= nil and sh.group ~= nil and sh.group.refLine == nil then
                        local ref = {}
                        for _, n2 in ipairs(lane) do ref[#ref + 1] = { x = n2.x, z = n2.z } end
                        sh.group.refLine = ref
                    end
                end
            end
            lane = smoothLane(lane, sl.useOut)
        end
        for _, n in ipairs(lane) do keep[n] = true end
    end

    -- WHAT IS LEFT INSIDE THE BOX is junction, not road: everything there that is not a kept path.
    local theirs = jp.foreignWiring or {}
    local doomed = {}
    for _, n in pairs(ADGraphManager:getWayPoints()) do
        if n ~= nil and n.id ~= nil and inBox(n.x, n.z) and not theirs[n] and not (leave and keep[n]) then
            doomed[#doomed + 1] = n.id
        end
    end
    table.sort(doomed, function(a, b) return a > b end)
    for _, id in ipairs(doomed) do
        jxRemove(id, "junction box sweep")
        removed = removed + 1
    end

    -- SPURS - after the box is emptied, because a connector only becomes a dead end once its
    -- middle is gone. What is left of a connector hangs off a kept lane near the junction and goes nowhere:
    -- step off each kept node onto anything that is not kept, follow it while it stays a plain
    -- chain, and if it dead-ends within 30 m it was wiring.
    do
        local function nbs(w)
            local seen, list = {}, {}
            for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                for _, id in pairs(lst) do
                    if not seen[id] then
                        seen[id] = true
                        local o = ADGraphManager:getWayPointById(id)
                        if o ~= nil then list[#list + 1] = o end
                    end
                end
            end
            return list
        end
        local spur = {}
        for n in pairs(keep) do
            if live(n) and (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2 <= 35 * 35 then
                for _, first in ipairs(nbs(n)) do
                    if not keep[first] and not (jp.foreignWiring or {})[first] then
                        local chain, prev, node, run, dead = { first }, n, first, 0, false
                        for _ = 1, 40 do
                            local onward = {}
                            for _, o in ipairs(nbs(node)) do if o ~= prev then onward[#onward + 1] = o end end
                            if #onward == 0 then dead = true break end
                            if #onward > 1 or keep[onward[1]] then break end
                            run = run + math.sqrt((onward[1].x - node.x) ^ 2 + (onward[1].z - node.z) ^ 2)
                            if run > 60 then break end
                            prev, node = node, onward[1]
                            chain[#chain + 1] = node
                        end
                        if dead then for _, c in ipairs(chain) do spur[c] = true end end
                    end
                end
            end
        end
        local ids = {}
        for c in pairs(spur) do if live(c) then ids[#ids + 1] = c.id end end
        table.sort(ids, function(a, b) return a > b end)
        for _, id in ipairs(ids) do
            jxRemove(id, "junction spur")
            removed = removed + 1
        end
    end

    -- THE FINAL RESPACE, PER LEG, AFTER THE TRIM - and the density check with it. Each leg now runs
    -- from its outer end to the point on the box edge, so this is what decides the spacing leading
    -- into the box: checked here, a leg cannot finish with a short segment in front of its end, and
    -- it comes back with the points-per-metre that leg of the road had before the clear (within
    -- 10 %; the spacing is scaled and the leg rebuilt, up to six times, until it does).
    for _, h in ipairs(afterCut) do
        if #h.seq >= 3 then
            local first, last = h.seq[1], h.seq[#h.seq]
            local old = {}
            for i, n in ipairs(h.seq) do old[i] = { x = n.x, z = n.z } end
            local seq = h.seq
            for _ = 1, 6 do
                jp._laneSeqs = { { seq = seq, useOut = h.useOut, len = 1e9, step = h.step } }
                tryCall("junction smooth leg", function() self:junctionRespaceApproaches(jp) end)
                -- the leg as it now is
                local now, nd, cm = { first }, first, nil
                for _ = 1, 600 do
                    if nd == last then break end
                    local list = h.useOut and (nd.out or {}) or (nd.incoming or {})
                    local best, bd = nil, math.huge
                    for _, id in pairs(list) do
                        local nx = ADGraphManager:getWayPointById(id)
                        if nx ~= nil and nx ~= cm then
                            local d = distLine(old, nx.x, nx.z)
                            if d < bd then bd, best = d, nx end
                        end
                    end
                    if best == nil or bd > 3 then break end
                    cm, nd = nd, best
                    now[#now + 1] = nd
                end
                if nd ~= last or #now < 3 then break end
                seq = now
                for _, n in ipairs(now) do keep[n] = true end
                local dNow = density(now)
                if h.dens == nil or dNow == nil then break end
                local ratio = dNow / h.dens
                if math.abs(ratio - 1) <= 0.10 then break end
                h.step = math.max(3, math.min(25, (h.step or STEP) * ratio ^ 1.4))
            end
        end
    end
    -- LOOSE ENDS. Anything near the junction that is no longer joined to a kept lane - a single
    -- point, or a scrap of a few - is what the sweeps above left of some connector. A small
    -- component with no kept node in it goes.
    do
        local seenC, loose = {}, {}
        for _, n in pairs(ADGraphManager:getWayPoints()) do
            if n ~= nil and n.id ~= nil and not seenC[n] and not keep[n] and not theirs[n]
                and (n.x - box.centre.x) ^ 2 + (n.z - box.centre.z) ^ 2 <= 40 * 40 then
                local comp, stack, small = {}, { n }, true
                seenC[n] = true
                while #stack > 0 do
                    local w = table.remove(stack)
                    comp[#comp + 1] = w
                    if keep[w] or #comp > 8 then small = false break end
                    for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
                        for _, id in pairs(lst) do
                            local o = ADGraphManager:getWayPointById(id)
                            if o ~= nil and keep[o] then small = false end
                            if o ~= nil and not seenC[o] then seenC[o] = true stack[#stack + 1] = o end
                        end
                    end
                    if not small then break end
                end
                -- ...AND ONLY IF THIS CLEAR IS WHY IT IS LOOSE. Two ways a scrap can be none of our
                -- business: it already held a loose end when we began - the finished lane end of the
                -- junction next door - or this clear cut nothing in it at all, and it simply came
                -- adrift when something else went. Both were taken; at a close pair the second click
                -- ate three points of the first junction's road, 31 m away. A scrap is this clear's
                -- leftover only if this clear severed one of its points.
                if small and jxWasLoose ~= nil then
                    for _, w in ipairs(comp) do
                        if jxWasLoose[w] then small = false break end
                    end
                end
                if small then
                    local ours = false
                    for _, w in ipairs(comp) do
                        if jxWasCutByUs(w) then ours = true break end
                    end
                    if not ours then small = false end
                end
                if small then for _, w in ipairs(comp) do loose[#loose + 1] = w.id end end
            end
        end
        table.sort(loose, function(a, b) return a > b end)
        for _, id in ipairs(loose) do
            jxRemove(id, "junction loose end")
            removed = removed + 1
        end
    end
    jp._laneNodes = keep
    jp._laneSeqs = {}
    jp._boxCentre = box.centre
    return #ends, made, removed, cutN
end

--- Unwire one point from itself. True when there was something to undo. The single implementation:
--- the integrity sweep calls it for the junction it is working on, and the network-wide pass calls
--- it for everything - written twice, it would have been tuned once.
local function jxUnwireSelf(w, apply)
    if w == nil or w.id == nil then return false, nil end
    local selfIn = w.incoming ~= nil and table.contains(w.incoming, w.id)
    local selfOut = w.out ~= nil and table.contains(w.out, w.id)
    if not selfIn and not selfOut then return false, nil end
    if apply ~= false then
        table.removeValue(w.incoming, w.id)
        table.removeValue(w.out, w.id)
    end
    return true, (selfIn and selfOut) and "both ways" or (selfIn and "incoming" or "outgoing")
end

--- UNWIRE EVERY POINT THAT IS WIRED TO ITSELF, ACROSS THE WHOLE NETWORK.
---
--- The integrity sweep only ever looks at the junction being cleared, so the self-wired points
--- scattered elsewhere are never reached by it. This is the one-shot pass for those.
---
--- Deliberately the ONLY thing it repairs. Coincident points and shared-node crossings are left
--- exactly where they are: at a fifth of a metre apart two points may simply be a tight bend, and
--- what looks like debris is mostly the network doing its job. A self-link is different in kind -
--- no road leaves a point and arrives back at that same point without going anywhere, so there is
--- no case in which it means something, and removing it cannot change a route. Nothing can be
--- driven differently afterwards; the only difference is that AutoDrive stops counting a road that
--- was never there.
---
--- `apply` false (the default) changes nothing and only reports.
function ADFlyoverEditor:repairSelfLinks(apply)
    local found, fixed = {}, 0
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if w ~= nil and w.id ~= nil then
            local hit, how = jxUnwireSelf(w, apply == true)
            if hit then
                found[#found + 1] = string.format("%.1f, %.1f (%s)", w.x, w.z, how)
                if apply then fixed = fixed + 1 end
            end
        end
    end
    for _, where in ipairs(found) do
        Logging.info("[FlyoverEditor]: self-wired point at %s", where)
    end
    if apply and fixed > 0 then
        ADGraphManager:markChanges()
    end
    return #found, fixed
end

--- NETWORK INTEGRITY SWEEP. Three faults a rebuild can leave behind, none of which show on screen
--- until something drives into one:
---
---   DANGLING  - a short chain wired at one end only. The tidy lays a lane end, a later pass takes
---               the node it was anchored to, and what is left starts from nothing. Measured across
---               the map, the clear leaves one at four sites in eight. Repaired by joining the loose
---               end back to the nearest point of road that leads the right way; removed when there
---               is nothing sensible to join it to.
---   DOUBLES   - two points in the same place. Harmless to look at, but a route through one of them
---               misses whatever hangs off the other, so the links are folded onto one point and the
---               spare is taken out.
---   REVERSALS - a point whose road arrives one way and leaves back along it. Always a fault, but
---               never one worth guessing a fix for, so these are REPORTED and left alone.
---
--- Confined to `reach` metres of (cx, cz). `dry` reports and changes nothing. Returns the counts and
--- a list of descriptions, so the same pass can back a cleanup tool as well as the end of a clear.
function ADFlyoverEditor:networkIntegritySweep(cx, cz, reach, dry)
    local rep = { doubles = 0, repaired = 0, removed = 0, reversals = 0, unjoined = 0, selfLinks = 0, notes = {} }
    if cx == nil or cz == nil then return rep end
    reach = reach or 45
    local r2 = reach * reach
    local function note(fmt, ...)
        if #rep.notes < 40 then rep.notes[#rep.notes + 1] = string.format(fmt, ...) end
    end
    local function near(w)
        return w ~= nil and w.id ~= nil and (w.x - cx) ^ 2 + (w.z - cz) ^ 2 <= r2
    end
    local function byId(id) return ADGraphManager:getWayPointById(id) end
    local function degree(w)
        local s, n = {}, 0
        for _, i in ipairs(w.out or {}) do s[i] = true end
        for _, i in ipairs(w.incoming or {}) do s[i] = true end
        for _ in pairs(s) do n = n + 1 end
        return n
    end
    -- Removals renumber every id above the one taken, so the doomed are held as OBJECTS and taken
    -- highest id first, which leaves the ids below them - and so the rest of the list - still valid.
    local doomed, doomedSet = {}, {}
    local function kill(w)
        if w ~= nil and not doomedSet[w] then
            doomedSet[w] = true
            doomed[#doomed + 1] = w
        end
    end

    -- ONLY THIS JUNCTION. A radius takes in whatever happens to be within it, and a junction that
    -- has ALREADY been cleared looks, from here, exactly like damage: its branches were cut from the
    -- road on purpose and now lead nowhere. Cleaning one of a close pair over a flat radius tied the
    -- other one's branches straight back to the road - clear the right hand junction, then the left,
    -- and the right one is joined up again. So the same bound the deletions use applies here: what
    -- belongs to the junction in hand, and nothing beyond its arms.
    local site = {}
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if near(w) and jxInSite(w.x, w.z) then site[#site + 1] = w end
    end

    -- SELF-REFERENCES. A point listing itself among its own incoming or outgoing links. There is no
    -- reading of the graph in which that means anything - no road leaves a point and arrives back at
    -- the same point without going anywhere - so it is simply removed, with no judgement to make and
    -- nothing to weigh up.
    --
    -- It is not harmless. AutoDrive counts stored incoming to decide what is a merge, so a point
    -- with one real road in and itself makes two, and 3.0.1.2 paints it as a right-of-way centre:
    -- a junction drawn on the map where no two roads meet. One at (-927.39, -39.60) had the user
    -- hunting a connection that was never there; 19 points across that network do it, in the saved
    -- network BEFORE a clear as much as after, so this is old damage rather than anything a clear
    -- does. Counted with the doubles, since it is the same kind of fault: the graph disagreeing with
    -- itself about what is wired to what.
    for _, w in ipairs(site) do
        local hit = jxUnwireSelf(w, not dry)
        if hit then
            rep.selfLinks = (rep.selfLinks or 0) + 1
            note("a point at (%.1f, %.1f) is wired to itself - nothing drives that, and AutoDrive counts it as a road arriving", w.x, w.z)
        end
    end

    -- DOUBLES. Everything wired to the spare is re-wired to the keeper first, so folding the two
    -- together cannot lose a link.
    local SAME = 0.3
    for i = 1, #site do
        local a = site[i]
        if not doomedSet[a] then
            for j = i + 1, #site do
                local b = site[j]
                if not doomedSet[b] and (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 <= SAME * SAME then
                    rep.doubles = rep.doubles + 1
                    note("two points in the same place at (%.1f, %.1f)", b.x, b.z)
                    if not dry then
                        local outs, ins = {}, {}
                        for _, id in ipairs(b.out or {}) do outs[#outs + 1] = id end
                        for _, id in ipairs(b.incoming or {}) do ins[#ins + 1] = id end
                        for _, id in ipairs(outs) do
                            local t = byId(id)
                            if t ~= nil and t ~= a and t ~= b then junctionConnect(a, t, false) end
                        end
                        for _, id in ipairs(ins) do
                            local f = byId(id)
                            if f ~= nil and f ~= a and f ~= b then junctionConnect(f, a, false) end
                        end
                        junctionDisconnect(a, b)
                        kill(b)
                    end
                end
            end
        end
    end

    -- DANGLING. Walked from the loose end along the single way it has, for as long as the points it
    -- passes are plain road (two links or fewer). A chain that reaches a fork really is attached at
    -- its far end, which is what makes it a dangling tail rather than an ordinary dead-end lane; one
    -- that simply peters out is left to the stranded sweep that follows.
    local MAXLEN, MAXN, JOIN = 25, 14, 6
    for _, w in ipairs(site) do
        if not doomedSet[w] and degree(w) > 0 then
            local nout, nin = #(w.out or {}), #(w.incoming or {})
            local headless = (nin == 0 and nout > 0)
            local tailless = (nout == 0 and nin > 0)
            if headless or tailless then
                local chain, seen, len, cur = { w }, { [w] = true }, 0, w
                -- Attached at the far end unless it PETERS OUT. Requiring the walk to reach a fork
                -- was wrong: a lane end runs on into ordinary road, never meeting one, so every real
                -- case was walked past and called clean. Running out of chain to follow is the only
                -- thing that means the whole thing is free-floating - and that is the stranded
                -- sweep's job, not this one.
                local anchored = true
                while #chain < MAXN and len < MAXLEN do
                    local list = headless and (cur.out or {}) or (cur.incoming or {})
                    if #list ~= 1 then
                        anchored = (#list > 1)
                        break
                    end
                    local nxt = byId(list[1])
                    if nxt == nil or seen[nxt] then
                        anchored = (nxt ~= nil)
                        break
                    end
                    if degree(nxt) >= 3 then break end
                    len = len + math.sqrt((nxt.x - cur.x) ^ 2 + (nxt.z - cur.z) ^ 2)
                    chain[#chain + 1] = nxt
                    seen[nxt] = true
                    cur = nxt
                end
                if anchored then
                    -- The way the chain is already pointing, so it is not tied to something behind it.
                    local hx, hz = 0, 0
                    if #chain >= 2 then
                        hx, hz = chain[1].x - chain[2].x, chain[1].z - chain[2].z
                        local m = math.sqrt(hx * hx + hz * hz)
                        if m > 0 then hx, hz = hx / m, hz / m end
                    end
                    local best, bestD = nil, JOIN * JOIN
                    for _, t in ipairs(site) do
                        if not seen[t] and not doomedSet[t] and degree(t) > 0 then
                            local dx, dz = t.x - w.x, t.z - w.z
                            local d = dx * dx + dz * dz
                            if d > 0.01 and d < bestD then
                                local m = math.sqrt(d)
                                if (hx == 0 and hz == 0)
                                    or ((dx / m) * hx + (dz / m) * hz) >= 0.2 then
                                    bestD, best = d, t
                                end
                            end
                        end
                    end
                    -- NOTHING IS TIED BACK. A chain leading nowhere is not reliably damage: at a
                    -- junction that has already been cleared it is the work - the branches were cut
                    -- from the road on purpose - and there is no way to tell the two apart from the
                    -- shape of the graph, because a cleared junction has no forks left to recognise
                    -- it by. Joining them up put a cleared neighbour back together every time one of
                    -- a close pair was done after the other, six different ways as each route into
                    -- it was closed off. Reported and left alone.
                    -- WHOSE LOOSE END IS THIS? Three cases, and only one of them is damage:
                    --   already loose before this clear began - somebody else's, very likely a
                    --     junction cleared earlier, whose branches were cut from the road on purpose;
                    --   cut by this clear on purpose - that IS the work, and rejoining it undoes it;
                    --   loose because one of our own passes dropped a link - damage, and ours to fix.
                    -- The clear knows all three exactly. Distance never could: a cleared junction
                    -- keeps no forks to be recognised by, and its branches sit well inside any radius
                    -- wide enough to be worth having. Three goes at a radius, three failures.
                    local wasLoose = (jxWasLoose ~= nil) and jxWasLoose[w] or false
                    local cutOnPurpose = (jxCut ~= nil) and jxCut[w] or false
                    -- A POINT THIS CLEAR LAID ITSELF is a lane end on purpose - the tidy ran the lane
                    -- out to the box edge and stopped it there. It was in neither set, being new, so
                    -- it read as accidental damage and was joined to the nearest road: a side lane
                    -- wired into the through lane inside the box, a connector left by the very pass
                    -- meant to catch them.
                    local laidByUs = (jxExisted ~= nil) and not jxExisted[w] or false
                    if laidByUs then cutOnPurpose = true end
                    if wasLoose or cutOnPurpose then
                        rep.unjoined = (rep.unjoined or 0) + 1
                        note("a chain of %d leads nowhere at (%.1f, %.1f) - %s, left alone",
                            #chain, w.x, w.z,
                            wasLoose and "it was already loose before this clear" or "this clear cut it on purpose")
                    elseif best ~= nil then
                        rep.repaired = rep.repaired + 1
                        note("a chain of %d led nowhere at (%.1f, %.1f) - tied back to the road %.1f m away",
                            #chain, w.x, w.z, math.sqrt(bestD))
                        if not dry then
                            if headless then junctionConnect(best, w, false)
                            else junctionConnect(w, best, false) end
                        end
                    else
                        -- NOTHING IS REMOVED HERE. A one-way dead-end lane is indistinguishable from
                        -- a dangling tail by shape alone: both are wired at one end, both walk back
                        -- along their own road without petering out. Taking away what could not be
                        -- tied back nearly doubled the deletions across the map - 399 to 698 - and
                        -- trebled the sites reaching past 60 m, because it was pulling up real
                        -- roads. Repairing a tail is safe; deleting one is not, so an end with
                        -- nothing to join is reported and left exactly where it is.
                        rep.unjoined = (rep.unjoined or 0) + 1
                        note("a chain of %d ends at (%.1f, %.1f) with nothing leading into it, and nothing close enough to tie it to - left alone",
                            #chain, w.x, w.z)
                    end
                end
            end
        end
    end

    -- REVERSALS. Reported only.
    for _, w in ipairs(site) do
        if not doomedSet[w] and #(w.out or {}) == 1 and #(w.incoming or {}) == 1 then
            local f, t = byId(w.incoming[1]), byId(w.out[1])
            if f ~= nil and t ~= nil and f ~= t then
                local ax, az = w.x - f.x, w.z - f.z
                local bx, bz = t.x - w.x, t.z - w.z
                local la, lb = math.sqrt(ax * ax + az * az), math.sqrt(bx * bx + bz * bz)
                if la > 0.05 and lb > 0.05 then
                    local dot = (ax / la) * (bx / lb) + (az / la) * (bz / lb)
                    if dot < -0.866 then
                        rep.reversals = rep.reversals + 1
                        note("the road doubles back on itself at (%.1f, %.1f)", w.x, w.z)
                    end
                end
            end
        end
    end

    if not dry and #doomed > 0 then
        table.sort(doomed, function(a, b) return (a.id or 0) > (b.id or 0) end)
        for _, n in ipairs(doomed) do
            if n.id ~= nil then
                jxRemove(n, "integrity sweep remove")
            end
        end
    end
    return rep
end

--- WHAT KIND OF JUNCTION THIS IS. Read off the tool's OWN pairing - which lanes it found carrying a
--- route straight across, and which stop here - not off the arm angles alone. Angles alone misread a
--- T whose through road bends through the junction (its two through arms 141 degrees apart) as a Y,
--- which is how one site was filed under the wrong heading for a whole survey. Angles still describe
--- the type once the pairing has decided it.
---
--- Nothing branches on this yet: it is recorded and logged so that per-type rules have somewhere to
--- attach later, without the order of the clear having to be taken apart a second time.
function ADFlyoverEditor:junctionClassify(jp)
    if jp == nil then return "?" end
    local c = jp._boxCentre or jp.boxCentre or jp.tracksCentre
    if c == nil then return "?" end

    local function bearing(x, z)
        return math.deg(math.atan2(x - c.x, z - c.z)) % 360
    end
    local function sep(a, b)
        local d = math.abs(a - b) % 360
        if d > 180 then d = 360 - d end
        return d
    end
    -- Bearings that are within tol of each other are the same arm - the two lanes of one road, and
    -- the several near-coincident one-way tracks a busy arm is built from.
    local function arms(list, tol)
        local out = {}
        for _, a in ipairs(list) do
            local hit = nil
            for _, g in ipairs(out) do
                for _, b in ipairs(g) do
                    if sep(a, b) <= tol then hit = g break end
                end
                if hit ~= nil then break end
            end
            if hit == nil then out[#out + 1] = { a } else hit[#hit + 1] = a end
        end
        local means = {}
        for _, g in ipairs(out) do
            local sx, sz = 0, 0
            for _, v in ipairs(g) do
                sx = sx + math.sin(math.rad(v))
                sz = sz + math.cos(math.rad(v))
            end
            means[#means + 1] = math.deg(math.atan2(sx, sz)) % 360
        end
        table.sort(means)
        return means
    end

    local routes = jp.pathRoutes or {}
    local tB, sB, sPt = {}, {}, {}
    for _, t in ipairs(routes.through or {}) do
        if #t >= 2 then
            tB[#tB + 1] = bearing(t[1].x, t[1].z)
            tB[#tB + 1] = bearing(t[#t].x, t[#t].z)
        end
    end
    for _, sl in ipairs(routes.side or {}) do
        local n = sl.nodes
        if n ~= nil and #n >= 1 then
            -- TWO DIFFERENT ENDS ANSWER TWO DIFFERENT QUESTIONS. Which way the arm lies is read off
            -- the end FURTHEST out, because a bearing taken from a node a metre from the centre is
            -- mostly noise. WHERE it joins is read off the end NEAREST in - taking that from the far
            -- end too had a side road that runs 95 m away reported as a 95 m stagger, which is how a
            -- plain crossroads gets filed as a staggered one.
            local far, fd, nearW, nd = n[1], -1, n[1], math.huge
            for _, w in ipairs(n) do
                local d = (w.x - c.x) ^ 2 + (w.z - c.z) ^ 2
                if d > fd then fd, far = d, w end
                if d < nd then nd, nearW = d, w end
            end
            sB[#sB + 1] = bearing(far.x, far.z)
            sPt[#sPt + 1] = nearW
        end
    end

    local T, S = arms(tB, 30), arms(sB, 30)
    local nT, nS = #T, #S

    local function cross(a)
        local x = math.min(a, 180 - a)
        return (x >= 78) and "4W square" or ((x >= 55) and "4W skew" or "4W very skew")
    end

    if nT >= 4 then
        local worst = 180
        for i = 1, nT do
            for j = i + 1, nT do
                local d = sep(T[i], T[j])
                if d < worst then worst = d end
            end
        end
        return cross(worst)
    elseif nT == 2 and nS >= 2 then
        -- A through road with two side roads on it. Meeting it in the same place is a crossroads;
        -- meeting it a way apart is a STAGGERED crossing - two T's sharing one road - and the two
        -- must not be taken for one junction. Measured ALONG the through road, which needs no angle.
        local hx, hz = math.sin(math.rad(T[1])), math.cos(math.rad(T[1]))
        local lo, hi = math.huge, -math.huge
        for _, p in ipairs(sPt) do
            local along = (p.x - c.x) * hx + (p.z - c.z) * hz
            if along < lo then lo = along end
            if along > hi then hi = along end
        end
        if (hi - lo) > 10 then
            return string.format("4W offset (%.0f m stagger)", hi - lo)
        end
        local branch = math.min(sep(S[1], T[1]), sep(S[1], T[2]))
        return cross(branch)
    elseif nT == 2 then
        local branch = 90
        if nS == 1 then branch = math.min(sep(S[1], T[1]), sep(S[1], T[2])) end
        return (branch <= 38) and "Y merge" or ((branch <= 62) and "T skew" or "T square")
    elseif nT >= 3 or nT == 0 then
        -- Every arm pairs with every other, because in a Y each one really does run into each other
        -- fairly straight. Nothing here is a side road off a main road, which is why no box forms.
        return "Y"
    end
    return "?"
end

function ADFlyoverEditor:applyJunctionClear()
    local jp = self.junctionPreview
    if jp == nil then return end
    -- The bounds are measured from the crossing too, where there is one, so that "this junction"
    -- means the same place to the deletions as it does on screen.
    if self.junctionSite ~= nil and jp.boxCentre ~= nil then
        self.junctionSite.x, self.junctionSite.z = jp.boxCentre.x, jp.boxCentre.z
    end
    -- From here until jxEnd, nothing is deleted outside the junction that was selected. See jxRemove.
    jxBegin(self.junctionSite)

    -- The network as it stands, before a single point moves, when capture is on. Nil otherwise, and
    -- every debugCapture call below is a no-op on nil.
    local cap = self:debugCaptureBegin("clear", self.junctionSite, {
        string.format("leave through paths  %s", (self.junctionLeaveThrough ~= false) and "on" or "off"),
        string.format("turn radius          %s m", tostring(self.junctionTurnRadius or 12)),
    })

    -- STEP 2: CLEAN THE SITE BEFORE ANYTHING MEASURES IT. This used to run last of all, which meant
    -- the box, the road widths and the answer to which lanes are parent road were all worked out on
    -- a site that still had points sitting on top of each other and chains leading nowhere in it -
    -- and those get counted as tracks of a road. The same road measured 2.50 m one way and 4.23 m
    -- the other at one site, purely from what the measurement happened to catch.
    --
    -- It cannot run in the preview: the preview is pure inspection and runs on every frame, and this
    -- changes waypoints. So the site is cleaned here, once, and the preview is then rebuilt on the
    -- cleaned graph before the rest of the clear reads it.
    do
        local site = self.junctionSite
        local c0 = site or jp._boxCentre or jp.tracksCentre
        if c0 ~= nil and AutoDrive.FLYOVER_JUNCTION_CLEAN_FIRST ~= false then
            local notes, touched = {}, 0
            local tot = { doubles = 0, repaired = 0, removed = 0, reversals = 0, unjoined = 0 }
            -- Repeated until the site settles: taking a chain out can leave the next point along
            -- with nothing leading into it, so one pass is never enough. Three is, and anything that
            -- will not settle by then is left alone rather than chased.
            for _ = 1, 3 do
                local ok, r = pcall(function()
                    return self:networkIntegritySweep(c0.x, c0.z, 45, false)
                end)
                if not ok or r == nil then break end
                tot.doubles = tot.doubles + r.doubles
                tot.repaired = tot.repaired + r.repaired
                tot.removed = tot.removed + r.removed
                tot.reversals, tot.unjoined = r.reversals, r.unjoined or 0
                for _, n in ipairs(r.notes or {}) do notes[#notes + 1] = n end
                local did = r.doubles + r.repaired + r.removed
                touched = touched + did
                if did == 0 then break end
            end
            if tot.repaired + tot.removed + tot.doubles > 0 then
                Logging.info("[FlyoverEditor]: junction - cleaned the site first: %d chain(s) tied back to the road, %d removed with nothing to tie them to, %d doubled point(s) folded together.",
                    tot.repaired, tot.removed, tot.doubles)
            end
            if (tot.unjoined or 0) > 0 then
                Logging.warning("[FlyoverEditor]: junction - %d lane end(s) with nothing leading into them and nothing close enough to tie them back to. Left in place, not removed: a one-way dead-end lane looks the same from here.",
                    tot.unjoined)
            end
            if tot.reversals > 0 then
                Logging.warning("[FlyoverEditor]: junction - %d point(s) where the road doubles back on itself. Left alone: reported, not guessed at.",
                    tot.reversals)
            end
            for _, n in ipairs(notes) do
                Logging.info("[FlyoverEditor]: junction - %s.", n)
            end
            -- STEP 3, FIRST HALF: SMOOTH THE PARENT LANES BEFORE THE BOX IS MEASURED. Years of
            -- tie-ins and re-laid ends leave an approach with 0.9 m hops next to 12 m ones, and a
            -- box measured against that is measured against the spacing rather than the road. The
            -- spec put the box first and the smoothing after; measuring unsmoothed lanes is exactly
            -- what has been moving the box, so it is done the other way round.
            local rsM, rsR, rsC = 0, 0, 0
            tryCall("junction smooth parent lanes", function()
                rsM, rsR, rsC = self:junctionRespaceApproaches(jp)
            end)
            if (rsM or 0) + (rsR or 0) + (rsC or 0) > 0 then
                touched = touched + 1
                Logging.info("[FlyoverEditor]: junction - smoothed the parent lanes before measuring: %d point(s) moved, %d removed, %d added.",
                    rsM or 0, rsR or 0, rsC or 0)
            end

            -- Whatever was measured before the cleaning was measured on the wrong site.
            if touched > 0 then
                -- ONCE A SITE IS ACCEPTED, THE CLEAR SEES IT THROUGH. Rebuilding the preview runs
                -- the selection again, and the cleaning it has just done can change the answer -
                -- folding one doubled point drops a fork, the site no longer counts as a junction,
                -- and the clear walked away having cleaned the site and cleared nothing: twenty
                -- links still running across the box, no line in the log, and the deletion bound
                -- left switched on behind it. The rebuild is there to measure the cleaned site, not
                -- to reconsider whether to work on it, so a refusal here keeps what we already had.
                local keep = jp
                self.junctionPreviewKey = nil
                tryCall("junction preview after cleaning", function() self:updateJunctionPreview() end)
                jp = self.junctionPreview
                if jp == nil then
                    jp = keep
                    self.junctionPreview = keep
                    Logging.info("[FlyoverEditor]: junction - cleaning the site changed it enough that it no longer reads as a junction; carrying on with the site as first found.")
                end
            end
            -- NO BOX IS A RESULT, AND IT HAS TO BE SAID. The box is the overlap of two roads' claim
            -- bands, and it needs two roads that actually cross: where the roads here run nearly
            -- parallel, or meet at a shallow merge, no pair qualifies and no box is built. The clear
            -- then trims what it can and leaves whatever lies between the roads standing - which
            -- looks exactly like a clear that half worked, with nothing anywhere saying why.
            if jp._box == nil then
                Logging.warning("[FlyoverEditor]: junction - NO BOX could be built here: no two of its roads cross at an angle the box can be made from (they run nearly parallel, or meet at a shallow merge). What lies between them is left alone; the lanes are still tidied.")
            end
            local kind = jp.junctionType or "?"
            if kind == "?" then
                tryCall("junction classify", function() kind = self:junctionClassify(jp) end)
            end
            jp.junctionType = kind
            if self.junctionSite ~= nil then self.junctionSite.kind = kind end
            Logging.info("[FlyoverEditor]: junction - this is a %s, %s. Nothing branches on that yet; it is recorded so rules for each kind have somewhere to attach.",
                kind, tostring(jp.junctionSituation or "situation unknown"))
        end
    end
    local leave = self.junctionLeaveThrough ~= false
    -- Through paths KEPT: only the turn wiring goes. Through paths CLEARED: the through route's
    -- own WIRING goes with it and its links are cut, but its ROAD stays.
    --
    -- Keeping every through node and merely cutting the links was too literal a reading of "sever
    -- continuity, keep the road" - it left the whole route sitting in the junction as disconnected
    -- points, which is not a cleared junction. Keeping the road means keeping the RUN: the part the
    -- lane chains walked from the anchor to the last fork. The wiring in between is not road and
    -- has no business surviving a clear that was asked to take the through path out.
    local nodes = jp.turnDebris
    if not leave then
        local keep = jp.runNodes or {}
        local both = {}
        for _, w in ipairs(jp.turnDebris or {}) do both[#both + 1] = w end
        for _, w in ipairs(jp.throughDebris or {}) do
            if not keep[w] then both[#both + 1] = w end
        end
        nodes = both
    end
    local links = jp.staleLinks or {}
    local nodeCount = nodes ~= nil and #nodes or 0
    local throughSkippedLinks = 0
    local linksToSever = {}
    for _, pair in ipairs(links) do
        if leave and pair.isThrough then
            throughSkippedLinks = throughSkippedLinks + 1
        else
            linksToSever[#linksToSever + 1] = pair
        end
    end
    local throughCut = 0
    if not leave then
        for _, pair in ipairs(jp.throughLinks or {}) do
            local a, b = pair[1], pair[2]
            if a ~= nil and b ~= nil and a.id ~= nil and b.id ~= nil
                and a.id >= 0 and b.id >= 0 then
                linksToSever[#linksToSever + 1] = { a, b }
                throughCut = throughCut + 1
            end
        end
    end
    if nodeCount == 0 and #linksToSever == 0 then
        Logging.info("[FlyoverEditor]: junction - nothing here for this site to clear.")
        return
    end

    ADEditorHistory:snapshot("clear junction")
    local staleCut = 0
    for _, pair in ipairs(linksToSever) do
        local a, b = pair[1], pair[2]
        if a ~= nil and b ~= nil and a.id ~= nil and b.id ~= nil and a.id >= 0 and b.id >= 0 then
            junctionDisconnect(a, b)
            staleCut = staleCut + 1
        end
    end

    -- PARENT ROAD IS NEVER DELETED, whatever the toggle says.
    --
    -- "Leave through paths" governs whether the route ACROSS this junction survives. It was doing
    -- far more than that: with it off the clear deleted every node on those routes, and where two
    -- junctions sit close together the route between them IS the road joining them - so clearing one
    -- took out the road to its neighbour. The run set is the tool's own answer to which nodes are
    -- parent road, and it is held by OBJECT because ids renumber on every removal.
    local roadKept = 0
    local keep = jp.runNodes or {}
    local doomed = {}
    -- The through paths stay WHOLE through this stage: the tidy smooths each one right across the
    -- junction and then cuts it at the box, and it cannot smooth a path with its middle gone.
    local onPath = {}
    if jp._box ~= nil and jp.pathRoutes ~= nil then
        for _, nodes in ipairs(jp.pathRoutes.through or {}) do
            for _, n in ipairs(nodes) do onPath[n] = true end
        end
    end
    for _, w in ipairs(nodes or {}) do
        if w ~= nil and w.id ~= nil and w.id >= 0 then
            if keep[w] or onPath[w] then roadKept = roadKept + 1 else doomed[#doomed + 1] = w end
        end
    end
    if roadKept > 0 then
        Logging.info("[FlyoverEditor]: junction - kept %d point(s) of parent road that the clear would otherwise have taken.",
            roadKept)
    end

    -- Highest id first: removeWayPoint renumbers everything above the id it removes, so a pending
    -- lower id is still valid when its turn comes; a pending higher id would not be.
    local ids = {}
    for _, w in ipairs(doomed) do ids[#ids + 1] = w.id end
    table.sort(ids, function(a, b) return a > b end)
    local cleared = 0
    for _, id in ipairs(ids) do
        if jxRemove(id, "junction clear") then
            cleared = cleared + 1
        end
    end

    -- STEP 4: THE CONNECTORS GO BEFORE THE TIDY, not after it. A tidy trims a lane end back to the
    -- box; it has no business running with connector remnants still hanging off the lanes it is
    -- measuring. The cost of the move is that the tidy's own lane walks are not available yet, so
    -- the stub sweep falls back to its cruder walk - which is why this was the other way round.
    local stubs = 0
    tryCall("junction clear stubs", function() stubs = self:junctionClearStubs(jp) end)
    if stubs > 0 then
        Logging.info("[FlyoverEditor]: junction - removed %d point(s) of connector left hanging off the lanes.",
            stubs)
    end

    -- Tidy AFTER the removals: the ends being measured are the ones the clear just created.
    local tidyTrim, tidyAdd, tidyLanes, boxSwept, boxSevered = 0, 0, 0, 0, 0
    tryCall("junction tidy lane ends", function()
        local nEnds, nMade, nRemoved, nCut = self:junctionTidyByPaths(jp)
        if nEnds ~= nil then
            tidyLanes, tidyAdd, tidyTrim, boxSwept, boxSevered = nEnds, nMade, 0, nRemoved, nCut
        else
            tidyTrim, tidyAdd, tidyLanes, boxSwept, boxSevered = self:junctionTidyLaneEnds(jp)
        end
    end)
    -- WHERE EVERY LANE ENDS, AND WHETHER A ROAD'S TWO LANES AGREE.
    --
    -- Asked of the finished network rather than of whichever tidy ran, so it reports the same thing
    -- however the lane was handled - and reports a lane that no pass touched at all, which is the
    -- case that used to pass in silence.
    --
    -- The pair check is the one the eye makes first. At j33 one lane of a road ended 18.5 m from the
    -- middle and its partner 5.1 m: obvious on screen, invisible to every count the tool kept, and
    -- it took a capture and an hour to find. Two lanes of one road should stop together.
    do
        local c = jp._boxCentre or jp.tracksCentre
        if c ~= nil then
            local lanes = {}
            for _, ap in ipairs(jp.approaches or {}) do
                local b = math.deg(ap.bearing or 0) % 360
                local nearest = nil
                for _, w in pairs(ADGraphManager:getWayPoints()) do
                    if w ~= nil and w.id ~= nil then
                        local dx, dz = w.x - c.x, w.z - c.z
                        local d = math.sqrt(dx * dx + dz * dz)
                        if d <= 45 then
                            local wb = math.deg(math.atan2(dx, dz)) % 360
                            local sep = math.abs(wb - b) % 360
                            if sep > 180 then sep = 360 - sep end
                            if sep <= 12 and (nearest == nil or d < nearest) then nearest = d end
                        end
                    end
                end
                if nearest ~= nil then
                    lanes[#lanes + 1] = { b = b, d = nearest, dir = ap.dir }
                end
            end
            -- Pair the lanes of a road: same bearing within 20 degrees, opposite travel.
            local said = {}
            for i = 1, #lanes do
                for j = i + 1, #lanes do
                    if not said[i] and not said[j] then
                        local sep = math.abs(lanes[i].b - lanes[j].b) % 360
                        if sep > 180 then sep = 360 - sep end
                        if sep <= 20 then
                            local gap = math.abs(lanes[i].d - lanes[j].d)
                            said[i], said[j] = true, true
                            if gap > 3 then
                                Logging.warning("[FlyoverEditor]: junction - the two lanes of the road on bearing %.0f do not stop together: one ends %.1f m from the middle, the other %.1f m. A lane no pass could reach is left where it was.",
                                    lanes[i].b, lanes[i].d, lanes[j].d)
                            else
                                Logging.info("[FlyoverEditor]: junction - road on bearing %.0f: both lanes end %.1f and %.1f m from the middle.",
                                    lanes[i].b, lanes[i].d, lanes[j].d)
                            end
                        end
                    end
                end
            end
            for i = 1, #lanes do
                if not said[i] then
                    Logging.info("[FlyoverEditor]: junction - single lane on bearing %.0f ends %.1f m from the middle.",
                        lanes[i].b, lanes[i].d)
                end
            end
        end
    end

    if (boxSwept or 0) + (boxSevered or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - the box (the roads' own offset lines, centred %.1f, %.1f): removed %d point(s) inside it and cut %d link(s) running across it; lanes now end on its edge.",
            jp._boxCentre and jp._boxCentre.x or 0, jp._boxCentre and jp._boxCentre.z or 0,
            boxSwept or 0, boxSevered or 0)
    end


    -- Respace LAST: the ends are where they belong and the stubs are gone, so what is left is lane.
    local rsMoved, rsRemoved, rsCreated = 0, 0, 0
    tryCall("junction respace approaches", function()
        rsMoved, rsRemoved, rsCreated = self:junctionRespaceApproaches(jp)
    end)
    if (rsMoved or 0) + (rsRemoved or 0) + (rsCreated or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - respaced the approaches like the smooth tool's rebuild - up to %.0f m apart, closer through bends - over the last %.0f m: %d point(s) moved, %d removed, %d added. Ends, forks and marker points stay put.",
            AutoDrive.FLYOVER_JUNCTION_RESPACE_STEP or 5, AutoDrive.FLYOVER_JUNCTION_RESPACE_LEN or 50,
            rsMoved or 0, rsRemoved or 0, rsCreated or 0)
    end

    -- A SECOND SWEEP, AND IT ONLY EVER COUNTS. The site was cleaned before anything measured it
    -- (step 2); anything broken by the time we get here was broken by the stages in between, and
    -- that number is worth knowing - moving the single sweep to the front took the map from 1 broken
    -- connector to 25, because this pass at the end had never been a cleanup step at all, only a
    -- bandage over the stages before it.
    --
    -- IT MUST NOT REPAIR. A clear's whole job is to cut the branches away from the road they joined,
    -- and a branch end left hanging afterwards is not damage - it is the work. Repairing it tied
    -- every branch straight back to its parent: two or three links running back across the box at
    -- every junction on the map, and a clear that visibly did nothing. So it reports and changes
    -- nothing, and the number belongs at zero.
    do
        local c0 = self.junctionSite or jp._boxCentre or jp.tracksCentre
        if c0 ~= nil and AutoDrive.FLYOVER_JUNCTION_FINAL_SWEEP ~= false then
            -- Repairing again here, and only here, because this is the one point at which the three
            -- kinds of loose end can be told apart: what was already loose when the clear began, what
            -- the clear cut on purpose, and what one of its own passes broke by accident. Only the
            -- last is put back.
            local ok, r = pcall(function()
                return self:networkIntegritySweep(c0.x, c0.z, 45, false)
            end)
            if ok and r ~= nil then
                local n = r.repaired
                if n > 0 then
                    Logging.warning("[FlyoverEditor]: junction - %d link(s) that this clear broke by accident, put back. Not the branches it cut on purpose, and nothing that was already loose before it started. This count belongs at zero.",
                        n)
                end
                if r.reversals > 0 then
                    Logging.warning("[FlyoverEditor]: junction - %d point(s) where the road doubles back on itself.",
                        r.reversals)
                end
            end
        end
    end

    -- LAST OF ALL, ANYTHING LEFT JOINED TO NOTHING. Every stage before this can strand a point: the
    -- box sweep takes a connector's middle, the stub sweep takes its far end, the respace bridges
    -- over one and deletes it. Whatever is standing near the junction with no link left on it is
    -- not road by any reading, so it goes - but only if it is genuinely alone, so a real dead-end
    -- lane (which still has the link back up its own road) is untouched.
    do
        local c0 = jp._boxCentre or jp.tracksCentre
        local stranded = {}
        if c0 ~= nil then
            for _, w in pairs(ADGraphManager:getWayPoints()) do
                if w ~= nil and w.id ~= nil and (w.x - c0.x) ^ 2 + (w.z - c0.z) ^ 2 <= 45 * 45
                    and #(w.out or {}) == 0 and #(w.incoming or {}) == 0 then
                    stranded[#stranded + 1] = w.id
                end
            end
        end
        table.sort(stranded, function(a, b) return a > b end)
        for _, id in ipairs(stranded) do
            jxRemove(id, "junction stranded point")
        end
        if #stranded > 0 then
            Logging.info("[FlyoverEditor]: junction - removed %d point(s) left joined to nothing.", #stranded)
        end
    end
    if tidyLanes > 0 then
        Logging.info("[FlyoverEditor]: junction - tidied %d lane end(s) onto the box edge: %d point(s) trimmed, %d added.",
            tidyLanes, tidyTrim, tidyAdd)
    end

    if throughCut > 0 then
        Logging.info("[FlyoverEditor]: junction - cut %d through-route link(s); the roads themselves are left in place.",
            throughCut)
    end
    local throughLeft = leave and (#(jp.throughDebris or {})) or 0
    if leave and (throughLeft > 0 or throughSkippedLinks > 0) then
        -- SAYS WHICH STAGE IT IS COUNTING. `cleared` is the turn wiring and nothing else - not the
        -- box sweep, not the respace - so on a junction that has been cleared once already it is
        -- legitimately 0 while the stage line beneath reports 18 taken. Phrased as though it were
        -- the total, those two lines flatly contradict each other, and the total is on the next line
        -- anyway.
        Logging.info("[FlyoverEditor]: junction - removed %d point(s) of old turn wiring and %d stale link(s); left %d through-path point(s) and %d through link(s) in place.",
            cleared, staleCut, throughLeft, throughSkippedLinks)
    else
        Logging.info("[FlyoverEditor]: junction - removed %d point(s) of old turn wiring and %d stale link(s). Roads it joined are untouched.",
            cleared, staleCut)
    end
    -- WHICH STAGE TOOK WHAT, AND FROM HOW FAR. One total hides the stage that is over-reaching: in
    -- game a clear reported 29 points taken, the farthest 39 m out, at a junction 12 m across - and
    -- nothing in the log said which of fourteen removers had gone that far.
    do
        local parts = {}
        for why, e in pairs(jxWhy) do
            parts[#parts + 1] = string.format("%s %d (to %.0f m)", why:gsub("^junction ", ""), e.n, e.far)
        end
        table.sort(parts)
        if #parts > 0 then
            Logging.info("[FlyoverEditor]: junction - taken by stage: %s.", table.concat(parts, "; "))
        end
    end
    local held, took, farOut = jxEnd()
    Logging.info("[FlyoverEditor]: junction - took %d point(s) in all, the farthest %.0f m out; %d left alone as belonging to a neighbouring junction rather than this one.",
        took, farOut, held)
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    -- After markChanges, so what is written is the network as the game now holds it.
    self:debugCaptureEnd(cap)
    self.junctionArmed, self.junctionPreview, self.junctionPreviewKey = nil, nil, nil
end

function ADFlyoverEditor:applyJunction()
    local jp = self.junctionPreview
    if jp == nil then return end
    if jp.clearMode then
        self:applyJunctionClear()
        return
    end
    -- A build changes the network just as a clear does, so it is captured the same way: the point of
    -- the numbered folders is to follow a SEQUENCE, and a sequence with the builds missing from it
    -- cannot be replayed.
    local cap = self:debugCaptureBegin("build", self.junctionSite, {
        string.format("turn radius          %s m", tostring(self.junctionTurnRadius or 12)),
    })

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
        Logging.info("[FlyoverEditor]: junction - refused %d turn(s): tighter than the %.0f m turn radius even at the %.0f m floor.",
            jp.nTight, jp.turnRadius or 0, AutoDrive.FLYOVER_JUNCTION_TURN_MIN or 4)
    end
    if (jp.nOffRoad or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - refused %d turn(s): no radius down to %.0f m keeps a %.1f m corridor on the road.",
            jp.nOffRoad, AutoDrive.FLYOVER_JUNCTION_TURN_MIN or 4,
            self.junctionCorridor or AutoDrive.FLYOVER_JUNCTION_CORRIDOR or 4)
    end
    if (jp.nNoCurve or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - %d pair(s) had no joinable curve (see the id lines above) - not placed.",
            jp.nNoCurve)
    end
    if (jp.nUTurn or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - %d pair(s) skipped as U-turns (bearings over 170 deg apart, see above).",
            jp.nUTurn)
    end
    if (jp.nFar or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - %d pair(s) never came close to each other - likely two separate crossings caught by one scope; not placed.",
            jp.nFar)
    end
    if (jp.nLane or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - %d redundant lane pairing(s) skipped (a closer match exists for the same turn, see above).",
            jp.nLane)
    end
    if (jp.nBlocked or 0) > 0 then
        Logging.info("[FlyoverEditor]: junction - refused %d turn(s): a static obstacle sits in the corridor at every radius tried.",
            jp.nBlocked)
    end
    if #newMoves == 0 then
        Logging.info("[FlyoverEditor]: junction - nothing new to connect here.")
        return
    end

    ADEditorHistory:snapshot("junction")
    -- The WORK region, not the search circle: tie-ins and kickouts land wherever the geometry puts
    -- them on the tracks, which is routinely outside the circle that merely found those tracks.
    local cx, cz, radius = jp.cx, jp.cz, (jp.workRadius or jp.radius)
    self.junctionChainCache = nil
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
        Logging.info("[FlyoverEditor]: junction - severed %d stale direct link(s) between road nodes (rebuild).", staleCut)
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
            jxRemove(s.id, "junction removeWayPoint")
        end
    end

    -- Rebuild's debris clearing, LAST of all and only once something actually placed: every old
    -- off-skeleton node wired to this junction goes, including duplicate connectors and connectors of
    -- pairs the matrix now refuses - the per-movement path deletion this replaces left those behind.
    -- No degree guard here: a degree-3 debris node is an old connector fork, not road (roads are
    -- skeleton and never in this list). Deleted by object reference, id re-read each time.
    local debrisCleared = 0
    -- Clear the old wiring when something was LAID, and ALSO when turns were deliberately REFUSED
    -- because the design vehicle cannot take them (too tight, off road, blocked, rig off road, rig
    -- hits something). A refusal is a decision that the turn should not exist - leaving the old
    -- connector standing keeps an undrivable turn on the network, which is worse than no turn at all:
    -- AutoDrive will happily route a rig into it. The `placed > 0` guard alone meant a junction whose
    -- every movement was refused kept ALL of its old wiring and the rebuild silently did nothing.
    -- Reasons that are NOT a drivability judgement (nFar = two separate crossings in one scope, nLane
    -- = a redundant lane pairing, nNoCurve = no joinable geometry) deliberately do not trigger this:
    -- they mean "not this junction's business", not "this turn is undrivable".
    local nRefusedForVehicle = (jp.nTight or 0) + (jp.nOffRoad or 0) + (jp.nBlocked or 0)
        + (jp.nTrailerRoad or 0) + (jp.nTrailerHit or 0)
    if placed == 0 and nRefusedForVehicle > 0 then
        Logging.info("[FlyoverEditor]: junction - nothing could be laid here, but %d turn(s) were refused as undrivable - clearing their old wiring rather than leaving it.",
            nRefusedForVehicle)
    end
    if (placed > 0 or nRefusedForVehicle > 0) and jp.debris ~= nil then
        for _, s in ipairs(jp.debris) do
            if s ~= nil and not stubSeen[s] and s.id ~= nil and s.id >= 0 then
                stubSeen[s] = true
                if jxRemove(s.id, "junction clear debris") then
                    debrisCleared = debrisCleared + 1
                end
            end
        end
    end
    if debrisCleared > 0 then
        Logging.info("[FlyoverEditor]: junction - cleared %d old junction point(s) (rebuild).", debrisCleared)
    end

    if mirrorsSkipped > 0 then
        Logging.info("[FlyoverEditor]: junction - %d mirrored one-way pair(s) folded into their dual connector (built once, not twice).",
            mirrorsSkipped)
    end
    Logging.info("[FlyoverEditor]: junction placed %d connector(s) (%d dual, %d rebuilt over old ones), consumed %d stub point(s).",
        placed, dualPlaced, rebuiltPlaced, #allStubs)
    self:invalidateIdReferences()
    ADGraphManager:markChanges()
    self:debugCaptureEnd(cap)
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
        -- NOTHING IN CLEAR MODE. The scope radius used to be "the primary disambiguation lever for
        -- what the crossing is", and that was the trouble: what belongs to a junction is a property
        -- of the road, and letting a wheel decide it meant the same click gave different answers.
        -- Clearing takes its scope from the junction now, so there is nothing here to turn. Build
        -- mode still has one - its tie-in and kickout geometry is laid out around it.
        if self.junctionMode == "clear" then return false end
        self:setJunctionRadius(self:junctionRadiusValue() + step * AutoDrive.FLYOVER_JUNCTION_RADIUS_STEP)
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
    -- of the tolerances and counts the global reversal above suits. So the move tool keeps the original
    -- (pre-reversal) wheel direction; everything else (junction scope radius included) stays reversed.
    -- The -/+ steppers are unaffected either way (they call stepAction directly, not here).
    local toolStep = (self.tool == self.TOOL.MOVE) and -step or step

    -- Any numeric field under the cursor takes the wheel: the floating card's fields, the settings
    -- fields in the corner block, and the armed popup. Only rows carrying a stepAction match, so a
    -- scroll over a plain button or empty space still falls through to the camera zoom below. A field
    -- flagged wheelKeepDir (move's falloff) keeps the original direction; the rest use the reversed one.
    if ADFlyoverHud ~= nil then
        local field = ADFlyoverHud:numberFieldAt(self.mouseX, self.mouseY)
        if field ~= nil and field.stepAction ~= nil then
            field.stepAction(field.wheelKeepDir and -step or step)
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
    -- progress), so the camera zoom keeps the wheel the rest of the time. toolStep carries move's
    -- kept-direction; for every other tool it is the reversed step.
    if self.tool == self.TOOL.SIDING and self.sidingAnchorId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.PARALLEL and self.offsetToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.GROUND and self.groundToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.STRAIGHTEN and self.straightenToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.DIVIDE and self.divideToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.MOVE and self.dragId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    if self.tool == self.TOOL.SMOOTH and self.smoothToId ~= nil then return self:applyWheelToActiveTool(toolStep) end
    -- Junction claims the wheel once a SITE IS LOCKED (its pending action - the lock message says
    -- "wheel = scope" at that moment), the same rule as every tool above. It used to claim the wheel
    -- unconditionally while the tool was up, which took the camera zoom away for the whole time the
    -- tool was selected - hunting for the next crossing with no way to zoom. Before the lock the card
    -- still takes the wheel when hovered (the branch above), so the scope can be dialled in first.
    if self.tool == self.TOOL.JUNCTION and self.junctionArmed ~= nil then return self:applyWheelToActiveTool(toolStep) end

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
        Logging.info("[FlyoverEditor]: divide cancelled.")
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

ADFlyoverEditor.FIELD_LOOP_DIR = { CW = 1, CCW = 2, TWOWAY = 3 }
ADFlyoverEditor.FIELD_LOOP_DIR_NAMES = { "clockwise", "counter-clockwise", "two-way" }

function ADFlyoverEditor:toggleFieldLoopPriority()
    self.fieldLoopSubPrio = not self.fieldLoopSubPrio
    Logging.info("[FlyoverEditor]: field loop track will be %s.", self.fieldLoopSubPrio and "secondary" or "primary")
end

function ADFlyoverEditor:cycleFieldLoopDirection()
    self.fieldLoopDirection = (self.fieldLoopDirection % #self.FIELD_LOOP_DIR_NAMES) + 1
    Logging.info("[FlyoverEditor]: field loop track will be %s.", self.FIELD_LOOP_DIR_NAMES[self.fieldLoopDirection])
end

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

    local flags = self.fieldLoopSubPrio and AutoDrive.FLAG_SUBPRIO or AutoDrive.FLAG_NONE
    local direction = ({ [self.FIELD_LOOP_DIR.CW] = "cw", [self.FIELD_LOOP_DIR.CCW] = "ccw",
        [self.FIELD_LOOP_DIR.TWOWAY] = "twoway" })[self.fieldLoopDirection] or "twoway"

    -- A field loop can add hundreds of waypoints in one click, which is exactly the kind of thing
    -- that wants to be undoable in one step.
    ADEditorHistory:snapshot("field loop")

    local ok = AutoDrive:generateFieldLoopAt(self.cursorX, self.cursorZ,
        marginDistance, treeClearance, turningRadius, "ADFlyoverEditor field loop", flags, direction)

    if ok then
        self:invalidateIdReferences()
        ADGraphManager:markChanges()
    end
end
