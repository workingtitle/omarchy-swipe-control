import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// Mission Control for one monitor: the monitor's workspaces as a strip of
// thumbnails along the top, and the windows of the active workspace spread
// out below with live previews. Click a window to focus it, click a workspace
// to switch to it, or drag a window onto a workspace to move it there.
//
// gestures.lua recognises the layer namespace below: while it is on screen,
// swiping down closes it instead of opening a bar popup.
Scope {
  id: root

  property var screen: null
  property bool open: false
  // Drives the enter/leave animation separately from `open`, so the window
  // tiles can glide back to their real positions before the layer unmaps.
  property bool shown: false
  property int selected: -1

  readonly property var monitor: screen ? Hyprland.monitorFor(screen) : null
  readonly property var activeWorkspace: monitor ? monitor.activeWorkspace : null
  readonly property color foreground: Color.foreground
  readonly property color accent: Color.accent
  readonly property int animationMs: 220

  function show() {
    if (open) return
    Hyprland.refreshToplevels()
    Hyprland.refreshWorkspaces()
    selected = -1
    shown = false
    open = true
    Qt.callLater(function() { root.shown = true })
  }

  function hide() {
    if (!open || !shown) return
    shown = false
    unmapTimer.restart()
  }

  function toggle() { open && shown ? hide() : show() }

  Timer {
    id: unmapTimer
    interval: root.animationMs
    onTriggered: root.open = false
  }

  function dispatch(lua) { Hyprland.dispatch(lua) }

  function focusWindow(toplevel) {
    dispatch("hl.dsp.focus({ window = \"address:0x" + toplevel.address + "\" })")
    hide()
  }

  function focusWorkspace(workspace) {
    dispatch("hl.dsp.focus({ workspace = \"" + workspace.id + "\" })")
    hide()
  }

  // Hyprland only moves the focused window, so focus it first. The overlay
  // stays open, and the tile leaves the grid once Hyprland reports the move.
  function moveWindow(toplevel, workspace) {
    if (!workspace || !toplevel.workspace || toplevel.workspace.id === workspace.id) return
    dispatch("hl.dsp.focus({ window = \"address:0x" + toplevel.address + "\" })")
    dispatch("hl.dsp.window.move({ workspace = \"" + workspace.id + "\", follow = false })")
    Qt.callLater(Hyprland.refreshToplevels)
  }

  // ------------------------------------------------------------------ model

  readonly property var workspaces: {
    var list = []
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) {
      var ws = all[i]
      if (ws.id >= 1 && ws.monitor === root.monitor) list.push(ws)
    }
    list.sort(function(a, b) { return a.id - b.id })
    return list
  }

  function geometry(toplevel) {
    var ipc = toplevel.lastIpcObject || {}
    var at = ipc.at || [0, 0]
    var size = ipc.size || [0, 0]
    var mx = monitor ? monitor.x : 0
    var my = monitor ? monitor.y : 0
    return { x: at[0] - mx, y: at[1] - my, w: Math.max(1, size[0]), h: Math.max(1, size[1]) }
  }

  function windowsOf(workspace) {
    if (!workspace) return []
    var list = []
    var all = Hyprland.toplevels.values
    for (var i = 0; i < all.length; i++) {
      var t = all[i]
      var ipc = t.lastIpcObject || {}
      if (t.workspace === workspace && ipc.hidden !== true && ipc.mapped !== false) list.push(t)
    }
    // Reading order of the real layout, so the grid keeps the windows roughly
    // where they were.
    list.sort(function(a, b) {
      var ga = root.geometry(a), gb = root.geometry(b)
      var rowA = Math.round((ga.y + ga.h / 2) / 200), rowB = Math.round((gb.y + gb.h / 2) / 200)
      return rowA !== rowB ? rowA - rowB : (ga.x - gb.x)
    })
    return list
  }

  readonly property var windows: open ? windowsOf(activeWorkspace) : []

  // Rows of tiles that keep each window's aspect ratio. Every row count is
  // tried and the one covering the most area wins; windows are never scaled
  // up past their real size.
  function computeLayout(wins, W, H, gap) {
    var n = wins.length
    if (n === 0 || W <= 0 || H <= 0) return []
    var geos = wins.map(function(t) { return root.geometry(t) })
    var best = null

    for (var r = 1; r <= n; r++) {
      var per = Math.ceil(n / r)
      var rows = []
      for (var i = 0; i < n; i += per) rows.push(geos.slice(i, i + per).map(function(g, k) { return { g: g, index: i + k } }))
      var rowH = (H - gap * (rows.length - 1)) / rows.length
      var area = 0
      var laidRows = []
      for (var j = 0; j < rows.length; j++) {
        var row = rows[j]
        var natural = 0
        for (var k = 0; k < row.length; k++) natural += row[k].g.w / row[k].g.h * rowH
        var fit = Math.min(1, (W - gap * (row.length - 1)) / natural)
        var tiles = []
        var rowHeight = 0
        for (var m = 0; m < row.length; m++) {
          var g = row[m].g
          var h = Math.min(rowH * fit, g.h)
          var w = g.w / g.h * h
          tiles.push({ index: row[m].index, w: w, h: h })
          rowHeight = Math.max(rowHeight, h)
          area += w * h
        }
        laidRows.push({ tiles: tiles, height: rowHeight })
      }
      if (!best || area > best.area) best = { area: area, rows: laidRows }
    }

    var out = []
    var totalH = gap * (best.rows.length - 1)
    for (var a = 0; a < best.rows.length; a++) totalH += best.rows[a].height
    var y = (H - totalH) / 2
    for (var b = 0; b < best.rows.length; b++) {
      var lr = best.rows[b]
      var rowW = gap * (lr.tiles.length - 1)
      for (var c = 0; c < lr.tiles.length; c++) rowW += lr.tiles[c].w
      var x = (W - rowW) / 2
      for (var d = 0; d < lr.tiles.length; d++) {
        var t = lr.tiles[d]
        out[t.index] = { x: x, y: y + (lr.height - t.h) / 2, w: t.w, h: t.h }
        x += t.w + gap
      }
      y += lr.height + gap
    }
    return out
  }

  // ----------------------------------------------------------------- window

  PanelWindow {
    id: overlay
    visible: root.open
    screen: root.screen
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "omarchy-gestures-expose"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property real stripHeight: Math.round(height * 0.14)
    readonly property real margin: Math.round(width * 0.04)
    readonly property rect gridArea: Qt.rect(margin, stripHeight + margin * 1.4,
      width - margin * 2, height - stripHeight - margin * 2.4)
    readonly property var layout: root.computeLayout(root.windows, gridArea.width, gridArea.height, Math.round(margin * 0.6))

    property var dragWindow: null
    property point dragPoint: Qt.point(0, 0)

    function workspaceAt(x, y) {
      for (var i = 0; i < strip.children.length; i++) {
        var thumb = strip.children[i]
        if (!thumb.workspace) continue
        var p = thumb.mapFromItem(content, x, y)
        if (p.x >= 0 && p.y >= 0 && p.x <= thumb.width && p.y <= thumb.height) return thumb.workspace
      }
      return null
    }

    Item {
      id: content
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        var n = root.windows.length
        if (event.key === Qt.Key_Escape) root.hide()
        else if ((event.key === Qt.Key_Right || event.key === Qt.Key_Tab || event.key === Qt.Key_L) && n > 0)
          root.selected = (root.selected + 1) % n
        else if ((event.key === Qt.Key_Left || event.key === Qt.Key_Backtab || event.key === Qt.Key_H) && n > 0)
          root.selected = (root.selected - 1 + n) % n
        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.selected >= 0 && root.selected < n)
          root.focusWindow(root.windows[root.selected])
        else return
        event.accepted = true
      }

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.62)
        opacity: root.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }
      }

      // A click on empty space closes Mission Control, like on macOS.
      MouseArea {
        anchors.fill: parent
        onClicked: root.hide()
      }

      // ------------------------------------------------------- workspace strip

      Row {
        id: strip
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.shown ? overlay.margin * 0.5 : -overlay.stripHeight
        spacing: Math.round(overlay.margin * 0.4)
        Behavior on y { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }

        Repeater {
          model: root.workspaces

          delegate: Item {
            id: thumb
            required property var modelData
            readonly property var workspace: modelData
            readonly property bool active: modelData === root.activeWorkspace
            readonly property bool dropTarget: overlay.dragWindow !== null
              && overlay.workspaceAt(overlay.dragPoint.x, overlay.dragPoint.y) === modelData
            readonly property real ratio: height / Math.max(1, overlay.height)

            height: overlay.stripHeight
            width: Math.round(height * overlay.width / Math.max(1, overlay.height))

            Rectangle {
              anchors.fill: parent
              color: Color.background
              radius: Style.cornerRadius
              clip: true
              border.width: thumb.active || thumb.dropTarget || thumbMouse.containsMouse ? 2 : 1
              border.color: thumb.active || thumb.dropTarget ? root.accent
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, thumbMouse.containsMouse ? 0.5 : 0.2)

              Repeater {
                model: root.open ? root.windowsOf(thumb.workspace) : []
                delegate: ScreencopyView {
                  required property var modelData
                  readonly property var g: root.geometry(modelData)
                  x: g.x * thumb.ratio
                  y: g.y * thumb.ratio
                  width: g.w * thumb.ratio
                  height: g.h * thumb.ratio
                  captureSource: modelData.wayland
                  live: false
                }
              }
            }

            Text {
              anchors.top: parent.bottom
              anchors.topMargin: 4
              anchors.horizontalCenter: parent.horizontalCenter
              text: thumb.workspace.name || String(thumb.workspace.id)
              color: thumb.active ? root.accent : root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: thumbMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.focusWorkspace(thumb.workspace)
            }
          }
        }
      }

      // ---------------------------------------------------------- window grid

      Repeater {
        model: root.windows

        delegate: Item {
          id: tile
          required property var modelData
          required property int index
          readonly property var real: root.geometry(modelData)
          readonly property var slot: overlay.layout[index] || { x: real.x, y: real.y, w: real.w, h: real.h }
          readonly property bool hot: tileMouse.containsMouse || root.selected === index
          readonly property bool dragging: overlay.dragWindow === modelData

          x: root.shown ? overlay.gridArea.x + slot.x : real.x
          y: root.shown ? overlay.gridArea.y + slot.y : real.y
          width: root.shown ? slot.w : real.w
          height: root.shown ? slot.h : real.h
          opacity: dragging ? 0.35 : 1
          z: hot ? 2 : 1

          Behavior on x { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }
          Behavior on y { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }
          Behavior on width { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }
          Behavior on height { NumberAnimation { duration: root.animationMs; easing.type: Easing.OutCubic } }

          ScreencopyView {
            id: preview
            anchors.fill: parent
            captureSource: tile.modelData.wayland
            live: root.open
          }

          Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            color: "transparent"
            radius: Style.cornerRadius
            border.width: 3
            border.color: root.accent
            visible: tile.hot && root.shown
          }

          Rectangle {
            visible: tile.hot && root.shown
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.bottom
            anchors.topMargin: 8
            width: Math.min(titleText.implicitWidth + 20, overlay.width * 0.4)
            height: titleText.implicitHeight + 8
            radius: height / 2
            color: Color.background

            Text {
              id: titleText
              anchors.centerIn: parent
              width: parent.width - 20
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: tile.modelData.title
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            property point pressPoint

            onEntered: root.selected = -1
            onPressed: function(mouse) { pressPoint = Qt.point(mouse.x, mouse.y) }
            onPositionChanged: function(mouse) {
              if (!pressed) return
              if (!overlay.dragWindow && Math.hypot(mouse.x - pressPoint.x, mouse.y - pressPoint.y) > 12)
                overlay.dragWindow = tile.modelData
              if (overlay.dragWindow) overlay.dragPoint = mapToItem(content, mouse.x, mouse.y)
            }
            onReleased: function(mouse) {
              if (overlay.dragWindow) {
                var target = overlay.workspaceAt(overlay.dragPoint.x, overlay.dragPoint.y)
                var dragged = overlay.dragWindow
                overlay.dragWindow = null
                if (target) root.moveWindow(dragged, target)
              } else {
                root.focusWindow(tile.modelData)
              }
            }
          }
        }
      }

      // The window being dragged, following the pointer at thumbnail size.
      ScreencopyView {
        visible: overlay.dragWindow !== null
        captureSource: overlay.dragWindow ? overlay.dragWindow.wayland : null
        live: false
        width: overlay.stripHeight * 1.2
        height: overlay.dragWindow ? width * root.geometry(overlay.dragWindow).h / root.geometry(overlay.dragWindow).w : 0
        x: overlay.dragPoint.x - width / 2
        y: overlay.dragPoint.y - height / 2
        z: 10
        opacity: 0.9
      }
    }
  }
}
