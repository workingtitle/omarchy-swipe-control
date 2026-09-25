import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Trackpad gestures: a settings popup in the bar, plus the popup navigation
// the Hyprland side (gestures.lua) calls over IPC while a bar popup is open.
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
  readonly property string hyprSettingsPath: stateDir + "/gestures-settings.lua"
  readonly property string lastPanelPath: stateDir + "/gestures-last-panel"

  readonly property int fingers: setting("fingers", 3) === 4 ? 4 : 3
  readonly property bool workspaceSwipe: setting("workspaceSwipe", true) === true
  readonly property bool stopAtLastWorkspace: setting("stopAtLastWorkspace", true) === true
  readonly property bool swipeUpExpose: setting("swipeUpExpose", true) === true
  readonly property bool swipeDownPanels: setting("swipeDownPanels", true) === true
  readonly property bool windowSwipe: setting("windowSwipe", true) === true
  readonly property string startPanel: setting("startPanel", "last") === "first" ? "first" : "last"

  property string lastPanel: ""
  property int cursorIndex: -1

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
      fingers: fingers,
      workspaceSwipe: workspaceSwipe,
      stopAtLastWorkspace: stopAtLastWorkspace,
      swipeUpExpose: swipeUpExpose,
      swipeDownPanels: swipeDownPanels,
      windowSwipe: windowSwipe,
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

  function hyprSettingsText() {
    return "-- Written by the io.github.workingtitle.gestures shell plugin.\n"
      + "return {\n"
      + "  fingers = " + fingers + ",\n"
      + "  workspaceSwipe = " + workspaceSwipe + ",\n"
      + "  stopAtLastWorkspace = " + stopAtLastWorkspace + ",\n"
      + "  swipeUpExpose = " + swipeUpExpose + ",\n"
      + "  swipeDownPanels = " + swipeDownPanels + ",\n"
      + "  windowSwipe = " + windowSwipe + ",\n"
      + "}\n"
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
    { key: "fingers", kind: "choice", label: "Fingers",
      options: [{ value: "3", label: "Three" }, { value: "4", label: "Four" }] },
    { key: "workspaceSwipe", kind: "toggle", label: "Swipe between workspaces",
      description: "Left and right follow your fingers, like Spaces on macOS" },
    { key: "stopAtLastWorkspace", kind: "toggle", label: "Stop at the last workspace",
      description: "Otherwise swiping past it creates a new, empty one" },
    { key: "swipeUpExpose", kind: "toggle", label: "Swipe up opens Mission Control",
      description: "All windows at a glance; swipe down to close. Up also closes a bar popup" },
    { key: "swipeDownPanels", kind: "toggle", label: "Swipe down opens bar popups",
      description: "Then swipe left and right to move between them" },
    { key: "startPanel", kind: "choice", label: "Popup to open",
      options: [{ value: "last", label: "Last used" }, { value: "first", label: "First" }] },
    { key: "windowSwipe", kind: "toggle", label: "Shift + swipe moves the window",
      description: "Drags the focused window to the next workspace, even past the last" }
  ]

  function rowValue(row) {
    return row.key === "fingers" ? String(fingers) : currentSettings()[row.key]
  }

  function setChoice(row, value) {
    updateSetting(row.key, row.key === "fingers" ? Number(value) : value)
  }

  function activateRow(index, delta) {
    var row = rows[index]
    if (!row) return
    if (row.kind === "toggle") {
      updateSetting(row.key, !currentSettings()[row.key])
      return
    }
    var options = row.options
    var current = 0
    for (var i = 0; i < options.length; i++) if (options[i].value === rowValue(row)) current = i
    var next = (current + (delta || 1) + options.length) % options.length
    setChoice(row, options[next].value)
  }

  onOpenedChanged: if (!opened) cursorIndex = -1

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
    tooltipText: "Trackpad gestures"
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
          text: "TRACKPAD GESTURES"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
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
              visible: rowItem.modelData.kind === "choice"
              width: parent.width
              implicitHeight: Math.max(choiceLabel.implicitHeight, choices.implicitHeight)

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
            }
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          text: "With a popup open, swipe left or right to switch popups and up to close. Tab works too."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
