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

    property bool dBg: true

    function dBG() {
        if (!dBG) return
        console.log.apply(console, arguments)
    }


    property bool allSoundsDisabled: false
    property int expandedIndex: -1

    ListModel { id: actionModel }

    function serializeModel() {
        const arr = []
        for (let i = 0; i < actionModel.count; i++) {
            const o = actionModel.get(i)

            let intervalSeconds = o.intervalSeconds
            if ((intervalSeconds === undefined || intervalSeconds === null) && o.intervalMinutes !== undefined) {
                intervalSeconds = parseInt(o.intervalMinutes) * 60
            }
            if (intervalSeconds === undefined || intervalSeconds === null || isNaN(intervalSeconds))
                intervalSeconds = 1800

            arr.push({
                text: (o.text ?? "Neue Aktion"),
                mode: (o.mode === "interval" ? "interval" : "fixed"),
                fixedTime: (o.fixedTime ?? "00:00"),
                startTime: (o.startTime ?? ""),
                endTime: (o.endTime ?? ""),
                intervalSeconds: intervalSeconds,
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

                let intervalSeconds = o.intervalSeconds
                if ((intervalSeconds === undefined || intervalSeconds === null) && o.intervalMinutes !== undefined) {
                    intervalSeconds = parseInt(o.intervalMinutes) * 60
                }
                if (intervalSeconds === undefined || intervalSeconds === null || isNaN(intervalSeconds))
                    intervalSeconds = 1800

                actionModel.append({
                    text: (typeof o.text === "string" && o.text.trim().length > 0) ? o.text : "Neue Aktion",
                    mode: (o.mode === "interval" ? "interval" : "fixed"),
                    fixedTime: (typeof o.fixedTime === "string" && o.fixedTime.length > 0) ? o.fixedTime : "00:00",
                    startTime: (typeof o.startTime === "string") ? o.startTime : "",
                    endTime: (typeof o.endTime === "string") ? o.endTime : "",
                    intervalSeconds: intervalSeconds,
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
            "intervalSeconds": 1800,
            "sound": "beep.wav",
            "soundDuration": 5,
            "soundEnabled": true
        })
        actionModel.append({
            "text": "Trinken",
            "mode": "interval",
            "fixedTime": "00:00",
            "startTime": "09:00",
            "endTime": "18:00",
            "intervalSeconds": 1800,
            "sound": "beep.wav",
            "soundDuration": 3,
            "soundEnabled": true
        })
    }

    function saveNow() {
        // atomar, sofort
        Storage.saveState(app.allSoundsDisabled, serializeModel())
        dBG("[Main] saveNow() allSoundsDisabled=", app.allSoundsDisabled,
            " jsonLen=", (typeof appSettings !== "undefined" ? appSettings.actionsJson.length : "n/a"))

    }

    function setRole(idx, role, value) {
        if (idx < 0 || idx >= actionModel.count) return
        actionModel.setProperty(idx, role, value)
        saveNow()
    }

    Component.onCompleted: {
        dBG("[Main] onCompleted() start")
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
        dBG("[Main] after load: count=", actionModel.count,
            " first.soundEnabled=",
            (actionModel.count > 0 ? actionModel.get(0).soundEnabled : "n/a"))
    }

    onClosing: function(close) {
        saveNow()
    }

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
                }
            }
        }
    }

    ListView {
        id: listView
        anchors.fill: parent
        anchors.margins: 12
        model: actionModel
        clip: true
        spacing: 12

        delegate: Item {
            width: listView.width
            height: delegateRoot.implicitHeight + 12

            ActionDelegate {
                id: delegateRoot
                width: parent.width

                delegateIndex: index
                expanded: (app.expandedIndex === index)

                // ✅ WICHTIG: Rollen explizit über model.<role>
                actionText: model.text
                mode: model.mode
                fixedTime: model.fixedTime
                startTime: model.startTime
                endTime: model.endTime
                intervalSeconds: model.intervalSeconds
                sound: model.sound
                soundDuration: model.soundDuration
                soundEnabled: model.soundEnabled

                onToggleRequested: function(idx) {
                    app.expandedIndex = (app.expandedIndex === idx) ? -1 : idx
                }

                // Write-back -> Model (wie du es hast)
                onActionTextEdited: function(v) { app.setRole(index, "text", v) }
                onModeEdited: function(v)       { app.setRole(index, "mode", v) }
                onFixedTimeEdited: function(v)  { app.setRole(index, "fixedTime", v) }
                onStartTimeEdited: function(v)  { app.setRole(index, "startTime", v) }
                onEndTimeEdited: function(v)    { app.setRole(index, "endTime", v) }
                onIntervalSecondsEdited: function(v) { app.setRole(index, "intervalSeconds", v) }
                onSoundEdited: function(v)      { app.setRole(index, "sound", v) }
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

    Button {
        id: addBtn
        text: "+"
        width: 56
        height: 56
        font.pixelSize: 26

        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 16

        onClicked: {
            actionModel.append({
                "text": "Neue Aktion",
                "mode": "fixed",
                "fixedTime": "00:00",
                "startTime": "",
                "endTime": "",
                "intervalSeconds": 1800,
                "sound": "",
                "soundDuration": 0,
                "soundEnabled": true
            })

            app.expandedIndex = actionModel.count - 1
            listView.positionViewAtIndex(app.expandedIndex, ListView.End)
            saveNow()
        }
    }
}
