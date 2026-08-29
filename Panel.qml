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
  // O "svg" do Seafile é só um wrapper com um PNG 128px dentro; usar o PNG
  // direto evita o borrão que o Qt produz rasterizando o wrapper.
  readonly property url logo: Qt.resolvedUrl("seafile.png")
  // Máscara monocromática do mesmo logo (as nuvens e o anel, sem o disco
  // laranja), tingida com a cor do tema na barra. O logo colorido fica no
  // painel. Colorizar o PNG original não serviria: ele é um disco cheio.
  readonly property url logoMono: Qt.resolvedUrl("seafile-mono.png")

  property var info: ({})
  property var remote: ({})
  property string tab: "local"

  readonly property bool running: info.running === true
  readonly property var repos: info.repos || []
  // Bibliotecas ainda baixando pela primeira vez: vivem em clone tasks, fora
  // da lista de repositórios, até o download terminar.
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
    if (daemonBusy) return running ? "Parando o daemon…" : "Iniciando o daemon…"
    if (!hasDaemon) return "seaf-daemon não instalado"
    if (!running) return "Daemon parado"
    if (cloning.length > 0) return cloning.length + " baixando"
    if (repos.length === 0) return "Nenhuma biblioteca"
    if (errorCount > 0) return errorCount + " com erro · " + repos.length + " bibliotecas"
    if (busyCount > 0) return busyCount + " sincronizando"
    return repos.length + " bibliotecas sincronizadas"
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
    if (repo.invalid) return "pasta ausente"
    if (repo.error) return repo.error
    if (repo.transfer && repo.transfer.rate > 0)
      return (repo.state === "uploading" ? "enviando" : "recebendo") + " · " + fmtSize(repo.transfer.rate) + "/s"
    if (repo.state === "uploading") return "enviando"
    if (repo.state === "downloading") return "recebendo"
    if (repo.state === "committing") return "indexando"
    if (repo.state === "merging") return "mesclando"
    if (repo.state === "initializing") return "iniciando"
    if (!repo.autoSync) return "pausada"
    return repo.lastSync > 0 ? "sincronizada " + fmtAgo(repo.lastSync) : "sincronizada"
  }

  function cloneLabel(task) {
    if (task.error) return task.error
    var t = task.transfer
    if (t && t.total > 0) {
      var pct = Math.floor(100 * t.done / t.total)
      var line = "baixando " + pct + "%  ·  " + fmtSize(t.done) + " de " + fmtSize(t.total)
      if (t.rate > 0) line += "  ·  " + fmtSize(t.rate) + "/s"
      return line
    }
    if (task.state === "checkout") return "gravando os arquivos"
    if (task.state === "fetch") return "baixando"
    if (task.state === "check-server") return "falando com o servidor"
    if (task.state === "password-required") return "precisa da senha da biblioteca"
    if (task.state === "canceled") return "cancelado"
    if (task.state === "error") return "falhou"
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
    if (s < 60) return "agora"
    if (s < 3600) return "há " + Math.floor(s / 60) + " min"
    if (s < 86400) return "há " + Math.floor(s / 3600) + " h"
    return "há " + Math.floor(s / 86400) + " d"
  }

  // ------------------------------------------------------------- refresh ---
  property var lastStates: ({})
  // Clones vistos na leitura anterior, para saber quando um termina: uma
  // clone task some da lista ao virar repositório.
  property var lastCloning: ({})
  // A primeira leitura só registra o estado: sem isto tudo que já existe
  // seria anunciado a cada restart do shell.
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
      // Biblioteca que não existia: o download terminou. Vale mesmo quando o
      // clone foi rápido demais para aparecer em duas leituras seguidas.
      if (was === "") {
        notify("normal", "Biblioteca baixada", r.name + " está pronta")
        continue
      }
      if (was === r.state) continue
      if (r.error)
        notify("critical", "Erro de sincronização", r.name + ": " + r.error)
      else if (r.state === "uploading")
        notify("low", "Enviando arquivos", r.name)
      else if (r.state === "downloading")
        notify("low", "Recebendo arquivos", r.name)
      else if (r.state === "synchronized" && isBusy(was))
        notify("low", "Sincronizado", r.name)
    }
    lastStates = seen
  }

  // Um download que termina sai de `cloning` e entra em `repos`. Um que falha
  // sai de `cloning` sem entrar em lugar nenhum — os dois merecem aviso.
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
      // O caso de sucesso é anunciado pelo repositório novo em notifyChanges.
      if (landed) continue
      else if (was.error) notify("critical", "Download falhou", was.name + ": " + was.error)
      else notify("critical", "Download interrompido", was.name)
    }

    // Uma falha que ainda está na lista (state "error") também avisa, uma vez.
    for (i = 0; i < list.length; i++) {
      var c = list[i]
      var prev = lastCloning[c.id]
      if (notifyTransfers && c.error && (!prev || !prev.error))
        notify("critical", "Erro no download", c.name + ": " + c.error)
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

  function toggleDaemon() {
    if (daemonBusy || !hasDaemon) return
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
        if (cmd === "") { root.actionError = "nenhum instalador disponível"; return }
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
    // O ícone da barra é o logo do Seafile em monocromático, tingido com o
    // foreground do tema — mesmo tratamento que o Tray dá a ícones simbólicos.
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
          // Mantido como camada escondida para o efeito amostrar a textura.
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: monoSource
          source: monoSource
          colorization: 1.0
          colorizationColor: root.barForeground

          // Uma transferência em curso faz o ícone pulsar.
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
            // A conta vai na linha de status, não no `detail`: como chip ao lado
            // do título ela espremia "OmaSeafile" até virar "Oma…".
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
            // O daemon é nosso: liga e desliga aqui, sem o cliente gráfico.
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

          ButtonGroup {
            id: tabs
            foreground: root.barForeground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            focusable: false
            value: root.tab
            options: [
              { value: "local", label: "Locais" },
              { value: "server", label: "Remotas" },
              { value: "starred", label: "Favoritos" }
            ]
            onChanged: function(v) {
              root.tab = v
              if (v !== "local") root.refreshRemote()
            }
          }

          Column {
            visible: !root.hasDaemon
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "O binário seaf-daemon não está nesta máquina. É só dele que o OmaSeafile precisa — o cliente gráfico não entra."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              iconText: "󰇚"
              text: "Instalar o seaf-daemon"
              fontSize: Style.font.caption
              bordered: true
              enabled: root.installCmd !== ""
              foreground: root.barForeground
              fontFamily: root.fontFamily
              onClicked: root.installDaemon()
            }

            // O comando fica à vista antes do clique: quem preferir roda no
            // próprio terminal, e ninguém instala às cegas.
            Text {
              visible: root.installCmd !== ""
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Roda em um terminal flutuante:  " + root.installCmd
              color: root.dim
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.installCmd === ""
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Nenhum instalador disponível aqui. No Arch: yay -S seafile. Em outras distros, instale o pacote que traz o seaf-daemon."
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
            text: "Daemon parado. Use a chave acima para ligar."
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
              text: "BAIXANDO"
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
              text: "BIBLIOTECAS"
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
              text: "PASTAS FORA DO SYNC"
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
              text: "ARQUIVOS COM ERRO"
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
              text: "CONECTAR AO SERVIDOR"
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
              placeholderText: "e-mail"
              foreground: root.barForeground
            }
            TextField {
              id: passField
              width: parent.width
              placeholderText: "senha"
              password: true
              foreground: root.barForeground
              onAccepted: root.submitLogin()
            }
            TextField {
              id: otpField
              width: parent.width
              placeholderText: "código 2FA (se usar)"
              foreground: root.barForeground
              onAccepted: root.submitLogin()
            }

            Button {
              iconText: "󰍁"
              text: root.loginBusy ? "Conectando…" : "Conectar"
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
              text: "A senha só é usada para pegar um token de API, guardado em ~/.config/omarchy/omaseafile/account.json (0600)."
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
              text: "NÃO SINCRONIZADAS AQUI"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.serverOnly.length === 0 && root.remoteError === ""
              width: parent.width
              text: root.account ? "Todas as bibliotecas do servidor estão sincronizadas."
                                 : "Carregando…"
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
                actionTip: "Sincronizar nesta máquina"
                actionEnabled: root.running && root.busyRepo === ""
                actionBusy: root.busyRepo === modelData.id
                trailing: root.isCloning(modelData.id) ? "baixando" : (modelData.permission === "r" ? "somente leitura" : "")
                onActivated: root.openLibrary(modelData)
                onActionTriggered: root.syncLibrary(modelData)
              }
            }

            Text {
              visible: root.serverOnly.length > 0
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Clique na linha para abrir no servidor, ou em 󰇚 para sincronizar aqui. Bibliotecas criptografadas ainda precisam do cliente gráfico."
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
              text: "FAVORITOS"
              foreground: root.barForeground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.starred.length === 0 && root.remoteError === ""
              width: parent.width
              text: root.account ? "Nenhum favorito marcado no servidor." : "Carregando…"
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
            text: root.account ? "Sair de " + root.account.user : "Sair"
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

  // Uma linha por biblioteca local. O botão de ação vive DENTRO da primeira
  // linha, como item do layout: assim ele alinha com o nome, respeita a
  // margem do card e não pode transbordar. O MouseArea vem antes da coluna
  // para ficar por baixo — os Text deixam o clique passar, o botão não.
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
          text: root.confirmDesync === row.repo.id ? "confirmar" : ""
          tooltipText: "Parar de sincronizar (mantém os arquivos)"
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

  // Linha genérica das abas remotas e de pastas, mesmo esquema.
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
