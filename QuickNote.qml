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

  readonly property string script: Qt.resolvedUrl("save-note.sh").toString().replace("file://", "")

  // Obsidian's file explorer lists notes by filename, so this previews the
  // name the file will actually get rather than deriving one from the text.
  readonly property string noteTitle: {
    if (root.mode === "daily")
      return root.info ? root.info.dailyNote.split("/").pop().replace(/\.md$/, "") : "…"
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

      Column {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.md

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: root.noteTitle
          color: root.foreground
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Item {
          width: parent.width
          height: Style.space(28)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - buttons.width - Style.space(12)
            elide: Text.ElideMiddle
            text: "→ " + root.destination
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

        Flickable {
          width: parent.width
          height: parent.height - Style.space(136)
          contentWidth: width
          contentHeight: editor.paintedHeight
          clip: true
          interactive: true

          TextEdit {
            id: editor
            width: parent.width
            color: root.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            selectionColor: root.accent
            focus: true

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

        Text {
          width: parent.width
          elide: Text.ElideMiddle
          color: root.failed ? root.urgent : root.foreground
          opacity: root.status ? 0.85 : 0.45
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
          text: root.status
                ? (root.failed ? root.status
                               : (root.mode === "daily" ? "Appended → " : "Saved → ")
                                 + root.status.split("/").slice(-2).join("/"))
                : "Ctrl+Enter save · Ctrl+Shift+Enter save & open · Tab switch · Esc discard"
        }
      }
    }
  }
}
