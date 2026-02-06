import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia

import DailyActions 1.0

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
    property bool dbgEnabled: true
    function lw() {
        if(typeof Log==='undefined'||!Log||typeof Log.w!=='function')
            return;Log.w(Array.prototype.join.call(arguments,' '))
    }

    function dbg() {
        if (!dbgEnabled) return
        if (typeof Log !== "undefined" && Log && typeof Log.w === "function")
            Log.w(Array.prototype.join.call(arguments, " "))
    }

    // -------------------------
    // Sound mapping (Name -> qrc:/sounds/...)
    // -------------------------
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

    // -------------------------
    // State (actionsRunning NICHT persistieren)
    // -------------------------
    property bool actionsRunning: false
    property bool allSoundsDisabled: false   // legacy (persistiert), aktuell nicht im UI benutzt
    property int expandedIndex: -1
    property bool uiPaused: false
    property bool configured: false

    Connections {
        target: (typeof SoundTaskManager !== "undefined") ? SoundTaskManager : null
        function onLogLine(s) { lw("[SoundTaskManager]", s) }
    }

    function detectRunningActionsOnStartup() {
        if (!SoundTaskManager) return

        let any = false
        for (let i = 0; i < actionModel.count; i++) {
            const id = actionModel.get(i).alarmId   // oder wie bei dir die ID heißt
            dbg("[checkAlarmId =", id)

            if (SoundTaskManager.isScheduled(id)) {
                any = true
                break
            }
        }
        return any
    }

    function updateUiPaused() {
        uiPaused = (Qt.application.state !== Qt.ApplicationActive)
    }

    Connections {
        target: Qt.application
        function onStateChanged() { app.updateUiPaused() }
    }

    Timer {
        interval: 200
        running: actionsRunning && !uiPaused
        repeat: true
        onTriggered: schedulerStep()
    }

    ListModel { id: actionModel }

    // -------------------------
    // Helpers
    // -------------------------
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

    // Stable IDs for Android AlarmManager (persisted)
    property int nextAlarmId: 1
    function ensureAlarmId(idx) {
        if (idx < 0 || idx >= actionModel.count) return -1
        const o = actionModel.get(idx)
        if (typeof o.alarmId === "number" && o.alarmId > 0) return o.alarmId
        const id = Math.max(1, nextAlarmId)
        actionModel.setProperty(idx, "alarmId", id)
        nextAlarmId = id + 1
        saveNow()
        return id
    }

    function normalizeAlarmIds() {
        let maxId = 0
        let changed = false
        for (let i = 0; i < actionModel.count; i++) {
            const o = actionModel.get(i)
            let id = (typeof o.alarmId === "number") ? o.alarmId : 0
            if (id <= 0) {
                id = maxId + 1
                actionModel.setProperty(i, "alarmId", id)
                changed = true
            }
            if (id > maxId) maxId = id
        }
        nextAlarmId = maxId + 1
        if (changed) saveNow()
    }
    function _isAppActive() { return Qt.application.state === Qt.ApplicationActive }

    function _shouldUseSoundTaskManagersNow() {
        // Plattform-unabhängig: Scheduling wird vom SoundTaskManager entschieden.
        return actionsRunning
    }

    function _hasSoundTaskManagerBridge() {
        return (typeof SoundTaskManager !== "undefined") && SoundTaskManager
    }

    function cancelTaskManagerForIndex(idx) {
        if (!_hasSoundTaskManagerBridge()) return
        if (idx < 0 || idx >= actionModel.count) return
        const o = actionModel.get(idx)
        const id = (typeof o.alarmId === "number") ? o.alarmId : 0
        if (id > 0) {
            dbg("[SoundTaskManager] cancel idx=", idx, " id=", id)
            SoundTaskManager.cancel(id)
        }
    }

    function cancelAllSoundTaskManagers() {
        if (!_hasSoundTaskManagerBridge()) return
        for (let i = 0; i < actionModel.count; i++)
            cancelTaskManagerForIndex(i)
    }

    function scheduleTaskManagerForIndex(idx, nowMs) {
        if (!_hasSoundTaskManagerBridge()) return
        if (idx < 0 || idx >= actionModel.count) return

        const id = ensureAlarmId(idx)
        if (id <= 0) return

        const o = actionModel.get(idx)
        const fireMs = (typeof o.nextFireMs === "number") ? o.nextFireMs : 0
        if (!fireMs || fireMs <= 0) return

        const rawSound = soundRawForName(o.sound)
        const title = (typeof o.text === "string" && o.text.length > 0) ? o.text : "Reminder"
        const text = ""

        const enabled = (o.soundEnabled === undefined) ? true : !!o.soundEnabled
        const baseVol = (typeof o.volume === "number" && !isNaN(o.volume)) ? o.volume : 1.0
        const effectiveVol = (!app.allSoundsDisabled && enabled) ? Math.max(0.0, Math.min(1.0, baseVol)) : 0.0

        dbg("[SoundTaskManager] schedule idx=", idx, " id=", id, " fire=", new Date(fireMs).toISOString(), " mode=", o.mode, " enabled=", enabled, " vol=", effectiveVol)
        SoundTaskManager.scheduleWithParams(
            fireMs,
            rawSound,
            id,
            title,
            text,
            (o.mode === "interval" ? "interval" : "fixed"),
            (o.fixedTime || "00:00"),
            (o.startTime || ""),
            (o.endTime || ""),
            ((typeof o.intervalMinutes === "number" ? o.intervalMinutes : parseInt(o.intervalMinutes || 0)) * 10),
            effectiveVol
        )
    }

    function scheduleAllSoundTaskManagers() {
        if (!_hasSoundTaskManagerBridge()) return
        const nowMs = Date.now()
        for (let i = 0; i < actionModel.count; i++) {
            scheduleForIndex(i, nowMs) // UI countdown only
            scheduleTaskManagerForIndex(i, nowMs) // real scheduling
        }
    }

    // -------------------------
    // Persistence
    // -------------------------
    function serializeModel() {
        const arr = []
        for (let i = 0; i < actionModel.count; i++) {
            const o = actionModel.get(i)

            let intervalMinutes = o.intervalMinutes

            arr.push({
                alarmId: (typeof o.alarmId === "number") ? o.alarmId : 0,
                text: (o.text ?? "Neue Aktion"),
                mode: (o.mode === "interval" ? "interval" : "fixed"),
                fixedTime: (o.fixedTime ?? "00:00"),
                startTime: (o.startTime ?? ""),
                endTime: (o.endTime ?? ""),
                intervalMinutes: intervalMinutes,
                sound: (o.sound ?? "Bell"),
                soundEnabled: (o.soundEnabled ?? true),
                volume: (typeof o.volume === "number") ? o.volume : 1.0
            })
        }
        return JSON.stringify(arr)
    }

    // NEW: hält ein Element, bis SoundEffect wirklich Ready ist
    property var _pendingSfxItem: null

    function _pumpSoundQueue() {
        if (_soundQueue.length === 0 && _pendingSfxItem === null) return
        if (previewSfx.playing) return

        const now = Date.now()
        if ((now - _lastSoundStartMs) < _minSoundGapMs) return

        if (_pendingSfxItem === null) {
            _pendingSfxItem = _soundQueue.shift()
            desiredPreviewSource = _pendingSfxItem.src
            desiredPreviewVolume = _pendingSfxItem.vol

            if (previewSfx.source !== desiredPreviewSource) {
                previewSfx.source = desiredPreviewSource
                return
            }
        }

        if (previewSfx.status === SoundEffect.Loading) return

        if (previewSfx.status === SoundEffect.Error) {
            _soundQueue.unshift(_pendingSfxItem)
            _pendingSfxItem = null
            resetPreviewSfx("pump saw SoundEffect.Error")
            _lastSoundStartMs = now
            return
        }

        if (previewSfx.status !== SoundEffect.Ready) return

        _lastSoundStartMs = now
        previewSfx.play()
        _pendingSfxItem = null
    }

    function loadFromJson(jsonStr) {
        try {
            const arr = JSON.parse(jsonStr)
            if (!Array.isArray(arr)) return false

            actionModel.clear()

            for (let i = 0; i < arr.length; i++) {
                const o = arr[i] || {}

                let intervalMinutes = o.intervalMinutes

                actionModel.append({
                    alarmId: (typeof o.alarmId === "number") ? o.alarmId : parseInt(o.alarmId || 0),
                    text: (typeof o.text === "string" && o.text.trim().length > 0) ? o.text : "Neue Aktion",
                    mode: (o.mode === "interval" ? "interval" : "fixed"),
                    fixedTime: (typeof o.fixedTime === "string" && o.fixedTime.length > 0) ? o.fixedTime : "00:00",
                    startTime: (typeof o.startTime === "string") ? o.startTime : "",
                    endTime: (typeof o.endTime === "string") ? o.endTime : "",
                    intervalMinutes: intervalMinutes,
                    sound: (typeof o.sound === "string" && o.sound.trim().length > 0) ? o.sound : "Bell",
                    soundEnabled: (typeof o.soundEnabled === "boolean") ? o.soundEnabled : true,
                    volume: (typeof o.volume === "number") ? o.volume : parseFloat(o.volume || 1.0)
                })
            }

            normalizeAlarmIds()
            return true
        } catch (e) {
            console.warn("Load JSON failed:", e)
            return false
        }
    }

    function loadDefaults() {
        actionModel.clear()
        actionModel.append({
            "alarmId": 1,
            "text": "Übung machen",
            "mode": "fixed",
            "fixedTime": "08:00",
            "startTime": "",
            "endTime": "",
            "intervalMinutes": 60,
            "sound": "Bell",
            "soundEnabled": true,
            "volume": 1.0
        })
        actionModel.append({
            "alarmId": 2,
            "text": "Trinken",
            "mode": "interval",
            "fixedTime": "00:00",
            "startTime": "09:00",
            "endTime": "18:00",
            "intervalMinutes": 60,
            "sound": "Bell",
            "soundEnabled": true,
            "volume": 1.0
        })
        normalizeAlarmIds()
    }

    function saveNow() {
        Storage.saveState(app.allSoundsDisabled, serializeModel())
    }

    function setRole(idx, role, value) {
        if (idx < 0 || idx >= actionModel.count) return

        actionModel.setProperty(idx, role, value)
        saveNow()

        if (app.expandedIndex === idx) {
            ensureVisibleTimer.kick(idx)
        }

        if (actionsRunning && (
                role === "mode" ||
                role === "startTime" || role === "endTime" || role === "intervalMinutes" ||
                role === "fixedTime"
            )) {

            actionModel.setProperty(idx, "nextFireMs", 0)
            actionModel.setProperty(idx, "lastFiredMs", 0)

            Qt.callLater(function() {
                const nowMs = Date.now()
                scheduleForIndex(idx, nowMs)
                scheduleTaskManagerForIndex(idx, nowMs)
            })
        }
        if (actionsRunning && (role === "sound" || role === "soundEnabled" || role === "volume")) {
            dbg("[main] sound changed", "role=", role)
            Qt.callLater(function() {
                // immer: alten Task weg
                dbg("[main] sound changed cancel", "role=", role)
                cancelTaskManagerForIndex(idx)

                const nowMs = Date.now()

                // UI-Next/Countdown ggf. aktualisieren wie vorher (unverändert)
                dbg("[main] sound changed scheduleForIndex", "role=", role)
                scheduleForIndex(idx, nowMs)

                // immer neu planen – auch wenn soundEnabled=false oder volume=0,
                // damit der Android-Alarm die neuen Extras (vol=0) bekommt
                dbg("[main] sound changed scheduleTaskManagerForIndex", "role=", role)
                scheduleTaskManagerForIndex(idx, nowMs)
            })
        }
    }

    function addNewAction() {
        const newAlarmId = nextAlarmId
        nextAlarmId += 1
        actionModel.append({
            "alarmId": newAlarmId,
            "text": "Neue Aktion",
            "mode": "fixed",
            "fixedTime": "00:00",
            "startTime": "",
            "endTime": "",
            "intervalMinutes": 60,
            "sound": "Bell",
            "soundEnabled": true,
            "volume": 0.5
        })

        const idx = actionModel.count - 1
        app.expandedIndex = idx
        ensureVisibleTimer.kick(idx)
        saveNow()

        if (actionsRunning) {
            const nowMs = Date.now()
            scheduleForIndex(idx, nowMs)
            scheduleTaskManagerForIndex(idx, nowMs)
        }
    }



    // -------------------------
    // Test-Scheduling Dialog (ausgelagert)
    // -------------------------
    TestScheduling {
        id: testScheduling
        soundChoices: app.soundChoices
        soundMap: app.soundMap
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
        SoundTaskManager.ensure()

        normalizeAlarmIds()
        // Running-Status aus Android-Alarms ableiten
        app.actionsRunning = app.detectRunningActionsOnStartup()
        dbg("[Main] startup actionsRunning=", actionsRunning)
        if (app.actionsRunning) {
            startActions()
        } else {
            stopActions()
        }

        //stopActions()
        // statt testScheduling.open()
        /*
        Qt.callLater(function() {
            Qt.callLater(function() {
                testScheduling.open()
                testScheduling.forceActiveFocus()
            })
        })
        */
    }

    onClosing: function(close) {
        previewSfx.stop()
        saveNow()
    }

    // -------------------------
    // Preview SoundEffect (zentraler Player)
    // -------------------------
    property string desiredPreviewSource: "qrc:/sounds/bell.wav"
    property real desiredPreviewVolume: 1.0

    SoundEffect {
        id: previewSfx
        source: app.desiredPreviewSource
        volume: app.desiredPreviewVolume
        muted: false

        onStatusChanged: {
            if (status === SoundEffect.Error) {
                app.resetPreviewSfx("SoundEffect.Error")
            }
        }
    }

    MediaDevices {
        id: mediaDevices
        onDefaultAudioOutputChanged: {
            if (previewSfx.playing || app._soundQueue.length > 0 || app._pendingSfxItem)
                app.resetPreviewSfx("defaultAudioOutputChanged")
        }
        onAudioOutputsChanged: {
            if (previewSfx.playing || app._soundQueue.length > 0 || app._pendingSfxItem)
                app.resetPreviewSfx("audioOutputsChanged")
        }
    }

    Timer {
        id: sfxSafeReset
        interval: 250
        repeat: false
        property string reason: ""

        onTriggered: {
            if (previewSfx.playing) {
                previewSfx.stop()
                sfxSafeReset.restart()
                return
            }
            const src = app.desiredPreviewSource
            previewSfx.source = ""
            Qt.callLater(function() { previewSfx.source = src })
        }
    }

    function resetPreviewSfx(reason) {
        lw("[Main:SFX] resetPreviewSfx reason=", reason)
        _pendingSfxItem = null
        sfxSafeReset.reason = reason
        sfxSafeReset.restart()
    }

    // =========================================================
    // Sound Queue: entzerrt gleichzeitige Trigger (>= 500ms Abstand)
    // =========================================================
    property var _soundQueue: []          // [{name, src, vol}]
    property int _minSoundGapMs: 500
    property int _lastSoundStartMs: 0

    Timer {
        id: soundQueuePump
        interval: 50
        repeat: true
        running: true
        onTriggered: app._pumpSoundQueue()
    }

    function enqueueSound(soundName, vol01, priority) {
        const name = (typeof soundName === "string" && soundName.trim().length > 0) ? soundName.trim() : "Bell"
        const src = soundSourceForName(name)
        const v = (typeof vol01 === "number" && !isNaN(vol01)) ? Math.max(0.0, Math.min(1.0, vol01)) : 1.0
        const it = { name: name, src: src, vol: v }

        if (priority)
            _soundQueue.unshift(it)
        else
            _soundQueue.push(it)
    }

    function playSoundPreview(soundName, vol) {
        enqueueSound(soundName, vol, true)
    }

    // =========================================================
    // Scheduler
    // =========================================================
    Timer {
        id: intervalScheduler
        interval: 1000
        repeat: true
        running: app.actionsRunning
        triggeredOnStart: true
        onTriggered: app.schedulerStep()
    }

    function startActions() {
        dbg("[Main] startActions()")
        actionsRunning = true
        schedulerInit()
        intervalScheduler.restart()

        // Scheduling ausschließlich über SoundTaskManager
        //cancelAllSoundTaskManagers()
        scheduleAllSoundTaskManagers()
    }


    function stopActions() {
        dbg("[Main] stopActions()")
        actionsRunning = false
        intervalScheduler.stop()

        // Scheduling ausschließlich über SoundTaskManager
        cancelAllSoundTaskManagers()

        for (let i = 0; i < actionModel.count; i++) {
            actionModel.setProperty(i, "nextInMinutes", -1)
            actionModel.setProperty(i, "nextInSeconds", -1)

            actionModel.setProperty(i, "nextFixedH", -1)
            actionModel.setProperty(i, "nextFixedM", -1)
            actionModel.setProperty(i, "nextFixedS", -1)

            actionModel.setProperty(i, "nextFireMs", 0)
            actionModel.setProperty(i, "lastFiredMs", 0)
        }
    }


    function computeNextFixedFireMs(nowMs, fixedTime) {
        const now = new Date(nowMs)
        const tMin = parseHHMMToMinutes(fixedTime || "00:00")
        let target = dateAtMinutes(now, tMin)
        if (now.getTime() >= target.getTime())
            target.setDate(target.getDate() + 1)
        return target.getTime()
    }

    function _clearIntervalCountdown(i) {
        actionModel.setProperty(i, "nextInMinutes", -1)
        actionModel.setProperty(i, "nextInSeconds", -1)
    }
    function _clearFixedCountdown(i) {
        actionModel.setProperty(i, "nextFixedH", -1)
        actionModel.setProperty(i, "nextFixedM", -1)
        actionModel.setProperty(i, "nextFixedS", -1)
    }

    function _setIntervalCountdown(i, targetMs, nowMs) {
        _clearFixedCountdown(i)

        const msLeft = targetMs - nowMs
        if (msLeft <= 0) {
            actionModel.setProperty(i, "nextInMinutes", 0)
            actionModel.setProperty(i, "nextInSeconds", 0)
            return
        }

        if (msLeft <= 60000) {
            const secsTotal = Math.max(0, Math.floor(msLeft / 1000.0))
            actionModel.setProperty(i, "nextInMinutes", -1)
            actionModel.setProperty(i, "nextInSeconds", secsTotal)
            return
        }

        const mins = Math.max(1, Math.ceil(msLeft / 60000.0))
        actionModel.setProperty(i, "nextInMinutes", mins)
        actionModel.setProperty(i, "nextInSeconds", -1)
    }

    function _setFixedCountdown(i, targetMs, nowMs) {
        _clearIntervalCountdown(i)

        const msLeft = targetMs - nowMs
        if (msLeft <= 0) {
            actionModel.setProperty(i, "nextFixedH", 0)
            actionModel.setProperty(i, "nextFixedM", 0)
            actionModel.setProperty(i, "nextFixedS", 0)
            return
        }

        if (msLeft <= 60000) {
            const totalSec = Math.max(0, Math.floor(msLeft / 1000.0))
            const h = Math.floor(totalSec / 3600)
            const m = Math.floor((totalSec % 3600) / 60)
            const s = totalSec % 60
            actionModel.setProperty(i, "nextFixedH", h)
            actionModel.setProperty(i, "nextFixedM", m)
            actionModel.setProperty(i, "nextFixedS", s)
            return
        }

        const totalMin = Math.max(1, Math.ceil(msLeft / 60000.0))
        const h2 = Math.floor(totalMin / 60)
        const m2 = totalMin % 60
        actionModel.setProperty(i, "nextFixedH", h2)
        actionModel.setProperty(i, "nextFixedM", m2)
        actionModel.setProperty(i, "nextFixedS", -1)
    }

    function scheduleForIndex(idx, nowMs) {
        if (idx < 0 || idx >= actionModel.count) return
        const o = actionModel.get(idx)
        const mode = (o.mode || "fixed")
        if (mode === "interval")
            scheduleIntervalForIndex(idx, nowMs)
        else
            scheduleFixedForIndex(idx, nowMs)
    }

    function scheduleFixedForIndex(idx, nowMs) {
        if (idx < 0 || idx >= actionModel.count) return
        const o = actionModel.get(idx)

        if ((o.mode || "fixed") !== "fixed") {
            _clearFixedCountdown(idx)
            actionModel.setProperty(idx, "nextFireMs", 0)
            actionModel.setProperty(idx, "lastFiredMs", 0)
            return
        }

        const nextMs = computeNextFixedFireMs(nowMs, o.fixedTime || "00:00")
        actionModel.setProperty(idx, "nextFireMs", nextMs)
        actionModel.setProperty(idx, "lastFiredMs", 0)
        _setFixedCountdown(idx, nextMs, nowMs)
    }

    function scheduleIntervalForIndex(idx, nowMs) {
        if (idx < 0 || idx >= actionModel.count) return
        const o = actionModel.get(idx)

        if ((o.mode || "fixed") !== "interval") {
            _clearIntervalCountdown(idx)
            actionModel.setProperty(idx, "nextFireMs", 0)
            actionModel.setProperty(idx, "lastFiredMs", 0)
            return
        }

        const intervalMinutes = parseInt(o.intervalMinutes || 0)
        if (!intervalMinutes || intervalMinutes <= 0) {
            _clearIntervalCountdown(idx)
            actionModel.setProperty(idx, "nextFireMs", 0)
            actionModel.setProperty(idx, "lastFiredMs", 0)
            return
        }

        const nextMs = computeNextIntervalFireMs(nowMs, o.startTime || "", o.endTime || "", intervalMinutes)
        actionModel.setProperty(idx, "nextFireMs", nextMs)
        actionModel.setProperty(idx, "lastFiredMs", 0)
        _setIntervalCountdown(idx, nextMs, nowMs)
    }

    function schedulerInit() {
        const nowMs = Date.now()
        for (let i = 0; i < actionModel.count; i++)
            scheduleForIndex(i, nowMs)
        schedulerStep()
    }

    function schedulerStep() {
        if (!actionsRunning) return

        const nowMs = Date.now()

        for (let i = 0; i < actionModel.count; i++) {
            const o = actionModel.get(i)
            const mode = (o.mode || "fixed")

            if (mode === "interval") {
                const intervalMinutes = parseInt(o.intervalMinutes || 0)
                if (!intervalMinutes || intervalMinutes <= 0) {
                    _clearIntervalCountdown(i)
                    actionModel.setProperty(i, "nextFireMs", 0)
                    continue
                }

                let nextMs = parseInt(o.nextFireMs || 0)
                if (!nextMs || isNaN(nextMs) || nextMs <= 0) {
                    nextMs = computeNextIntervalFireMs(nowMs, o.startTime || "", o.endTime || "", intervalMinutes)
                    actionModel.setProperty(i, "nextFireMs", nextMs)
                }

                _setIntervalCountdown(i, nextMs, nowMs)

                const lastFired = parseInt(o.lastFiredMs || 0)
                if (nowMs >= nextMs && lastFired !== nextMs) {
                    actionModel.setProperty(i, "lastFiredMs", nextMs)

                    const baseNow = nowMs + 1000
                    const next2 = computeNextIntervalFireMs(baseNow, o.startTime || "", o.endTime || "", intervalMinutes)
                    actionModel.setProperty(i, "nextFireMs", next2)
                    _setIntervalCountdown(i, next2, baseNow)
                }

            } else {
                let nextMsF = parseInt(o.nextFireMs || 0)
                if (!nextMsF || isNaN(nextMsF) || nextMsF <= 0) {
                    nextMsF = computeNextFixedFireMs(nowMs, o.fixedTime || "00:00")
                    actionModel.setProperty(i, "nextFireMs", nextMsF)
                }

                _setFixedCountdown(i, nextMsF, nowMs)

                const lastFiredF = parseInt(o.lastFiredMs || 0)
                if (nowMs >= nextMsF && lastFiredF !== nextMsF) {
                    actionModel.setProperty(i, "lastFiredMs", nextMsF)

                    const baseNowF = nowMs + 1000
                    const next2F = computeNextFixedFireMs(baseNowF, o.fixedTime || "00:00")
                    actionModel.setProperty(i, "nextFireMs", next2F)
                    _setFixedCountdown(i, next2F, baseNowF)
                }
            }
        }
    }

    function parseHHMMToMinutes(t) {
        if (typeof t !== "string") return 0
        const s = t.trim()
        if (s.length === 0) return 0
        const parts = s.split(":")
        if (parts.length < 2) return 0

        let h = parseInt(parts[0])
        let m = parseInt(parts[1])
        if (isNaN(h)) h = 0
        if (isNaN(m)) m = 0

        h = Math.max(0, Math.min(23, h))
        m = Math.max(0, Math.min(59, m))
        return h * 60 + m
    }

    function dateAtMinutes(baseDate, minutes) {
        const d = new Date(baseDate.getFullYear(), baseDate.getMonth(), baseDate.getDate(), 0, 0, 0, 0)
        d.setMinutes(minutes)
        return d
    }

    function computeNextIntervalFireMs(nowMs, startTime, endTime, intervalMinutes) {
        const now = new Date(nowMs)

        const startMin = parseHHMMToMinutes(startTime)
        const endMin = parseHHMMToMinutes(endTime)

        let start = dateAtMinutes(now, startMin)
        let end = dateAtMinutes(now, endMin)

        if (endMin === startMin) {
            end.setDate(end.getDate() + 1)
        } else if (endMin < startMin) {
            end.setDate(end.getDate() + 1)
        }

        if (now.getTime() < start.getTime())
            return start.getTime()

        if (now.getTime() >= end.getTime()) {
            start.setDate(start.getDate() + 1)
            return start.getTime()
        }

        const intervalMs = Math.max(1, intervalMinutes) * 60 * 1000
        const elapsedMs = now.getTime() - start.getTime()

        let k = Math.ceil(elapsedMs / intervalMs)
        if (k < 0) k = 0

        let next = new Date(start.getTime() + k * intervalMs)

        if (next.getTime() < start.getTime())
            next = start

        if (next.getTime() >= end.getTime()) {
            start.setDate(start.getDate() + 1)
            next = start
        }

        return next.getTime()
    }

    // -------------------------
    // Header
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

                    Button {
                        id: actionsToggleBtn
                        text: app.actionsRunning ? "Aktionen stoppen" : "Aktionen starten"
                        height: 34
                        padding: 10

                        onClicked: {
                            if (app.actionsRunning)
                                app.stopActions()
                            else
                                app.startActions()
                        }

                        contentItem: Text {
                            text: actionsToggleBtn.text
                            color: "white"
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            elide: Text.ElideRight
                        }

                        background: Rectangle {
                            radius: 10
                            border.color: "#2b2b2b"
                            color: app.actionsRunning ? "#616161" : "#2e7d32"
                            opacity: actionsToggleBtn.down ? 0.85 : 1.0
                        }
                    }

                                        Button {
                        id: addHeaderBtn
                        width: 80
                        height: 80
                        onClicked: addNewAction()

                        ToolTip.visible: hovered
                        ToolTip.text: "Neue Aktion"

                        contentItem: Text {
                            text: "+"
                            color: "#ffffff"
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
    // Auto-scroll
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

                nextInMinutes: (app.actionsRunning && typeof model.nextInMinutes === "number") ? model.nextInMinutes : -1
                nextInSeconds: (app.actionsRunning && typeof model.nextInSeconds === "number") ? model.nextInSeconds : -1

                nextFixedH: (app.actionsRunning && typeof model.nextFixedH === "number") ? model.nextFixedH : -1
                nextFixedM: (app.actionsRunning && typeof model.nextFixedM === "number") ? model.nextFixedM : -1
                nextFixedS: (app.actionsRunning && typeof model.nextFixedS === "number") ? model.nextFixedS : -1

                sound: model.sound
                soundEnabled: model.soundEnabled
                volume: model.volume
                onVolumeEdited: function(v) { app.setRole(index, "volume", v) }

                soundChoices: app.soundChoices
                onPreviewSoundRequested: function(name) { app.playSoundPreview(name, delegateRoot.volume) }

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
                onSoundEnabledEdited: function(v) { app.setRole(index, "soundEnabled", v) }

                onDeleteRequested: function(idx) {
                    if (idx < 0 || idx >= actionModel.count) return

                    cancelTaskManagerForIndex(idx)

                    if (app.expandedIndex === idx)
                        app.expandedIndex = -1
                    else if (app.expandedIndex > idx)
                        app.expandedIndex -= 1

                    actionModel.remove(idx, 1)
                    saveNow()

                    if (actionsRunning) {
                        schedulerInit()
                        if (_shouldUseSoundTaskManagersNow())
                            scheduleAllSoundTaskManagers()
                    }
                }
            }
        }
    }
}
