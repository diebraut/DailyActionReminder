#include "soundtaskmanagerandroid.h"

#include <QTimer>
#include <QMutexLocker>
#include <QDateTime>
#include <QTime>
#include <limits>
#include <QtGlobal>
#include <algorithm>

#include <android/log.h>
#include <QJniObject>
#include <QJniEnvironment>
#include <cstdarg>

#include <QSettings>

static int parseHHMMToMinutes(const QString &time)
{
    const QString s = time.trimmed();
    const auto parts = s.split(u':');
    if (parts.size() < 2)
        return -1;

    bool okH = false;
    bool okM = false;
    const int h = parts[0].toInt(&okH);
    const int m = parts[1].toInt(&okM);
    if (okH && okM && h == 24 && m == 0)
        return 24 * 60;
    if (!okH || !okM || h < 0 || h > 23 || m < 0 || m > 59)
        return -1;
    return h * 60 + m;
}

static qint64 dateAtMinutes(qint64 nowMs, int minutes)
{
    QDateTime dt = QDateTime::fromMSecsSinceEpoch(nowMs).toLocalTime();
    dt.setTime(QTime(0, 0));
    return dt.addSecs(qint64(qMax(0, minutes)) * 60).toMSecsSinceEpoch();
}

static qint64 computeNextIntervalFireMs(qint64 nowMs,
                                        const QString &startTime,
                                        const QString &endTime,
                                        const QString &startAnchorTime,
                                        qint64 startAnchorMs,
                                        int intervalSeconds)
{
    if (intervalSeconds <= 0)
        return 0;

    const QDateTime now = QDateTime::fromMSecsSinceEpoch(nowMs).toLocalTime();
    const int currentMin = now.time().hour() * 60 + now.time().minute();
    const int startMinRaw = parseHHMMToMinutes(startTime);
    const int endMinRaw = parseHHMMToMinutes(endTime);
    const int anchorMinRaw = parseHHMMToMinutes(startAnchorTime);
    const int startMin = startMinRaw >= 0 ? startMinRaw : 0;
    const int endMin = endMinRaw >= 0 ? endMinRaw : 24 * 60;
    const int anchorMin = anchorMinRaw >= 0
                              ? anchorMinRaw
                              : now.time().hour() * 60 + now.time().minute();

    qint64 start = dateAtMinutes(nowMs, startMin);
    qint64 end = dateAtMinutes(nowMs, endMin);
    qint64 anchor = startAnchorMs > 0 ? startAnchorMs : dateAtMinutes(nowMs, anchorMin);
    const qint64 dayMs = 24LL * 60LL * 60LL * 1000LL;

    if (endMin == startMin) {
        end += dayMs;
    } else if (endMin < startMin) {
        if (currentMin < endMin) {
            start -= dayMs;
            if (anchorMin >= startMin)
                anchor -= dayMs;
        } else {
            end += dayMs;
        }
    }

    if (nowMs >= end) {
        start += dayMs;
        end += dayMs;
    }

    const qint64 intervalMs = qMax<qint64>(1000, qint64(intervalSeconds) * 1000);

    if (anchor > nowMs && anchor >= start && anchor < end) {
        const qint64 firstAfterStart = anchor + intervalMs;
        if (firstAfterStart < end)
            return firstAfterStart;
    }

    const qint64 searchFrom = qMax(nowMs, start);
    qint64 k = (searchFrom - anchor + intervalMs - 1) / intervalMs;
    if (k < 0)
        k = 0;
    qint64 next = anchor + k * intervalMs;

    if (next < start) {
        k = (start - anchor + intervalMs - 1) / intervalMs;
        next = anchor + k * intervalMs;
    }

    if (next >= end) {
        start += dayMs;
        k = (start - anchor + intervalMs - 1) / intervalMs;
        next = anchor + k * intervalMs;
    }

    return qMax(next, nowMs + 1);
}

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

qint64 SoundTaskManagerAndroid::getNextAtMs(int requestId) const
{
    QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        emit logLine("getNextAtMs(): QtNative.activity() invalid");
        return 0;
    }

    const jlong ms = QJniObject::callStaticMethod<jlong>(
        "org/dailyactions/AlarmScheduler",
        "getNextAtMs",
        "(Landroid/content/Context;I)J",
        activity.object<jobject>(),
        (jint)requestId
        );

    const bool ok = clearJniException("getNextAtMs");
    return ok ? (qint64)ms : 0;
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
    const int id = m_nextId++;
    m_activeIds.insert(id);

    QSettings s;
    s.setValue(QStringLiteral("SoundTaskManagerAndroid/nextId"), m_nextId);

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

bool SoundTaskManagerAndroid::scheduleWithParams(qint64 triggerAtMillis,
                                                 const QString &soundName,
                                                 int requestId,
                                                 const QString &title,
                                                 const QString &text,
                                                 const QString &mode,
                                                 const QString &fixedTime,
                                                 const QString &startTime,
                                                 const QString &endTime,
                                                 const QString &startAnchorTime,
                                                 int intervalSeconds,
                                                 float volume01,
                                                 int durationSound)
{
    QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        emit logLine("scheduleWithParams(): QtNative.activity() invalid");
        return false;
    }

    const float v = std::max(0.0f, std::min(1.0f, volume01));

    const char *sig =
        "(Landroid/content/Context;JLjava/lang/String;ILjava/lang/String;Ljava/lang/String;"
        "Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;IFI)V";


    QJniObject jSound = QJniObject::fromString(soundName);
    QJniObject jTitle = QJniObject::fromString(title);
    QJniObject jText  = QJniObject::fromString(text);
    QJniObject jMode  = QJniObject::fromString(mode);
    QJniObject jFixed = QJniObject::fromString(fixedTime);
    QJniObject jStart = QJniObject::fromString(startTime);
    QJniObject jEnd   = QJniObject::fromString(endTime);
    QJniObject jStartAnchor = QJniObject::fromString(startAnchorTime);

    alogW("istScheduled() start id=%d",requestId);
    alogW("SoundTaskManager.scheduleWithParams id=%d at=%lld inMs=%lld mode=%s sound=%s vol=%.2f fixed=%s start=%s end=%s anchor=%s intervalSec=%d durationSound=%d",
          requestId,
          (long long)triggerAtMillis,
          (long long)(triggerAtMillis - QDateTime::currentMSecsSinceEpoch()),
          mode.toUtf8().constData(),
          soundName.toUtf8().constData(),
          v,
          fixedTime.toUtf8().constData(),
          startTime.toUtf8().constData(),
          endTime.toUtf8().constData(),
          startAnchorTime.toUtf8().constData(),
          intervalSeconds,
          durationSound);

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
        jStartAnchor.object<jstring>(),
        (jint)intervalSeconds,
        (jfloat)v,
        (jint) durationSound
        );

    const bool ok = clearJniException("scheduleWithParams");
    emit logLine(ok ? "scheduleWithParams(): OK" : "scheduleWithParams(): EXCEPTION");
    return ok;
}

bool SoundTaskManagerAndroid::cancelAll(const QList<int> &ids)
{
    QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        alogW("cancelAll(): QtNative.activity() invalid");
        return false;
    }

    alogW("cancelAll(): calling AlarmScheduler.cancelAll(ctx, ids) count=%d", ids.size());

    // jintArray bauen
    QJniEnvironment env;
    jintArray jIds = env->NewIntArray(ids.size());
    if (jIds && ids.size() > 0) {
        QVector<jint> tmp;
        tmp.reserve(ids.size());
        for (int id : ids) tmp.push_back((jint)id);
        env->SetIntArrayRegion(jIds, 0, tmp.size(), tmp.constData());
    }

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "cancelAll",
        "(Landroid/content/Context;[I)V",
        activity.object<jobject>(),
        jIds
        );

    if (jIds) env->DeleteLocalRef(jIds);


    const bool ok = clearJniException("cancelAll");

    // C++-seitigen Zustand komplett leeren
    {
        QMutexLocker lk(&m_mutex);

        // Timer stoppen/entsorgen
        for (auto it = m_autoFreeTimers.begin(); it != m_autoFreeTimers.end(); ++it) {
            if (QTimer *t = it.value()) {
                t->stop();
                t->deleteLater();
            }
        }
        m_autoFreeTimers.clear();

        m_activeIds.clear();
        m_intervalIds.clear();
    }

    alogW(ok ? "cancelAll(): OK" : "cancelAll(): EXCEPTION");
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
                                                 int durationSound)
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
        "",
        0,
        volume01,
        durationSound
        );

    if (!ok) {
        freeId(id);
        return -1;
    }
    return id;
}

int SoundTaskManagerAndroid::startIntervalSoundTask(const QString &rawSound,
                                                    const QString &notificationTxt,
                                                    qint64 startTimeMs,
                                                    qint64 endTimeMs,
                                                    qint64 startAnchorTimeMs,
                                                    int intervalSecs,
                                                    float volume01,
                                                    int durationSound)
{
    if (intervalSecs <= 0) return -1;

    // --- Hilfswerte fürs Zeitfenster (nur Zeitanteil zählt) ---
    const bool hasStart = (startTimeMs > 0);
    const bool hasEnd   = (endTimeMs > 0);
    const bool hasAnchor = (startAnchorTimeMs > 0);

    // Zeitstrings (HH:mm) bleiben gleich – Java nutzt die täglich
    const QString startStr = hasStart
                                 ? QDateTime::fromMSecsSinceEpoch(startTimeMs).time().toString("HH:mm")
                                 : QString();
    const QString endStr = hasEnd
                               ? QDateTime::fromMSecsSinceEpoch(endTimeMs).time().toString("HH:mm")
                               : QString();
    const QString startAnchorStr = hasAnchor
                                       ? QDateTime::fromMSecsSinceEpoch(startAnchorTimeMs).time().toString("HH:mm")
                                       : QDateTime::currentDateTime().time().toString("HH:mm");

    const qint64 firstAt = computeNextIntervalFireMs(QDateTime::currentMSecsSinceEpoch(),
                                                     startStr,
                                                     endStr,
                                                     startAnchorStr,
                                                     startAnchorTimeMs,
                                                     intervalSecs);

    // --- ID holen & schedulen ---
    const int id = allocId();

    alogW("startIntervalSoundTask() start id=%d durationSound = %d ",id , durationSound);
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
        startAnchorStr,
        intervalSecs,
        volume01,
        durationSound
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
