-- LOAD THE EDITOR, the way the game does: every file Prelude sources from FlyoverEditor.lua on, in
-- Prelude's order (P.EDITOR_FILES). Today that is FlyoverEditor.lua alone; once it is split into
-- modules (docs/editor-modules-spec.md) the modules follow it in that list, and offline loads exactly
-- the files the game loads. The files before it in the list (the HUD, the theme, the swept-path sim...)
-- are the harness's to stub or load, as before.
--   dofile("editor_load.lua")()
-- FE_SRC=<file> loads that one file instead: an older copy of FlyoverEditor.lua, or a bundle of all
-- the editor's modules in one file (tools/modsplit/bundle.py) - how an A/B comparison runs a build
-- that is not the working tree's.
return function()
    local src = os.getenv("FE_SRC")
    if src ~= nil and src ~= "" then
        dofile(src)
        return
    end
    local f = assert(io.open("../../scripts/Prelude.lua", "r"))
    local txt = f:read("*a")
    f:close()
    local list = assert(txt:match("P%.EDITOR_FILES%s*=%s*(%b{})"), "Prelude.lua: no P.EDITOR_FILES list")
    local on = false
    -- road runs and the multi-point spline (1.0.3.0) lean on two files listed before FlyoverEditor.lua
    -- that the harness does not stub: load them as the game does
    for _, early in ipairs({ { "ADRoadFinder", "scripts/editor/RoadFinder.lua" }, { "ADSplinePath", "scripts/editor/SplinePath.lua" } }) do
        if _G[early[1]] == nil and list:find(early[2], 1, true) then dofile("../../" .. early[2]) end
    end
    for path in list:gmatch('"([^"]+)"') do
        if path == "scripts/editor/FlyoverEditor.lua" then on = true end
        if on then dofile("../../" .. path) end
    end
    assert(on, "Prelude.lua: FlyoverEditor.lua is not in P.EDITOR_FILES")
end
