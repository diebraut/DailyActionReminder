#pragma once

#include <QObject>
#include <QString>

// Small JNI bridge so QML can arm/cancel Android alarms.
// On non-Android platforms all functions are no-ops.
class AndroidBackground : public QObject
{
    Q_OBJECT
public:
    explicit AndroidBackground(QObject *parent = nullptr);

    // Global enable flag (stored in SharedPreferences on Android).
    // The AlarmReceiver checks this flag before (re)scheduling...
    Q_INVOKABLE void setEnabled(bool enabled);

    // Arm one action alarm. The receiver will re-arm itself after it fires.
    // - requestId must be stable for an action while alarms are active.
    // - triggerAtMs is epoch milliseconds (System.currentTimeMillis / Date.now()).
    Q_INVOKABLE void scheduleAction(
        int requestId,
        qint64 triggerAtMs,
        const QString &mode,          // "fixed" or "interval"
        const QString &fixedTime,     // "HH:MM" (used when mode==fixed)
        const QString &startTime,     // "HH:MM" (used when mode==interval)
        const QString &endTime,       // "HH:MM" (used when mode==interval)
        int intervalMinutes,
        bool soundEnabled,
        const QString &soundName,     // e.g. "bell" or "bell.wav"
        float volume01,               // 0..1
        const QString &title,
        const QString &text);

    Q_INVOKABLE void cancelAction(int requestId);

    // Backwards-compatible alias (older QML used AndroidAlarm.cancel(...)).
    Q_INVOKABLE void cancel(int requestId) { cancelAction(requestId); }

    // Convenience: cancel N actions (firstRequestId..firstRequestId+count-1)
    Q_INVOKABLE void cancelActions(int firstRequestId, int count);
};
