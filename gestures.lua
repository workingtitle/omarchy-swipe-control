-- Swipe Control: trackpad gestures for the io.github.workingtitle.gestures
-- shell plugin.
--
-- Loaded from ~/.config/hypr/input.lua. Settings are written by the plugin's
-- bar popup to ~/.local/state/omarchy/gestures-settings.conf as plain
-- key=value lines, which are parsed, never executed. The plugin calls
-- OmarchyGestures.reload() through `hyprctl eval` after each change, so a
-- settings tweak never needs a full Hyprland reload.
--
-- Hyprland allows one gesture per finger count and axis, so the horizontal
-- swipe cannot mean two things at once. Instead the gesture set is swapped:
-- while a bar popup (layer "omarchy-keyboard-panel") is on screen, left/right
-- step between popups and up closes it; while Mission Control (layer
-- "omarchy-gestures-expose") is on screen, down closes it; otherwise left/right
-- is the 1:1 workspace swipe, up opens Mission Control and down opens a popup.
--
-- The same swipe with Shift held carries the focused window to the
-- neighbouring workspace and follows it. Gestures with modifiers are matched
-- separately, so this never collides with the plain swipe.

local M = {}

local SETTINGS_PATH = (os.getenv("HOME") or "") .. "/.local/state/omarchy/gestures-settings.conf"
local PANEL_NAMESPACE = "omarchy-keyboard-panel"
local EXPOSE_NAMESPACE = "omarchy-gestures-expose"
local IPC = "omarchy-shell -q io.github.workingtitle.gestures "

local DEFAULTS = {
  threeFingers = true,
  fourFingers = false,
  workspaceSwipe = true,
  stopAtLastWorkspace = true,
  swipeUpExpose = true,
  swipeDownPanels = true,
  windowSwipe = true,
  popupArrowKeys = true,
  resizeOnEdges = true,
  shortSwipe = true,
  pinchFullscreen = true,
  pinchMaximize = false,
}

local registered = {}
-- Layer addresses on screen per namespace, and the mode they add up to.
local open_layers = { [PANEL_NAMESPACE] = {}, [EXPOSE_NAMESPACE] = {} }
local mode = "normal"

local function load_settings()
  local settings = {}
  for key, value in pairs(DEFAULTS) do settings[key] = value end

  local file = io.open(SETTINGS_PATH, "r")
  if file then
    for line in file:lines() do
      local key, raw = line:match("^%s*([%a_]+)%s*=%s*(%S+)%s*$")
      local default = key and DEFAULTS[key]
      -- Settings from before three and four fingers could both be on.
      if key == "fingers" and (raw == "3" or raw == "4") then
        settings.threeFingers = raw == "3"
        settings.fourFingers = raw == "4"
      elseif type(default) == "boolean" and (raw == "true" or raw == "false") then
        settings[key] = raw == "true"
      elseif type(default) == "number" and tonumber(raw) then
        settings[key] = tonumber(raw)
      end
    end
    file:close()
  end

  if not settings.threeFingers and not settings.fourFingers then settings.threeFingers = true end
  return settings
end

local function run(cmd)
  return function() hl.dispatch(hl.dsp.exec_cmd(cmd)) end
end

-- The workspace next to the active one on the same monitor, in the direction
-- given, skipping ids that do not exist the way the workspace swipe does.
-- Past the last one this is a fresh workspace: stopAtLastWorkspace is only for
-- the plain swipe, since carrying a window onto a new workspace is useful.
local function neighbour_workspace(direction)
  local active = hl.get_active_workspace()
  if not active or active.id < 1 then return nil end

  local monitor = active.monitor and active.monitor.name
  local best
  for _, ws in ipairs(hl.get_workspaces()) do
    local same_monitor = not monitor or (ws.monitor and ws.monitor.name == monitor)
    if ws.id >= 1 and same_monitor then
      if direction > 0 and ws.id > active.id and (not best or ws.id < best) then best = ws.id end
      if direction < 0 and ws.id < active.id and (not best or ws.id > best) then best = ws.id end
    end
  end

  if best then return best end
  local fresh = active.id + direction
  return fresh >= 1 and fresh or nil
end

local function move_window(direction)
  return function()
    if not hl.get_active_window() then return end
    local target = neighbour_workspace(direction)
    if target then hl.dispatch(hl.dsp.window.move({ workspace = tostring(target) })) end
  end
end

-- Only gestures this file added are unset: Hyprland rejects unsetting one that
-- does not exist, and a user's own gestures on other finger counts stay put.
local function add(fingers, direction, action, mods, extra)
  local spec = { fingers = fingers, direction = direction, action = action, mods = mods }
  for key, value in pairs(extra or {}) do spec[key] = value end
  hl.gesture(spec)
  table.insert(registered, { fingers = fingers, direction = direction, mods = mods })
end

local function clear()
  for _, g in ipairs(registered) do
    hl.gesture({ fingers = g.fingers, direction = g.direction, action = "unset", mods = g.mods })
  end
  registered = {}
end

-- Whether the focused window is fullscreen or maximized right now.
local active_fullscreen = false

local function current_fullscreen()
  local window = hl.get_active_window()
  return window ~= nil and (tonumber(window.fullscreen) or 0) ~= 0
end

-- The whole gesture set for one finger count; three and four fingers can both
-- be on, and then each gets its own copy.
local function apply_fingers(f, s)
  -- Opposite sense to the workspace swipe: the window is dragged along with
  -- the fingers, so fingers right carries it to the workspace on the right.
  if s.windowSwipe then
    add(f, "right", move_window(1), "SHIFT")
    add(f, "left", move_window(-1), "SHIFT")
  end

  -- Spread to go fullscreen, pinch to come back, as on macOS. Hyprland's
  -- fullscreen gesture follows the fingers but only toggles, so only the
  -- direction that fits the focused window is registered.
  if s.pinchFullscreen and mode ~= "expose" then
    add(f, active_fullscreen and "pinchin" or "pinchout", "fullscreen", nil,
      { mode = s.pinchMaximize and "maximize" or "fullscreen" })
  end

  if mode == "expose" then
    -- Workspaces still switch underneath, and Mission Control follows.
    if s.workspaceSwipe then add(f, "horizontal", "workspace") end
    add(f, "down", run(IPC .. "closeExpose"))
    return
  end

  if mode == "popup" and s.swipeDownPanels then
    -- The popups sit in a row along the bar, so they move with the fingers
    -- like a scrolled list: fingers right steps to the popup on the right.
    add(f, "right", run(IPC .. "next"))
    add(f, "left", run(IPC .. "previous"))
    add(f, "up", run(IPC .. "closePanel"))
    return
  end

  if s.workspaceSwipe then add(f, "horizontal", "workspace") end
  if s.swipeUpExpose then add(f, "up", run(IPC .. "expose")) end
  if s.swipeDownPanels then add(f, "down", run(IPC .. "openPanel")) end
end

local function apply()
  clear()
  active_fullscreen = current_fullscreen()

  local s = M.settings
  hl.config({ gestures = { workspace_swipe_create_new = not s.stopAtLastWorkspace } })

  if s.threeFingers then apply_fingers(3, s) end
  if s.fourFingers then apply_fingers(4, s) end
end

-- Omarchy turns blur off globally, and a layer rule cannot blur on its own, so
-- blur is switched on only while Mission Control is on screen and the user's
-- values are put back afterwards.
local EXPOSE_BLUR = { enabled = true, size = 10, passes = 3 }
local saved_blur

local function set_expose_blur(on)
  if on and not saved_blur then
    saved_blur = {}
    for key in pairs(EXPOSE_BLUR) do saved_blur[key] = hl.get_config("decoration.blur." .. key) end
    hl.config({ decoration = { blur = EXPOSE_BLUR } })
  elseif not on and saved_blur then
    hl.config({ decoration = { blur = saved_blur } })
    saved_blur = nil
  end
end

-- While a bar popup is open, SUPER+LEFT/RIGHT step between popups (plain
-- arrows stay with the popup: volume, brightness, calendar month ...).
-- Hyprland would run both bindings of a key, so Omarchy's own window-focus
-- bindings step aside meanwhile and are restored as Omarchy defines them in
-- default/hypr/bindings/tiling.lua.
local POPUP_KEYS = {
  { key = "SUPER + LEFT", ipc = "previous", default = { "Focus on left window", "l" } },
  { key = "SUPER + RIGHT", ipc = "next", default = { "Focus on right window", "r" } },
}
local popup_binds

local function set_popup_keys(on)
  if on and not popup_binds then
    popup_binds = {}
    for _, k in ipairs(POPUP_KEYS) do
      hl.unbind(k.key)
      table.insert(popup_binds, hl.bind(k.key, hl.dsp.exec_cmd(IPC .. k.ipc), { description = "Switch bar popup" }))
    end
  elseif not on and popup_binds then
    for _, keybind in ipairs(popup_binds) do keybind:unbind() end
    popup_binds = nil
    for _, k in ipairs(POPUP_KEYS) do
      hl.bind(k.key, hl.dsp.focus({ direction = k.default[2] }), { description = k.default[1] })
    end
  end
end

local function update_mode()
  local next_mode = "normal"
  if next(open_layers[EXPOSE_NAMESPACE]) then next_mode = "expose"
  elseif next(open_layers[PANEL_NAMESPACE]) then next_mode = "popup" end
  if next_mode == mode then return end
  mode = next_mode
  set_expose_blur(mode == "expose")
  set_popup_keys(mode == "popup" and M.settings.popupArrowKeys)
  apply()
end

-- For `hyprctl repl 'return OmarchyGestures.describe()'`.
function M.describe()
  local parts = {}
  for _, g in ipairs(registered) do table.insert(parts, g.fingers .. ":" .. (g.mods and g.mods .. "+" or "") .. g.direction) end
  return mode .. " " .. table.concat(parts, ",")
end

-- Exposed for testing: `hyprctl repl 'return OmarchyGestures.neighbour_workspace(1)'`.
M.neighbour_workspace = neighbour_workspace

-- Resize windows by dragging their edges and corners, as on macOS. Omarchy
-- turns this off; while the setting is on, it is switched on with a grab zone
-- wide enough to hit the edge inside the gap, and switching the setting off
-- puts the previous values back.
local EDGE_GRAB_AREA = 20
-- Hyprland's corner zone: rounding + border + 10 px, and Omarchy has no
-- rounding.
local EDGE_CORNER = 12
-- A tiled edge this close to the usable area's border sits against the
-- screen edge or the bar and has nothing to trade space with.
local EDGE_SCREEN_TOLERANCE = 40
local saved_edges
local edge_icon
local edge_timer

local function xy(v)
  if type(v) ~= "table" then return 0, 0 end
  return v.x or v[1] or 0, v.y or v[2] or 0
end

-- Hyprland shows the resize cursor on every edge, also where a tiled window
-- touches the screen and cannot be resized. Whether the cursor is on such an
-- edge decides if the resize cursor may show.
local function edge_icon_allowed()
  local cursor = hl.get_cursor_pos()
  local monitor = hl.get_monitor_at_cursor()
  if not cursor or not monitor then return true end

  local workspace = monitor.active_workspace
  local scale = monitor.scale or 1
  local reserved = type(monitor.reserved) == "table" and monitor.reserved or {}
  local area = {
    l = monitor.x + (reserved.left or 0),
    t = monitor.y + (reserved.top or 0),
    r = monitor.x + monitor.width / scale - (reserved.right or 0),
    b = monitor.y + monitor.height / scale - (reserved.bottom or 0),
  }

  local grab = EDGE_GRAB_AREA + (tonumber(hl.get_config("general.border_size")) or 0)
  local cx, cy = cursor.x, cursor.y
  local found
  for _, w in ipairs(hl.get_windows()) do
    if w.mapped and not w.hidden and w.workspace and workspace and w.workspace.id == workspace.id then
      local x, y = xy(w.at)
      local width, height = xy(w.size)
      if cx >= x - grab and cx <= x + width + grab and cy >= y - grab and cy <= y + height + grab then
        if not found or (w.floating and not found.floating) then
          found = { floating = w.floating, x = x, y = y, w = width, h = height }
        end
      end
    end
  end
  if not found or found.floating then return true end

  local f = found
  if cx >= f.x and cx <= f.x + f.w and cy >= f.y and cy <= f.y + f.h then return true end

  local sides = {}
  if cx < f.x + EDGE_CORNER then sides.l = true elseif cx > f.x + f.w - EDGE_CORNER then sides.r = true end
  if cy < f.y + EDGE_CORNER then sides.t = true elseif cy > f.y + f.h - EDGE_CORNER then sides.b = true end

  local stuck = {
    l = f.x - area.l <= EDGE_SCREEN_TOLERANCE,
    r = area.r - (f.x + f.w) <= EDGE_SCREEN_TOLERANCE,
    t = f.y - area.t <= EDGE_SCREEN_TOLERANCE,
    b = area.b - (f.y + f.h) <= EDGE_SCREEN_TOLERANCE,
  }
  -- A corner counts as resizable when either of its sides is.
  for side in pairs(sides) do
    if not stuck[side] then return true end
  end
  return next(sides) == nil
end

local last_cursor

local function update_edge_icon()
  -- Nothing to decide while the pointer rests.
  local cursor = hl.get_cursor_pos()
  local key = cursor and (math.floor(cursor.x) .. "," .. math.floor(cursor.y)) or ""
  if key == last_cursor and edge_icon ~= nil then return end
  last_cursor = key

  local allowed = edge_icon_allowed()
  if allowed == edge_icon then return end
  edge_icon = allowed
  hl.config({ general = { hover_icon_on_border = allowed } })
end

local function set_resize_on_edges(on)
  if on then
    if not saved_edges then
      saved_edges = {
        resize_on_border = hl.get_config("general.resize_on_border"),
        extend_border_grab_area = hl.get_config("general.extend_border_grab_area"),
        hover_icon_on_border = hl.get_config("general.hover_icon_on_border"),
      }
    end
    hl.config({ general = {
      resize_on_border = true,
      extend_border_grab_area = math.max(tonumber(saved_edges.extend_border_grab_area) or 0, EDGE_GRAB_AREA),
    } })
    -- Only worth watching when the resize cursor is wanted at all.
    if saved_edges.hover_icon_on_border ~= false then
      edge_icon = nil
      if edge_timer then edge_timer:set_enabled(true)
      else edge_timer = hl.timer(update_edge_icon, { timeout = 40, type = "repeat" }) end
    end
  elseif saved_edges then
    if edge_timer then edge_timer:set_enabled(false) end
    edge_icon = nil
    hl.config({ general = saved_edges })
    saved_edges = nil
  end
end

-- On macOS a short flick is enough to move on to the next Space. Hyprland
-- snaps back unless the swipe covered half its distance or was fast; the short
-- swipe lowers both thresholds and puts the previous values back when off.
local SHORT_SWIPE = { workspace_swipe_cancel_ratio = 0.3, workspace_swipe_min_speed_to_force = 15 }
local saved_swipe

local function set_short_swipe(on)
  if on then
    if not saved_swipe then
      saved_swipe = {}
      for key in pairs(SHORT_SWIPE) do saved_swipe[key] = hl.get_config("gestures." .. key) end
    end
    hl.config({ gestures = SHORT_SWIPE })
  elseif saved_swipe then
    hl.config({ gestures = saved_swipe })
    saved_swipe = nil
  end
end

function M.reload()
  M.settings = load_settings()
  set_short_swipe(M.settings.shortSwipe)
  set_resize_on_edges(M.settings.resizeOnEdges)
  set_popup_keys(mode == "popup" and M.settings.popupArrowKeys)
  apply()
end

-- Switching popups closes one and opens the next, in either order, so the
-- mode follows the set of layers on screen rather than the last event.
-- The events alone can drift (a layer can close while the shell restarts, and
-- Hyprland reuses addresses), so shortly after each event the tracked set is
-- checked against the layers Hyprland actually has mapped.
local function reconcile()
  for namespace, tracked in pairs(open_layers) do
    local present = {}
    for _, layer in ipairs(hl.get_layers({ namespace = namespace })) do
      if layer.mapped ~= false then present[layer.address] = true end
    end
    for address in pairs(tracked) do
      if not present[address] then tracked[address] = nil end
    end
    for address in pairs(present) do tracked[address] = true end
  end
  update_mode()
end

local function reconcile_soon()
  hl.timer(reconcile, { timeout = 150, type = "oneshot" })
end

-- Focus moving to another window, or a window entering or leaving fullscreen,
-- can flip which pinch direction fits.
local function refresh_pinch()
  if M.settings and M.settings.pinchFullscreen and current_fullscreen() ~= active_fullscreen then apply() end
end

hl.on("window.active", refresh_pinch)
hl.on("window.fullscreen", refresh_pinch)

hl.on("layer.opened", function(layer)
  local tracked = layer and open_layers[layer.namespace]
  if not tracked then return end
  tracked[layer.address] = true
  update_mode()
  reconcile_soon()
  -- Lets the plugin remember popups opened by mouse or hotkey as well.
  if layer.namespace == PANEL_NAMESPACE then run(IPC .. "panelOpened")() end
end)

hl.on("layer.closed", function(layer)
  local tracked = layer and open_layers[layer.namespace]
  if not tracked then return end
  tracked[layer.address] = nil
  update_mode()
  reconcile_soon()
end)

-- Blur what is behind Mission Control, and let it animate itself.
hl.layer_rule({ match = { namespace = EXPOSE_NAMESPACE }, blur = true, no_anim = true, animation = "none" })

M.reload()
-- Popups or Mission Control may already be open when Hyprland reloads.
reconcile_soon()

OmarchyGestures = M
return M
