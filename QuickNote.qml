import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  // "note" writes a new file into the quick-notes folder; "daily" appends a
  // timestamped section to today's daily note. The script owns both, so the
  // overlay only has to pass a flag.
  property string mode: "note"
  property var info: null
  property string savedPath: ""
  property bool openAfterSave: false

  property string status: ""
  property bool failed: false

  // Qt.resolvedUrl percent-encodes, so a plugin path containing a space or #
  // would come back as %20/%23 and fail to execute. Decode it back.
  readonly property string script: decodeURIComponent(
    Qt.resolvedUrl("save-note.sh").toString().replace(/^file:\/\//, ""))

  // Obsidian's file explorer lists notes by filename, so this previews the
  // name the file will actually get rather than deriving one from the text.
  readonly property string noteTitle: {
    if (root.mode === "daily")
      return (root.info && root.info.dailyNote)
        ? String(root.info.dailyNote).split("/").pop().replace(/\.md$/, "") : "…"
    return Qt.formatDateTime(new Date(), "yyyyMMddhhmm")
  }

  readonly property string destination: {
    if (!root.info) return "…"
    return root.info.vault + " / " + (root.mode === "daily" ? root.info.dailyNote : root.info.noteFolder)
  }

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.popups.border
  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  property color urgent: Color.urgent

  function open(payloadJson) {
    root.status = ""
    root.failed = false
    root.savedPath = ""
    root.openAfterSave = false
    // Always open in the default mode. A sticky mode means the destination
    // depends on what you did last time, which is exactly the kind of thing
    // you forget at the moment you are trying to capture a thought quickly.
    root.mode = "note"
    editor.text = ""
    root.opened = true
    infoProc.running = true
    Qt.callLater(function() { editor.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.chrisalt224.quick-note")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function switchMode() {
    root.mode = (root.mode === "note") ? "daily" : "note"
    editor.forceActiveFocus()
  }

  function save(thenOpen) {
    if (!editor.text || !editor.text.replace(/\s/g, "")) { root.dismiss(); return }
    // Coerce: the key handler passes a modifier bitmask (an integer), not a bool.
    root.openAfterSave = !!thenOpen
    // Guard against a second Ctrl+Enter landing while the first is still in
    // flight, which would write the note twice.
    if (saveProc.running) return
    // The body is passed as an argument. Linux caps a single argument at
    // MAX_ARG_STRLEN (32 pages, 131072 bytes) and exec fails above it, so
    // refuse clearly rather than losing the note. Measured in bytes, not
    // characters: one non-ASCII character can be up to four of them.
    var bytes = encodeURIComponent(editor.text).replace(/%[0-9A-F]{2}/gi, "x").length
    if (bytes > 120000) {
      root.failed = true
      root.status = "note too large to save (" + Math.round(bytes / 1024) + " KB, limit 117 KB)"
      return
    }
    saveProc.command = root.mode === "daily"
      ? [root.script, "--daily", editor.text]
      : [root.script, editor.text]
    saveProc.running = true
  }

  Process {
    id: infoProc
    command: [root.script, "--info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.info = JSON.parse(text) } catch (e) { root.info = null }
      }
    }
  }

  Process {
    id: saveProc
    // A failure that printed nothing to stderr would otherwise leave the
    // overlay open with no explanation.
    onExited: function(code, status) {
      if (code !== 0 && !root.failed) {
        root.failed = true
        if (!root.status) root.status = "save failed (exit " + code + ")"
      }
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.savedPath = text.trim()
        root.failed = false
        if (!root.savedPath) return
        root.status = root.savedPath
        if (root.openAfterSave) {
          // The script builds the percent-encoded obsidian:// URI and hands it to
          // xdg-open, which the registered scheme handler routes to Obsidian.
          openProc.command = [root.script, "--open", root.savedPath]
          openProc.running = true
        }
        closeTimer.start()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.trim()) { root.status = text.trim(); root.failed = true }
      }
    }
  }

  Process {
    id: openProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text.trim()) console.log("quick-note open failed:", text.trim()) }
    }
  }

  Timer {
    id: closeTimer
    interval: 550
    onTriggered: root.dismiss()
  }

  component ActionButton: Rectangle {
    id: btn
    property string label: ""
    property bool active: false
    signal clicked()
    implicitWidth: btnText.implicitWidth + Style.space(20)
    implicitHeight: Style.space(26)
    radius: Style.cornerRadius / 2
    color: btn.active ? root.accent
                      : (hover.hovered ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                                       : "transparent")
    border.color: btn.active ? root.accent : root.borderColor
    border.width: 1
    Text {
      // Paths and subprocess output are data, never markup: AutoText would
      // interpret tags and resource references coming from those sources.
      textFormat: Text.PlainText
      id: btnText
      anchors.centerIn: parent
      text: btn.label
      color: btn.active ? root.background : root.foreground
      opacity: btn.active ? 1.0 : 0.8
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body
    }
    HoverHandler { id: hover }
    TapHandler { onTapped: btn.clicked() }
  }

  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "quick-note-obsidian"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(620), parent.width - Style.space(80))
      height: Math.min(Style.space(380), parent.height - Style.space(80))
      radius: Style.cornerRadius
      color: root.background
      border.color: root.failed ? root.urgent : root.borderColor
      border.width: Math.max(1, Style.space(2))

      MouseArea { anchors.fill: parent; onClicked: editor.forceActiveFocus() }

      Item {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding

        Text {
          // Paths and subprocess output are data, never markup: AutoText would
          // interpret tags and resource references coming from those sources.
          textFormat: Text.PlainText
          id: titleText
          anchors { top: parent.top; left: parent.left; right: parent.right }
          elide: Text.ElideRight
          text: root.noteTitle
          color: root.foreground
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Item {
          id: headerRow
          anchors { top: titleText.bottom; left: parent.left; right: parent.right }
          anchors.topMargin: Style.spacing.md
          height: Style.space(28)

          Text {
            // Paths and subprocess output are data, never markup: AutoText would
            // interpret tags and resource references coming from those sources.
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - buttons.width - Style.space(12)
            elide: Text.ElideMiddle
            text: "\u2192 " + root.destination
            color: root.foreground
            opacity: 0.65
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }

          Row {
            id: buttons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            ActionButton {
              label: root.mode === "daily" ? "Daily" : "New note"
              active: root.mode === "daily"
              onClicked: root.switchMode()
            }
            ActionButton {
              label: "Open in Obsidian"
              onClicked: root.save(true)
            }
          }
        }

        // Pinned to the bottom so the hint sits on the floor of the card rather
        // than wherever the editor happens to end.
        Text {
          // Paths and subprocess output are data, never markup: AutoText would
          // interpret tags and resource references coming from those sources.
          textFormat: Text.PlainText
          id: hintText
          anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
          elide: Text.ElideMiddle
          color: root.failed ? root.urgent : root.foreground
          opacity: root.status ? 0.85 : 0.45
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          text: root.status
                ? (root.failed ? root.status
                               : (root.mode === "daily" ? "Appended \u2192 " : "Saved \u2192 ")
                                 + root.status.split("/").slice(-2).join("/"))
                : "Ctrl+Enter save \u00b7 Ctrl+Shift+Enter save & open \u00b7 Tab switch \u00b7 Esc discard"
        }

        Flickable {
          id: flick
          anchors {
            top: headerRow.bottom
            bottom: hintText.top
            left: parent.left
            right: parent.right
          }
          anchors.topMargin: Style.spacing.md
          anchors.bottomMargin: Style.spacing.md
          contentWidth: width
          contentHeight: Math.max(editor.paintedHeight, editor.implicitHeight)
          clip: true
          interactive: true
          boundsBehavior: Flickable.StopAtBounds

          // Keep the caret on screen: a Flickable does not follow it on its own,
          // so text past the bottom of the card would be typed into the void.
          function ensureVisible(r) {
            if (contentHeight <= height) { contentY = 0; return }
            if (contentY >= r.y) contentY = r.y
            else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
          }

          TextEdit {
            id: editor
            width: flick.width
            color: root.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            selectionColor: root.accent
            focus: true

            // Both signals matter: the caret moves on arrow keys without the text
            // changing, and fast input can outrun layout, leaving cursorRectangle
            // stale until the next frame -- hence the deferred second pass.
            onCursorRectangleChanged: flick.ensureVisible(cursorRectangle)
            onTextChanged: Qt.callLater(function() { flick.ensureVisible(editor.cursorRectangle) })

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.dismiss()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab) {
                root.switchMode()
                event.accepted = true
              } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                         && (event.modifiers & Qt.ControlModifier)) {
                root.save(event.modifiers & Qt.ShiftModifier)
                event.accepted = true
              }
            }
          }
        }
      }
    }
  }
}
