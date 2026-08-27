#!/bin/bash
# Local install: symlink this folder into Omarchy's plugin directory and enable it.
# Does not need a git remote. omarchy plugin add is for GitHub later.

set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
ID=$(jq -r '.id' "$SRC/manifest.json")
DEST="$HOME/.config/omarchy/plugins/$ID"

omarchy plugin validate "$SRC"

mkdir -p "$HOME/.config/omarchy/plugins"
ln -sfn "$SRC" "$DEST"

omarchy-shell -q shell rescanPlugins || true
sleep 0.4
omarchy plugin enable "$ID" --section right

echo "Enabled $ID from $SRC"
echo "The first session builds hypr-dynamic-cursors in the background; shake the mouse once the bar icon undims."
