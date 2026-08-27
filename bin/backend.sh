#!/bin/bash
# Build, load, and configure hypr-dynamic-cursors for Omarchy.
# Never writes ~/.config/hypr/. Settings live in the state JSON; apply.lua
# is eval'd at runtime and after every Hyprland config reload.

set -euo pipefail
export GIT_TERMINAL_PROMPT=0

STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_DIR="$STATE_HOME/omarchy/omacursorshake"
SRC_DIR="$STATE_DIR/src"
SO_PATH="$STATE_DIR/dynamic-cursors.so"
STAMP_PATH="$STATE_DIR/built-for"
SETTINGS_PATH="$STATE_DIR/settings.json"
APPLY_LUA="$STATE_DIR/apply.lua"
REPO_URL="https://github.com/VirtCode/hypr-dynamic-cursors.git"

fail() {
  echo "omacursorshake: $*" >&2
  exit 1
}

hyprland_commit() {
  hyprctl -j version 2>/dev/null | jq -r '.commit // empty'
}

hyprland_version() {
  hyprctl -j version 2>/dev/null | jq -r '.version // empty'
}

# Hyprland commit -> hypr-dynamic-cursors commit (from upstream hyprpm.toml).
plugin_rev_for() {
  local hl="${1:-}"
  case "$hl" in
  efb50993780079460b0cbed1363e2166a2de1d9f) echo "5a224284872208b5324759d535d65061043725de" ;; # 0.56.2
  5c9377c15f85c50648f35ca5a213754f95b93ca0) echo "f5ba36c7622098b53bf62ddb8ddf03b914abbdf8" ;; # 0.56.1
  36b2e0cfe0c6094dbc47bd42a437431315bb3087) echo "f5ba36c7622098b53bf62ddb8ddf03b914abbdf8" ;; # 0.56.0
  a0136d8c04687bb36eb8a28eb9d1ff92aea99704) echo "da447486c84e0be81f2cdd208af1ef92469f0a88" ;; # 0.55.4
  *) echo "main" ;;
  esac
}

plugin_loaded() {
  local list
  list=$(hyprctl -j plugin list 2>/dev/null || echo "[]")
  jq -e --arg so "$SO_PATH" '
    (type == "array" and (
      any(.[]; (
        (.name // .plugin // .handle // "") | tostring | test("dynamic-cursors"; "i")
      ) or (
        (.path // .filename // "") | tostring | contains($so)
      ))
    )) or (type == "object" and ((.name // "") | test("dynamic-cursors"; "i")))
  ' <<<"$list" >/dev/null 2>&1
}

# Replace the directory entry, never truncate a mapped inode.
install_so() {
  local src=$1
  local tmp
  tmp=$(mktemp -p "$(dirname "$SO_PATH")" ".dynamic-cursors.so.XXXXXX")
  cp -f "$src" "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$SO_PATH"
}

# QML FileView writes are async; jobs pass a JSON snapshot as $2 so disable
# cannot race against a stale settings.json.
ingest_settings_json() {
  local raw=${1:-}
  [[ -n $raw ]] || return 0
  mkdir -p "$STATE_DIR"
  jq -e 'type == "object"' <<<"$raw" >/dev/null || fail "settings JSON is invalid"
  printf '%s\n' "$raw" >"$SETTINGS_PATH"
}

write_apply_lua() {
  mkdir -p "$STATE_DIR"
  local enabled threshold base timeout
  if [[ -f $SETTINGS_PATH ]]; then
    enabled=$(jq -r 'if .enabled == false then "false" else "true" end' "$SETTINGS_PATH")
    threshold=$(jq -r '.threshold // 6.0' "$SETTINGS_PATH")
    base=$(jq -r '.base // 4.0' "$SETTINGS_PATH")
    timeout=$(jq -r '.timeout // 2000' "$SETTINGS_PATH")
  else
    enabled=true
    threshold=6.0
    base=4.0
    timeout=2000
  fi

  [[ $enabled == true || $enabled == false ]] || fail "settings.enabled must be boolean"
  [[ $threshold =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "settings.threshold must be a number"
  [[ $base =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "settings.base must be a number"
  [[ $timeout =~ ^[0-9]+$ ]] || fail "settings.timeout must be an integer"

  # mode is a cached variant on the plugin: hl.config() updates the store but
  # not the live mode. Shape rules override mode immediately on the next
  # setShape (any cursor change). Apply them for every protocol shape plus
  # Hyprland's wallpaper name so nothing keeps the default "tilt".
  cat >"$APPLY_LUA" <<EOF
if hl.plugin.dynamic_cursors then
  hl.config({
    plugin = {
      dynamic_cursors = {
        enabled = ${enabled},
        mode = "none",
        shake = {
          enabled = ${enabled},
          threshold = ${threshold},
          base = ${base},
          timeout = ${timeout},
          effects = false,
        },
      },
    },
  })
  local shapes = {
    "clientside", "left_ptr", "default", "context_menu", "help", "pointer",
    "progress", "wait", "cell", "crosshair", "text", "vertical_text", "alias",
    "copy", "move", "no_drop", "not_allowed", "grab", "grabbing",
    "e-resize", "n-resize", "ne-resize", "nw-resize", "s-resize", "se-resize",
    "sw-resize", "w-resize", "ew-resize", "ns-resize", "nesw-resize",
    "nwse-resize", "col-resize", "row-resize", "all-scroll", "zoom-in", "zoom-out",
  }
  for _, s in ipairs(shapes) do
    hl.plugin.dynamic_cursors.shape_rule { shape = s, mode = "none" }
  end
end
EOF
}

eval_apply() {
  write_apply_lua
  hyprctl eval "dofile([[$APPLY_LUA]])" >&2
}

cmd_status() {
  mkdir -p "$STATE_DIR"
  local arch hl_commit hl_ver built loaded so_exists needs
  arch=$(uname -m)
  hl_commit=$(hyprland_commit)
  hl_ver=$(hyprland_version)
  built=""
  [[ -f $STAMP_PATH ]] && built=$(<"$STAMP_PATH")
  so_exists=false
  [[ -f $SO_PATH ]] && so_exists=true
  loaded=false
  plugin_loaded && loaded=true
  needs=false
  if [[ $arch != x86_64 ]]; then
    needs=false
  elif [[ $so_exists != true || -z $built || $built != "$hl_commit" ]]; then
    needs=true
  fi
  jq -n \
    --arg arch "$arch" \
    --argjson supported "$([[ $arch == x86_64 ]] && echo true || echo false)" \
    --arg soPath "$SO_PATH" \
    --argjson soExists "$so_exists" \
    --arg builtFor "$built" \
    --arg hyprlandCommit "$hl_commit" \
    --arg hyprlandVersion "$hl_ver" \
    --arg pluginRev "$(plugin_rev_for "$hl_commit")" \
    --argjson needsRebuild "$needs" \
    --argjson loaded "$loaded" \
    --arg settingsPath "$SETTINGS_PATH" \
    '{
      arch: $arch,
      supported: $supported,
      soPath: $soPath,
      soExists: $soExists,
      builtFor: $builtFor,
      hyprlandCommit: $hyprlandCommit,
      hyprlandVersion: $hyprlandVersion,
      pluginRev: $pluginRev,
      needsRebuild: $needsRebuild,
      loaded: $loaded,
      settingsPath: $settingsPath
    }'
}

ensure_tree() {
  mkdir -p "$STATE_DIR"
  [[ $(uname -m) == x86_64 ]] || fail "hypr-dynamic-cursors only works on x86_64 (Hyprland function hooks)"
  command -v git >/dev/null || fail "git is required to fetch hypr-dynamic-cursors"
  command -v make >/dev/null || fail "make is required to build hypr-dynamic-cursors"
  command -v g++ >/dev/null || fail "g++ is required to build hypr-dynamic-cursors"
  pkg-config --exists hyprland || fail "pkg-config hyprland is missing; install the hyprland package"
}

cmd_ensure() {
  local force=${1:-0}
  ensure_tree
  local hl_commit plugin_rev was_loaded=false
  hl_commit=$(hyprland_commit)
  [[ -n $hl_commit ]] || fail "could not read Hyprland version (is hyprctl available?)"
  plugin_rev=$(plugin_rev_for "$hl_commit")
  plugin_loaded && was_loaded=true

  if (( force == 0 )) && [[ -f $SO_PATH && -f $STAMP_PATH && $(<"$STAMP_PATH") == "$hl_commit" ]]; then
    cmd_status
    return 0
  fi

  echo "omacursorshake: building hypr-dynamic-cursors ($plugin_rev) for Hyprland $hl_commit" >&2

  if [[ ! -d $SRC_DIR/.git ]]; then
    rm -rf "$SRC_DIR"
    git clone --filter=blob:none "$REPO_URL" "$SRC_DIR" >&2
  fi

  git -C "$SRC_DIR" remote set-url origin "$REPO_URL" >&2
  git -C "$SRC_DIR" fetch --tags --force origin >&2
  if ! git -C "$SRC_DIR" checkout --force "$plugin_rev" >&2; then
    git -C "$SRC_DIR" fetch origin "$plugin_rev" >&2
    git -C "$SRC_DIR" checkout --force FETCH_HEAD >&2
  fi

  make -C "$SRC_DIR" all >&2
  [[ -f $SRC_DIR/out/dynamic-cursors.so ]] || fail "build finished but $SRC_DIR/out/dynamic-cursors.so is missing"

  if [[ $was_loaded == true ]]; then
    echo "omacursorshake: plugin is loaded; installing beside the mapped inode" >&2
  fi
  install_so "$SRC_DIR/out/dynamic-cursors.so"
  printf '%s\n' "$hl_commit" >"$STAMP_PATH"
  cmd_status
}

cmd_load() {
  ingest_settings_json "${1:-}"
  [[ -f $SO_PATH ]] || fail "plugin is not built yet"
  if plugin_loaded; then
    eval_apply || true
    cmd_status
    return 0
  fi
  local out
  if ! out=$(hyprctl plugin load "$SO_PATH" 2>&1); then
    if grep -qiE 'already loaded|plugin.*loaded' <<<"$out"; then
      eval_apply || true
      cmd_status
      return 0
    fi
    echo "$out" >&2
    fail "hyprctl plugin load failed"
  fi
  echo "$out" >&2
  eval_apply || true
  cmd_status
}

cmd_unload() {
  ingest_settings_json "${1:-}"
  # Never hyprctl plugin unload while Hyprland is running. Disable via config.
  if plugin_loaded; then
    eval_apply
  else
    write_apply_lua
  fi
  cmd_status
}

cmd_apply() {
  ingest_settings_json "${1:-}"
  if plugin_loaded; then
    eval_apply
  else
    write_apply_lua
  fi
  cmd_status
}

cmd_save() {
  ingest_settings_json "${1:-}"
  [[ -f $SETTINGS_PATH ]] || fail "no settings to save"
  cmd_status
}

cmd_claim() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "${1:-}" >"$STATE_DIR/owner"
}

cmd_unload_if() {
  cmd_status
}

usage() {
  echo "Usage: backend.sh <status|ensure|load|unload|unload-if|claim|apply|save>" >&2
  exit 2
}

cmd=${1:-}
case "$cmd" in
status) cmd_status ;;
ensure) cmd_ensure 0 ;;
load) cmd_load "${2:-}" ;;
unload) cmd_unload "${2:-}" ;;
unload-if) cmd_unload_if "${2:-}" ;;
claim) cmd_claim "${2:-}" ;;
apply) cmd_apply "${2:-}" ;;
save) cmd_save "${2:-}" ;;
*) usage ;;
esac
