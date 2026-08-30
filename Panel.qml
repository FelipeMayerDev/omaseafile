import QtQuick
import Quickshell
import Quickshell.Io
import QtQuick.Effects
import qs.Commons
import qs.Ui

// OmaSeafile — bar widget. Local state comes from `bin/seafile-status`, which speaks
// seaf-daemon's own RPC socket — no seaf-cli, so the flatpak client works too.
// The Remotas/Favoritos tabs add `--remote`, which reuses the API token the
// desktop client already stored in accounts.db. Network reads only happen
// while the panel is open, on their own slow timer.
//
// The Seafile GUI client is never required: the widget starts and stops
// seaf-daemon itself, logs into the server for its own API token, and adds or
// drops libraries over the same RPC socket. Only the daemon binary has to
// exist — and if it doesn't, the panel offers to install it.
Panel {
  id: root
  moduleName: "io.github.felipemayerdev.omaseafile"
  ipcTarget: "io.github.felipemayerdev.omaseafile"

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(barForeground, 1.4)
  readonly property color urgent: bar && bar.urgent !== undefined ? bar.urgent : "#cc6666"

  readonly property string statusScript: Qt.resolvedUrl("bin/seafile-status").toString().replace(/^file:\/\//, "")
  // Seafile's "svg" is just a wrapper around an embedded 128px PNG; using the
  // PNG directly avoids the blur Qt produces rasterizing that wrapper.
  readonly property url logo: Qt.resolvedUrl("seafile.png")
  // Monochrome mask of the same mark (clouds and ring, without the orange
  // disc), tinted with the theme color in the bar; the panel keeps the colored
  // logo. Colorizing the original would not do: it is a filled disc.
  readonly property url logoMono: Qt.resolvedUrl("seafile-mono.png")

  property var info: ({})
  property var remote: ({})
  property string tab: "local"

  readonly property bool running: info.running === true
  readonly property var repos: info.repos || []
  // Libraries still downloading for the first time: they live in clone tasks,
  // out of the repo list, until the download finishes.
  readonly property var cloning: info.cloning || []
  readonly property var unsynced: info.unsynced || []
  readonly property var fileErrors: info.fileErrors || []
  readonly property var account: remote.account || null
  readonly property var starred: remote.starred || []
  readonly property string remoteError: remote.remoteError || ""
  readonly property bool notifyTransfers: setting("notifyTransfers", true) !== false
  readonly property string daemonBinary: info.daemonBinary || ""
  readonly property bool loggedIn: info.loggedIn === true
  readonly property bool hasDaemon: daemonBinary !== ""
  readonly property string installCmd: info.installCmd || ""

  property bool daemonBusy: false
  // Autostart runs once per shell session, and never fights a deliberate stop.
  property bool autostartTried: false
  property bool userStopped: false
  property bool loginBusy: false
  property string actionError: ""
  property string busyRepo: ""
  property string confirmDesync: ""

  // Only the libraries that exist on the server but aren't syncing here.
  readonly property var serverOnly: {
    var all = remote.serverRepos || [], out = []
    for (var i = 0; i < all.length; i++) if (!all[i].synced) out.push(all[i])
    return out
  }

  readonly property int busyCount: {
    var n = cloning.length
    for (var i = 0; i < repos.length; i++) if (isBusy(repos[i].state)) n++
    return n
  }
  readonly property int errorCount: {
    var n = fileErrors.length
    for (var c = 0; c < cloning.length; c++) if (cloning[c].error) n++
    for (var i = 0; i < repos.length; i++) if (repos[i].error || repos[i].invalid) n++
    return n
  }

  readonly property string statusText: {
    if (daemonBusy) return running ? "Stopping the daemon…" : "Starting the daemon…"
    if (!hasDaemon) return "seaf-daemon not installed"
    if (!running) return "Daemon stopped"
    if (cloning.length > 0) return cloning.length + " downloading"
    if (repos.length === 0) return "No libraries"
    if (errorCount > 0) return errorCount + " with errors · " + repos.length + " libraries"
    if (busyCount > 0) return busyCount + " syncing"
    return repos.length + " libraries in sync"
  }

  function isBusy(state) {
    return state === "uploading" || state === "downloading" || state === "committing"
        || state === "merging" || state === "initializing"
  }

  function stateIcon(repo) {
    if (repo.error || repo.invalid) return "󰅚"
    if (repo.state === "uploading") return "󰕒"
    if (repo.state === "downloading") return "󰇚"
    if (isBusy(repo.state)) return "󰑓"
    if (!repo.autoSync) return "󰏤"
    return "󰄬"
  }

  function stateLabel(repo) {
    if (repo.invalid) return "folder missing"
    if (repo.error) return repo.error
    if (repo.transfer && repo.transfer.rate > 0)
      return (repo.state === "uploading" ? "uploading" : "downloading") + " · " + fmtSize(repo.transfer.rate) + "/s"
    if (repo.state === "uploading") return "uploading"
    if (repo.state === "downloading") return "downloading"
    if (repo.state === "committing") return "indexing"
    if (repo.state === "merging") return "merging"
    if (repo.state === "initializing") return "starting up"
    if (!repo.autoSync) return "paused"
    return repo.lastSync > 0 ? "in sync · " + fmtAgo(repo.lastSync) : "in sync"
  }

  function cloneLabel(task) {
    if (task.error) return task.error
    var t = task.transfer
    if (t && t.total > 0) {
      var pct = Math.floor(100 * t.done / t.total)
      var line = "downloading " + pct + "%  ·  " + fmtSize(t.done) + " of " + fmtSize(t.total)
      if (t.rate > 0) line += "  ·  " + fmtSize(t.rate) + "/s"
      return line
    }
    if (task.state === "checkout") return "writing files"
    if (task.state === "fetch") return "downloading"
    if (task.state === "check-server") return "contacting the server"
    if (task.state === "password-required") return "library password required"
    if (task.state === "canceled") return "canceled"
    if (task.state === "error") return "failed"
    return task.state
  }

  function isCloning(repoId) {
    for (var i = 0; i < cloning.length; i++) if (cloning[i].id === repoId) return true
    return false
  }

  function fmtSize(bytes) {
    if (bytes === undefined || bytes === null || bytes < 0) return ""
    var units = ["B", "KB", "MB", "GB", "TB"], i = 0, n = bytes
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
    return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[i]
  }

  function fmtAgo(epoch) {
    if (!epoch) return ""
    var s = Math.max(0, Math.floor(Date.now() / 1000) - epoch)
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + " min ago"
    if (s < 86400) return Math.floor(s / 3600) + " h ago"
    return Math.floor(s / 86400) + " d ago"
  }

  // ------------------------------------------------------------- refresh ---
  property var lastStates: ({})
  // Clones seen on the previous read, so we can tell when one finishes: a
  // clone task simply disappears once it becomes a repository.
  property var lastCloning: ({})
  // The first read only records state: without this every existing library
  // would be announced on each shell restart.
  property bool primed: false

  function refresh() { if (!statusProc.running) statusProc.running = true }
  function refreshDetails() { if (!detailsProc.running) detailsProc.running = true }
  function refreshRemote() { if (!remoteProc.running) remoteProc.running = true }

  function updateInfo(raw) {
    var next
    try { next = JSON.parse(raw) } catch (e) { return }
    if (!next || typeof next !== "object") return
    notifyChanges(next)
    info = next
    maybeAutostart()
  }

  function updateRemote(raw) {
    try {
      var next = JSON.parse(raw)
      if (next && typeof next === "object") remote = next
    } catch (e) {}
  }

  // A library entering or leaving a transfer raises one notification, so a
  // sync that starts while the panel is closed is still visible.
  function notifyChanges(next) {
    var seen = {}
    var list = next.repos || []
    var i

    if (!primed) {
      for (i = 0; i < list.length; i++) seen[list[i].id] = list[i].state
      lastStates = seen
      var seed = {}
      var seedList = next.cloning || []
      for (i = 0; i < seedList.length; i++) seed[seedList[i].id] = seedList[i]
      lastCloning = seed
      primed = true
      return
    }

    notifyClones(next)

    for (i = 0; i < list.length; i++) {
      var r = list[i]
      var was = lastStates[r.id] || ""
      seen[r.id] = r.state
      if (!notifyTransfers) continue
      // A library that did not exist before: its download finished. This holds
      // even when the clone was too quick to show up in two consecutive reads.
      if (was === "") {
        notify("normal", "Library downloaded", r.name + " is ready")
        continue
      }
      if (was === r.state) continue
      if (r.error)
        notify("critical", "Sync error", r.name + ": " + r.error)
      else if (r.state === "uploading")
        notify("low", "Uploading files", r.name)
      else if (r.state === "downloading")
        notify("low", "Downloading files", r.name)
      else if (r.state === "synchronized" && isBusy(was))
        notify("low", "In sync", r.name)
    }
    lastStates = seen
  }

  // A finished download leaves `cloning` and lands in `repos`. A failed one
  // leaves `cloning` for nowhere — both deserve a notification.
  function notifyClones(next) {
    var current = {}
    var list = next.cloning || []
    var i
    for (i = 0; i < list.length; i++) current[list[i].id] = list[i]

    for (var id in lastCloning) {
      if (current[id]) continue
      var was = lastCloning[id]
      var landed = false
      var repoList = next.repos || []
      for (i = 0; i < repoList.length; i++) if (repoList[i].id === id) landed = true
      if (!notifyTransfers) continue
      // The success case is announced by the new repo in notifyChanges.
      if (landed) continue
      else if (was.error) notify("critical", "Download failed", was.name + ": " + was.error)
      else notify("critical", "Download interrupted", was.name)
    }

    // A failure still in the list (state "error") is announced once too.
    for (i = 0; i < list.length; i++) {
      var c = list[i]
      var prev = lastCloning[c.id]
      if (notifyTransfers && c.error && (!prev || !prev.error))
        notify("critical", "Download error", c.name + ": " + c.error)
    }

    lastCloning = current
  }

  function notify(urgency, title, body) {
    Quickshell.execDetached(["notify-send", "-u", urgency, "-a", "Seafile", title, body])
  }

  function openPath(path) {
    root.close()
    Quickshell.execDetached(["xdg-open", path])
  }

  // Where a synced library keeps a path locally, open the real file; otherwise
  // fall back to the web UI. Adding a library still belongs to the GUI client.
  function localPathFor(repoId, path) {
    for (var i = 0; i < repos.length; i++)
      if (repos[i].id === repoId) return repos[i].path + (path || "")
    return ""
  }

  function openLibrary(lib) {
    var local = localPathFor(lib.id, "")
    if (local !== "") openPath(local)
    else if (account) openPath(account.url + "/library/" + lib.id + "/" + encodeURIComponent(lib.name) + "/")
  }

  function openStarred(item) {
    var local = localPathFor(item.repoId, item.path)
    if (local !== "") { openPath(local); return }
    if (!account) return
    openPath(account.url + (item.isDir
      ? "/library/" + item.repoId + "/" + encodeURIComponent(item.repo) + item.path
      : "/lib/" + item.repoId + "/file" + item.path))
  }

  function runAction(proc, args) {
    if (proc.running) return
    actionError = ""
    proc.command = [statusScript].concat(args)
    proc.running = true
  }

  function readResult(raw) {
    try {
      var r = JSON.parse(raw)
      actionError = r && r.ok === false ? (r.error || "falhou") : ""
    } catch (e) { actionError = "" }
  }

  // The daemon does not survive a reboot on its own, and the shell starts with
  // the session — so the widget brings it up the first time it sees it down.
  function maybeAutostart() {
    if (autostartTried || userStopped || daemonBusy) return
    if (!hasDaemon || running) return
    if (setting("autostart", true) === false) return
    autostartTried = true
    daemonBusy = true
    runAction(daemonProc, ["--daemon-start"])
  }

  function toggleDaemon() {
    if (daemonBusy || !hasDaemon) return
    userStopped = running
    daemonBusy = true
    runAction(daemonProc, [running ? "--daemon-stop" : "--daemon-start"])
  }

  function installDaemon() {
    if (installProc.running) return
    installProc.running = true
  }

  function syncLibrary(lib) {
    if (busyRepo !== "") return
    busyRepo = lib.id
    runAction(syncProc, ["--sync", lib.id])
  }

  function desyncLibrary(repo) {
    if (busyRepo !== "") return
    confirmDesync = ""
    busyRepo = repo.id
    runAction(syncProc, ["--desync", repo.id])
  }

  function submitLogin() {
    if (loginBusy) return
    loginBusy = true
    actionError = ""
    loginProc.command = [statusScript, "--login"]
    loginProc.running = true
    loginProc.write(JSON.stringify({
      server: serverField.text, user: userField.text,
      password: passField.text, otp: otpField.text
    }))
    loginProc.stdinEnabled = false
  }

  function logout() {
    runAction(loginProc2, ["--logout"])
  }

  function launchClient() {
    root.close()
    Quickshell.execDetached(["sh", "-c",
      "command -v seafile-applet >/dev/null && exec seafile-applet || exec flatpak run com.seafile.Client"])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: [root.statusScript]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  Process {
    id: detailsProc
    command: [root.statusScript, "--sizes"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateInfo(text) }
  }

  Process {
    id: daemonProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.readResult(text) }
    onExited: { root.daemonBusy = false; root.refresh() }
  }

  Process {
    id: syncProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.readResult(text) }
    onExited: { root.busyRepo = ""; root.refresh(); root.refreshRemote() }
  }

  Process {
    id: loginProc
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.readResult(text) }
    onExited: {
      root.loginBusy = false
      passField.text = ""
      root.refresh()
      root.refreshRemote()
    }
  }

  Process {
    id: loginProc2
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.readResult(text) }
    onExited: { root.remote = ({}); root.refresh() }
  }

  // Installing needs a visible terminal: it may ask for confirmation and it
  // takes a while. The floating terminal is Omarchy's own presentation shell.
  Process {
    id: installProc
    command: [root.statusScript, "--install-cmd"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var cmd = ""
        try { cmd = JSON.parse(text).cmd || "" } catch (e) {}
        if (cmd === "") { root.actionError = "no installer available"; return }
        root.close()
        Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                                 cmd + "; echo; read -p 'Enter para fechar'"])
      }
    }
  }

  Process {
    id: remoteProc
    command: [root.statusScript, "--remote"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateRemote(text) }
  }

  // Closed: slow poll, enough to catch a sync starting. Open: fast, with sizes.
  Timer {
    interval: Math.max(2, root.setting("interval", 10)) * 1000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 2000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshDetails()
  }

  // The server round-trip is the expensive one: only while the panel is open,
  // and only for the tabs that actually show server data.
  Timer {
    interval: Math.max(15, root.setting("remoteInterval", 60)) * 1000
    running: root.opened && root.tab !== "local"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshRemote()
  }

  onOpenedChanged: {
    if (!opened) { confirmDesync = ""; actionError = "" }
    else if (tab !== "local") refreshRemote()
  }

  // ----------------------------------------------------------------- bar ---
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The bar icon is the Seafile mark in monochrome, tinted with the theme
    // foreground — the same treatment the Tray gives symbolic icons.
    text: ""
    opacity: root.running ? 1 : 0.5
    slotSize: Style.bar.statusSlot
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    iconComponent: Component {
      Item {
        anchors.fill: parent

        Image {
          id: monoSource
          source: root.logoMono
          anchors.centerIn: parent
          width: Style.font.icon * 1.3
          height: width
          sourceSize.width: 64
          sourceSize.height: 64
          smooth: true
          mipmap: true
          // Kept as a hidden layer so the effect can sample it as a texture.
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: monoSource
          source: monoSource
          colorization: 1.0
          colorizationColor: root.barForeground

          // A running transfer makes the mark pulse.
          SequentialAnimation on opacity {
            running: root.busyCount > 0
            loops: Animation.Infinite
            onRunningChanged: if (!running) parent.opacity = 1
            NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
          }
        }
      }
    }

    Rectangle {
      visible: root.errorCount > 0
      width: Style.space(6)
      height: width
      radius: width / 2
      color: root.urgent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(2)
      anchors.topMargin: Style.space(2)
    }
  }

  // --------------------------------------------------------------- panel ---
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: "OmaSeafile"
            // The account goes on the status line, not in `detail`: as a chip
            // beside the title it squeezed "OmaSeafile" down to "Oma…".
            meta: root.account
              ? root.statusText + " · " + root.fmtSize(root.account.used)
              : root.statusText
            foreground: root.barForeground
            fontFamily: root.fontFamily
            iconOpacity: root.running ? 1.0 : 0.5
            iconComponent: Component {
              Item {
                implicitWidth: Style.font.display
                implicitHeight: Style.font.display
                Image {
                  id: heroLogo
                  source: root.logo
                  anchors.fill: parent
                  sourceSize.width: 128
                  sourceSize.height: 128
                  smooth: true
                  mipmap: true
                  visible: status === Image.Ready
                }
                Text {
                  visible: !heroLogo.visible
                  anchors.centerIn: parent
                  text: "󱍥"
                  color: root.barForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
            // The daemon is ours: start and stop it here, no desktop client.
            trailingControl: Component {
              ToggleSwitch {
                visible: root.hasDaemon
                checked: root.daemonBusy ? !root.running : root.running
                busy: root.daemonBusy
                foreground: root.barForeground
                onToggled: root.toggleDaemon()
              }
            }
          }

          // Square tabs spanning the full card width: three equal columns, no
          // pill radius, so the row reads as a segmented control.
          Row {
            id: tabs
            width: parent.width
            spacing: Style.space(6)

            readonly property var items: [
              { value: "local", label: "Local" },
              { value: "server", label: "Remote" },
              { value: "starred", label: "Starred" }
            ]

            Repeater {
              model: tabs.items

              Button {
                required property var modelData
                width: (tabs.width - tabs.spacing * (tabs.items.length - 1)) / tabs.items.length
                radius: 0
                bordered: true
                selected: root.tab === modelData.value
                text: modelData.label
                fontSize: Style.font.caption
                foreground: root.barForeground
                fontFamily: root.fontFamily
                onClicked: {
                  root.tab = modelData.value
                  if (modelData.value !== "local") root.refreshRemote()
                }
              }
            }
          }

          Column {
            visible: !root.hasDaemon
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "The seaf-daemon binary is not on this machine. It is all OmaSeafile needs — the desktop client stays out of it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              iconText: "󰇚"
              text: "Install seaf-daemon"
              fontSize: Style.font.caption
              bordered: true
              enabled: root.installCmd !== ""
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.installDaemon()
            }

            // The command is visible before the click: anyone who prefers can
            // run it in their own terminal, and nobody installs blind.
            Text {
              visible: root.installCmd !== ""
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Runs in a floating terminal:  " + root.installCmd
              color: root.dim
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.installCmd === ""
              width: parent.width
              wrapMode: Text.WordWrap
              text: "No installer available here. On Arch: yay -S seafile. Elsewhere, install the package that ships seaf-daemon."
              color: root.dim
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            visible: root.hasDaemon && !root.running && !root.daemonBusy
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Daemon stopped. Use the switch above to start it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.actionError !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: "󰀦 " + root.actionError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ============================ LOCAIS ============================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "local" && root.cloning.length > 0

            PanelSeparator { foreground: root.barForeground }
            PanelSectionHeader {
              text: "DOWNLOADING"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.tab === "local" ? root.cloning : []
              ListRow {
                required property var modelData
                width: parent.width
                icon: modelData.error ? "󰅚" : "󰇚"
                label: modelData.name
                sub: root.cloneLabel(modelData)
                onActivated: if (modelData.path) root.openPath(modelData.path)
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "local" && root.repos.length > 0

            PanelSeparator { foreground: root.barForeground }
            PanelSectionHeader {
              text: "LIBRARIES"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.tab === "local" ? root.repos : []
              RepoRow {
                required property var modelData
                width: parent.width
                repo: modelData
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "local" && root.unsynced.length > 0

            PanelSeparator { foreground: root.barForeground }
            PanelSectionHeader {
              text: "FOLDERS NOT SYNCED"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.tab === "local" ? root.unsynced : []
              ListRow {
                required property var modelData
                width: parent.width
                icon: "󰉋"
                label: modelData.name
                trailing: root.fmtSize(modelData.size)
                onActivated: root.openPath(modelData.path)
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.tab === "local" && root.fileErrors.length > 0

            PanelSeparator { foreground: root.barForeground }
            PanelSectionHeader {
              text: "FILES WITH ERRORS"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.tab === "local" ? root.fileErrors : []
              Text {
                required property var modelData
                width: parent.width
                wrapMode: Text.WordWrap
                text: "󰀦 " + modelData.path + " — " + modelData.error
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ============================ LOGIN =============================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab !== "local" && !root.loggedIn

            PanelSeparator { foreground: root.barForeground }
            PanelSectionHeader {
              text: "CONNECT TO SERVER"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            TextField {
              id: serverField
              width: parent.width
              placeholderText: "https://seafile.exemplo.com"
              foreground: root.barForeground
            }
            TextField {
              id: userField
              width: parent.width
              placeholderText: "email"
              foreground: root.barForeground
            }
            TextField {
              id: passField
              width: parent.width
              placeholderText: "password"
              password: true
              foreground: root.barForeground
              onAccepted: root.submitLogin()
            }
            TextField {
              id: otpField
              width: parent.width
              placeholderText: "2FA code (if enabled)"
              foreground: root.barForeground
              onAccepted: root.submitLogin()
            }

            Button {
              iconText: "󰍁"
              text: root.loginBusy ? "Connecting…" : "Connect"
              fontSize: Style.font.caption
              bordered: true
              enabled: !root.loginBusy
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.submitLogin()
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "The password is only exchanged for an API token, stored in ~/.config/omarchy/omaseafile/account.json (0600)."
              color: root.dim
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // =========================== REMOTAS ============================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "server" && root.loggedIn

            PanelSeparator { foreground: root.barForeground }
            PanelSectionHeader {
              text: "NOT SYNCED HERE"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.serverOnly.length === 0 && root.remoteError === ""
              width: parent.width
              text: root.account ? "Every server library is already synced."
                                 : "Loading…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.tab === "server" ? root.serverOnly : []
              ListRow {
                required property var modelData
                width: parent.width
                icon: modelData.encrypted ? "󰌾" : "󰡰"
                label: modelData.name
                sub: root.fmtSize(modelData.size) + " · alterada " + root.fmtAgo(modelData.mtime)
                actionIcon: root.isCloning(modelData.id) ? "" : "󰇚"
                actionTip: "Sync on this machine"
                actionEnabled: root.running && root.busyRepo === ""
                actionBusy: root.busyRepo === modelData.id
                trailing: root.isCloning(modelData.id) ? "downloading" : (modelData.permission === "r" ? "read only" : "")
                onActivated: root.openLibrary(modelData)
                onActionTriggered: root.syncLibrary(modelData)
              }
            }

            Text {
              visible: root.serverOnly.length > 0
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Click a row to open it on the server, or 󰇚 to sync it here. Encrypted libraries still need the desktop client."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              opacity: 0.8
            }
          }

          // ========================== FAVORITOS ===========================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.tab === "starred" && root.loggedIn

            PanelSeparator { foreground: root.barForeground }
            PanelSectionHeader {
              text: "STARRED"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.starred.length === 0 && root.remoteError === ""
              width: parent.width
              text: root.account ? "Nothing starred on the server." : "Loading…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.tab === "starred" ? root.starred : []
              ListRow {
                required property var modelData
                width: parent.width
                icon: modelData.isDir ? "󰉋" : "󰈔"
                label: modelData.name
                sub: modelData.repo + " · " + root.fmtAgo(modelData.mtime)
                trailing: root.localPathFor(modelData.repoId, "") !== "" ? "local" : ""
                onActivated: root.openStarred(modelData)
              }
            }
          }

          Button {
            visible: root.tab !== "local" && root.loggedIn
            iconText: "󰍂"
            text: root.account ? "Sign out of " + root.account.user : "Sign out"
            fontSize: Style.font.caption
            bordered: true
            foreground: root.barForeground
            fontFamily: root.fontFamily
            onClicked: root.logout()
          }

          Text {
            visible: root.tab !== "local" && root.remoteError !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: "󰀦 " + root.remoteError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // One row per local library. The action button lives INSIDE the first line,
  // as a layout item: that way it aligns with the name, respects the card's
  // margin and cannot overflow. The MouseArea comes before the column so it
  // sits underneath — Text items let the click through, the button does not.
  component RepoRow: Item {
    id: row
    property var repo: ({})
    readonly property bool bad: !!repo.error || repo.invalid === true

    implicitHeight: rowColumn.implicitHeight

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openPath(row.repo.path)
    }

    Column {
      id: rowColumn
      width: parent.width
      spacing: Style.space(2)

      Item {
        width: parent.width
        implicitHeight: Math.max(nameText.implicitHeight, desyncButton.implicitHeight)

        Text {
          id: stateGlyph
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: root.stateIcon(row.repo)
          color: row.bad ? root.urgent : root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Button {
          id: desyncButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.confirmDesync === row.repo.id ? "󰄬" : "󰅖"
          text: root.confirmDesync === row.repo.id ? "confirm" : ""
          tooltipText: "Stop syncing (files stay on disk)"
          fontSize: Style.font.caption
          iconSize: Style.font.caption
          horizontalPadding: Style.space(4)
          verticalPadding: Style.space(2)
          enabled: root.busyRepo === ""
          opacity: root.busyRepo === row.repo.id ? 0.4 : (root.confirmDesync === row.repo.id ? 1 : 0.55)
          foreground: root.confirmDesync === row.repo.id ? root.urgent : root.barForeground
          fontFamily: root.fontFamily
          onClicked: {
            if (root.confirmDesync === row.repo.id) root.desyncLibrary(row.repo)
            else root.confirmDesync = row.repo.id
          }
        }

        Text {
          id: sizeText
          anchors.right: desyncButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.fmtSize(row.repo.size)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: nameText
          anchors.left: stateGlyph.right
          anchors.leftMargin: Style.space(8)
          anchors.right: sizeText.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: row.repo.name + (row.repo.encrypted ? "  󰌾" : "")
          color: root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Text {
        x: Style.space(18)
        width: parent.width - x
        elide: Text.ElideRight
        text: root.stateLabel(row.repo)
        color: row.bad ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Generic row for the remote and folder sections, same scheme.
  component ListRow: Item {
    id: lrow
    property string icon: ""
    property string label: ""
    property string sub: ""
    property string trailing: ""
    property string actionIcon: ""
    property string actionTip: ""
    property bool actionEnabled: true
    property bool actionBusy: false
    signal activated()
    signal actionTriggered()

    implicitHeight: lrowColumn.implicitHeight

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: lrow.activated()
    }

    Column {
      id: lrowColumn
      width: parent.width
      spacing: Style.space(2)

      Item {
        width: parent.width
        implicitHeight: Math.max(labelText.implicitHeight, actionButton.implicitHeight)

        Text {
          id: rowGlyph
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: lrow.icon
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Button {
          id: actionButton
          visible: lrow.actionIcon !== ""
          width: visible ? implicitWidth : 0
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: lrow.actionIcon
          tooltipText: lrow.actionTip
          fontSize: Style.font.caption
          iconSize: Style.font.caption
          horizontalPadding: Style.space(4)
          verticalPadding: Style.space(2)
          enabled: lrow.actionEnabled && !lrow.actionBusy
          opacity: lrow.actionBusy ? 0.4 : 0.75
          iconSpinning: lrow.actionBusy
          foreground: root.barForeground
          fontFamily: root.fontFamily
          onClicked: lrow.actionTriggered()
        }

        Text {
          id: trailingText
          anchors.right: actionButton.visible ? actionButton.left : parent.right
          anchors.rightMargin: actionButton.visible ? Style.space(8) : 0
          anchors.verticalCenter: parent.verticalCenter
          text: lrow.trailing
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: labelText
          anchors.left: rowGlyph.right
          anchors.leftMargin: Style.space(8)
          anchors.right: trailingText.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: lrow.label
          color: root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Text {
        visible: lrow.sub !== ""
        x: Style.space(18)
        width: parent.width - x
        elide: Text.ElideRight
        text: lrow.sub
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
