import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "oma.performance"
  ipcTarget: "oma.performance"

  // The host may replace moduleName with an instance id. Keep the manifest id
  // stable for registry lookups and filesystem paths.
  readonly property string manifestPluginId: "oma.performance"
  readonly property var manifestMetadata: bar && bar.shell && bar.shell.barWidgetRegistry
    ? bar.shell.barWidgetRegistry.metadataFor(manifestPluginId)
    : null
  readonly property string metadataSourceDir: manifestMetadata
    ? String(manifestMetadata.sourceDir || "")
    : ""
  readonly property string pluginDir: metadataSourceDir !== ""
    ? metadataSourceDir
    : (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/" + manifestPluginId
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var previousSystemRaw: null
  property var previousGpuRaw: null
  property real lastSystemSampleAt: 0
  property real lastGpuSampleAt: 0
  property real nowMs: Date.now()
  property string systemError: ""
  property string gpuError: ""
  property bool systemRefreshPending: false
  property bool btopAvailable: false
  property var snapshot: ({
    cpu: 0, temperature: -1, memoryUsedBytes: 0, memoryTotalBytes: 0,
    memoryPercent: 0, uptime: 0, disk: null, gpus: [], gpuScanned: false, processes: []
  })
  property string sortMode: String(setting("processSort", "cpu")) === "memory" ? "memory" : "cpu"
  property bool cursorActive: false
  property string focusSection: "sort"
  property int selectedIndex: 0
  property int performancePhraseIndex: 0

  readonly property var performancePhrases: [
    "Crunching numbers",
    "Watching cycles",
    "Counting bytes",
    "Cooling cores",
    "Sorting processes",
    "Balancing workloads",
    "Reading thermals",
    "Keeping score"
  ]

  readonly property int systemIntervalMs: opened ? 1500 : 8000
  readonly property int gpuIntervalMs: 4000
  readonly property string sampleState: Model.sampleState(lastSystemSampleAt, nowMs, systemIntervalMs, systemError !== "")
  readonly property string gpuSampleState: Model.sampleState(lastGpuSampleAt, nowMs, gpuIntervalMs, gpuError !== "")
  readonly property bool gpuCurrent: gpuSampleState === "current"
  readonly property var health: Model.status(snapshot.cpu, snapshot.memoryPercent, snapshot.temperature,
    gpuCurrent ? snapshot.gpus : [], snapshot.disk)
  readonly property bool hasSample: lastSystemSampleAt > 0
  readonly property string sampleNotice: (hasSample ? "Last sample " + Math.max(0, Math.floor((nowMs - lastSystemSampleAt) / 1000)) + "s ago" : "")
    + (systemError !== "" ? (hasSample ? " · " : "") + systemError : "")
  // A retained system snapshot is useful for gauges, but an exited process
  // must never look like a live row after collection stalls or fails.
  readonly property var topProcesses: sampleState === "current"
    ? Model.topProcesses(snapshot.processes, sortMode, 5) : []
  readonly property bool alarming: health.level > 0
  readonly property string heroMetaText: sampleState === "error" ? "Data unavailable"
    : sampleState === "stale" ? "Reading out of date"
    : sampleState === "loading" ? "Collecting data"
    : health.level > 0 ? health.title
    : performancePhrases[performancePhraseIndex % performancePhrases.length]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refreshSystem() {
    if (systemCollector.running) { systemRefreshPending = true; return }
    systemCollector.running = true
  }

  function refreshGpu() {
    if (!opened || gpuCollector.running) return
    // Counters sampled before a long pause cannot describe current activity.
    if (lastGpuSampleAt > 0 && Date.now() - lastGpuSampleAt > gpuIntervalMs * 3)
      previousGpuRaw = null
    gpuCollector.running = true
  }

  function refresh() {
    refreshSystem()
    refreshGpu()
  }

  function applySystemSample(raw) {
    var next = Model.buildSnapshot(raw, previousSystemRaw)
    if (!next) {
      systemError = "System collector returned an invalid sample"
      return false
    }
    previousSystemRaw = next.raw
    next.gpus = snapshot.gpus
    next.gpuScanned = snapshot.gpuScanned
    snapshot = next
    lastSystemSampleAt = Date.now()
    nowMs = lastSystemSampleAt
    systemError = ""
    if (selectedIndex >= topProcesses.length) selectedIndex = Math.max(0, topProcesses.length - 1)
    return true
  }

  function applyGpuSample(raw) {
    var sampledAt = Date.now()
    var elapsedSeconds = lastGpuSampleAt > 0 ? (sampledAt - lastGpuSampleAt) / 1000 : 0
    var next = Model.buildGpuSnapshot(raw, previousGpuRaw, elapsedSeconds)
    if (!next) {
      gpuError = "GPU collector returned an invalid sample"
      return false
    }
    previousGpuRaw = next.raw
    snapshot = Object.assign({}, snapshot, { gpus: next.gpus, gpuScanned: next.gpuScanned })
    lastGpuSampleAt = sampledAt
    nowMs = sampledAt
    gpuError = ""
    return true
  }

  function selectSort(mode) {
    if (mode !== "cpu" && mode !== "memory") return
    sortMode = mode
    root.settings = Object.assign({}, root.settings, { processSort: mode })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function openBtop() {
    if (!btopAvailable) return
    close()
    if (bar) bar.run("omarchy-launch-or-focus-tui btop")
    else Quickshell.execDetached(["omarchy-launch-or-focus-tui", "btop"])
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dx !== 0 && focusSection === "sort") {
      selectSort(dx < 0 ? "cpu" : "memory")
      return
    }
    if (dy > 0) {
      if (focusSection === "sort") { focusSection = topProcesses.length > 0 ? "process" : (btopAvailable ? "action" : "sort"); selectedIndex = 0 }
      else if (focusSection === "process" && selectedIndex < topProcesses.length - 1) selectedIndex++
      else focusSection = btopAvailable ? "action" : "sort"
    } else if (dy < 0) {
      if (focusSection === "action") {
        focusSection = topProcesses.length > 0 ? "process" : "sort"
        selectedIndex = Math.max(0, topProcesses.length - 1)
      } else if (focusSection === "process" && selectedIndex > 0) selectedIndex--
      else focusSection = "sort"
    }
  }

  function activateCursor() {
    if (focusSection === "sort") selectSort(sortMode === "cpu" ? "memory" : "cpu")
    else if (btopAvailable && (focusSection === "action" || focusSection === "process")) openBtop()
  }

  Process {
    command: ["bash", "-c", "command -v btop >/dev/null && command -v omarchy-launch-or-focus-tui >/dev/null"]
    running: true
    onExited: function(code) { root.btopAvailable = code === 0 }
  }

  Process {
    id: systemCollector
    property bool launched: false
    property bool outputReady: false
    property string outputText: ""
    property int runId: 0
    command: [root.pluginDir + "/collect.sh"]
    running: false
    onStarted: launched = true
    onRunningChanged: {
      if (running) { launched = false; outputReady = false; outputText = ""; runId++; return }
      if (!launched) root.systemError = "System collector could not start"
    }
    onExited: function(code) {
      var finishedRun = runId
      Qt.callLater(function() {
        if (finishedRun !== systemCollector.runId) return
        if (code !== 0) root.systemError = "System collector exited with code " + code
        else if (!systemCollector.outputReady || !root.applySystemSample(systemCollector.outputText))
          root.systemError = "System collector returned no valid sample"
        if (root.systemRefreshPending) {
          root.systemRefreshPending = false
          root.refreshSystem()
        }
      })
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { systemCollector.outputText = text; systemCollector.outputReady = true }
    }
  }

  Process {
    id: gpuCollector
    property bool launched: false
    property bool outputReady: false
    property string outputText: ""
    property int runId: 0
    // GNU timeout bounds driver calls and the /proc fdinfo traversal.
    command: ["timeout", "--signal=TERM", "--kill-after=1s", "2s", root.pluginDir + "/collect-gpu.sh"]
    running: false
    onStarted: launched = true
    onRunningChanged: {
      if (running) { launched = false; outputReady = false; outputText = ""; runId++; return }
      if (!launched) root.gpuError = "GPU collector could not start"
    }
    onExited: function(code) {
      var finishedRun = runId
      Qt.callLater(function() {
        if (finishedRun !== gpuCollector.runId) return
        if (code === 124) root.gpuError = "GPU sample timed out"
        else if (code !== 0) root.gpuError = "GPU collector exited with code " + code
        else if (!gpuCollector.outputReady || !root.applyGpuSample(gpuCollector.outputText))
          root.gpuError = "GPU collector returned no valid sample"
      })
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { gpuCollector.outputText = text; gpuCollector.outputReady = true }
    }
  }

  Timer {
    interval: root.systemIntervalMs
    running: true
    repeat: true
    onTriggered: root.refreshSystem()
  }

  Timer {
    interval: root.gpuIntervalMs
    running: root.opened
    repeat: true
    onTriggered: root.refreshGpu()
  }

  Component.onCompleted: refreshSystem()

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: performancePhraseTimer
    interval: 2800
    running: root.opened && root.health.level === 0
    repeat: true
    onTriggered: performancePhraseSwap.restart()
  }

  SequentialAnimation {
    id: performancePhraseSwap
    PropertyAnimation {
      target: hero
      property: "metaOpacity"
      to: 0.0
      duration: 180
      easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.performancePhraseIndex = (root.performancePhraseIndex + 1) % root.performancePhrases.length
    }
    PropertyAnimation {
      target: hero
      property: "metaOpacity"
      to: 1.0
      duration: 260
      easing.type: Easing.InQuad
    }
  }

  onHealthChanged: {
    if (health.level > 0) {
      performancePhraseSwap.stop()
      hero.metaOpacity = 1.0
    }
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = "sort"
    selectedIndex = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍛"
    active: root.alarming || root.sampleState === "stale" || root.sampleState === "error"
    tooltipText: root.sampleState === "current"
      ? "CPU " + Math.round(root.snapshot.cpu) + "% · RAM " + Math.round(root.snapshot.memoryPercent) + "%"
      : root.heroMetaText + (root.sampleNotice !== "" ? " · " + root.sampleNotice : "")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.btopAvailable) root.openBtop()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(650))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        clip: true

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            title: "System performance"
            meta: root.heroMetaText
            detail: root.hasSample ? "UP " + Model.formatUptime(root.snapshot.uptime) : "Waiting for first sample"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.sampleState === "stale" || root.sampleState === "error" || root.health.level === 2
                  ? "󰈸" : (root.health.level === 1 ? "󰓅" : "󰍛")
                color: root.sampleState === "stale" || root.sampleState === "error" || root.health.level > 0
                  ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: root.sampleState === "stale" || root.sampleState === "error"
            width: parent.width
            text: root.sampleNotice
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            MetricCard {
              width: (parent.width - parent.spacing) / 2
              title: "CPU"
              value: root.hasSample ? Math.round(root.snapshot.cpu) + "%" : "—"
              detail: root.snapshot.temperature >= 0 ? Math.round(root.snapshot.temperature) + "°C" : "Temperature unavailable"
              ratio: root.snapshot.cpu / 100
              warning: root.health.cpuWarning || root.health.cpuTemperatureWarning
              critical: root.health.cpuCritical || root.health.cpuTemperatureCritical
            }

            MetricCard {
              width: (parent.width - parent.spacing) / 2
              title: "MEMORY"
              value: root.hasSample ? Math.round(root.snapshot.memoryPercent) + "%" : "—"
              detail: root.hasSample
                ? Model.formatBytes(root.snapshot.memoryUsedBytes) + " / " + Model.formatBytes(root.snapshot.memoryTotalBytes)
                : "Waiting for sample"
              ratio: root.snapshot.memoryPercent / 100
              warning: root.health.memoryWarning
              critical: root.health.memoryCritical
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            GridLayout {
              id: gpuGrid
              visible: root.snapshot.gpus.length > 0
              width: parent.width
              columns: root.snapshot.gpus.length === 1 ? 1 : 2
              columnSpacing: Style.space(10)
              rowSpacing: Style.space(10)

              Repeater {
                model: root.snapshot.gpus

                MetricCard {
                  required property var modelData
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.preferredWidth: (gpuGrid.width - gpuGrid.columnSpacing * (gpuGrid.columns - 1)) / gpuGrid.columns
                  title: Model.gpuName(modelData)
                  value: root.gpuCurrent && modelData.usage !== null ? Math.round(modelData.usage) + "%" : "—"
                  detail: root.gpuCurrent ? Model.gpuDetail(modelData)
                    : root.gpuSampleState === "loading" ? "Waiting for GPU sample"
                    : root.gpuSampleState === "error" ? "GPU data unavailable" : "GPU reading out of date"
                  tooltip: root.gpuCurrent ? Model.gpuTooltip(modelData)
                    : (root.gpuError !== "" ? root.gpuError : "GPU reading out of date")
                  ratio: root.gpuCurrent && modelData.usage !== null ? modelData.usage / 100 : 0
                  warning: root.gpuCurrent && modelData.temperature !== null && modelData.temperature >= Model.THRESHOLDS.gpuTemperature.warning
                  critical: root.gpuCurrent && modelData.temperature !== null && modelData.temperature >= Model.THRESHOLDS.gpuTemperature.critical
                }
              }
            }

            MetricCard {
              visible: root.snapshot.gpus.length === 0
              width: parent.width
              title: "GPU"
              value: "—"
              detail: root.gpuCurrent && root.snapshot.gpuScanned ? "No graphics device detected"
                : root.gpuSampleState === "loading" ? "Waiting for GPU sample"
                : root.gpuSampleState === "error" ? "GPU data unavailable" : "GPU reading out of date"
            }

            MetricCard {
              width: parent.width
              title: "STORAGE"
              value: root.snapshot.disk && root.snapshot.disk.total > 0
                ? Math.round(root.snapshot.disk.used * 100 / root.snapshot.disk.total) + "%" : "—"
              detail: root.snapshot.disk
                ? (root.snapshot.disk.total > 0
                    ? Model.formatBytes(root.snapshot.disk.used) + " / " + Model.formatBytes(root.snapshot.disk.total)
                    : "Capacity unavailable")
                  + "\nR " + Model.formatBytes(root.snapshot.disk.readRate) + "/s · W " + Model.formatBytes(root.snapshot.disk.writeRate) + "/s"
                : "Unavailable"
              ratio: root.snapshot.disk && root.snapshot.disk.total > 0 ? root.snapshot.disk.used / root.snapshot.disk.total : 0
              warning: root.health.storageWarning
              critical: root.health.storageCritical
            }
          }

          PanelSeparator { width: parent.width }

          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              id: processesHeader
              text: "PROCESSES"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.verticalCenter: parent.verticalCenter
            }

            Item { width: Math.max(0, parent.width - processesHeader.width - cpuButton.width - memoryButton.width - parent.spacing * 3); height: 1 }

            Button {
              id: cpuButton
              text: "CPU"
              selected: root.sortMode === "cpu"
              hasCursor: root.cursorActive && root.focusSection === "sort" && root.sortMode === "cpu"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onHovered: function(hovered) { if (hovered) { root.cursorActive = true; root.focusSection = "sort" } }
              onClicked: root.selectSort("cpu")
            }

            Button {
              id: memoryButton
              text: "MEM"
              selected: root.sortMode === "memory"
              hasCursor: root.cursorActive && root.focusSection === "sort" && root.sortMode === "memory"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(3)
              onHovered: function(hovered) { if (hovered) { root.cursorActive = true; root.focusSection = "sort" } }
              onClicked: root.selectSort("memory")
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(5)

            Item {
              width: parent.width
              height: Style.space(18)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(38)
                anchors.verticalCenter: parent.verticalCenter
                text: "PROCESS"
                color: Qt.darker(root.foreground, 1.45)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                anchors.right: cpuEquivalentHeader.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: root.sortMode === "memory" ? Style.space(72) : Style.space(52)
                text: root.sortMode === "memory" ? "MEMORY" : "TOTAL"
                color: Qt.darker(root.foreground, 1.45)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                horizontalAlignment: Text.AlignRight
              }

              Text {
                id: cpuEquivalentHeader
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(54)
                text: root.sortMode === "memory" ? "% RAM" : "CPU×"
                color: Qt.darker(root.foreground, 1.45)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                horizontalAlignment: Text.AlignRight

                MouseArea {
                  id: cpuEquivalentHeaderHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                }

                PanelToolTip {
                  visible: root.sortMode === "cpu" && cpuEquivalentHeaderHover.containsMouse
                  text: "1.00× = one logical CPU"
                  panelForeground: root.foreground
                  fontFamily: root.fontFamily
                }
              }
            }

            Repeater {
              model: root.topProcesses

              ProcessRow {
                required property var modelData
                required property int index
                width: parent.width
                process: modelData
                rank: index + 1
                selected: root.cursorActive && root.focusSection === "process" && root.selectedIndex === index
                sortMode: root.sortMode
                actionAvailable: root.btopAvailable
                onHovered: function() {
                  root.cursorActive = true
                  root.focusSection = "process"
                  root.selectedIndex = index
                }
                onActivated: root.openBtop()
              }
            }

            Text {
              visible: root.topProcesses.length === 0
              width: parent.width
              text: root.sampleState === "current" ? "No processes found"
                : root.sampleState === "loading" ? "Collecting process activity…" : "Process list out of date"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(10)
              bottomPadding: Style.space(10)
            }
          }

          Button {
            visible: root.btopAvailable
            width: parent.width
            text: "Open full activity monitor"
            iconText: "󰍛"
            bordered: true
            hasCursor: root.cursorActive && root.focusSection === "action"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onHovered: function(hovered) { if (hovered) { root.cursorActive = true; root.focusSection = "action" } }
            onClicked: root.openBtop()
          }
        }
      }
    }
  }

  component MetricCard: BorderSurface {
    id: metricCard
    property string title: ""
    property string value: ""
    property string detail: ""
    property string tooltip: ""
    property real ratio: 0
    property bool warning: false
    property bool critical: false
    readonly property bool alerting: warning || critical

    implicitHeight: metricContent.implicitHeight + Style.space(20)
    color: Style.selectedFillFor(root.foreground, Color.accent)
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
    radius: Style.cornerRadius

    Column {
      id: metricContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(4)

      Text {
        width: parent.width
        text: title
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight

        MouseArea {
          id: metricTitleHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }

        PanelToolTip {
          visible: metricCard.tooltip !== "" && metricTitleHover.containsMouse
          text: metricCard.tooltip
          panelForeground: root.foreground
          fontFamily: root.fontFamily
        }
      }

      Text {
        text: value
        color: alerting ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Rectangle {
        width: parent.width
        height: Math.max(Style.space(4), 3)
        radius: height / 2
        color: Style.hoverFillFor(root.foreground, Color.accent)

        Rectangle {
          width: parent.width * Math.max(0, Math.min(1, ratio))
          height: parent.height
          radius: parent.radius
          color: alerting ? root.urgent : root.foreground
          Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        }
      }

      Text {
        width: parent.width
        text: detail
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
    }
  }

  component ProcessRow: CursorSurface {
    required property var process
    property int rank: 0
    property bool selected: false
    property string sortMode: "cpu"
    property bool actionAvailable: false
    signal hovered()
    signal activated()

    hasCursor: selected
    foreground: root.foreground
    accent: Color.accent
    implicitHeight: Style.space(42)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: actionAvailable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) parent.hovered()
      onClicked: if (parent.actionAvailable) parent.activated()
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(9)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      text: rank
      color: Qt.darker(root.foreground, 1.45)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Column {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(38)
      anchors.right: totalValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        width: parent.width
        text: process.name
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        text: "PID " + process.pid
        color: Qt.darker(root.foreground, 1.45)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      id: totalValue
      anchors.right: cpuEquivalentValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: sortMode === "memory" ? Style.space(72) : Style.space(52)
      text: sortMode === "memory" ? Model.formatBytes(process.memoryBytes) : process.cpuTotalPercent.toFixed(1) + "%"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignRight
    }

    Text {
      id: cpuEquivalentValue
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(54)
      text: sortMode === "memory" ? process.memoryPercent.toFixed(1) + "%" : process.cpuEquivalent.toFixed(2) + "×"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignRight
    }
  }
}
