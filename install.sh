#!/bin/bash
# Local install from a checkout: symlink this folder into Omarchy's plugin
# directory and enable it. For a published copy, use:
#   omarchy plugin add https://github.com/thinklinux/omacursorshake.git --enable

set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
ID=$(jq -r '.id' "$SRC/manifest.json")
# The id becomes a path below; never let it traverse out of the plugin dir.
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo "manifest id is not a safe path component: $ID" >&2
  exit 1
}
DEST="$HOME/.config/omarchy/plugins/$ID"

omarchy plugin validate "$SRC"

mkdir -p "$HOME/.config/omarchy/plugins"
# Drop the previous local id if this checkout was renamed.
if [[ -L $HOME/.config/omarchy/plugins/tvalkanov.omacursorshake ]]; then
  omarchy plugin disable tvalkanov.omacursorshake >/dev/null 2>&1 || true
  rm -f "$HOME/.config/omarchy/plugins/tvalkanov.omacursorshake"
fi
ln -sfn "$SRC" "$DEST"

omarchy-shell -q shell rescanPlugins || true
sleep 0.4
omarchy plugin enable "$ID" --section right

echo "Enabled $ID from $SRC"
echo "The first session builds hypr-dynamic-cursors in the background; shake the mouse once the bar icon undims."
