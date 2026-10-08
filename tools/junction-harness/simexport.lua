-- FOR THE TRAFFIC STUDY (tools/xt-study/junctionsim.lua): lay a junction with the editor's own code and
-- write the network around it, as a Lua table the traffic sim reads.
--   GRAPH=<network .lua> lua simexport.lua X Z place|build OUT.lua [radius]
--   place: PATTERN=exact|smooth (as dbgplace.lua); build: TURNR=, the build card's turn radius
--   WIREFIRST=1: build the site and clear it (through roads kept) before the place, as in game
-- Points within 160 m: { id, x, z, out = {...}, incoming = {...} }.
LOG_ECHO = false
local H = dofile("harness.lua")
local E = ADFlyoverEditor
local CX, CZ, MODE, OUT = tonumber(arg[1]), tonumber(arg[2]), arg[3], arg[4]
local RADIUS = tonumber(arg[5] or "") or 15
-- "place" on a site wired first and then cleared with its through roads kept - the way a place is done
-- in game (a virgin site with every arm cut is placed as the plain piece, not the pattern).
if os.getenv("WIREFIRST") == "1" then
    local bjp = H.lock(CX, CZ, { mode = "build", radius = RADIUS, turnRadius = 12 })
    assert(bjp ~= nil, "wire first: build refused")
    H.build()
    local cjp = H.lock(CX, CZ, { mode = "clear", radius = 12, leaveThrough = true })
    assert(cjp ~= nil, "wire first: clear refused - " .. tostring(E.junctionRefused))
    H.apply()
    print("wired, then cleared with the through roads kept")
end
if MODE == "place" then
    local jp = H.lock(CX, CZ, { mode = "place" })
    assert(jp ~= nil and jp.placeMode and jp.ok, "place: no preview or cannot place - " .. tostring(jp and jp.why))
    LOG = {}
    E:applyJunction()
    local last = E.junctionLastPlace or {}
    print(string.format("placed %s %s: %d turn piece(s), %d shared, %d loose", tostring(last.shape), tostring(last.kind),
        last.turns or 0, last.shared or 0, last.loose or 0))
elseif MODE == "build" then
    local jp = H.lock(CX, CZ, { mode = "build", radius = RADIUS, turnRadius = tonumber(os.getenv("TURNR") or "12") })
    assert(jp ~= nil, "build refused: " .. tostring(E.junctionRefused))
    local log = H.build()
    for _, l in ipairs(log) do
        if l:find("placed %d") or l:find("route check") or l:find("refused") then print((l:gsub(".*FlyoverEditor%]: ", ""))) end
    end
end
local f = assert(io.open(OUT, "w"))
f:write("return {\n")
for _, w in pairs(ADGraphManager:getWayPoints()) do
    if w ~= nil and w.id ~= nil and (w.x - CX) ^ 2 + (w.z - CZ) ^ 2 <= 160 * 160 then
        local o, i = {}, {}
        for _, id in ipairs(w.out or {}) do o[#o + 1] = tostring(id) end
        for _, id in ipairs(w.incoming or {}) do i[#i + 1] = tostring(id) end
        f:write(string.format("  {id=%d,x=%.3f,z=%.3f,out={%s},incoming={%s}},\n", w.id, w.x, w.z, table.concat(o, ","), table.concat(i, ",")))
    end
end
f:write("}\n")
f:close()
print("wrote " .. OUT)
