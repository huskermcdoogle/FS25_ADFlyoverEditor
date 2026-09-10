--[[
Launch - the two ways a player opens the editor without the developer console.

1. A key binding, declared in modDesc.xml as AD_FLYOVER_TOGGLE so it appears in the game's own
   controls menu and can be rebound. It has to work on foot AND in a vehicle.

   That is the hard part. An action event belongs to the input CONTEXT it was registered in, and the
   context changes under us: on foot is one, a vehicle is another, and the editor pushes its own.
   AutoDrive side-steps this by only registering in the active vehicle, which is exactly why its keys
   do nothing on foot. So this re-registers into whatever context is current each time it changes,
   removing its previous event first so a context that survived the round trip does not end up with
   two - which would open the editor and close it again on the same press.

   If the context cannot be read at all, it falls back to watching for the default key in keyEvent,
   which reaches a mod event listener in every context. That path is not rebindable, so it only runs
   when the proper one has failed, and it says so in the log.

2. A button on AutoDrive's HUD, anchored to its edge using the position AutoDrive publishes on its
   own table (AutoDrive.HudX / HudY) and the live instance's size. It follows the HUD when the player
   drags it. It is only there when AutoDrive's HUD is - which means in a vehicle - so it is the
   discoverable way in, not the only one.
]]

ADFlyoverLaunch = {
    ACTION = "AD_FLYOVER_TOGGLE",
    -- A single press can arrive by more than one route while a context is changing. Anything inside
    -- this window after a toggle is the same press, not a second one.
    DEBOUNCE_MS = 300,
    registeredContext = nil,
    eventId = nil,
    everRegistered = false,
    loggedNoContext = false,
    lastToggleMs = -math.huge,
    buttonRect = nil,
    buttonDrawnAt = -math.huge,
    iconOverlay = nil,
}

local L = ADFlyoverLaunch

--- Image overlays load asynchronously: rendering one before it is ready draws nothing and makes the
--- engine log "renderOverlay called too soon". It asked, by name, for this check.
local function overlayReady(overlay)
    if getIsOverlayReady == nil then
        return true
    end
    local ok, ready = pcall(getIsOverlayReady, overlay)
    return not ok or ready
end

local function nowMs()
    return (g_time ~= nil and g_time) or 0
end

--- Open or close the editor, once per physical press.
function L.toggle(source)
    local t = nowMs()
    if t - L.lastToggleMs < L.DEBOUNCE_MS then
        return
    end
    L.lastToggleMs = t
    if ADFlyoverEditor == nil or ADFlyoverEditor.toggle == nil then
        Logging.warning("[ADFlyoverEditor] %s pressed, but the editor is not loaded.", tostring(source))
        return
    end
    Logging.info("[ADFlyoverEditor] editor toggled from the %s.", tostring(source))
    ADFlyoverEditor:toggle()
end

-- ---------------------------------------------------------------------------------------------
-- The key binding
-- ---------------------------------------------------------------------------------------------

--- The name of the input context that is current right now, or nil when it cannot be read.
--- Tried two ways because this is base-game internals and neither is documented for mods.
local function currentContextName()
    if g_inputBinding == nil then
        return nil
    end
    if type(g_inputBinding.getContextName) == "function" then
        local ok, name = pcall(function() return g_inputBinding:getContextName() end)
        if ok and name ~= nil then
            return name
        end
    end
    local field = rawget(g_inputBinding, "currentContextName")
    if field ~= nil then
        return field
    end
    return nil
end

local function onAction()
    L.toggle("key binding")
end

--- Keep the toggle registered in whatever context is current. Called every frame; does real work
--- only when the context has changed since last time.
function L.update()
    if g_inputBinding == nil or InputAction == nil or InputAction[L.ACTION] == nil then
        return
    end

    local context = currentContextName()
    if context == nil then
        if not L.loggedNoContext then
            L.loggedNoContext = true
            Logging.warning("[ADFlyoverEditor] could not read the current input context, so the %s "
                .. "binding cannot follow it between on-foot and vehicle. Falling back to watching "
                .. "for Left Alt + F directly - that works everywhere but is not rebindable.", L.ACTION)
        end
        return
    end
    if context == L.registeredContext then
        return
    end

    -- Drop the previous registration before making a new one. If the context we left is later
    -- returned to intact, a second registration there would fire twice per press.
    if L.eventId ~= nil then
        pcall(function() g_inputBinding:removeActionEvent(L.eventId) end)
        L.eventId = nil
    end

    local ok, err = pcall(function()
        local _, id = g_inputBinding:registerActionEvent(InputAction[L.ACTION], L, onAction,
            false, true, false, true)
        L.eventId = id
    end)

    L.registeredContext = context
    if ok and L.eventId ~= nil then
        L.everRegistered = true
        -- The key does its job whether or not it is advertised; keeping it out of the help box
        -- stops it cluttering every context for a key most people will press once a session.
        pcall(function() g_inputBinding:setActionEventTextVisibility(L.eventId, false) end)
        Logging.info("[ADFlyoverEditor] %s registered in context '%s'.", L.ACTION, tostring(context))
    else
        Logging.warning("[ADFlyoverEditor] %s could not be registered in context '%s'%s.",
            L.ACTION, tostring(context), err ~= nil and (": " .. tostring(err)) or "")
    end
end

--- The fallback path. keyEvent reaches a mod event listener in every context, which is what makes it
--- usable when the action cannot follow the context - but it can only see the DEFAULT key.
function L.keyEvent(unicode, sym, modifier, isDown)
    if not isDown or L.everRegistered then
        return
    end
    if Input == nil or Input.KEY_f == nil or sym ~= Input.KEY_f then
        return
    end
    local altHeld = Input.MOD_LALT ~= nil and modifier ~= nil and bitAND ~= nil
        and bitAND(modifier, Input.MOD_LALT) ~= 0
    if altHeld then
        L.toggle("fallback key")
    end
end

-- ---------------------------------------------------------------------------------------------
-- The HUD button
-- ---------------------------------------------------------------------------------------------

local function ensureIcon()
    if L.iconOverlay ~= nil then
        return L.iconOverlay ~= false
    end
    local dir = ADFlyoverPrelude ~= nil and ADFlyoverPrelude.MOD_DIRECTORY or nil
    if dir == nil or createImageOverlay == nil then
        L.iconOverlay = false
        return false
    end
    local ok, overlay = pcall(function()
        return createImageOverlay(Utils.getFilename("modIcon.dds", dir))
    end)
    if ok and overlay ~= nil and overlay ~= 0 then
        L.iconOverlay = overlay
        return true
    end
    L.iconOverlay = false
    Logging.warning("[ADFlyoverEditor] could not load modIcon.dds for the HUD button.")
    return false
end

local function mouseOver(rect, x, y)
    return rect ~= nil and x ~= nil and y ~= nil
        and x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h
end

--- Draw the button against the edge of AutoDrive's HUD. Called from the drawHud wrapper, after
--- AutoDrive has drawn, with AutoDrive's own HUD instance - so the position is always this frame's.
function L.drawHudButton(hud)
    if hud == nil or not ensureIcon() then
        return
    end
    -- Nil-guarded throughout: if AutoDrive ever renames these, the button goes missing rather than
    -- taking their HUD down with it.
    local hx, hy = hud.posX or AutoDrive.HudX, hud.posY or AutoDrive.HudY
    local hw, hh = hud.width, hud.height
    if hx == nil or hy == nil or hw == nil or hh == nil then
        return
    end

    local uiScale = (g_gameSettings ~= nil and g_gameSettings:getValue("uiScale")) or 1
    local w, h = getNormalizedScreenValues(44 * uiScale, 44 * uiScale)
    local gapX = getNormalizedScreenValues(6 * uiScale, 0)

    -- Flush to the HUD's left edge and level with its top, so it reads as part of the panel. The
    -- left side because the HUD defaults to the right-hand edge of the screen - on the right there
    -- is nowhere to put it.
    local x = hx - w - gapX
    local y = hy + hh - h
    if x < 0 then
        -- HUD dragged hard against the left edge: go on its right instead of off screen.
        x = hx + hw + gapX
    end

    L.buttonRect = { x = x, y = y, w = w, h = h }
    L.buttonDrawnAt = nowMs()

    local hovering = g_inputBinding ~= nil and g_inputBinding:getShowMouseCursor()
        and mouseOver(L.buttonRect, L.mouseX, L.mouseY)
    local alpha = hovering and 1 or 0.85
    if not overlayReady(L.iconOverlay) then
        return
    end
    setOverlayColor(L.iconOverlay, 1, 1, 1, alpha)
    renderOverlay(L.iconOverlay, x, y, w, h)

    if hovering then
        setTextAlignment(RenderText.ALIGN_RIGHT)
        setTextColor(1, 1, 1, 1)
        renderText(x - gapX, y + h * 0.35, 0.012 * uiScale, "Flyover editor")
        setTextAlignment(RenderText.ALIGN_LEFT)
    end
end

--- Clicks on the button. Only while it has been drawn recently: AutoDrive's HUD disappears when the
--- player leaves the vehicle, and a rectangle remembered from before would otherwise still catch
--- clicks on empty screen.
function L.mouseEvent(posX, posY, isDown, isUp, button)
    L.mouseX, L.mouseY = posX, posY
    if not isDown or L.buttonRect == nil then
        return false
    end
    if nowMs() - L.buttonDrawnAt > 500 then
        return false
    end
    local left = Input ~= nil and Input.MOUSE_BUTTON_LEFT or 1
    if button ~= left then
        return false
    end
    if mouseOver(L.buttonRect, posX, posY) then
        L.toggle("HUD button")
        return true
    end
    return false
end
