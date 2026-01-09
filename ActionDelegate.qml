import QtQuick
import QtQuick.Layouts

Rectangle {
    id: root
    radius: 14
    color: "#ffffff"
    border.color: "#dddddd"
    border.width: 1
    width: parent ? parent.width : 360

    property bool expanded: false

    property string actionText
    property string mode
    property string fixedTime
    property string startTime
    property string endTime
    property int intervalMinutes
    property bool soundEnabled
    property string sound
    property int soundDuration

    implicitHeight: content.implicitHeight + 32

    Item {
        anchors.fill: parent
        anchors.margins: 16

        ColumnLayout {
            id: content
            width: parent.width
            spacing: 12

            // ================= HEADER =================
            GridLayout {
                id: header
                columns: 2
                columnSpacing: 8
                rowSpacing: 4
                Layout.fillWidth: true

                // ========= LINKE SPALTE: TEXT + KLICK =========
                Item {
                    Layout.fillWidth: true
                    implicitHeight: headerText.implicitHeight

                    ColumnLayout {
                        id: headerText
                        anchors.fill: parent
                        spacing: 4

                        Text {
                            text: root.actionText
                            font.pixelSize: 18
                            font.bold: true
                            color: "#222222"
                            elide: Text.ElideRight
                        }

                        Text {
                            text: root.mode === "interval" ? "Intervall" : "Feste Uhrzeit"
                            font.pixelSize: 13
                            color: "#666666"
                        }
                    }

                    // 👉 DAS ist jetzt der funktionierende Header-Klick
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: function(mouse) {
                            mouse.accepted = true
                            root.expanded = !root.expanded
                        }
                    }
                }

                // ========= RECHTE SPALTE: CHECKBOX =========
                RowLayout {
                    spacing: 6
                    Layout.alignment: Qt.AlignTop | Qt.AlignRight

                    Text {
                        text: "Ton"
                        font.pixelSize: 13
                        color: "#666666"
                        verticalAlignment: Text.AlignVCenter
                    }
                    Rectangle {
                        width: 14
                        height: 14
                        radius: 7
                        color: root.soundEnabled ? "#4CAF50" : "#cccccc"

                        MouseArea {
                            anchors.fill: parent
                            onClicked: function(mouse) {
                                mouse.accepted = true
                                root.soundEnabled = !root.soundEnabled
                            }
                        }
                    }
                }
            }

            Rectangle {
                height: 1
                color: "#eeeeee"
                Layout.fillWidth: true
            }

            // ================= EDIT MODE =================
            ColumnLayout {
                visible: root.expanded
                spacing: 12
                Layout.fillWidth: true

                RowLayout {
                    spacing: 12

                    Rectangle {
                        width: 120; height: 36; radius: 6
                        color: root.mode === "fixed" ? "#4CAF50" : "#eeeeee"
                        Text {
                            anchors.centerIn: parent
                            text: "Uhrzeit"
                            color: root.mode === "fixed" ? "white" : "#333333"
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: function(mouse) {
                                mouse.accepted = true
                                root.mode = "fixed"
                            }
                        }
                    }

                    Rectangle {
                        width: 120; height: 36; radius: 6
                        color: root.mode === "interval" ? "#4CAF50" : "#eeeeee"
                        Text {
                            anchors.centerIn: parent
                            text: "Intervall"
                            color: root.mode === "interval" ? "white" : "#333333"
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: function(mouse) {
                                mouse.accepted = true
                                root.mode = "interval"
                            }
                        }
                    }
                }

                Text { text: "Ton"; font.bold: true }
                Text { text: "Datei: " + (root.sound.length ? root.sound : "(keine)") }
                Text { text: "Dauer: " + root.soundDuration + " Sekunden" }
            }
        }
    }
}
