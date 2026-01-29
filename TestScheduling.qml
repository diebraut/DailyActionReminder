import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia

import DailyActions 1.0

Dialog {
    id: dlg
    modal: true
    closePolicy: Popup.NoAutoClose

    x: (parent && parent.width) ? (parent.width - width) / 2 : 0
    y: (parent && parent.height) ? Math.max(10, (parent.height - height) / 2 - 60) : 0
    width: (parent && parent.width) ? Math.min(560, parent.width * 0.96) : 560

    title: "Alarm-Testparameter"
    standardButtons: Dialog.NoButton

    // ---- input / defaults (gehören jetzt hierher) ----
    property string pSoundName: "Bell"
    property string pMode: "fixedTime"        // "fixedTime" | "interval"
    property string pFixedTime: "12:00"
    property string pStartTime: "09:00"
    property string pEndTime: "00:00"
    property int    pIntervalSeconds: 10
    property real   pVolume01: 1.0
    property bool   configured: false

    // Optional: vom Main injizieren (sonst Default hier)
    property var soundChoices: [
        "Bell",
        "Soft Chime",
        "Beep Short",
        "Beep Double",
        "Pop Click",
        "Wood Tap",
        "Marimba Hit",
        "Triangle Ping",
        "Low Gong",
        "Airy Whoosh"
    ]

    // Optional: vom Main injizieren (sonst Default hier)
    property var soundMap: ({
        "Bell":          "qrc:/sounds/bell.wav",
        "Soft Chime":    "qrc:/sounds/soft_chime.wav",
        "Beep Short":    "qrc:/sounds/beep_short.wav",
        "Beep Double":   "qrc:/sounds/beep_double.wav",
        "Pop Click":     "qrc:/sounds/pop_click.wav",
        "Wood Tap":      "qrc:/sounds/wood_tap.wav",
        "Marimba Hit":   "qrc:/sounds/marimba_hit.wav",
        "Triangle Ping": "qrc:/sounds/triangle_ping.wav",
        "Low Gong":      "qrc:/sounds/low_gong.wav",
        "Airy Whoosh":   "qrc:/sounds/airy_whoosh.wav"
    })

    // auf kleinen Screens Label schmaler
    property int labelW: Math.min(120, Math.floor(width * 0.30))

    // Liste der aktuell gestarteten Test-IDs
    property var activeTestIds: []
    property int selectedTestId: -1

    // -------------------------
    // Helpers (früher in Main.qml)
    // -------------------------
    function _canonicalSoundChoice(name) {
        const s0 = (typeof name === "string") ? name.trim().toLowerCase() : ""
        if (!s0) return "Bell"

        // 1) Match Anzeige-Namen
        for (let i = 0; i < soundChoices.length; i++) {
            if (soundChoices[i].toLowerCase() === s0)
                return soundChoices[i]
        }

        // 2) Match raw-Namen (bell, soft_chime, ...)
        const rawToChoice = {
            "bell": "Bell",
            "soft_chime": "Soft Chime",
            "beep_short": "Beep Short",
            "beep_double": "Beep Double",
            "pop_click": "Pop Click",
            "wood_tap": "Wood Tap",
            "marimba_hit": "Marimba Hit",
            "triangle_ping": "Triangle Ping",
            "low_gong": "Low Gong",
            "airy_whoosh": "Airy Whoosh"
        }
        if (rawToChoice[s0]) return rawToChoice[s0]

        // 3) Falls jemand "soft_chime.wav" etc eingibt
        const s1 = s0.replace(/\.(wav|mp3|ogg)$/i, "")
        if (rawToChoice[s1]) return rawToChoice[s1]

        return "Bell"
    }

    function soundSourceForName(name) {
        const key = (typeof name === "string" && name.trim().length > 0) ? name.trim() : "Bell"
        return soundMap[key] || soundMap["Bell"]
    }

    // Android notifications use res/raw resources (file name without extension)
    function soundRawForName(name) {
        const key = (typeof name === "string" && name.trim().length > 0) ? name.trim() : "Bell"
        const map = {
            "Bell":          "bell",
            "Soft Chime":    "soft_chime",
            "Beep Short":    "beep_short",
            "Beep Double":   "beep_double",
            "Pop Click":     "pop_click",
            "Wood Tap":      "wood_tap",
            "Marimba Hit":   "marimba_hit",
            "Triangle Ping": "triangle_ping",
            "Low Gong":      "low_gong",
            "Airy Whoosh":   "airy_whoosh"
        }
        return map[key] || "bell"
    }

    function _rebuildSelectedId() {
        if (idList.currentIndex < 0 || idList.currentIndex >= activeTestIds.length) {
            selectedTestId = -1
        } else {
            selectedTestId = activeTestIds[idList.currentIndex]
        }
    }

    function _applyFromFields() {
        pSoundName = soundBox.currentText

        pMode = modeBox.currentValue
        pFixedTime = fixedField.text.trim().length ? fixedField.text.trim() : "12:00"
        pStartTime = startField.text.trim().length ? startField.text.trim() : "09:00"
        pEndTime   = endField.text.trim().length   ? endField.text.trim()   : "00:00"

        var v = parseInt(intervalField.text)
        if (isNaN(v) || v <= 0) v = 10
        pIntervalSeconds = v

        configured = true
    }

    // -------------------------
    // Preview (kein app.playSoundPreview mehr)
    // -------------------------
    SoundEffect {
        id: previewSfx
        muted: false
    }

    function playSoundPreview(soundName, volume01) {
        var src = soundSourceForName(soundName)
        var vol = Number(volume01)
        if (isNaN(vol)) vol = 1.0
        if (vol < 0) vol = 0
        if (vol > 1) vol = 1

        // Reset, damit Android zuverlässiger neu lädt
        previewSfx.stop()
        previewSfx.source = ""
        previewSfx.volume = vol
        Qt.callLater(function() {
            previewSfx.source = src
            Qt.callLater(function() { previewSfx.play() })
        })
    }

    // -------------------------
    // Android Test Schedule (komplett hier)
    // -------------------------
    function startAndroidTestSchedule(rawSound, mode, fixedTime, startTime, endTime, intervalSec, volume01) {
        if (typeof SoundTaskManager === "undefined" || !SoundTaskManager) {
            console.warn("[TestSchedule] SoundTaskManager missing")
            return -1
        }

        var vol = Number(volume01)
        if (isNaN(vol)) vol = 1.0
        if (vol < 0) vol = 0
        if (vol > 1) vol = 1

        function parseHHMM(s) {
            if (!s || typeof s !== "string") return null
            var p = s.split(":")
            if (p.length < 2) return null
            var h = parseInt(p[0], 10)
            var m = parseInt(p[1], 10)
            if (isNaN(h) || isNaN(m)) return null
            if (h < 0 || h > 23 || m < 0 || m > 59) return null
            return { h: h, m: m }
        }

        function todayAt(h, m) {
            var d = new Date()
            d.setSeconds(0)
            d.setMilliseconds(0)
            d.setHours(h)
            d.setMinutes(m)
            return d
        }

        var isFixed = (mode === "fixed" || mode === "fixedTime" || mode === "fixedtime")
        if (isFixed) {
            var fm = parseHHMM(fixedTime)
            if (!fm) {
                console.warn("[TestSchedule] fixedTime invalid:", fixedTime)
                return -1
            }

            var t = todayAt(fm.h, fm.m)
            var now = new Date()
            if (t.getTime() <= now.getTime())
                t.setDate(t.getDate() + 1)

            if (typeof SoundTaskManager.startFixedSoundTask !== "function") {
                console.warn("[TestSchedule] startFixedSoundTask() not available")
                return -1
            }

            var idFixed = SoundTaskManager.startFixedSoundTask(
                rawSound,
                "Test: " + rawSound,
                t.getTime(),
                vol,
                0
            )

            console.warn("[TestSchedule] fixed start id=", idFixed,
                         "at=", new Date(t.getTime()).toISOString(),
                         "fixed=", fixedTime,
                         "vol=", vol)

            return idFixed
        }

        var st = parseHHMM(startTime)
        var en = parseHHMM(endTime)
        if (!st || !en) {
            console.warn("[TestSchedule] startTime/endTime invalid:", startTime, endTime)
            return -1
        }

        var startD = todayAt(st.h, st.m)
        var endD   = todayAt(en.h, en.m)

        if (endD.getTime() <= startD.getTime())
            endD.setDate(endD.getDate() + 1)

        var sec = parseInt(intervalSec, 10)
        if (isNaN(sec) || sec < 1) sec = 10

        if (typeof SoundTaskManager.startIntervalSoundTask !== "function") {
            console.warn("[TestSchedule] startIntervalSoundTask() not available")
            return -1
        }

        var idInt = SoundTaskManager.startIntervalSoundTask(
            rawSound,
            "Test: " + rawSound,
            startD.getTime(),
            endD.getTime(),
            sec,
            vol,
            0
        )

        console.warn("[TestSchedule] interval start id=", idInt,
                     "start=", new Date(startD.getTime()).toISOString(),
                     "end=", new Date(endD.getTime()).toISOString(),
                     "intervalSec=", sec,
                     "vol=", vol)

        return idInt
    }

    function runTest() {
        _applyFromFields()

        const raw = soundRawForName(pSoundName)

        const id = startAndroidTestSchedule(
            raw,
            pMode,
            pFixedTime,
            pStartTime,
            pEndTime,
            pIntervalSeconds,
            pVolume01
        )

        if (typeof id === "number" && id > 0) {
            if (activeTestIds.indexOf(id) < 0)
                activeTestIds = activeTestIds.concat([id])

            idList.currentIndex = -1
            _rebuildSelectedId()
        } else {
            idList.currentIndex = -1
            _rebuildSelectedId()
        }
    }

    function stopSelected() {
        if (selectedTestId <= 0) return

        if (typeof SoundTaskManager !== "undefined" && SoundTaskManager) {
            if (typeof SoundTaskManager.cancel === "function") {
                SoundTaskManager.cancel(selectedTestId)
            } else if (typeof SoundTaskManager.cancelAlarmTask === "function") {
                SoundTaskManager.cancelAlarmTask(selectedTestId)
            }
        }

        const idx = activeTestIds.indexOf(selectedTestId)
        if (idx >= 0) {
            const copy = activeTestIds.slice(0)
            copy.splice(idx, 1)
            activeTestIds = copy
        }

        idList.currentIndex = -1
        _rebuildSelectedId()
    }

    function abortDialog() {
        configured = true
        reject()
    }

    onOpened: {
        const c = _canonicalSoundChoice(pSoundName)
        const idx = soundChoices.indexOf(c)
        soundBox.currentIndex = (idx >= 0) ? idx : 0

        idList.currentIndex = -1
        _rebuildSelectedId()
    }

    // ✅ FIX: ScrollView + Spacer unten (kein Overlap mit Footer)
    contentItem: ScrollView {
        id: dlgScroll
        anchors.fill: parent
        clip: true

        Item {
            width: dlgScroll.availableWidth
            implicitHeight: contentCol.implicitHeight

            ColumnLayout {
                id: contentCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 10

                Label {
                    text: ""
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    height: 0
                }

                GridLayout {
                    columns: 2
                    columnSpacing: 10
                    rowSpacing: 10
                    Layout.fillWidth: true

                    Label { text: "Sound:"; Layout.preferredWidth: dlg.labelW }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 8

                        ComboBox {
                            id: soundBox
                            Layout.fillWidth: true
                            Layout.minimumWidth: 140
                            model: dlg.soundChoices

                            topPadding: (Qt.platform.os === "android") ? 0 : 6
                            bottomPadding: (Qt.platform.os === "android") ? 0 : 6

                            Component.onCompleted: {
                                const c2 = dlg._canonicalSoundChoice(dlg.pSoundName)
                                const idx2 = dlg.soundChoices.indexOf(c2)
                                currentIndex = (idx2 >= 0) ? idx2 : 0
                            }
                            onActivated: dlg.pSoundName = currentText
                        }

                        Button {
                            text: "▶"
                            Layout.preferredWidth: 44
                            Layout.minimumWidth: 44
                            Layout.preferredHeight: soundBox.implicitHeight
                            Layout.alignment: Qt.AlignVCenter
                            onClicked: dlg.playSoundPreview(soundBox.currentText, 1.0)
                            ToolTip.visible: hovered
                            ToolTip.text: "Sound vorhören"
                        }
                    }

                    Label { text: "Mode:"; Layout.preferredWidth: dlg.labelW }
                    ComboBox {
                        id: modeBox
                        Layout.fillWidth: true
                        model: [
                            { text: "fixedTime", value: "fixedTime" },
                            { text: "interval",  value: "interval" }
                        ]
                        textRole: "text"
                        valueRole: "value"
                        Component.onCompleted: currentIndex = 1
                    }

                    Label { text: "fixedTime:"; Layout.preferredWidth: dlg.labelW }
                    TextField {
                        id: fixedField
                        Layout.fillWidth: true
                        text: dlg.pFixedTime
                        inputMask: "00:00"
                    }

                    Label { text: "startTime:"; Layout.preferredWidth: dlg.labelW }
                    TextField {
                        id: startField
                        Layout.fillWidth: true
                        text: dlg.pStartTime
                        placeholderText: "HH:MM"
                        inputMethodHints: Qt.ImhDigitsOnly
                    }

                    Label { text: "endTime:"; Layout.preferredWidth: dlg.labelW }
                    TextField {
                        id: endField
                        Layout.fillWidth: true
                        text: dlg.pEndTime
                        placeholderText: "HH:MM"
                        inputMethodHints: Qt.ImhDigitsOnly
                    }

                    Label { text: "intervalSeconds:"; Layout.preferredWidth: dlg.labelW }
                    TextField {
                        id: intervalField
                        Layout.fillWidth: true
                        text: "" + dlg.pIntervalSeconds
                        inputMethodHints: Qt.ImhDigitsOnly
                    }
                }

                Frame {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 10
                    padding: 6

                    background: Rectangle {
                        radius: 6
                        border.width: 1
                        border.color: "#6b6b6b"
                        color: "transparent"
                    }

                    ListView {
                        id: idList
                        clip: true
                        model: dlg.activeTestIds
                        anchors.left: parent.left
                        anchors.right: parent.right

                        property int rowH: 42
                        implicitHeight: rowH * 5

                        currentIndex: -1
                        onCurrentIndexChanged: dlg._rebuildSelectedId()

                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                        delegate: Item {
                            width: idList.width
                            height: idList.rowH

                            property bool selected: (idList.currentIndex === index)

                            Rectangle {
                                z: 0
                                anchors.fill: parent
                                radius: 8
                                border.width: selected ? 2 : 1
                                border.color: selected ? "#FFFFFF" : "#6b6b6b"
                                color: selected ? "#1E88E5" : "#FFFFFF"
                            }

                            Rectangle {
                                z: 1
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: 8
                                radius: 8
                                visible: selected
                                color: "#FFD54F"
                            }

                            Row {
                                z: 2
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 10

                                Rectangle {
                                    width: 28
                                    height: parent.height
                                    radius: 6
                                    color: selected ? "#000000AA" : "transparent"

                                    Text {
                                        anchors.centerIn: parent
                                        text: selected ? "✓" : ""
                                        color: selected ? "#FFD54F" : "transparent"
                                        font.pixelSize: 18
                                        font.bold: true
                                    }
                                }

                                Rectangle {
                                    height: parent.height
                                    radius: 6
                                    color: selected ? "#000000AA" : "transparent"
                                    width: Math.max(0, parent.width - 28 - parent.spacing)

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.left: parent.left
                                        anchors.leftMargin: 8
                                        anchors.right: parent.right
                                        anchors.rightMargin: 8

                                        text: "ID: " + modelData
                                        color: selected ? "#FFD54F" : "#111111"
                                        font.pixelSize: 16
                                        font.bold: selected
                                        elide: Text.ElideRight
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    // Toggle: Tap auf selektiertes Item => deselect
                                    if (idList.currentIndex === index)
                                        idList.currentIndex = -1
                                    else
                                        idList.currentIndex = index
                                }
                            }
                        }
                    }
                }

                Label {
                    text: "Test plant Android-Alarm (Dialog bleibt offen). Abbrechen schließt nur den Dialog."
                    font.pixelSize: 12
                    opacity: 0.7
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }

                // Spacer: damit unten nichts vom Footer überdeckt wird
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: footerBox.implicitHeight + 8
                }
            }
        }
    }

    footer: DialogButtonBox {
        id: footerBox
        Layout.fillWidth: true

        Button {
            text: "Test-Start"
            onClicked: dlg.runTest()
        }

        Button {
            text: "Test-Stop"
            enabled: (dlg.selectedTestId > 0)
            onClicked: dlg.stopSelected()
        }

        Button {
            text: "Abbrechen"
            onClicked: dlg.abortDialog()
        }
    }
}
