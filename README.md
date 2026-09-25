# Trackpad Gestures for Omarchy

macOS-style trackpad gestures for Omarchy: swipe between workspaces, carry the
focused window along, open the Omarchy menu, and swipe through the popups in
the bar. A bar icon opens the settings.

![Trackpad Gestures settings popup](preview.png)

| Gesture (default: three fingers) | Normally | While a bar popup is open |
|---|---|---|
| Left / right | Switch workspace, following your fingers 1:1 | Step to the neighbouring popup |
| Up | Open the Omarchy menu | Close the popup |
| Down | Open a popup from the right of the bar (last used, or the first) | — |
| Four fingers left / right | Move the focused window to the neighbouring workspace and follow it | same |

When the main gesture uses four fingers, the window gesture uses three.

## Requirements

- Omarchy with the plugin-capable shell and Hyprland 0.55 or newer (Lua config)
- A touchpad with multi-finger gestures

## Install

```sh
omarchy plugin add https://github.com/workingtitle/omarchy-gestures.git --enable
```

Hyprland does not load shell plugins, so its gestures are set up by
`gestures.lua` from this plugin. Load it from `~/.config/hypr/input.lua`:

```lua
do
  local gestures = os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.workingtitle.gestures/gestures.lua"
  local ok, err = pcall(dofile, gestures)
  if not ok then print("trackpad gestures: " .. tostring(err)) end
end
```

Remove any `hl.gesture(...)` lines for the same finger counts from your config;
Hyprland rejects a second gesture on the same fingers and direction.

## Settings

Click the icon in the bar. Changes apply at once. They are stored on the
widget's entry in `~/.config/omarchy/shell.json` and mirrored for Hyprland to
`~/.local/state/omarchy/gestures-settings.lua`.

| Key | Default | Meaning |
|---|---|---|
| `fingers` | `3` | Fingers for the main gestures (3 or 4) |
| `workspaceSwipe` | `true` | Left/right switches workspaces |
| `stopAtLastWorkspace` | `true` | Stop at the last workspace instead of creating an empty one |
| `swipeUpMenu` | `true` | Up opens the Omarchy menu |
| `swipeDownPanels` | `true` | Down opens bar popups; left/right then moves between them |
| `startPanel` | `"last"` | Popup that down opens: `"last"` used or `"first"` |
| `windowSwipe` | `true` | The other finger count moves the focused window |

## How it works

Hyprland allows only one gesture per finger count and direction, so
`gestures.lua` swaps the gesture set whenever a bar popup (layer
`omarchy-keyboard-panel`) opens or closes. Popup navigation runs through the
plugin's IPC target:

```sh
omarchy-shell io.github.workingtitle.gestures openPanel|next|previous|closePanel|current
```

To see which gestures are active:

```sh
hyprctl repl 'return OmarchyGestures.describe()'
```

The shell's plugin API does not expose other widgets' popups, so the plugin
finds them through the bar's module slots. A larger change to the Omarchy bar
can break popup navigation; workspace and window swipes do not depend on it.

## License

MIT
