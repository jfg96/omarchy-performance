import QtQuick
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
  readonly property string pluginDir: bar && bar.shell && bar.shell.barWidgetRegistry.metadataFor(manifestPluginId)
    ? String(bar.shell.barWidgetRegistry.metadataFor(manifestPluginId).sourceDir || "")
    : (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/" + manifestPluginId
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var previousRaw: null
  property var snapshot: ({
    cpu: 0, temperature: -1, memoryUsedBytes: 0, memoryTotalBytes: 0,
    memoryPercent: 0, uptime: 0, disk: null, gpu: null, processes: []
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

  readonly property var health: Model.status(snapshot.cpu, snapshot.memoryPercent, snapshot.temperature, snapshot.gpu, snapshot.disk)
  readonly property var topProcesses: Model.topProcesses(snapshot.processes, sortMode, 5)
  readonly property bool alarming: health.level > 0
  readonly property string heroMetaText: health.level > 0
    ? health.title
    : performancePhrases[performancePhraseIndex % performancePhrases.length]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!collector.running) collector.running = true
  }

  function applySample(raw) {
    var next = Model.buildSnapshot(raw, previousRaw)
    if (!next) return
    previousRaw = next.raw
    snapshot = next
    if (selectedIndex >= topProcesses.length) selectedIndex = Math.max(0, topProcesses.length - 1)
  }

  function selectSort(mode) {
    if (mode !== "cpu" && mode !== "memory") return
    sortMode = mode
    root.settings = Object.assign({}, root.settings, { processSort: mode })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function openBtop() {
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
      if (focusSection === "sort") { focusSection = topProcesses.length > 0 ? "process" : "action"; selectedIndex = 0 }
      else if (focusSection === "process" && selectedIndex < topProcesses.length - 1) selectedIndex++
      else focusSection = "action"
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
    else if (focusSection === "action" || focusSection === "process") openBtop()
  }

  Process {
    id: collector
    command: [root.pluginDir + "/collect.sh", root.opened ? "--full" : "--light"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySample(text)
    }
  }

  Timer {
    interval: root.opened ? 1500 : 8000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
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
    active: root.alarming
    tooltipText: "CPU " + Math.round(root.snapshot.cpu) + "% · RAM " + Math.round(root.snapshot.memoryPercent) + "%"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openBtop()
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
            detail: "UP " + Model.formatUptime(root.snapshot.uptime)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.health.level === 2 ? "󰈸" : (root.health.level === 1 ? "󰓅" : "󰍛")
                color: root.health.level > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            MetricCard {
              width: (parent.width - parent.spacing) / 2
              title: "CPU"
              value: Math.round(root.snapshot.cpu) + "%"
              detail: root.snapshot.temperature >= 0 ? Math.round(root.snapshot.temperature) + "°C" : "Temperature unavailable"
              ratio: root.snapshot.cpu / 100
              warning: root.health.cpuWarning || root.health.cpuTemperatureWarning
              critical: root.health.cpuCritical || root.health.cpuTemperatureCritical
            }

            MetricCard {
              width: (parent.width - parent.spacing) / 2
              title: "MEMORY"
              value: Math.round(root.snapshot.memoryPercent) + "%"
              detail: Model.formatBytes(root.snapshot.memoryUsedBytes) + " / " + Model.formatBytes(root.snapshot.memoryTotalBytes)
              ratio: root.snapshot.memoryPercent / 100
              warning: root.health.memoryWarning
              critical: root.health.memoryCritical
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            MetricCard {
              width: (parent.width - parent.spacing) / 2
              title: "GPU"
              value: root.snapshot.gpu ? Math.round(root.snapshot.gpu.usage) + "%" : "—"
              detail: root.snapshot.gpu
                ? Model.formatBytes(root.snapshot.gpu.memoryUsedMb * 1024 * 1024) + " VRAM · " + Math.round(root.snapshot.gpu.temperature) + "°C"
                : "No telemetry"
              ratio: root.snapshot.gpu ? root.snapshot.gpu.usage / 100 : 0
              warning: root.health.gpuTemperatureWarning
              critical: root.health.gpuTemperatureCritical
            }

            MetricCard {
              width: (parent.width - parent.spacing) / 2
              title: "STORAGE"
              value: root.snapshot.disk && root.snapshot.disk.total > 0
                ? Math.round(root.snapshot.disk.used * 100 / root.snapshot.disk.total) + "%" : "—"
              detail: root.snapshot.disk
                ? "R " + Model.formatBytes(root.snapshot.disk.readRate) + "/s · W " + Model.formatBytes(root.snapshot.disk.writeRate) + "/s"
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
              text: "Collecting process activity…"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(10)
              bottomPadding: Style.space(10)
            }
          }

          Button {
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
    property string title: ""
    property string value: ""
    property string detail: ""
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
        text: title
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
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
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component ProcessRow: CursorSurface {
    required property var process
    property int rank: 0
    property bool selected: false
    property string sortMode: "cpu"
    signal hovered()
    signal activated()

    hasCursor: selected
    foreground: root.foreground
    accent: Color.accent
    implicitHeight: Style.space(42)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) parent.hovered()
      onClicked: parent.activated()
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
