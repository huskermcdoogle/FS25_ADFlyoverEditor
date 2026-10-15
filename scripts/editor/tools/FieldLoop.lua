-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.

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
