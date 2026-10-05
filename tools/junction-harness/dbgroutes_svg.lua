-- Draw the routes a junction's type is read from, over the network around it. North up.
--   RIG_TRAILER=11 lua dbgroutes_svg.lua CX CZ out.svg [halfSpan]
local H = dofile("harness.lua")
local CX, CZ, OUT, R = tonumber(arg[1]), tonumber(arg[2]), arg[3], tonumber(arg[4]) or 75
local jp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = false })
local c = (jp and (jp._boxCentre or jp.boxCentre or jp.tracksCentre)) or { x = CX, z = CZ }
-- VIEW="x,z": centre the picture there instead (e.g. between two halves of a compound junction)
if os.getenv("VIEW") then
    local vx, vz = os.getenv("VIEW"):match("(%-?[%d.]+),(%-?[%d.]+)")
    if vx then c = { x = tonumber(vx), z = tonumber(vz) } end
end
local kind = jp and ADFlyoverEditor.junctionClassify(ADFlyoverEditor, jp) or "no reading - the tool found no junction here"
local S, PAD = 900, 20
local function px(x) return PAD + (x - (c.x - R)) / (2 * R) * S end
local function py(z) return PAD + (z - (c.z - R)) / (2 * R) * S end   -- FS25 z grows south: north up
local o = {}
local function add(s) o[#o + 1] = s end
add(string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">', S + 2 * PAD, S + 2 * PAD + 150, S + 2 * PAD, S + 2 * PAD + 150))
add('<style>text{font-family:ui-sans-serif,system-ui,sans-serif;font-size:14px}</style>')
add('<rect width="100%" height="100%" fill="#fbfbfa"/>')
for g = -R, R, 10 do
    add(string.format('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="#eee"/>', px(c.x + g), PAD, px(c.x + g), PAD + S))
    add(string.format('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="#eee"/>', PAD, py(c.z + g), PAD + S, py(c.z + g)))
end
-- The map's own roads (FlyoverRoadSplines), drawn first so everything else sits on top: wide
-- pale orange bands, one per traffic spline. SPLINES=<path to ADFlyoverEditor_roadSplines.xml>.
local nSpl, splLoaded = 0, false
if os.getenv("SPLINES") then
    local f = io.open(os.getenv("SPLINES"), "r")
    if f then
        splLoaded = true
        local txt = f:read("*a")
        f:close()
        for pts in txt:gmatch('points="([^"]*)"') do
            local seg, near = {}, false
            for x, z in pts:gmatch("(%-?[%d.]+),(%-?[%d.]+)") do
                x, z = tonumber(x), tonumber(z)
                seg[#seg + 1] = string.format("%.1f,%.1f", px(x), py(z))
                if math.abs(x - c.x) < R * 1.4 and math.abs(z - c.z) < R * 1.4 then near = true end
            end
            if near then
                nSpl = nSpl + 1
                add(string.format('<polyline points="%s" fill="none" stroke="#f6b26b" stroke-width="9" stroke-opacity="0.45" stroke-linecap="round" stroke-linejoin="round"/>', table.concat(seg, " ")))
            end
        end
    end
end
-- Network: main network grey, loose pieces dashed blue.
local main, done = {}, {}
do
    local best, bn = nil, -1
    for _, w in pairs(ADGraphManager:getWayPoints()) do
        if not done[w] and (w.x - c.x) ^ 2 + (w.z - c.z) ^ 2 <= (R * 1.4) ^ 2 then
            local piece, st = {}, { w }
            done[w] = true
            while #st > 0 do
                local a = table.remove(st)
                piece[#piece + 1] = a
                for _, l in ipairs({ a.out or {}, a.incoming or {} }) do
                    for _, id in pairs(l) do
                        local t = ADGraphManager:getWayPointById(id)
                        if t and not done[t] then done[t] = true st[#st + 1] = t end
                    end
                end
            end
            if #piece > bn then best, bn = piece, #piece end
        end
    end
    for _, w in ipairs(best or {}) do main[w] = true end
end
for _, w in pairs(ADGraphManager:getWayPoints()) do
    if (w.x - c.x) ^ 2 + (w.z - c.z) ^ 2 <= (R * 1.4) ^ 2 then
        for _, id in pairs(w.out or {}) do
            local t = ADGraphManager:getWayPointById(id)
            if t then
                add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%s"%s/>',
                    px(w.x), py(w.z), px(t.x), py(t.z), main[w] and "#bbb" or "#1a73e8", main[w] and "1.2" or "2",
                    main[w] and "" or ' stroke-dasharray="6 4"'))
            end
        end
    end
end
local function route(nodes, col, label, w)
    local pts = {}
    for _, n in ipairs(nodes) do pts[#pts + 1] = string.format("%.1f,%.1f", px(n.x), py(n.z)) end
    add(string.format('<polyline points="%s" fill="none" stroke="%s" stroke-width="%d" stroke-opacity="0.75" stroke-linejoin="round"/>', table.concat(pts, " "), col, w))
    local far, fd = nodes[1], -1
    for _, n in ipairs(nodes) do
        local d = (n.x - c.x) ^ 2 + (n.z - c.z) ^ 2
        if d > fd then fd, far = d, n end
    end
    local lx, ly = px(far.x), py(far.z)
    lx = math.max(PAD + 30, math.min(PAD + S - 30, lx)); ly = math.max(PAD + 18, math.min(PAD + S - 8, ly))
    add(string.format('<text x="%.1f" y="%.1f" font-weight="700" fill="%s" stroke="#fff" stroke-width="4" paint-order="stroke" text-anchor="middle">%s</text>', lx, ly, col, label))
end
local r = (jp and jp.pathRoutes) or {}
local SIDECOL = { "#e8710a", "#9334e6", "#188038", "#c5221f" }
for i, t in ipairs(r.through or {}) do route(t, "#202124", "T" .. i, 7) end
for i, sl in ipairs(r.side or {}) do route(sl.nodes, SIDECOL[(i - 1) % #SIDECOL + 1], "S" .. i, 5) end
-- THE BRANCH ANGLE, drawn where the label reads it: the main-road arm it is measured from, the
-- side road's direction, the angle between them, and guide rays at 38 and 62 degrees (the Y merge /
-- T skew / T square lines) on the side road's side of the main arm.
local br = jp and jp._branch
if br ~= nil and br.meet ~= nil then
    -- measured where the side road meets the main road (see junctionClassify's sGeo)
    local g = br.meet
    local function line(bdeg, len, col, width, dash, op, both)
        local r = math.rad(bdeg)
        local dx, dz = math.sin(r) * len, math.cos(r) * len
        local x1, z1 = both and (g.x - dx) or g.x, both and (g.z - dz) or g.z
        add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%s"%s stroke-opacity="%s" stroke-linecap="round"/>',
            px(x1), py(z1), px(g.x + dx), py(g.z + dz), col, width, dash and (' stroke-dasharray="' .. dash .. '"') or "", op or 1))
        return g.x + dx, g.z + dz
    end
    -- the main-road leg the side road leans towards: the angle is always the sharper one
    local d0 = (g.side - g.main + 540) % 360 - 180
    local legDir = (math.abs(d0) <= 90) and g.main or ((g.main + 180) % 360)
    local d = (g.side - legDir + 540) % 360 - 180
    local sgn = (d >= 0) and 1 or -1
    local L = R * 0.6
    -- A CORNER T's kind is not read from this angle (the main road turns right here, so its line is
    -- a chord across the corner): the angle is drawn grey, and the corner's own reading below.
    local corner = br.corner
    local arcCol = corner and "#9aa0a6" or "#d93025"
    for _, gd in ipairs({ 38, 62 }) do
        local gx, gz = line(legDir + sgn * gd, L * 0.9, "#1a73e8", 2, "5 5", corner and 0.35 or 0.8)
        add(string.format('<text x="%.1f" y="%.1f" font-size="13" fill="#1a73e8" fill-opacity="%s" stroke="#fff" stroke-width="3" paint-order="stroke">%d°</text>', px(gx) + 4, py(gz) - 4, corner and "0.5" or "1", gd))
    end
    -- THE MAIN ROAD IS READ OVER 8 m EITHER WAY along each lane beside the red dot (MAIN_HALF in
    -- junctionClassify): each lane's stretch is the wide grey band (its two ends ticked), and the
    -- road's line is solid over those 8 m and faint beyond, so on a bend it is plain which part of
    -- the road it was read from (drawn 18 m each way, it ran off the road at 46, 50 and 63).
    for _, w in ipairs(g.windows or {}) do
        add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#202124" stroke-width="9" stroke-opacity="0.22" stroke-linecap="butt"/>',
            px(w.ax), py(w.az), px(w.bx), py(w.bz)))
        for _, e in ipairs({ { w.ax, w.az }, { w.bx, w.bz } }) do
            add(string.format('<circle cx="%.1f" cy="%.1f" r="3.5" fill="#202124"/>', px(e[1]), py(e[2])))
        end
    end
    line(g.main, L, "#202124", 2, "4 6", 0.45, true)
    line(g.main, 8, "#202124", 4, nil, 1, true)
    line(g.side, L, "#e8710a", 4, "10 6")
    -- each lane read from its own start (roadReading gives each lane's stretch): the lanes are the
    -- wide bands and the middle line between them a thin dark line, ends dotted
    local ownStarts = g.starts ~= nil and g.starts[1] ~= nil and g.starts[1].toX ~= nil
    if ownStarts then
        for _, s in ipairs(g.starts) do
            add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#e8710a" stroke-width="12" stroke-opacity="0.35" stroke-linecap="round"/>',
                px(s.x), py(s.z), px(s.toX), py(s.toZ)))
        end
        if #g.starts == 2 then
            add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#8a3b00" stroke-width="3.5" stroke-linecap="round"/>',
                px(g.fromX), py(g.fromZ), px(g.toX), py(g.toZ)))
            for _, e in ipairs({ { g.fromX, g.fromZ }, { g.toX, g.toZ } }) do
                add(string.format('<circle cx="%.1f" cy="%.1f" r="4" fill="#8a3b00"/>', px(e[1]), py(e[2])))
            end
        end
    elseif g.fromX ~= nil then
        -- the stretch of side road the direction was read along (on a two-lane side road, its middle
        -- line between the two lanes)
        add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#e8710a" stroke-width="12" stroke-opacity="0.35" stroke-linecap="round"/>',
            px(g.fromX), py(g.fromZ), px(g.toX), py(g.toZ)))
    end
    if g.across ~= nil then
        -- the two cross-sections the middle line runs between: the point on each lane the same
        -- distance out along the road, where the side road starts and SIDE_LEN metres on
        for k = 1, 3, 2 do
            local p, q = g.across[k], g.across[k + 1]
            add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#e8710a" stroke-width="2.5"/>',
                px(p.x), py(p.z), px(q.x), py(q.z)))
            for _, e in ipairs({ p, q }) do
                add(string.format('<circle cx="%.1f" cy="%.1f" r="3" fill="#e8710a"/>', px(e.x), py(e.z)))
            end
        end
    end
    if g.starts == nil then
        -- read lane by lane (no roadReading): every lane's own 6 m and its own meeting point, since the
        -- angle is their average (the wide band and the dot are the lane nearest the centre)
        for _, sr in pairs(jp._sideRead or {}) do
            local m = sr.meet
            if m ~= nil and m ~= g and m.fromX ~= nil and (m.x - c.x) ^ 2 + (m.z - c.z) ^ 2 <= 20 * 20 then
                add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#e8710a" stroke-width="12" stroke-opacity="0.35" stroke-linecap="round"/>',
                    px(m.fromX), py(m.fromZ), px(m.toX), py(m.toZ)))
                add(string.format('<circle cx="%.1f" cy="%.1f" r="5" fill="none" stroke="#d93025" stroke-width="2"/>', px(m.x), py(m.z)))
            end
        end
    end
    for _, s in ipairs(g.starts or {}) do
        -- where the side road proper starts on each lane read (past its turn connectors)
        add(string.format('<circle cx="%.1f" cy="%.1f" r="7" fill="none" stroke="#e8710a" stroke-width="2.5"/>', px(s.x), py(s.z)))
        add(string.format('<text x="%.1f" y="%.1f" font-size="12" fill="#e8710a" stroke="#fff" stroke-width="3" paint-order="stroke">%s start</text>',
            px(s.x) + 9, py(s.z) + 4, s.flow or ""))
    end
    local pts, rr = {}, L * 0.35
    for k = 0, 24 do
        local b = math.rad(legDir + d * k / 24)
        pts[#pts + 1] = string.format("%.1f,%.1f", px(g.x + math.sin(b) * rr), py(g.z + math.cos(b) * rr))
    end
    add(string.format('<polyline points="%s" fill="none" stroke="%s" stroke-width="3"/>', table.concat(pts, " "), arcCol))
    add(string.format('<circle cx="%.1f" cy="%.1f" r="5" fill="%s"/>', px(g.x), py(g.z), arcCol))
    local mb = math.rad(legDir + d / 2)
    add(string.format('<text x="%.1f" y="%.1f" font-size="22" font-weight="700" fill="%s" stroke="#fff" stroke-width="4" paint-order="stroke" text-anchor="middle">%.0f°%s</text>',
        px(g.x + math.sin(mb) * rr * 1.8), py(g.z + math.cos(mb) * rr * 1.8) + 7, arcCol, br.angle, corner and " (not used)" or ""))
    if corner ~= nil then
        -- what a corner T is read from: the main road's two legs (the way each leaves, 12 m out from
        -- the centre) and the side road's own direction where it leaves, all from the centre
        local cc = jp._branchCentre or c
        local function ray(bdeg, len, col, width, dash)
            local r = math.rad(bdeg)
            local x2, z2 = cc.x + math.sin(r) * len, cc.z + math.cos(r) * len
            add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%s"%s stroke-linecap="round"/>',
                px(cc.x), py(cc.z), px(x2), py(z2), col, width, dash and (' stroke-dasharray="' .. dash .. '"') or ""))
            return x2, z2
        end
        for _, leg in ipairs(corner.legs) do
            local lx, lz = ray(leg, R * 0.45, "#5f6368", 5)
            add(string.format('<text x="%.1f" y="%.1f" font-size="13" font-weight="700" fill="#5f6368" stroke="#fff" stroke-width="3" paint-order="stroke">main leg</text>', px(lx) + 6, py(lz) + 4))
        end
        local sx2, sz2 = ray(corner.side, R * 0.45, "#e8710a", 5, "2 5")
        add(string.format('<text x="%.1f" y="%.1f" font-size="13" font-weight="700" fill="#e8710a" stroke="#fff" stroke-width="3" paint-order="stroke">side road</text>', px(sx2) + 6, py(sz2) + 4))
    end
elseif br ~= nil then
    local bc = jp._branchCentre or c
    local function ray(bdeg, len, col, width, dash, op)
        local r = math.rad(bdeg)
        local x2, z2 = bc.x + math.sin(r) * len, bc.z + math.cos(r) * len
        add(string.format('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="%s"%s stroke-opacity="%s" stroke-linecap="round"/>',
            px(bc.x), py(bc.z), px(x2), py(z2), col, width, dash and (' stroke-dasharray="' .. dash .. '"') or "", op or 1))
        return x2, z2
    end
    local d = (br.side - br.main + 540) % 360 - 180          -- signed turn from the main arm to the side arm
    local sgn = (d >= 0) and 1 or -1
    local L = R * 0.8
    for _, g in ipairs({ 38, 62 }) do
        local gx, gz = ray(br.main + sgn * g, L * 0.95, "#1a73e8", 2, "5 5", 0.8)
        add(string.format('<text x="%.1f" y="%.1f" font-size="13" fill="#1a73e8" stroke="#fff" stroke-width="3" paint-order="stroke">%d°</text>', px(gx) + 4, py(gz) - 4, g))
    end
    ray(br.main, L, "#202124", 4, "10 6")
    local sx, sz = ray(br.side, L, "#e8710a", 4, "10 6")
    -- the arc
    local pts, rr = {}, L * 0.35
    for k = 0, 24 do
        local b = math.rad(br.main + d * k / 24)
        pts[#pts + 1] = string.format("%.1f,%.1f", px(bc.x + math.sin(b) * rr), py(bc.z + math.cos(b) * rr))
    end
    add(string.format('<polyline points="%s" fill="none" stroke="#d93025" stroke-width="3"/>', table.concat(pts, " ")))
    local mb = math.rad(br.main + d / 2)
    add(string.format('<text x="%.1f" y="%.1f" font-size="22" font-weight="700" fill="#d93025" stroke="#fff" stroke-width="4" paint-order="stroke" text-anchor="middle">%.0f°</text>',
        px(bc.x + math.sin(mb) * rr * 1.7), py(bc.z + math.cos(mb) * rr * 1.7) + 7, br.angle))
end
add(string.format('<circle cx="%.1f" cy="%.1f" r="6" fill="none" stroke="#d93025" stroke-width="2.5"/>', px(c.x), py(c.z)))
add(string.format('<text x="%.1f" y="%.1f" fill="#d93025" font-weight="700">centre</text>', px(c.x) + 9, py(c.z) - 8))
add(string.format('<text x="%d" y="%d" font-size="22" font-weight="700" fill="#202124">N &#8593;</text>', PAD + S - 45, PAD + 26))
-- MARKS="x,z,label;x,z,label": extra labelled points (e.g. the meeting points of a compound junction)
for mx, mz, ml in (os.getenv("MARKS") or ""):gmatch("(%-?[%d.]+),(%-?[%d.]+),([^;]*)") do
    mx, mz = tonumber(mx), tonumber(mz)
    add(string.format('<circle cx="%.1f" cy="%.1f" r="16" fill="#7b1fa2" fill-opacity="0.18" stroke="#7b1fa2" stroke-width="3"/>', px(mx), py(mz)))
    add(string.format('<text x="%.1f" y="%.1f" font-size="20" font-weight="700" fill="#7b1fa2" stroke="#fff" stroke-width="4" paint-order="stroke">%s</text>', px(mx) + 20, py(mz) - 14, ml))
end
-- THE CAPTION sits just under the map, in 13px, so it fits the 1110 px the pictures are rendered at
-- (940x1110 in Chrome) even when a corner T or a held meeting point adds its lines: up to nine.
local y = S + 2 * PAD + 6
local g = jp and jp._branch and jp._branch.meet
local lines = {
    string.format("Junction at %.0f, %.0f - read as: %s", c.x, c.z, tostring(kind)),
    "Black = through route (T). Coloured = side routes (S). Grey = main network. Dashed blue = loose pieces wired to nothing.",
    string.format("%d through, %d side route(s); grid 10 m; north up. %s", #(r.through or {}), #(r.side or {}),
        nSpl > 0 and string.format("Wide pale orange = the map's own roads (%d traffic spline(s) nearby).", nSpl)
        or (splLoaded and "(No map road lines nearby.)" or "(No map road lines loaded.)")),
}
local corner = jp and jp._branch and jp._branch.corner
if corner ~= nil then
    -- a corner T is read from the main road's turn and the side road carrying straight on, not the angle
    lines[#lines + 1] = string.format("Corner T: the main road turns %.0f deg (grey rays = its legs); the side road carries on within %.0f deg of straight on from one. Its kind is read from those; the T angle (%.1f deg, grey) is a chord across the turn, not used.",
        corner.bend, corner.straightOn, jp._branch.angle)
elseif jp and jp._branch then
    lines[#lines + 1] = string.format("Side road meets the main road at %.1f deg (red%s). Blue dashes: 38 and 62 deg - under 38 Y merge, 38-62 T skew, over 62 T square.",
        jp._branch.angle, g == nil and ", read from the centre" or "")
end
if g ~= nil and g.starts ~= nil then
    -- the side road read once (junctionClassify's roadReading)
    if g.across ~= nil then
        lines[#lines + 1] = "Wide orange = the side road's first 6 m, midway between its two lanes (thin orange = the cross-sections); rings = each lane's start."
    elseif #g.starts == 2 and g.starts[1].toX ~= nil then
        lines[#lines + 1] = "Wide orange = each lane's first 6 m from its own start (rings); thin dark line = the side road's middle line, from midway between the two starts to midway between the two ends."
    elseif (g.lanes or 1) >= 2 then
        lines[#lines + 1] = "Wide orange = the side road's first 6 m along ONE of its two lanes: they do not lie side by side (over 12 m or 30 deg apart), so it is read along the one meeting the main road nearest the centre."
    else
        lines[#lines + 1] = "Wide orange = the side road's first 6 m, along its one lane; ring = where the side road starts on it."
    end
    lines[#lines + 1] = "Dot = that line's crossing with the main road's middle, where the main road is read: 8 m either way along each lane (grey bands)."
    if g.borrowed then
        lines[#lines + 1] = "Its second lane is a side route not counted as a side road (it runs within 6 m of the main road)."
    end
    if g.held then
        lines[#lines + 1] = "Dot held at the mouth: the side road's line barely crosses the main road's, over 16 m past where its lanes leave it."
    end
elseif g ~= nil then
    lines[#lines + 1] = "Wide orange = each lane's first 6 m, read lane by lane, the angle averaged over them; red dot = where the lane nearest the centre meets the main road (ring = the other lane's)."
end
-- LONG LINES ARE WRAPPED at word boundaries: at 13px about 128 characters fit across the 900 px
-- picture, and the old single lines ran off the right edge ("Blue dashes: 38 a").
local wrapped = {}
for i, s in ipairs(lines) do
    local cur = ""
    for word in s:gmatch("%S+") do
        if cur ~= "" and #cur + 1 + #word > 128 then
            wrapped[#wrapped + 1] = { text = cur, head = (i == 1) }
            cur = word
        elseif cur == "" then
            cur = word
        else
            cur = cur .. " " .. word
        end
    end
    if cur ~= "" then wrapped[#wrapped + 1] = { text = cur, head = (i == 1) } end
end
local yy = y
for i, w in ipairs(wrapped) do
    yy = yy + (w.head and 20 or 17)
    add(string.format('<text x="%d" y="%d"%s>%s</text>', PAD, yy, w.head and ' font-weight="700" font-size="16"' or ' font-size="13"', w.text))
end
-- the picture grows to fit the caption (1110 px tall for up to nine lines)
local H2 = math.max(S + 2 * PAD + 150, yy + 8)
o[1] = string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">', S + 2 * PAD, H2, S + 2 * PAD, H2)
add('</svg>')
local f = assert(io.open(OUT, "w"))
f:write(table.concat(o, "\n"))
f:close()
print("wrote " .. OUT)
