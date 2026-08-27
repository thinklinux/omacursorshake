import QtQuick
import qs.Commons
import qs.Ui

// Bar button plus settings popup. The compositor plugin itself lives in
// Service.qml so shake-to-find keeps working while this panel is closed.
Panel {
  id: root
  moduleName: "tvalkanov.omacursorshake"
  ipcTarget: "tvalkanov.omacursorshake"

  readonly property var shakeService: bar && bar.shell
    ? bar.shell.serviceFor(moduleName)
    : null
  readonly property bool serviceReady: !!shakeService
  readonly property var currentSettings: serviceReady ? shakeService.settings : ({
    enabled: true, threshold: 6.0, base: 4.0, timeout: 2000
  })

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.45)

  readonly property string icon: {
    if (!serviceReady) return "󰍽"
    if (shakeService.phase === "error") return "󰅙"
    if (shakeService.phase === "building" || shakeService.busy) return "󰦖"
    if (shakeService.active) return "󰍽"
    return "󰍾"
  }

  function setEnabled(value) {
    if (serviceReady) shakeService.updateSettings({ enabled: value === true })
  }

  function setThreshold(value) {
    if (serviceReady) shakeService.updateSettings({ threshold: value })
  }

  function setBase(value) {
    if (serviceReady) shakeService.updateSettings({ base: value })
  }

  function setTimeoutMs(value) {
    if (serviceReady) shakeService.updateSettings({ timeout: value })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    dimmed: !root.serviceReady || (root.shakeService && !root.shakeService.active)
    tooltipText: root.serviceReady ? root.shakeService.moodLabel : "Shake to find"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        root.setEnabled(!(root.currentSettings.enabled === true))
      } else {
        root.toggle()
      }
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.close()

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍽"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.serviceReady && root.shakeService.active ? 1.0 : 0.5
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: powerSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Shake to find"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.serviceReady ? root.shakeService.statusText : "Starting…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }

          ToggleSwitch {
            id: powerSwitch
            checked: root.currentSettings.enabled === true
            busy: root.serviceReady && root.shakeService.busy
            foreground: root.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.setEnabled(!(root.currentSettings.enabled === true))
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(sensHeader.implicitHeight, sensValue.implicitHeight)

            PanelSectionHeader {
              id: sensHeader
              text: "SHAKE SENSITIVITY"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: sensValue
              text: Number(root.currentSettings.threshold).toFixed(1)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            width: parent.width
            text: "Lower detects a shake sooner"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSlider {
            id: sensSlider
            bar: root.bar
            width: parent.width
            minimum: 2
            maximum: 12
            step: 0.5
            value: Number(root.currentSettings.threshold)
            onReleased: function(v) { root.setThreshold(v) }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(magHeader.implicitHeight, magValue.implicitHeight)

            PanelSectionHeader {
              id: magHeader
              text: "MAGNIFICATION"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: magValue
              text: Number(root.currentSettings.base).toFixed(1) + "×"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: magSlider
            bar: root.bar
            width: parent.width
            minimum: 2
            maximum: 8
            step: 0.5
            value: Number(root.currentSettings.base)
            onReleased: function(v) { root.setBase(v) }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(holdHeader.implicitHeight, holdValue.implicitHeight)

            PanelSectionHeader {
              id: holdHeader
              text: "HOLD"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: holdValue
              text: (Number(root.currentSettings.timeout) / 1000).toFixed(1) + "s"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelSlider {
            id: holdSlider
            bar: root.bar
            width: parent.width
            minimum: 500
            maximum: 4000
            step: 100
            integer: true
            value: Number(root.currentSettings.timeout)
            onReleased: function(v) { root.setTimeoutMs(v) }
          }
        }

        Text {
          width: parent.width
          visible: root.serviceReady && root.shakeService.lastError !== ""
          text: root.shakeService.lastError
          color: bar ? bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }
    }
  }
}
