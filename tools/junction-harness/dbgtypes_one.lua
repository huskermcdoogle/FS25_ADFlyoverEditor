-- One junction for dbgtypes.lua: lock it (through paths off) and print its type and route counts.
local H = dofile("harness.lua")
local jp = H.lock(tonumber(arg[1]), tonumber(arg[2]), { mode = "clear", radius = 12, leaveThrough = false })
local r = jp and jp.pathRoutes or {}
print(string.format("TYPE %s | %d through, %d side",
    tostring(jp and ADFlyoverEditor.junctionClassify(ADFlyoverEditor, jp)), #(r.through or {}), #(r.side or {})))
