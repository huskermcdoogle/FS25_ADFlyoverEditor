-- Part of the flyover editor, moved out of FlyoverEditor.lua (docs/editor-modules-spec.md). Prelude.lua
-- loads it after FlyoverEditor.lua, in the old file's order.
-- MODSPLIT: HELPERS FROM THE FILES LOADED BEFORE THIS ONE (tools/modsplit/split.py writes this block)
for _, name in ipairs({ "heightAlongChain" }) do
    if ADFlyoverEditor.shared == nil or ADFlyoverEditor.shared[name] == nil then
        Logging.error("[FlyoverEditor]: Appearance.lua needs %s, which no file loaded before it shares", name)
    end
end
local heightAlongChain = ADFlyoverEditor.shared.heightAlongChain
-- MODSPLIT: end of the helpers

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
