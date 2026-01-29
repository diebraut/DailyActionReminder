#include "soundtaskmanagerdesktop.h"
#include <QMutexLocker>

int SoundTaskManagerDesktop::nextId()
{
    QMutexLocker lk(&mtx);
    return m_nextId++;
}

int SoundTaskManagerDesktop::startFixedSoundTask(const QString &rawSound,
                                               const QString &notificationTxt,
                                               qint64 fixedTimeMs,
                                               float volume01,
                                               int soundDurationSec)
{
    const int id = nextId();
    emit logLine(QString("[Dummy] startFixedSoundTask id=%1 sound=%2 text=%3 at=%4 vol=%5 dur=%6")
                     .arg(id).arg(rawSound, notificationTxt)
                     .arg(fixedTimeMs).arg(volume01).arg(soundDurationSec));
    return id;
}

int SoundTaskManagerDesktop::startIntervalSoundTask(const QString &rawSound,
                                                  const QString &notificationTxt,
                                                  qint64 startTimeMs,
                                                  qint64 endTimeMs,
                                                  int intervalSecs,
                                                  float volume01,
                                                  int soundDurationSec)
{
    const int id = nextId();
    emit logLine(QString("[Dummy] startIntervalSoundTask id=%1 sound=%2 text=%3 start=%4 end=%5 every=%6 vol=%7 dur=%8")
                     .arg(id).arg(rawSound, notificationTxt)
                     .arg(startTimeMs).arg(endTimeMs).arg(intervalSecs).arg(volume01).arg(soundDurationSec));
    return id;
}

void SoundTaskManagerDesktop::cancelAlarmTask(int alarmId)
{
    emit logLine(QString("[Dummy] cancelAlarmTask id=%1").arg(alarmId));
}

bool SoundTaskManagerDesktop::schedule(qint64 triggerAtMillis,
                                     const QString &soundName,
                                     int requestId,
                                     const QString &title,
                                     const QString &text,
                                     const QString &mode,
                                     const QString &fixedTime,
                                     const QString &startTime,
                                     const QString &endTime,
                                     int intervalSeconds,
                                     float volume01)
{
    return scheduleWithParams(triggerAtMillis, soundName, requestId, title, text, mode,
                              fixedTime, startTime, endTime, intervalSeconds, volume01);
}

bool SoundTaskManagerDesktop::scheduleWithParams(qint64 triggerAtMillis,
                                               const QString &soundName,
                                               int requestId,
                                               const QString &title,
                                               const QString &text,
                                               const QString &mode,
                                               const QString &fixedTime,
                                               const QString &startTime,
                                               const QString &endTime,
                                               int intervalSeconds,
                                               float volume01)
{
    emit logLine(QString("[Dummy] scheduleWithParams id=%1 at=%2 sound=%3 title=%4 text=%5 mode=%6 fixed=%7 start=%8 end=%9 interval=%10 vol=%11")
                     .arg(requestId).arg(triggerAtMillis).arg(soundName, title, text, mode, fixedTime, startTime, endTime)
                     .arg(intervalSeconds).arg(volume01));
    return true;
}

bool SoundTaskManagerDesktop::cancel(int requestId)
{
    emit logLine(QString("[Dummy] cancel id=%1").arg(requestId));
    return true;
}
