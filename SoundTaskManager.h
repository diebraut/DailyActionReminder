#pragma once

#include <QObject>
#include <QDateTime>
#include <QHash>
#include <QSet>
#include <QMutex>

class QTimer;

/**
 * SoundTaskManager
 * - Vergibt eindeutige Alarm-IDs
 * - Plant Android Alarme über org.dailyactions.AlarmScheduler (JNI)
 * - Kann mehrere parallel laufende Sound-Tasks verwalten (unterschiedliche alarmId)
 *
 * Hinweis:
 * - soundDurationSec ist aktuell nur vorgesehen (noch nicht implementiert).
 * - FixedTasks werden nach Ausführung nicht automatisch vom Java-Code zurückgemeldet.
 *   Deshalb wird die ID bei FixedTasks nach Ablauf von fixedTime (+60s Puffer) automatisch freigegeben,
 *   sofern nicht vorher cancelAlarmTask() aufgerufen wurde.
 */
class SoundTaskManager : public QObject
{
    Q_OBJECT
public:
    explicit SoundTaskManager(QObject *parent = nullptr);

    Q_INVOKABLE bool isAndroid() const;

    // Optional: Notification Permission / Setup
    Q_INVOKABLE void ensure();

    // Neue API (wie gewünscht)
    Q_INVOKABLE int startFixedSoundTask(const QString &rawSound,
                                        const QString &notificationTxt,
                                        qint64 fixedTimeMs,
                                        float volume01,
                                        int soundDurationSec);

    Q_INVOKABLE int startIntervalSoundTask(const QString &rawSound,
                                           const QString &notificationTxt,
                                           qint64 startTimeMs,
                                           qint64 endTimeMs,
                                           int intervalSecs,
                                           float volume01,
                                           int soundDurationSec);

    Q_INVOKABLE void cancelAlarmTask(int alarmId);

    // Backward-Compat für bestehende QML-Calls (ersetzt AndroidAlarmBridge)
    Q_INVOKABLE bool schedule(qint64 triggerAtMillis,
                              const QString &soundName,
                              int requestId,
                              const QString &title,
                              const QString &text,
                              const QString &mode,
                              const QString &fixedTime,
                              const QString &startTime,
                              const QString &endTime,
                              int intervalSeconds,
                              float volume01 = 1.0f);

    Q_INVOKABLE bool scheduleWithParams(qint64 triggerAtMillis,
                                        const QString &soundName,
                                        int requestId,
                                        const QString &title,
                                        const QString &text,
                                        const QString &mode,
                                        const QString &fixedTime,
                                        const QString &startTime,
                                        const QString &endTime,
                                        int intervalSeconds,
                                        float volume01 = 1.0f);

    Q_INVOKABLE bool cancel(int requestId);

signals:
    void logLine(const QString &line);

private:
    int allocId_locked();
    void freeId_locked(int id);

    int allocId();
    void freeId(int id);

    void armAutoFreeFixed(int id, qint64 fixedTimeMs);

private:
    mutable QMutex m_mutex;
    int m_nextId = 777001;
    QSet<int> m_freeIds;
    QSet<int> m_activeIds;
    QSet<int> m_intervalIds;
    QHash<int, QTimer*> m_autoFreeTimers;
};
