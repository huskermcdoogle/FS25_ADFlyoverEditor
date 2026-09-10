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
    width = 0.215,
    rowHeight = 0.023,
    padding = 0.006,

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

    add("header", "AUTODRIVE FLYOVER EDITOR")
    add("note", "Standard AD editing is suspended")
    -- What the cursor is over. Field numbers are how fields are referred to when working on them,
    -- and in flyover mode there is no vehicle sitting in one to tell you which is which.
    add("cursor", "under cursor", editor.fieldLabel or "-")
    add("gap")

    add("section", editor.tool == editor.TOOL.NONE and "TOOL - none selected" or "TOOL")
    for i = 1, #editor.TOOL_NAMES do
        -- COMPANION EDIT: TOOL_NAMES has 11 entries but the key binding is
        -- (tool == 10) and "KEY_0" or ("KEY_" .. tool), so tool 11 has no key at all. Printing
        -- i % 10 labelled it "1", duplicating tool 1 and advertising a key that does something else.
        local toolKey = (i <= 10) and tostring(i % 10) or " "
        add("tool", string.format("%s  %s", toolKey, editor.TOOL_NAMES[i]), nil, editor.tool == i,
            function() editor:setTool(i) end)
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

    return rows
end

function ADFlyoverHud:draw(editor)
    self:ensureOverlays()

    local rows = self:buildRows(editor)
    self.rows = rows

    local uiScale = (g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1
    local rowH = self.rowHeight * uiScale
    local fontSize = 0.0115 * uiScale

    -- Spacers are separators, not rows, so they get a fraction of the height. With eight tools
    -- plus sections the panel is tall enough that full-height gaps cost real screen space.
    local function heightOf(row)
        return row.kind == "gap" and rowH * 0.35 or rowH
    end

    local totalHeight = self.padding * 2
    for _, row in ipairs(rows) do
        totalHeight = totalHeight + heightOf(row)
    end

    local x = self.posX
    local width = self.width * uiScale
    -- Anchored at the TOP and grown downward. Growing upward from a fixed bottom edge meant every
    -- row was measured from a top that moved whenever the panel's height changed - so selecting a
    -- tool with more controls than the last one shifted the header and the whole button list under
    -- the cursor. The rows that must not move are all at the top, so the top is what gets pinned;
    -- the panel now lengthens into empty space below instead of shoving itself up the screen.
    local top = self.topY
    local bottom = top - totalHeight

    self.frameX, self.frameY, self.frameW, self.frameH = x, bottom, width, totalHeight

    -- Near-opaque. At 0.72 the world showed straight through the text, which made the panel hard
    -- to read over bright terrain - the one thing it exists to avoid. A thin lighter border sits
    -- behind it so the panel has a defined edge against any background.
    local edge = 0.0025
    drawQuad(self.borderOverlay, x - edge, bottom - edge, width + edge * 2, totalHeight + edge * 2,
        0.55, 0.55, 0.55, 0.9)
    drawQuad(self.background, x, bottom, width, totalHeight, 0.04, 0.04, 0.05, 0.96)

    local y = top - self.padding
    for _, row in ipairs(rows) do
        local h = heightOf(row)
        y = y - h
        row.x, row.y, row.w, row.h = x, y, width, h
        local textY = y + (h - fontSize) * 0.5
        local textX = x + self.padding * 2

        if row.kind == "header" then
            drawQuad(self.headerOverlay, x, y, width, h, 0.9, 0.62, 0, 0.95)
            label(textX, textY, fontSize, row.text, 0, 0, 0, 1)
        elseif row.kind == "note" then
            label(textX, textY, fontSize * 0.92, row.text, 1, 0.75, 0.2, 1)
        elseif row.kind == "section" then
            label(textX, textY, fontSize * 0.86, row.text, 0.55, 0.75, 1, 1)
        elseif row.kind == "tool" then
            -- Every tool gets a plate, not just the selected one, so the list reads as a row of
            -- buttons rather than as text with one line highlighted. The selected one keeps the
            -- bright fill; the rest get a dim plate that still says "this is clickable".
            if row.active then
                drawQuad(self.rowOverlay, x, y, width, h, 0.15, 0.55, 0.95, 0.85)
                label(textX, textY, fontSize, row.text, 1, 1, 1, 1)
            else
                drawQuad(self.rowOverlay, x, y, width, h, 0.20, 0.21, 0.24, 0.55)
                label(textX, textY, fontSize, row.text, 0.82, 0.82, 0.82, 1)
            end
        elseif row.kind == "number" then
            if row.active then
                drawQuad(self.rowOverlay, x, y, width, h, 0.35, 0.28, 0.05, 0.95)
            end
            label(textX, textY, fontSize, row.text, 0.78, 0.78, 0.78, 1)
            label(x + width - self.padding * 2, textY, fontSize, row.value,
                row.active and 1 or 1, row.active and 1 or 0.85, row.active and 1 or 0.3, 1,
                RenderText.ALIGN_RIGHT)
        elseif row.kind == "toggle" then
            label(textX, textY, fontSize, row.text, 0.78, 0.78, 0.78, 1)
            label(x + width - self.padding * 2, textY, fontSize, row.value, 1, 0.85, 0.3, 1,
                RenderText.ALIGN_RIGHT)
        elseif row.kind == "action" then
            -- Dimmed when the action would currently do nothing, so the panel says what is
            -- available rather than only what exists.
            local bright = row.active
            label(textX, textY, fontSize, row.text,
                bright and 1 or 0.55, bright and 0.95 or 0.55, bright and 0.7 or 0.55, 1)
            label(x + width - self.padding * 2, textY, fontSize * 0.85, row.value,
                0.5, 0.5, 0.5, 1, RenderText.ALIGN_RIGHT)
        elseif row.kind == "cursor" then
            label(textX, textY, fontSize * 0.92, row.text, 0.6, 0.6, 0.6, 1)
            label(x + width - self.padding * 2, textY, fontSize * 0.92, row.value, 0.6, 1, 0.9, 1,
                RenderText.ALIGN_RIGHT)
        elseif row.kind == "status" then
            label(textX, textY, fontSize * 0.9, row.text, 0.65, 0.65, 0.65, 1)
        elseif row.kind == "hint" then
            label(textX, textY, fontSize * 0.92, row.text, 0.6, 1, 0.6, 1)
        end
    end
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
