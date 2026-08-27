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
BUILD_LOG="$STATE_DIR/build.log"
REPO_URL="https://github.com/VirtCode/hypr-dynamic-cursors.git"
DIAG_BYTES=2048
CLONE_TIMEOUT=120
FETCH_TIMEOUT=120
CHECKOUT_TIMEOUT=30
MAKE_TIMEOUT=300

fail() {
  {
    printf 'omacursorshake: %s\n' "$*"
    if [[ -s ${BUILD_LOG:-} ]]; then
      printf 'omacursorshake: build log tail:\n'
      tail -c "$DIAG_BYTES" "$BUILD_LOG" || true
    fi
  } | tr -d '\000-\010\013\014\016-\037\177' | tail -c "$DIAG_BYTES" >&2
  exit 1
}

# Run a network/build step with a hard timeout. stdout/stderr stay in BUILD_LOG
# so Quickshell never buffers unbounded git/make output.
run_timed() {
  local secs=$1
  shift
  mkdir -p "$STATE_DIR"
  printf '\n+ [%ss] %s\n' "$secs" "$*" >>"$BUILD_LOG"
  local code=0
  timeout --foreground --signal=TERM --kill-after=8 "$secs" "$@" >>"$BUILD_LOG" 2>&1 || code=$?
  if (( code == 0 )); then
    return 0
  fi
  if (( code == 124 || code == 137 )); then
    fail "timed out after ${secs}s: $*"
  fi
  fail "failed ($code): $*"
}

hyprland_commit() {
  hyprctl -j version 2>/dev/null | jq -r '.commit // empty'
}

hyprland_version() {
  hyprctl -j version 2>/dev/null | jq -r '.version // empty'
}

require_commit_sha() {
  local sha=${1:-}
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || fail "hypr-dynamic-cursors pin must be a 40-character commit SHA (got: ${sha:-empty})"
}

# Hyprland commit -> hypr-dynamic-cursors commit (from upstream hyprpm.toml).
# Unknown Hyprland versions fail; never fall back to a moving branch.
plugin_rev_for() {
  local hl="${1:-}"
  case "$hl" in
  918d8340afd652b011b937d29d5eea0be08467f5) echo "f0409be76564171a97a792deabab3bd0528fe40c" ;; # 0.41.2
  9a09eac79b85c846e3a865a9078a3f8ff65a9259) echo "ddfea3a29c9badf6dabe12be86e4c5ba6d5507ad" ;; # 0.42.0
  0f594732b063a90d44df8c5d402d658f27471dfe) echo "ddfea3a29c9badf6dabe12be86e4c5ba6d5507ad" ;; # 0.43.0
  0c7a7e2d569eeed9d6025f3eef4ea0690d90845d) echo "3ff4c2a053f7673b3b8cd45ada0886cbda13ebcc" ;; # 0.44.0
  4520b30d498daca8079365bdb909a8dea38e8d55) echo "3ff4c2a053f7673b3b8cd45ada0886cbda13ebcc" ;; # 0.44.1
  a425fbebe4cf4238e48a42f724ef2208959d66cf) echo "81f4b964f997a3174596ef22c7a1dee8a5f616c7" ;; # 0.45.0
  500d2a3580388afc8b620b0a3624147faa34f98b) echo "81f4b964f997a3174596ef22c7a1dee8a5f616c7" ;; # 0.45.1
  12f9a0d0b93f691d4d9923716557154d74777b0a) echo "81f4b964f997a3174596ef22c7a1dee8a5f616c7" ;; # 0.45.2
  788ae588979c2a1ff8a660f16e3c502ef5796755) echo "111669a699f998b5eb5a0d5610b5fcb748aab038" ;; # 0.46.0
  254fc2bc6000075f660b4b8ed818a6af544d1d64) echo "111669a699f998b5eb5a0d5610b5fcb748aab038" ;; # 0.46.1
  0bd541f2fd902dbfa04c3ea2ccf679395e316887) echo "111669a699f998b5eb5a0d5610b5fcb748aab038" ;; # 0.46.2
  04ac46c54357278fc68f0a95d26347ea0db99496) echo "261bc1668f7de45b48ba6a40d5d727025575390b" ;; # 0.47.0
  75dff7205f6d2bd437abfb4196f700abee92581a) echo "261bc1668f7de45b48ba6a40d5d727025575390b" ;; # 0.47.1
  882f7ad7d2bbfc7440d0ccaef93b1cdd78e8e3ff) echo "261bc1668f7de45b48ba6a40d5d727025575390b" ;; # 0.47.2
  5ee35f914f921e5696030698e74fb5566a804768) echo "9f40dc905e5b7e00f0c00956a5c2b007b26c50c2" ;; # 0.48.0
  29e2e59fdbab8ed2cc23a20e3c6043d5decb5cdc) echo "2e7ea0224d8de63bb3ffead40e44248321b349bc" ;; # 0.48.1
  9958d297641b5c84dcff93f9039d80a5ad37ab00) echo "0e0e58ca95a58ea44896558409e0a151e7013fc0" ;; # 0.49.0
  c4a4c341568944bd4fb9cd503558b2de602c0213) echo "d6eb0b798c9b07f7f866647c8eb1d75a930501be" ;; # 0.50.0
  4e242d086e20b32951fdc0ebcbfb4d41b5be8dcc) echo "d6eb0b798c9b07f7f866647c8eb1d75a930501be" ;; # 0.50.1
  46174f78b374b6cea669c48880877a8bdcf7802f) echo "acac1f9a5c896ba934af1fc2414670c752ae529d" ;; # 0.51.0
  71a1216abcc7031776630a6d88f105605c4dc1c9) echo "acac1f9a5c896ba934af1fc2414670c752ae529d" ;; # 0.51.1
  f56ec180d3a03a5aa978391249ff8f40f949fb73) echo "8c1679b87c54e97145cae83e622956d720e88bef" ;; # 0.52.0
  967c3c7404d4fa00234e29c70df3e263386d2597) echo "8c1679b87c54e97145cae83e622956d720e88bef" ;; # 0.52.1
  386376400119dd46a767c9f8c8791fd22c7b6e61) echo "8c1679b87c54e97145cae83e622956d720e88bef" ;; # 0.52.2
  ea444c35bb23b6e34505ab6753e069de7801cc25) echo "7e9b7bc9fbcbb2f7f8985ec1f435b43021609639" ;; # 0.53.0
  ab1d80f3d6aebd57a0971b53a1993b1c1dfe0b09) echo "7e9b7bc9fbcbb2f7f8985ec1f435b43021609639" ;; # 0.53.1
  39f3feddbee4a66be9608ed1eb7e73878d596b50) echo "7e9b7bc9fbcbb2f7f8985ec1f435b43021609639" ;; # 0.53.2
  dd220efe7b1e292415bd0ea7161f63df9c95bfd3) echo "7e9b7bc9fbcbb2f7f8985ec1f435b43021609639" ;; # 0.53.3
  0002f148c9a4fe421a9d33c0faa5528cdc411e62) echo "57e14edd0ae265b01828e466e287e96eb1e84dd3" ;; # 0.54.0
  4b07770b9ef1cceb2e6f56d33538aaffb9186b9c) echo "57e14edd0ae265b01828e466e287e96eb1e84dd3" ;; # 0.54.1
  59f9f2688ac508a0584d1462151195a6c4992f99) echo "57e14edd0ae265b01828e466e287e96eb1e84dd3" ;; # 0.54.2
  521ece463c4a9d3d128670688a34756805a4328f) echo "57e14edd0ae265b01828e466e287e96eb1e84dd3" ;; # 0.54.3
  af923e30d1d24f1f4a4f5cb8308065173c1d9539) echo "d195ab3ce94b0c983e04569a613361bff72be3d7" ;; # 0.55.0
  a47147bc095e5b3be3eb8bd04f0ac242b968cd4d) echo "da447486c84e0be81f2cdd208af1ef92469f0a88" ;; # 0.55.1
  39d7e209c79d451efab1b21151d5938289da838d) echo "da447486c84e0be81f2cdd208af1ef92469f0a88" ;; # 0.55.2
  fe5fe79a29ac3adaf3e75560b2f4b7a6d58b31c9) echo "da447486c84e0be81f2cdd208af1ef92469f0a88" ;; # 0.55.3
  a0136d8c04687bb36eb8a28eb9d1ff92aea99704) echo "da447486c84e0be81f2cdd208af1ef92469f0a88" ;; # 0.55.4
  36b2e0cfe0c6094dbc47bd42a437431315bb3087) echo "f5ba36c7622098b53bf62ddb8ddf03b914abbdf8" ;; # 0.56.0
  5c9377c15f85c50648f35ca5a213754f95b93ca0) echo "f5ba36c7622098b53bf62ddb8ddf03b914abbdf8" ;; # 0.56.1
  efb50993780079460b0cbed1363e2166a2de1d9f) echo "5a224284872208b5324759d535d65061043725de" ;; # 0.56.2
  *) echo "" ;;
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
  command -v timeout >/dev/null || fail "timeout (coreutils) is required to bound git/make"
  pkg-config --exists hyprland || fail "pkg-config hyprland is missing; install the hyprland package"
}

cmd_ensure() {
  local force=${1:-0}
  ensure_tree
  local hl_commit plugin_rev was_loaded=false
  hl_commit=$(hyprland_commit)
  [[ -n $hl_commit ]] || fail "could not read Hyprland version (is hyprctl available?)"
  plugin_rev=$(plugin_rev_for "$hl_commit")
  [[ -n $plugin_rev ]] || fail "no pinned hypr-dynamic-cursors commit for Hyprland $hl_commit ($(hyprland_version))"
  require_commit_sha "$plugin_rev"
  plugin_loaded && was_loaded=true

  if (( force == 0 )) && [[ -f $SO_PATH && -f $STAMP_PATH && $(<"$STAMP_PATH") == "$hl_commit" ]]; then
    cmd_status
    return 0
  fi

  echo "omacursorshake: building hypr-dynamic-cursors $plugin_rev for Hyprland $hl_commit" >&2
  : >"$BUILD_LOG"

  if [[ ! -d $SRC_DIR/.git ]]; then
    rm -rf "$SRC_DIR"
    run_timed "$CLONE_TIMEOUT" git clone --filter=blob:none --no-checkout "$REPO_URL" "$SRC_DIR"
  fi

  run_timed "$FETCH_TIMEOUT" git -C "$SRC_DIR" remote set-url origin "$REPO_URL"
  run_timed "$FETCH_TIMEOUT" git -C "$SRC_DIR" fetch --force origin "$plugin_rev"
  run_timed "$CHECKOUT_TIMEOUT" git -C "$SRC_DIR" checkout --detach "$plugin_rev"
  run_timed "$MAKE_TIMEOUT" make -C "$SRC_DIR" all
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
