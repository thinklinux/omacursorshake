#!/bin/bash
# Build, load, and configure hypr-dynamic-cursors for Omarchy.
# Never writes ~/.config/hypr/. Settings live in the state JSON; apply.lua
# is eval'd at runtime and after every Hyprland config reload.

set -euo pipefail
export GIT_TERMINAL_PROMPT=0

HERE=$(cd "$(dirname "$0")" && pwd)
STATEIO="$HERE/stateio.py"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_DIR="$STATE_HOME/omarchy/omacursorshake"
SRC_DIR="$STATE_DIR/src"
SO_PATH="$STATE_DIR/dynamic-cursors.so"
STAMP_PATH="$STATE_DIR/built-for"
SETTINGS_PATH="$STATE_DIR/settings.json"
APPLY_LUA="$STATE_DIR/apply.lua"
BUILD_LOG="$STATE_DIR/build.log"
LOADED_IN_PATH="$STATE_DIR/loaded-in"
REPO_URL="https://github.com/VirtCode/hypr-dynamic-cursors.git"
# Config keys that make git execute a command on our behalf. The source tree
# is re-cloned from scratch on every build so a planted .git cannot reach
# these, but the same-uid actor who could plant one could equally edit
# ~/.gitconfig, and clone applies init.templateDir from there. Global config
# is otherwise left intact so proxy settings keep working.
GIT_SAFE=(
  -c core.hooksPath=/dev/null
  -c init.templateDir=
  -c core.fsmonitor=
  -c core.pager=cat
  -c core.editor=true
  -c core.sshCommand=false
  -c protocol.file.allow=never
  -c protocol.ext.allow=never
)
DIAG_BYTES=2048
LOG_BUDGET=65536
IPC_TIMEOUT=5
IPC_MAX_BYTES=65536
CLONE_TIMEOUT=120
FETCH_TIMEOUT=120
CHECKOUT_TIMEOUT=30
MAKE_TIMEOUT=300

# Strip control characters and keep only the last DIAG_BYTES. tail -c must
# read its whole input, so this never SIGPIPEs an upstream producer.
cap_diag() {
  tr -d '\000-\010\013\014\016-\037\177' | tail -c "$DIAG_BYTES"
}

emit_diag() {
  printf '%s\n' "$*" | cap_diag >&2
}

# Capture at most $1 bytes of stdout under a hard $2-second runtime cap.
# head stops reading at the ceiling and the producer is signalled, so the
# complete response is never buffered in a shell variable first.
capture_bounded() {
  local max=$1 secs=$2
  shift 2
  { timeout --signal=TERM --kill-after=3 "$secs" "$@" </dev/null 2>/dev/null || true; } \
    | head -c "$max"
}

# hyprctl talks to the compositor over a socket: bound both how long it can
# hold us and how much of its answer we will read.
hyprctl_capture() {
  local max=$1
  shift
  capture_bounded "$max" "$IPC_TIMEOUT" hyprctl "$@"
}

# Run a command under the same runtime cap and forward at most DIAG_BYTES of
# its combined output. cap_diag streams, so the producer's bytes are never
# accumulated whole; Quickshell collects this stream for the life of the
# shell, so nothing external is allowed onto stderr unbounded or untimed.
run_diag() {
  local rc=0 had_e=0
  local -a codes=()
  [[ $- == *e* ]] && had_e=1
  set +e
  timeout --signal=TERM --kill-after=3 "$IPC_TIMEOUT" "$@" </dev/null 2>&1 | cap_diag >&2
  codes=("${PIPESTATUS[@]}")
  (( had_e )) && set -e
  rc=${codes[0]:-1}
  return "$rc"
}

# Bounded, control-stripped scalar for anything sourced outside this script.
sanitize_field() {
  local v=${1:-}
  v=${v//[[:cntrl:]]/}
  printf '%s' "${v:0:${2:-128}}"
}

# Used before the tool preflight passes: cannot rely on tr/tail/python3.
fail_plain() {
  printf 'omacursorshake: %s\n' "$*" >&2
  exit 1
}

# The message goes out first so a long log tail can never truncate it away.
fail() {
  emit_diag "omacursorshake: $*"
  if [[ -n ${BUILD_LOG:-} && -n ${STATEIO:-} ]]; then
    local log_tail=""
    log_tail=$(python3 "$STATEIO" read-tail "$BUILD_LOG" "$DIAG_BYTES" 2>/dev/null || true)
    if [[ -n $log_tail ]]; then
      emit_diag "omacursorshake: build log tail:"
      emit_diag "$log_tail"
    fi
  fi
  exit 1
}

# apply.lua is handed to Hyprland as dofile([==[<path>]==]) and every state
# path is also passed to git/make. Refuse anything that could close the Lua
# long bracket or smuggle control characters into the compositor.
require_base_tools() {
  local tool
  for tool in timeout head tr tail jq python3; do
    command -v "$tool" >/dev/null || fail_plain "$tool is required but was not found in PATH"
  done
}

require_safe_state_path() {
  local p=${1:-}
  if [[ $p != /* ]]; then
    fail "state path must be absolute (got: ${p:-empty})"
  fi
  if [[ $p == *"["* || $p == *"]"* ]]; then
    fail "state path must not contain square brackets"
  fi
  if [[ $p =~ [[:cntrl:]] ]]; then
    fail "state path must not contain control characters"
  fi
  if [[ $p == *"/../"* || $p == *"/.." ]]; then
    fail "state path must not contain .."
  fi
}

ensure_state_dir() {
  python3 "$STATEIO" ensure-dir "$STATE_DIR"
}

secure_read() {
  python3 "$STATEIO" read "$1" "${2:-65536}"
}

secure_write() {
  local dest=$1 mode=${2:-0600}
  python3 "$STATEIO" write "$dest" "$mode"
}

cap_output_ring() {
  python3 "$STATEIO" write-ring "$1" "$LOG_BUDGET"
}

# Timeout plus a hard on-disk byte ceiling. The log file never grows past
# LOG_BUDGET while git/make run; extra output fails the phase.
#
# No --foreground on purpose: timeout then runs the command in its own
# process group and signals the whole group on expiry. With --foreground
# only the direct child is signalled, and a surviving grandchild (a compiler
# under make, a helper under git) keeps the capture pipe open, so the reader
# blocks forever and the timeout buys nothing.
run_timed() {
  local secs=$1
  shift
  ensure_state_dir
  local tcode=0 capcode=0
  local -a codes=()
  set +e
  timeout --signal=TERM --kill-after=8 "$secs" "$@" </dev/null 2>&1 \
    | cap_output_ring "$BUILD_LOG"
  # Snapshot both stages at once: any command in between, an assignment
  # included, replaces PIPESTATUS.
  codes=("${PIPESTATUS[@]}")
  set -e
  tcode=${codes[0]:-1}
  capcode=${codes[1]:-1}
  if (( capcode == 2 )); then
    fail "output exceeded ${LOG_BUDGET}-byte budget: $*"
  fi
  if (( capcode != 0 )); then
    fail "failed to capture output ($capcode): $*"
  fi
  if (( tcode == 0 )); then
    return 0
  fi
  if (( tcode == 124 || tcode == 137 )); then
    fail "timed out after ${secs}s: $*"
  fi
  fail "failed ($tcode): $*"
}

hyprland_field() {
  local raw=""
  raw=$(hyprctl_capture "$IPC_MAX_BYTES" -j version | jq -r "$1 // empty" 2>/dev/null || true)
  sanitize_field "$raw" "$2"
}

hyprland_commit() {
  hyprland_field .commit 64
}

hyprland_version() {
  hyprland_field .version 128
}

# Identity of the running compositor instance. A recorded load is evidence
# only for the instance it happened in: a Hyprland restart drops every loaded
# plugin, and the signature changes with it, so a stale record stops matching
# on its own and needs no cleanup.
hyprland_instance() {
  local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
  if [[ -z $sig ]]; then
    # hyprctl itself falls back to the runtime directory when the variable is
    # missing. Only an unambiguous single instance counts; anything else stays
    # empty and leaves the load unproven.
    local runtime="${XDG_RUNTIME_DIR:-}" dir="" count=0
    if [[ -n $runtime && -d $runtime/hypr ]]; then
      for dir in "$runtime"/hypr/*/; do
        [[ -d $dir ]] || continue
        count=$((count + 1))
        dir=${dir%/}
        sig=${dir##*/}
      done
      (( count == 1 )) || sig=""
    fi
  fi
  sanitize_field "$sig" 128
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

recorded_instance() {
  local v=""
  v=$(secure_read "$LOADED_IN_PATH" 256 2>/dev/null || true)
  sanitize_field "${v//$'\n'/}" 128
}

# Remember that *we* loaded the .so, and into which compositor instance.
record_load() {
  ensure_state_dir
  printf '%s\n' "$(hyprland_instance)" | secure_write "$LOADED_IN_PATH"
}

# Three-valued, because the truth is three-valued:
#
#   mine    - proven ours: the compositor reports a path that is our .so, or a
#             name matches and we recorded a confirmed load in this same
#             compositor instance.
#   unknown - something matching is loaded, but nothing proves it is ours.
#   none    - nothing matching is loaded.
#
# Hyprland 0.56 reports only name/author/handle/version, so the path branch is
# unreachable there and a bare name match cannot tell our .so from an hyprpm
# install of the same upstream plugin. A name match alone must therefore never
# resolve to "mine" -- that is what let a failed load report success.
#
# Piped straight into jq: no shell variable holds the response. Empty input (no
# compositor, timeout, byte ceiling hit) yields "none", so callers fail closed.
plugin_state() {
  local listed="" inst=""
  listed=$(hyprctl_capture "$IPC_MAX_BYTES" -j plugin list \
    | jq -r --arg so "$SO_PATH" '
    def entries: if type == "array" then .[] elif type == "object" then . else empty end;
    def pathof: (.path // .filename // "") | tostring;
    def nameof: (.name // .plugin // .handle // "") | tostring;
    if any(entries; pathof != "" and (pathof | contains($so))) then "mine"
    elif any(entries; nameof | test("dynamic-cursors"; "i")) then "unknown"
    else "none"
    end
  ' 2>/dev/null || true)
  listed=$(sanitize_field "$listed" 16)
  case "$listed" in
  mine) printf 'mine\n' ;;
  unknown)
    inst=$(hyprland_instance)
    if [[ -n $inst && $inst == "$(recorded_instance)" ]]; then
      printf 'mine\n'
    else
      printf 'unknown\n'
    fi
    ;;
  *) printf 'none\n' ;;
  esac
}

# Proven ours. Gate every action that assumes we own the loaded plugin.
plugin_is_mine() {
  [[ $(plugin_state) == mine ]]
}

# Anything matching is loaded, ours or not. Only for decisions that must be
# conservative about a possibly-mapped .so.
plugin_present() {
  [[ $(plugin_state) != none ]]
}

# Replace the directory entry, never truncate a mapped inode.
# The compiler output is a predictable path: read it without following
# a symlink, then publish the bytes through a same-directory temporary.
install_so() {
  local src=$1
  ensure_state_dir
  python3 "$STATEIO" copy "$src" "$SO_PATH" 0755
}

# QML FileView writes are async; jobs pass a JSON snapshot as $2 so disable
# cannot race against a stale settings.json.
ingest_settings_json() {
  local raw=${1:-}
  [[ -n $raw ]] || return 0
  (( ${#raw} <= 65536 )) || fail "settings JSON exceeds 65536 bytes"
  ensure_state_dir
  jq -e 'type == "object"' <<<"$raw" >/dev/null || fail "settings JSON is invalid"
  printf '%s\n' "$raw" | secure_write "$SETTINGS_PATH"
}

write_apply_lua() {
  ensure_state_dir
  local enabled threshold base timeout raw
  raw=$(secure_read "$SETTINGS_PATH" 65536 || true)
  if [[ -n $raw ]]; then
    enabled=$(jq -r 'if .enabled == false then "false" else "true" end' <<<"$raw")
    threshold=$(jq -r '.threshold // 6.0' <<<"$raw")
    base=$(jq -r '.base // 4.0' <<<"$raw")
    timeout=$(jq -r '.timeout // 2000' <<<"$raw")
  else
    enabled=true
    threshold=6.0
    base=4.0
    timeout=2000
  fi

  # Shape and range: a hand-edited settings.json bypasses the QML clamps, and
  # the regexes alone would accept an arbitrarily long digit string.
  [[ $enabled == true || $enabled == false ]] || fail "settings.enabled must be boolean"
  [[ $threshold =~ ^[0-9]{1,3}([.][0-9]{1,3})?$ ]] || fail "settings.threshold must be a number"
  [[ $base =~ ^[0-9]{1,3}([.][0-9]{1,3})?$ ]] || fail "settings.base must be a number"
  [[ $timeout =~ ^[0-9]{1,6}$ ]] || fail "settings.timeout must be an integer"
  (( timeout >= 100 && timeout <= 60000 )) || fail "settings.timeout must be 100-60000 ms"

  # Default simulation mode is tilt. hl.config() updates the Hyprlang store
  # but CVariantProp keeps the live MODE until activate() (setShape or a
  # config reload). Shape rules force mode=none (and zero tilt) on every
  # protocol/xcursor name Hyprland actually uses, including wallpaper
  # left_ptr. eval_apply then reloads the cursor so activate() runs now.
  local lua
  lua=$(cat <<EOF
if hl.plugin.dynamic_cursors then
  hl.config({
    plugin = {
      dynamic_cursors = {
        enabled = ${enabled},
        mode = "none",
        tilt = { full = 0 },
        rotate = { length = 0 },
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
    "X_cursor", "xterm", "hand1", "hand2", "watch", "fleur", "pirate",
    "sb_h_double_arrow", "sb_v_double_arrow", "sb_left_arrow", "sb_right_arrow",
    "sb_up_arrow", "sb_down_arrow", "top_left_corner", "top_right_corner",
    "bottom_left_corner", "bottom_right_corner", "left_side", "right_side",
    "top_side", "bottom_side", "sizing", "circle", "plus", "pencil",
    "cross", "crossed_circle", "dnd-move", "dnd-copy", "dnd-link", "dnd-none",
    "dnd-no-drop", "center_ptr", "arrow", "right_ptr",
  }
  for _, s in ipairs(shapes) do
    hl.plugin.dynamic_cursors.shape_rule {
      shape = s,
      mode = "none",
      tilt = { full = 0 },
      rotate = { length = 0 },
    }
  end
end
EOF
)
  printf '%s\n' "$lua" | secure_write "$APPLY_LUA"
}

# Reload the cursor manager so dynamic-cursors activate() runs against the
# rules we just published. Without this, mode stays at the default "tilt"
# until the pointer happens to change shape.
force_cursor_activate() {
  local theme size
  theme=${HYPRCURSOR_THEME:-${XCURSOR_THEME:-}}
  if [[ -z $theme || $theme == default ]]; then
    theme=$(capture_bounded 256 5 gsettings get org.gnome.desktop.interface cursor-theme | tr -d "'")
  fi
  if [[ -z $theme || $theme == default ]]; then
    theme=Adwaita
  fi
  theme=$(sanitize_field "$theme" 128)
  # Allowlist, not just a control-character strip: a leading '-' would reach
  # hyprctl as an option rather than a cursor theme name.
  [[ $theme =~ ^[A-Za-z0-9_.][A-Za-z0-9_.\ -]*$ ]] || theme=Adwaita
  size=${HYPRCURSOR_SIZE:-${XCURSOR_SIZE:-24}}
  [[ $size =~ ^[0-9]+$ ]] || size=24
  run_diag hyprctl setcursor "$theme" "$size" || true
}

eval_apply() {
  write_apply_lua
  run_diag hyprctl eval "dofile([==[$APPLY_LUA]==])"
  force_cursor_activate
}

cmd_status() {
  ensure_state_dir
  local arch hl_commit hl_ver built loaded so_exists needs
  arch=$(capture_bounded 64 5 uname -m)
  hl_commit=$(hyprland_commit)
  hl_ver=$(hyprland_version)
  built=$(secure_read "$STAMP_PATH" 128 || true)
  built=$(sanitize_field "${built//$'\n'/}" 64)
  so_exists=false
  python3 "$STATEIO" exists "$SO_PATH" && so_exists=true
  loaded=false
  # Only a proven-ours plugin counts as loaded. "unknown" is reported as false
  # rather than dressed up as success.
  plugin_is_mine && loaded=true
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
  ensure_state_dir
  [[ $(capture_bounded 64 5 uname -m) == x86_64 ]] || fail "hypr-dynamic-cursors only works on x86_64 (Hyprland function hooks)"
  command -v git >/dev/null || fail "git is required to fetch hypr-dynamic-cursors"
  command -v make >/dev/null || fail "make is required to build hypr-dynamic-cursors"
  command -v g++ >/dev/null || fail "g++ is required to build hypr-dynamic-cursors"
  command -v timeout >/dev/null || fail "timeout (coreutils) is required to bound git/make"
  command -v python3 >/dev/null || fail "python3 is required to cap build-log size"
  pkg-config --exists hyprland || fail "pkg-config hyprland is missing; install the hyprland package"
}

# The tree we are about to compile must be exactly the pinned commit, with
# nothing extra in it for make to pick up.
verify_source_tree() {
  local want=$1 head="" dirty=""
  head=$(capture_bounded 128 "$CHECKOUT_TIMEOUT" \
    git "${GIT_SAFE[@]}" -C "$SRC_DIR" rev-parse HEAD)
  head=$(sanitize_field "$head" 64)
  [[ $head == "$want" ]] || fail "checkout is '${head:-empty}', expected the pinned $want"
  dirty=$(capture_bounded 4096 "$CHECKOUT_TIMEOUT" \
    git "${GIT_SAFE[@]}" -C "$SRC_DIR" status --porcelain --untracked-files=all)
  [[ -z $dirty ]] || fail "source tree is not clean after checkout; refusing to build"
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
  # Conservative on purpose: any matching plugin may have our .so mapped.
  plugin_present && was_loaded=true

  local built_for=""
  built_for=$(secure_read "$STAMP_PATH" 128 || true)
  built_for=$(sanitize_field "${built_for//$'\n'/}" 64)
  if (( force == 0 )) && python3 "$STATEIO" exists "$SO_PATH" && [[ $built_for == "$hl_commit" ]]; then
    cmd_status
    return 0
  fi

  emit_diag "omacursorshake: building hypr-dynamic-cursors $plugin_rev for Hyprland $hl_commit"

  # Always rebuild the tree from scratch. Reusing whatever sits in $SRC_DIR
  # let a same-uid process pre-plant git hooks, executable git config, or an
  # untracked GNUmakefile -- which GNU make prefers over Makefile and which
  # survives checkout -- and so reach `make` and then the compositor dlopen.
  python3 "$STATEIO" rm-tree "$STATE_DIR" src
  run_timed "$CLONE_TIMEOUT" git "${GIT_SAFE[@]}" clone \
    --filter=blob:none --no-checkout "$REPO_URL" "$SRC_DIR"
  python3 "$STATEIO" ensure-dir "$SRC_DIR"

  run_timed "$FETCH_TIMEOUT" git "${GIT_SAFE[@]}" -C "$SRC_DIR" fetch --force origin "$plugin_rev"
  run_timed "$CHECKOUT_TIMEOUT" git "${GIT_SAFE[@]}" -C "$SRC_DIR" checkout --detach "$plugin_rev"
  verify_source_tree "$plugin_rev"
  # -f Makefile: never let a GNUmakefile take precedence.
  run_timed "$MAKE_TIMEOUT" make -f Makefile -C "$SRC_DIR" all
  python3 "$STATEIO" exists "$SRC_DIR/out/dynamic-cursors.so" \
    || fail "build finished but $SRC_DIR/out/dynamic-cursors.so is missing or not a regular file"

  if [[ $was_loaded == true ]]; then
    emit_diag "omacursorshake: plugin is loaded; installing beside the mapped inode"
  fi
  install_so "$SRC_DIR/out/dynamic-cursors.so"
  printf '%s\n' "$hl_commit" | secure_write "$STAMP_PATH"
  cmd_status
}

cmd_load() {
  ingest_settings_json "${1:-}"
  python3 "$STATEIO" exists "$SO_PATH" || fail "plugin is not built yet"

  local state=""
  state=$(plugin_state)

  if [[ $state == unknown ]]; then
    # Refuse rather than guess. Loading a second copy would be rejected by the
    # compositor, and pushing our config into someone else's plugin would make
    # us a confused deputy for a build we never verified.
    fail "a dynamic-cursors plugin is already loaded that we cannot prove is ours; remove the other copy (hyprpm remove hypr-dynamic-cursors) and retry"
  fi

  if [[ $state == none ]]; then
    local load_rc=0
    run_diag hyprctl plugin load "$SO_PATH" || load_rc=$?
    # hyprctl's exit status is the only signal that proves *our* load: the
    # listing carries no path on current Hyprland, so a name match cannot
    # distinguish our .so from anyone else's. It is a hard gate, not a hint.
    (( load_rc == 0 )) || fail "hyprctl plugin load failed (exit ${load_rc})"
    record_load
    # Second, independent signal: the compositor must now actually list it.
    plugin_present || fail "hyprctl reported success but no matching plugin is listed"
    # The load is confirmed either way; only the durable ownership record needs
    # an instance identity. Say so plainly instead of reporting a false load
    # failure, or worse, claiming a load we cannot stand behind later.
    plugin_is_mine || emit_diag "omacursorshake: loaded, but this compositor instance has no identity (HYPRLAND_INSTANCE_SIGNATURE unset); status will keep reporting not-loaded"
  fi

  eval_apply || true
  cmd_status
}

cmd_unload() {
  ingest_settings_json "${1:-}"
  # Never hyprctl plugin unload while Hyprland is running. Disable via config.
  # Only eval into a plugin we own; otherwise just publish the file.
  if plugin_is_mine; then
    eval_apply
  else
    write_apply_lua
  fi
  cmd_status
}

cmd_apply() {
  ingest_settings_json "${1:-}"
  if plugin_is_mine; then
    eval_apply
  else
    write_apply_lua
  fi
  cmd_status
}

cmd_save() {
  ingest_settings_json "${1:-}"
  python3 "$STATEIO" exists "$SETTINGS_PATH" || fail "no settings to save"
  cmd_status
}

cmd_claim() {
  ensure_state_dir
  printf '%s\n' "$(sanitize_field "${1:-}" 128)" | secure_write "$STATE_DIR/owner"
}

cmd_unload_if() {
  cmd_status
}

usage() {
  echo "Usage: backend.sh <status|ensure|load|unload|unload-if|claim|apply|save>" >&2
  exit 2
}

require_base_tools
require_safe_state_path "$STATE_DIR"

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
