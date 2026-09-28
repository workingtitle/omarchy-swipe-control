import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Swipe Control: a settings popup in the bar, plus the popup navigation the
// Hyprland side (gestures.lua) calls over IPC while a bar popup is open.
//
// The plugin API only lets a widget see its own id, so the popups of the other
// widgets are found through the bar's ModuleSlot items, which every widget
// shares a window with. switchPanelFrom on the plugin bar API is the bar's own
// Tab navigation, so stepping between popups matches the keyboard exactly.
Panel {
  id: root
  moduleName: "io.github.workingtitle.gestures"
  ipcTarget: "io.github.workingtitle.gestures"
  manageIpc: false

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
  readonly property string hyprSettingsPath: stateDir + "/gestures-settings.conf"
  readonly property string lastPanelPath: stateDir + "/gestures-last-panel"

  // Three and four fingers can both be on; an entry from before that keeps
  // its single "fingers" choice until the first change.
  readonly property int legacyFingers: setting("fingers", 3) === 4 ? 4 : 3
  readonly property bool threeFingers: setting("threeFingers", legacyFingers === 3) === true
  readonly property bool fourFingers: setting("fourFingers", legacyFingers === 4) === true
  readonly property bool workspaceSwipe: setting("workspaceSwipe", true) === true
  readonly property bool stopAtLastWorkspace: setting("stopAtLastWorkspace", true) === true
  readonly property bool swipeUpExpose: setting("swipeUpExpose", true) === true
  readonly property bool swipeDownPanels: setting("swipeDownPanels", true) === true
  readonly property bool windowSwipe: setting("windowSwipe", true) === true
  readonly property bool popupArrowKeys: setting("popupArrowKeys", true) === true
  readonly property bool resizeOnEdges: setting("resizeOnEdges", true) === true
  readonly property bool shortSwipe: setting("shortSwipe", true) === true
  readonly property bool pinchFullscreen: setting("pinchFullscreen", true) === true
  readonly property bool pinchMaximize: setting("pinchMaximize", false) === true
  readonly property string startPanel: setting("startPanel", "last") === "first" ? "first" : "last"

  property string lastPanel: ""
  property int cursorIndex: -1
  // Which chip of a multi-select row the keyboard cursor is on.
  property int chipCursor: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function open() { controller.show() }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  // ---------------------------------------------------------------- settings

  function currentSettings() {
    return {
      threeFingers: threeFingers,
      fourFingers: fourFingers,
      workspaceSwipe: workspaceSwipe,
      stopAtLastWorkspace: stopAtLastWorkspace,
      swipeUpExpose: swipeUpExpose,
      swipeDownPanels: swipeDownPanels,
      windowSwipe: windowSwipe,
      popupArrowKeys: popupArrowKeys,
      resizeOnEdges: resizeOnEdges,
      shortSwipe: shortSwipe,
      pinchFullscreen: pinchFullscreen,
      pinchMaximize: pinchMaximize,
      startPanel: startPanel
    }
  }

  function updateSetting(key, value) {
    var next = currentSettings()
    next[key] = value
    var shellApi = bar ? bar.shell : null
    if (shellApi && typeof shellApi.updateEntryInline === "function")
      shellApi.updateEntryInline(moduleName, next)
  }

  // Plain key=value lines: gestures.lua parses them and never runs them as code.
  function hyprSettingsText() {
    return "# Written by the Swipe Control plugin (io.github.workingtitle.gestures).\n"
      + "threeFingers=" + threeFingers + "\n"
      + "fourFingers=" + fourFingers + "\n"
      + "workspaceSwipe=" + workspaceSwipe + "\n"
      + "stopAtLastWorkspace=" + stopAtLastWorkspace + "\n"
      + "swipeUpExpose=" + swipeUpExpose + "\n"
      + "swipeDownPanels=" + swipeDownPanels + "\n"
      + "windowSwipe=" + windowSwipe + "\n"
      + "popupArrowKeys=" + popupArrowKeys + "\n"
      + "resizeOnEdges=" + resizeOnEdges + "\n"
      + "shortSwipe=" + shortSwipe + "\n"
      + "pinchFullscreen=" + pinchFullscreen + "\n"
      + "pinchMaximize=" + pinchMaximize + "\n"
  }

  // Every per-monitor instance sees the same settings, so writing an identical
  // file is skipped and Hyprland only reloads the gestures on a real change.
  function syncHyprSettings() {
    var text = hyprSettingsText()
    if (hyprSettingsFile.loaded && hyprSettingsFile.text() === text) return
    hyprSettingsFile.setText(text)
  }

  onSettingsChanged: Qt.callLater(syncHyprSettings)

  FileView {
    id: hyprSettingsFile
    property bool loaded: false
    path: root.hyprSettingsPath
    atomicWrites: true
    printErrors: false
    onLoaded: { loaded = true; Qt.callLater(root.syncHyprSettings) }
    onLoadFailed: Qt.callLater(root.syncHyprSettings)
    // Reload only once the write has landed, or Hyprland reads the old file.
    onSaved: {
      hyprReload.running = false
      hyprReload.running = true
    }
  }

  Process {
    id: hyprReload
    command: ["hyprctl", "eval", "if OmarchyGestures then OmarchyGestures.reload() end"]
  }

  // ------------------------------------------------------------ bar popups

  function isModuleSlot(item) {
    return item && item.moduleName !== undefined && item.region !== undefined
      && item.activeItem !== undefined && item.panelOpen !== undefined
  }

  function collectSlots(item, out) {
    if (!item || !item.children) return
    for (var i = 0; i < item.children.length; i++) {
      var child = item.children[i]
      if (isModuleSlot(child)) out.push(child)
      else collectSlots(child, out)
    }
  }

  // All module slots on the bar window this widget instance lives in, in
  // layout order.
  function slotsOf(widget) {
    var top = widget
    while (top && top.parent) top = top.parent
    var out = []
    collectSlots(top, out)
    return out
  }

  function isPanelSlot(slot) {
    var item = slot.activeItem
    return !!item && item.visible === true && slot.visible === true && slot.width > 0
      && typeof item.open === "function" && typeof item.close === "function" && item.opened !== undefined
  }

  function instances() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    return items && items.length > 0 ? items : [root]
  }

  function screenNameOf(widget) {
    var window = widget && widget.QsWindow ? widget.QsWindow.window : null
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  // The bar on the focused monitor, where a gesture-opened popup belongs.
  function focusedInstance() {
    var items = instances()
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    for (var i = 0; i < items.length; i++) if (screenNameOf(items[i]) === focused) return items[i]
    return items[0]
  }

  function openSlot() {
    var items = instances()
    for (var i = 0; i < items.length; i++) {
      var slots = slotsOf(items[i])
      for (var j = 0; j < slots.length; j++) {
        if (isPanelSlot(slots[j]) && slots[j].activeItem.opened === true) return slots[j]
      }
    }
    return null
  }

  function rememberOpenPanel() {
    var slot = openSlot()
    if (!slot || slot.region !== "right" || slot.moduleName === lastPanel) return
    lastPanel = slot.moduleName
    lastPanelFile.setText(lastPanel + "\n")
  }

  function openPanel() {
    var slots = slotsOf(focusedInstance())
    var first = null
    for (var i = 0; i < slots.length; i++) {
      var slot = slots[i]
      if (slot.region !== "right" || !isPanelSlot(slot)) continue
      if (!first) first = slot
      if (startPanel === "last" && slot.moduleName === lastPanel) {
        slot.activeItem.open()
        return
      }
    }
    if (first) first.activeItem.open()
  }

  function step(direction) {
    var slot = openSlot()
    if (!slot || !bar || typeof bar.switchPanelFrom !== "function") return
    bar.switchPanelFrom(slot.activeItem, direction)
    rememberTimer.restart()
  }

  function closePanel() {
    var slot = openSlot()
    if (slot) slot.activeItem.close()
  }

  FileView {
    id: lastPanelFile
    path: root.lastPanelPath
    // A swipe right after the shell starts must already see the last popup.
    blockLoading: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.lastPanel = text().trim()
  }

  // A popup opened by mouse or hotkey is remembered too: gestures.lua reports
  // every popup layer that opens, and the scan waits for the bar to settle.
  Timer {
    id: rememberTimer
    interval: 150
    onTriggered: root.rememberOpenPanel()
  }

  IpcHandler {
    target: "io.github.workingtitle.gestures"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function openPanel(): void { root.openPanel() }
    function closePanel(): void { root.closePanel() }
    function togglePanel(): void { root.openSlot() ? root.closePanel() : root.openPanel() }
    function next(): void { root.step(1) }
    function previous(): void { root.step(-1) }
    function panelOpened(): void { rememberTimer.restart() }
    function expose(): void { root.eachExpose("show") }
    function closeExpose(): void { root.eachExpose("hide") }
    function toggleExpose(): void { root.eachExpose("toggle") }
    function exposeState(): string {
      var items = root.instances()
      var out = []
      for (var i = 0; i < items.length; i++) {
        var o = items[i] ? items[i].exposeOverlay : null
        out.push(o ? { screen: o.screen ? o.screen.name : "", open: o.open, shown: o.shown } : null)
      }
      return JSON.stringify(out)
    }
    function current(): string {
      var slot = root.openSlot()
      return slot ? slot.moduleName : ""
    }
  }

  // ---------------------------------------------------------------- popup UI

  readonly property var rows: [
    { key: "fingers", kind: "multi", label: "Fingers",
      options: [{ value: "threeFingers", label: "Three" }, { value: "fourFingers", label: "Four" }] },
    { key: "workspaceSwipe", kind: "toggle", label: "Swipe between workspaces",
      description: "Follows your fingers, like Spaces on macOS" },
    { key: "shortSwipe", kind: "choice", label: "Switch after",
      options: [{ value: "short", label: "Short swipe" }, { value: "half", label: "Halfway" }] },
    { key: "stopAtLastWorkspace", kind: "toggle", label: "Stop at the last workspace",
      description: "Instead of creating a new, empty one" },
    { key: "swipeUpExpose", kind: "toggle", label: "Swipe up opens Mission Control",
      description: "All windows at a glance; swipe down to close" },
    { key: "swipeDownPanels", kind: "toggle", label: "Swipe down opens bar popups",
      description: "Then swipe sideways between them" },
    { key: "startPanel", kind: "choice", label: "Popup to open",
      options: [{ value: "last", label: "Last used" }, { value: "first", label: "First" }] },
    { key: "pinchFullscreen", kind: "toggle", label: "Spread for fullscreen",
      description: "Pinch to come back" },
    { key: "pinchMaximize", kind: "choice", label: "Spread makes it",
      options: [{ value: "fullscreen", label: "Fullscreen" }, { value: "maximize", label: "Maximized" }] },
    { key: "resizeOnEdges", kind: "toggle", label: "Drag edges to resize",
      description: "Pull a window's edge or corner, like on macOS" },
    { key: "windowSwipe", kind: "toggle", label: "Shift + swipe moves the window",
      description: "Carries the window to the next workspace" },
    { key: "popupArrowKeys", kind: "toggle", label: "Super + arrows switch popups",
      description: "Instead of window focus while a popup is open" }
  ]

  function rowValue(row) {
    if (row.key === "shortSwipe") return shortSwipe ? "short" : "half"
    if (row.key === "pinchMaximize") return pinchMaximize ? "maximize" : "fullscreen"
    return currentSettings()[row.key]
  }

  function setChoice(row, value) {
    if (row.key === "shortSwipe") value = value === "short"
    else if (row.key === "pinchMaximize") value = value === "maximize"
    updateSetting(row.key, value)
  }

  // Each chip of a multi-select row is its own boolean setting. The last one
  // on stays on, so some gestures always remain.
  function toggleChip(key) {
    var current = currentSettings()
    var on = 0
    for (var k in { threeFingers: 1, fourFingers: 1 }) if (current[k]) on++
    if (current[key] && on <= 1) return
    updateSetting(key, !current[key])
  }

  function activateRow(index, delta) {
    var row = rows[index]
    if (!row) return
    if (row.kind === "toggle") {
      updateSetting(row.key, !currentSettings()[row.key])
      return
    }
    if (row.kind === "multi") {
      toggleChip(row.options[Math.max(0, Math.min(row.options.length - 1, chipCursor))].value)
      return
    }
    var options = row.options
    var current = 0
    for (var i = 0; i < options.length; i++) if (options[i].value === rowValue(row)) current = i
    var next = (current + (delta || 1) + options.length) % options.length
    setChoice(row, options[next].value)
  }

  onOpenedChanged: {
    if (!opened) cursorIndex = -1
    else refreshSetup()
  }

  // ------------------------------------------------------------ Hyprland setup

  // Hyprland loads gestures.lua from a marked block in ~/.config/hypr/input.lua.
  // setup.sh adds or removes that block, and only when the buttons below are
  // pressed. hyprSetup is "enabled", "manual" (a hand-written block) or
  // "disabled"; hyprActive says whether Hyprland has the module loaded.
  readonly property string setupScript: Qt.resolvedUrl("setup.sh").toString().replace("file://", "")
  property string hyprSetup: ""
  property bool hyprActive: true

  function refreshSetup() {
    if (!setupStatus.running) setupStatus.running = true
    if (!hyprStatus.running) hyprStatus.running = true
  }

  function runSetup(action) {
    if (setupAction.running) return
    setupAction.command = ["bash", setupScript, action]
    setupAction.running = true
  }

  Component.onCompleted: refreshSetup()

  Process {
    id: setupStatus
    command: ["bash", root.setupScript, "status"]
    stdout: StdioCollector { onStreamFinished: root.hyprSetup = text.trim() }
  }

  Process {
    id: hyprStatus
    command: ["hyprctl", "repl", "return type(OmarchyGestures)"]
    stdout: StdioCollector { onStreamFinished: root.hyprActive = text.trim() === "table" }
  }

  Process {
    id: setupAction
    onExited: setupRefreshTimer.restart()
  }

  // setup.sh reloads Hyprland; give it a moment before asking again.
  Timer {
    id: setupRefreshTimer
    interval: 600
    onTriggered: root.refreshSetup()
  }

  // ---------------------------------------------------------- Mission Control

  // One overlay per bar, so every monitor shows its own workspaces like
  // Mission Control does on each display.
  Expose {
    id: expose
    screen: button.QsWindow.window ? button.QsWindow.window.screen : null
  }

  function eachExpose(method) {
    var items = instances()
    for (var i = 0; i < items.length; i++) {
      var overlay = items[i] ? items[i].exposeOverlay : null
      if (overlay && typeof overlay[method] === "function") overlay[method]()
    }
  }

  readonly property var exposeOverlay: expose

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(0xF0ABF)
    slotSize: Style.bar.iconSlot
    tooltipText: "Swipe Control"
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          root.cursorIndex = root.cursorIndex < 0 ? 0
            : Math.max(0, Math.min(root.rows.length - 1, root.cursorIndex + dy))
        } else if (dx !== 0 && root.cursorIndex >= 0 && root.rows[root.cursorIndex].kind === "choice") {
          root.activateRow(root.cursorIndex, dx)
        } else if (dx !== 0 && root.cursorIndex >= 0 && root.rows[root.cursorIndex].kind === "multi") {
          var count = root.rows[root.cursorIndex].options.length
          root.chipCursor = Math.max(0, Math.min(count - 1, root.chipCursor + dx))
        }
      }
      onActivateRequested: if (root.cursorIndex >= 0) root.activateRow(root.cursorIndex, 1)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Text {
          text: "SWIPE CONTROL"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        Rectangle {
          visible: !root.hyprActive
          width: parent.width
          implicitHeight: setupColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: "transparent"
          border.width: 1
          border.color: Color.accent

          Column {
            id: setupColumn
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: root.hyprSetup === "disabled"
                ? "Hyprland does not load the gestures yet. Enabling adds a marked block to ~/.config/hypr/input.lua (after a backup) and reloads Hyprland."
                : "input.lua has the block, but Hyprland has not loaded it. Check hyprctl configerrors."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Button {
              visible: root.hyprSetup === "disabled"
              text: setupAction.running ? "Enabling…" : "Enable in Hyprland"
              bordered: true
              enabled: !setupAction.running
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.runSetup("enable")
            }
          }
        }

        Repeater {
          model: root.rows

          delegate: Item {
            id: rowItem
            required property var modelData
            required property int index
            width: column.width
            implicitHeight: modelData.kind === "toggle" ? toggle.implicitHeight : choiceRow.implicitHeight

            Toggle {
              id: toggle
              visible: rowItem.modelData.kind === "toggle"
              width: parent.width
              label: rowItem.modelData.label
              description: rowItem.modelData.description || ""
              checked: rowItem.modelData.kind === "toggle" && root.rowValue(rowItem.modelData) === true
              hasCursor: root.cursorIndex === rowItem.index
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.activateRow(rowItem.index, 1)
              onHovered: function(isHovered) { if (isHovered) root.cursorIndex = rowItem.index }
            }

            Item {
              id: choiceRow
              visible: rowItem.modelData.kind === "choice" || rowItem.modelData.kind === "multi"
              width: parent.width
              implicitHeight: Math.max(choiceLabel.implicitHeight, choices.implicitHeight, chips.implicitHeight)

              Text {
                id: choiceLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: rowItem.modelData.label
                color: root.cursorIndex === rowItem.index ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              ButtonGroup {
                id: choices
                visible: rowItem.modelData.kind === "choice"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                options: rowItem.modelData.options || []
                value: rowItem.modelData.kind === "choice" ? String(root.rowValue(rowItem.modelData)) : ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                focusable: false
                onChanged: function(value) { root.setChoice(rowItem.modelData, value) }
                onHovered: function(i, isHovered) { if (isHovered) root.cursorIndex = rowItem.index }
              }

              // Like the ButtonGroup chips, but every chip toggles on its own.
              Row {
                id: chips
                visible: rowItem.modelData.kind === "multi"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Repeater {
                  model: rowItem.modelData.kind === "multi" ? rowItem.modelData.options : []

                  delegate: Button {
                    required property var modelData
                    required property int index
                    text: modelData.label
                    selected: root.currentSettings()[modelData.value] === true
                    hasCursor: root.cursorIndex === rowItem.index && root.chipCursor === index
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.toggleChip(modelData.value)
                    onHovered: function(isHovered) {
                      if (!isHovered) return
                      root.cursorIndex = rowItem.index
                      root.chipCursor = index
                    }
                  }
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          text: "Popup open: swipe sideways to switch, up to close."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          visible: root.hyprSetup === "enabled"
          text: setupAction.running ? "Removing…" : "Remove from Hyprland"
          bordered: true
          enabled: !setupAction.running
          foreground: root.dim
          fontFamily: root.fontFamily
          onClicked: root.runSetup("disable")
        }
      }
    }
  }
}
