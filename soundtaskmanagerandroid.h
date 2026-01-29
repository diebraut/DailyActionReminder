#pragma once

#include "i_soundtaskmanager.h"

#include <QDateTime>
#include <QHash>
#include <QSet>
#include <QMutex>

class QTimer;

class SoundTaskManagerAndroid : public ISoundTaskManager
{
    Q_OBJECT
public:
    explicit SoundTaskManagerAndroid(QObject *parent = nullptr);

    bool isAndroid() const override { return true; }
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
