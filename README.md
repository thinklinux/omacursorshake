# Shake to find

Omarchy plugin that magnifies the cursor when you shake the mouse, like
macOS. It wraps [hypr-dynamic-cursors](https://github.com/VirtCode/hypr-dynamic-cursors)
and loads it into Hyprland at runtime. Simulation modes (tilt / rotate /
stretch) are forced off; only shake-to-find zoom is enabled.

It does **not** edit `hyprland.lua` or any other file under `~/.config/hypr/`.
The compositor plugin is built into the state dir, loaded with `hyprctl`, and
re-applied after Hyprland config reloads.

The Omarchy shell starts every login. This plugin rides that process and
re-attaches the compositor plugin each session.

## Install (this machine, no GitHub yet)

From this folder:

```bash
./install.sh
```

That validates the manifest, symlinks the folder into
`~/.config/omarchy/plugins/tvalkanov.omacursorshake`, and enables it on the
right side of the bar.

First enable clones and compiles `hypr-dynamic-cursors` into
`~/.local/state/omarchy/omacursorshake/` (needs git, g++, and the hyprland
headers that already ship with Omarchy). No sudo. After that, shake the mouse.

## Use

- Left-click the bar icon for settings
- Middle-click to toggle

The feature stays on while the widget is enabled, even with the panel closed.
Sensitivity, magnification, hold, and the on/off switch are saved in
`~/.local/state/omarchy/omacursorshake/settings.json` and restored on login.

## Uninstall

```bash
omarchy plugin disable tvalkanov.omacursorshake
rm "$HOME/.config/omarchy/plugins/tvalkanov.omacursorshake"
```

The compiled plugin under `~/.local/state/omarchy/omacursorshake/` can be
deleted too if you want it gone.

## Limits

- x86_64 only (Hyprland function hooks)
- A Hyprland update rebuilds the compositor plugin on next login (stamp
  mismatch). Do not hot-swap the `.so` while Hyprland has it loaded.
- Removing the bar widget disables shake detection; leave it on the bar, or
  we can add a plugins[] pin later
