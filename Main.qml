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

    function collectAlarmIds() {
        var ids = []
        var seen = {}
        for (var i = 0; i < actionModel.count; ++i) {
            var o = actionModel.get(i)
            var id = (typeof o.alarmId === "number") ? o.alarmId : 0
            if (id > 0 && !seen[id]) {
                seen[id] = true
                ids.push(id)
            }
        }
        return ids
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

    function _isAppActive() { return Qt.application.state === Qt.ApplicationActive }

    function cancelTaskManagerForIndex(idx) {
        if (idx < 0 || idx >= actionModel.count) return
        const o = actionModel.get(idx)
        const id = (typeof o.alarmId === "number") ? o.alarmId : 0
        if (id > 0) {
            dbg("[SoundTaskManager] cancel idx=", idx, " alarmId=", id)
            SoundTaskManager.cancelAlarmTask(id)
            actionModel.setProperty(idx, "alarmId", 0)
        }
    }

    function cancelAllSoundTaskManagers() {
        for (let i = 0; i < actionModel.count; i++)
            cancelTaskManagerForIndex(i)
    }

    function _hhmmToTodayMs(nowMs, hhmm) {
        if (!hhmm || typeof hhmm !== "string" || hhmm.indexOf(":") < 0) return 0
        const p = hhmm.trim().split(":")
        if (p.length < 2) return 0
        const hh = parseInt(p[0]); const mm = parseInt(p[1])
        if (isNaN(hh) || isNaN(mm)) return 0
        const d = new Date(nowMs)
        d.setHours(hh, mm, 0, 0)
        return d.getTime()
    }


    function scheduleTaskManagerForIndex(idx, nowMs) {
        if (idx < 0 || idx >= actionModel.count) return
        const o = actionModel.get(idx)

        // Falls schon ein Alarm existiert: erst weg damit (sonst doppelt)
        cancelTaskManagerForIndex(idx)

        // disabled / volume=0 => bleibt gecancelt
        const enabled = (o.soundEnabled === undefined) ? true : !!o.soundEnabled
        const baseVol = (typeof o.volume === "number" && !isNaN(o.volume)) ? o.volume : 1.0
        const effectiveVol = (!app.allSoundsDisabled && enabled) ? Math.max(0.0, Math.min(1.0, baseVol)) : 0.0
        if (!enabled || effectiveVol <= 0.0) {
            dbg("[SoundTaskManager] skip schedule (disabled/vol=0) idx=", idx, " enabled=", enabled, " vol=", effectiveVol)
            return
        }

        const rawSound = soundRawForName(o.sound)
        const txt = (typeof o.text === "string" && o.text.length > 0) ? o.text : "Reminder"

        if ((o.mode || "fixed") === "fixed") {
            const fireMs = (typeof o.nextFireMs === "number") ? o.nextFireMs : 0
            if (!fireMs || fireMs <= 0) return

            dbg("[SoundTaskManager] startFixed idx=", idx, " fire=", new Date(fireMs).toISOString(), " vol=", effectiveVol)
            const newId = SoundTaskManager.startFixedSoundTask(rawSound, txt, fireMs, effectiveVol, 0)
            dbg("[SoundTaskManager] startFixed -> id=", newId)
            if (newId > 0) actionModel.setProperty(idx, "alarmId", newId)
            return
        }

        // interval
        const intervalMinutes = (typeof o.intervalMinutes === "number")
                ? o.intervalMinutes
                : parseInt(o.intervalMinutes || 0)
        const intervalSecs = (intervalMinutes > 0) ? intervalMinutes * 60 : 0
        if (intervalSecs <= 0) return

        const startMs = _hhmmToTodayMs(nowMs, o.startTime || "")
        const endMs   = _hhmmToTodayMs(nowMs, o.endTime || "")

        dbg("[SoundTaskManager] startInterval idx=", idx, " startMs=", startMs, " endMs=", endMs, " intervalSecs=", intervalSecs, " vol=", effectiveVol)
        const newId2 = SoundTaskManager.startIntervalSoundTask(rawSound, txt, startMs, endMs, intervalSecs, effectiveVol, 0)
        dbg("[SoundTaskManager] startInterval -> id=", newId2)
        if (newId2 > 0) actionModel.setProperty(idx, "alarmId", newId2)
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

            return true
        } catch (e) {
            console.warn("Load JSON failed:", e)
            return false
        }
    }

    function rescheduleExistingForIndexKeepNextAt(idx) {
        if (idx < 0 || idx >= actionModel.count) return false;

        const o = actionModel.get(idx);
        const id = (typeof o.alarmId === "number") ? o.alarmId : 0;
        if (id <= 0) return false;

        const nextAt = SoundTaskManager.getNextAtMs(id);
        if (!nextAt || nextAt <= 0) return false;   // wichtig

        const enabled = (o.soundEnabled === undefined) ? true : !!o.soundEnabled;
        const baseVol = (typeof o.volume === "number" && !isNaN(o.volume)) ? o.volume : 1.0;
        const effectiveVol = (!app.allSoundsDisabled && enabled)
                ? Math.max(0.0, Math.min(1.0, baseVol))
                : 0.0;   // disable => stumm, aber Timer bleibt

        const rawSound = soundRawForName(o.sound);
        const txt = (typeof o.text === "string" && o.text.length > 0) ? o.text : "Reminder";
        const mode = (o.mode || "fixed");

        if (mode === "fixed") {
            SoundTaskManager.scheduleWithParams(
                nextAt, rawSound, id,
                "DailyActions", txt,
                "fixedTime",
                o.fixedTime || "",
                "", "",
                0,
                effectiveVol
            );
            return true;
        }

        if (mode === "interval") {
            const intervalMinutes = (typeof o.intervalMinutes === "number")
                    ? o.intervalMinutes
                    : parseInt(o.intervalMinutes || 0, 10);
            const intervalSec = (intervalMinutes > 0) ? intervalMinutes * 60 : 0;
            if (intervalSec <= 0) return false;

            SoundTaskManager.scheduleWithParams(
                nextAt, rawSound, id,
                "DailyActions", txt,
                "interval",
                "",
                o.startTime || "",
                o.endTime || "",
                intervalSec,
                effectiveVol
            );
            syncUiFromAndroidNextAtOnStartup()
            return true;
        }

        return false;
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
    }

    function saveNow() {
        Storage.saveState(app.allSoundsDisabled, serializeModel())
    }

    function setRole(idx, role, value) {
        const cur = actionModel.get(idx)[role]
        if (cur === value) return

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
                dbg("[main] sound changed start callLater")
                // 1) Wenn ein Alarm schon läuft: nur Extras updaten, Phase behalten

                if (rescheduleExistingForIndexKeepNextAt(idx)) {
                    dbg("[main] sound changed -> rescheduled keep phase")
                    return
                }

                // 2) Fallback: wenn kein laufender Alarm (oder kein nextAt verfügbar) => normal neu planen
                dbg("[main] sound changed -> fallback full reschedule")
                cancelTaskManagerForIndex(idx)

                const nowMs = Date.now()
                scheduleForIndex(idx, nowMs)

                const o = actionModel.get(idx)
                const enabled = (o.soundEnabled === undefined) ? true : (o.soundEnabled !== false)
                const vol = Number(o.volume) || 0
                if (!enabled || vol <= 0) return

                scheduleTaskManagerForIndex(idx, nowMs)
            })
        }
    }

    function addNewAction() {
        actionModel.append({
            "alarmId": 0,                 // <-- neu: keine Vorab-ID
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
            scheduleForIndex(idx, nowMs)          // UI
            scheduleTaskManagerForIndex(idx, nowMs) // ruft start... und setzt alarmId
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

        // Running-Status aus Android-Alarms ableiten
        app.actionsRunning = app.detectRunningActionsOnStartup()
        dbg("[Main] startup actionsRunning=", actionsRunning)
        if (app.actionsRunning) {
            schedulerInit()
            syncUiFromAndroidNextAtOnStartup()
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
        SoundTaskManager.cancelAll(collectAlarmIds())
        actionsRunning = true

        schedulerInit()

        // UI+Model einmal initial
        const nowMs = Date.now()
        initUiAll(nowMs)

        // echtes Scheduling einmalig
        scheduleAllAlarms(nowMs)

        // optional: explizit einmal tick, falls du es sofort willst
        schedulerStep()
    }

    function initUiAll(nowMs) {
        for (let i = 0; i < actionModel.count; i++)
            scheduleForIndex(i, nowMs) // setzt nextFireMs + countdown
    }

    function scheduleAllAlarms(nowMs) {
        for (let i = 0; i < actionModel.count; i++)
            scheduleTaskManagerForIndex(i, nowMs) // Android alarm scheduling
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

            actionModel.setProperty(i, "AlarmId", 0)
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

        const intervalMs = intervalMinutes * 60 * 1000

        function hhmmToTodayMs(hhmm, baseNowMs) {
            if (!hhmm || typeof hhmm !== "string" || hhmm.indexOf(":") < 0) return 0
            const p = hhmm.trim().split(":")
            if (p.length < 2) return 0
            const hh = parseInt(p[0]); const mm = parseInt(p[1])
            if (isNaN(hh) || isNaN(mm)) return 0
            const d = new Date(baseNowMs)
            d.setHours(hh, mm, 0, 0)
            return d.getTime()
        }

        const startMs0 = hhmmToTodayMs(o.startTime || "", nowMs)
        const endMs0   = hhmmToTodayMs(o.endTime   || "", nowMs)

        const hasStart = startMs0 > 0
        const hasEnd   = endMs0 > 0

        // Fenster heute
        let winStart = startMs0
        let winEnd   = endMs0

        // über Mitternacht: end <= start => end + 24h
        const dayMs = 24 * 60 * 60 * 1000
        if (hasStart && hasEnd && winEnd <= winStart) {
            winEnd += dayMs
        }

        // 1) firstAt: erst nach Intervall
        let nextMs = nowMs + intervalMs

        // 2) auf Zeitfenster schieben
        function inWindow(t, s, e) {
            if (hasStart && hasEnd) return (t >= s && t < e)
            if (hasStart) return (t >= s)
            if (hasEnd)   return (t < e)
            return true
        }

        if (hasStart || hasEnd) {
            if (hasStart && hasEnd) {
                if (!inWindow(nextMs, winStart, winEnd)) {
                    if (nextMs < winStart) {
                        nextMs = winStart
                    } else {
                        // nach Endfenster -> nächstes Fenster (morgen) am Start
                        nextMs = winStart + dayMs
                    }
                }
            } else if (hasStart && !hasEnd) {
                if (nextMs < winStart) nextMs = winStart
            } else if (!hasStart && hasEnd) {
                // nur End: wenn nextMs >= end, dann nicht sinnvoll -> kein next
                if (nextMs >= winEnd) {
                    _clearIntervalCountdown(idx)
                    actionModel.setProperty(idx, "nextFireMs", 0)
                    actionModel.setProperty(idx, "lastFiredMs", 0)
                    return
                }
            }
        }

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

    function syncUiFromAndroidNextAtOnStartup() {
        const nowMs = Date.now()

        for (let i = 0; i < actionModel.count; i++) {
            const o = actionModel.get(i)
            const id = (typeof o.alarmId === "number") ? o.alarmId : 0
            if (id <= 0) continue

            if (!SoundTaskManager.isScheduled(id)) continue

            const nextAt = SoundTaskManager.getNextAtMs(id)
            if (!nextAt || nextAt <= 0) continue

            actionModel.setProperty(i, "nextFireMs", nextAt)

            if ((o.mode || "fixed") === "interval") {
                _setIntervalCountdown(i, nextAt, nowMs)
            } else {
                _setFixedCountdown(i, nextAt, nowMs)
            }
        }
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

                // 1) primär: echte Android-Planung lesen
                const id = (typeof o.alarmId === "number") ? o.alarmId : 0
                let nextMs = 0

                if (id > 0) {
                    nextMs = SoundTaskManager.getNextAtMs(id)   // <<<<<< der Sync-Key
                }

                // 2) Fallback: falls Android nichts liefert (z.B. Desktop oder noch nicht gespeichert)
                if (!nextMs || isNaN(nextMs) || nextMs <= 0) {
                    nextMs = parseInt(o.nextFireMs || 0)
                    if (!nextMs || isNaN(nextMs) || nextMs <= 0) {
                        // “erst nach Intervall”
                        nextMs = nowMs + intervalMinutes * 60 * 1000
                    }
                }

                // 3) UI aktualisieren
                if (nextMs !== parseInt(o.nextFireMs || 0)) {
                    actionModel.setProperty(i, "nextFireMs", nextMs)
                }
                _setIntervalCountdown(i, nextMs, nowMs)

                // WICHTIG: kein lastFired/computeNextIntervalFireMs mehr in der UI!
                // Android reschedult selbst und speichert nextAtMs.
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
                onSoundEdited: function(v) {
                    app.setRole(index, "sound", v)
                }
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
                        //scheduleAllSoundTaskManagers()
                    }
                }
            }
        }
    }
}
