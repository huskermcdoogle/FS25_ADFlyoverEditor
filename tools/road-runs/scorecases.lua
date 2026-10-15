-- Score the road walk on every saved test case: one table, and a picture per case.
--   lua scorecases.lua                 (cases/ here + the game's modSettings/FS25_ADFlyoverEditor/roadCases/)
--   lua scorecases.lua some.xml ...    (just these)
-- A case is a track the user saved in game (detection view, "draw the middle" -> "save track"): the
-- ground the game read along it, and the true middle the user drew. Each case is walked from five
-- mouse spots along the middle (casewalk.lua: the game's hover walk on the saved ground only).
--   covers  how much of the middle a line runs along (within 2 m)
--   off     how far the line is from the middle there: average and worst (m)
--   stray   metres of line more than 2 m from the middle (beside the ends do not count)
--   same    whether every spot gave the same line (spread = most they differ, m)
-- Pictures and a page with the table: out/cases/index.html
local HERE = (arg[0]:match("^(.*)[/\\]") or ".") .. "/"
local LUA = '"C:/Program Files (x86)/Lua/5.1/lua.exe"'
local NEAR = 2.0                 -- a line within this of the middle is running along it (m)
local SAME = 0.25                -- lines from every spot within this of each other are the same (m)

local function listXml(dir)
    local out = {}
    local p = io.popen('dir /b /on "' .. dir:gsub("/", "\\") .. '\\*.xml" 2>nul')
    for name in p:lines() do out[#out + 1] = dir .. name end
    p:close()
    return out
end

local files = {}
if #arg > 0 then
    for _, a in ipairs(arg) do files[#files + 1] = a end
else
    local function addWithMiddle(list)
        for _, f in ipairs(list) do
            local h = io.open(f, "rb")
            if h ~= nil then
                local s = h:read("*a")
                h:close()
                if s:find("<middle ", 1, true) then files[#files + 1] = f end
            end
        end
    end
    addWithMiddle(listXml(HERE .. "cases/"))
    local profile = os.getenv("FS_PROFILE") or ((os.getenv("USERPROFILE") or "") .. "/OneDrive/Documents/My Games/FarmingSimulator2025/")
    addWithMiddle(listXml(profile .. "modSettings/FS25_ADFlyoverEditor/roadCases/"))
end
if #files == 0 then
    print("No cases with a middle yet. In game: road runs, detection view, 'draw the middle', then 'save track'.")
    return
end

-- geometry: distance from a point to a polyline, and where along it
local function nearestOn(P, x, z)
    local best, bx, bz, bi = math.huge, nil, nil, nil
    for i = 2, #P do
        local a, b = P[i - 1], P[i]
        local dx, dz = b.x - a.x, b.z - a.z
        local l2 = dx * dx + dz * dz
        local u = l2 > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / l2)) or 0
        local px, pz = a.x + dx * u, a.z + dz * u
        local d = (px - x) ^ 2 + (pz - z) ^ 2
        if d < best then best, bx, bz, bi = d, px, pz, i - 1 + u end
    end
    return math.sqrt(best), bx, bz, bi
end

local function nameOf(f) return (f:match("([^/\\]+)%.xml$") or f) end

local function svgCase(case, path)
    -- the ground, straight from the case file (0.25 m, runs of one kind joined)
    local h = io.open(case.file, "rb")
    local xml = h:read("*a")
    h:close()
    local T = tonumber(xml:match('tile="([^"]+)"')) or 8
    local st = tonumber(xml:match('step="([^"]+)"')) or 0.25
    local per = math.floor(T / st + 0.5)
    local tiles = {}
    local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
    for tx, tz, k in xml:gmatch('<tile x0="([^"]+)" z0="([^"]+)" k="([^"]*)"') do
        tx, tz = tonumber(tx), tonumber(tz)
        tiles[#tiles + 1] = { x = tx, z = tz, k = k }
        x0, x1, z0, z1 = math.min(x0, tx), math.max(x1, tx + T), math.min(z0, tz), math.max(z1, tz + T)
    end
    if #tiles == 0 then return end
    local W, H = x1 - x0, z1 - z0
    local S = math.max(1, math.min(14, 2400 / math.max(W, H)))
    local pad, top, legend = 30, 50, 170
    local function px(x) return pad + (x - x0) * S end
    local function pz(z) return top + (z - z0) * S end          -- north (small z) up
    local col = { d = "#8b5a2b", g = "#e6c84a", p = "#9a9a9a", F = "#e8b0b0" }
    local o = {}
    local SW, SH = math.ceil(W * S + 2 * pad + legend), math.ceil(H * S + top + pad)
    o[#o + 1] = string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="sans-serif" font-size="12">',
        SW, SH, SW, SH)
    o[#o + 1] = '<rect width="100%" height="100%" fill="#2f4a2a"/>'
    o[#o + 1] = string.format('<text x="%d" y="22" fill="white" font-size="15">%s</text>', pad, case.title)
    o[#o + 1] = string.format('<text x="%d" y="40" fill="#ddd">%s</text>', pad, case.sub)
    for _, t in ipairs(tiles) do
        o[#o + 1] = string.format('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#3a5a34"/>', px(t.x), pz(t.z), T * S, T * S)
        for j = 0, per - 1 do
            local i = 0
            while i < per do
                local c = t.k:sub(j * per + i + 1, j * per + i + 1)
                local n = 1
                while i + n < per and t.k:sub(j * per + i + n + 1, j * per + i + n + 1) == c do n = n + 1 end
                if col[c] then
                    o[#o + 1] = string.format('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s"/>',
                        px(t.x + i * st), pz(t.z + j * st), n * st * S, st * S + 0.05, col[c])
                end
                i = i + n
            end
        end
    end
    local function poly(P, colour, w, extra)
        if #P < 2 then return end
        local q = {}
        for _, p in ipairs(P) do q[#q + 1] = string.format("%.1f,%.1f", px(p.x), pz(p.z)) end
        o[#o + 1] = string.format('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s" %s/>', table.concat(q, " "), colour, w, extra or "")
    end
    poly(case.mid, "#ff33e6", math.max(3, S * 0.6), 'stroke-opacity="0.55"')
    local LC = { "#3050ff", "#ff9f1c", "#00e5ff", "#ffffff", "#7CFC00" }
    for si, sp in ipairs(case.spots) do
        poly(sp.line, LC[(si - 1) % #LC + 1], 1.6)
    end
    for si, sp in ipairs(case.spots) do
        local c = LC[(si - 1) % #LC + 1]
        o[#o + 1] = string.format('<circle cx="%.1f" cy="%.1f" r="5" fill="%s" stroke="black"/>', px(sp.x), pz(sp.z), c)
        o[#o + 1] = string.format('<text x="%.1f" y="%.1f" fill="white" font-weight="bold">%d</text>', px(sp.x) + 7, pz(sp.z) + 4, si)
    end
    local lx, ly = pad + W * S + 15, top + 10
    local items = { { "#9a9a9a", "asphalt" }, { "#e6c84a", "gravel" }, { "#8b5a2b", "dirt" }, { "#e8b0b0", "field" }, { "#ff33e6", "your middle" } }
    for si = 1, #case.spots do items[#items + 1] = { LC[(si - 1) % #LC + 1], "line from spot " .. si } end
    for i, it in ipairs(items) do
        o[#o + 1] = string.format('<rect x="%.0f" y="%.0f" width="12" height="12" fill="%s"/><text x="%.0f" y="%.0f" fill="white">%s</text>',
            lx, ly + (i - 1) * 20, it[1], lx + 18, ly + (i - 1) * 20 + 11, it[2])
    end
    o[#o + 1] = "</svg>"
    local f = io.open(path, "w")
    f:write(table.concat(o, "\n"))
    f:close()
    return table.concat(o, "\n")
end

os.execute('if not exist "' .. (HERE .. "out/cases"):gsub("/", "\\") .. '" mkdir "' .. (HERE .. "out/cases"):gsub("/", "\\") .. '"')
local rows, pages, allSame, worstOff = {}, {}, 0, 0
print(string.format("%-22s %6s  %-4s %7s %8s %9s %7s", "case", "length", "spot", "covers", "off avg", "off worst", "stray"))
for _, file in ipairs(files) do
    local cmd = string.format('set "AREA=%s" && set AREAONLY=1 && set AREAQUIET=1 && %s "%scasewalk.lua"', file, LUA, HERE)
    local p = io.popen(cmd .. " 2>&1")
    local out = p:read("*a")
    p:close()
    local case = { file = file, mid = {}, spots = {} }
    for ln in out:gmatch("[^\r\n]+") do
        local t, a, b, c = ln:match("^(%a) (%S+) ?(%S*) ?(%S*)")
        if t == "m" then case.mid[#case.mid + 1] = { x = tonumber(a), z = tonumber(b) }
        elseif t == "s" then case.spots[tonumber(a)] = { x = tonumber(b), z = tonumber(c), line = {} }
        elseif t == "l" then local L = case.spots[tonumber(a)].line L[#L + 1] = { x = tonumber(b), z = tonumber(c) }
        elseif t == "e" or (t == nil and ln:find("rror")) then print("  " .. ln) end
    end
    local M = case.mid
    local len = 0
    for i = 2, #M do len = len + math.sqrt((M[i].x - M[i - 1].x) ^ 2 + (M[i].z - M[i - 1].z) ^ 2) end
    -- score each spot's line against the middle
    local covAll = {}
    for si, sp in ipairs(case.spots) do
        local L = sp.line
        local n, cov, sum, worst = 0, 0, 0, 0
        sp.near = {}
        for mi, m in ipairs(M) do
            n = n + 1
            if #L >= 2 then
                local d, bx, bz = nearestOn(L, m.x, m.z)
                if d <= NEAR then
                    cov, sum, worst = cov + 1, sum + d, math.max(worst, d)
                    sp.near[mi] = { x = bx, z = bz }
                end
            end
        end
        local stray = 0
        for i = 2, #L do
            local da, _, _, ia = nearestOn(M, L[i - 1].x, L[i - 1].z)
            local db, _, _, ib = nearestOn(M, L[i].x, L[i].z)
            local pastEnd = (ia <= 0.01 or ia >= #M - 1.01) and (ib <= 0.01 or ib >= #M - 1.01)
            if da > NEAR and db > NEAR and not pastEnd then
                stray = stray + math.sqrt((L[i].x - L[i - 1].x) ^ 2 + (L[i].z - L[i - 1].z) ^ 2)
            end
        end
        sp.cov, sp.avg, sp.worst, sp.stray = n > 0 and cov / n or 0, cov > 0 and sum / cov or 0, worst, stray
        covAll[#covAll + 1] = sp.cov
        if cov > 0 then worstOff = math.max(worstOff, worst) end
        local row = string.format("%-22s %5.0fm  %-4d %6.0f%% %7.2fm %8.2fm %6.0fm",
            si == 1 and nameOf(file) or "", si == 1 and len or 0, si, sp.cov * 100, sp.avg, sp.worst, sp.stray)
        if si ~= 1 then row = row:gsub("^(%s+)%s+0m", "%1   ") end
        print(row)
    end
    -- same from every spot: where all lines run along the middle, how far apart are they
    local spread = 0
    for mi = 1, #M do
        local pts = {}
        for _, sp in ipairs(case.spots) do if sp.near[mi] then pts[#pts + 1] = sp.near[mi] else pts = nil break end end
        if pts ~= nil then
            for a = 1, #pts do for b = a + 1, #pts do
                spread = math.max(spread, math.sqrt((pts[a].x - pts[b].x) ^ 2 + (pts[a].z - pts[b].z) ^ 2))
            end end
        end
    end
    local cmin, cmax = math.huge, -math.huge
    for _, c in ipairs(covAll) do cmin, cmax = math.min(cmin, c), math.max(cmax, c) end
    local same = #covAll > 0 and spread <= SAME and (cmax - cmin) <= 0.02
    if same then allSame = allSame + 1 end
    local verdict = string.format("same from every spot: %s (lines differ by up to %.2f m, cover %.0f-%.0f%%)",
        same and "yes" or "NO", spread, cmin * 100, cmax * 100)
    print(string.format("%-22s %s", "", verdict))
    case.title = nameOf(file) .. string.format(" - %.0f m of middle", len)
    case.sub = verdict
    local svg = nameOf(file) .. ".svg"
    local picture = svgCase(case, HERE .. "out/cases/" .. svg)
    pages[#pages + 1] = { name = nameOf(file), svg = svg, case = case, len = len, verdict = verdict, same = same, picture = picture }
end
print(string.format("%d case(s); same from every spot in %d; worst distance from the middle %.2f m", #files, allSame, worstOff))

-- one page: the table and every picture
local h = {}
h[#h + 1] = [[<!doctype html><html><head><meta charset="utf-8"><title>Road cases</title><style>
body{background:#1e1e1e;color:#eee;font-family:sans-serif;margin:16px}
table{border-collapse:collapse;margin-bottom:20px}td,th{padding:3px 10px;text-align:right;border-bottom:1px solid #444}
td:first-child,th:first-child{text-align:left}.bad{color:#ff7070}.ok{color:#8f8}
.pic{border:1px solid #444;margin:6px 0 24px}.pic svg{height:auto;display:block}</style></head><body>
<h2>Road cases</h2><table><tr><th>case</th><th>length</th><th>spot</th><th>covers</th><th>off avg</th><th>off worst</th><th>stray</th><th>same?</th></tr>]]
for _, pg in ipairs(pages) do
    for si, sp in ipairs(pg.case.spots) do
        h[#h + 1] = string.format('<tr><td>%s</td><td>%s</td><td>%d</td><td>%.0f%%</td><td>%.2f m</td><td>%.2f m</td><td>%.0f m</td><td>%s</td></tr>',
            si == 1 and ('<a href="#' .. pg.name .. '" style="color:#9cf">' .. pg.name .. '</a>') or "",
            si == 1 and string.format("%.0f m", pg.len) or "", si, sp.cov * 100, sp.avg, sp.worst, sp.stray,
            si == 1 and (pg.same and '<span class="ok">yes</span>' or '<span class="bad">NO</span>') or "")
    end
end
h[#h + 1] = "</table>"
for _, pg in ipairs(pages) do
    -- the picture inline (one file to open); the .svg beside it opens full size
    local pic = (pg.picture or ""):gsub('^<svg (.-)width="%d+" height="%d+"', '<svg %1width="100%%"', 1)
    h[#h + 1] = string.format('<h3 id="%s">%s</h3><div>%s - <a style="color:#9cf" href="%s">full size</a></div><div class="pic">%s</div>',
        pg.name, pg.name, pg.verdict, pg.svg, pic)
end
h[#h + 1] = "</body></html>"
local f = io.open(HERE .. "out/cases/index.html", "w")
f:write(table.concat(h, "\n"))
f:close()
print("pictures: " .. HERE .. "out/cases/index.html")
