import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia


ApplicationWindow {
    id: app
    width: 390
    height: 720
    visible: true
    title: "Daily Actions"
    color: "#f2f2f2"

    // -------------------------
    // Debug
    // -------------------------
    property bool dbgEnabled: false
    function dbg() {
        if (!dbgEnabled) return
        console.log.apply(console, arguments)
    }

    // -------------------------
    // State
    // -------------------------
    property bool allSoundsDisabled: false
    property int expandedIndex: -1

    ListModel { id: actionModel }

    // -------------------------
    // Persistence helpers
    // -------------------------
    function serializeModel() {
        const arr = []
        for (let i = 0; i < actionModel.count; i++) {
            const o = actionModel.get(i)

            // ✅ intervalMinutes bleibt Minuten (Backwards: intervalSeconds -> Minuten)
            let intervalMinutes = o.intervalMinutes
            if ((intervalMinutes === undefined || intervalMinutes === null) && o.intervalSeconds !== undefined) {
                intervalMinutes = Math.round(parseInt(o.intervalSeconds) / 60)
            }
            if (intervalMinutes === undefined || intervalMinutes === null || isNaN(intervalMinutes))
                intervalMinutes = 60

            arr.push({
                text: (o.text ?? "Neue Aktion"),
                mode: (o.mode === "interval" ? "interval" : "fixed"),
                fixedTime: (o.fixedTime ?? "00:00"),
                startTime: (o.startTime ?? ""),
                endTime: (o.endTime ?? ""),
                intervalMinutes: intervalMinutes,
                sound: (o.sound ?? ""),
                soundDuration: (o.soundDuration ?? 0),
                soundEnabled: (o.soundEnabled ?? true)
            })
        }
        return JSON.stringify(arr)
    }

    function loadFromJson(jsonStr) {
        try {
            const arr = JSON.parse(jsonStr)
            if (!Array.isArray(arr)) return false

            actionModel.clear()

            for (let i = 0; i < arr.length; i++) {
                const o = arr[i] || {}

                // ✅ intervalMinutes bleibt Minuten (Backwards: intervalSeconds -> Minuten)
                let intervalMinutes = o.intervalMinutes
                if ((intervalMinutes === undefined || intervalMinutes === null) && o.intervalSeconds !== undefined) {
                    intervalMinutes = Math.round(parseInt(o.intervalSeconds) / 60)
                }
                if (intervalMinutes === undefined || intervalMinutes === null || isNaN(intervalMinutes))
                    intervalMinutes = 60

                actionModel.append({
                    text: (typeof o.text === "string" && o.text.trim().length > 0) ? o.text : "Neue Aktion",
                    mode: (o.mode === "interval" ? "interval" : "fixed"),
                    fixedTime: (typeof o.fixedTime === "string" && o.fixedTime.length > 0) ? o.fixedTime : "00:00",
                    startTime: (typeof o.startTime === "string") ? o.startTime : "",
                    endTime: (typeof o.endTime === "string") ? o.endTime : "",
                    intervalMinutes: intervalMinutes,
                    sound: (typeof o.sound === "string") ? o.sound : "",
                    soundDuration: (typeof o.soundDuration === "number") ? o.soundDuration : parseInt(o.soundDuration || 0),
                    soundEnabled: (typeof o.soundEnabled === "boolean") ? o.soundEnabled : true
                })
            }
            return true
        } catch (e) {
            console.warn("Load JSON failed:", e)
            return false
        }
    }

    function loadDefaults() {
        actionModel.clear()
        actionModel.append({
            "text": "Übung machen",
            "mode": "fixed",
            "fixedTime": "08:00",
            "startTime": "",
            "endTime": "",
            "intervalMinutes": 60,
            "sound": "Bell",
            "soundDuration": 5,
            "soundEnabled": true
        })
        actionModel.append({
            "text": "Trinken",
            "mode": "interval",
            "fixedTime": "00:00",
            "startTime": "09:00",
            "endTime": "18:00",
            "intervalMinutes": 60,
            "sound": "Bell",
            "soundDuration": 3,
            "soundEnabled": true
        })
    }

    function saveNow() {
        Storage.saveState(app.allSoundsDisabled, serializeModel())
        dbg("[Main] saveNow() allSoundsDisabled=", app.allSoundsDisabled, "count=", actionModel.count)
    }

    function setRole(idx, role, value) {
        if (idx < 0 || idx >= actionModel.count) return

        actionModel.setProperty(idx, role, value)
        saveNow()

        // ✅ wenn gerade diese Einheit offen ist, nachscrollen
        if (app.expandedIndex === idx) {
            ensureVisibleTimer.kick(idx)
        }
    }

    // ✅ exakt die alte "+" Funktionalität
    function addNewAction() {
        actionModel.append({
            "text": "Neue Aktion",
            "mode": "fixed",
            "fixedTime": "00:00",
            "startTime": "",
            "endTime": "",
            "intervalMinutes": 60,
            "sound": "Bell",
            "soundDuration": 0,
            "soundEnabled": true
        })

        app.expandedIndex = actionModel.count - 1
        ensureVisibleTimer.kick(app.expandedIndex)
        saveNow()
    }

    Component.onCompleted: {
        dbg("[Main] onCompleted() start")
        const st = Storage.loadState()
        if (st.ok) {
            app.allSoundsDisabled = !!st.allSoundsDisabled
            const ok = loadFromJson(st.actionsJson || "")
            if (!ok) {
                loadDefaults()
                saveNow()
            }
        } else {
            loadDefaults()
            saveNow()
        }
        dbg("[Main] after load: count=", actionModel.count,
            " first.soundEnabled=",
            (actionModel.count > 0 ? actionModel.get(0).soundEnabled : "n/a"))
    }

    onClosing: function(close) {
        bellSfx.stop()
        saveNow()
    }

    SoundEffect {
        id: bellSfx
        source: "qrc:/sounds/bell.wav"
        volume: 1.0
        muted: false

        onStatusChanged: {
            //console.log("[Main:SFX] status=", status, "source=", source, "err=", (errorString || ""))
            if (status === SoundEffect.Error) {
                app.resetBellSfx("SoundEffect.Error")
            }
        }
        onPlayingChanged: {
            console.log("[Main:SFX] playing=", playing)
        }
    }

    function playBellPreview() {
        console.log("[Main] playBellPreview() status=", bellSfx.status, "playing=", bellSfx.playing)

        if (bellSfx.status === SoundEffect.Error) {
            resetBellSfx("playBellPreview saw Error")
            // nach Reset abspielen (leicht verzögert, damit source neu geladen ist)
            Qt.callLater(function() { bellSfx.stop(); bellSfx.play() })
            return
        }

        bellSfx.stop()
        bellSfx.play()
    }

    MediaDevices {
        id: mediaDevices

        onDefaultAudioOutputChanged: app.resetBellSfx("defaultAudioOutputChanged")
        onAudioOutputsChanged: app.resetBellSfx("audioOutputsChanged")
    }

    Timer {
        id: bellResetDebounce
        interval: 150
        repeat: false
        property string reason: ""

        onTriggered: {
            console.log("[Main:SFX] RESET now reason=", reason)
            bellSfx.stop()
            // “hart” neu laden
            bellSfx.source = ""
            bellSfx.source = "qrc:/sounds/bell.wav"
        }
    }

    function resetBellSfx(reason) {
        console.log("[Main:SFX] resetBellSfx request reason=", reason,
                    " status=", bellSfx.status, " playing=", bellSfx.playing)
        bellResetDebounce.reason = reason
        bellResetDebounce.restart()
    }

    // -------------------------
    // Header (+ neben Ton-Button)
    // -------------------------
    header: ToolBar {
        id: topBar
        height: 56

        Item {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12

            RowLayout {
                anchors.fill: parent
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12

                Label {
                    text: "Daily Actions"
                    font.pixelSize: 18
                    font.bold: true
                    Layout.fillWidth: true
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                }

                RowLayout {
                    spacing: 10
                    Layout.alignment: Qt.AlignVCenter | Qt.AlignRight

                    Label {
                        text: app.allSoundsDisabled ? "Töne: AUS" : "Töne: AN"
                        opacity: 0.85
                        font.pixelSize: 13
                        verticalAlignment: Text.AlignVCenter
                        color: "#444444"
                    }

                    Button {
                        id: soundToggleBtn
                        text: app.allSoundsDisabled ? "Ton an" : "Ton ausschalten"
                        onClicked: {
                            app.allSoundsDisabled = !app.allSoundsDisabled
                            saveNow()
                        }

                        height: 34
                        padding: 10

                        contentItem: Text {
                            text: soundToggleBtn.text
                            color: "white"
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                        }

                        background: Rectangle {
                            radius: 10
                            border.color: "#2b2b2b"
                            color: app.allSoundsDisabled ? "#9e9e9e" : "#2e7d32"
                            opacity: soundToggleBtn.down ? 0.85 : 1.0
                        }
                    }

                    // ✅ neuer + Button im Kopf (statt Floating)
                    Button {
                        id: addHeaderBtn
                        width: 80
                        height: 80
                        onClicked: addNewAction()

                        // Tooltip (Desktop Hover)
                        ToolTip.visible: hovered
                        ToolTip.text: "Neue Aktion"

                        contentItem: Text {
                            text: "+"
                            color: "#ffffff"          // ✅ weiß
                            font.pixelSize: 40
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 10
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }

                        background: Rectangle {
                            radius: 10
                            color: "transparent"
                            opacity: addHeaderBtn.down ? 0.85 : 1.0
                        }

                        Accessible.name: "Neue Aktion"
                    }
                }
            }
        }
    }

    // -------------------------
    // Auto-scroll (ohne FAB-safe)
    // -------------------------
    function ensureIndexVisible(idx) {
        if (idx < 0) return

        listView.positionViewAtIndex(idx, ListView.Visible)

        const item = listView.itemAtIndex(idx)
        if (!item) return

        const viewTop = listView.contentY
        const viewBottom = listView.contentY + listView.height

        const itemTop = item.y
        const itemBottom = item.y + item.height

        let newY = listView.contentY

        if (itemBottom > viewBottom) {
            newY = itemBottom - listView.height
        } else if (itemTop < viewTop) {
            newY = itemTop
        }

        const maxY = Math.max(0, listView.contentHeight - listView.height)
        newY = Math.max(0, Math.min(newY, maxY))

        if (newY !== listView.contentY)
            listView.contentY = newY
    }

    Timer {
        id: ensureVisibleTimer
        interval: 16
        repeat: true
        property int targetIndex: -1
        property int tries: 0

        function kick(idx) {
            targetIndex = idx
            tries = 0
            start()
        }

        onTriggered: {
            tries++
            ensureIndexVisible(targetIndex)
            if (tries >= 8)
                stop()
        }
    }

    // -------------------------
    // List
    // -------------------------
    ListView {
        id: listView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        anchors.leftMargin: 12
        anchors.rightMargin: 12
        anchors.topMargin: 12

        model: actionModel
        spacing: 12
        clip: true

        // kleine Luft unten (optional)
        footerPositioning: ListView.InlineFooter
        footer: Item { width: 1; height: 12 }

        delegate: Item {
            width: listView.width
            height: delegateRoot.implicitHeight + 12

            ActionDelegate {
                id: delegateRoot
                width: parent.width

                delegateIndex: index
                expanded: (app.expandedIndex === index)

                actionText: model.text
                mode: model.mode
                fixedTime: model.fixedTime
                startTime: model.startTime
                endTime: model.endTime
                intervalMinutes: model.intervalMinutes
                sound: model.sound
                soundDuration: model.soundDuration
                soundEnabled: model.soundEnabled
                onBellPreviewRequested: app.playBellPreview()

                onToggleRequested: function(idx) {
                    app.expandedIndex = (app.expandedIndex === idx) ? -1 : idx
                    if (app.expandedIndex >= 0)
                        ensureVisibleTimer.kick(app.expandedIndex)
                }

                onActionTextEdited: function(v) { app.setRole(index, "text", v) }
                onModeEdited: function(v) { app.setRole(index, "mode", v) }
                onFixedTimeEdited: function(v) { app.setRole(index, "fixedTime", v) }
                onStartTimeEdited: function(v) { app.setRole(index, "startTime", v) }
                onEndTimeEdited: function(v) { app.setRole(index, "endTime", v) }
                onIntervalMinutesEdited: function(v) { app.setRole(index, "intervalMinutes", v) }
                onSoundEdited: function(v) { app.setRole(index, "sound", v) }
                onSoundDurationEdited: function(v) { app.setRole(index, "soundDuration", v) }
                onSoundEnabledEdited: function(v) { app.setRole(index, "soundEnabled", v) }

                onDeleteRequested: function(idx) {
                    if (idx < 0 || idx >= actionModel.count) return

                    if (app.expandedIndex === idx)
                        app.expandedIndex = -1
                    else if (app.expandedIndex > idx)
                        app.expandedIndex -= 1

                    actionModel.remove(idx, 1)
                    saveNow()
                }
            }
        }
    }
}
