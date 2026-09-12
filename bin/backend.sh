#!/bin/bash
# Build, load, and configure the vendored shake-only Hyprland plugin.
# Never writes ~/.config/hypr/. Settings live in the state JSON; apply.lua
# is eval'd at runtime and after every Hyprland config reload.

set -euo pipefail

# Resolve through the plugin-dir symlink that `./install.sh` creates.
# Logical `pwd` would keep ~/.config/omarchy/plugins/<id>, and tree-digest
# then refuses that symlink component. Physical paths are the project tree.
HERE=$(cd -P "$(dirname "$0")" && pwd -P)
PLUGIN_ROOT=$(cd -P "$HERE/.." && pwd -P)
STATEIO="$HERE/stateio.py"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
STATE_DIR="$STATE_HOME/omarchy/omacursorshake"
# Collapse repeated separators before anything is derived from this string.
# A trailing slash in XDG_STATE_HOME leaves a "//" that os.path.abspath and
# the kernel both normalize away, so every file operation kept working and the
# plugin looked healthy -- but so_is_mapped compares SO_PATH literally against
# /proc/<pid>/maps, which is always canonical, so that one comparison could
# never match and the mapped-.so ownership proof silently did nothing.
# One pass only rewrites non-overlapping pairs, so "///" needs the loop.
while [[ $STATE_DIR == *//* ]]; do STATE_DIR=${STATE_DIR//\/\//\/}; done
NATIVE_DIR="${OMACURSORSHAKE_NATIVE:-$PLUGIN_ROOT/native}"
SO_PATH="$STATE_DIR/omacursorshake.so"
STAMP_PATH="$STATE_DIR/built-for"
SETTINGS_PATH="$STATE_DIR/settings.json"
APPLY_LUA="$STATE_DIR/apply.lua"
BUILD_LOG="$STATE_DIR/build.log"
LOADED_IN_PATH="$STATE_DIR/loaded-in"
# Generation of the build-and-attest pipeline. The stamp records it alongside
# the digests, and cmd_ensure refuses to reuse an .so that was not produced by
# the current generation. Bump this whenever a change to the build path makes
# an older artifact no longer trustworthy.
PIPELINE_VERSION=3
DIAG_BYTES=2048
LOG_BUDGET=65536
IPC_TIMEOUT=5
IPC_MAX_BYTES=65536
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
  # Enforces the invariant the normalization above establishes, so that if that
  # step is ever removed the mapped-.so proof fails loudly here instead of
  # silently never matching.
  if [[ $p == *"//"* ]]; then
    fail "state path must not contain repeated separators"
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

# Inclusive decimal range check. Bash has no float comparison; the caller's
# shape regex guarantees at most 3 integer and 3 fraction digits, so scale
# both parts to thousandths and compare as integers. 10# keeps a leading-zero
# field ("050") decimal rather than an invalid octal literal.
require_range() {
  local name=$1 v=$2 lo=$3 hi=$4 int frac scaled
  int=${v%%.*}
  frac=000
  if [[ $v == *.* ]]; then
    frac=${v#*.}
    while (( ${#frac} < 3 )); do frac="${frac}0"; done
  fi
  scaled=$(( 10#$int * 1000 + 10#$frac ))
  (( scaled >= lo * 1000 && scaled <= hi * 1000 )) \
    || fail "settings.$name must be between $lo and $hi (got $v)"
}

require_sha256() {
  local d=${1:-}
  [[ $d =~ ^[0-9a-f]{64}$ ]] || fail "source digest must be 64 hex characters (got: ${d:-empty})"
}

# --- build attestation stamp -------------------------------------------------
#
# The stamp is a JSON record of what produced the installed .so, not merely
# which Hyprland it was built for. A bare Hyprland SHA let an artifact built by
# an older, weaker pipeline survive an upgrade untouched: the short-circuit in
# cmd_ensure matched, no rebuild happened, and the digest attestation this
# plugin is built around never applied to it. Every field must match, and the
# file on disk must still hash to the recorded digest, before the .so is
# reused or handed to the compositor.

read_stamp() {
  secure_read "$STAMP_PATH" 4096 2>/dev/null || true
}

stamp_field() {
  local v=""
  v=$(jq -r --arg k "$2" '.[$k] // empty | tostring' <<<"$1" 2>/dev/null || true)
  sanitize_field "${v//$'\n'/}" 128
}

write_stamp() {
  ensure_state_dir
  jq -n \
    --argjson pipeline "$PIPELINE_VERSION" \
    --arg hyprland "$1" \
    --arg sourceDigest "$2" \
    --arg soDigest "$3" \
    '{
      pipeline: $pipeline,
      hyprland: $hyprland,
      sourceDigest: $sourceDigest,
      soDigest: $soDigest
    }' | secure_write "$STAMP_PATH"
}

so_digest() {
  local d=""
  d=$(python3 "$STATEIO" file-digest "$SO_PATH" 2>/dev/null || true)
  sanitize_field "${d//$'\n'/}" 64
}

# True only when the installed .so is the artifact this pipeline generation
# built, from the native tree whose digest we attested, for this Hyprland --
# and the bytes on disk still hash to it. A legacy stamp has no fields and
# fails here, forcing a rebuild.
so_attested_for() {
  local hl=$1 want_src=$2 raw="" recorded=""
  [[ -n $hl && -n $want_src ]] || return 1
  raw=$(read_stamp)
  [[ -n $raw ]] || return 1
  [[ $(stamp_field "$raw" pipeline) == "$PIPELINE_VERSION" ]] || return 1
  [[ $(stamp_field "$raw" hyprland) == "$hl" ]] || return 1
  [[ $(stamp_field "$raw" sourceDigest) == "$want_src" ]] || return 1
  recorded=$(stamp_field "$raw" soDigest)
  [[ $recorded =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ $(so_digest) == "$recorded" ]] || return 1
  return 0
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

# PID of this compositor instance, as the compositor itself reports it.
# The signature is a single path-safe token; anything else is not an instance.
hyprland_pid() {
  local sig pid
  sig=$(hyprland_instance)
  [[ $sig =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  pid=$(hyprctl_capture "$IPC_MAX_BYTES" -j instances \
    | jq -r --arg sig "$sig" '
      def entries: if type == "array" then .[] elif type == "object" then . else empty end;
      [entries | select((.instance // "") | tostring == $sig) | (.pid // empty) | tostring]
      | if length == 1 then .[0] else empty end
    ' 2>/dev/null || true)
  pid=$(sanitize_field "$pid" 16)
  [[ $pid =~ ^[1-9][0-9]{0,9}$ ]] || return 1
  printf '%s\n' "$pid"
}

# Hyprland 0.56's plugin listing has no path. The maps file does: if this
# instance has our exact .so mapped, that copy is ours. A hyprpm build lives
# at a different path and will not match. Misses fail closed (not mapped).
so_is_mapped() {
  local pid=""
  pid=$(hyprland_pid) || return 1
  python3 "$STATEIO" maps-has "/proc/${pid}/maps" "$SO_PATH" >/dev/null 2>&1
}

# Three-valued, because the truth is three-valued:
#
#   mine    - proven ours: the compositor reports a path that is our .so, our
#             exact .so is mapped into this instance, or a name matches and we
#             recorded a confirmed load in this same compositor instance.
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
    # Exact equality, never a substring: a sibling ".so.bak" or a copy under a
    # longer prefix contains our path but is not our build, and treating it as
    # ours would push our config into a binary we never verified. This matches
    # the exact-pathname rule stateio.py maps-has applies to /proc/<pid>/maps.
    if any(entries; pathof == $so) then "mine"
    elif any(entries; nameof | test("omacursorshake"; "i")) then "unknown"
    else "none"
    end
  ' 2>/dev/null || true)
  listed=$(sanitize_field "$listed" 16)
  case "$listed" in
  mine) printf 'mine\n' ;;
  unknown)
    if so_is_mapped; then
      printf 'mine\n'
    else
      inst=$(hyprland_instance)
      if [[ -n $inst && $inst == "$(recorded_instance)" ]]; then
        printf 'mine\n'
      else
        printf 'unknown\n'
      fi
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

# Replace the directory entry, never truncate a mapped inode. The compiler
# output is read relative to the pinned source descriptor, so the artifact we
# install is the one built from the tree we digested, then published through a
# same-directory temporary.
install_so_from() {
  python3 "$STATEIO" copy-fd "$1" "$2" "$SO_PATH" 0755
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
  # Range, not just shape, and for every field the compositor consumes. The
  # shape regexes alone admit 0-999.999, so a hand-edited settings.json could
  # push a ~999x magnification or a zero shake threshold straight through
  # hl.config(). These bounds are the ones the QML sliders enforce, so a
  # normalized snapshot always passes and only a hand-edited file can trip it.
  require_range threshold "$threshold" 4 8
  require_range base "$base" 3 6
  (( timeout >= 1000 && timeout <= 3000 )) || fail "settings.timeout must be 1000-3000 ms"

  local lua
  lua=$(cat <<EOF
if hl.plugin.omacursorshake then
  hl.config({
    plugin = {
      omacursorshake = {
        enabled = ${enabled},
        shake = {
          enabled = ${enabled},
          threshold = ${threshold},
          base = ${base},
          timeout = ${timeout},
        },
        hyprcursor = {
          enabled = true,
        },
      },
    },
  })
end
EOF
)
  printf '%s\n' "$lua" | secure_write "$APPLY_LUA"
}

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
  local arch hl_commit hl_ver built loaded so_exists needs src_digest=""
  arch=$(capture_bounded 64 5 uname -m)
  hl_commit=$(hyprland_commit)
  hl_ver=$(hyprland_version)
  # builtFor reports the Hyprland the current attestation names. A legacy
  # plain-SHA stamp has no such field and reads empty, which is accurate:
  # nothing about that artifact is attested any more.
  built=$(stamp_field "$(read_stamp)" hyprland)
  built=$(sanitize_field "$built" 64)
  so_exists=false
  python3 "$STATEIO" exists "$SO_PATH" && so_exists=true
  loaded=false
  # Only a proven-ours plugin counts as loaded. "unknown" is reported as false
  # rather than dressed up as success.
  plugin_is_mine && loaded=true
  src_digest=$(native_digest 2>/dev/null || true)
  src_digest=$(sanitize_field "${src_digest//$'\n'/}" 64)
  # Same rule the build path uses, so the UI never shows an up-to-date plugin
  # that cmd_ensure would in fact rebuild.
  needs=false
  if [[ $arch != x86_64 ]]; then
    needs=false
  elif [[ $so_exists != true ]] || ! so_attested_for "$hl_commit" "$src_digest"; then
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
    --arg sourceDigest "$src_digest" \
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
      sourceDigest: $sourceDigest,
      needsRebuild: $needsRebuild,
      loaded: $loaded,
      settingsPath: $settingsPath
    }'
}

ensure_tree() {
  ensure_state_dir
  [[ $(capture_bounded 64 5 uname -m) == x86_64 ]] || fail "omacursorshake only works on x86_64 (Hyprland function hooks)"
  command -v make >/dev/null || fail "make is required to build omacursorshake"
  command -v g++ >/dev/null || fail "g++ is required to build omacursorshake"
  command -v timeout >/dev/null || fail "timeout (coreutils) is required to bound make"
  command -v python3 >/dev/null || fail "python3 is required to cap build-log size"
  env --chdir=/ true >/dev/null 2>&1 \
    || fail "env --chdir (coreutils 8.28+) is required to pin the source tree during the build"
  [[ -r /proc/self/fd ]] || fail "/proc must be mounted to pin the source tree during the build"
  pkg-config --exists hyprland || fail "pkg-config hyprland is missing; install the hyprland package"
  [[ -d $NATIVE_DIR ]] || fail "vendored plugin source is missing: $NATIVE_DIR"
  [[ -f $NATIVE_DIR/Makefile ]] || fail "vendored plugin Makefile is missing: $NATIVE_DIR/Makefile"
}

native_digest() {
  python3 "$STATEIO" tree-digest "$NATIVE_DIR"
}

# Digest the pinned native descriptor. The inode that is hashed is the inode
# make then compiles and the artifact is copied out of.
verify_source_tree() {
  local srcfd=$1 got_digest=""
  got_digest=$(python3 "$STATEIO" tree-digest-fd "$srcfd") \
    || fail "could not digest the source tree at $NATIVE_DIR"
  got_digest=$(sanitize_field "${got_digest//$'\n'/}" 64)
  require_sha256 "$got_digest"
  printf '%s\n' "$got_digest"
}

cmd_ensure() {
  local force=${1:-0}
  ensure_tree
  require_safe_state_path "$NATIVE_DIR"
  local hl_commit was_loaded=false src_digest=""
  hl_commit=$(hyprland_commit)
  [[ -n $hl_commit ]] || fail "could not read Hyprland version (is hyprctl available?)"
  src_digest=$(native_digest)
  src_digest=$(sanitize_field "${src_digest//$'\n'/}" 64)
  require_sha256 "$src_digest"
  plugin_present && was_loaded=true

  if (( force == 0 )) && python3 "$STATEIO" exists "$SO_PATH" \
     && so_attested_for "$hl_commit" "$src_digest"; then
    cmd_status
    return 0
  fi

  emit_diag "omacursorshake: building vendored plugin for Hyprland $hl_commit"

  local srcfd="" src_pin="" verified=""
  exec {srcfd}<"$NATIVE_DIR" || fail "could not pin the source tree at $NATIVE_DIR"
  src_pin="/proc/self/fd/$srcfd"
  verified=$(verify_source_tree "$srcfd")
  require_sha256 "$verified"
  [[ $verified == "$src_digest" ]] \
    || fail "source tree changed between digest and pin; refusing to build"
  run_timed "$MAKE_TIMEOUT" env --chdir="$src_pin" make -f Makefile all

  if [[ $was_loaded == true ]]; then
    emit_diag "omacursorshake: plugin is loaded; installing beside the mapped inode"
  fi
  local so_sha=""
  so_sha=$(install_so_from "$srcfd" out/omacursorshake.so)
  so_sha=$(sanitize_field "${so_sha//$'\n'/}" 64)
  require_sha256 "$so_sha"
  exec {srcfd}<&-

  write_stamp "$hl_commit" "$verified" "$so_sha"
  cmd_status
}

cmd_load() {
  ingest_settings_json "${1:-}"
  python3 "$STATEIO" exists "$SO_PATH" || fail "plugin is not built yet"

  # About to hand this file to the compositor to dlopen. Existence and
  # ownership say nothing about its content, so re-check the full attestation
  # against the bytes on disk first. That catches a stale, corrupt, or
  # half-written artifact, and one left behind by an older pipeline; the next
  # ensure rebuilds it.
  #
  # It is not a race-proof gate, and should not be read as one. hyprctl takes a
  # path, not a descriptor, so Hyprland reopens SO_PATH by name after this
  # check and a same-uid process could swap the file in between. That is not a
  # boundary this can defend -- such a process can already dlopen anything of
  # its own -- and there is no descriptor-passing interface to close it with.
  local hl_now="" src_now=""
  hl_now=$(hyprland_commit)
  src_now=$(native_digest 2>/dev/null || true)
  src_now=$(sanitize_field "${src_now//$'\n'/}" 64)
  so_attested_for "$hl_now" "$src_now" \
    || fail "the built plugin no longer matches its build attestation; refusing to load it"

  local state=""
  state=$(plugin_state)

  if [[ $state == unknown ]]; then
    # Refuse rather than guess. Loading a second copy would be rejected by the
    # compositor, and pushing our config into someone else's plugin would make
    # us a confused deputy for a build we never verified.
    fail "an omacursorshake plugin is already loaded that we cannot prove is ours; unload the other copy and retry"
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
  else
    # Already ours (listing path, mapped .so, or a prior record). Persist the
    # instance id so a later name-only listing still counts as mine.
    record_load
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
NATIVE_DIR=$(cd -P "$NATIVE_DIR" && pwd -P) \
  || fail "cannot resolve native source dir: $NATIVE_DIR"
require_safe_state_path "$NATIVE_DIR"

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
