-- SHUFFLE=<seed>: pairs() walks a table's hash part in a random order (fixed per seed), as the
-- game does after a clear renumbers points or the memory falls differently. The array part 1..#t
-- still comes first and in order, as in real Lua. harness.lua loads it when SHUFFLE is set.
local seed = tonumber(os.getenv("SHUFFLE") or "")
if seed == nil or seed == 0 then return end
local rawnext = next
local state = seed
local function rnd(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return math.floor(state / 65536) % n + 1
end
function pairs(t)
    local n = #t
    local keys = {}
    local k = rawnext(t)
    while k ~= nil do
        if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
            keys[#keys + 1] = k
        end
        k = rawnext(t, k)
    end
    for i = #keys, 2, -1 do
        local j = rnd(i)
        keys[i], keys[j] = keys[j], keys[i]
    end
    local i, h = 0, 0
    return function()
        while i < n do
            i = i + 1
            if t[i] ~= nil then return i, t[i] end
        end
        while true do
            h = h + 1
            local key = keys[h]
            if key == nil then return nil end
            local v = t[key]
            if v ~= nil then return key, v end
        end
    end, t, nil
end
