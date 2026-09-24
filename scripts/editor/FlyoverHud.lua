--[[
ADFlyoverHud - the docked panel for the flyover editor.

Replaces the line of text that used to be rendered across the top of the screen. That was hard to
read against the world, gave no indication of which editor was in charge, and could not be clicked -
so every tool and every connection option had to be a key you remembered.

This panel is the primary interface: it states plainly which editor owns the input, lists the tools
with the active one marked, exposes the connection options as persistent toggles rather than
modifier keys held during each click, and carries a "next step" line that changes with what the
current tool is waiting for.

Built from the same primitives as the mod's own HUD - Overlay.new(g_baseUIFilename) with
g_colorBgUVs and a tint - so it needs no new textures and matches the rest of the mod visually.
]]

ADFlyoverHud = {
    -- Normalised screen coordinates, anchored BOTTOM left and grown upward. The top of the screen
    -- is where the game puts its own control hints, and this panel changes height as tools add
    -- their own rows - anchoring at the top meant it grew down into that space, while anchoring at
    -- the bottom keeps it clear and keeps the header in the same place whatever the height.
    posX = 0.012,
    topY = 0.965,
    width = 0.185,
    rowHeight = 0.020,
    padding = 0.005,

    -- Drag by the header. Screen real estate is personal and every HUD mod wants a different
    -- corner, so pinning it is the default rather than the rule.
    dragging = false,
    dragOffsetX = 0,
    dragOffsetY = 0,

    rows = {},
    background = nil,
    borderOverlay = nil,
    headerOverlay = nil,
    rowOverlay = nil
}

-- Height of the floating tool card's header strip - its drag handle (see buildRows and
-- isMouseOverToolCardGrab). Declared here, at the top: both users sit far apart in this file, and a
-- `local` is only visible to code compiled after it.
local placeMenuAround   -- defined with the menu helpers below; the tool card uses it too
local placeCardInOpenSpace   -- likewise, defined below

--- The fallback when nowhere is fully clear: exactly what a single point gets - centred just below the
--- cursor, clear of it, clamped on screen. No cleverness, so it always behaves the same way.
local function belowCursor(w, h, curX, curY)
    curX, curY = curX or g_lastMousePosX or 0.5, curY or g_lastMousePosY or 0.5
    local x = math.max(0, math.min(1 - w, curX - w * 0.5))
    local top = math.max(h, math.min(1, curY - 0.07))
    return x, top
end
local CTX_GRAB_H = 0.022

-- Localization shorthand: an English UI string in, its localized form out (or unchanged when there is
-- no translation, or when the locale module is not loaded). Safe on nil and on already-formatted or
-- dynamic values, which simply pass through - so it can wrap any drawn label or value freely.
local function TR(s)
    if ADFlyoverLocale ~= nil then
        return ADFlyoverLocale.t(s)
    end
    return s
end

function ADFlyoverHud:ensureOverlays()
    if self.background == nil then
        self.background = Overlay.new(g_baseUIFilename, 0, 0, 1, 1)
        self.background:setUVs(g_colorBgUVs)
    end
    if self.borderOverlay == nil then
        self.borderOverlay = Overlay.new(g_baseUIFilename, 0, 0, 1, 1)
        self.borderOverlay:setUVs(g_colorBgUVs)
    end
    if self.headerOverlay == nil then
        self.headerOverlay = Overlay.new(g_baseUIFilename, 0, 0, 1, 1)
        self.headerOverlay:setUVs(g_colorBgUVs)
    end
    if self.rowOverlay == nil then
        self.rowOverlay = Overlay.new(g_baseUIFilename, 0, 0, 1, 1)
        self.rowOverlay:setUVs(g_colorBgUVs)
    end
    -- The tool-glyph atlas: our own DXT1 texture, loaded once. If it cannot be loaded (or the UV
    -- API differs), the toolbar simply stays label-only - the icons are an enhancement, not load-
    -- bearing. iconTried stops it retrying a failed load every frame.
    if self.iconOverlay == nil and not self.iconTried then
        self.iconTried = true
        local dir = ADFlyoverPrelude ~= nil and ADFlyoverPrelude.MOD_DIRECTORY or nil
        if dir ~= nil and Overlay ~= nil then
            local ok, ov = pcall(function()
                return Overlay.new(Utils.getFilename("textures/tool_icons.dds", dir), 0, 0, 1, 1)
            end)
            if ok and ov ~= nil then
                self.iconOverlay = ov
            else
                Logging.warning("[ADFlyoverHud]: could not load textures/tool_icons.dds; the toolbar stays label-only.")
            end
        end
    end
end

--- Draw one tool glyph from the atlas: cell 0..14, row-major in a 4x4 grid of 128px cells, tinted to
--- the button. Guarded so an unexpected UV/render API drops to label-only rather than erroring.
function ADFlyoverHud:renderIcon(cell, x, y, w, h, r, g, b, a)
    if self.iconOverlay == nil or GuiUtils == nil then
        return
    end
    local col, row = cell % 4, math.floor(cell / 4)
    local ok = pcall(function()
        self.iconOverlay:setUVs(GuiUtils.getUVs({ col * 128, row * 128, 128, 128 }, { 512, 512 }))
        self.iconOverlay:setColor(r, g, b, a)
        self.iconOverlay:setPosition(x, y)
        self.iconOverlay:setDimension(w, h)
        self.iconOverlay:render()
    end)
    if not ok then
        self.iconOverlay = nil
    end
end

local function drawQuad(ov, x, y, w, h, r, g, b, a)
    ov:setPosition(x, y)
    ov:setDimension(w, h)
    ov:setColor(r, g, b, a)
    ov:render()
end

local function label(x, y, size, text, r, g, b, a, align)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(r, g, b, a)
    renderText(x, y, size, text)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
end

-- Fill a quad in a theme role's colour. Alpha stays per-call because the same role is drawn at
-- different opacities in different places (a near-opaque panel, a lighter row plate).
local function fillRole(ov, x, y, w, h, role, a)
    local r, g, b = ADFlyoverTheme:rgb(role)
    drawQuad(ov, x, y, w, h, r, g, b, a or 1)
end

-- Draw text in a theme role's colour.
local function labelRole(x, y, size, text, role, a, align)
    local r, g, b = ADFlyoverTheme:rgb(role)
    label(x, y, size, text, r, g, b, a or 1, align)
end

-- A FULLY opaque fill. The base UI overlay is not quite opaque even at alpha 1, so a single fill lets
-- bright text on a panel underneath bleed through a dark modal. Stacking a few passes builds it solid.
-- Used for the backgrounds of the overlay panels (help, settings dialog, manual) that sit over others.
local function fillRoleSolid(ov, x, y, w, h, role)
    local r, g, b = ADFlyoverTheme:rgb(role)
    for _ = 1, 3 do
        drawQuad(ov, x, y, w, h, r, g, b, 1)
    end
end

-- ---------------------------------------------------------------------------------------------
-- The settings dialog draws in its OWN fixed palette, not the theme's - so it stays readable even
-- when a custom theme has made the editor panel itself unreadable, which is the whole reason it
-- exists. Authored in sRGB and linearised the same way the theme is, since setColor takes linear.
-- ---------------------------------------------------------------------------------------------
local function s2l(v)
    if v <= 0.04045 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
end
local DLG = {
    backdrop = { 0, 0, 0 },
    bg       = { 0.10, 0.11, 0.14 },
    border   = { 0.34, 0.40, 0.50 },
    header   = { 0.17, 0.21, 0.29 },
    text     = { 0.93, 0.95, 0.98 },
    muted    = { 0.62, 0.66, 0.72 },
    value    = { 0.70, 0.82, 1.00 },
    accent   = { 0.26, 0.53, 0.90 },
    accentTx = { 1, 1, 1 },
    field    = { 0.14, 0.16, 0.21 },
    step     = { 0.22, 0.26, 0.33 },
}
local function fillC(ov, x, y, w, h, c, a)
    drawQuad(ov, x, y, w, h, s2l(c[1]), s2l(c[2]), s2l(c[3]), a or 1)
end
local function labelC(x, y, size, text, c, a, align)
    label(x, y, size, text, s2l(c[1]), s2l(c[2]), s2l(c[3]), a or 1, align)
end

--- Render one adjustable numeric field as "label ........ value (-)(+)" and register the two stepper
--- buttons as their own clickable rows, so a click on either nudges row.stepAction while a click on
--- the value still types (row.action). The buttons sit at the right; the value is right-aligned just
--- left of them. The buttons overlap the field's full-width box, so isMouseOver scans back-to-front:
--- the buttons are appended after the field and therefore win the click that lands on them.
---
--- Appends to self.rows, so the caller's render loop MUST freeze its length first (numeric for over
--- a frozen count), or it will walk into the buttons it just added.
function ADFlyoverHud:drawNumberField(row, x, y, w, h, fontSize, mx, my, labelRoleName, valueRoleName)
    local pad = self.padding
    local aspect = g_screenAspectRatio or (16 / 9)
    local bh = h * 0.80
    local by = y + (h - bh) * 0.5
    local bw = math.max(bh / aspect, 0.011)   -- pixel-square, but never too narrow to click
    local plusX  = x + w - pad - bw
    local minusX = plusX - bw - pad * 0.6
    local textY = y + (h - fontSize) * 0.5

    labelRole(x + pad * 2, textY, fontSize, row.text, labelRoleName or "bodyText")

    local be = 0.0014
    local function button(bx, glyph, dir)
        local hovered = mx ~= nil and mx >= bx and mx <= bx + bw and my >= by and my <= by + bh
        fillRole(self.borderOverlay, bx - be, by - be, bw + be * 2, bh + be * 2, "stepperBorder", 0.7)
        fillRole(self.rowOverlay, bx, by, bw, bh, hovered and "hoverBg" or "stepperBg", 0.98)
        labelRole(bx + bw * 0.5, textY, fontSize, glyph, "stepperText", hovered and 1 or 0.85,
            RenderText.ALIGN_CENTER)
        table.insert(self.rows, { x = bx, y = by, w = bw, h = bh,
            action = function() if row.stepAction ~= nil then row.stepAction(dir) end end })
    end
    button(minusX, "-", -1)
    button(plusX, "+", 1)

    labelRole(minusX - pad * 0.8, textY, fontSize, row.value or "-", valueRoleName or "valueText", 1,
        RenderText.ALIGN_RIGHT)
end

--- Rebuild the row list for the current editor state. Rows are rebuilt every frame rather than
--- cached because almost all of them change with the tool, the selection or the pending action -
--- caching would mean invalidating on nearly every event anyway.
function ADFlyoverHud:buildRows(editor)
    local rows = {}

    local function add(kind, text, value, active, action)
        -- Labels and option values are localized here, at the one place every panel row is built.
        -- Dynamic values (numbers, hex, key caps, the field readout) are not translation keys, so they
        -- pass through TR unchanged; only the fixed UI chrome actually maps to another language.
        table.insert(rows, { kind = kind, text = TR(text), value = TR(value), active = active, action = action })
    end
    -- A read-only numeric field the mouse wheel drives, now also carrying - / + steppers and per-field
    -- wheel: stepAction nudges the ACTIVE tool's setting (there is one such field per tool), which is
    -- exactly what applyWheelToActiveTool changes. The HUD renders the steppers and routes the wheel.
    local function addWheelNumber(text, value)
        add("toggle", text, value)
        rows[#rows].stepAction = function(dir) editor:applyWheelToActiveTool(dir) end
    end

    add("header", "FLYOVER EDITOR")
    -- Build number, dim, right after the title - so a screenshot in a bug report always says which
    -- version it is. Short P.BUILD, not the full stale-warning string.
    rows[#rows].build = "v" .. ((ADFlyoverPrelude ~= nil and ADFlyoverPrelude.BUILD) or "?")
    -- A gear at the header's right edge opens the standalone settings dialog. (Esc still exits.)
    rows[#rows].gear = true
    add("note", "Standard AutoDrive editing suspended")
    if editor.cardHidden and editor.tool ~= editor.TOOL.NONE then
        add("note", "tool card hidden - press H or the button to show")
    end
    -- What the cursor is over. Field numbers are how fields are referred to when working on them,
    -- and in flyover mode there is no vehicle sitting in one to tell you which is which.
    add("cursor", "under cursor", editor.fieldLabel or "-")
    add("gap")

    -- Tools grouped by job. Grouping and display order are cosmetic: the number key and the setTool
    -- id are the tool's enum value, so regrouping never changes which key drives which tool. Select
    -- is TOOL.NONE - the state that puts every tool away.
    local T = editor.TOOL
    local GROUPS = {
        { "MODE", { T.NONE } },
        { "CREATE", { T.DRAW, T.SPLINE, T.FIELDLOOP, T.PARALLEL, T.SIDING } },
        { "SHAPE", { T.MOVE, T.SMOOTH, T.STRAIGHTEN, T.DIVIDE, T.GROUND } },
        -- JUNCTION is disconnected in this release (see the 0.31.0.1 patch notes) - left out of
        -- this group entirely so there is no button for it, on top of setTool's own refusal.
        { "CONNECT", { T.CONVERT, T.MERGE } },
        { "UTILITY", { T.NAME, T.DELETE } },
    }
    -- Atlas cell per tool (row-major in the 4x4 tool_icons.dds), independent of grouping/order.
    local ICON_CELL = {
        [T.NONE] = 0, [T.DRAW] = 1, [T.SPLINE] = 2, [T.FIELDLOOP] = 3,
        [T.PARALLEL] = 4, [T.SIDING] = 5, [T.MOVE] = 6, [T.SMOOTH] = 7,
        [T.STRAIGHTEN] = 8, [T.DIVIDE] = 9, [T.CONVERT] = 10, [T.MERGE] = 11,
        [T.NAME] = 12, [T.DELETE] = 13, [T.GROUND] = 14,
    }
    for _, grp in ipairs(GROUPS) do
        add("section", grp[1])
        for _, id in ipairs(grp[2]) do
            local name = (id == T.NONE) and "select" or editor.TOOL_NAMES[id]
            add("tool", name, editor:toolKeyLabel(id), editor.tool == id, function() editor:setTool(id) end)
            rows[#rows].iconCell = ICON_CELL[id]
        end
    end

    add("gap")
    add("section", "ACTIONS")
    add("action", "undo", "Q", ADEditorHistory:canUndo(), function()
        if ADEditorHistory:undo() ~= nil then
            editor:invalidateIdReferences()
        end
    end)
    add("action", "redo", "E", ADEditorHistory:canRedo(), function()
        if ADEditorHistory:redo() ~= nil then
            editor:invalidateIdReferences()
        end
    end)
    add("action", "settings", editor.settingsOpen and "open" or "", true,
        function() editor:toggleSettings() end)
    -- Hide/show the floating tool card - the panel-button half of it (the H key does the same). Only
    -- offered when a tool is up, since Select mode has no card to hide.
    if editor.tool ~= editor.TOOL.NONE then
        add("action", editor.cardHidden and "show tool card" or "hide tool card", "H", true,
            function() editor:toggleCard() end)
    end

    -- The look-and-feel controls. Kept in the fixed corner block (above the status line) rather than
    -- the floating card so they stay put while you audition scales and colours, which all apply live.
    if editor.settingsOpen then
        add("gap")
        add("section", "SETTINGS")

        local scaleEntry = {
            label = "ui scale", unit = "x",
            get = function() return ADFlyoverTheme.scale end,
            apply = function(v) return editor:applyThemeScale(v) end,
            step = function(d) editor:stepThemeScale(d) end,
        }
        local scaleEditing = editor.editing ~= nil and editor.editing.label == "ui scale"
        local scaleShown = scaleEditing and (editor.editing.buffer .. "_")
            or string.format("%.2f x", ADFlyoverTheme.scale)
        add("number", "ui scale", scaleShown, scaleEditing, function() editor:beginEditNumber(scaleEntry) end)
        rows[#rows].stepAction = function(d) editor:stepThemeScale(d) end

        add("toggle", "theme", ADFlyoverTheme.PRESET_NAMES[ADFlyoverTheme.preset] or ADFlyoverTheme.preset,
            false, function() editor:cycleThemePreset(1) end)
        rows[#rows].stepAction = function(d) editor:cycleThemePreset(d) end

        add("toggle", "accent", ADFlyoverTheme:accentName(), false, function() editor:cycleThemeAccent(1) end)
        rows[#rows].stepAction = function(d) editor:cycleThemeAccent(d) end

        add("action", "reset to default", "", true, function() editor:resetTheme() end)
        add("action", "more settings...", "", true, function() editor:openSettingsDialog() end)
        add("note", "click / scroll / +- to change - saved automatically")
    end

    add("gap")
    add("status", string.format(TR("selected %d   undo %d   placed %d"),
        editor.selectionCount, ADEditorHistory:depth(), editor.placedCount))

    -- The per-tool context (below) becomes the floating tool card, and only exists while a tool is
    -- active, no menu/armed popup is up (those carry their own controls), and it has not been hidden
    -- with middle-click. In Select mode the point/span/run menus stand in for it, so there is no card.
    -- The card also auto-hides while a point is being dragged (editor.dragId): it is only ever in the
    -- way during a move, and this takes it away for exactly that gesture, then brings it straight back
    -- on release - no key or button needed for the common case.
    --
    -- Reported live (2026-09-22, field loop): the manual/help popup and settings dialog draw over
    -- the screen but the tool card kept drawing too, visibly overlapping it - manualOpen/dialogOpen
    -- were missing from this guard even though the popups themselves already exclude each other
    -- (see manualOpen = false at line ~9700, "the two modals are mutually exclusive").
    local armedMenu = editor.ctxMenu ~= nil and editor.ctxMenu.kind == "armed"
    if editor.tool ~= editor.TOOL.NONE and (editor.ctxMenu == nil or armedMenu) and not editor.cardHidden
        and editor.dragId == nil and not editor.manualOpen and not editor.dialogOpen then
    -- Everything from here down changes height with the tool, so it all lives BELOW the rows that
    -- do not. The tool buttons, undo/redo and the status line keep a fixed position on screen no
    -- matter what is selected, which is what makes them clickable without looking - a button that
    -- moves when the panel above it grows is a button you have to re-find every time. The per-tool
    -- controls are the things that are meant to come and go, so they are the ones that shift.

    -- Only for the tools that actually CREATE connections. Showing it everywhere put 'direction:
    -- two-way' next to the convert tool's own 'make it: two-way', two controls reading the same
    -- but meaning different things - one describing connections not yet made, the other about to
    -- rewrite the ones already there.
    local makesConnections = editor.tool == editor.TOOL.DRAW
        or editor.tool == editor.TOOL.SPLINE

    if makesConnections then
        add("gap")
        add("section", "NEW CONNECTIONS")
        add("toggle", "direction", editor.CONNECTION_NAMES[editor.connectionMode], false,
            function() editor:cycleConnectionMode() end)
        add("toggle", "priority", editor.subPrio and "secondary" or "primary", false,
            function() editor:togglePriority() end)
    end

    add("gap")
    add("section", "THIS TOOL")
    if armedMenu then
        add("note", "right-click applies - Esc cancels")
    end

    if editor.tool == editor.TOOL.PARALLEL or editor.tool == editor.TOOL.SIDING then
        add("toggle", "side", (editor.offsetSide or 1) >= 0 and "left" or "right", false,
            function() editor:flipOffsetSide() end)
    end

    if editor:toolTakesSpanScope() then
        add("toggle", "covers", editor.OFFSET_SCOPE_NAMES[editor.offsetScope], false,
            function() editor:cycleOffsetScope() end)
    end

    if editor.tool == editor.TOOL.MOVE then
        add("toggle", "picks", editor.MOVE_SELECT_NAMES[editor.moveSelectMode], false,
            function() editor:cycleMoveSelectMode() end)
        add("toggle", "falloff", editor.moveFalloffOn and "on" or "off", false,
            function() editor:toggleMoveFalloff() end)
        add("toggle", "copy (b)", editor.moveCopyOn and "on" or "off", false,
            function() editor:toggleMoveCopy() end)
        add("toggle", "disconnect", editor.moveBreakOn and "on" or "off", false,
            function() editor:toggleMoveBreak() end)
        if editor.moveSelectMode == editor.MOVE_SELECT.RUN or editor.moveSelectMode == editor.MOVE_SELECT.SPAN then
            add("toggle", "offset", editor.moveOffsetOn and "on" or "off", false,
                function() editor:toggleMoveOffset() end)
            if editor.moveOffsetOn or editor.moveOffsetChainIds ~= nil then
                add("toggle", "offset falloff", editor.moveOffsetFalloffOn and "on" or "off", false,
                    function() editor:toggleMoveOffsetFalloff() end)
            end
        end
        add("toggle", "auto-hookup", editor.moveAutoHookupOn and "on" or "off", false,
            function() editor:toggleMoveAutoHookup() end)
        add("toggle", "rotate pivot", editor.moveRotatePivotMode == "click" and "click point" or "centroid", false,
            function() editor:cycleMoveRotatePivot() end)
    end

    if editor.tool == editor.TOOL.MOVE or editor.tool == editor.TOOL.DRAW then
        add("toggle", "snap to", editor.snapToTerrain and "terrain" or "surface", false,
            function() editor:toggleSnapToTerrain() end)
    end

    -- Typed numbers for whatever the current tool exposes. Click the value to type it, Enter to
    -- apply; the - / + steppers and the wheel nudge it by the field's own step.
    for _, entry in ipairs(editor:getEditableNumbers()) do
        local editing = editor.editing ~= nil and editor.editing.label == entry.label
        local shown
        if editing then
            shown = editor.editing.buffer .. "_"
        else
            local v = entry.get()
            shown = type(v) == "number"
                and string.format("%." .. tostring(entry.decimals or 2) .. "f %s", v, entry.unit or ""):gsub(" $", "")
                or "-"
        end
        add("number", entry.label, shown, editing, function() editor:beginEditNumber(entry) end)
        if entry.step ~= nil then
            rows[#rows].stepAction = function(dir) entry.step(dir) end
            rows[#rows].wheelReach = entry.wheelReach
        end
    end

    if editor.tool == editor.TOOL.SPLINE then
        -- Read-only: the wheel drives this while a preview is up, and the mod clamps it to
        -- 0.49-3.5. Showing the live value beats a list of preset steps.
        local c = AutoDrive.splineInterpolationUserCurvature
        add("toggle", "curvature (wheel)",
            type(c) == "number" and string.format("%.2f", c) or "-")
        -- Two different things: 'endpoints' changes which end the curve is computed from, so it
        -- reshapes it; 'direction' under NEW CONNECTIONS flips which way traffic runs along it
        -- without touching the shape.
        add("toggle", "endpoints (shape)", editor.splineSwapEnds and "swapped" or "normal", false,
            function() editor:toggleSplineEnds() end)
        -- Which way the curve lies against the track where it arrives. On a two-way track the
        -- automatic choice is a guess between two equally valid tangents.
        add("toggle", "end tangent", editor.splineFlipEndTangent and "flipped" or "auto", false,
            function() editor:toggleSplineEndTangent() end)
        add("toggle", "start tangent", editor.splineFlipStartTangent and "flipped" or "auto", false,
            function() editor:toggleSplineStartTangent() end)

        -- Spell out which way traffic will run, because 'direction: reverse' is meaningless while
        -- direction is two-way and there is otherwise no way to tell that from the panel.
        if editor.splineResolvedStart ~= nil and editor.splineResolvedEnd ~= nil then
            local a, b = editor.splineResolvedStart, editor.splineResolvedEnd
            local mode = editor.connectionMode
            local flow
            if mode == editor.CONNECTION.TWOWAY then
                flow = string.format("%d <-> %d", a, b)
            elseif mode == editor.CONNECTION.REVERSE then
                flow = string.format("%d -> %d", b, a)
            else
                flow = string.format("%d -> %d", a, b)
            end
            add("toggle", "flow", flow)
            if mode == editor.CONNECTION.TWOWAY then
                add("hint", "two-way: set direction to one-way")
                add("hint", "if you want to flip it")
            end
        end
    elseif editor.tool == editor.TOOL.SMOOTH then
        add("toggle", "mode", editor.SMOOTH_MODE_NAMES[editor.smoothMode], false,
            function() editor:cycleSmoothMode() end)
        -- Max spacing (rebuild) and strength (relax) are both typed number fields from
        -- getEditableNumbers, below.
    elseif editor.tool == editor.TOOL.GROUND then
        add("toggle", "level", editor.GROUND_LEVEL_NAMES[editor.groundLevel], false,
            function() editor:cycleGroundLevel() end)
        add("toggle", "snap to", editor.snapToTerrain and "terrain" or "surface", false,
            function() editor:toggleSnapToTerrain() end)
        if editor.groundPreview ~= nil then
            add("toggle", "off the ground", string.format("%d of %d",
                #editor.groundPreview, editor.groundChecked or 0))
        end
    elseif editor.tool == editor.TOOL.FIELDLOOP then
        add("toggle", "priority", editor.fieldLoopSubPrio and "secondary" or "primary", false,
            function() editor:toggleFieldLoopPriority() end)
        add("toggle", "track", editor.FIELD_LOOP_DIR_NAMES[editor.fieldLoopDirection], false,
            function() editor:cycleFieldLoopDirection() end)
        -- Off switches back to the map-field-only lookup, which misses ground plowed to connect
        -- two separate map fields into one (the live tilled-ground trace finds that) - here so
        -- that can be isolated per-site without a settings-dialog trip.
        add("toggle", "detect custom field", ADFlyoverSettings.get("fieldLoopDetectCustomField") and "on" or "off", false,
            function() ADFlyoverSettings.cycle("fieldLoopDetectCustomField", 1) end)
        -- Off skips the tree/pole/fence/building detour entirely, taking the offset boundary as
        -- laid rather than nudging it clear of whatever the obstacle check is flagging.
        add("toggle", "avoid obstacles", ADFlyoverSettings.get("fieldLoopAvoidObstacles") and "on" or "off", false,
            function() ADFlyoverSettings.cycle("fieldLoopAvoidObstacles", 1) end)
    elseif editor.tool == editor.TOOL.CONVERT then
        add("toggle", "make it", editor.CONVERT_OP_NAMES[editor.convertOp], false,
            function() editor:cycleConvertOp() end)
        add("toggle", "applies to", editor.DELETE_SCOPE_NAMES[editor.convertScope], false,
            function() editor:cycleConvertScope() end)
    elseif editor.tool == editor.TOOL.DELETE then
        add("toggle", "removes", editor.DELETE_SCOPE_NAMES[editor.deleteScope], false,
            function() editor:cycleDeleteScope() end)
        -- A selection wins over "scope" entirely (see deleteAtCursor) - easy to miss since nothing
        -- else on this card says so, so a click can look like it deleted "scope"'s single waypoint
        -- when it actually took out the whole selection (reported 2026-09-21).
        if editor.selectionCount > 0 then
            add("header", string.format("%d selected - click deletes the SELECTION, not the setting above", editor.selectionCount))
        end
    elseif editor.tool == editor.TOOL.JUNCTION then
        -- First slice: the scope-radius wheel plus a read-out of what the preview found. No apply yet.
        addWheelNumber("search radius", string.format("%.0f m", editor.junctionRadius or 15))
        add("number", "turn radius", string.format("%.0f m", editor.junctionTurnRadius or 12))
        rows[#rows].stepAction = function(dir)
            editor.junctionTurnRadius = math.max(AutoDrive.FLYOVER_JUNCTION_TURN_MIN,
                math.min(AutoDrive.FLYOVER_JUNCTION_TURN_MAX,
                    (editor.junctionTurnRadius or 12) + dir * AutoDrive.FLYOVER_JUNCTION_TURN_STEP))
        end
        add("toggle", "road check", (editor.junctionCheckSurface ~= false) and "on" or "off (radius only)", false,
            function() editor:toggleJunctionCheckSurface() end)
        add("toggle", "trim/extend", (editor.junctionExtendTrim ~= false) and "on" or "off (clamp at trim)", false,
            function() editor:toggleJunctionExtendTrim() end)
        add("toggle", "existing turns", (editor.junctionRebuild == true) and "rebuild" or "keep", false,
            function() editor:toggleJunctionRebuild() end)
        add("toggle", "curve", (editor.junctionUseDubins ~= false) and "dubins" or "biarc", false,
            function() editor:toggleJunctionCurveEngine() end)
        add("toggle", "obstacles", (editor.junctionCheckObstacles ~= false) and "on" or "off", false,
            function() editor:toggleJunctionCheckObstacles() end)
        add("number", "corridor", string.format("%.1f m", editor.junctionCorridor or 4))
        rows[#rows].stepAction = function(dir)
            editor.junctionCorridor = math.max(AutoDrive.FLYOVER_JUNCTION_CORRIDOR_MIN,
                math.min(AutoDrive.FLYOVER_JUNCTION_CORRIDOR_MAX,
                    (editor.junctionCorridor or 4) + dir * AutoDrive.FLYOVER_JUNCTION_CORRIDOR_STEP))
            editor.junctionPreviewKey = nil
        end
        add("number", "clearance", string.format("%.1f m", editor.junctionClearance or 5))
        rows[#rows].stepAction = function(dir)
            editor.junctionClearance = math.max(AutoDrive.FLYOVER_JUNCTION_CLEARANCE_MIN,
                math.min(AutoDrive.FLYOVER_JUNCTION_CLEARANCE_MAX,
                    (editor.junctionClearance or 5) + dir * AutoDrive.FLYOVER_JUNCTION_CLEARANCE_STEP))
            editor.junctionPreviewKey = nil
        end
        local jp = editor.junctionPreview
        if jp ~= nil then
            add("toggle", "approaches", string.format("%d  (in %d / out %d)", #jp.approaches, jp.nIn, jp.nOut))
            add("toggle", "new movements", tostring(jp.nNew))
            if (jp.nRebuild or 0) > 0 then
                add("toggle", "rebuilt existing", tostring(jp.nRebuild))
            end
            if jp.debris ~= nil and #jp.debris > 0 then
                add("toggle", "old points to clear", tostring(#jp.debris))
            end
            if jp.usedMin ~= nil and jp.usedMax ~= nil then
                local used = (jp.usedMin == jp.usedMax) and string.format("%.0f m", jp.usedMin)
                    or string.format("%.0f-%.0f m", jp.usedMin, jp.usedMax)
                add("toggle", "radius used", used)
            end
            if (jp.nTight or 0) > 0 then
                add("toggle", "too tight (refused)", tostring(jp.nTight))
            end
            if (editor.junctionCheckSurface ~= false) and (jp.nOffRoad or 0) > 0 then
                add("toggle", "off road (refused)", tostring(jp.nOffRoad))
            end
            if (jp.nNoCurve or 0) > 0 then
                add("toggle", "no joinable curve", tostring(jp.nNoCurve))
            end
            if (jp.nUTurn or 0) > 0 then
                add("toggle", "skipped as U-turn", tostring(jp.nUTurn))
            end
            if (jp.nFar or 0) > 0 then
                add("toggle", "too far apart", tostring(jp.nFar))
            end
            if (jp.nLane or 0) > 0 then
                add("toggle", "redundant lane", tostring(jp.nLane))
            end
            if (jp.nBlocked or 0) > 0 then
                add("toggle", "blocked (refused)", tostring(jp.nBlocked))
            end
            add("toggle", "already there", tostring(jp.nExisting))
            add("toggle", "confidence", string.format("%d%%", math.floor(jp.confidence * 100 + 0.5)))
        else
            add("note", "point at a crossing")
        end
    end
    -- MERGE's distance and divergence are the typed number fields above (getEditableNumbers), each
    -- with its own steppers, so there is no separate read-only row for them here any more.

    add("gap")
    add("section", "NEXT")
    -- getNextStepLines now returns one whole (localized) message; wrap it to the card width here so it
    -- breaks correctly whatever the language.
    local nextMsg = editor:getNextStepLines()
    local nextLines = ADFlyoverLocale ~= nil and ADFlyoverLocale.wrap(nextMsg, 34) or { nextMsg }
    for _, line in ipairs(nextLines) do
        add("hint", line)
    end
    end

    return rows
end

function ADFlyoverHud:draw(editor)
    self:ensureOverlays()

    -- A modal owns the screen: draw it ALONE. The panel is skipped on purpose, not just covered - its
    -- own rows are text (the wide "under cursor" field readout reaches under the modal's left edge and
    -- shows straight through it), and engine text composites in a pass an overlay background cannot
    -- hide. The world network and its labels are already suppressed for the same reason (see
    -- ADFlyoverEditor:draw and ADFlyoverProxy.run), so the manual/dialog is the only thing on screen.
    if editor.dialogOpen then
        self:drawSettingsDialog(editor)
        return
    end
    if editor.manualOpen then
        self:drawManual(editor)
        return
    end

    -- Cleared each frame; drawHelp sets it again only when the help card is actually up. Otherwise a
    -- stale rect would keep suppressing world labels over an area with no help panel on it.
    self.helpRect = nil

    local rows = self:buildRows(editor)
    self.rows = rows

    -- The panel scales with the game's own UI scale, times the mod's own scale setting so the editor
    -- can be enlarged for low vision or a high-res display without blowing up the rest of the HUD.
    local modScale = (ADFlyoverTheme ~= nil and ADFlyoverTheme.scale) or 1
    local uiScale = ((g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1) * modScale
    local rowH = self.rowHeight * uiScale
    local width = self.width * uiScale
    local pad = self.padding
    local fontSize = 0.0110 * uiScale
    local toolGap = 0.002

    -- The fixed block (header .. status) stays in the corner. Everything after it is the per-tool
    -- context, which now moves to a floating card near where you are working, so a tool's controls
    -- come to the cursor instead of living in the far corner.
    local split = #rows
    for i, row in ipairs(rows) do
        if row.kind == "status" then
            split = i
            break
        end
    end

    -- Lay rows[first..last] as one column from (x, top); tools pair two to a row. Returns the height.
    local function place(first, last, x, top)
        local y = top - pad
        local leftTaken = false
        for i = first, last do
            local row = rows[i]
            if row.kind == "tool" then
                if leftTaken then
                    row.x, row.y, row.w, row.h = x + width * 0.5 + toolGap, y, width * 0.5 - toolGap, rowH
                    leftTaken = false
                else
                    y = y - rowH
                    row.x, row.y, row.w, row.h = x, y, width * 0.5 - toolGap, rowH
                    leftTaken = true
                end
            else
                leftTaken = false
                local h = row.kind == "gap" and rowH * 0.35 or rowH
                y = y - h
                row.x, row.y, row.w, row.h = x, y, width, h
            end
        end
        return (top - y) + pad
    end

    -- Corner block, anchored top-left and grown down. Its frame is what the header drag clamps.
    local top = self.topY
    local fixedH = place(1, split, self.posX, top)
    self.frameX, self.frameY, self.frameW, self.frameH = self.posX, top - fixedH, width, fixedH

    -- The per-tool context, as a floating card near where you are working - the last world click, or
    -- a default beside the toolbar - grown down, clamped fully on screen.
    local hasContext = split < #rows
    self.ctxFrameW = 0
    if hasContext then
        -- The card carries a VISIBLE header strip along its TOP - the drag handle, styled like the
        -- corner panel's own draggable header so it reads as the same affordance. (The first grab
        -- zone was an invisible strip, and - in this bottom-origin coordinate system - accidentally
        -- along the BOTTOM edge. Nobody found it, reasonably.)
        local grabH = CTX_GRAB_H
        local ch = pad * 2 + grabH
        for i = split + 1, #rows do
            ch = ch + (rows[i].kind == "gap" and rowH * 0.35 or rowH)
        end
        local T = ADFlyoverTheme
        local cardX = editor.toolCardX or (T ~= nil and T.cardX) or (self.posX + width + 0.02)
        local cardY = editor.toolCardY or (T ~= nil and T.cardY) or top
        -- Picked from a menu: the card takes the menu's place, where the player was already looking.
        -- Held only until they drag the card themselves (that clears it), and never saved.
        if editor.cardSpawnX ~= nil then
            -- The menu was small; the card is not. Reusing the menu's corner let the card run off the
            -- bottom, get clamped back up and land ON the selection. So work out its real spot once per
            -- pick: the menu's own spot if the whole card fits clear there, otherwise the best clear one.
            if self.spawnFor ~= editor.cardSpawnToken then
                self.spawnFor = editor.cardSpawnToken
                local bx0, by0, bx1, by1, _, _, tpts = self:actionTargetsBox(editor, 0, 0, 0, 0, true)
                local sx, sy = editor.cardSpawnX, editor.cardSpawnY
                if bx0 ~= nil then
                    local avoid = {}
                    if self.frameW ~= nil and self.frameW > 0 then
                        avoid[1] = { self.frameX, self.frameY, self.frameW, self.frameH }
                    end
                    local found
                    sx, sy, found = placeCardInOpenSpace(tpts, width, ch, avoid, editor.cardSpawnCX, editor.cardSpawnCY)
                    Logging.info("[FlyoverHud] card spawn: %d pts, card %.3fx%.3f, %s -> (%.3f,%.3f) menu spot was (%.3f,%.3f) cursor (%.3f,%.3f)",
                        #tpts, width, ch, found and "clear spot found" or "nothing clear within reach, staying below cursor",
                        sx, sy, editor.cardSpawnX, editor.cardSpawnY, editor.cardSpawnCX or -1, editor.cardSpawnCY or -1)
                end
                self.spawnPos = { sx, sy }
            end
            cardX, cardY = self.spawnPos[1], self.spawnPos[2]
        end
        cardX = math.max(0, math.min(1 - width, cardX))
        cardY = math.max(ch, math.min(1, cardY))
        -- Home is where the player left it. When a NEW thing becomes the work (a selection, a picked
        -- span end, a drag), and the card would cover it, the card steps aside ONCE and then holds
        -- that spot - so it does not chase points as the camera pans. It goes home when the work
        -- ends or changes, and never moves while the player is dragging it.
        if self.ctxDragging or editor.cardSpawnX ~= nil then
            self.cardShift, self.cardKey = nil, nil
        else
            local bx0, by0, bx1, by1, covered, key, tpts = self:actionTargetsBox(editor, cardX, cardY - ch, width, ch)
            if key ~= self.cardKey then
                self.cardKey = key
                self.cardShift = nil
                if covered then
                    local avoid = {}
                    if self.frameW ~= nil and self.frameW > 0 then
                        avoid[1] = { self.frameX, self.frameY, self.frameW, self.frameH }
                    end
                    local sx, sy = placeCardInOpenSpace(tpts, width, ch, avoid, nil, nil, cardX, cardY)
                    self.cardShift = { sx, sy }
                end
            end
            if self.cardShift ~= nil then
                cardX = math.max(0, math.min(1 - width, self.cardShift[1]))
                cardY = math.max(ch, math.min(1, self.cardShift[2]))
            end
        end
        local hC = place(split + 1, #rows, cardX, cardY - grabH) + grabH
        self.ctxFrameX, self.ctxFrameY, self.ctxFrameW, self.ctxFrameH = cardX, cardY - hC, width, hC
    end

    local edge = 0.0025
    -- Corner panel: near-opaque so the world does not read through the text, with a defined edge.
    fillRole(self.borderOverlay, self.frameX - edge, self.frameY - edge,
        self.frameW + edge * 2, self.frameH + edge * 2, "panelBorder", 0.95)
    fillRole(self.background, self.frameX, self.frameY, self.frameW, self.frameH, "panelBg", 0.98)
    -- Floating tool card, accent-tinted border so it reads as the active tool's own controls.
    if hasContext then
        fillRole(self.borderOverlay, self.ctxFrameX - edge, self.ctxFrameY - edge,
            self.ctxFrameW + edge * 2, self.ctxFrameH + edge * 2, "cardBorder", 0.96)
        fillRole(self.background, self.ctxFrameX, self.ctxFrameY, self.ctxFrameW, self.ctxFrameH,
            "cardBg", 0.99)
        -- The header strip: the card's drag handle, styled like the corner panel's own draggable
        -- header so it reads as the same affordance, titled with the active tool's name.
        local gy = self.ctxFrameY + self.ctxFrameH - CTX_GRAB_H
        fillRole(self.headerOverlay, self.ctxFrameX, gy, self.ctxFrameW, CTX_GRAB_H, "headerBg", 1)
        local gTitle = TR(editor.TOOL_NAMES[editor.tool] or "tool")
        labelRole(self.ctxFrameX + pad * 2, gy + (CTX_GRAB_H - fontSize * 0.85) * 0.5,
            fontSize * 0.85, gTitle, "headerText")
    end

    -- Normalised coords are square only on a 1:1 screen; on 16:9 a shape with equal w and h renders
    -- wider than tall. Icons must be pixel-square, so their width is divided by the aspect ratio.
    local aspect = g_screenAspectRatio or (16 / 9)
    local mx, my = editor.mouseX, editor.mouseY
    -- Numeric for over a frozen count: drawNumberField appends the stepper buttons to `rows` as it
    -- draws, and this must not then iterate into the buttons it just added.
    for ri = 1, #rows do
        local row = rows[ri]
        local x, y, width, h = row.x, row.y, row.w, row.h
        local textY = y + (h - fontSize) * 0.5
        local textX = x + self.padding * 2

        if row.kind == "header" then
            fillRole(self.headerOverlay, x, y, width, h, "headerBg", 1)
            labelRole(textX, textY, fontSize, row.text, "headerText")
            if row.build ~= nil then
                -- Dim, small, tucked just after the title. Positioned by the title's measured width
                -- so it sits right against it whatever the label or scale.
                local titleW = getTextWidth ~= nil and getTextWidth(fontSize, row.text) or 0
                local vSize = fontSize * 0.72
                labelRole(textX + titleW + self.padding * 1.5, y + (h - vSize) * 0.5, vSize,
                    row.build, "mutedText")
            end
            if row.value ~= nil then
                labelRole(x + width - self.padding * 2, textY, fontSize * 0.8, row.value,
                    "mutedText", 1, RenderText.ALIGN_RIGHT)
            end
            if row.gear then
                local gh = h * 0.66
                local gw = gh / aspect
                local gx = x + width - self.padding * 1.5 - gw
                local gy = y + (h - gh) * 0.5
                local hovered = mx ~= nil and mx >= gx - self.padding and mx <= x + width
                    and my >= y and my <= y + h
                local gr, gg, gb = ADFlyoverTheme:rgb(hovered and "headerText" or "mutedText")
                self:renderIcon(15, gx, gy, gw, gh, gr, gg, gb, 1)
                -- Remembered so the header DRAG can exclude it: the header is the drag handle, so
                -- without this a click on the gear starts a panel drag and never reaches its action.
                self.gearRect = { x = gx - self.padding, y = y, w = gw + self.padding * 2.5, h = h }
                table.insert(self.rows, { x = self.gearRect.x, y = y, w = self.gearRect.w, h = h,
                    action = function() editor:openSettingsDialog() end })

                -- Help "?" toggle, just left of the gear (accent-tinted while help is open). Also
                -- excluded from the header drag, same as the gear.
                local hbw = gw + self.padding
                local hbx = self.gearRect.x - self.padding * 0.5 - hbw
                local hbHov = mx ~= nil and mx >= hbx and mx <= hbx + hbw and my >= y and my <= y + h
                local hbRole = editor.helpOpen and "accent" or (hbHov and "headerText" or "mutedText")
                labelRole(hbx + hbw * 0.5, textY, fontSize, "?", hbRole, 1, RenderText.ALIGN_CENTER)
                self.helpBtnRect = { x = hbx, y = y, w = hbw, h = h }
                table.insert(self.rows, { x = hbx, y = y, w = hbw, h = h,
                    action = function() editor:toggleHelp() end })
            end
        elseif row.kind == "note" then
            labelRole(textX, textY, fontSize * 0.86, row.text, "mutedText")
        elseif row.kind == "section" then
            labelRole(textX, textY, fontSize * 0.80, row.text, "sectionText")
        elseif row.kind == "tool" then
            -- A plated, bordered button: a hairline outline behind the fill gives it a defined edge
            -- (the "button feel"), the glyph on the left carries the tool, the label names it, and the
            -- number key sits as a dim cap on the right so the labels line up.
            local hovered = mx ~= nil and mx >= x and mx <= x + width and my >= y and my <= y + h
            local fillR, borderR, textR
            if row.active then
                fillR, borderR, textR = "accent", "accentBorder", "accentText"
            elseif hovered then
                fillR, borderR, textR = "hoverBg", "hoverBorder", "bodyText"
            else
                fillR, borderR, textR = "toolBg", "toolBorder", "bodyText"
            end
            local be = 0.0016
            fillRole(self.borderOverlay, x - be, y - be, width + be * 2, h + be * 2, borderR, 0.9)
            fillRole(self.rowOverlay, x, y, width, h, fillR, row.active and 0.96 or 0.95)
            local tr, tg, tb = ADFlyoverTheme:rgb(textR)
            local iconH = h * 0.72
            local iconW = iconH / aspect
            local labelX = textX
            if row.iconCell ~= nil then
                local iconX = x + self.padding * 1.2
                self:renderIcon(row.iconCell, iconX, y + (h - iconH) * 0.5, iconW, iconH, tr, tg, tb, 1)
                labelX = iconX + iconW + self.padding * 1.1
            end
            label(labelX, textY, fontSize, row.text, tr, tg, tb, 1)
            if row.value ~= nil and row.value ~= "" then
                label(x + width - self.padding * 1.5, textY, fontSize * 0.78, row.value,
                    tr * 0.72, tg * 0.72, tb * 0.78, 1, RenderText.ALIGN_RIGHT)
            end
        elseif row.kind == "number" then
            if row.active then
                -- Being typed into: show the buffer, no steppers (they would fight the half-typed value).
                fillRole(self.rowOverlay, x, y, width, h, "editBg", 0.95)
                labelRole(textX, textY, fontSize, row.text, "bodyText")
                labelRole(x + width - self.padding * 2, textY, fontSize, row.value, "headerText", 1,
                    RenderText.ALIGN_RIGHT)
            elseif row.stepAction ~= nil then
                self:drawNumberField(row, x, y, width, h, fontSize, mx, my, "bodyText", "valueText")
            else
                labelRole(textX, textY, fontSize, row.text, "bodyText")
                labelRole(x + width - self.padding * 2, textY, fontSize, row.value, "valueText", 1,
                    RenderText.ALIGN_RIGHT)
            end
        elseif row.kind == "toggle" then
            if row.stepAction ~= nil then
                -- A wheel-driven number dressed as a toggle: give it steppers and per-field wheel too.
                self:drawNumberField(row, x, y, width, h, fontSize, mx, my, "bodyText", "valueText")
            else
                labelRole(textX, textY, fontSize, row.text, "bodyText")
                labelRole(x + width - self.padding * 2, textY, fontSize, row.value, "valueText", 1,
                    RenderText.ALIGN_RIGHT)
            end
        elseif row.kind == "action" then
            -- Dimmed when the action would currently do nothing, so the panel says what is
            -- available rather than only what exists.
            if row.active then
                labelRole(textX, textY, fontSize, row.text, "bodyText")
            else
                labelRole(textX, textY, fontSize, row.text, "mutedText", 0.7)
            end
            labelRole(x + width - self.padding * 2, textY, fontSize * 0.85, row.value, "mutedText", 0.85,
                RenderText.ALIGN_RIGHT)
        elseif row.kind == "cursor" then
            labelRole(textX, textY, fontSize * 0.90, row.text, "mutedText")
            labelRole(x + width - self.padding * 2, textY, fontSize * 0.90, row.value, "valueText", 1,
                RenderText.ALIGN_RIGHT)
        elseif row.kind == "status" then
            labelRole(textX, textY, fontSize * 0.9, row.text, "mutedText")
        elseif row.kind == "hint" then
            labelRole(textX, textY, fontSize * 0.92, row.text, "hintText")
        elseif row.kind == "swatch" then
            -- A colour chip of the edited role plus its hex, so you can see the exact colour you are
            -- tuning even when the role only shows up in a small corner of the panel.
            local chip = h * 0.78
            local chipW = chip / aspect
            local cx = x + self.padding * 2
            local cy = y + (h - chip) * 0.5
            fillRole(self.borderOverlay, cx - 0.0012, cy - 0.0012, chipW + 0.0024, chip + 0.0024, "panelBorder", 0.9)
            if row.swatchRole ~= nil then
                fillRole(self.rowOverlay, cx, cy, chipW, chip, row.swatchRole, 1)
            end
            labelRole(cx + chipW + self.padding * 1.6, textY, fontSize * 0.86, row.text, "mutedText")
            if row.value ~= nil and row.value ~= "" then
                labelRole(x + width - self.padding * 2, textY, fontSize * 0.86, row.value, "valueText", 1,
                    RenderText.ALIGN_RIGHT)
            end
        end
    end

    -- Resize grip in the panel's bottom-right corner: a triangle of dots, drawn last so no row fill
    -- covers it. Dragging it sets the mod's ui scale (see handleDrag); the typed field stays the exact
    -- route. Only the corner panel gets one - the card and menus follow its scale.
    do
        local gh = rowH * 0.62
        local gw = gh / aspect
        local gx = self.frameX + self.frameW - gw - self.padding * 0.6
        local gy = self.frameY + self.padding * 0.6
        self.gripRect = { x = gx - self.padding * 0.6, y = gy - self.padding * 0.6,
            w = gw + self.padding * 1.6, h = gh + self.padding * 1.6 }
        local hov = self.gripDragging or (mx ~= nil and mx >= self.gripRect.x
            and mx <= self.gripRect.x + self.gripRect.w and my >= self.gripRect.y
            and my <= self.gripRect.y + self.gripRect.h)
        local role = hov and "headerText" or "mutedText"
        local dw, dh = gw * 0.2, gh * 0.2
        for row = 0, 2 do
            for col = 0, 2 - row do
                -- col counts leftward from the right edge, row upward from the bottom.
                fillRole(self.rowOverlay, gx + gw - dw - col * gw * 0.4, gy + row * gh * 0.4,
                    dw, dh, role, hov and 1 or 0.75)
            end
        end
    end

    self:drawContextMenu(editor)

    -- Contextual help sits beside the panel and is non-modal, so you can read it while working. The
    -- modals (settings dialog, manual) never reach here - they return at the top of draw(), drawn
    -- alone over a cleared screen - so help and a modal can never render at once.
    if editor.helpOpen and not editor.dialogOpen and not editor.manualOpen then
        self:drawHelp(editor)
    end
end

--- Screen-space bounding box of what a Select-mode menu is about to act on (point / span / run), or
--- nil when none of it is in front of the camera. Same projection the amber highlights use.
local function menuSelectionBox(m)
    if project == nil then return nil end
    local ids = {}
    if m.kind == "point" then
        ids[1] = m.id
    elseif m.kind == "span" and m.ids ~= nil then
        ids = m.ids
    elseif m.kind == "run" and m.runSet ~= nil then
        for id in pairs(m.runSet) do ids[#ids + 1] = id end
    end
    local x0, y0, x1, y1
    local pts, screenOf, inSet = {}, {}, {}
    for _, id in ipairs(ids) do inSet[id] = true end
    for _, id in ipairs(ids) do
        local wp = ADGraphManager:getWayPointById(id)
        if wp ~= nil then
            local ok, sx, sy, depth = pcall(project, wp.x, wp.y + 0.7, wp.z)
            if ok and sx ~= nil and depth ~= nil and depth > 0 then
                x0 = x0 and math.min(x0, sx) or sx
                x1 = x1 and math.max(x1, sx) or sx
                y0 = y0 and math.min(y0, sy) or sy
                y1 = y1 and math.max(y1, sy) or sy
                pts[#pts + 1] = { sx, sy }
                screenOf[id] = { sx, sy }
            end
        end
    end
    if x0 == nil then return nil end
    -- Midpoints between connected selected points, so the drawn line between two far-apart points
    -- counts as covered too, not only the dots.
    for _, id in ipairs(ids) do
        local wp, a = ADGraphManager:getWayPointById(id), screenOf[id]
        if wp ~= nil and a ~= nil and wp.out ~= nil then
            for _, otherId in pairs(wp.out) do
                local b = inSet[otherId] and screenOf[otherId] or nil
                if b ~= nil then
                    pts[#pts + 1] = { (a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5 }
                end
            end
        end
    end
    return x0, y0, x1, y1, pts
end

--- Where a w x h card goes so it does not cover what is selected. "What is selected" is the actual
--- points (and the lines between them) in `pts`, NOT their bounding box: a long curved run has a huge
--- box that is mostly empty ground, and keeping clear of that pushed the card far from the work. So a
--- candidate is fine as long as no selected point falls under it; it may sit inside the box's empty
--- space. Candidates are tried near the cursor first (below it, then to its sides), then around the
--- box. Every one must stay on screen and clear of the `avoid` rects (panel, tool card) and of a
--- keep-out around the cursor (curX, curY). Returns the card's left and top edge; if nothing is fully
--- clear it takes the candidate covering the fewest points.
function placeMenuAround(x0, y0, x1, y1, w, h, avoid, curX, curY, pts, prefer)
    local gap, pm = 0.012, 0.010
    pts = pts or {}
    local function overlap(ax, ay, aw, ah, bx, by, bw, bh)
        local ox = math.min(ax + aw, bx + bw) - math.max(ax, bx)
        local oy = math.min(ay + ah, by + bh) - math.max(ay, by)
        if ox <= 0 or oy <= 0 then return 0 end
        return ox * oy
    end
    local midY = (y0 + y1) * 0.5 + h * 0.5
    local midX = (x0 + x1) * 0.5 - w * 0.5
    local cursorKeep = nil
    if curX ~= nil and curY ~= nil then
        cursorKeep = { curX - 0.04, curY - 0.07, 0.08, 0.14 }
        avoid = { unpack(avoid) }
        avoid[#avoid + 1] = cursorKeep
    end
    -- The top edge that puts a card at column x just below the lowest selected point in that column,
    -- and below the cursor's keep-out - "drop below what is above it".
    local function columnBelow(cx)
        local top = nil
        for _, p in ipairs(pts) do
            if p[1] >= cx - pm and p[1] <= cx + w + pm then
                top = top and math.min(top, p[2] - gap) or (p[2] - gap)
            end
        end
        if cursorKeep ~= nil then
            top = top and math.min(top, curY - 0.07) or (curY - 0.07)
        end
        return top or (y0 - gap)
    end
    local cands = {}
    if prefer ~= nil then
        cands[#cands + 1] = { prefer[1], prefer[2] }                  -- where the menu it replaces sat
    end
    cands[#cands + 1] = { midX, columnBelow(midX) }                   -- below, centred on the selection
    if curX ~= nil then
        cands[#cands + 1] = { curX - w * 0.5, columnBelow(curX - w * 0.5) }   -- below the cursor
        cands[#cands + 1] = { curX + 0.03, curY + h * 0.5 }                  -- right of the cursor
        cands[#cands + 1] = { curX - 0.03 - w, curY + h * 0.5 }              -- left of the cursor
    end
    local below = y0 - gap
    cands[#cands + 1] = { x1 + gap, below }              -- below-right of the box
    cands[#cands + 1] = { x0 - gap - w, below }          -- below-left
    cands[#cands + 1] = { midX, y1 + gap + h }           -- above, centred
    cands[#cands + 1] = { x1 + gap, y1 + gap + h }       -- top-right
    cands[#cands + 1] = { x0 - gap - w, y1 + gap + h }   -- top-left
    cands[#cands + 1] = { x1 + gap, midY }               -- right
    cands[#cands + 1] = { x0 - gap - w, midY }           -- left

    local best, bestScore
    for _, c in ipairs(cands) do
        local cx, ct = c[1], c[2]
        local fits = cx >= 0 and cx + w <= 1 and ct <= 1 and ct - h >= 0
        local ux = math.max(0, math.min(1 - w, cx))
        local ut = math.max(h, math.min(1, ct))
        local covered = 0
        for _, p in ipairs(pts) do
            if p[1] >= ux - pm and p[1] <= ux + w + pm and p[2] >= ut - h - pm and p[2] <= ut + pm then
                covered = covered + 1
            end
        end
        local score = covered * 0.001
        for _, r in ipairs(avoid) do
            score = score + overlap(ux, ut - h, w, h, r[1], r[2], r[3], r[4])
        end
        if not fits then score = score + 0.0001 end
        if score == 0 and fits then
            return ux, ut
        end
        if bestScore == nil or score < bestScore then
            best, bestScore = { ux, ut }, score
        end
    end
    -- Nothing fully clear: fall back to the single-point placement (below the cursor) rather than the
    -- least-bad edge spot.
    if curX ~= nil and curY ~= nil then
        return belowCursor(w, h, curX, curY)
    end
    return best[1], best[2]
end

--- Offsets for the card walk, nearest first, out to CARD_WALK_RADIUS in steps of CARD_WALK_STEP. Built
--- once: the walk tries them in order and the first clear one wins, so it always finds the closest.
local CARD_WALK_STEP, CARD_WALK_RADIUS = 0.01, 0.22
local CARD_WALK_OFFSETS = nil
local function cardWalkOffsets()
    if CARD_WALK_OFFSETS ~= nil then return CARD_WALK_OFFSETS end
    local list, n = {}, math.floor(CARD_WALK_RADIUS / CARD_WALK_STEP + 0.5)
    for ix = -n, n do
        for iy = -n, n do
            local dx, dy = ix * CARD_WALK_STEP, iy * CARD_WALK_STEP
            list[#list + 1] = { dx, dy, dx * dx + dy * dy }
        end
    end
    table.sort(list, function(a, b) return a[3] < b[3] end)
    CARD_WALK_OFFSETS = list
    return list
end

--- Find open ground for a w x h card. Start where a single point would put it (centred just below the
--- cursor) and walk the card outward in small steps, nearest first, out to about a fifth of the
--- screen, taking the first spot with no selected point under it (plus a margin), off the `avoid`
--- rects and off a keep-out around the cursor. Nothing clear within that reach: stay at the start
--- rather than wander off across the screen. Always returns a position.
function placeCardInOpenSpace(pts, w, h, avoid, curX, curY, fromX, fromTop)
    -- `fromX/fromTop` starts the walk at the card's own home instead of below the cursor, so a card
    -- that only needs to step aside moves the least it can - never teleporting to the cursor.
    local startX, startTop
    if fromX ~= nil and fromTop ~= nil then
        startX, startTop = fromX, fromTop
    else
        startX, startTop = belowCursor(w, h, curX, curY)
    end
    if pts == nil or #pts == 0 then return startX, startTop, true end
    local pm = 0.012
    -- Sampled: a 400-point selection does not need every point tested against every step.
    local use, stride = {}, math.max(1, math.floor(#pts / 200))
    for i = 1, #pts, stride do use[#use + 1] = pts[i] end
    local rects = {}
    for _, r in ipairs(avoid or {}) do rects[#rects + 1] = r end
    local cx, cy = curX or g_lastMousePosX, curY or g_lastMousePosY
    if cx ~= nil and cy ~= nil then
        rects[#rects + 1] = { cx - 0.04, cy - 0.07, 0.08, 0.14 }
    end
    local function clearAt(x, top)
        if x < 0 or x + w > 1 or top > 1 or top - h < 0 then return false end
        for _, r in ipairs(rects) do
            if x < r[1] + r[3] and x + w > r[1] and top - h < r[2] + r[4] and top > r[2] then return false end
        end
        for _, p in ipairs(use) do
            if p[1] >= x - pm and p[1] <= x + w + pm and p[2] >= top - h - pm and p[2] <= top + pm then
                return false
            end
        end
        return true
    end
    for _, o in ipairs(cardWalkOffsets()) do
        local x, top = startX + o[1], startTop + o[2]
        if clearAt(x, top) then
            return x, top, true
        end
    end
    return startX, startTop, false
end

--- Screen box of the points the active tool is working on (selection, a picked span end, the point
--- being dragged), and whether any of them sits under the given rect (x, y = bottom-left). Returns
--- x0, y0, x1, y1, covered. Sampled, so a huge box selection stays cheap.
function ADFlyoverHud:actionTargetsBox(editor, rx, ry, rw, rh, includeSpan)
    if project == nil then return nil, nil, nil, nil, nil, "" end
    local ids, n = {}, 0
    local function add(id)
        if id ~= nil and n < 400 then n = n + 1; ids[n] = id end
    end
    for _, key in ipairs({ "dragId", "moveSpanFromId", "moveSpanToId", "straightenFromId", "smoothFromId",
        "divideFromId", "groundFromId", "offsetFromId", "sidingAnchorId", "splineFromId", "mergeFromId",
        "lastWaypointId" }) do
        add(editor[key])
    end
    if editor.selection ~= nil then
        for id in pairs(editor.selection) do add(id) end
    end
    if includeSpan and editor.spanIds ~= nil then
        for _, id in ipairs(editor.spanIds) do add(id) end
    end
    if includeSpan then add(editor.cardSpawnPointId) end
    -- What the work IS, not where it is on screen: count and a cheap sum of the ids, so the key only
    -- changes when the target set does (panning never changes it).
    local sum = 0
    for i = 1, n do sum = sum + ids[i] * i end
    local key = n .. ":" .. sum .. ":" .. (editor.selectionCount or 0)
    local x0, y0, x1, y1, covered
    local tpts = {}
    local m = 0.012
    for i = 1, n do
        local wp = ADGraphManager:getWayPointById(ids[i])
        if wp ~= nil then
            local ok, sx, sy, depth = pcall(project, wp.x, wp.y + 0.7, wp.z)
            if ok and sx ~= nil and depth ~= nil and depth > 0 and sx >= 0 and sx <= 1 and sy >= 0 and sy <= 1 then
                x0 = x0 and math.min(x0, sx) or sx
                x1 = x1 and math.max(x1, sx) or sx
                y0 = y0 and math.min(y0, sy) or sy
                y1 = y1 and math.max(y1, sy) or sy
                tpts[#tpts + 1] = { sx, sy }
                if sx >= rx - m and sx <= rx + rw + m and sy >= ry - m and sy <= ry + rh + m then
                    covered = true
                end
            end
        end
    end
    return x0, y0, x1, y1, covered, key, tpts
end

--- The Select-mode context menu: a small panel of actions for the clicked point, span, or run,
--- anchored just right of the click so the clicked point stays clear for a second/double click. Its
--- rows are appended to self.rows so the panel's own click routing (isMouseOver / onClick) consumes
--- and dispatches them exactly like the main panel's buttons, and they light up on hover.
function ADFlyoverHud:drawContextMenu(editor)
    -- Cleared each frame; set again only when a menu is actually drawn, so a stale header rect never
    -- keeps capturing drags after the menu is gone.
    self.menuHeadRect, self.menuRect = nil, nil
    local m = editor.ctxMenu
    if m == nil then
        return
    end
    -- Selection menus (point/span/run) show only in Select mode; the armed popup shows while its
    -- tool is active, replacing the action list with that tool's own controls.
    if m.kind ~= "armed" and editor.tool ~= editor.TOOL.NONE then
        return
    end
    -- The card-hide (H, or the panel button) hides the armed popup too, so hiding is consistent
    -- across tools - the floating card and this popup are the same "tool options" to the player.
    -- Right-click still applies the armed tool while it is hidden, and the panel note says H shows it.
    if m.kind == "armed" and editor.cardHidden then
        return
    end
    -- The armed state stays (right-click applies, Esc cancels), but its options now live on the tool
    -- card, which opens where this popup used to. Nothing to draw here.
    if m.kind == "armed" then
        return
    end
    self:ensureOverlays()

    local T = editor.TOOL
    local OP = editor.CONVERT_OP
    local modScale = (ADFlyoverTheme ~= nil and ADFlyoverTheme.scale) or 1
    local uiScale = ((g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1) * modScale
    local aspect = g_screenAspectRatio or (16 / 9)
    local rowH = self.rowHeight * uiScale * 1.1
    local pad = self.padding
    local colGap = pad * 0.7
    local vGap = pad * 0.4
    -- Sized to the text: the action menus are two short labels per row, the armed popup also has to
    -- fit a label, a value and two steppers on one row.
    local pw = (m.kind == "armed" and 0.165 or 0.14) * uiScale
    -- Same size as the main panel's text, so the two read as one UI.
    local fontSize = 0.0110 * uiScale

    -- Items. "mbtn" buttons pair into two columns (an unpaired last one spans the row); the rest are
    -- full width. Groups are separated by an "mgap".
    local items = {}
    local function btn(text, action, icon)
        items[#items + 1] = { kind = "mbtn", text = text, action = action, iconCell = icon }
    end
    local function danger(text, action)
        items[#items + 1] = { kind = "mdanger", text = text, action = action }
    end
    local function gap() items[#items + 1] = { kind = "mgap" } end
    local function head(text) items[#items + 1] = { kind = "mhead", text = text } end
    local function itv(kind, text, value, action)
        items[#items + 1] = { kind = kind, text = text, value = value, action = action }
    end
    if m.kind == "point" then
        head(string.format(TR("point %d"), m.id))
        btn("name...", function() editor:menuName() end, 12)
        btn("move", function() editor:menuArmMove() end, 6)
        btn("connect", function() editor:menuArmDraw() end, 1)
        btn("spline", function() editor:menuArmSpline() end, 2)
        gap()
        btn("make two-way", function() editor:menuConvert(OP.TWOWAY) end)
        btn("make one-way", function() editor:menuConvert(OP.ONEWAY) end)
        btn("primary", function() editor:menuConvert(OP.PRIMARY) end)
        btn("secondary", function() editor:menuConvert(OP.SECONDARY) end)
        gap()
        danger("delete point", function() editor:menuDelete() end)
    elseif m.kind == "span" then
        head(string.format(TR("span  %d pts"), m.ids ~= nil and #m.ids or 0))
        btn("straighten", function() editor:menuArmStraighten() end, 8)
        btn("smooth", function() editor:menuArmSmooth() end, 7)
        btn("divide", function() editor:menuArmDivide() end, 9)
        btn("ground", function() editor:menuArmGround() end, 14)
        gap()
        btn("make two-way", function() editor:menuConvertSpan(OP.TWOWAY) end)
        btn("make one-way", function() editor:menuConvertSpan(OP.ONEWAY) end)
        btn("flip direction", function() editor:menuConvertSpan(OP.REVERSE) end)
        gap()
        danger("delete span", function() editor:menuDeleteSpan() end)
    elseif m.kind == "run" then
        head(string.format(TR("run  %s pts"), tostring(m.count or "?")))
        btn("straighten", function() editor:menuArmStraighten() end, 8)
        btn("smooth", function() editor:menuArmSmooth() end, 7)
        btn("divide", function() editor:menuArmDivide() end, 9)
        btn("parallel", function() editor:menuArmParallel() end, 4)
        btn("ground", function() editor:menuArmGround() end, 14)
        gap()
        btn("make two-way", function() editor:menuConvertRun(OP.TWOWAY) end)
        btn("make one-way", function() editor:menuConvertRun(OP.ONEWAY) end)
        btn("flip direction", function() editor:menuConvertRun(OP.REVERSE) end)
        gap()
        danger("delete run", function() editor:menuDeleteRun() end)
    else
        -- Armed: only the selected tool's own controls - its wheel value and any toggles - plus apply
        -- and cancel. The values are read live each frame, so the wheel updates them in place.
        local t = m.tool
        head(string.format(TR("%s - selected"), TR(editor.TOOL_NAMES[t] or "tool")))
        if t == T.SMOOTH then
            itv("mtoggle", "mode", editor.SMOOTH_MODE_NAMES[editor.smoothMode], function() editor:cycleSmoothMode() end)
            if editor.smoothMode == editor.SMOOTH_MODE.REBUILD then
                itv("mwheel", "max spacing", string.format("%.1f m", editor.smoothSpacing))
            else
                itv("mwheel", "strength", tostring(editor.smoothStrength))
            end
        elseif t == T.STRAIGHTEN then
            itv("mwheel", "tolerance", string.format("%.1f m", editor.straightenTolerance))
        elseif t == T.DIVIDE then
            itv("mwheel", "points", tostring(editor.divideCount))
        elseif t == T.GROUND then
            itv("mwheel", "tolerance", string.format("%.1f m", editor.groundTolerance))
            itv("mtoggle", "level", editor.GROUND_LEVEL_NAMES[editor.groundLevel], function() editor:cycleGroundLevel() end)
            itv("mtoggle", "snap to", editor.snapToTerrain and "terrain" or "surface", function() editor:toggleSnapToTerrain() end)
        elseif t == T.PARALLEL then
            itv("mwheel", "distance", string.format("%.1f m", editor.offsetDistance))
            itv("mtoggle", "side", (editor.offsetSide or 1) >= 0 and "left" or "right", function() editor:flipOffsetSide() end)
        end
        gap()
        items[#items + 1] = { kind = "mapply", text = "apply", action = function() editor:menuApplyArmed() end }
        items[#items + 1] = { kind = "mfull", text = "cancel", action = function() editor:menuCancelArmed() end }
        items[#items + 1] = { kind = "mnote", text = "scroll or +/- to adjust - right-click applies" }
    end

    -- Localize every label and toggle value in one place, before layout so widths measure the text
    -- that is actually drawn. The headers were already localized as they were built (they carry
    -- formatted ids), so TR passes them through unchanged; dynamic values (the numbers) are not keys.
    for _, item in ipairs(items) do
        if item.text ~= nil then item.text = TR(item.text) end
        if item.value ~= nil then item.value = TR(item.value) end
    end

    -- Lines: a header, a gap, a full-width row, or a pair of half-width buttons.
    local lines = {}
    do
        local i = 1
        while i <= #items do
            local it = items[i]
            if it.kind == "mbtn" then
                local nxt = items[i + 1]
                if nxt ~= nil and nxt.kind == "mbtn" then
                    lines[#lines + 1] = { cells = { it, nxt }, h = rowH + vGap }
                    i = i + 2
                else
                    lines[#lines + 1] = { cells = { it }, full = true, h = rowH + vGap }
                    i = i + 1
                end
            elseif it.kind == "mhead" then
                lines[#lines + 1] = { cells = { it }, bleed = true, h = rowH * 0.9 + vGap }
                i = i + 1
            elseif it.kind == "mgap" then
                lines[#lines + 1] = { gap = true, h = vGap * 1.5 }
                i = i + 1
            else
                lines[#lines + 1] = { cells = { it }, full = true, h = rowH + vGap }
                i = i + 1
            end
        end
    end
    local ph = pad
    for _, ln in ipairs(lines) do ph = ph + ln.h end

    -- Position. Armed opens beside the click; point/span/run below the selection they act on. Either
    -- is then held (m.placeX) - including wherever the player drags it by the header - and dropped with
    -- the menu, never saved: a menu belongs to one selection.
    local menuGapX, menuGapY = 0.014, 0.02
    local x = math.max(0, math.min(1 - pw, (m.sx or 0.5) + menuGapX))
    local top = math.max(ph, math.min(1, (m.sy or 0.5) + menuGapY + ph))
    if m.placeX == nil and m.kind ~= "armed" then
        local bx0, by0, bx1, by1, bpts = menuSelectionBox(m)
        if bx0 ~= nil then
            local avoid = {}
            if self.frameW ~= nil and self.frameW > 0 then
                avoid[#avoid + 1] = { self.frameX, self.frameY, self.frameW, self.frameH }
            end
            -- Not the tool card: a selection menu only exists in Select mode, where there is no card.
            -- Same walk as the tool card: start just below the cursor and step outward to the nearest
            -- spot with no selected point under it, so the menu lands in the open ground inside a
            -- curve rather than hugging the line.
            local wx, wy, found = placeCardInOpenSpace(bpts, pw, ph, avoid, m.sx, m.sy)
            Logging.info("[FlyoverHud] menu place: %d pts, menu %.3fx%.3f, %s -> (%.3f,%.3f) cursor (%.3f,%.3f)",
                bpts ~= nil and #bpts or 0, pw, ph, found and "clear spot found" or "nothing clear within reach",
                wx, wy, m.sx or -1, m.sy or -1)
            m.placeX, m.placeTop = wx, wy
        end
    end
    if m.placeX ~= nil then
        x, top = m.placeX, m.placeTop
    end
    x = math.max(0, math.min(1 - pw, x))
    top = math.max(ph, math.min(1, top))
    self.menuRect = { x = x, y = top - ph, w = pw, h = ph }
    local mx, my = editor.mouseX, editor.mouseY

    local edge = 0.0025
    fillRole(self.borderOverlay, x - edge, top - ph - edge, pw + edge * 2, ph + edge * 2,
        "cardBorder", 0.98)
    fillRole(self.background, x, top - ph, pw, ph, "cardBg", 0.99)

    local halfW = (pw - pad * 2 - colGap) * 0.5
    local function inside(cx, cy, cw, ch)
        return mx ~= nil and mx >= cx and mx <= cx + cw and my >= cy and my <= cy + ch
    end

    local y = top - pad * 0.5
    for _, ln in ipairs(lines) do
        if not ln.gap then
            for ci, item in ipairs(ln.cells) do
                local cx, cw, ch
                if ln.bleed then
                    cx, cw, ch = x, pw, rowH * 0.9
                elseif ln.full then
                    cx, cw, ch = x + pad, pw - pad * 2, rowH
                else
                    cw, ch = halfW, rowH
                    cx = x + pad + (ci - 1) * (halfW + colGap)
                end
                local cy = y - ch
                item.x, item.y, item.w, item.h = cx, cy, cw, ch
                -- Registered up front so any stepper buttons drawn for it land AFTER it in self.rows;
                -- isMouseOver scans back-to-front, so the buttons on top then win the click over the row.
                table.insert(self.rows, item)
                local hovered = inside(cx, cy, cw, ch)
                local textY = cy + (ch - fontSize) * 0.5
                local be = 0.0016

                if item.kind == "mhead" then
                    -- The drag handle, styled like the card's own header strip.
                    fillRole(self.headerOverlay, cx, cy, cw, ch, "headerBg", 1)
                    labelRole(cx + pad * 2, cy + (ch - fontSize * 0.95) * 0.5, fontSize * 0.95, item.text, "headerText")
                    self.menuHeadRect = { x = cx, y = cy, w = cw, h = ch }
                elseif item.kind == "mnote" then
                    labelRole(cx + pad * 2, cy + (ch - fontSize * 0.8) * 0.5, fontSize * 0.8, item.text, "mutedText")
                elseif item.kind == "mwheel" then
                    -- The wheel drives this while armed; the - / + steppers and per-field wheel adjust it too.
                    fillRole(self.rowOverlay, cx, cy, cw, ch, "toolBg", 0.9)
                    item.stepAction = function(dir) editor:applyWheelToActiveTool(dir) end
                    self:drawNumberField(item, cx, cy, cw, ch, fontSize, mx, my, "bodyText", "valueText")
                elseif item.kind == "mtoggle" then
                    fillRole(self.borderOverlay, cx - be, cy - be, cw + be * 2, ch + be * 2, hovered and "hoverBorder" or "toolBorder", 0.9)
                    fillRole(self.rowOverlay, cx, cy, cw, ch, hovered and "hoverBg" or "toolBg", 0.95)
                    labelRole(cx + pad * 2, textY, fontSize, item.text, "bodyText")
                    labelRole(cx + cw - pad * 2, textY, fontSize, item.value or "-", "valueText", 1, RenderText.ALIGN_RIGHT)
                elseif item.kind == "mapply" then
                    fillRole(self.borderOverlay, cx - be, cy - be, cw + be * 2, ch + be * 2, "accentBorder", 0.9)
                    fillRole(self.rowOverlay, cx, cy, cw, ch, "accent", hovered and 0.98 or 0.9)
                    labelRole(cx + cw * 0.5, textY, fontSize, item.text, "accentText", 1, RenderText.ALIGN_CENTER)
                elseif item.kind == "mdanger" then
                    -- A translucent red wash on hover keeps the "this deletes" cue without a dedicated role.
                    fillRole(self.borderOverlay, cx - be, cy - be, cw + be * 2, ch + be * 2, "danger", hovered and 0.9 or 0.45)
                    fillRole(self.rowOverlay, cx, cy, cw, ch, hovered and "danger" or "toolBg", hovered and 0.30 or 0.9)
                    labelRole(cx + cw * 0.5, textY, fontSize, item.text, "danger", 1, RenderText.ALIGN_CENTER)
                else
                    -- mbtn / mfull: a plated, bordered button like the toolbar's, icon on the left when
                    -- the action is a tool, label centred otherwise.
                    fillRole(self.borderOverlay, cx - be, cy - be, cw + be * 2, ch + be * 2, hovered and "hoverBorder" or "toolBorder", 0.9)
                    fillRole(self.rowOverlay, cx, cy, cw, ch, hovered and "hoverBg" or "toolBg", 0.95)
                    if item.iconCell ~= nil then
                        local ih = ch * 0.66
                        local iw = ih / aspect
                        local tr, tg, tb = ADFlyoverTheme:rgb("bodyText")
                        self:renderIcon(item.iconCell, cx + pad * 1.2, cy + (ch - ih) * 0.5, iw, ih, tr, tg, tb, 1)
                        labelRole(cx + cw * 0.5 + iw * 0.5, textY, fontSize, item.text, "bodyText", 1, RenderText.ALIGN_CENTER)
                    else
                        labelRole(cx + cw * 0.5, textY, fontSize, item.text, "bodyText", 1, RenderText.ALIGN_CENTER)
                    end
                end
            end
        end
        y = y - ln.h
    end
end

-- ---------------------------------------------------------------------------------------------
-- The standalone settings dialog: a modal popup for scale + theme + accent + per-role colour, with
-- reset and close. It draws over the editor, dims everything behind it, and owns every click and
-- wheel notch while it is up (the editor routes input to dialogClick/dialogWheel). It matches the
-- panel - the theme's own palette, at the theme's scale; the reset key/FlyoverResetTheme command are
-- the theme-independent recovery path if a colour ever makes things unreadable.
-- ---------------------------------------------------------------------------------------------

--- One numeric/cycle field: "label ........ value (-)(+)", themed, hit-rows into dialogRows.
function ADFlyoverHud:drawDialogField(item, x, y, w, h, fontSize, pad, mx, my)
    local aspect = g_screenAspectRatio or (16 / 9)
    local textY = y + (h - fontSize) * 0.5
    fillRole(self.rowOverlay, x, y, w, h, "toolBg", 0.95)
    labelRole(x + pad * 1.5, textY, fontSize, TR(item.text), "bodyText")

    if item.editing then
        labelRole(x + w - pad * 1.5, textY, fontSize, item.value or "", "headerText", 1, RenderText.ALIGN_RIGHT)
        table.insert(self.dialogRows, { x = x, y = y, w = w, h = h, action = item.action })
        return
    end

    local bh = h * 0.74
    local by = y + (h - bh) * 0.5
    local bw = math.max(bh / aspect, 0.016)
    local plusX = x + w - pad - bw
    local minusX = plusX - bw - pad * 0.6

    local function button(bx, glyph, dir)
        local hov = mx ~= nil and mx >= bx and mx <= bx + bw and my >= by and my <= by + bh
        fillRole(self.borderOverlay, bx - 0.0016, by - 0.0016, bw + 0.0032, bh + 0.0032, "stepperBorder", 0.7)
        fillRole(self.rowOverlay, bx, by, bw, bh, hov and "hoverBg" or "stepperBg", 1)
        labelRole(bx + bw * 0.5, textY, fontSize, glyph, "stepperText", hov and 1 or 0.85, RenderText.ALIGN_CENTER)
        table.insert(self.dialogRows, { x = bx, y = by, w = bw, h = bh,
            action = function() if item.stepAction then item.stepAction(dir) end end })
    end
    button(minusX, "-", -1)
    button(plusX, "+", 1)
    labelRole(minusX - pad * 0.8, textY, fontSize, TR(item.value or "-"), "valueText", 1, RenderText.ALIGN_RIGHT)

    -- The label/value area: click cycles/edits, wheel over it steps. Shrunk so it does not swallow the
    -- stepper clicks (dialogRows is scanned back-to-front, and this row is added after the buttons).
    table.insert(self.dialogRows, { x = x, y = y, w = math.max(0, minusX - x - pad * 0.4), h = h,
        action = item.action, stepAction = item.stepAction })
end

function ADFlyoverHud:drawSettingsDialog(editor)
    self:ensureOverlays()
    self.dialogRows = {}
    local T = ADFlyoverTheme

    -- Matches the panel: the game UI scale times the mod scale, and (below) the theme's own colours.
    local uiScale = (((g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1)) * ((T.scale) or 1)
    local W = 0.34 * uiScale
    local rowH = 0.030 * uiScale
    local pad = 0.008 * uiScale
    local fontSize = 0.013 * uiScale
    local headH = rowH * 1.4
    local mx, my = editor.mouseX, editor.mouseY

    -- Backdrop over the whole screen: dims the world/panel and (via dialogClick) eats stray clicks.
    fillC(self.background, 0, 0, 1, 1, DLG.backdrop, 0.5)
    fillC(self.background, 0, 0, 1, 1, DLG.backdrop, 0.5)

    local items = {}
    local function push(t) items[#items + 1] = t end
    push({ kind = "title" })
    push({ kind = "section", text = "DISPLAY" })
    do
        local editing = editor.editing ~= nil and editor.editing.label == "ui scale"
        push({ kind = "field", text = "ui scale",
            value = editing and (editor.editing.buffer .. "_") or string.format("%.2f x", T.scale),
            editing = editing,
            action = function()
                editor:beginEditNumber({ label = "ui scale", unit = "x",
                    get = function() return T.scale end,
                    apply = function(v) return editor:applyThemeScale(v) end,
                    step = function(d) editor:stepThemeScale(d) end })
            end,
            stepAction = function(d) editor:stepThemeScale(d) end })
    end
    do
        local editing = editor.editing ~= nil and editor.editing.label == "line weight"
        push({ kind = "field", text = "line weight",
            value = editing and (editor.editing.buffer .. "_") or string.format("%.1f", T.lineWeight),
            editing = editing,
            action = function()
                editor:beginEditNumber({ label = "line weight", unit = "",
                    get = function() return T.lineWeight end,
                    apply = function(v) return editor:applyLineWeight(v) end,
                    step = function(d) editor:stepLineWeight(d) end })
            end,
            stepAction = function(d) editor:stepLineWeight(d) end })
    end
    push({ kind = "section", text = "THEME" })
    push({ kind = "field", text = "theme", value = (T.PRESET_NAMES[T.preset] or T.preset),
        action = function() editor:cycleThemePreset(1) end,
        stepAction = function(d) editor:cycleThemePreset(d) end })
    push({ kind = "field", text = "accent", value = T:accentName(),
        action = function() editor:cycleThemeAccent(1) end,
        stepAction = function(d) editor:cycleThemeAccent(d) end })

    -- Advanced: hand-tune one role's R/G/B - the same controls as the in-panel advanced editor.
    push({ kind = "section", text = "ADVANCED - PER-ROLE COLOUR" })
    local roleKey, roleLabel = editor:currentEditRole()
    local overridden = roleKey ~= nil and T.overrides[roleKey] ~= nil
    push({ kind = "field", text = "role", value = roleLabel or "-",
        action = function() editor:cycleEditRole(1) end,
        stepAction = function(d) editor:cycleEditRole(d) end })
    push({ kind = "swatch", role = roleKey, value = roleKey ~= nil and T:hexOf(roleKey) or "",
        text = overridden and "current (custom)" or "current" })
    for _, cc in ipairs({ { "R", 1 }, { "G", 2 }, { "B", 3 } }) do
        local chLabel, idx = cc[1], cc[2]
        local editingCh = editor.editing ~= nil and editor.editing.label == ("dlg colour " .. chLabel)
        push({ kind = "field", text = chLabel,
            value = editingCh and (editor.editing.buffer .. "_") or tostring(editor:roleChannel255(idx)),
            editing = editingCh,
            action = function()
                editor:beginEditNumber({ label = "dlg colour " .. chLabel, unit = "",
                    get = function() return editor:roleChannel255(idx) end,
                    apply = function(v) return editor:setRoleChannel255(idx, v) end,
                    step = function(d) editor:stepRoleChannel(idx, d) end })
            end,
            stepAction = function(d) editor:stepRoleChannel(idx, d) end })
    end
    if overridden then
        push({ kind = "button", text = "clear this colour", action = function() editor:clearEditRole() end })
    end

    push({ kind = "section", text = "LAUNCH BUTTON" })
    push({ kind = "field", text = "on AutoDrive HUD",
        value = ADFlyoverSettings.get("launchButtonHidden") and "hidden" or "shown",
        action = function() ADFlyoverSettings.cycle("launchButtonHidden", 1) end,
        stepAction = function(d) ADFlyoverSettings.cycle("launchButtonHidden", d) end })
    push({ kind = "field", text = "position", value = tostring(ADFlyoverSettings.get("launchButtonPosition")),
        action = function() ADFlyoverSettings.cycle("launchButtonPosition", 1) end,
        stepAction = function(d) ADFlyoverSettings.cycle("launchButtonPosition", d) end })

    push({ kind = "section", text = "DEBUG" })
    push({ kind = "field", text = "verbose logging",
        value = ADFlyoverSettings.get("flyoverDebugLogging") and "on" or "off",
        action = function() ADFlyoverSettings.cycle("flyoverDebugLogging", 1) end,
        stepAction = function(d) ADFlyoverSettings.cycle("flyoverDebugLogging", d) end })
    push({ kind = "note", text = "off by default - routine click/action lines bloat log.txt over a "
        .. "long session; warnings and errors always log regardless" })

    push({ kind = "gap" })
    push({ kind = "button", text = "reset all to default", action = function() editor:resetTheme() end })
    push({ kind = "button", text = "close", style = "accent", action = function() editor:closeSettingsDialog() end })
    push({ kind = "note", text = "changes apply live and save automatically  -  Esc to close" })

    local function itemH(it)
        if it.kind == "title" then return headH
        elseif it.kind == "gap" then return rowH * 0.4
        elseif it.kind == "section" or it.kind == "note" then return rowH * 0.85
        else return rowH end
    end
    local h = pad * 2
    for _, it in ipairs(items) do h = h + itemH(it) end

    local x = 0.5 - W * 0.5
    local top = 0.5 + h * 0.5
    -- Backdrop stays a fixed dark dim (not a theme colour) so it darkens the world behind whatever
    -- the theme; everything else below is the theme's own palette, at the theme's scale.
    local edge = 0.0028
    fillRole(self.borderOverlay, x - edge, top - h - edge, W + edge * 2, h + edge * 2, "cardBorder", 1)
    fillRoleSolid(self.background, x, top - h, W, h, "panelBg")

    local y = top - pad
    for _, it in ipairs(items) do
        local ih = itemH(it)
        y = y - ih
        local textY = y + (ih - fontSize) * 0.5
        if it.kind == "title" then
            fillRole(self.headerOverlay, x, y, W, ih, "headerBg", 1)
            local titleText = TR("FLYOVER EDITOR")
            labelRole(x + pad * 2, textY, fontSize, titleText, "headerText")
            local tw = getTextWidth ~= nil and getTextWidth(fontSize, titleText) or 0
            local ver = TR("settings") .. "  v" .. ((ADFlyoverPrelude ~= nil and ADFlyoverPrelude.BUILD) or "?")
            labelRole(x + pad * 2 + tw + pad * 1.5, y + (ih - fontSize * 0.72) * 0.5, fontSize * 0.72, ver, "mutedText")
            local xw = ih
            local xbx = x + W - xw
            local hov = mx ~= nil and mx >= xbx and mx <= xbx + xw and my >= y and my <= y + ih
            labelRole(xbx + xw * 0.5, textY, fontSize, "X", hov and "headerText" or "mutedText", 1, RenderText.ALIGN_CENTER)
            table.insert(self.dialogRows, { x = xbx, y = y, w = xw, h = ih,
                action = function() editor:closeSettingsDialog() end })
        elseif it.kind == "section" then
            labelRole(x + pad * 2, y + (ih - fontSize * 0.82) * 0.5, fontSize * 0.82, TR(it.text), "sectionText")
        elseif it.kind == "note" then
            labelRole(x + pad * 2, y + (ih - fontSize * 0.8) * 0.5, fontSize * 0.8, TR(it.text), "mutedText")
        elseif it.kind == "gap" then
            -- spacer only
        elseif it.kind == "swatch" then
            local chip = ih * 0.7
            local chipW = chip / (g_screenAspectRatio or (16 / 9))
            local cx = x + pad * 2
            local cy = y + (ih - chip) * 0.5
            fillRole(self.borderOverlay, cx - 0.0014, cy - 0.0014, chipW + 0.0028, chip + 0.0028, "cardBorder", 0.9)
            if it.role ~= nil then fillRole(self.rowOverlay, cx, cy, chipW, chip, it.role, 1) end
            labelRole(cx + chipW + pad * 1.6, textY, fontSize * 0.9, TR(it.text), "mutedText")
            if it.value ~= nil and it.value ~= "" then
                labelRole(x + W - pad * 2, textY, fontSize * 0.9, it.value, "valueText", 1, RenderText.ALIGN_RIGHT)
            end
        elseif it.kind == "field" then
            self:drawDialogField(it, x + pad, y, W - pad * 2, ih, fontSize, pad, mx, my)
        elseif it.kind == "button" then
            local bx0, bw0 = x + pad, W - pad * 2
            local hov = mx ~= nil and mx >= bx0 and mx <= bx0 + bw0 and my >= y and my <= y + ih
            local accent = it.style == "accent"
            fillRole(self.rowOverlay, bx0, y, bw0, ih, accent and "accent" or (hov and "hoverBg" or "toolBg"), 1)
            labelRole(x + W * 0.5, textY, fontSize, TR(it.text), accent and "accentText" or "bodyText", 1, RenderText.ALIGN_CENTER)
            table.insert(self.dialogRows, { x = bx0, y = y, w = bw0, h = ih, action = it.action })
        end
    end
end

--- Modal click: back-to-front over dialogRows so a stepper on top wins over the field beneath it.
--- Always returns true - the dialog swallows every click, including ones that miss (the backdrop).
function ADFlyoverHud:dialogClick(mx, my)
    if self.dialogRows ~= nil then
        for i = #self.dialogRows, 1, -1 do
            local r = self.dialogRows[i]
            if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
                if r.action ~= nil then r.action() end
                return true
            end
        end
    end
    return true
end

--- Modal wheel: steps whichever field the cursor is over. Always consumes, so nothing zooms behind.
function ADFlyoverHud:dialogWheel(mx, my, step)
    if self.dialogRows ~= nil and mx ~= nil then
        for i = #self.dialogRows, 1, -1 do
            local r = self.dialogRows[i]
            if r.stepAction ~= nil and mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
                r.stepAction(step)
                return true
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Contextual help: a themed panel beside the editor showing the current tool's help (from Help.lua),
-- following the tool as you switch. Non-modal - it takes no input; a full-frame blocker row just
-- stops a click on it reaching the world underneath. Toggled by the "?" header button and the / key.
-- ---------------------------------------------------------------------------------------------
function ADFlyoverHud:drawHelp(editor)
    if ADFlyoverHelp == nil or ADFlyoverHelp.tools == nil then return end
    self:ensureOverlays()
    local T = ADFlyoverTheme

    local key = (editor.tool == editor.TOOL.NONE) and "select" or editor.TOOL_NAMES[editor.tool]
    local help = ADFlyoverHelp.tools[key]
    if help == nil then return end

    local uiScale = (((g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1)) * ((T.scale) or 1)
    local W = 0.30 * uiScale
    local rowH = 0.019 * uiScale
    local pad = 0.006 * uiScale
    local fontSize = 0.0105 * uiScale
    local headH = rowH * 1.5
    local footH = rowH * 1.35

    -- Reset the scroll to the top when the page (tool) changes, so switching tools does not leave the
    -- new page opened part way down.
    if self.helpToolShown ~= key then
        self.helpToolShown = key
        editor.helpScroll = 0
    end

    local lines = {}
    local function line(kind, text) lines[#lines + 1] = { kind = kind, text = text } end
    -- Localized when a translation exists, English otherwise. The summary comes from one localized
    -- string, the what / how / controls prose from the locale's help sections; all are wrapped to this
    -- (narrower) panel's width so German breaks to fit. Headers localize too.
    local sumLines = ADFlyoverLocale ~= nil and ADFlyoverLocale.summaryLines(key, help.summary, 42) or help.summary
    for _, l in ipairs(sumLines) do line("summary", l) end
    local function section(header, skey, src)
        if src == nil then return end
        local body = ADFlyoverLocale ~= nil and ADFlyoverLocale.helpSection(key, skey, src, 42) or src
        if #body == 0 then return end
        line("gap", "")
        line("section", TR(header))
        for _, l in ipairs(body) do line("body", l) end
    end
    section("WHAT IT DOES", "what", help.what)
    section("HOW TO USE IT", "how", help.how)
    section("CONTROLS", "controls", help.controls)

    local mx, my = editor.mouseX, editor.mouseY

    local contentH = 0
    for _, l in ipairs(lines) do
        contentH = contentH + ((l.kind == "gap") and rowH * 0.4 or rowH)
    end

    -- To the right of the editor panel (so it does not cover the tools), top aligned with the panel,
    -- grown down. The height is CAPPED so the whole card - header, body and footer - fits on screen and
    -- the "browse the full manual" button is always reachable; the body scrolls (wheel over it) when
    -- the page is longer than fits. This is what stopped the long pages (Select's) from pushing the
    -- footer button off the bottom where it could not be clicked.
    local panelW = self.width * uiScale
    local x = math.max(0.006, math.min(self.posX + panelW + 0.015, 1 - W - 0.006))
    local top = math.min(1, math.max(0.30, self.topY))
    local maxContentH = math.max(rowH * 3, top - 0.02 - headH - footH - pad * 4)
    local visibleH = math.min(contentH, maxContentH)
    local maxScroll = math.max(0, contentH - visibleH)
    local scroll = math.max(0, math.min(editor.helpScroll or 0, maxScroll))
    editor.helpScroll = scroll

    local h = headH + pad + visibleH + pad + footH + pad

    local edge = 0.0025
    fillRole(self.borderOverlay, x - edge, top - h - edge, W + edge * 2, h + edge * 2, "cardBorder", 0.96)
    fillRoleSolid(self.background, x, top - h, W, h, "cardBg")
    -- Whole-card blocker (stops a click reaching the world) and the wheel target for scrolling.
    self.helpRect = { x = x, y = top - h, w = W, h = h }
    table.insert(self.rows, { x = x - edge, y = top - h - edge, w = W + edge * 2, h = h + edge * 2 })

    local y = top - pad - headH
    fillRole(self.headerOverlay, x, y, W, headH, "headerBg", 1)
    labelRole(x + pad * 1.5, y + (headH - fontSize) * 0.5, fontSize, TR(help.name or "?") .. "  -  " .. TR("help"), "headerText")
    local cap = editor:toolKeyLabel(editor.tool)
    if cap ~= nil and cap ~= "" then
        labelRole(x + W - pad * 1.5, y + (headH - fontSize * 0.8) * 0.5, fontSize * 0.8, "key " .. cap,
            "mutedText", 1, RenderText.ALIGN_RIGHT)
    end

    -- content viewport [viewBottom, viewTop], scrolled; lines fully outside it are skipped (same as the
    -- manual, so the edges stay clean with no partial clipping).
    local viewTop = y - pad
    local viewBottom = viewTop - visibleH
    local cursor = 0
    for _, l in ipairs(lines) do
        local ih = (l.kind == "gap") and rowH * 0.4 or rowH
        local lineTopY = viewTop - (cursor - scroll)
        local lineBottomY = lineTopY - ih
        if lineBottomY >= viewBottom - 0.0002 and lineTopY <= viewTop + 0.0002 then
            local ty = lineBottomY + (ih - fontSize) * 0.5
            if l.kind == "summary" then
                labelRole(x + pad * 1.5, ty, fontSize, l.text, "bodyText")
            elseif l.kind == "section" then
                labelRole(x + pad * 1.5, ty, fontSize * 0.82, l.text, "sectionText")
            elseif l.kind == "body" then
                labelRole(x + pad * 1.5, ty, fontSize * 0.92, l.text, "mutedText")
            end
        end
        cursor = cursor + ih
    end

    -- scrollbar on the right edge of the viewport when there is more than fits
    if maxScroll > 0 then
        local sbW = 0.003 * uiScale
        local sbX = x + W - sbW - pad * 0.4
        fillRole(self.rowOverlay, sbX, viewBottom, sbW, visibleH, "toolBg", 0.9)
        local thumbH = math.max(rowH * 0.8, visibleH * (visibleH / contentH))
        local frac = maxScroll > 0 and (scroll / maxScroll) or 0
        local thumbTopY = viewTop - frac * (visibleH - thumbH)
        fillRole(self.rowOverlay, sbX, thumbTopY - thumbH, sbW, thumbH, "accent", 0.9)
    end

    -- Footer: open the full browsable manual. Fixed below the viewport (not the scrolled content), so
    -- it is always on screen and clickable. Added to self.rows after the blocker so the back-to-front
    -- scan finds this button first over its area.
    y = viewBottom - pad - footH
    local fhov = mx ~= nil and mx >= x + pad and mx <= x + W - pad and my >= y and my <= y + footH
    fillRole(self.rowOverlay, x + pad, y + footH * 0.14, W - pad * 2, footH * 0.72, fhov and "hoverBg" or "toolBg", 1)
    labelRole(x + W * 0.5, y + (footH - fontSize) * 0.5, fontSize * 0.92, TR("browse the full manual  >"),
        "bodyText", 1, RenderText.ALIGN_CENTER)
    table.insert(self.rows, { x = x + pad, y = y, w = W - pad * 2, h = footH,
        action = function() editor:openManual() end })
end

-- ---------------------------------------------------------------------------------------------
-- The browsable manual: a modal that pages through the General reference (page 1) and every tool
-- (ADFlyoverHelp.ORDER). Reuses the modal input path - it populates self.dialogRows, so dialogClick
-- and dialogWheel handle its buttons. Prev / Next buttons, the arrow keys, the X, and Esc navigate.
-- ---------------------------------------------------------------------------------------------
function ADFlyoverHud:drawManual(editor)
    if ADFlyoverHelp == nil or ADFlyoverHelp.tools == nil then return end
    self:ensureOverlays()
    self.dialogRows = {}
    local T = ADFlyoverTheme

    local order = ADFlyoverHelp.ORDER or {}
    local pageCount = #order + 1
    local idx = editor.manualIndex or 1
    if idx < 1 then idx = 1 elseif idx > pageCount then idx = pageCount end
    editor.manualIndex = idx

    local uiScale = (((g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1)) * ((T.scale) or 1)
    local W = 0.42 * uiScale
    local rowH = 0.019 * uiScale
    local pad = 0.008 * uiScale
    local fontSize = 0.0115 * uiScale
    local headH = rowH * 1.5
    local footH = rowH * 1.4
    local mx, my = editor.mouseX, editor.mouseY

    fillC(self.background, 0, 0, 1, 1, DLG.backdrop, 0.5)
    fillC(self.background, 0, 0, 1, 1, DLG.backdrop, 0.5)

    local title
    local lines = {}
    local function line(kind, text) lines[#lines + 1] = { kind = kind, text = text } end
    if idx == 1 then
        title = TR("General reference")
        local g = ADFlyoverHelp.general
        if g ~= nil then
            local gSum = ADFlyoverLocale ~= nil and ADFlyoverLocale.generalSummary(g.summary) or g.summary
            if gSum ~= nil then
                for _, l in ipairs(ADFlyoverLocale ~= nil and ADFlyoverLocale.wrap(gSum, 46) or { gSum }) do
                    line("summary", l)
                end
            end
            local secs
            if ADFlyoverLocale ~= nil then
                secs = ADFlyoverLocale.generalSections(g.sections, 46)
            else
                secs = {}
                for _, sec in ipairs(g.sections or {}) do
                    secs[#secs + 1] = { title = string.upper(sec.title or ""), lines = sec.lines or {} }
                end
            end
            for _, sec in ipairs(secs) do
                line("gap", "")
                line("section", sec.title)
                for _, l in ipairs(sec.lines) do line("body", l) end
            end
        end
    else
        local toolKey = order[idx - 1]
        local help = ADFlyoverHelp.tools[toolKey]
        if help == nil then return end
        title = TR(help.name or "?") .. "  -  " .. TR(help.group or "")
        local sumLines = ADFlyoverLocale ~= nil and ADFlyoverLocale.summaryLines(toolKey, help.summary, 48) or (help.summary or {})
        for _, l in ipairs(sumLines) do line("summary", l) end
        -- what / how / controls: localized (wrapped to width in the section's style) when a German
        -- translation exists, else the bundled English lines. Headers localize too.
        local function section(header, key, src)
            if src == nil then return end
            local body = ADFlyoverLocale ~= nil and ADFlyoverLocale.helpSection(toolKey, key, src, 46) or src
            if #body == 0 then return end
            line("gap", "")
            line("section", TR(header))
            for _, l in ipairs(body) do line("body", l) end
        end
        section("WHAT IT DOES", "what", help.what)
        section("HOW TO USE IT", "how", help.how)
        section("CONTROLS", "controls", help.controls)
    end

    local contentH = 0
    for _, l in ipairs(lines) do
        contentH = contentH + ((l.kind == "gap") and rowH * 0.4 or rowH)
    end

    -- Cap the panel to the screen and scroll the body if it does not fit. maxContentH is what is left
    -- for the body after the title bar, footer and paddings, in a panel at most ~0.9 of the screen.
    local maxContentH = math.max(rowH * 3, 0.9 - headH - footH - pad * 4)
    local visibleH = math.min(contentH, maxContentH)
    local maxScroll = math.max(0, contentH - visibleH)
    local scroll = math.max(0, math.min(editor.manualScroll or 0, maxScroll))
    editor.manualScroll = scroll

    local h = headH + pad + visibleH + pad + footH + pad
    local x = 0.5 - W * 0.5
    local top = math.min(1, math.max(h, 0.5 + h * 0.5))

    local edge = 0.0028
    fillRole(self.borderOverlay, x - edge, top - h - edge, W + edge * 2, h + edge * 2, "cardBorder", 1)
    fillRoleSolid(self.background, x, top - h, W, h, "panelBg")

    -- title bar: title (left), page indicator, close X (right)
    local y = top - pad - headH
    local textY = y + (headH - fontSize) * 0.5
    fillRole(self.headerOverlay, x, y, W, headH, "headerBg", 1)
    labelRole(x + pad * 2, textY, fontSize, title, "headerText")
    local xw = headH
    labelRole(x + W - xw - pad, textY, fontSize * 0.8, string.format("%d / %d", idx, pageCount),
        "mutedText", 1, RenderText.ALIGN_RIGHT)
    local xbx = x + W - xw
    local xhov = mx ~= nil and mx >= xbx and mx <= xbx + xw and my >= y and my <= y + headH
    labelRole(xbx + xw * 0.5, textY, fontSize, "X", xhov and "headerText" or "mutedText", 1, RenderText.ALIGN_CENTER)
    table.insert(self.dialogRows, { x = xbx, y = y, w = xw, h = headH, action = function() editor:closeManual() end })

    -- content viewport [viewBottom, viewTop], scrolled. Lines fully outside it are skipped (no partial
    -- clipping, so the edges stay clean); the scroll step is small enough that nothing is skipped over.
    local viewTop = y - pad
    local viewBottom = viewTop - visibleH
    local cursor = 0   -- distance of the current line's top from the content start
    for _, l in ipairs(lines) do
        local ih = (l.kind == "gap") and rowH * 0.4 or rowH
        local lineTopY = viewTop - (cursor - scroll)
        local lineBottomY = lineTopY - ih
        if lineBottomY >= viewBottom - 0.0002 and lineTopY <= viewTop + 0.0002 then
            local ty = lineBottomY + (ih - fontSize) * 0.5
            if l.kind == "summary" then
                labelRole(x + pad * 2, ty, fontSize, l.text, "bodyText")
            elseif l.kind == "section" then
                labelRole(x + pad * 2, ty, fontSize * 0.82, l.text, "sectionText")
            elseif l.kind == "body" then
                labelRole(x + pad * 2, ty, fontSize * 0.92, l.text, "mutedText")
            end
        end
        cursor = cursor + ih
    end

    -- scrollbar on the right edge of the viewport when there is more than fits
    if maxScroll > 0 then
        local sbW = 0.003 * uiScale
        local sbX = x + W - sbW - pad * 0.4
        fillRole(self.rowOverlay, sbX, viewBottom, sbW, visibleH, "toolBg", 0.9)
        local thumbH = math.max(rowH * 0.8, visibleH * (visibleH / contentH))
        local frac = scroll / maxScroll
        local thumbTopY = viewTop - frac * (visibleH - thumbH)
        fillRole(self.rowOverlay, sbX, thumbTopY - thumbH, sbW, thumbH, "accent", 0.9)
    end

    -- footer sits below the fixed viewport, not below the (possibly scrolled) content.
    y = viewBottom - pad - footH
    local halfW = (W - pad * 3) * 0.5
    local function navBtn(bx, label, dir)
        local hov = mx ~= nil and mx >= bx and mx <= bx + halfW and my >= y and my <= y + footH
        fillRole(self.rowOverlay, bx, y, halfW, footH, hov and "hoverBg" or "toolBg", 1)
        labelRole(bx + halfW * 0.5, y + (footH - fontSize) * 0.5, fontSize, label, "bodyText", 1,
            RenderText.ALIGN_CENTER)
        table.insert(self.dialogRows, { x = bx, y = y, w = halfW, h = footH,
            action = function() editor:manualStep(dir) end })
    end
    navBtn(x + pad, TR("<  prev"), -1)
    navBtn(x + pad * 2 + halfW, TR("next  >"), 1)
end

--- Is the mouse over the floating tool card? The wheel handler asks this so scrolling over the card
--- adjusts the active tool's setting even with nothing selected yet (move's falloff, a tolerance).
function ADFlyoverHud:isMouseOverToolCard(mx, my)
    if mx == nil or self.ctxFrameW == nil or self.ctxFrameW <= 0 then
        return false
    end
    return mx >= self.ctxFrameX and mx <= self.ctxFrameX + self.ctxFrameW
        and my >= self.ctxFrameY and my <= self.ctxFrameY + self.ctxFrameH
end

--- Is the point over the contextual help card? The wheel handler asks this so a scroll over the help
--- pages its body rather than zooming the camera. Only meaningful while the help is open (the rect is
--- from the last help draw); callers gate on editor.helpOpen.
function ADFlyoverHud:isMouseOverHelp(mx, my)
    local r = self.helpRect
    if mx == nil or r == nil then
        return false
    end
    return mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h
end

--- Does a screen point (normalised, y up - the same space as project() and the mouse) fall on one of
--- the editor's solid UI surfaces: the corner panel, the floating tool card, or the help card? The
--- world-label wrap uses this to drop AutoDrive's marker names where they would otherwise draw as text
--- straight through the panel (the engine composites text over overlays, so hiding them is the only
--- way). The help card is covered by the frame test only while it is open; its rect persists between
--- draws, so this also folds in isMouseOver for the panel/card rows and any open context menu.
function ADFlyoverHud:coversPoint(x, y)
    if x == nil or y == nil then
        return false
    end
    local function inRect(rx, ry, rw, rh)
        return rw ~= nil and rw > 0 and x >= rx and x <= rx + rw and y >= ry and y <= ry + rh
    end
    if inRect(self.frameX, self.frameY, self.frameW, self.frameH) then return true end
    if inRect(self.ctxFrameX, self.ctxFrameY, self.ctxFrameW, self.ctxFrameH) then return true end
    local r = self.helpRect
    if r ~= nil and inRect(r.x, r.y, r.w, r.h) then return true end
    return (self:isMouseOver(x, y))
end

--- The lowest the panel may reach without covering the game's HUD map, for a panel spanning x..x+w.
---
--- Read from hud.ingameMap's live layout (mapPosX/Y, mapSizeX/Y), which the base game swaps as the
--- map cycles through its states - so this follows small, large and rotating without knowing which
--- is which. State 1 is the map switched off. Measured in game: the large map reaches y = 0.51, the
--- small ones about 0.20.
function ADFlyoverHud:mapFloorFor(x, w)
    local margin = 0.02
    local hud = g_currentMission ~= nil and g_currentMission.hud or nil
    local map = hud ~= nil and hud.ingameMap or nil
    if map == nil or map.isVisible == false or map.state == 1 then
        return margin
    end
    local l = map.layout
    if l == nil or l.mapPosX == nil or l.mapSizeX == nil or l.mapPosY == nil or l.mapSizeY == nil then
        return margin
    end
    -- A panel that has been dragged clear of the map sideways owes it nothing.
    if x > l.mapPosX + l.mapSizeX or x + w < l.mapPosX then
        return margin
    end
    return l.mapPosY + l.mapSizeY + 0.012
end

--- Is the mouse over the panel's header row? That is the drag handle.
function ADFlyoverHud:isMouseOverHeader(mouseX, mouseY)
    -- The gear and the "?" help button sit in the header but are NOT drag handles - a click on either
    -- must reach its own action, not start a panel drag.
    local function overRect(r)
        return r ~= nil and mouseX >= r.x and mouseX <= r.x + r.w and mouseY >= r.y and mouseY <= r.y + r.h
    end
    if overRect(self.gearRect) or overRect(self.helpBtnRect) then
        return false
    end
    for _, row in ipairs(self.rows) do
        if row.kind == "header" and row.x ~= nil then
            return mouseX >= row.x and mouseX <= row.x + row.w
                and mouseY >= row.y and mouseY <= row.y + row.h
        end
    end
    return false
end

--- Is the mouse over the floating tool card's header strip - its drag handle? The strip is the TOP
--- of the card: in this bottom-origin coordinate system that is the ctxFrame's HIGH y end (the first
--- version tested the low end, i.e. the card's bottom edge, and was invisible besides - nobody found
--- it, reasonably).
function ADFlyoverHud:isMouseOverToolCardGrab(mouseX, mouseY)
    if self.ctxFrameW == nil or self.ctxFrameW <= 0 then
        return false
    end
    return mouseX >= self.ctxFrameX and mouseX <= self.ctxFrameX + self.ctxFrameW
        and mouseY >= self.ctxFrameY + self.ctxFrameH - CTX_GRAB_H
        and mouseY <= self.ctxFrameY + self.ctxFrameH
end

--- Drag handling for the corner panel AND the floating tool card - two independent drags, each
--- claiming the whole gesture so it never also pans the camera or clicks through to the world.
--- `editor` is needed to write the card's position back (editor.toolCardX/Y), and to remember that
--- the player has taken control of it (editor.toolCardDragged) so the next click of the same action
--- does not jump it back - see ADFlyoverEditor:onLeftPress.
function ADFlyoverHud:handleDrag(editor, mouseX, mouseY, isDown, isUp, button)
    -- The point/span/run/armed menu's header is its drag handle. The position lives on the menu
    -- itself (editor.ctxMenu.placeX/placeTop), so it is held while the menu is open and gone with it.
    local hr, mr, menu = self.menuHeadRect, self.menuRect, editor ~= nil and editor.ctxMenu or nil
    if button == 1 and isDown and menu ~= nil and hr ~= nil and mr ~= nil
        and mouseX >= hr.x and mouseX <= hr.x + hr.w and mouseY >= hr.y and mouseY <= hr.y + hr.h then
        self.menuDragging = true
        self.menuDragDX = mouseX - mr.x
        self.menuDragDY = mouseY - (mr.y + mr.h)
        self.menuDragLogged = 0
        Logging.info("[FlyoverHud] menu drag PRESS mouse=(%.4f,%.4f) rect=(%.4f,%.4f %.4fx%.4f) placeX=%s placeTop=%s",
            mouseX, mouseY, mr.x, mr.y, mr.w, mr.h, tostring(menu.placeX), tostring(menu.placeTop))
        return true
    end
    if self.menuDragging then
        if (button == 1 and isUp) or menu == nil or mr == nil then
            self.menuDragging = false
            Logging.info("[FlyoverHud] menu drag RELEASE mouse=(%.4f,%.4f) button=%s", mouseX, mouseY, tostring(button))
            return true
        end
        menu.placeX = math.max(0, math.min(1 - mr.w, mouseX - self.menuDragDX))
        menu.placeTop = math.max(mr.h, math.min(1, mouseY - self.menuDragDY))
        if (self.menuDragLogged or 0) < 4 then
            self.menuDragLogged = (self.menuDragLogged or 0) + 1
            Logging.info("[FlyoverHud] menu drag MOVE mouse=(%.4f,%.4f) button=%s down=%s up=%s -> place=(%.4f,%.4f)",
                mouseX, mouseY, tostring(button), tostring(isDown), tostring(isUp), menu.placeX, menu.placeTop)
        end
        return true
    end

    if button == 1 and isDown and self:isMouseOverToolCardGrab(mouseX, mouseY) then
        if editor ~= nil then
            editor.cardSpawnX, editor.cardSpawnY = nil, nil
        end
        self.ctxDragging = true
        self.ctxDragOffsetX = mouseX - self.ctxFrameX
        self.ctxDragOffsetY = mouseY - self.ctxFrameY
        return true
    end
    if self.ctxDragging then
        if button == 1 and isUp then
            self.ctxDragging = false
            -- Remember where it was left, once, on release (not per mouse-move: saving writes a file).
            if editor ~= nil and ADFlyoverTheme ~= nil then
                ADFlyoverTheme:setCardPos(editor.toolCardX, editor.toolCardY)
            end
            return true
        end
        if editor ~= nil then
            editor.toolCardDragged = true
            editor.toolCardX = math.max(0, math.min(1 - self.ctxFrameW, mouseX - self.ctxDragOffsetX))
            editor.toolCardY = math.max(self.ctxFrameH or 0, math.min(1, mouseY - self.ctxDragOffsetY + (self.ctxFrameH or 0)))
        end
        return true
    end

    -- Corner grip: resizes the whole editor UI by scale. The panel is anchored top-left, so the
    -- bottom-right corner follows the cursor: the new width is the cursor's distance from the left
    -- edge, and the scale is the grabbed scale times new width over grabbed width. Clamped by the
    -- theme's own limits, and so the right edge cannot leave the screen.
    local gr = self.gripRect
    if button == 1 and isDown and gr ~= nil and ADFlyoverTheme ~= nil
        and mouseX >= gr.x and mouseX <= gr.x + gr.w and mouseY >= gr.y and mouseY <= gr.y + gr.h then
        self.gripDragging = true
        self.gripStartScale = ADFlyoverTheme.scale
        self.gripStartW = self.frameW
        self.gripOffsetX = (self.frameX + self.frameW) - mouseX
        return true
    end
    if self.gripDragging then
        if button == 1 and isUp then
            self.gripDragging = false
            return true
        end
        local w = math.min(mouseX + self.gripOffsetX, 1) - self.posX
        if w > 0 and self.gripStartW > 0 then
            -- setScale() persists each call; only call when the snapped step actually changes so a
            -- drag does not rewrite the settings file on every mouse event.
            local want = self.gripStartScale * w / self.gripStartW
            if math.abs(want - ADFlyoverTheme.scale) >= ADFlyoverTheme.SCALE_STEP * 0.5 then
                ADFlyoverTheme:setScale(want)
            end
        end
        return true
    end

    if button == 1 and isDown and self:isMouseOverHeader(mouseX, mouseY) then
        self.dragging = true
        -- Remember the grab point within the panel so it does not jump to align a corner with
        -- the cursor on the first frame.
        self.dragOffsetX = mouseX - self.posX
        self.dragOffsetY = mouseY - self.topY
        return true
    end

    if self.dragging then
        if button == 1 and isUp then
            self.dragging = false
            return true
        end
        self.posX = mouseX - self.dragOffsetX
        self.topY = mouseY - self.dragOffsetY
        -- Keep the panel entirely on screen. Leaving only a sliver visible is not enough: the
        -- drag handle is the header at the TOP of the panel, so a panel pushed off the bottom
        -- would still be visible but no longer grabbable, and could not be recovered.
        local maxX = 1 - self.frameW
        self.posX = math.max(0, math.min(math.max(0, maxX), self.posX))
        -- The top edge is what is stored now, so the limits are the other way round: it may not go
        -- above the screen, and may not sit so low that the panel hangs off the bottom.
        self.topY = math.max(math.min(self.frameH, 1), math.min(1, self.topY))
        return true
    end

    return false
end

--- True if the mouse is over the panel. The world tools have to know this so a click on a button
--- does not also place a waypoint on the terrain underneath it.
---
--- Scanned back-to-front so the most recently drawn (topmost) row wins where rows overlap: the
--- stepper buttons sit inside a numeric field's full-width box, and a menu can sit over the corner
--- block. Later in the list means drawn on top, so it takes the click.
function ADFlyoverHud:isMouseOver(mouseX, mouseY)
    for i = #self.rows, 1, -1 do
        local row = self.rows[i]
        if row.x ~= nil and mouseX >= row.x and mouseX <= row.x + row.w
            and mouseY >= row.y and mouseY <= row.y + row.h then
            return true, row
        end
    end
    return false, nil
end

--- The numeric field (if any) under the cursor - the one the wheel should drive when scrolling over
--- the card, so scrolling a specific field adjusts THAT field rather than only the tool's default.
--- Uses each field's full-width box (steppers included); the button rows carry no stepAction, so the
--- field row is what matches.
function ADFlyoverHud:numberFieldAt(mouseX, mouseY)
    if mouseX == nil then
        return nil
    end
    for i = #self.rows, 1, -1 do
        local row = self.rows[i]
        if row.stepAction ~= nil and row.x ~= nil
            and mouseX >= row.x and mouseX <= row.x + row.w
            and mouseY >= row.y and mouseY <= row.y + row.h then
            return row
        end
    end
    return nil
end

--- Handle a click on the panel. Returns true if the panel consumed it.
function ADFlyoverHud:onClick(mouseX, mouseY)
    local over, row = self:isMouseOver(mouseX, mouseY)
    if over and row ~= nil and row.action ~= nil then
        row.action()
        return true
    end
    -- A click anywhere on the panel is consumed even if that row does nothing, so clicking a
    -- label never leaks through and edits the world behind the panel.
    return over
end
