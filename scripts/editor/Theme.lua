--[[
ADFlyoverTheme - the editor panel's colours and scale.

Every colour the HUD draws is a named ROLE resolved from three layers:
  1. a PRESET  - the neutral colours (backgrounds, borders, text greys)
  2. an ACCENT - the highlight family (active tool, value text, card border), derived from one colour
  3. per-role OVERRIDES - explicit values that win over both, for fine tuning

rgb(role) returns three 0..1 floats for setColor. The resolved map is cached and only rebuilt when
something changes (dirty()). Selection persists to theme.xml beside settings.xml.

Defaults: Contrast Dark preset + amber accent + 1.0x scale - chosen for legibility over the game
world, deliberately away from the old low-contrast grey-on-grey-with-blue.
]]

ADFlyoverTheme = {}
local T = ADFlyoverTheme

T.MOD_NAME = "ADFlyoverEditor"
T.FOLDER = "modSettings/FS25_ADFlyoverEditor/"
T.FILE = "theme.xml"

T.SCALE_MIN, T.SCALE_MAX, T.SCALE_STEP, T.SCALE_DEFAULT = 0.7, 2.0, 0.05, 1.0

-- #rrggbb (or #rgb) -> { r, g, b } in 0..1
local function hexToRgb(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("#", "")
    if #hex == 3 then
        hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
    end
    if #hex ~= 6 then return nil end
    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)
    if r == nil or g == nil or b == nil then return nil end
    return { r / 255, g / 255, b / 255 }
end

local function rgbToHex(c)
    local function ch(v) return string.format("%02x", math.max(0, math.min(255, math.floor(v * 255 + 0.5)))) end
    return "#" .. ch(c[1]) .. ch(c[2]) .. ch(c[3])
end

-- Blend two 0..1 rgb triples, t of the way from a to b.
local function mix(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

-- FS25's Overlay:setColor takes LINEAR light, but our palette (and the theme lab) is authored in
-- sRGB, the way a colour picker or CSS hex is. Passing sRGB straight through makes the display's
-- gamma curve lift every value - a near-black 0.05 renders as a ~0.28 grey - which is exactly why
-- the dark themes came out washed grey. Convert to linear here so what shows matches what was picked.
local function srgbToLinear(v)
    if v <= 0.04045 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
end
local function toLinear(c)
    return { srgbToLinear(c[1]), srgbToLinear(c[2]), srgbToLinear(c[3]) }
end

-- WCAG relative luminance, for choosing black vs white text on an accent.
local function luminance(c)
    local function lin(v) if v <= 0.03928 then return v / 12.92 else return ((v + 0.055) / 1.055) ^ 2.4 end end
    return 0.2126 * lin(c[1]) + 0.7152 * lin(c[2]) + 0.0722 * lin(c[3])
end
local BLACK_TEXT = { 0.04, 0.05, 0.07 }
local WHITE_TEXT = { 1, 1, 1 }
local function textOn(bg)
    local l = luminance(bg)
    -- contrast of white vs bg rises as bg darkens; pick whichever is higher.
    local cWhite = 1.05 / (l + 0.05)
    local cBlack = (l + 0.05) / 0.05
    return cBlack >= cWhite and BLACK_TEXT or WHITE_TEXT
end

-- The neutral roles every preset defines. Overrides are validated against this plus the derived set.
T.NEUTRAL_ROLES = {
    "panelBg", "panelBorder", "cardBg", "headerBg", "headerText", "sectionText",
    "bodyText", "mutedText", "toolBg", "toolBorder", "hoverBg", "danger",
    "stepperBg", "stepperText",
}
T.DERIVED_ROLES = {
    "accent", "accentBorder", "accentText", "cardBorder", "valueText",
    "hoverBorder", "stepperBorder", "editBg", "hintText",
}

-- The roles the in-editor advanced colour editor lets you override, in the order it cycles them.
-- A curated set - the ones worth hand-tuning - each with a short label for the panel.
T.EDITABLE_ROLES = {
    { "panelBg", "panel bg" }, { "cardBg", "card bg" }, { "headerBg", "header bg" },
    { "panelBorder", "panel border" }, { "cardBorder", "card border" },
    { "bodyText", "body text" }, { "valueText", "value text" }, { "mutedText", "muted text" },
    { "sectionText", "section text" }, { "headerText", "header text" }, { "accentText", "accent text" },
    { "hoverBg", "hover" }, { "danger", "danger" }, { "toolBg", "tool bg" }, { "stepperBg", "stepper bg" },
}

T.PRESET_ORDER = { "contrastDark", "amber", "cyan", "green", "slateBlue", "hcLight", "classic" }
T.PRESET_NAMES = {
    contrastDark = "Contrast Dark", amber = "Amber", cyan = "Cyan", green = "Green",
    slateBlue = "Slate + Blue", hcLight = "HC Light", classic = "Classic",
}

T.presets = {
    contrastDark = { panelBg = "#0c0f14", panelBorder = "#2b313d", cardBg = "#10141b", headerBg = "#1a2130",
        headerText = "#dfe7f2", sectionText = "#8894a6", bodyText = "#e8ecf2", mutedText = "#7c8494",
        toolBg = "#161b24", toolBorder = "#2b313d", hoverBg = "#222b39", danger = "#ff6b6b",
        stepperBg = "#232b38", stepperText = "#cbd4e0" },
    amber = { panelBg = "#0d0c0a", panelBorder = "#383124", cardBg = "#12100c", headerBg = "#241d10",
        headerText = "#f0e7d5", sectionText = "#b39a6a", bodyText = "#efe7d6", mutedText = "#8f8064",
        toolBg = "#191510", toolBorder = "#3a3222", hoverBg = "#2c2415", danger = "#ff7a5c",
        stepperBg = "#2a2416", stepperText = "#e2d4b6" },
    cyan = { panelBg = "#0a0f12", panelBorder = "#213038", cardBg = "#0d141a", headerBg = "#132630",
        headerText = "#d7ecf2", sectionText = "#6f9fb0", bodyText = "#e2eef2", mutedText = "#728a94",
        toolBg = "#111b22", toolBorder = "#213038", hoverBg = "#193440", danger = "#ff6b6b",
        stepperBg = "#1a2b33", stepperText = "#c4dbe2" },
    green = { panelBg = "#080f0b", panelBorder = "#1f3327", cardBg = "#0b1410", headerBg = "#0f2718",
        headerText = "#d6f2e0", sectionText = "#6fae86", bodyText = "#e0f2e7", mutedText = "#6f8a79",
        toolBg = "#0f1c15", toolBorder = "#1f3327", hoverBg = "#173a28", danger = "#ff6b6b",
        stepperBg = "#152b1f", stepperText = "#c3e2cf" },
    slateBlue = { panelBg = "#141a24", panelBorder = "#2c3646", cardBg = "#1a2130", headerBg = "#222c3e",
        headerText = "#e7edf6", sectionText = "#8a97ac", bodyText = "#e8edf5", mutedText = "#84909f",
        toolBg = "#1d2634", toolBorder = "#2c3646", hoverBg = "#28374d", danger = "#ff7373",
        stepperBg = "#28303f", stepperText = "#ccd6e4" },
    hcLight = { panelBg = "#eef1f5", panelBorder = "#c3cad5", cardBg = "#ffffff", headerBg = "#dde4ee",
        headerText = "#161c26", sectionText = "#4a5568", bodyText = "#131820", mutedText = "#586274",
        toolBg = "#f6f8fb", toolBorder = "#cdd5e0", hoverBg = "#e3e9f2", danger = "#c0392b",
        stepperBg = "#e8edf4", stepperText = "#2a3341" },
    classic = { panelBg = "#1b1d22", panelBorder = "#474f5a", cardBg = "#1f2126", headerBg = "#292a33",
        headerText = "#e6e8ec", sectionText = "#858f9e", bodyText = "#d1d4d9", mutedText = "#808387",
        toolBg = "#282a30", toolBorder = "#4c525e", hoverBg = "#3b4450", danger = "#ee9e8f",
        stepperBg = "#313842", stepperText = "#c7d0dc" },
}

T.ACCENT_ORDER = { "amber", "blue", "cyan", "green", "red", "purple", "white" }
T.ACCENTS = {
    amber = "#f5a524", blue = "#3b82f6", cyan = "#22d3ee", green = "#3ddc84",
    red = "#ff5d5d", purple = "#a679ff", white = "#f2f4f8",
}

-- current selection (defaults)
T.preset = "contrastDark"
T.accent = T.ACCENTS.amber
T.scale = T.SCALE_DEFAULT
T.overrides = {}     -- role -> { r, g, b }
T.resolved = nil     -- role -> { r, g, b } (cache)

function T:dirty() self.resolved = nil; self.resolvedSrgb = nil end

--- Rebuild the resolved role map from preset + accent + overrides.
function T:resolve()
    local preset = self.presets[self.preset] or self.presets.contrastDark
    local r = {}
    for role, hex in pairs(preset) do
        r[role] = hexToRgb(hex) or { 1, 0, 1 }
    end

    local accent = hexToRgb(self.accent) or hexToRgb("#f5a524")
    r.accent = accent
    r.accentBorder = mix(accent, WHITE_TEXT, 0.25)
    r.accentText = textOn(accent)
    r.cardBorder = mix(accent, r.panelBg, 0.34)
    r.valueText = mix(accent, r.bodyText, 0.35)
    r.hoverBorder = mix(r.hoverBg, WHITE_TEXT, 0.18)
    r.stepperBorder = mix(r.stepperBg, WHITE_TEXT, 0.14)
    r.editBg = mix(accent, r.panelBg, 0.72)
    r.hintText = mix(accent, r.bodyText, 0.45)

    for role, rgb in pairs(self.overrides) do
        r[role] = rgb
    end

    -- Everything above is sRGB, where mixing and the contrast maths belong. Keep that map for the
    -- colour editor (which works in sRGB / 0-255), then convert a copy to linear for setColor, which
    -- is what FS25's overlays actually take.
    self.resolvedSrgb = r
    local lin = {}
    for role, c in pairs(r) do lin[role] = toLinear(c) end
    self.resolved = lin
end

--- Three 0..1 floats for the role, resolving on demand. Magenta if a role name is unknown, so a
--- typo shows up loudly on screen rather than drawing invisibly.
function T:rgb(role)
    if self.resolved == nil then self:resolve() end
    local c = self.resolved[role] or { 1, 0, 1 }
    return c[1], c[2], c[3]
end

--- { r, g, b } for the role - handy where a caller wants to pass the colour around as one value.
function T:arr(role)
    local r, g, b = self:rgb(role)
    return { r, g, b }
end

--- The role's colour in sRGB (0..1), the space the colour editor and hex work in - as opposed to
--- rgb(), which returns the linear value setColor wants.
function T:srgb(role)
    if self.resolvedSrgb == nil then self:resolve() end
    local c = self.resolvedSrgb[role] or { 1, 0, 1 }
    return c[1], c[2], c[3]
end

--- "#rrggbb" for the role, from its sRGB value.
function T:hexOf(role)
    local r, g, b = self:srgb(role)
    return rgbToHex({ r, g, b })
end

-- ---------------------------------------------------------------------------------------------
-- Mutators (each persists)
-- ---------------------------------------------------------------------------------------------

function T:setPreset(id)
    if self.presets[id] == nil then return end
    self.preset = id
    self:dirty()
    self:save()
end

function T:setAccent(hex)
    if hexToRgb(hex) == nil then return end
    self.accent = hex
    self:dirty()
    self:save()
end

local function cycle(order, currentIndexValue, dir)
    local n = #order
    local idx = 1
    for i, v in ipairs(order) do
        if v == currentIndexValue then idx = i break end
    end
    return order[((idx - 1 + dir) % n) + 1]
end

function T:cyclePreset(dir)
    self:setPreset(cycle(self.PRESET_ORDER, self.preset, dir >= 0 and 1 or -1))
end

function T:cycleAccent(dir)
    -- current accent name (fall back to the first if it is a custom hex)
    local name = self.ACCENT_ORDER[1]
    for _, n in ipairs(self.ACCENT_ORDER) do
        if self.ACCENTS[n]:lower() == tostring(self.accent):lower() then name = n break end
    end
    local nextName = cycle(self.ACCENT_ORDER, name, dir >= 0 and 1 or -1)
    self:setAccent(self.ACCENTS[nextName])
end

function T:accentName()
    for _, n in ipairs(self.ACCENT_ORDER) do
        if self.ACCENTS[n]:lower() == tostring(self.accent):lower() then return n end
    end
    return "custom"
end

--- Clamp to the allowed band and snap to the step, then store. Returns the applied value.
function T:setScale(v)
    v = tonumber(v)
    if v == nil then return self.scale end
    v = math.max(self.SCALE_MIN, math.min(self.SCALE_MAX, v))
    v = math.floor(v / self.SCALE_STEP + 0.5) * self.SCALE_STEP
    self.scale = v
    self:save()
    return self.scale
end

function T:setOverride(role, r, g, b)
    self.overrides[role] = { r, g, b }
    self:dirty()
    self:save()
end

function T:clearOverride(role)
    self.overrides[role] = nil
    self:dirty()
    self:save()
end

function T:clearOverrides()
    self.overrides = {}
    self:dirty()
    self:save()
end

function T:resetDefault()
    self.preset = "contrastDark"
    self.accent = self.ACCENTS.amber
    self.scale = self.SCALE_DEFAULT
    self.overrides = {}
    self:dirty()
    self:save()
end

-- ---------------------------------------------------------------------------------------------
-- Persistence - theme.xml beside settings.xml. Its own file rather than sharing Settings' so the
-- two never fight over the same handle.
-- ---------------------------------------------------------------------------------------------

local function themePath()
    if getUserProfileAppPath == nil then return nil end
    return getUserProfileAppPath() .. T.FOLDER .. T.FILE
end

local function isKnownRole(role)
    for _, r in ipairs(T.NEUTRAL_ROLES) do if r == role then return true end end
    for _, r in ipairs(T.DERIVED_ROLES) do if r == role then return true end end
    return false
end

function T.save()
    local path = themePath()
    if path == nil then return false end
    local ok, err = pcall(function()
        createFolder(getUserProfileAppPath() .. "modSettings/")
        createFolder(getUserProfileAppPath() .. T.FOLDER)
        local xml = createXMLFile("ADFlyoverTheme", path, "flyoverTheme")
        setXMLString(xml, "flyoverTheme#preset", T.preset)
        setXMLString(xml, "flyoverTheme#accent", T.accent)
        setXMLFloat(xml, "flyoverTheme#scale", T.scale)
        local i = 0
        for role, rgb in pairs(T.overrides) do
            setXMLString(xml, string.format("flyoverTheme.override(%d)#role", i), role)
            setXMLString(xml, string.format("flyoverTheme.override(%d)#hex", i), rgbToHex(rgb))
            i = i + 1
        end
        saveXMLFile(xml)
        delete(xml)
    end)
    if not ok then
        Logging.warning("[%s] could not save theme: %s", T.MOD_NAME, tostring(err))
        return false
    end
    return true
end

function T.load()
    local path = themePath()
    if path == nil or not fileExists(path) then return false end
    local ok, err = pcall(function()
        local xml = loadXMLFile("ADFlyoverTheme", path)

        local preset = getXMLString(xml, "flyoverTheme#preset")
        if preset ~= nil and T.presets[preset] ~= nil then T.preset = preset end

        local accent = getXMLString(xml, "flyoverTheme#accent")
        if accent ~= nil and hexToRgb(accent) ~= nil then T.accent = accent end

        -- Set directly, not via setScale(): setScale() persists, and saving here (before the
        -- overrides below are read) would write the file back with no overrides and lose them.
        local scale = getXMLFloat(xml, "flyoverTheme#scale")
        if scale ~= nil then
            scale = math.max(T.SCALE_MIN, math.min(T.SCALE_MAX, scale))
            T.scale = math.floor(scale / T.SCALE_STEP + 0.5) * T.SCALE_STEP
        end

        T.overrides = {}
        local i = 0
        while true do
            local role = getXMLString(xml, string.format("flyoverTheme.override(%d)#role", i))
            if role == nil then break end
            local hex = getXMLString(xml, string.format("flyoverTheme.override(%d)#hex", i))
            local rgb = hexToRgb(hex)
            -- Ignore unknown roles or malformed colours rather than trusting the file.
            if rgb ~= nil and isKnownRole(role) then
                T.overrides[role] = rgb
            end
            i = i + 1
        end

        delete(xml)
    end)
    T:dirty()
    if not ok then
        Logging.warning("[%s] could not load theme: %s", T.MOD_NAME, tostring(err))
        return false
    end
    return true
end
