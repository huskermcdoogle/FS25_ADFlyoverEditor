--[[ ADFlyoverActionCodec - AN ACTION AS BYTES, CUT INTO PIECES (multiplayer step 2)

Turns an action from the one door (GraphOps.lua) into a byte string and back, exactly, and cuts the
bytes into pieces of at most PIECE_BYTES (6 KB: the size nobody has proven too big for one FS25
message; docs/multiplayer-probe-results.md). Nothing is sent yet: step 3 puts the pieces in an event.

Pure Lua 5.1 (the game's), no bit library: numbers are written as varints (7 bits a byte), so small
numbers - tags, counts, flags - take one or two bytes.

Coordinates must come back EXACTLY, or two PCs drift apart after the first action. A coordinate that is
a whole number of millimetres (what GraphOps.QUANTIZE makes them) is written as that integer, 2-4 bytes;
any other is written as its exact binary parts (mantissa and exponent), ~9-10 bytes. So turning
QUANTIZE on later only makes actions smaller; it is never needed for them to be exact.

Layout (all numbers varints unless said):
    version, label (string), countBefore, countAfter
    dels:  n, then per point: tag, index, x y z (coord), flags, fieldID+1 (0 = none), out list, in list
    adds:  n, then per point: tag, x y z, flags, fieldID+1, out list, in list
    sets:  n, then per point: tag, before (x y z flags fieldID+1), after (same)
    lists: n, then per point: tag, before out, before in, after out, after in
    markers: 0 | 1 + before list + after list      groups: 0 | 1 + before + after
  a list of tags is: count, then each tag zig-zagged (a link to a number nobody held is negative)
  a marker is: tag zig-zagged (0 = none), name, group, isADDebug (0/1)
  a piece is: actionId, index, count, then its slice of the bytes
]]

ADFlyoverActionCodec = ADFlyoverActionCodec or {}
local C = ADFlyoverActionCodec

C.VERSION = 1
C.PIECE_BYTES = 6144

-- ---------------------------------------------------------------- writer
local function newWriter() return { parts = {}, n = 0 } end
local function byte(w, b) w.n = w.n + 1; w.parts[w.n] = b end

local function uvar(w, v)
    assert(v >= 0 and v == math.floor(v), "uvar needs a whole number >= 0")
    repeat
        local b = v % 128
        v = (v - b) / 128
        if v > 0 then b = b + 128 end
        byte(w, b)
    until v == 0
end
local function svar(w, v) -- zig-zag: 0,-1,1,-2,2 -> 0,1,2,3,4
    if v >= 0 then uvar(w, v * 2) else uvar(w, -v * 2 - 1) end
end
local function str(w, s)
    s = s or ""
    uvar(w, #s)
    for i = 1, #s do byte(w, s:byte(i)) end
end
local function coord(w, v)
    local mm = math.floor(v * 1000 + 0.5)
    if mm / 1000 == v and math.abs(mm) < 2 ^ 50 then
        byte(w, 0)
        svar(w, mm)
        return
    end
    -- exact: v = m * 2^e with 0.5 <= |m| < 1, so m * 2^53 is a whole number
    local m, e = math.frexp(v)
    local sign = 0
    if m < 0 then m, sign = -m, 1 end
    byte(w, 1)
    uvar(w, (e + 1100) * 2 + sign)
    uvar(w, m * 2 ^ 53)
end
local function tags(w, list)
    list = list or {}
    uvar(w, #list)
    for i = 1, #list do svar(w, list[i]) end
end
local function point(w, p)
    coord(w, p.x); coord(w, p.y); coord(w, p.z)
    uvar(w, p.flags or 0)
    uvar(w, p.fieldID ~= nil and p.fieldID + 1 or 0)
end
local function markers(w, list)
    uvar(w, #list)
    for _, m in ipairs(list) do
        svar(w, m.tag or 0)
        str(w, m.name); str(w, m.group)
        uvar(w, m.isADDebug == true and 1 or 0)
    end
end
local function groups(w, g)
    local names = {}
    for k in pairs(g) do names[#names + 1] = k end
    table.sort(names)      -- never let pairs() order reach the bytes
    uvar(w, #names)
    for _, k in ipairs(names) do str(w, k); uvar(w, g[k]) end
end

local function toString(w)
    local out, CH = {}, 4096
    for i = 1, w.n, CH do
        out[#out + 1] = string.char(unpack(w.parts, i, math.min(i + CH - 1, w.n)))
    end
    return table.concat(out)
end

--- An action as one byte string.
function C.pack(a)
    local w = newWriter()
    uvar(w, C.VERSION)
    str(w, a.label or "")
    uvar(w, a.countBefore); uvar(w, a.countAfter)
    uvar(w, #a.dels)
    for _, p in ipairs(a.dels) do
        svar(w, p.tag); uvar(w, p.index); point(w, p); tags(w, p.out); tags(w, p.incoming)
    end
    uvar(w, #a.adds)
    for _, p in ipairs(a.adds) do
        svar(w, p.tag); point(w, p); tags(w, p.out); tags(w, p.incoming)
    end
    uvar(w, #a.sets)
    for _, s in ipairs(a.sets) do
        svar(w, s.tag); point(w, s.before); point(w, s.after)
    end
    uvar(w, #a.lists)
    for _, l in ipairs(a.lists) do
        svar(w, l.tag); tags(w, l.bo); tags(w, l.bi); tags(w, l.ao); tags(w, l.ai)
    end
    if a.markers ~= nil then
        uvar(w, 1); markers(w, a.markers.before); markers(w, a.markers.after)
    else
        uvar(w, 0)
    end
    if a.groups ~= nil then
        uvar(w, 1); groups(w, a.groups.before); groups(w, a.groups.after)
    else
        uvar(w, 0)
    end
    return toString(w)
end

-- ---------------------------------------------------------------- reader
local function newReader(s) return { s = s, i = 1 } end
local function rbyte(r)
    local b = r.s:byte(r.i)
    if b == nil then error("action bytes end too soon") end
    r.i = r.i + 1
    return b
end
local function ruvar(r)
    local v, mul = 0, 1
    while true do
        local b = rbyte(r)
        if b >= 128 then
            v = v + (b - 128) * mul
            mul = mul * 128
        else
            return v + b * mul
        end
    end
end
local function rsvar(r)
    local u = ruvar(r)
    if u % 2 == 0 then return u / 2 end
    return -(u + 1) / 2
end
local function rstr(r)
    local n = ruvar(r)
    local s = r.s:sub(r.i, r.i + n - 1)
    if #s ~= n then error("action bytes end inside a string") end
    r.i = r.i + n
    return s
end
local function rcoord(r)
    local kind = rbyte(r)
    if kind == 0 then return rsvar(r) / 1000 end
    local es = ruvar(r)
    local sign = es % 2
    local e = (es - sign) / 2 - 1100
    local m = ruvar(r) / 2 ^ 53
    if sign == 1 then m = -m end
    return math.ldexp(m, e)
end
local function rtags(r)
    local n, t = ruvar(r), {}
    for i = 1, n do t[i] = rsvar(r) end
    return t
end
local function rpoint(r, p)
    p = p or {}
    p.x = rcoord(r); p.y = rcoord(r); p.z = rcoord(r)
    p.flags = ruvar(r)
    local f = ruvar(r)
    p.fieldID = f > 0 and f - 1 or nil
    return p
end
local function rmarkers(r)
    local n, list = ruvar(r), {}
    for i = 1, n do
        local tag = rsvar(r)
        local m = { tag = tag ~= 0 and tag or nil, name = rstr(r), group = rstr(r) }
        if ruvar(r) == 1 then m.isADDebug = true end
        list[i] = m
    end
    return list
end
local function rgroups(r)
    local n, g = ruvar(r), {}
    for _ = 1, n do
        local k = rstr(r)
        g[k] = ruvar(r)
    end
    return g
end

--- The action back from its bytes. Errors on bytes that are not one.
function C.unpack(s)
    local r = newReader(s)
    local version = ruvar(r)
    if version ~= C.VERSION then error("action version " .. version .. ", this build reads " .. C.VERSION) end
    local a = { label = rstr(r), dels = {}, adds = {}, sets = {}, lists = {} }
    a.countBefore = ruvar(r); a.countAfter = ruvar(r)
    for i = 1, ruvar(r) do
        local p = { tag = rsvar(r), index = ruvar(r) }
        rpoint(r, p); p.out = rtags(r); p.incoming = rtags(r)
        a.dels[i] = p
    end
    for i = 1, ruvar(r) do
        local p = { tag = rsvar(r) }
        rpoint(r, p); p.out = rtags(r); p.incoming = rtags(r)
        a.adds[i] = p
    end
    for i = 1, ruvar(r) do
        a.sets[i] = { tag = rsvar(r), before = rpoint(r), after = rpoint(r) }
    end
    for i = 1, ruvar(r) do
        a.lists[i] = { tag = rsvar(r), bo = rtags(r), bi = rtags(r), ao = rtags(r), ai = rtags(r) }
    end
    if ruvar(r) == 1 then a.markers = { before = rmarkers(r), after = rmarkers(r) } end
    if ruvar(r) == 1 then a.groups = { before = rgroups(r), after = rgroups(r) } end
    if r.i ~= #s + 1 then error(string.format("%d byte(s) left over after the action", #s + 1 - r.i)) end
    return a
end

-- ---------------------------------------------------------------- pieces
--- Cut bytes into pieces of at most PIECE_BYTES of payload. Each piece is a table the event will write:
--- { id, index, count, bytes }.
function C.cut(id, bytes)
    local count = math.max(1, math.ceil(#bytes / C.PIECE_BYTES))
    local pieces = {}
    for i = 1, count do
        pieces[i] = { id = id, index = i, count = count,
                      bytes = bytes:sub((i - 1) * C.PIECE_BYTES + 1, i * C.PIECE_BYTES) }
    end
    return pieces
end

--- Collects pieces; hands back the whole bytes when the last one of an action arrives, so an action
--- is only ever applied whole. Pieces of one sender arrive in order (one connection), but this does not
--- rely on it.
function C.newJoiner()
    return { pending = {} }
end
function C.join(joiner, piece)
    local slot = joiner.pending[piece.id]
    if slot == nil then
        slot = { got = 0, count = piece.count, parts = {} }
        joiner.pending[piece.id] = slot
    end
    if slot.parts[piece.index] == nil then
        slot.parts[piece.index] = piece.bytes
        slot.got = slot.got + 1
    end
    if slot.got < slot.count then return nil end
    joiner.pending[piece.id] = nil
    return table.concat(slot.parts)
end

--- Pack, cut, join, unpack, pack again: the bytes must come back the same. For the log in step 2.
--- Returns bytes, pieces, ok, why.
function C.roundTrip(a, id)
    local bytes = C.pack(a)
    local pieces = C.cut(id or 1, bytes)
    local j = C.newJoiner()
    local whole
    for _, p in ipairs(pieces) do whole = C.join(j, p) or whole end
    local ok, back = pcall(C.unpack, whole or "")
    if not ok then return bytes, pieces, false, tostring(back) end
    local again = C.pack(back)
    if again ~= bytes then return bytes, pieces, false, "bytes differ after unpack and pack" end
    return bytes, pieces, true
end
