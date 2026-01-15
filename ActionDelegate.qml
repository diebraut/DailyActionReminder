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
    property int intervalMinutes
    property bool soundEnabled
    property string sound

    property int delegateIndex: -1

    // NEW: wird von Main übergeben
    property var soundChoices: ["Bell"]

    // keep last valid non-empty name
    property string _lastNonEmptyActionText: ""

    // Anzeige-Name: wenn leer -> Bell
    readonly property string soundDisplayName: (root.sound && root.sound.trim().length > 0) ? root.sound.trim() : "Bell"

    property int nextInMinutes: -1   // wird von Main gesetzt
    property int nextInSeconds: -1   // <60s -> mm:ss Anzeige

    property real volume: 1.0   // 0.0 .. 1.0 (pro Aktion)

    property int nextFixedH: -1
    property int nextFixedM: -1
    property int nextFixedS: -1   // nur in letzter Minute (sonst -1)


    signal toggleRequested(int idx)
    signal deleteRequested(int idx)

    // write-back signals (Main.qml updates ListModel)
    signal actionTextEdited(string v)
    signal modeEdited(string v)
    signal fixedTimeEdited(string v)
    signal startTimeEdited(string v)
    signal endTimeEdited(string v)
    signal intervalMinutesEdited(int v)
    signal soundEdited(string v)
    signal soundEnabledEdited(bool v)
    signal volumeEdited(real v)


    // NEW: Preview mit Sound-Namen
    signal previewSoundRequested(string soundName)

    function _pad2(n) {
        return (n < 10) ? ("0" + n) : ("" + n)
    }

    function nextCountdownSuffix() {
        // FIXED: hh:mm bzw. hh:mm:ss in letzter Minute
        if (root.mode === "fixed") {
            if (root.nextFixedS >= 0 && root.nextFixedH >= 0 && root.nextFixedM >= 0)
                return " (in " + _pad2(root.nextFixedH) + ":" + _pad2(root.nextFixedM) + ":" + _pad2(root.nextFixedS) + ")"
            if (root.nextFixedH >= 0 && root.nextFixedM >= 0)
                return " (in " + _pad2(root.nextFixedH) + ":" + _pad2(root.nextFixedM) + ")"
            return ""
        }

        // INTERVALL: mm:ss in letzter Minute, sonst "X Min"
        if (root.nextInSeconds >= 0) {
            const mm = Math.floor(root.nextInSeconds / 60)
            const ss = root.nextInSeconds % 60
            return " (in " + _pad2(mm) + ":" + _pad2(ss) + ")"
        }
        if (root.nextInMinutes >= 0)
            return " (in " + root.nextInMinutes + " Min)"
        return ""
    }

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
            if (intervalMinutes <= 0) {
                _setIfChangedInt("intervalMinutes", 60, intervalMinutesEdited)
            }
        }

        if (!sound || sound.trim().length === 0) {
            _setIfChangedString("sound", "Bell", soundEdited)
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

    Dialog {
        id: soundDialog
        modal: true
        standardButtons: Dialog.NoButton

        // Nur über Buttons schließen (wie gewünscht)
        closePolicy: Popup.NoAutoClose

        // ✅ Wichtig: nicht im Delegate/ListView bleiben (sonst clip!)
        parent: (root.Window.window && root.Window.window.overlay)
                ? root.Window.window.overlay
                : (root.Window.window ? root.Window.window.contentItem : root)

        // Größe am Window orientieren
        width: Math.min(parent ? parent.width * 0.92 : 380, 420)
        height: Math.min(parent ? parent.height * 0.85 : 620, 620)

        // zentrieren
        x: parent ? Math.round((parent.width - width) / 2) : 0
        y: parent ? Math.round((parent.height - height) / 2) : 0

        // Overlay hell
        Overlay.modal: Rectangle { color: "#00000030" }

        // Erwartet:
        //   root.soundChoices : var (Liste von Namen)
        //   root.soundDisplayName : string (aktueller Name)
        //   root.previewSoundRequested(name)
        //   root.soundEdited(name)
        property var choices: (root.soundChoices && root.soundChoices.length > 0) ? root.soundChoices : ["Bell"]
        property string pendingSound: root.soundDisplayName

        onOpened: pendingSound = root.soundDisplayName

        contentItem: Rectangle {
            anchors.fill: parent
            color: "#ffffff"
            radius: 16
            border.color: "#d0d0d0"
            border.width: 1

            Item {
                id: body
                anchors.fill: parent
                anchors.margins: 16

                // Header
                Text {
                    id: dlgTitle
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    text: "Ton wählen"
                    color: "#222222"
                    font.pixelSize: 16
                    font.bold: true
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: dlgTitle.bottom
                    anchors.topMargin: 10
                    height: 1
                    color: "#e6e6e6"
                }

                // Footer (immer sichtbar)
                Item {
                    id: footer
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 36

                    Row {
                        spacing: 10
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter

                        // Abbrechen (klein, rechts unten)
                        Rectangle {
                            width: 95
                            height: 32
                            radius: 8
                            color: "#d0d0d0"
                            border.color: "#b0b0b0"

                            Text {
                                anchors.centerIn: parent
                                text: "Abbrechen"
                                color: "#000000"
                                font.pixelSize: 13
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: function(mouse) {
                                    mouse.accepted = true
                                    soundDialog.close()
                                }
                            }
                        }

                        // Übernehmen (klein, rechts neben Abbrechen)
                        Rectangle {
                            width: 110
                            height: 32
                            radius: 8
                            color: "#d0d0d0"
                            border.color: "#b0b0b0"

                            Text {
                                anchors.centerIn: parent
                                text: "Übernehmen"
                                color: "#000000"
                                font.pixelSize: 13
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: function(mouse) {
                                    mouse.accepted = true
                                    root.soundEdited(soundDialog.pendingSound)
                                    soundDialog.close()
                                }
                            }
                        }
                    }
                }

                // Liste zwischen Header und Footer eingeklemmt (scrollt)
                ListView {
                    id: soundList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: dlgTitle.bottom
                    anchors.topMargin: 22
                    anchors.bottom: footer.top
                    anchors.bottomMargin: 12
                    clip: true

                    model: soundDialog.choices

                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                    delegate: Rectangle {
                        width: soundList.width
                        height: 44
                        radius: 10
                        border.color: "#b0b0b0"
                        border.width: 1
                        color: (modelData === soundDialog.pendingSound) ? "#cfcfcf" : "#f6f6f6"

                        // Zeilenklick: auswählen, Dialog bleibt offen (hinten)
                        MouseArea {
                            anchors.fill: parent
                            z: 0
                            cursorShape: Qt.PointingHandCursor
                            onClicked: function(mouse) {
                                mouse.accepted = true
                                soundDialog.pendingSound = modelData
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 10
                            z: 1

                            // Preview Icon (klickbar)
                            Rectangle {
                                width: 34
                                height: 34
                                radius: 10
                                color: "#ffffff"
                                border.color: "#cfcfcf"
                                Layout.alignment: Qt.AlignVCenter

                                Text {
                                    anchors.centerIn: parent
                                    text: "🔊"
                                    font.pixelSize: 20
                                    color: "#222222"
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: function(mouse) {
                                        mouse.accepted = true
                                        root.previewSoundRequested(modelData)
                                    }
                                }
                            }

                            Text {
                                text: modelData
                                color: "#000000"
                                font.pixelSize: 14
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                                verticalAlignment: Text.AlignVCenter
                            }

                            Rectangle {
                                width: 12
                                height: 12
                                radius: 6
                                border.color: "#777777"
                                color: (modelData === soundDialog.pendingSound) ? "#4CAF50" : "transparent"
                                Layout.alignment: Qt.AlignVCenter
                            }
                        }
                    }
                }
            }
        }
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
    function intervalMinutesText() {
        var minutes = (root.intervalMinutes > 0) ? root.intervalMinutes : 60
        return minutes + " Min."
    }

    Item {
        anchors.fill: parent
        anchors.margins: 16

        ColumnLayout {
            id: content
            width: parent.width
            spacing: 12

            Rectangle {
                id: headerPanel
                radius: 12
                color: Qt.rgba(1, 1, 1, 0.60)
                border.color: "#d8d8d8"
                Layout.fillWidth: true
                implicitHeight: headerGrid.implicitHeight + 20

                // speichert Volume nicht bei jedem Pixel Drag
                Timer {
                    id: volDebounce
                    interval: 200
                    repeat: false
                    onTriggered: root.volumeEdited(root.volume)
                }

                GridLayout {
                    id: headerGrid
                    anchors.fill: parent
                    anchors.margins: 10
                    columns: 2
                    columnSpacing: 10
                    rowSpacing: 6

                    // ---------- LEFT: Titel + Kurzinfo (klickbar zum Auf/Zu) ----------
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: headerText.implicitHeight

                        ColumnLayout {
                            id: headerText
                            anchors.fill: parent
                            spacing: 4

                            Text {
                                id: actionTextID
                                padding: 0
                                topPadding: 0
                                bottomPadding: 55   // zieht optisch nach oben (klein halten)
                                text: root.actionText
                                font.pixelSize: 18
                                font.bold: true
                                color: "#222222"
                                elide: Text.ElideRight
                            }

                            RowLayout {
                                visible: root.mode === "interval"
                                spacing: 6
                                Layout.fillWidth: true
                                Layout.topMargin: -55     // <-- schiebt die Zeile nach unten

                                Text { text: "Intervall:"; font.pixelSize: 13; color: "#555555" }
                                Text {
                                    font.pixelSize: 13
                                    color: "#444444"
                                    text: root.intervalMinutesText() + root.nextCountdownSuffix()
                                    elide: Text.ElideRight
                                }
                                Item { Layout.fillWidth: true }
                            }
                            RowLayout {
                                visible: root.mode === "fixed"
                                spacing: 6
                                Layout.topMargin: -55     // <-- schiebt die Zeile nach unten
                                Layout.fillWidth: true
                                Text { text: "Um:"; font.pixelSize: 13; color: "#555555" }
                                Text { text: root.fixedTimeText() + " Uhr" + root.nextCountdownSuffix(); font.pixelSize: 13; color: "#444444"; elide: Text.ElideRight }
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

                    // ---------- RIGHT: Lautstärke-Slider + X (kompakter) ----------
                    ColumnLayout {
                        spacing: 8
                        Layout.alignment: Qt.AlignTop | Qt.AlignRight
                        Layout.preferredWidth: Math.round(headerPanel.width * 0.40)   // ca. 40%

                        // ✅ 1) X oben rechts (50% größer)
                        Rectangle {
                            id: deleteChip
                            width: 36           // war ~24 -> +50%
                            height: 30          // war ~20 -> +50%
                            radius: 9
                            color: deleteMA.pressed ? "#e0e0e0" : "#f2f2f2"
                            border.color: "#cfcfcf"
                            Layout.alignment: Qt.AlignRight

                            Text {
                                anchors.centerIn: parent
                                text: "X"
                                font.pixelSize: 16   // war ~11 -> +45%
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

                        // ✅ 2) Slider/Icon unten rechts
                        RowLayout {
                            spacing: 6
                            Layout.alignment: Qt.AlignRight
                            opacity: root.soundEnabled ? 1.0 : 0.45

                            Rectangle {
                                width: 22
                                height: 22
                                radius: 7
                                color: root.soundEnabled ? "#e8f4ff" : "#f0f0f0"
                                border.color: root.soundEnabled ? "#2f6fb3" : "#9a9a9a"
                                border.width: 1
                                Layout.alignment: Qt.AlignVCenter

                                Text {
                                    anchors.centerIn: parent
                                    text: root.soundEnabled ? "🔊" : "🔇"
                                    font.pixelSize: 14
                                    color: root.soundEnabled ? "#0b4a8b" : "#444444"
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: function(mouse) {
                                        mouse.accepted = true
                                        const v = !root.soundEnabled
                                        root.soundEnabled = v
                                        root.soundEnabledEdited(v)
                                        // ✅ nur wenn aktiviert -> abspielen
                                        if (v) {
                                            root.previewSoundRequested(root.soundDisplayName)
                                        }
                                    }
                                }
                            }

                            Slider {
                                id: volSliderHeader
                                from: 0.0
                                to: 1.0
                                stepSize: 0.05
                                value: root.volume
                                enabled: root.soundEnabled
                                Layout.preferredWidth: Math.max(110, Math.round(headerPanel.width * 0.26))
                                Layout.alignment: Qt.AlignVCenter

                                onMoved: {
                                    root.volume = value
                                    volDebounce.restart()
                                }

                                onPressedChanged: {
                                    if (!pressed) {
                                        root.volumeEdited(root.volume)
                                        if (root.soundEnabled) {
                                            root.previewSoundRequested(root.soundDisplayName)
                                        }
                                    }
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

                        // Mode buttons
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

                                        if (root.intervalMinutes <= 0) {
                                            root.intervalMinutes = 60
                                            root.intervalMinutesEdited(60)
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
                                label: "Intervall (Min.)"
                                value: root.intervalMinutes
                                minValue: 1
                                maxValue: 24 * 60
                                minInputWidth: 170
                                preferredInputWidth: 220
                                onValueEdited: function(v) {
                                    root.intervalMinutes = v
                                    root.intervalMinutesEdited(v)
                                }
                            }
                        }

                        // ---- SOUND ----
                        SectionHeader { title: "Ton" }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Item {
                                implicitWidth: 30
                                implicitHeight: 30
                                Layout.preferredWidth: 30
                                Layout.preferredHeight: 30
                                Layout.alignment: Qt.AlignVCenter

                                Text {
                                    anchors.centerIn: parent
                                    text: "🔊"
                                    font.pixelSize: 24
                                    color: "#222222"
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: function(mouse) {
                                        mouse.accepted = true
                                        root.previewSoundRequested(root.soundDisplayName)
                                    }
                                }
                            }

                            Text {
                                text: root.soundDisplayName
                                font.pixelSize: 14
                                color: "#000000"
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                verticalAlignment: Text.AlignVCenter
                            }

                            Rectangle {
                                width: 120
                                height: 36
                                radius: 8
                                color: "#d0d0d0"
                                border.color: "#b0b0b0"
                                Layout.alignment: Qt.AlignVCenter

                                Text {
                                    anchors.centerIn: parent
                                    text: "Ändern"
                                    color: "#000000"
                                    font.pixelSize: 14
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: function(mouse) {
                                        mouse.accepted = true
                                        soundDialog.open()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
