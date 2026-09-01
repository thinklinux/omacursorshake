# Shake to find

Omarchy plugin that magnifies the cursor when you shake the mouse, like
macOS.

![Shake to find settings](preview.png)

It wraps [hypr-dynamic-cursors](https://github.com/VirtCode/hypr-dynamic-cursors)
and loads that compositor plugin into Hyprland at runtime. Simulation modes
(tilt / rotate / stretch) are forced off; only shake-to-find zoom is enabled.

It does **not** edit `hyprland.lua` or any other file under `~/.config/hypr/`.
The `.so` is built into `~/.local/state/omarchy/omacursorshake/` and loaded
with `hyprctl`. Settings are re-applied after Hyprland config reloads.

The Omarchy shell starts every login. This plugin rides that process and
re-attaches the compositor plugin each session.

## Install

```bash
omarchy plugin add https://github.com/thinklinux/omacursorshake.git --enable
```

First enable clones and compiles hypr-dynamic-cursors (needs `git`, `make`,
`g++`, and the Hyprland headers that already ship with Omarchy). No sudo.
After that, shake the mouse.

From a local checkout you can instead run `./install.sh`, which symlinks this
folder into `~/.config/omarchy/plugins/` and enables it.

## Use

- Left-click the bar icon for settings
- Middle-click to toggle

The feature stays on while the widget is enabled, even with the panel closed.
Sensitivity, magnification, hold, and the on/off switch are saved in
`~/.local/state/omarchy/omacursorshake/settings.json` and restored on login.

Removing the bar widget disables shake detection. Leave the icon on the bar
if you want it to keep working.

## Uninstall

```bash
omarchy plugin remove io.github.thinklinux.omacursorshake
```

That disables the plugin and deletes the checkout. The compiled
hypr-dynamic-cursors binary under `~/.local/state/omarchy/omacursorshake/`
can be deleted too if you want it gone.

## Limits

- x86_64 only (Hyprland function hooks)
- hypr-dynamic-cursors is fetched at a pinned commit for the running Hyprland
  version. Unsupported Hyprland versions fail instead of building `main`.
- A Hyprland update rebuilds the compositor plugin on next login (stamp
  mismatch). Do not overwrite the mapped `.so` while Hyprland has it loaded.
- Only one copy of hypr-dynamic-cursors can be loaded. Hyprland does not report
  plugin paths, so if another copy is already loaded (typically via `hyprpm`)
  this plugin cannot prove which one is running and refuses to claim it. Run
  `hyprpm remove hypr-dynamic-cursors` and restart the shell.
- Every component of the state path must be a real directory owned by you (or
  root) and must not be group/other writable without the sticky bit. If
  `~/.local` or `~/.local/state` is group writable, `chmod go-w` it; otherwise
  the plugin refuses to read or publish state rather than risk a swapped
  component. The path itself must not contain `[` or `]`.

## License

MIT. See [LICENSE](LICENSE).
