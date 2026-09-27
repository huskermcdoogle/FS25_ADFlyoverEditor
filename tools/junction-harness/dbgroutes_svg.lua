-- Draw the routes a junction's type is read from, over the network around it. North up.
--   RIG_TRAILER=11 lua dbgroutes_svg.lua CX CZ out.svg [halfSpan]
local H = dofile("harness.lua")
local CX, CZ, OUT, R = tonumber(arg[1]), tonumber(arg[2]), arg[3], tonumber(arg[4]) or 75
local jp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = false })
local c = (jp and (jp._boxCentre or jp.boxCentre or jp.tracksCentre)) or { x = CX, z = CZ }
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
local nSpl = 0
if os.getenv("SPLINES") then
    local f = io.open(os.getenv("SPLINES"), "r")
    if f then
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
add(string.format('<circle cx="%.1f" cy="%.1f" r="6" fill="none" stroke="#d93025" stroke-width="2.5"/>', px(c.x), py(c.z)))
add(string.format('<text x="%.1f" y="%.1f" fill="#d93025" font-weight="700">centre</text>', px(c.x) + 9, py(c.z) - 8))
add(string.format('<text x="%d" y="%d" font-size="22" font-weight="700" fill="#202124">N &#8593;</text>', PAD + S - 45, PAD + 26))
local y = S + 2 * PAD + 24
local lines = {
    string.format("Junction at %.0f, %.0f - read as: %s", c.x, c.z, tostring(kind)),
    "Black = through route (T). Coloured = side routes (S). Grey = main network. Dashed blue = loose pieces wired to nothing.",
    string.format("%d through, %d side route(s); grid 10 m; north up.", #(r.through or {}), #(r.side or {})),
    nSpl > 0 and string.format("Wide pale orange = the map's own roads (%d traffic spline(s) nearby).", nSpl) or "(no map road lines loaded)",
}
for i, s in ipairs(lines) do
    add(string.format('<text x="%d" y="%d"%s>%s</text>', PAD, y + (i - 1) * 24, i == 1 and ' font-weight="700" font-size="16"' or "", s))
end
add('</svg>')
local f = assert(io.open(OUT, "w"))
f:write(table.concat(o, "\n"))
f:close()
print("wrote " .. OUT)
