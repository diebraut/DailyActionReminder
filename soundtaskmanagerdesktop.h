#pragma once

#include "i_soundtaskmanager.h"
#include <QMutex>

class SoundTaskManagerDesktop : public ISoundTaskManager
{
    Q_OBJECT
public:
    explicit SoundTaskManagerDesktop(QObject *parent = nullptr)
        : ISoundTaskManager(parent) {}

    bool isAndroid() const override { return false; }
    void ensure() override { emit logLine("ensure(): dummy"); }

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

    bool schedule(qint64 triggerAtMillis,
                  const QString &soundName,
                  int requestId,
                  const QString &title,
                  const QString &text,
                  const QString &mode,
                  const QString &fixedTime,
                  const QString &startTime,
                  const QString &endTime,
                  int intervalSeconds,
                  float volume01) override;

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
                            float volume01) override;

    bool cancel(int requestId) override;

private:
    int nextId();

    QMutex mtx;
    int m_nextId = 1001;
};
