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
        table.insert(rows, { kind = kind, text = text, value = value, active = active, action = action })
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
        { "CONNECT", { T.CONVERT, T.MERGE } },
        { "UTILITY", { T.NAME, T.DELETE } },
    }
    local function toolKeyLabel(id)
        if id >= 1 and id <= 9 then return tostring(id) end
        if id == 10 then return "0" end
        return ""
    end
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
            add("tool", name, toolKeyLabel(id), editor.tool == id, function() editor:setTool(id) end)
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
        add("toggle", "advanced colours", editor.advancedOpen and "shown" or "hidden", false,
            function() editor:toggleAdvanced() end)
        add("note", "click / scroll / +- to change - saved automatically")

        -- Layer 3: hand-tune one role at a time. Pick a role, then set its R/G/B (0-255); each write
        -- is an override on top of the preset + accent, cleared back to those with the button below.
        if editor.advancedOpen then
            add("gap")
            add("section", "COLOUR OVERRIDE")

            local roleKey, roleLabel = editor:currentEditRole()
            local overridden = roleKey ~= nil and ADFlyoverTheme.overrides[roleKey] ~= nil

            add("toggle", "edit", roleLabel or "-", false, function() editor:cycleEditRole(1) end)
            rows[#rows].stepAction = function(d) editor:cycleEditRole(d) end

            add("swatch", overridden and "current (custom)" or "current",
                roleKey ~= nil and ADFlyoverTheme:hexOf(roleKey) or "")
            rows[#rows].swatchRole = roleKey

            for _, cc in ipairs({ { "R", 1 }, { "G", 2 }, { "B", 3 } }) do
                local chLabel, idx = cc[1], cc[2]
                local entry = {
                    label = "colour " .. chLabel, unit = "",
                    get = function() return editor:roleChannel255(idx) end,
                    apply = function(v) return editor:setRoleChannel255(idx, v) end,
                    step = function(d) editor:stepRoleChannel(idx, d) end,
                }
                local editing = editor.editing ~= nil and editor.editing.label == entry.label
                local shown = editing and (editor.editing.buffer .. "_") or tostring(editor:roleChannel255(idx))
                add("number", chLabel, shown, editing, function() editor:beginEditNumber(entry) end)
                rows[#rows].stepAction = function(d) editor:stepRoleChannel(idx, d) end
            end

            add("action", "clear this colour", "", overridden, function() editor:clearEditRole() end)
        end
    end

    add("gap")
    add("status", string.format("selected %d   undo %d   placed %d",
        editor.selectionCount, ADEditorHistory:depth(), editor.placedCount))

    -- The per-tool context (below) becomes the floating tool card, and only exists while a tool is
    -- active, no menu/armed popup is up (those carry their own controls), and it has not been hidden
    -- with middle-click. In Select mode the point/span/run menus stand in for it, so there is no card.
    -- The card also auto-hides while a point is being dragged (editor.dragId): it is only ever in the
    -- way during a move, and this takes it away for exactly that gesture, then brings it straight back
    -- on release - no key or button needed for the common case.
    if editor.tool ~= editor.TOOL.NONE and editor.ctxMenu == nil and not editor.cardHidden
        and editor.dragId == nil then
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

    if editor.tool == editor.TOOL.PARALLEL or editor.tool == editor.TOOL.SIDING then
        add("toggle", "side", (editor.offsetSide or 1) >= 0 and "left" or "right", false,
            function() editor:flipOffsetSide() end)
    end

    if editor:toolTakesSpanScope() then
        add("toggle", "covers", editor.OFFSET_SCOPE_NAMES[editor.offsetScope], false,
            function() editor:cycleOffsetScope() end)
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
            shown = type(v) == "number" and string.format("%.2f %s", v, entry.unit or "") or "-"
        end
        add("number", entry.label, shown, editing, function() editor:beginEditNumber(entry) end)
        if entry.step ~= nil then
            rows[#rows].stepAction = function(dir) entry.step(dir) end
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
        -- REBUILD's max spacing is the typed number field above (getEditableNumbers), which carries
        -- its own steppers; MOVE_POINTS has strength instead, driven here.
        if editor.smoothMode ~= editor.SMOOTH_MODE.REBUILD then
            addWheelNumber("strength", tostring(editor.smoothStrength))
        end
    elseif editor.tool == editor.TOOL.GROUND then
        addWheelNumber("tolerance", string.format("%.1f m", editor.groundTolerance))
        add("toggle", "level", editor.GROUND_LEVEL_NAMES[editor.groundLevel], false,
            function() editor:cycleGroundLevel() end)
        add("toggle", "snap to", editor.snapToTerrain and "terrain" or "surface", false,
            function() editor:toggleSnapToTerrain() end)
        if editor.groundPreview ~= nil then
            add("toggle", "off the ground", string.format("%d of %d",
                #editor.groundPreview, editor.groundChecked or 0))
        end
    elseif editor.tool == editor.TOOL.DIVIDE then
        addWheelNumber("points", tostring(editor.divideCount))
    elseif editor.tool == editor.TOOL.PARALLEL then
        addWheelNumber("distance", string.format("%.1f m", editor.offsetDistance))
    elseif editor.tool == editor.TOOL.CONVERT then
        add("toggle", "make it", editor.CONVERT_OP_NAMES[editor.convertOp], false,
            function() editor:cycleConvertOp() end)
        add("toggle", "scope", editor.DELETE_SCOPE_NAMES[editor.convertScope], false,
            function() editor:cycleConvertScope() end)
    elseif editor.tool == editor.TOOL.DELETE then
        add("toggle", "scope", editor.DELETE_SCOPE_NAMES[editor.deleteScope], false,
            function() editor:cycleDeleteScope() end)
    end
    -- MERGE's distance and divergence are the typed number fields above (getEditableNumbers), each
    -- with its own steppers, so there is no separate read-only row for them here any more.

    add("gap")
    add("section", "NEXT")
    for _, line in ipairs(editor:getNextStepLines()) do
        add("hint", line)
    end
    end

    return rows
end

function ADFlyoverHud:draw(editor)
    self:ensureOverlays()

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
        local ch = pad * 2
        for i = split + 1, #rows do
            ch = ch + (rows[i].kind == "gap" and rowH * 0.35 or rowH)
        end
        local cardX = editor.toolCardX or (self.posX + width + 0.02)
        local cardY = editor.toolCardY or top
        cardX = math.max(0, math.min(1 - width, cardX))
        cardY = math.max(ch, math.min(1, cardY))
        local hC = place(split + 1, #rows, cardX, cardY)
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

    self:drawContextMenu(editor)

    -- Drawn last, over everything, so the modal dialog and its dim backdrop sit on top of the panel.
    if editor.dialogOpen then
        self:drawSettingsDialog(editor)
    end
end

--- The Select-mode context menu: a small panel of actions for the clicked point, span, or run,
--- anchored just right of the click so the clicked point stays clear for a second/double click. Its
--- rows are appended to self.rows so the panel's own click routing (isMouseOver / onClick) consumes
--- and dispatches them exactly like the main panel's buttons, and they light up on hover.
function ADFlyoverHud:drawContextMenu(editor)
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
    self:ensureOverlays()

    local modScale = (ADFlyoverTheme ~= nil and ADFlyoverTheme.scale) or 1
    local uiScale = ((g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1) * modScale
    local rowH = self.rowHeight * uiScale
    local pad = self.padding
    local pw = 0.150 * uiScale
    local fontSize = 0.0110 * uiScale
    local OP = editor.CONVERT_OP

    local items = {}
    local function it(kind, text, action, danger)
        table.insert(items, { kind = kind, text = text, action = action, danger = danger })
    end
    -- A row that also carries a right-aligned value: a toggle's state, or a wheel-driven number.
    local function itv(kind, text, value, action)
        table.insert(items, { kind = kind, text = text, value = value, action = action })
    end
    if m.kind == "point" then
        it("mhead", "point " .. tostring(m.id))
        it("mitem", "name...", function() editor:menuName() end)
        it("mitem", "move", function() editor:menuArmMove() end)
        it("mitem", "connect from here", function() editor:menuArmDraw() end)
        it("mitem", "spline from here", function() editor:menuArmSpline() end)
        it("mitem", "make two-way", function() editor:menuConvert(OP.TWOWAY) end)
        it("mitem", "make one-way", function() editor:menuConvert(OP.ONEWAY) end)
        it("mitem", "primary", function() editor:menuConvert(OP.PRIMARY) end)
        it("mitem", "secondary", function() editor:menuConvert(OP.SECONDARY) end)
        it("mitem", "delete point", function() editor:menuDelete() end, true)
    elseif m.kind == "span" then
        it("mhead", string.format("span  %d pts", m.ids ~= nil and #m.ids or 0))
        it("mitem", "straighten", function() editor:menuArmStraighten() end)
        it("mitem", "smooth", function() editor:menuArmSmooth() end)
        it("mitem", "divide", function() editor:menuArmDivide() end)
        it("mitem", "ground", function() editor:menuArmGround() end)
        it("mitem", "make two-way", function() editor:menuConvertSpan(OP.TWOWAY) end)
        it("mitem", "make one-way", function() editor:menuConvertSpan(OP.ONEWAY) end)
        it("mitem", "flip direction", function() editor:menuConvertSpan(OP.REVERSE) end)
        it("mitem", "delete span", function() editor:menuDeleteSpan() end, true)
    elseif m.kind == "run" then
        it("mhead", string.format("run  %s pts", tostring(m.count or "?")))
        it("mitem", "straighten", function() editor:menuArmStraighten() end)
        it("mitem", "smooth", function() editor:menuArmSmooth() end)
        it("mitem", "divide", function() editor:menuArmDivide() end)
        it("mitem", "parallel", function() editor:menuArmParallel() end)
        it("mitem", "ground", function() editor:menuArmGround() end)
        it("mitem", "make two-way", function() editor:menuConvertRun(OP.TWOWAY) end)
        it("mitem", "make one-way", function() editor:menuConvertRun(OP.ONEWAY) end)
        it("mitem", "flip direction", function() editor:menuConvertRun(OP.REVERSE) end)
        it("mitem", "delete run", function() editor:menuDeleteRun() end, true)
    else
        -- Armed: only the selected tool's own controls - its wheel value and any toggles - plus apply
        -- and cancel. The values are read live each frame, so the wheel updates them in place.
        local t = m.tool
        it("mhead", (editor.TOOL_NAMES[t] or "tool") .. " - selected")
        if t == editor.TOOL.SMOOTH then
            itv("mtoggle", "mode", editor.SMOOTH_MODE_NAMES[editor.smoothMode], function() editor:cycleSmoothMode() end)
            if editor.smoothMode == editor.SMOOTH_MODE.REBUILD then
                itv("mwheel", "max spacing", string.format("%.1f m", editor.smoothSpacing))
            else
                itv("mwheel", "strength", tostring(editor.smoothStrength))
            end
        elseif t == editor.TOOL.STRAIGHTEN then
            itv("mwheel", "tolerance", string.format("%.1f m", editor.straightenTolerance))
        elseif t == editor.TOOL.DIVIDE then
            itv("mwheel", "points", tostring(editor.divideCount))
        elseif t == editor.TOOL.GROUND then
            itv("mwheel", "tolerance", string.format("%.1f m", editor.groundTolerance))
            itv("mtoggle", "level", editor.GROUND_LEVEL_NAMES[editor.groundLevel], function() editor:cycleGroundLevel() end)
            itv("mtoggle", "snap to", editor.snapToTerrain and "terrain" or "surface", function() editor:toggleSnapToTerrain() end)
        elseif t == editor.TOOL.PARALLEL then
            itv("mwheel", "distance", string.format("%.1f m", editor.offsetDistance))
            itv("mtoggle", "side", (editor.offsetSide or 1) >= 0 and "left" or "right", function() editor:flipOffsetSide() end)
        end
        it("mapply", "apply", function() editor:menuApplyArmed() end)
        it("mitem", "cancel", function() editor:menuCancelArmed() end)
        it("mnote", "scroll or +/- to adjust - right-click applies")
    end

    local ph = #items * rowH + pad * 2
    -- Offset right of the click so the clicked point stays uncovered - a second click on it makes a
    -- span, a rapid second click makes a run, and both need the point still reachable.
    local x = math.max(0, math.min(1 - pw, (m.sx or 0.5) + 0.006))
    local top = math.max(ph, math.min(1, m.sy or 0.5))
    local mx, my = editor.mouseX, editor.mouseY

    local edge = 0.0025
    fillRole(self.borderOverlay, x - edge, top - ph - edge, pw + edge * 2, ph + edge * 2,
        "cardBorder", 0.98)
    fillRole(self.background, x, top - ph, pw, ph, "cardBg", 0.99)

    local y = top - pad
    for _, item in ipairs(items) do
        y = y - rowH
        item.x, item.y, item.w, item.h = x, y, pw, rowH
        -- Register the row up front so any stepper buttons drawn for it land AFTER it in self.rows;
        -- isMouseOver scans back-to-front, so the buttons on top then win the click over the row.
        table.insert(self.rows, item)
        local textY = y + (rowH - fontSize) * 0.5
        local textX = x + pad * 2
        local rightX = x + pw - pad * 2
        local hovered = mx ~= nil and mx >= x and mx <= x + pw and my >= y and my <= y + rowH
        if item.kind == "mhead" then
            fillRole(self.headerOverlay, x, y, pw, rowH, "headerBg", 1)
            labelRole(textX, textY, fontSize * 0.9, item.text, "headerText")
        elseif item.kind == "mnote" then
            labelRole(textX, textY, fontSize * 0.82, item.text, "mutedText")
        elseif item.kind == "mwheel" then
            -- The wheel drives this while armed; the - / + steppers and per-field wheel adjust it too.
            fillRole(self.rowOverlay, x, y, pw, rowH, "toolBg", 0.9)
            item.stepAction = function(dir) editor:applyWheelToActiveTool(dir) end
            self:drawNumberField(item, x, y, pw, rowH, fontSize, mx, my, "bodyText", "valueText")
        elseif item.kind == "mtoggle" then
            fillRole(self.rowOverlay, x, y, pw, rowH, hovered and "hoverBg" or "toolBg", 0.95)
            labelRole(textX, textY, fontSize, item.text, "bodyText")
            labelRole(rightX, textY, fontSize, item.value or "-", "valueText", 1, RenderText.ALIGN_RIGHT)
        elseif item.kind == "mapply" then
            fillRole(self.rowOverlay, x, y, pw, rowH, "accent", hovered and 0.98 or 0.9)
            labelRole(textX, textY, fontSize, item.text, "accentText")
        elseif item.danger then
            -- A translucent red wash on hover keeps the "this deletes" cue without a dedicated role.
            fillRole(self.rowOverlay, x, y, pw, rowH, hovered and "danger" or "toolBg", hovered and 0.30 or 0.9)
            labelRole(textX, textY, fontSize, item.text, "danger")
        else
            fillRole(self.rowOverlay, x, y, pw, rowH, hovered and "hoverBg" or "toolBg", 0.95)
            labelRole(textX, textY, fontSize, item.text, "bodyText")
        end
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
    labelRole(x + pad * 1.5, textY, fontSize, item.text, "bodyText")

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
    labelRole(minusX - pad * 0.8, textY, fontSize, item.value or "-", "valueText", 1, RenderText.ALIGN_RIGHT)

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
    fillC(self.background, 0, 0, 1, 1, DLG.backdrop, 0.55)

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
    fillRole(self.background, x, top - h, W, h, "panelBg", 1)

    local y = top - pad
    for _, it in ipairs(items) do
        local ih = itemH(it)
        y = y - ih
        local textY = y + (ih - fontSize) * 0.5
        if it.kind == "title" then
            fillRole(self.headerOverlay, x, y, W, ih, "headerBg", 1)
            labelRole(x + pad * 2, textY, fontSize, "FLYOVER EDITOR", "headerText")
            local tw = getTextWidth ~= nil and getTextWidth(fontSize, "FLYOVER EDITOR") or 0
            local ver = "settings  v" .. ((ADFlyoverPrelude ~= nil and ADFlyoverPrelude.BUILD) or "?")
            labelRole(x + pad * 2 + tw + pad * 1.5, y + (ih - fontSize * 0.72) * 0.5, fontSize * 0.72, ver, "mutedText")
            local xw = ih
            local xbx = x + W - xw
            local hov = mx ~= nil and mx >= xbx and mx <= xbx + xw and my >= y and my <= y + ih
            labelRole(xbx + xw * 0.5, textY, fontSize, "X", hov and "headerText" or "mutedText", 1, RenderText.ALIGN_CENTER)
            table.insert(self.dialogRows, { x = xbx, y = y, w = xw, h = ih,
                action = function() editor:closeSettingsDialog() end })
        elseif it.kind == "section" then
            labelRole(x + pad * 2, y + (ih - fontSize * 0.82) * 0.5, fontSize * 0.82, it.text, "sectionText")
        elseif it.kind == "note" then
            labelRole(x + pad * 2, y + (ih - fontSize * 0.8) * 0.5, fontSize * 0.8, it.text, "mutedText")
        elseif it.kind == "gap" then
            -- spacer only
        elseif it.kind == "swatch" then
            local chip = ih * 0.7
            local chipW = chip / (g_screenAspectRatio or (16 / 9))
            local cx = x + pad * 2
            local cy = y + (ih - chip) * 0.5
            fillRole(self.borderOverlay, cx - 0.0014, cy - 0.0014, chipW + 0.0028, chip + 0.0028, "cardBorder", 0.9)
            if it.role ~= nil then fillRole(self.rowOverlay, cx, cy, chipW, chip, it.role, 1) end
            labelRole(cx + chipW + pad * 1.6, textY, fontSize * 0.9, it.text, "mutedText")
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
            labelRole(x + W * 0.5, textY, fontSize, it.text, accent and "accentText" or "bodyText", 1, RenderText.ALIGN_CENTER)
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

--- Is the mouse over the floating tool card? The wheel handler asks this so scrolling over the card
--- adjusts the active tool's setting even with nothing selected yet (move's falloff, a tolerance).
function ADFlyoverHud:isMouseOverToolCard(mx, my)
    if mx == nil or self.ctxFrameW == nil or self.ctxFrameW <= 0 then
        return false
    end
    return mx >= self.ctxFrameX and mx <= self.ctxFrameX + self.ctxFrameW
        and my >= self.ctxFrameY and my <= self.ctxFrameY + self.ctxFrameH
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
    -- The gear sits in the header but is NOT a drag handle - a click on it must reach its own action
    -- (open the dialog), not start a panel drag.
    local g = self.gearRect
    if g ~= nil and mouseX >= g.x and mouseX <= g.x + g.w and mouseY >= g.y and mouseY <= g.y + g.h then
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

--- Drag handling. Returns true while the panel is being dragged, so the editor leaves the world
--- alone for the whole gesture rather than only for the initial click.
function ADFlyoverHud:handleDrag(mouseX, mouseY, isDown, isUp, button)
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
