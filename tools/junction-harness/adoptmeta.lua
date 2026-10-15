-- Apply the settings a capture recorded, so a replay runs on the game's values and not the
-- harness's defaults. Returns how many it set. dofile this AFTER harness.lua, since the harness
-- replaces the AutoDrive table wholesale.
return function(metaPath)
    local f = io.open(metaPath, "r")
    if f == nil then return 0, "no meta.txt at " .. tostring(metaPath) end
    local n, seen = 0, false
    for line in f:lines() do
        if line:find("settings as they stood", 1, true) then seen = true
        elseif seen then
            local k, v = line:match("^(%S+)%s+(%S+)%s*$")
            if k ~= nil then
                local val
                if v == "true" then val = true
                elseif v == "false" then val = false
                elseif v == "nil" then val = nil
                elseif tonumber(v) ~= nil then val = tonumber(v)
                else val = v end
                if k:sub(1, 8) == "FLYOVER_" then
                    AutoDrive[k] = val; n = n + 1
                elseif k:sub(1, 7) == "editor." then
                    ADFlyoverEditor[k:sub(8)] = val; n = n + 1
                end
            end
        end
    end
    f:close()
    return n
end
