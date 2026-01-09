import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: app
    width: 390
    height: 720
    visible: true
    title: "Daily Actions"

    color: "#f2f2f2"

    property bool allSoundsDisabled: false

    ListModel {
        id: actionModel

        ListElement {
            text: "Übung machen"
            mode: "interval"
            fixedTime: "08:00"
            startTime: "09:00"
            endTime: "18:00"
            intervalMinutes: 60
            sound: "beep.wav"
            soundDuration: 5
            soundEnabled: true
        }

        ListElement {
            text: "Trinken"
            mode: "interval"
            fixedTime: "00:00"
            startTime: "09:00"
            endTime: "18:00"
            intervalMinutes: 30
            sound: "beep.wav"
            soundDuration: 3
            soundEnabled: true
        }
    }

    header: ToolBar {
        id: header
        RowLayout {
            anchors.fill: parent
            spacing: 12

            Label {
                text: "Daily Actions"
                font.pixelSize: 18
                font.bold: true
                Layout.fillWidth: true
            }

            Switch {
                text: "Alle Töne aus"
                checked: app.allSoundsDisabled
            }
        }
    }

    ListView {
        id: listView

        anchors.top: parent.top
        anchors.topMargin: header.height + 12
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.bottomMargin: 88   // Platz für +

        model: actionModel
        clip: true

        delegate: Item {
            width: listView.width
            height: delegateRoot.implicitHeight + 12

            ActionDelegate {
                id: delegateRoot
                width: parent.width

                actionText: text
                mode: mode
                fixedTime: fixedTime
                startTime: startTime
                endTime: endTime
                intervalMinutes: intervalMinutes
                sound: sound
                soundDuration: soundDuration
                soundEnabled: soundEnabled
            }
        }
    }

    Button {
        text: "+"
        width: 56
        height: 56
        font.pixelSize: 26

        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 16
    }
}
