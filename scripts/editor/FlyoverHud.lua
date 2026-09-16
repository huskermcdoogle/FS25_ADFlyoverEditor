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

--- Rebuild the row list for the current editor state. Rows are rebuilt every frame rather than
--- cached because almost all of them change with the tool, the selection or the pending action -
--- caching would mean invalidating on nearly every event anyway.
function ADFlyoverHud:buildRows(editor)
    local rows = {}

    local function add(kind, text, value, active, action)
        table.insert(rows, { kind = kind, text = text, value = value, active = active, action = action })
    end

    add("header", "FLYOVER EDITOR", "Esc to exit")
    add("note", "Standard AutoDrive editing suspended")
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
    for _, grp in ipairs(GROUPS) do
        add("section", grp[1])
        for _, id in ipairs(grp[2]) do
            local name = (id == T.NONE) and "select" or editor.TOOL_NAMES[id]
            add("tool", name, toolKeyLabel(id), editor.tool == id, function() editor:setTool(id) end)
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

    add("gap")
    add("status", string.format("selected %d   undo %d   placed %d",
        editor.selectionCount, ADEditorHistory:depth(), editor.placedCount))

    -- The per-tool context (below) becomes the floating tool card, and only exists while a tool is
    -- active and no menu/armed popup is up (those carry their own controls). In Select mode the
    -- point/span/run menus stand in for it, so there is no card then.
    if editor.tool ~= editor.TOOL.NONE and editor.ctxMenu == nil then
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

    if editor.tool == editor.TOOL.MOVE then
        add("toggle", "falloff (wheel)", string.format("%.1f m", editor.falloffRadius or 0))
    end

    if editor.tool == editor.TOOL.MOVE or editor.tool == editor.TOOL.DRAW then
        add("toggle", "snap to", editor.snapToTerrain and "terrain" or "surface", false,
            function() editor:toggleSnapToTerrain() end)
    end

    -- Typed numbers for whatever the current tool exposes. Click one, type, Enter.
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
        if editor.smoothMode == editor.SMOOTH_MODE.REBUILD then
            add("toggle", "max spacing (wheel)", string.format("%.1f m", editor.smoothSpacing))
        else
            add("toggle", "strength (wheel)", tostring(editor.smoothStrength))
        end
    elseif editor.tool == editor.TOOL.GROUND then
        add("toggle", "tolerance (wheel)", string.format("%.1f m", editor.groundTolerance))
        add("toggle", "level", editor.GROUND_LEVEL_NAMES[editor.groundLevel], false,
            function() editor:cycleGroundLevel() end)
        add("toggle", "snap to", editor.snapToTerrain and "terrain" or "surface", false,
            function() editor:toggleSnapToTerrain() end)
        if editor.groundPreview ~= nil then
            add("toggle", "off the ground", string.format("%d of %d",
                #editor.groundPreview, editor.groundChecked or 0))
        end
    elseif editor.tool == editor.TOOL.DIVIDE then
        add("toggle", "points (wheel)", tostring(editor.divideCount))
    elseif editor.tool == editor.TOOL.CONVERT then
        add("toggle", "make it", editor.CONVERT_OP_NAMES[editor.convertOp], false,
            function() editor:cycleConvertOp() end)
        add("toggle", "scope", editor.DELETE_SCOPE_NAMES[editor.convertScope], false,
            function() editor:cycleConvertScope() end)
    elseif editor.tool == editor.TOOL.DELETE then
        add("toggle", "scope", editor.DELETE_SCOPE_NAMES[editor.deleteScope], false,
            function() editor:cycleDeleteScope() end)
    elseif editor.tool == editor.TOOL.MERGE then
        -- Read-only here: it is a saved setting, changed in AutoDrive's settings page, so showing
        -- it on the panel is about knowing what will happen rather than another place to set it.
        add("toggle", "merge distance",
            string.format("%.1f m", ADFlyoverSettings.get("flyoverMergeDistance") or AutoDrive.FLYOVER_MERGE_DISTANCE))
    end

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

    local uiScale = (g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1
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
    drawQuad(self.borderOverlay, self.frameX - edge, self.frameY - edge,
        self.frameW + edge * 2, self.frameH + edge * 2, 0.28, 0.31, 0.35, 0.95)
    drawQuad(self.background, self.frameX, self.frameY, self.frameW, self.frameH,
        0.105, 0.11, 0.125, 0.97)
    -- Floating tool card, blue-accented so it reads as the active tool's own controls.
    if hasContext then
        drawQuad(self.borderOverlay, self.ctxFrameX - edge, self.ctxFrameY - edge,
            self.ctxFrameW + edge * 2, self.ctxFrameH + edge * 2, 0.34, 0.52, 0.72, 0.96)
        drawQuad(self.background, self.ctxFrameX, self.ctxFrameY, self.ctxFrameW, self.ctxFrameH,
            0.12, 0.13, 0.15, 0.99)
    end

    local mx, my = editor.mouseX, editor.mouseY
    for _, row in ipairs(rows) do
        local x, y, width, h = row.x, row.y, row.w, row.h
        local textY = y + (h - fontSize) * 0.5
        local textX = x + self.padding * 2

        if row.kind == "header" then
            drawQuad(self.headerOverlay, x, y, width, h, 0.16, 0.17, 0.20, 1)
            label(textX, textY, fontSize, row.text, 0.90, 0.91, 0.93, 1)
            if row.value ~= nil then
                label(x + width - self.padding * 2, textY, fontSize * 0.8, row.value,
                    0.54, 0.57, 0.62, 1, RenderText.ALIGN_RIGHT)
            end
        elseif row.kind == "note" then
            label(textX, textY, fontSize * 0.86, row.text, 0.50, 0.53, 0.57, 1)
        elseif row.kind == "section" then
            label(textX, textY, fontSize * 0.80, row.text, 0.52, 0.58, 0.66, 1)
        elseif row.kind == "tool" then
            -- Every tool gets a plate, not just the selected one, so the list reads as a row of
            -- buttons rather than as text with one line highlighted. The selected one keeps the
            -- bright fill; the rest get a dim plate that still says "this is clickable". The number
            -- key sits as a dim cap on the right so the labels line up cleanly - inline "5  spline"
            -- ran scrambled, out-of-sequence digits down the middle of the list.
            local hovered = mx ~= nil and mx >= x and mx <= x + width and my >= y and my <= y + h
            if row.active then
                drawQuad(self.rowOverlay, x, y, width, h, 0.28, 0.52, 0.78, 0.95)
                label(textX, textY, fontSize, row.text, 0.96, 0.98, 1, 1)
            elseif hovered then
                drawQuad(self.rowOverlay, x, y, width, h, 0.22, 0.24, 0.28, 0.95)
                label(textX, textY, fontSize, row.text, 0.92, 0.94, 0.97, 1)
            else
                drawQuad(self.rowOverlay, x, y, width, h, 0.16, 0.17, 0.195, 0.92)
                label(textX, textY, fontSize, row.text, 0.78, 0.80, 0.83, 1)
            end
            if row.value ~= nil and row.value ~= "" then
                label(x + width - self.padding * 1.5, textY, fontSize * 0.78, row.value,
                    row.active and 0.86 or 0.48, row.active and 0.90 or 0.52, row.active and 0.98 or 0.58, 1,
                    RenderText.ALIGN_RIGHT)
            end
        elseif row.kind == "number" then
            if row.active then
                drawQuad(self.rowOverlay, x, y, width, h, 0.20, 0.28, 0.38, 0.95)
            end
            label(textX, textY, fontSize, row.text, 0.76, 0.78, 0.81, 1)
            label(x + width - self.padding * 2, textY, fontSize, row.value,
                row.active and 0.96 or 0.62, row.active and 0.98 or 0.72, row.active and 1 or 0.86, 1,
                RenderText.ALIGN_RIGHT)
        elseif row.kind == "toggle" then
            label(textX, textY, fontSize, row.text, 0.76, 0.78, 0.81, 1)
            label(x + width - self.padding * 2, textY, fontSize, row.value, 0.58, 0.74, 0.92, 1,
                RenderText.ALIGN_RIGHT)
        elseif row.kind == "action" then
            -- Dimmed when the action would currently do nothing, so the panel says what is
            -- available rather than only what exists.
            local bright = row.active
            label(textX, textY, fontSize, row.text,
                bright and 0.82 or 0.45, bright and 0.85 or 0.47, bright and 0.90 or 0.50, 1)
            label(x + width - self.padding * 2, textY, fontSize * 0.85, row.value,
                0.48, 0.50, 0.54, 1, RenderText.ALIGN_RIGHT)
        elseif row.kind == "cursor" then
            label(textX, textY, fontSize * 0.90, row.text, 0.55, 0.57, 0.60, 1)
            label(x + width - self.padding * 2, textY, fontSize * 0.90, row.value, 0.58, 0.74, 0.92, 1,
                RenderText.ALIGN_RIGHT)
        elseif row.kind == "status" then
            label(textX, textY, fontSize * 0.9, row.text, 0.60, 0.62, 0.66, 1)
        elseif row.kind == "hint" then
            label(textX, textY, fontSize * 0.92, row.text, 0.72, 0.80, 0.88, 1)
        end
    end

    self:drawContextMenu(editor)
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
    self:ensureOverlays()

    local uiScale = (g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1
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
        it("mnote", "scroll to adjust - right-click applies")
    end

    local ph = #items * rowH + pad * 2
    -- Offset right of the click so the clicked point stays uncovered - a second click on it makes a
    -- span, a rapid second click makes a run, and both need the point still reachable.
    local x = math.max(0, math.min(1 - pw, (m.sx or 0.5) + 0.006))
    local top = math.max(ph, math.min(1, m.sy or 0.5))
    local mx, my = editor.mouseX, editor.mouseY

    local edge = 0.0025
    drawQuad(self.borderOverlay, x - edge, top - ph - edge, pw + edge * 2, ph + edge * 2,
        0.34, 0.52, 0.72, 0.98)
    drawQuad(self.background, x, top - ph, pw, ph, 0.12, 0.13, 0.15, 0.99)

    local y = top - pad
    for _, item in ipairs(items) do
        y = y - rowH
        item.x, item.y, item.w, item.h = x, y, pw, rowH
        local textY = y + (rowH - fontSize) * 0.5
        local textX = x + pad * 2
        local rightX = x + pw - pad * 2
        local hovered = mx ~= nil and mx >= x and mx <= x + pw and my >= y and my <= y + rowH
        if item.kind == "mhead" then
            drawQuad(self.headerOverlay, x, y, pw, rowH, 0.20, 0.30, 0.42, 1)
            label(textX, textY, fontSize * 0.9, item.text, 0.72, 0.82, 0.95, 1)
        elseif item.kind == "mnote" then
            label(textX, textY, fontSize * 0.82, item.text, 0.5, 0.53, 0.57, 1)
        elseif item.kind == "mwheel" then
            -- Read-only: the mouse wheel drives this while the tool is armed (the note row says so).
            drawQuad(self.rowOverlay, x, y, pw, rowH, 0.15, 0.17, 0.20, 0.9)
            label(textX, textY, fontSize, item.text, 0.72, 0.75, 0.79, 1)
            label(rightX, textY, fontSize, item.value or "-", 0.60, 0.78, 0.98, 1, RenderText.ALIGN_RIGHT)
        elseif item.kind == "mtoggle" then
            drawQuad(self.rowOverlay, x, y, pw, rowH, hovered and 0.24 or 0.165,
                hovered and 0.30 or 0.18, hovered and 0.40 or 0.205, 0.95)
            label(textX, textY, fontSize, item.text, hovered and 0.94 or 0.78,
                hovered and 0.96 or 0.80, hovered and 1 or 0.84, 1)
            label(rightX, textY, fontSize, item.value or "-", 1, 0.85, 0.4, 1, RenderText.ALIGN_RIGHT)
        elseif item.kind == "mapply" then
            drawQuad(self.rowOverlay, x, y, pw, rowH, hovered and 0.32 or 0.24,
                hovered and 0.56 or 0.44, hovered and 0.82 or 0.66, 0.95)
            label(textX, textY, fontSize, item.text, 0.96, 0.98, 1, 1)
        elseif item.danger then
            drawQuad(self.rowOverlay, x, y, pw, rowH, hovered and 0.42 or 0.23,
                hovered and 0.17 or 0.155, hovered and 0.16 or 0.15, hovered and 0.95 or 0.9)
            label(textX, textY, fontSize, item.text, 0.94, 0.62, 0.56, 1)
        else
            drawQuad(self.rowOverlay, x, y, pw, rowH, hovered and 0.24 or 0.165,
                hovered and 0.30 or 0.175, hovered and 0.40 or 0.205, 0.95)
            label(textX, textY, fontSize, item.text, hovered and 0.96 or 0.82,
                hovered and 0.98 or 0.84, hovered and 1 or 0.88, 1)
        end
        -- So the shared onClick/isMouseOver see it as one more clickable row.
        table.insert(self.rows, item)
    end
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
function ADFlyoverHud:isMouseOver(mouseX, mouseY)
    for _, row in ipairs(self.rows) do
        if row.x ~= nil and mouseX >= row.x and mouseX <= row.x + row.w
            and mouseY >= row.y and mouseY <= row.y + row.h then
            return true, row
        end
    end
    return false, nil
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
