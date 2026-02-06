#include "soundtaskmanagerandroid.h"

#include <QTimer>
#include <QMutexLocker>
#include <limits>
#include <QtGlobal>
#include <algorithm>

#include <android/log.h>
#include <QJniObject>
#include <QJniEnvironment>
#include <cstdarg>


static QJniObject getQtActivity()
{
    return QJniObject::callStaticObjectMethod(
        "org/qtproject/qt/android/QtNative",
        "activity",
        "()Landroid/app/Activity;"
        );
}

static bool clearJniException(const char *where)
{
    QJniEnvironment env;
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        return false;
    }
    return true;
}

SoundTaskManagerAndroid::SoundTaskManagerAndroid(QObject *parent)
    : ISoundTaskManager(parent) {}

void SoundTaskManagerAndroid::alogW(const char* fmt, ...)
{
    if (!fmt) return;

    char buf[2048];

    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    // direkt über deine Instanz
    logInst->w(QString::fromUtf8(buf));
}

void SoundTaskManagerAndroid::ensure()
{
    QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        emit logLine("ensure(): QtNative.activity() invalid");
        return;
    }

    alogW("JNI: calling AlarmScheduler.ensureNotificationPermission(Activity)");

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "ensureNotificationPermission",
        "(Landroid/app/Activity;)V",
        activity.object<jobject>()
        );

    const bool ok = clearJniException("ensureNotificationPermission");
    emit logLine(ok ? "ensure(): OK" : "ensure(): EXCEPTION");
}

// -------------------- ID management --------------------

int SoundTaskManagerAndroid::allocId_locked()
{
    if (!m_freeIds.isEmpty()) {
        auto it = m_freeIds.begin();
        const int id = *it;
        m_freeIds.erase(it);
        m_activeIds.insert(id);
        return id;
    }
    const int id = m_nextId++;
    m_activeIds.insert(id);
    return id;
}

void SoundTaskManagerAndroid::freeId_locked(int id)
{
    if (id <= 0) return;

    m_activeIds.remove(id);
    m_intervalIds.remove(id);

    if (auto it = m_autoFreeTimers.find(id); it != m_autoFreeTimers.end()) {
        QTimer *t = it.value();
        m_autoFreeTimers.erase(it);
        if (t) {
            t->stop();
            t->deleteLater();
        }
    }

    m_freeIds.insert(id);
}

int SoundTaskManagerAndroid::allocId()
{
    QMutexLocker lk(&m_mutex);
    return allocId_locked();
}

void SoundTaskManagerAndroid::freeId(int id)
{
    QMutexLocker lk(&m_mutex);
    freeId_locked(id);
}

void SoundTaskManagerAndroid::armAutoFreeFixed(int id, qint64 fixedTimeMs)
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    qint64 delayMs = fixedTimeMs - now;
    if (delayMs < 0) delayMs = 0;
    delayMs += 60000;

    QTimer *t = new QTimer(this);
    t->setSingleShot(true);

    {
        QMutexLocker lk(&m_mutex);
        if (auto it = m_autoFreeTimers.find(id); it != m_autoFreeTimers.end()) {
            if (it.value()) {
                it.value()->stop();
                it.value()->deleteLater();
            }
            m_autoFreeTimers.erase(it);
        }
        m_autoFreeTimers.insert(id, t);
    }

    connect(t, &QTimer::timeout, this, [this, id]() {
        freeId(id);
        emit logLine(QString("autoFreeFixed(): freed id=%1").arg(id));
    });

    t->start(static_cast<int>(std::min<qint64>(delayMs, std::numeric_limits<int>::max())));
}

// -------------------- Scheduling wrappers --------------------

bool SoundTaskManagerAndroid::schedule(qint64 triggerAtMillis,
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
    return scheduleWithParams(triggerAtMillis, soundName, requestId, title, text,
                              mode, fixedTime, startTime, endTime, intervalSeconds, volume01);
}

bool SoundTaskManagerAndroid::scheduleWithParams(qint64 triggerAtMillis,
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
    QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        emit logLine("scheduleWithParams(): QtNative.activity() invalid");
        return false;
    }

    const float v = std::max(0.0f, std::min(1.0f, volume01));

    const char *sig =
        "(Landroid/content/Context;JLjava/lang/String;ILjava/lang/String;Ljava/lang/String;"
        "Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;IF)V";

    QJniObject jSound = QJniObject::fromString(soundName);
    QJniObject jTitle = QJniObject::fromString(title);
    QJniObject jText  = QJniObject::fromString(text);
    QJniObject jMode  = QJniObject::fromString(mode);
    QJniObject jFixed = QJniObject::fromString(fixedTime);
    QJniObject jStart = QJniObject::fromString(startTime);
    QJniObject jEnd   = QJniObject::fromString(endTime);

    alogW("istScheduled() start id=%1",requestId);
    alogW("SoundTaskManager.scheduleWithParams id=%d at=%lld inMs=%lld mode=%s sound=%s vol=%.2f fixed=%s start=%s end=%s intervalSec=%d",
          requestId,
          (long long)triggerAtMillis,
          (long long)(triggerAtMillis - QDateTime::currentMSecsSinceEpoch()),
          mode.toUtf8().constData(),
          soundName.toUtf8().constData(),
          v,
          fixedTime.toUtf8().constData(),
          startTime.toUtf8().constData(),
          endTime.toUtf8().constData(),
          intervalSeconds);

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "scheduleWithParams",
        sig,
        activity.object<jobject>(),
        (jlong)triggerAtMillis,
        jSound.object<jstring>(),
        (jint)requestId,
        jTitle.object<jstring>(),
        jText.object<jstring>(),
        jMode.object<jstring>(),
        jFixed.object<jstring>(),
        jStart.object<jstring>(),
        jEnd.object<jstring>(),
        (jint)intervalSeconds,
        (jfloat)v
        );

    const bool ok = clearJniException("scheduleWithParams");
    emit logLine(ok ? "scheduleWithParams(): OK" : "scheduleWithParams(): EXCEPTION");
    return ok;
}

bool SoundTaskManagerAndroid::cancel(int requestId)
{
    alogW("start cancel reqId=%d",requestId);
    QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        alogW("cancel(): QtNative.activity() invalid");
        return false;
    }

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "cancel",
        "(Landroid/content/Context;I)V",
        activity.object<jobject>(),
        (jint)requestId
        );

    const bool ok = clearJniException("cancel");
    alogW(ok ? "cancel(): OK" : "cancel(): EXCEPTION");
    return ok;
}

// -------------------- New API --------------------

int SoundTaskManagerAndroid::startFixedSoundTask(const QString &rawSound,
                                                 const QString &notificationTxt,
                                                 qint64 fixedTimeMs,
                                                 float volume01,
                                                 int /*soundDurationSec*/)
{
    const int id = allocId();

    const QDateTime dt = QDateTime::fromMSecsSinceEpoch(fixedTimeMs);
    const QString fixedStr = dt.time().toString("HH:mm");

    const bool ok = scheduleWithParams(
        fixedTimeMs,
        rawSound,
        id,
        "DailyActions",
        notificationTxt,
        "fixedTime",
        fixedStr,
        "",
        "",
        0,
        volume01
        );

    if (!ok) {
        freeId(id);
        return -1;
    }

    armAutoFreeFixed(id, fixedTimeMs);
    return id;
}

int SoundTaskManagerAndroid::startIntervalSoundTask(const QString &rawSound,
                                                    const QString &notificationTxt,
                                                    qint64 startTimeMs,
                                                    qint64 endTimeMs,
                                                    int intervalSecs,
                                                    float volume01,
                                                    int /*soundDurationSec*/)
{
    if (intervalSecs <= 0) return -1;

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    qint64 firstAt = startTimeMs > 0 ? startTimeMs : (now + 250);
    if (firstAt < now + 250) firstAt = now + 250;

    if (endTimeMs > 0 && firstAt >= endTimeMs) {
        return -1;
    }

    const int id = allocId();

    const QString startStr = (startTimeMs > 0)
                                 ? QDateTime::fromMSecsSinceEpoch(startTimeMs).time().toString("HH:mm")
                                 : "";
    const QString endStr = (endTimeMs > 0)
                               ? QDateTime::fromMSecsSinceEpoch(endTimeMs).time().toString("HH:mm")
                               : "";

    const bool ok = scheduleWithParams(
        firstAt,
        rawSound,
        id,
        "DailyActions",
        notificationTxt,
        "interval",
        "00:00",
        startStr,
        endStr,
        intervalSecs,
        volume01
        );

    if (!ok) {
        freeId(id);
        return -1;
    }

    {
        QMutexLocker lk(&m_mutex);
        m_intervalIds.insert(id);
    }

    return id;
}

void SoundTaskManagerAndroid::cancelAlarmTask(int alarmId)
{
    if (alarmId <= 0) return;
    cancel(alarmId);
    freeId(alarmId);
}


bool SoundTaskManagerAndroid::isScheduled(int requestId) const
{
   logInst->w(QString("istScheduled() start id=%1").arg(requestId));
   QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        emit logLine("isScheduled(): QtNative.activity() invalid");
        return false;
    }

    const jboolean jb = QJniObject::callStaticMethod<jboolean>(
        "org/dailyactions/AlarmScheduler",
        "isScheduled",
        "(Landroid/content/Context;I)Z",
        activity.object<jobject>(),
        (jint)requestId
        );

    const bool ok = clearJniException("isScheduled");
    const bool scheduled = ok ? (jb == JNI_TRUE) : false;
    emit logLine(QString("isScheduled(%1): %2").arg(requestId).arg(scheduled ? "true" : "false"));
    return scheduled;
}

