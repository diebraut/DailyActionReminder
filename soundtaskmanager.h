#pragma once

#include <QObject>
#include "i_soundtaskmanager.h"

class SoundTaskManager : public QObject
{
    Q_OBJECT
public:
    explicit SoundTaskManager(QObject *parent = nullptr);

    Q_INVOKABLE bool isAndroid() const;
    Q_INVOKABLE void ensure();

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
    ISoundTaskManager *m_impl = nullptr; // gehört diesem QObject (parented)
};
