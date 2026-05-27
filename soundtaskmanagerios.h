#pragma once

#include "i_soundtaskmanager.h"

#include <QMutex>

class SoundTaskManagerIos : public ISoundTaskManager
{
    Q_OBJECT
public:
    explicit SoundTaskManagerIos(QObject *parent = nullptr);

    bool isAndroid() const override { return false; }
    void ensure() override;

    int startFixedSoundTask(const QString &rawSound,
                            const QString &notificationTxt,
                            qint64 fixedTimeMs,
                            float volume01,
                            int soundDurationSec) override;

    int startIntervalSoundTask(const QString &rawSound,
                               const QString &notificationTxt,
                               qint64 startTimeMs,
                               qint64 endTimeMs,
                               int intervalSecs,
                               float volume01,
                               int soundDurationSec) override;

    void cancelAlarmTask(int alarmId) override;

    bool scheduleWithParams(qint64 triggerAtMillis,
                            const QString &soundName,
                            int requestId,
                            const QString &title,
                            const QString &text,
                            const QString &mode,
                            const QString &fixedTime,
                            const QString &startTime,
                            const QString &endTime,
                            int intervalSeconds,
                            float volume01,
                            int durationSound) override;

    bool cancel(int requestId) override;
    bool cancelAll(const QList<int> &ids) override;
    bool isScheduled(int alarmId) const override;
    qint64 getNextAtMs(int alarmId) const override;

private:
    int nextId();

    mutable QMutex m_mutex;
    int m_nextId = 900001;
};
