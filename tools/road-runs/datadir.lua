-- Where the offline harness's map data lives: graph_data.lua (the exported AutoDrive network) and
-- terrain_data/ (the terrain grids, from tools/junction-harness/make_terrain.py). Neither is in git
-- (your own savegame's data). Returns a folder path ending in "/" (or "" for the current folder):
--   1. env JH or FE_DATA, if set;
--   2. this folder, if graph_data.lua is here (the old layout: data inside tools/junction-harness);
--   3. FS25_ADFlyoverEditor_harness_data beside the repo - from the main checkout or from a worktree
--      under .claude/worktrees (moved there 2026-10-15 so worktrees can come and go).
--   local JH = dofile(HERE .. "datadir.lua")(HERE)
return function(here)
    here = here or ""
    local env = os.getenv("JH") or os.getenv("FE_DATA")
    if env ~= nil and env ~= "" then
        if not env:match("[/\]$") then env = env .. "/" end
        return env
    end
    local function has(dir)
        local f = io.open(dir .. "graph_data.lua", "r")
        if f ~= nil then f:close() return true end
        return false
    end
    for _, dir in ipairs({ here, here .. "../junction-harness/", here .. "../../../FS25_ADFlyoverEditor_harness_data/",
        here .. "../../../../../../FS25_ADFlyoverEditor_harness_data/" }) do
        if has(dir) then return dir end
    end
    error("no harness data: set JH to the folder holding graph_data.lua and terrain_data/ "
        .. "(FS25_ADFlyoverEditor_harness_data beside the repo)")
end
