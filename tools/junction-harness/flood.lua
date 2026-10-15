-- Which of the given points can the seed reach, at several flood limits?
--   lua flood.lua SEED ID [ID ...]
dofile("harness.lua")
local function flood(seed, reach)
    local seen, stack, n = { [seed] = true }, { seed }, 1
    while #stack > 0 do
        local w = table.remove(stack)
        for _, lst in ipairs({ w.out or {}, w.incoming or {} }) do
            for _, id in pairs(lst) do
                local t = ADGraphManager:getWayPointById(id)
                if t ~= nil and not seen[t]
                    and (reach == nil or (t.x - seed.x) ^ 2 + (t.z - seed.z) ^ 2 <= reach * reach) then
                    seen[t] = true
                    n = n + 1
                    stack[#stack + 1] = t
                end
            end
        end
    end
    return seen, n
end
local seed = ADGraphManager:getWayPointById(tonumber(arg[1]))
for _, R in ipairs({ 150, 300, 600, 0 }) do
    local seen, n = flood(seed, R > 0 and R or nil)
    local s = ""
    for i = 2, #arg do
        local w = ADGraphManager:getWayPointById(tonumber(arg[i]))
        s = s .. string.format(" %s=%s", arg[i], tostring(seen[w] ~= nil))
    end
    print(string.format("reach %s: %d points reached;%s", R > 0 and R or "unlimited", n, s))
end
