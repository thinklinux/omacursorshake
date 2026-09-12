# Shake to find

Omarchy plugin that magnifies the cursor when you shake the mouse, like
macOS.

![Shake to find settings](preview.png)

It ships a shake-only Hyprland plugin vendored from
[hypr-dynamic-cursors](https://github.com/VirtCode/hypr-dynamic-cursors)
(MIT). Tilt, rotate, stretch, and shape rules are not compiled. The `.so`
is built from `native/` into `~/.local/state/omarchy/omacursorshake/` and
loaded with `hyprctl`. Settings are re-applied after Hyprland config
reloads.

It does **not** edit `hyprland.lua` or any other file under `~/.config/hypr/`.
It does **not** clone or fetch code at runtime.

The Omarchy shell starts every login. This plugin rides that process and
re-attaches the compositor plugin each session.

## Install

```bash
omarchy plugin add https://github.com/thinklinux/omacursorshake.git --enable
```

First enable compiles the vendored plugin (needs `make`, `g++`, and the
Hyprland headers that already ship with Omarchy). No sudo, no `git` fetch.
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
`.so` under `~/.local/state/omarchy/omacursorshake/` can be deleted too if
you want it gone.

## Limits

- x86_64 only (Hyprland function hooks)
- A Hyprland update rebuilds the compositor plugin on next login (stamp
  mismatch), as does any change to the vendored `native/` tree, the
  build-pipeline generation, or the installed binary's own bytes. Do not
  overwrite the mapped `.so` while Hyprland has it loaded.
- Building needs `/proc` mounted and coreutils 8.28+ (`env --chdir`), which is
  how the source tree is pinned by descriptor across the build.
- Sensitivity, magnification, and hold are range-checked backend-side against
  the same bounds the sliders enforce. A hand-edited `settings.json` outside
  those bounds is refused rather than passed through to the compositor.
- Only one copy of `omacursorshake` can be loaded. Hyprland does not report
  plugin paths. If our `.so` is already mapped into this compositor, that is
  treated as proof and the plugin keeps using it.
- Every component of the state path must be a real directory owned by you (or
  root) and must not be group/other writable without the sticky bit. If
  `~/.local` or `~/.local/state` is group writable, `chmod go-w` it; otherwise
  the plugin refuses to read or publish state rather than risk a swapped
  component. The path itself must not contain `[` or `]`.

## License

MIT. See [LICENSE](LICENSE). The vendored compositor plugin in `native/` is
Virt's MIT license; see [native/LICENSE.md](native/LICENSE.md).
