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

#include <QSettings>

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

    alogW("istScheduled() start id=%d",requestId);
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
    const qint64 intervalMs = (qint64)intervalSecs * 1000;

    // --- Hilfswerte fürs Zeitfenster (nur Zeitanteil zählt) ---
    const bool hasStart = (startTimeMs > 0);
    const bool hasEnd   = (endTimeMs > 0);

    // Zeitstrings (HH:mm) bleiben gleich – Java nutzt die täglich
    const QString startStr = hasStart
                                 ? QDateTime::fromMSecsSinceEpoch(startTimeMs).time().toString("HH:mm")
                                 : QString();
    const QString endStr = hasEnd
                               ? QDateTime::fromMSecsSinceEpoch(endTimeMs).time().toString("HH:mm")
                               : QString();

    // heute: start/end als Ms (wenn vorhanden)
    qint64 winStart = startTimeMs;
    qint64 winEnd   = endTimeMs;

    // Fenster kann über Mitternacht gehen (end <= start) => end + 24h
    if (hasStart && hasEnd && winEnd <= winStart) {
        winEnd += 24LL * 60LL * 60LL * 1000LL;
    }

    // --- 1) erster Termin: erst nach Intervall ---
    qint64 firstAt = now + intervalMs;

    // --- 2) auf Zeitfenster abbilden (heute/ggf. morgen) ---
    if (hasStart || hasEnd) {
        // Wenn wir ein über-Mitternacht-Fenster haben und now liegt nach Mitternacht (z.B. 01:00),
        // dann muss winStart ggf. "gestern" sein. Einfacher: wir betrachten zwei Fenster:
        // [winStart, winEnd] (heute) und [winStart+24h, winEnd+24h] (morgen)
        // und suchen den ersten firstAt, der in einem Fenster liegt bzw. auf start geschoben werden kann.

        auto inWindow = [](qint64 t, qint64 s, qint64 e, bool hasS, bool hasE) -> bool {
            if (hasS && hasE) return (t >= s && t < e);
            if (hasS)         return (t >= s);
            if (hasE)         return (t < e);
            return true;
        };

        auto adjustToWindow = [&](qint64 t, qint64 s, qint64 e, bool hasS, bool hasE) -> qint64 {
            // Wenn vor Start => auf Start schieben
            if (hasS && t < s) return s;
            // Wenn nach/gleich End => "nicht ok", Caller entscheidet (morgen)
            return t;
        };

        // Fenster heute
        qint64 s0 = winStart;
        qint64 e0 = winEnd;

        // Wenn winStart/winEnd als "heute" gegeben sind, aber now ist bereits weit danach,
        // kann firstAt außerhalb liegen. Dann prüfen wir heute, sonst morgen.
        if (hasStart && hasEnd) {
            if (!inWindow(firstAt, s0, e0, true, true)) {
                firstAt = adjustToWindow(firstAt, s0, e0, true, true);
                if (firstAt >= e0) {
                    // auf morgen verschieben
                    const qint64 s1 = s0 + 24LL * 60LL * 60LL * 1000LL;
                    const qint64 e1 = e0 + 24LL * 60LL * 60LL * 1000LL;
                    firstAt = s1; // frühester Zeitpunkt im nächsten Fenster
                    // (firstAt ist dann automatisch >= now+interval? nicht zwingend, aber das ist ok,
                    //  weil wir "erst nach Intervall" bereits erfüllt haben: s1 liegt in der Zukunft)
                    Q_UNUSED(e1);
                }
            }
        } else if (hasStart && !hasEnd) {
            // nur Start: frühestens Start, aber erst nach Intervall
            if (firstAt < s0) firstAt = s0;
        } else if (!hasStart && hasEnd) {
            // nur End: bis End, falls firstAt >= end => morgen ist nicht definierbar -> abbrechen
            if (firstAt >= e0) return -1;
        }
    }

    // Sicherheitscheck: firstAt muss in der Zukunft liegen
    if (firstAt < now + 1) firstAt = now + 1;

    // --- ID holen & schedulen ---
    const int id = allocId();

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

