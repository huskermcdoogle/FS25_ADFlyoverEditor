-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "LINK_LISTS", "linkList", "tryCall" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: TypedEntry.lua needs %s, which no file loaded before it shares", name)
    end
end
local LINK_LISTS = ADFlyoverEditor.shared.LINK_LISTS
local linkList = ADFlyoverEditor.shared.linkList
local tryCall = ADFlyoverEditor.shared.tryCall
-- MODSPLIT: end of the helpers

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

    if self.tool == self.TOOL.JUNCTION then
        -- THE JUNCTION TOOL'S NUMBERS, typed as well as stepped (the user, 2026-10-11: "you can't type a
        -- value into the radius or search boxes" - they were never in this list). Build mode only: clear
        -- takes its scope from the junction, and place shows none. The two radii are whole metres, as
        -- they are saved.
        if self.junctionMode == "clear" or self.junctionMode == "place" then return {} end
        local function num(label, decimals, get, set, stepBy)
            return {
                label = label, unit = "m", decimals = decimals,
                get = get,
                apply = function(value) set(value) return get() end,
                step = function(dir) set(get() + dir * stepBy) end,
            }
        end
        local function inRange(value, lo, hi) return math.max(lo, math.min(hi, value)) end
        return {
            num("search radius", 0, function() return editor:junctionRadiusValue() end,
                function(v) editor:setJunctionRadius(math.floor(v + 0.5)) end, AD.FLYOVER_JUNCTION_RADIUS_STEP),
            num("turn radius", 0, function() return editor.junctionTurnRadius or 12 end,
                function(v) editor:setJunctionTurnRadius(math.floor(v + 0.5)) end, AD.FLYOVER_JUNCTION_TURN_STEP),
            num("corridor", 1, function() return editor.junctionCorridor or 4 end,
                function(v)
                    editor.junctionCorridor = inRange(v, AD.FLYOVER_JUNCTION_CORRIDOR_MIN, AD.FLYOVER_JUNCTION_CORRIDOR_MAX)
                    editor.junctionPreviewKey = nil
                end, AD.FLYOVER_JUNCTION_CORRIDOR_STEP),
            num("clearance", 1, function() return editor.junctionClearance or 5 end,
                function(v)
                    editor.junctionClearance = inRange(v, AD.FLYOVER_JUNCTION_CLEARANCE_MIN, AD.FLYOVER_JUNCTION_CLEARANCE_MAX)
                    editor.junctionPreviewKey = nil
                end, AD.FLYOVER_JUNCTION_CLEARANCE_STEP),
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

--- Toggle whether one rig of the vehicle set must fit the turns the build lays (junctionDesignRigs).
function ADFlyoverEditor:toggleJunctionRig(key)
    local on = not self:junctionRigOn(key)
    self.junctionRigs = self.junctionRigs or {}
    self.junctionRigs[key] = on
    self.junctionPreviewKey = nil
    Logging.info("[FlyoverEditor]: junction vehicle set - %s %s.", tostring(key),
        on and "must fit the turns" or "no longer checked")
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
        tryCall("drawJunctionNumbers", function() self:drawJunctionNumbers() end)
    end

    tryCall("flyoverPanel", function() ADFlyoverHud:draw(self) end)
end
