import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml

Rectangle {
    id: root
    radius: 14
    border.color: "#dddddd"
    border.width: 1
    width: parent ? parent.width : 360

    readonly property color displayUnitColor: "#EBEDD3"
    readonly property color editUnitColor: "#C2F0C6"
    color: root.expanded ? editUnitColor : displayUnitColor

    property bool expanded: false

    property string actionText
    property string mode              // "fixed" | "interval"
    property string fixedTime
    property string startTime
    property string endTime
    property int intervalSeconds
    property bool soundEnabled
    property string sound
    property int soundDuration

    property int delegateIndex: -1

    // keep last valid non-empty name
    property string _lastNonEmptyActionText: ""

    signal toggleRequested(int idx)
    signal deleteRequested(int idx)

    // write-back signals (Main.qml updates ListModel)
    signal actionTextEdited(string v)
    signal modeEdited(string v)
    signal fixedTimeEdited(string v)
    signal startTimeEdited(string v)
    signal endTimeEdited(string v)
    signal intervalSecondsEdited(int v)
    signal soundEdited(string v)
    signal soundDurationEdited(int v)
    signal soundEnabledEdited(bool v)

    function _setIfChangedString(propName, newValue, sig) {
        if (root[propName] !== newValue) {
            root[propName] = newValue
            sig(newValue)
        }
    }
    function _setIfChangedInt(propName, newValue, sig) {
        if (root[propName] !== newValue) {
            root[propName] = newValue
            sig(newValue)
        }
    }

    function ensureDefaults() {
        if (mode !== "fixed" && mode !== "interval") {
            _setIfChangedString("mode", "fixed", modeEdited)
        }

        if (mode === "fixed") {
            if (!fixedTime || fixedTime.length === 0) {
                _setIfChangedString("fixedTime", "00:00", fixedTimeEdited)
            }
        }

        if (mode === "interval") {
            if (startTime === undefined || startTime === null) {
                _setIfChangedString("startTime", "", startTimeEdited)
            }
            if (endTime === undefined || endTime === null) {
                _setIfChangedString("endTime", "", endTimeEdited)
            }
            if (intervalSeconds <= 0) {
                _setIfChangedInt("intervalSeconds", 1800, intervalSecondsEdited)
            }
        }

        if (soundDuration === undefined || soundDuration === null) {
            _setIfChangedInt("soundDuration", 0, soundDurationEdited)
        }
        if (soundEnabled === undefined || soundEnabled === null) {
            root.soundEnabled = true
            soundEnabledEdited(true)
        }
    }

    Component.onCompleted: {
        ensureDefaults()

        _lastNonEmptyActionText = (actionText && actionText.trim().length > 0) ? actionText.trim() : "Neue Aktion"
        if (!actionText || actionText.trim().length === 0) {
            root.actionText = _lastNonEmptyActionText
            root.actionTextEdited(root.actionText)
        }
    }

    onExpandedChanged: {
        if (expanded) {
            ensureDefaults()
            Qt.callLater(function() { actionNameField.forceActiveFocus() })
        }
    }

    implicitHeight: content.implicitHeight + 32

    // ===== confirm delete dialog =====
    Dialog {
        id: deleteDialog
        modal: true
        title: "Aktion löschen?"
        standardButtons: Dialog.Yes | Dialog.No

        // feste Breite -> kein implicitWidth-Kreis mehr
        width: 320

        contentItem: Item {
            implicitWidth: deleteDialog.width
            implicitHeight: msg.implicitHeight + 20

            Label {
                id: msg
                anchors.fill: parent
                anchors.margins: 10
                width: parent.width - 20
                wrapMode: Text.WordWrap
                color: "#222222"
                text: "Willst du \"" + (root.actionText || "") + "\" wirklich löschen?"
            }
        }

        onAccepted: root.deleteRequested(root.delegateIndex)
    }

    // ===== robust inline fields (label + input next to each other) =====
    component InlineTextField: Item {
        id: itf
        property string label: ""
        property string value: ""
        property string placeholder: ""
        property var validator: null
        property int inputHints: Qt.ImhNone
        property int minInputWidth: 140
        property int preferredInputWidth: 180
        signal valueEdited(string v)

        width: parent ? parent.width : 300
        implicitHeight: rowITF.implicitHeight

        RowLayout {
            id: rowITF
            width: parent.width
            spacing: 10

            Text {
                text: itf.label + ":"
                color: "#444444"
                font.pixelSize: 13
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                Layout.alignment: Qt.AlignVCenter
                Layout.fillWidth: false
                Layout.maximumWidth: parent.width - itf.minInputWidth - rowITF.spacing
            }

            Rectangle {
                radius: 8
                color: "#ffffff"
                border.color: "#cfcfcf"
                height: 36
                Layout.fillWidth: true
                Layout.minimumWidth: itf.minInputWidth
                Layout.preferredWidth: itf.preferredInputWidth

                TextInput {
                    id: inputITF
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    font.pixelSize: 14
                    color: "#222222"
                    selectByMouse: true
                    inputMethodHints: itf.inputHints
                    validator: itf.validator

                    Binding {
                        target: inputITF
                        property: "text"
                        value: itf.value
                        when: !inputITF.activeFocus
                    }

                    onEditingFinished: itf.valueEdited(text)
                }

                Text {
                    visible: inputITF.text.length === 0 && !inputITF.activeFocus
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: itf.placeholder
                    color: "#999999"
                    font.pixelSize: 14
                    elide: Text.ElideRight
                }
            }
        }
    }

    component InlineNumberField: Item {
        id: inf
        property string label: ""
        property int value: 0
        property int minValue: 0
        property int maxValue: 999999999
        property int minInputWidth: 140
        property int preferredInputWidth: 180
        signal valueEdited(int v)

        width: parent ? parent.width : 300
        implicitHeight: rowINF.implicitHeight

        RowLayout {
            id: rowINF
            width: parent.width
            spacing: 10

            Text {
                text: inf.label + ":"
                color: "#444444"
                font.pixelSize: 13
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                Layout.alignment: Qt.AlignVCenter
                Layout.fillWidth: false
                Layout.maximumWidth: parent.width - inf.minInputWidth - rowINF.spacing
            }

            Rectangle {
                radius: 8
                color: "#ffffff"
                border.color: "#cfcfcf"
                height: 36
                Layout.fillWidth: true
                Layout.minimumWidth: inf.minInputWidth
                Layout.preferredWidth: inf.preferredInputWidth

                TextInput {
                    id: inputINF
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    font.pixelSize: 14
                    color: "#222222"
                    selectByMouse: true
                    inputMethodHints: Qt.ImhDigitsOnly
                    validator: IntValidator { bottom: inf.minValue; top: inf.maxValue }

                    Binding {
                        target: inputINF
                        property: "text"
                        value: inf.value.toString()
                        when: !inputINF.activeFocus
                    }

                    onEditingFinished: {
                        const v = parseInt(text)
                        if (!isNaN(v)) inf.valueEdited(v)
                    }
                }
            }
        }
    }

    RegularExpressionValidator {
        id: timeValidator
        regularExpression: /^$|^(?:[01]\d|2[0-3]):[0-5]\d$/
    }

    component SectionHeader: Item {
        id: sh
        property string title: ""
        width: parent ? parent.width : 360
        implicitHeight: colSH.implicitHeight

        ColumnLayout {
            id: colSH
            width: parent.width
            spacing: 8
            Text { text: sh.title; font.pixelSize: 14; font.bold: true; color: "#222222" }
            Rectangle { height: 1; color: "#d6d6d6"; Layout.fillWidth: true }
        }
    }

    function fixedTimeText() {
        return (root.fixedTime && root.fixedTime.length) ? root.fixedTime : "00:00"
    }
    function intervalSecondsText() {
        var sec = (root.intervalSeconds > 0) ? root.intervalSeconds : 1800
        return sec + " s"
    }

    Item {
        anchors.fill: parent
        anchors.margins: 16

        ColumnLayout {
            id: content
            width: parent.width
            spacing: 12

            // ============== HEADER PANEL ==============
            Rectangle {
                id: headerPanel
                radius: 12
                color: Qt.rgba(1, 1, 1, 0.60)
                border.color: "#d8d8d8"
                Layout.fillWidth: true
                implicitHeight: headerGrid.implicitHeight + 20

                GridLayout {
                    id: headerGrid
                    anchors.fill: parent
                    anchors.margins: 10
                    columns: 2
                    columnSpacing: 8
                    rowSpacing: 6

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

                            RowLayout {
                                visible: root.mode === "fixed"
                                spacing: 6
                                Layout.fillWidth: true
                                Text { text: "Feste Uhrzeit:"; font.pixelSize: 13; color: "#555555" }
                                Text { text: root.fixedTimeText(); font.pixelSize: 13; color: "#444444"; elide: Text.ElideRight }
                                Item { Layout.fillWidth: true }
                            }

                            RowLayout {
                                visible: root.mode === "interval"
                                spacing: 6
                                Layout.fillWidth: true
                                Text { text: "Intervall:"; font.pixelSize: 13; color: "#555555" }
                                Text { text: root.intervalSecondsText(); font.pixelSize: 13; color: "#444444" }
                                Item { Layout.fillWidth: true }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: function(mouse) {
                                mouse.accepted = true
                                root.toggleRequested(root.delegateIndex)
                            }
                        }
                    }

                    // Right side: Ton + dezent X darunter
                    ColumnLayout {
                        spacing: 8
                        Layout.alignment: Qt.AlignTop | Qt.AlignRight

                        RowLayout {
                            spacing: 6
                            Layout.alignment: Qt.AlignRight

                            Text { text: "Ton"; font.pixelSize: 13; color: "#555555"; verticalAlignment: Text.AlignVCenter }

                            Rectangle {
                                width: 14
                                height: 14
                                radius: 7
                                color: root.soundEnabled ? "#4CAF50" : "#cccccc"
                                border.color: "#9a9a9a"

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: function(mouse) {
                                        mouse.accepted = true
                                        const nv = !root.soundEnabled
                                        console.log("[Delegate] idx=", root.delegateIndex, "soundEnabled:", root.soundEnabled, "->", nv)
                                        root.soundEnabled = nv
                                        root.soundEnabledEdited(nv)

                                    }
                                }
                            }
                        }

                        // Dezent: kleines X, hellgrau, keine "Alarmfarbe"
                        Rectangle {
                            id: deleteChip
                            width: 28
                            height: 22
                            radius: 7
                            color: deleteMA.pressed ? "#e0e0e0" : "#f2f2f2"
                            border.color: "#cfcfcf"
                            Layout.alignment: Qt.AlignRight

                            Text {
                                anchors.centerIn: parent
                                text: "X"
                                font.pixelSize: 12
                                font.bold: true
                                color: "#666666"
                            }

                            MouseArea {
                                id: deleteMA
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: function(mouse) {
                                    mouse.accepted = true
                                    deleteDialog.open()
                                }
                            }
                        }
                    }
                }
            }

            // ============== EDIT PANEL ==============
            Rectangle {
                id: editPanel
                visible: root.expanded
                radius: 12
                color: Qt.rgba(1, 1, 1, 0.55)
                border.color: "#d8d8d8"
                Layout.fillWidth: true
                implicitHeight: editRow.implicitHeight + 20

                RowLayout {
                    id: editRow
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 10

                    Rectangle {
                        width: 6
                        radius: 6
                        color: "#4CAF50"
                        Layout.fillHeight: true
                    }

                    ColumnLayout {
                        id: editCol
                        Layout.fillWidth: true
                        spacing: 14

                        // Action name editable (prevent empty)
                        InlineTextField {
                            id: actionNameField
                            label: "Aktion"
                            value: root.actionText
                            placeholder: "z.B. Übung machen"
                            minInputWidth: 170
                            preferredInputWidth: 220

                            onValueEdited: function(v) {
                                const t = (v || "").trim()
                                if (t.length === 0) {
                                    root.actionText = root._lastNonEmptyActionText
                                    root.actionTextEdited(root._lastNonEmptyActionText)
                                    return
                                }
                                root._lastNonEmptyActionText = t
                                root.actionText = t
                                root.actionTextEdited(t)
                            }
                        }

                        // Mode buttons (immediate local + model)
                        RowLayout {
                            spacing: 12

                            Rectangle {
                                width: 120; height: 36; radius: 8
                                color: root.mode === "fixed" ? "#4CAF50" : "#eeeeee"
                                Text { anchors.centerIn: parent; text: "Uhrzeit"; color: root.mode === "fixed" ? "white" : "#333333" }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: function(mouse) {
                                        mouse.accepted = true
                                        root.mode = "fixed"
                                        root.modeEdited("fixed")

                                        if (!root.fixedTime || root.fixedTime.length === 0) {
                                            root.fixedTime = "00:00"
                                            root.fixedTimeEdited("00:00")
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                width: 120; height: 36; radius: 8
                                color: root.mode === "interval" ? "#4CAF50" : "#eeeeee"
                                Text { anchors.centerIn: parent; text: "Intervall"; color: root.mode === "interval" ? "white" : "#333333" }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: function(mouse) {
                                        mouse.accepted = true
                                        root.mode = "interval"
                                        root.modeEdited("interval")

                                        if (root.intervalSeconds <= 0) {
                                            root.intervalSeconds = 1800
                                            root.intervalSecondsEdited(1800)
                                        }
                                        if (root.startTime === undefined || root.startTime === null) {
                                            root.startTime = ""
                                            root.startTimeEdited("")
                                        }
                                        if (root.endTime === undefined || root.endTime === null) {
                                            root.endTime = ""
                                            root.endTimeEdited("")
                                        }
                                    }
                                }
                            }
                        }

                        // ---- TIME ----
                        SectionHeader { title: "Zeit" }

                        ColumnLayout {
                            visible: root.mode === "fixed"
                            spacing: 10
                            Layout.fillWidth: true

                            InlineTextField {
                                label: "Uhrzeit (HH:MM)"
                                value: root.fixedTime
                                placeholder: "z.B. 08:00"
                                validator: timeValidator
                                inputHints: Qt.ImhTime
                                minInputWidth: 170
                                preferredInputWidth: 220
                                onValueEdited: function(v) {
                                    root.fixedTime = v
                                    root.fixedTimeEdited(v)
                                }
                            }
                        }

                        ColumnLayout {
                            visible: root.mode === "interval"
                            spacing: 10
                            Layout.fillWidth: true

                            InlineTextField {
                                label: "Start (optional)"
                                value: root.startTime
                                placeholder: "leer = 00:00"
                                validator: timeValidator
                                inputHints: Qt.ImhTime
                                minInputWidth: 170
                                preferredInputWidth: 220
                                onValueEdited: function(v) {
                                    root.startTime = v
                                    root.startTimeEdited(v)
                                }
                            }

                            InlineTextField {
                                label: "Ende (optional)"
                                value: root.endTime
                                placeholder: "leer = 00:00"
                                validator: timeValidator
                                inputHints: Qt.ImhTime
                                minInputWidth: 170
                                preferredInputWidth: 220
                                onValueEdited: function(v) {
                                    root.endTime = v
                                    root.endTimeEdited(v)
                                }
                            }

                            InlineNumberField {
                                label: "Intervall (Sekunden)"
                                value: root.intervalSeconds
                                minValue: 1
                                maxValue: 24 * 60 * 60
                                minInputWidth: 170
                                preferredInputWidth: 220
                                onValueEdited: function(v) {
                                    root.intervalSeconds = v
                                    root.intervalSecondsEdited(v)
                                }
                            }
                        }

                        // ---- SOUND ----
                        SectionHeader { title: "Ton" }

                        ColumnLayout {
                            spacing: 10
                            Layout.fillWidth: true

                            InlineTextField {
                                label: "Datei / Name"
                                value: root.sound
                                placeholder: "z.B. beep.wav"
                                minInputWidth: 170
                                preferredInputWidth: 220
                                onValueEdited: function(v) {
                                    root.sound = v
                                    root.soundEdited(v)
                                }
                            }

                            InlineNumberField {
                                label: "Dauer (Sekunden)"
                                value: root.soundDuration
                                minValue: 0
                                maxValue: 120
                                minInputWidth: 170
                                preferredInputWidth: 220
                                onValueEdited: function(v) {
                                    root.soundDuration = v
                                    root.soundDurationEdited(v)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
