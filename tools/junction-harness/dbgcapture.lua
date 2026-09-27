-- Prove the debug capture writes what it says it writes, with the engine's XML and file calls
-- stubbed. The harness has no game behind it, so every one of these is a place the capture could
-- silently do nothing in the real build.
LOG_ECHO = true
local OUT = os.getenv("CAPDIR") or "captest/"

local made = {}
function createFolder(p)
    made[#made+1] = p
    -- os.execute under this Lua does not reach a shell that understands the path; do it the way the
    -- engine's createFolder does - make the directory and say whether it is there afterwards.
    os.execute('cmd /c mkdir "' .. p:gsub("/", "\\") .. '" 2>nul')
    return true
end
function getUserProfileAppPath() return OUT end
function getDate(f) return "12:00:00" end

-- AutoDrive's graph writer, stubbed to record what it was handed
local wrote = {}
local files = {}
function createXMLFile(_, path, root) print("  createXMLFile -> " .. path) files[path] = { root = root } return 900 + #made end
function saveXMLFile(id) end
function delete(id) end
local H = dofile("harness.lua")
-- AFTER the harness, which replaces g_currentMission wholesale.
g_currentMission.missionInfo = { savegameDirectory = OUT:gsub("/$", "") }
ADGraphManager.getMapMarkers = ADGraphManager.getMapMarkers or function() return {} end
ADGraphManager.getGroups = ADGraphManager.getGroups or function() return {} end

AutoDrive = AutoDrive or {}
AutoDrive.writeGraphToXml = function(id, root, wps, markers, groups)
    local n = 0
    for _ in pairs(wps or {}) do n = n + 1 end
    wrote[#wrote+1] = n
    -- actually put a file there, so "did it appear on disk" is a real question
    for path, _ in pairs(files) do
        local f = io.open(path, "w")
        if f then f:write('<?xml version="1.0"?>\n<routeExport><waypoints c="' .. n .. '"/></routeExport>\n') f:close() end
    end
    files = {}
end

LOG_ECHO = true
AutoDrive.FLYOVER_DEBUG_CAPTURE = true
local jp = H.lock(-863.6, -69.5, { mode="clear", radius=12, leaveThrough=true })
H.apply()

print("---- capture result ----")
print("folders created: " .. #made)
for _, m in ipairs(made) do print("   " .. m) end
print("graph writes: " .. #wrote .. "  (waypoint counts: " .. table.concat(wrote, ", ") .. ")")
