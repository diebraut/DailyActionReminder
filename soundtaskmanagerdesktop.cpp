#include "soundtaskmanagerdesktop.h"

#include <QDateTime>
#include <QHash>
#include <QPointer>
#include <QSoundEffect>
#include <QTimer>
#include <QUrl>
#include <QFileInfo>
#include <QMutexLocker>

// ============================================================================
// Desktop implementation
// - Pure Qt (no OS scheduler)
// - Keeps its own timers per requestId
// - Supports two styles:
//   1) startFixedSoundTask / startIntervalSoundTask: convenience wrappers
//   2) scheduleWithParams: used by QML/Android bridge style, supports repeat logic
// ============================================================================

namespace {

QMutex g_schedMtx;
QHash<const SoundTaskManagerDesktop*, QSet<int>> g_sched;

static void markScheduled(const SoundTaskManagerDesktop* self, int id)
{
    if (!self || id <= 0) return;
    QMutexLocker lk(&g_schedMtx);
    g_sched[self].insert(id);
}

static void markCanceled(const SoundTaskManagerDesktop* self, int id)
{
    if (!self || id <= 0) return;
    QMutexLocker lk(&g_schedMtx);
    auto it = g_sched.find(self);
    if (it == g_sched.end()) return;
    it.value().remove(id);
    if (it.value().isEmpty())
        g_sched.erase(it);
}

static bool isMarkedScheduled(const SoundTaskManagerDesktop* self, int id)
{
    if (!self || id <= 0) return false;
    QMutexLocker lk(&g_schedMtx);
    auto it = g_sched.constFind(self);
    if (it == g_sched.constEnd()) return false;
    return it.value().contains(id);
}

struct TaskState {
    // One-shot trigger to start a playback at a specific time
    QPointer<QTimer> oneShot;

    // Repeating interval timer (only for "interval" mode)
    QPointer<QTimer> repeating;

    // Active sound effect (kept alive while playing)
    QPointer<QSoundEffect> sfx;
    // NEU: "nächster geplanter Zeitpunkt" für UI-Sync
    qint64 nextAtMs = 0;

    // Parameters to reschedule after firing (fixed) or to enforce interval window
    QString mode;             // "fixed" or "interval"
    QString fixedTime;        // "HH:MM"
    QString startTime;        // "HH:MM"
    QString endTime;          // "HH:MM"
    int intervalSeconds = 0;  // for interval mode
    float volume01 = 1.0f;

    QString soundName;        // rawSound / url / file
    QString title;
    QString text;
};

static QHash<const SoundTaskManagerDesktop*, QHash<int, TaskState>> g_states;

static qint64 nowMs()
{
    return QDateTime::currentMSecsSinceEpoch();
}

static int parseHHMMToMinutes(const QString &t)
{
    const QString s = t.trimmed();
    const auto parts = s.split(u':');
    if (parts.size() < 2) return 0;

    bool okH=false, okM=false;
    int h = parts[0].toInt(&okH);
    int m = parts[1].toInt(&okM);
    if (!okH) h = 0;
    if (!okM) m = 0;

    h = qBound(0, h, 23);
    m = qBound(0, m, 59);
    return h * 60 + m;
}

static QDateTime dateAtMinutes(const QDateTime &baseLocal, int minutes)
{
    QDate d = baseLocal.date();
    QTime t(0,0,0,0);
    QDateTime dt(d, t, baseLocal.timeZone());
    dt = dt.addSecs(minutes * 60);
    return dt;
}

// Next trigger within interval window [start, end), possibly spanning midnight
// Desktop soll "ab jetzt + interval" laufen (nicht auf HH:MM-Raster runden)
static qint64 computeNextIntervalFireMs(qint64 nowMillis,
                                        const QString &startTime,
                                        const QString &endTime,
                                        int intervalSeconds)
{
    if (intervalSeconds <= 0) return 0;

    const QDateTime now = QDateTime::fromMSecsSinceEpoch(nowMillis).toLocalTime();

    const int startMin = parseHHMMToMinutes(startTime);
    const int endMin   = parseHHMMToMinutes(endTime);

    QDateTime start = dateAtMinutes(now, startMin);
    QDateTime end   = dateAtMinutes(now, endMin);

    // window spans midnight (or same -> treat as span)
    if (endMin == startMin || endMin < startMin)
        end = end.addDays(1);

    // before window -> first fire at window start
    if (now < start)
        return start.toMSecsSinceEpoch();

    // after window -> next day start
    if (now >= end) {
        start = start.addDays(1);
        return start.toMSecsSinceEpoch();
    }

    // inside window -> fire "interval" seconds from NOW (no rounding)
    const qint64 intervalMs = qMax<qint64>(1000, qint64(intervalSeconds) * 1000);
    qint64 next = now.toMSecsSinceEpoch() + intervalMs;

    // if that would leave the window -> next day start
    if (next >= end.toMSecsSinceEpoch()) {
        start = start.addDays(1);
        next = start.toMSecsSinceEpoch();
    }

    return next;
}

static qint64 computeNextFixedFireMs(qint64 nowMillis, const QString &fixedTime)
{
    const QDateTime now = QDateTime::fromMSecsSinceEpoch(nowMillis).toLocalTime();
    const int fixedMin = parseHHMMToMinutes(fixedTime);

    QDateTime target = dateAtMinutes(now, fixedMin);
    if (now >= target)
        target = target.addDays(1);

    return target.toMSecsSinceEpoch();
}

static QUrl toUrl(QString s)
{
    s = s.trimmed();
    if (s.isEmpty()) return {};

    // already looks like a URL
    if (s.startsWith("qrc:/") || s.startsWith("file:/") || s.contains("://"))
        return QUrl(s);

    // bare name like "bell" -> map to qrc:/sounds/bell.wav
    if (!s.contains('/') && !s.contains('\\') && !s.contains('.')) {
        return QUrl("qrc:/sounds/" + s + ".wav");
    }

    // relative or absolute file path
    return QUrl::fromLocalFile(QFileInfo(s).absoluteFilePath());
}

static void stopAndDeleteLater(QObject *obj)
{
    if (!obj) return;
    obj->deleteLater();
}

} // namespace

int SoundTaskManagerDesktop::nextId()
{
    QMutexLocker lk(&mtx);
    return m_nextId++;
}

static TaskState* stateFor(SoundTaskManagerDesktop *self, int requestId)
{
    auto &map = g_states[self];
    return &map[requestId];
}

static void clearState(SoundTaskManagerDesktop *self, int requestId)
{
    auto itOuter = g_states.find(self);
    if (itOuter == g_states.end()) return;

    auto &map = itOuter.value();
    auto it = map.find(requestId);
    if (it == map.end()) return;

    TaskState &st = it.value();
    if (st.oneShot)   stopAndDeleteLater(st.oneShot);
    if (st.repeating) stopAndDeleteLater(st.repeating);
    if (st.sfx)       stopAndDeleteLater(st.sfx);

    map.erase(it);

    if (map.isEmpty())
        g_states.erase(itOuter);
}

static void playOnce(SoundTaskManagerDesktop *self, TaskState &st, int requestId)
{
    auto statusToStr = [](QSoundEffect::Status s) -> const char* {
        switch (s) {
        case QSoundEffect::Null:    return "Null";
        case QSoundEffect::Loading: return "Loading";
        case QSoundEffect::Ready:   return "Ready";
        case QSoundEffect::Error:   return "Error";
        }
        return "<?>"; // should not happen
    };

    // Recreate to avoid stuck state across plays
    if (st.sfx)
        stopAndDeleteLater(st.sfx);

    QSoundEffect *sfx = new QSoundEffect(self);
    st.sfx = sfx;

    const QUrl src = toUrl(st.soundName);

    if (src.isLocalFile()) {
        const QString p = src.toLocalFile();
        self->emit logLine(QString("[Desktop] sfx localFile exists=%1 path=%2")
                               .arg(QFileInfo::exists(p))
                               .arg(p));
    }

    sfx->setSource(src);
    sfx->setLoopCount(1);
    sfx->setVolume(qBound(0.0f, st.volume01, 1.0f));

    self->emit logLine(QString("[Desktop] FIRE id=%1 mode=%2 sound=%3 url=%4 vol=%5 status=%6")
                           .arg(requestId)
                           .arg(st.mode)
                           .arg(st.soundName)
                           .arg(src.toString())
                           .arg(st.volume01)
                           .arg(statusToStr(sfx->status())));

    auto queuedPlay = [self, requestId, sfx, src]() {
        // IMPORTANT: queued/deferred play avoids Qt assert "m_player"
        QTimer::singleShot(0, sfx, [self, requestId, sfx, src]() {
            self->emit logLine(QString("[Desktop] sfx queued play id=%1 url=%2")
                                   .arg(requestId)
                                   .arg(src.toString()));
            sfx->play();
        });
    };

    QObject::connect(sfx, &QSoundEffect::statusChanged, self,
                     [self, requestId, sfx, src, statusToStr, queuedPlay]() {
                         const auto s = sfx->status();
                         self->emit logLine(QString("[Desktop] sfx statusChanged id=%1 url=%2 status=%3")
                                                .arg(requestId)
                                                .arg(src.toString())
                                                .arg(statusToStr(s)));

                         if (s == QSoundEffect::Ready) {
                             self->emit logLine(QString("[Desktop] sfx Ready -> queuedPlay id=%1 url=%2")
                                                    .arg(requestId)
                                                    .arg(src.toString()));
                             queuedPlay();
                         } else if (s == QSoundEffect::Error) {
                             self->emit logLine(QString("[Desktop] sfx ERROR id=%1 url=%2 status=%3")
                                                    .arg(requestId)
                                                    .arg(src.toString())
                                                    .arg(statusToStr(s)));
                         }
                     });

    // If already ready, also play queued (not immediate)
    if (sfx->status() == QSoundEffect::Ready) {
        self->emit logLine(QString("[Desktop] sfx already Ready -> queuedPlay id=%1 url=%2")
                               .arg(requestId)
                               .arg(src.toString()));
        queuedPlay();
    }
}

bool SoundTaskManagerDesktop::isScheduled(int alarmId) const
{
    return isMarkedScheduled(this, alarmId);
}

static void scheduleOneShot(SoundTaskManagerDesktop *self, TaskState &st, int requestId, qint64 triggerAtMillis)
{
    if (st.oneShot) stopAndDeleteLater(st.oneShot);

    st.nextAtMs = triggerAtMillis;   // <<< NEU

    const qint64 delayMs = qMax<qint64>(0, triggerAtMillis - nowMs());

    QTimer *t = new QTimer(self);
    st.oneShot = t;
    t->setSingleShot(true);
    t->setInterval(int(qMin<qint64>(delayMs, std::numeric_limits<int>::max())));

    QObject::connect(t, &QTimer::timeout, self, [self, requestId]() {
        auto itOuter = g_states.find(self);
        if (itOuter == g_states.end()) return;
        auto it = itOuter.value().find(requestId);
        if (it == itOuter.value().end()) return;

        TaskState &st = it.value();
        playOnce(self, st, requestId);

        // Reschedule depending on mode
        if (st.mode == "fixed") {
            const qint64 next = computeNextFixedFireMs(nowMs(), st.fixedTime);
            scheduleOneShot(self, st, requestId, next);
        } else { // "interval"
            const qint64 next = computeNextIntervalFireMs(nowMs(), st.startTime, st.endTime, st.intervalSeconds);
            scheduleOneShot(self, st, requestId, next);
        }
    });

    t->start();

    self->emit logLine(QString("[Desktop] schedule oneShot id=%1 in=%2ms at=%3 mode=%4")
                           .arg(requestId)
                           .arg(delayMs)
                           .arg(QDateTime::fromMSecsSinceEpoch(triggerAtMillis).toLocalTime().toString(Qt::ISODate))
                           .arg(st.mode));
}

int SoundTaskManagerDesktop::startFixedSoundTask(const QString &rawSound,
                                                 const QString &notificationTxt,
                                                 qint64 fixedTimeMs,
                                                 float volume01,
                                                 int soundDurationSec)
{
    Q_UNUSED(soundDurationSec);

    const int id = nextId();

    // Minimal mapping: fixedTimeMs is treated as the next absolute fire time.
    // We don't know the HH:MM string here, so we just reschedule by +24h.
    auto *st = stateFor(this, id);
    st->mode = "fixed";
    st->soundName = rawSound;
    st->title = notificationTxt;
    st->text = "";
    st->volume01 = volume01;
    st->fixedTime = QDateTime::fromMSecsSinceEpoch(fixedTimeMs).toLocalTime().time().toString("HH:mm");

    scheduleOneShot(this, *st, id, fixedTimeMs);

    emit logLine(QString("[Desktop] startFixedSoundTask id=%1 at=%2 sound=%3 text=%4")
                     .arg(id)
                     .arg(QDateTime::fromMSecsSinceEpoch(fixedTimeMs).toLocalTime().toString(Qt::ISODate))
                     .arg(rawSound, notificationTxt));

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
    Q_UNUSED(soundDurationSec);

    const int id = nextId();

    auto *st = stateFor(this, id);
    st->mode = "interval";
    st->soundName = rawSound;
    st->title = notificationTxt;
    st->text = "";
    st->volume01 = volume01;

    const QDateTime stDt = QDateTime::fromMSecsSinceEpoch(startTimeMs).toLocalTime();
    const QDateTime enDt = QDateTime::fromMSecsSinceEpoch(endTimeMs).toLocalTime();
    st->startTime = stDt.time().toString("HH:mm");
    st->endTime   = enDt.time().toString("HH:mm");
    st->intervalSeconds = intervalSecs;

    // Next trigger is computed against start/end strings + interval
    const qint64 next = computeNextIntervalFireMs(nowMs(), st->startTime, st->endTime, intervalSecs);
    scheduleOneShot(this, *st, id, next);

    // Repeating timer: once in-window, fires every intervalSecs; outside window it idles until next window
    QTimer *rep = new QTimer(this);
    st->repeating = rep;
    rep->setSingleShot(false);
    rep->setInterval(qMax(1, intervalSecs) * 1000);

    QObject::connect(rep, &QTimer::timeout, this, [this, id]() {
        auto itOuter = g_states.find(this);
        if (itOuter == g_states.end()) return;
        auto it = itOuter.value().find(id);
        if (it == itOuter.value().end()) return;

        TaskState &st = it.value();

        const qint64 n = nowMs();
        const qint64 next = computeNextIntervalFireMs(n, st.startTime, st.endTime, st.intervalSeconds);
        // We only play if we are "on or after" the computed next tick.
        if (next <= n + 50) // small tolerance
            playOnce(this, st, id);
        else
            scheduleOneShot(this, st, id, next);
    });

    rep->start();

    emit logLine(QString("[Desktop] startIntervalSoundTask id=%1 start=%2 end=%3 every=%4s sound=%5 text=%6")
                     .arg(id)
                     .arg(st->startTime, st->endTime)
                     .arg(intervalSecs)
                     .arg(rawSound, notificationTxt));

    return id;
}


void SoundTaskManagerDesktop::cancelAlarmTask(int alarmId)
{
    clearState(this, alarmId);
    emit logLine(QString("[Desktop] cancelAlarmTask id=%1").arg(alarmId));
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
    // Replace any existing task for this requestId
    clearState(this, requestId);

    auto *st = stateFor(this, requestId);
    st->mode = (mode == "interval") ? "interval" : "fixed";
    st->soundName = soundName;
    st->title = title;
    st->text = text;
    st->fixedTime = fixedTime;
    st->startTime = startTime;
    st->endTime = endTime;
    st->intervalSeconds = qMax(1, intervalSeconds); // scheduleWithParams expects seconds
    st->volume01 = volume01;

    if (st->mode == "interval") {
        //const qint64 next = computeNextIntervalFireMs(nowMs(), startTime, endTime, qMax(1, intervalSeconds));
        scheduleOneShot(this, *st, requestId, triggerAtMillis);
        Q_INVOKABLE bool cancel(int requestId);

        // repeating timer for in-window ticks
        QTimer *rep = new QTimer(this);
        st->repeating = rep;
        rep->setSingleShot(false);
        rep->setInterval(qMax(1, intervalSeconds) * 1000); // seconds -> ms

        QObject::connect(rep, &QTimer::timeout, this, [this, requestId]() {
            auto itOuter = g_states.find(this);
            if (itOuter == g_states.end()) return;
            auto it = itOuter.value().find(requestId);
            if (it == itOuter.value().end()) return;

            TaskState &st = it.value();
            const qint64 n = nowMs();
            const qint64 next = computeNextIntervalFireMs(n, st.startTime, st.endTime, qMax(1, st.intervalSeconds));
            if (next <= n + 50)
                playOnce(this, st, requestId);
            else
                scheduleOneShot(this, st, requestId, next);
        });

        rep->start();

        emit logLine(QString("[Desktop] scheduleWithParams interval id=%1 start=%2 end=%3 every=%4s sound=%5")
                         .arg(requestId).arg(startTime, endTime).arg(intervalSeconds).arg(soundName));

        return true;
    }

    // fixed
    qint64 first = triggerAtMillis;
    if (first <= 0)
        first = computeNextFixedFireMs(nowMs(), fixedTime);

    scheduleOneShot(this, *st, requestId, first);

    emit logLine(QString("[Desktop] scheduleWithParams fixed id=%1 fixed=%2 first=%3 sound=%4")
                     .arg(requestId)
                     .arg(fixedTime)
                     .arg(QDateTime::fromMSecsSinceEpoch(first).toLocalTime().toString(Qt::ISODate))
                     .arg(soundName));

    return true;
}

bool SoundTaskManagerDesktop::cancel(int requestId)
{
    clearState(this, requestId);
    emit logLine(QString("[Desktop] cancel id=%1").arg(requestId));
    return true;
}

bool SoundTaskManagerDesktop::cancelAll(const QList<int> &ids)
{
    int count = 0;
    for (int id : ids) {
        if (id <= 0) continue;
        clearState(this, id);
        count++;
    }
    emit logLine(QString("[Desktop] cancelAll count=%1").arg(count));
    return true;
}

qint64 SoundTaskManagerDesktop::getNextAtMs(int alarmId) const
{
    if (alarmId <= 0) return 0;

    auto itOuter = g_states.constFind(this);
    if (itOuter == g_states.constEnd()) return 0;

    auto it = itOuter.value().constFind(alarmId);
    if (it == itOuter.value().constEnd()) return 0;

    return it.value().nextAtMs;
}

