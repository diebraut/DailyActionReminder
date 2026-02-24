#include <QVariant>

#include "soundtaskmanager.h"
#include "soundtaskmanagerfactory.h"

SoundTaskManager::SoundTaskManager(QObject *parent)
    : QObject(parent)
{
    m_impl = SoundTaskManagerFactory::create(this);
    connect(m_impl, &ISoundTaskManager::logLine,
            this,   &SoundTaskManager::logLine);
}

bool SoundTaskManager::isAndroid() const { return m_impl->isAndroid(); }
void SoundTaskManager::ensure() { m_impl->ensure(); }

int SoundTaskManager::startFixedSoundTask(const QString &rawSound,
                                          const QString &notificationTxt,
                                          qint64 fixedTimeMs,
                                          float volume01,
                                          int soundDurationSec)
{
    return m_impl->startFixedSoundTask(rawSound, notificationTxt, fixedTimeMs, volume01, soundDurationSec);
}

int SoundTaskManager::startIntervalSoundTask(const QString &rawSound,
                                             const QString &notificationTxt,
                                             qint64 startTimeMs,
                                             qint64 endTimeMs,
                                             int intervalSecs,
                                             float volume01,
                                             int soundDurationSec)
{
    return m_impl->startIntervalSoundTask(rawSound, notificationTxt, startTimeMs, endTimeMs, intervalSecs, volume01, soundDurationSec);
}

void SoundTaskManager::cancelAlarmTask(int alarmId)
{
    m_impl->cancelAlarmTask(alarmId);
}

bool SoundTaskManager::scheduleWithParams(qint64 triggerAtMillis,
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
                                          int durationSound)
{
    return m_impl->scheduleWithParams(triggerAtMillis, soundName, requestId, title, text, mode,
                                      fixedTime, startTime, endTime, intervalSeconds, volume01,durationSound);
}

bool SoundTaskManager::cancel(int requestId)
{
    return m_impl->cancel(requestId);
}

bool SoundTaskManager::cancelAll(const QVariantList &ids)
{
    if (!m_impl) return false;

    QList<int> list;
    list.reserve(ids.size());
    for (const QVariant &v : ids) {
        bool ok = false;
        int id = v.toInt(&ok);
        if (ok && id > 0) list.push_back(id);
    }
    return m_impl->cancelAll(list);
}

bool SoundTaskManager::isScheduled(int alarmId)
{
    return m_impl->isScheduled(alarmId);
}

qint64 SoundTaskManager::getNextAtMs(int alarmId)
{
    return m_impl->getNextAtMs(alarmId);
}

