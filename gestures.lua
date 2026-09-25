-- Trackpad gestures for the io.github.workingtitle.gestures shell plugin.
--
-- Loaded from ~/.config/hypr/input.lua. Settings are written by the plugin's
-- bar popup to ~/.local/state/omarchy/gestures-settings.lua; the plugin calls
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

local SETTINGS_PATH = (os.getenv("HOME") or "") .. "/.local/state/omarchy/gestures-settings.lua"
local PANEL_NAMESPACE = "omarchy-keyboard-panel"
local EXPOSE_NAMESPACE = "omarchy-gestures-expose"
local IPC = "omarchy-shell -q io.github.workingtitle.gestures "

local DEFAULTS = {
  fingers = 3,
  workspaceSwipe = true,
  stopAtLastWorkspace = true,
  swipeUpExpose = true,
  swipeDownPanels = true,
  windowSwipe = true,
}

local registered = {}
-- Layer addresses on screen per namespace, and the mode they add up to.
local open_layers = { [PANEL_NAMESPACE] = {}, [EXPOSE_NAMESPACE] = {} }
local mode = "normal"

local function load_settings()
  local settings = {}
  for key, value in pairs(DEFAULTS) do settings[key] = value end

  local ok, loaded = pcall(dofile, SETTINGS_PATH)
  if ok and type(loaded) == "table" then
    for key, value in pairs(loaded) do
      if DEFAULTS[key] ~= nil and type(value) == type(DEFAULTS[key]) then settings[key] = value end
    end
  end

  if settings.fingers ~= 3 and settings.fingers ~= 4 then settings.fingers = DEFAULTS.fingers end
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
local function add(fingers, direction, action, mods)
  hl.gesture({ fingers = fingers, direction = direction, action = action, mods = mods })
  table.insert(registered, { fingers = fingers, direction = direction, mods = mods })
end

local function clear()
  for _, g in ipairs(registered) do
    hl.gesture({ fingers = g.fingers, direction = g.direction, action = "unset", mods = g.mods })
  end
  registered = {}
end

local function apply()
  clear()

  local s = M.settings
  local f = s.fingers

  hl.config({ gestures = { workspace_swipe_create_new = not s.stopAtLastWorkspace } })

  -- Opposite sense to the workspace swipe: the window is dragged along with
  -- the fingers, so fingers right carries it to the workspace on the right.
  if s.windowSwipe then
    add(f, "right", move_window(1), "SHIFT")
    add(f, "left", move_window(-1), "SHIFT")
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

local function update_mode()
  local next_mode = "normal"
  if next(open_layers[EXPOSE_NAMESPACE]) then next_mode = "expose"
  elseif next(open_layers[PANEL_NAMESPACE]) then next_mode = "popup" end
  if next_mode == mode then return end
  mode = next_mode
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

function M.reload()
  M.settings = load_settings()
  apply()
end

-- Switching popups closes one and opens the next, in either order, so the
-- mode follows the set of layers on screen rather than the last event.
hl.on("layer.opened", function(layer)
  local tracked = layer and open_layers[layer.namespace]
  if not tracked then return end
  tracked[layer.address] = true
  update_mode()
  -- Lets the plugin remember popups opened by mouse or hotkey as well.
  if layer.namespace == PANEL_NAMESPACE then run(IPC .. "panelOpened")() end
end)

hl.on("layer.closed", function(layer)
  local tracked = layer and open_layers[layer.namespace]
  if not tracked then return end
  tracked[layer.address] = nil
  update_mode()
end)

-- Blur what is behind Mission Control, and let it animate itself.
hl.layer_rule({ match = { namespace = EXPOSE_NAMESPACE }, blur = true, no_anim = true, animation = "none" })

M.reload()

OmarchyGestures = M
return M
