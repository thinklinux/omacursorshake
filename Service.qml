import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Headless owner of hypr-dynamic-cursors. Loaded with the shell, independent
// of the bar widget, so shake-to-find keeps working with the panel closed.
//
// Nothing here writes ~/.config/hypr/: the compositor plugin is built into
// state dir, loaded with hyprctl, and re-applied after Hyprland config reloads.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }
  readonly property string backend: pluginDir + "bin/backend.sh"
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string stateDir: stateHome + "/omarchy/omacursorshake"
  readonly property string settingsPath: stateDir + "/settings.json"

  readonly property var defaultSettings: ({
    enabled: true,
    threshold: 6.0,
    base: 4.0,
    timeout: 2000
  })

  property var settings: defaultSettings
  property bool settingsReady: false
  property bool started: false

  property string phase: "starting"   // starting|building|loading|ready|disabled|unsupported|error
  property string statusText: "Starting…"
  property string lastError: ""
  property bool loaded: false
  property bool supported: true
  property bool building: false
  property bool busy: job.running
  property string hyprlandVersion: ""

  readonly property bool active: settings.enabled === true && loaded && phase === "ready"
  readonly property string moodLabel: {
    if (phase === "building") return "Building…"
    if (phase === "error") return "Shake cursor error"
    if (phase === "unsupported") return "Shake cursor unavailable"
    if (phase === "disabled") return "Shake cursor off"
    if (active) return "Shake to find"
    return "Shake cursor"
  }

  property var queue: []
  property string currentJob: ""
  property string generation: ""
  property double lastApplyAt: 0

  function clampNumber(value, fallback, min, max) {
    var n = Number(value)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function snap(value, fallback, min, max, step) {
    var n = clampNumber(value, fallback, min, max)
    var snapped = min + Math.round((n - min) / step) * step
    return clampNumber(snapped, fallback, min, max)
  }

  function normalizeSettings(parsed) {
    var src = parsed && typeof parsed === "object" ? parsed : {}
    return {
      enabled: src.enabled !== false,
      threshold: snap(src.threshold, 6, 4, 8, 1),
      base: snap(src.base, 4, 3, 6, 1),
      timeout: Math.round(snap(src.timeout, 2000, 1000, 3000, 500))
    }
  }

  function settingsJson() {
    return JSON.stringify(normalizeSettings(settings), null, 2)
  }

  function persistSettings() {
    Quickshell.execDetached(["bash", backend, "save", settingsJson()])
  }

  function updateSettings(patch) {
    var merged = normalizeSettings(settings)
    for (var key in patch) {
      if (key === "enabled" || key === "threshold" || key === "base" || key === "timeout")
        merged[key] = patch[key]
    }
    settings = normalizeSettings(merged)
    persistSettings()
    if (settings.enabled) enqueue("apply")
    else enqueue("disable")
  }

  function enqueue(name) {
    if (root.queue.indexOf(name) !== -1) return
    root.queue = root.queue.concat([name])
    pump()
  }

  function pump() {
    if (job.running || root.queue.length === 0) return
    var next = root.queue[0]
    var rest = []
    for (var i = 1; i < root.queue.length; i++) rest.push(root.queue[i])
    root.queue = rest
    runJob(next)
  }

  function runJob(name) {
    if (name === "sync") name = settings.enabled ? "ensure" : "disable"
    currentJob = name
    if (name === "ensure") {
      phase = loaded ? "loading" : "building"
      statusText = loaded ? "Applying…" : "Building the cursor plugin…"
      building = !loaded
      job.command = ["bash", backend, "ensure"]
    } else if (name === "load") {
      phase = "loading"
      statusText = "Loading into Hyprland…"
      job.command = ["bash", backend, "load", settingsJson()]
    } else if (name === "apply") {
      job.command = ["bash", backend, "apply", settingsJson()]
    } else if (name === "disable") {
      phase = "disabled"
      statusText = "Shake to find is off"
      job.command = ["bash", backend, "unload", settingsJson()]
    } else if (name === "status") {
      job.command = ["bash", backend, "status"]
    } else {
      currentJob = ""
      pump()
      return
    }
    job.running = true
  }

  function ingestStatus(text) {
    var parsed
    try { parsed = JSON.parse(String(text || "").trim()) } catch (e) { return false }
    if (!parsed || typeof parsed !== "object") return false
    supported = parsed.supported !== false
    loaded = parsed.loaded === true
    hyprlandVersion = parsed.hyprlandVersion || ""
    if (!supported) {
      phase = "unsupported"
      statusText = "Needs an x86_64 session (Hyprland cursor hooks)"
      return true
    }
    if (currentJob === "disable" || settings.enabled === false) {
      phase = "disabled"
      statusText = "Shake to find is off"
      return true
    }
    if (loaded) {
      phase = "ready"
      statusText = "Shake the mouse to find the cursor"
      lastError = ""
      building = false
    }
    return true
  }

  function notify(title, body) {
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "omacursorshake",
      "-g", "󰍽",
      "-u", "normal",
      title,
      body
    ])
  }

  function reapply() {
    reapplyTimer.restart()
  }

  function claimOwner() {
    root.generation = Date.now() + "-" + Math.floor(Math.random() * 1000000)
    Quickshell.execDetached(["bash", backend, "claim", root.generation])
  }

  Process {
    id: job
    stdout: StdioCollector { id: jobOut; waitForEnd: true }
    stderr: StdioCollector { id: jobErr; waitForEnd: true }
    onExited: function(code) {
      var out = String(jobOut.text || "")
      var err = String(jobErr.text || "").trim()
      var name = root.currentJob
      root.currentJob = ""

      if (code !== 0) {
        root.building = false
        root.lastError = err || (name + " failed")
        root.phase = root.supported ? "error" : "unsupported"
        root.statusText = root.lastError
        if (name === "ensure" || name === "load")
          root.notify("Shake to find failed", root.lastError)
        root.pump()
        return
      }

      root.ingestStatus(out)

      if (name === "ensure") {
        if (root.settings.enabled) root.enqueue("load")
      } else if (name === "load") {
        if (root.settings.enabled) root.enqueue("apply")
      } else if (name === "apply") {
        root.lastApplyAt = Date.now()
        if (root.loaded) {
          root.phase = "ready"
          root.statusText = "Shake the mouse to find the cursor"
          root.building = false
        }
      } else if (name === "disable") {
        root.lastApplyAt = Date.now()
        root.phase = "disabled"
        root.statusText = "Shake to find is off"
      }

      root.pump()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && event.name === "configreloaded") root.reapply()
    }
  }

  Process {
    id: settingsReader
    command: ["bash", "-c", "head -c 65536 -- \"$0\" 2>/dev/null || true", root.settingsPath]
    stdout: StdioCollector { id: settingsOut; waitForEnd: true }
    onExited: function() {
      var text = String(settingsOut.text || "").trim()
      try {
        root.settings = root.normalizeSettings(text !== "" ? JSON.parse(text) : {})
      } catch (e) {
        root.settings = root.normalizeSettings({})
      }
      root.settingsReady = true
      if (!root.settings.enabled) {
        root.phase = "disabled"
        root.statusText = "Shake to find is off"
        root.enqueue("disable")
      } else {
        root.enqueue("sync")
      }
    }
  }

  Timer {
    id: reapplyTimer
    interval: 80
    onTriggered: {
      if (job.running || root.queue.length > 0) return
      // hl.config() from apply fires configreloaded; ignore that echo or we
      // stay busy forever and the toggle cannot be clicked.
      if (Date.now() - root.lastApplyAt < 1500) return
      if (root.settings.enabled) root.enqueue("apply")
    }
  }

  Component.onCompleted: {
    root.claimOwner()
    root.started = true
    settingsReader.running = true
  }

  Component.onDestruction: {
    if (root.generation !== "")
      Quickshell.execDetached(["bash", root.backend, "unload-if", root.generation])
  }
}
