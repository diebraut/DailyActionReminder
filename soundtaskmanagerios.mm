#include "soundtaskmanagerios.h"

#include <QDate>
#include <QDateTime>
#include <QFileInfo>
#include <QMetaObject>
#include <QMutexLocker>
#include <QSettings>
#include <QTime>
#include <QUrl>
#include <QtGlobal>

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

namespace {

constexpr int kMaxPendingIntervalNotifications = 60;

QString keyNextAt(int id) { return QStringLiteral("SoundTaskManagerIos/nextAtMs_%1").arg(id); }
QString keyMode(int id) { return QStringLiteral("SoundTaskManagerIos/mode_%1").arg(id); }
QString keyFixedTime(int id) { return QStringLiteral("SoundTaskManagerIos/fixedTime_%1").arg(id); }
QString keyStartTime(int id) { return QStringLiteral("SoundTaskManagerIos/startTime_%1").arg(id); }
QString keyEndTime(int id) { return QStringLiteral("SoundTaskManagerIos/endTime_%1").arg(id); }
QString keyIntervalSeconds(int id) { return QStringLiteral("SoundTaskManagerIos/intervalSeconds_%1").arg(id); }

NSString *toNSString(const QString &value)
{
    return [NSString stringWithUTF8String:value.toUtf8().constData()];
}

QString fromNSString(NSString *value)
{
    return value ? QString::fromUtf8([value UTF8String]) : QString();
}

void postLog(SoundTaskManagerIos *self, const QString &line)
{
    if (!self)
        return;

    QMetaObject::invokeMethod(self, [self, line]() {
        emit self->logLine(line);
    }, Qt::QueuedConnection);
}

QString identifierPrefix(int requestId)
{
    return QStringLiteral("dailyactions.%1").arg(requestId);
}

QString fixedIdentifier(int requestId)
{
    return identifierPrefix(requestId);
}

QString intervalIdentifier(int requestId, int index)
{
    return QStringLiteral("%1.%2").arg(identifierPrefix(requestId)).arg(index);
}

QString normalizeSoundName(QString soundName)
{
    soundName = soundName.trimmed();
    if (soundName.isEmpty())
        return QStringLiteral("bell.wav");

    if (soundName.startsWith(QStringLiteral("qrc:/")))
        soundName = soundName.mid(soundName.lastIndexOf(u'/') + 1);
    else if (soundName.startsWith(QStringLiteral("file:/")))
        soundName = QFileInfo(QUrl(soundName).toLocalFile()).fileName();
    else if (soundName.contains(u'/') || soundName.contains(u'\\'))
        soundName = QFileInfo(soundName).fileName();

    if (!soundName.contains(u'.'))
        soundName += QStringLiteral(".wav");

    return soundName;
}

UNNotificationSound *notificationSound(const QString &soundName)
{
    const QString normalized = normalizeSoundName(soundName);
    NSString *name = toNSString(normalized);
    if ([[NSBundle mainBundle] URLForResource:[name stringByDeletingPathExtension]
                                withExtension:[name pathExtension]]) {
        return [UNNotificationSound soundNamed:name];
    }
    return [UNNotificationSound defaultSound];
}

int parseHHMMToMinutes(const QString &time)
{
    const QString s = time.trimmed();
    const auto parts = s.split(u':');
    if (parts.size() < 2)
        return -1;

    bool okH = false;
    bool okM = false;
    const int h = parts[0].toInt(&okH);
    const int m = parts[1].toInt(&okM);
    if (!okH || !okM || h < 0 || h > 23 || m < 0 || m > 59)
        return -1;

    return h * 60 + m;
}

QDateTime dateAtMinutes(const QDateTime &baseLocal, int minutes)
{
    QDateTime dt(baseLocal.date(), QTime(0, 0), baseLocal.timeZone());
    return dt.addSecs(qint64(qMax(0, minutes)) * 60);
}

qint64 computeNextFixedFireMs(qint64 nowMs, const QString &fixedTime)
{
    const int fixedMin = parseHHMMToMinutes(fixedTime);
    if (fixedMin < 0)
        return qMax(nowMs + 1000, nowMs);

    const QDateTime now = QDateTime::fromMSecsSinceEpoch(nowMs).toLocalTime();
    QDateTime target = dateAtMinutes(now, fixedMin);
    if (now >= target)
        target = target.addDays(1);

    return target.toMSecsSinceEpoch();
}

qint64 computeNextIntervalFireMs(qint64 nowMs,
                                 const QString &startTime,
                                 const QString &endTime,
                                 int intervalSeconds)
{
    if (intervalSeconds <= 0)
        return 0;

    const int startMinRaw = parseHHMMToMinutes(startTime);
    const int endMinRaw = parseHHMMToMinutes(endTime);
    const int startMin = startMinRaw >= 0 ? startMinRaw : 0;
    const int endMin = endMinRaw >= 0 ? endMinRaw : startMin;

    const QDateTime now = QDateTime::fromMSecsSinceEpoch(nowMs).toLocalTime();
    QDateTime start = dateAtMinutes(now, startMin);
    QDateTime end = dateAtMinutes(now, endMin);

    if (endMin == startMin || endMin < startMin)
        end = end.addDays(1);

    if (now < start)
        return start.toMSecsSinceEpoch();

    if (now >= end)
        return start.addDays(1).toMSecsSinceEpoch();

    const qint64 intervalMs = qMax<qint64>(1000, qint64(intervalSeconds) * 1000);
    const qint64 elapsed = now.toMSecsSinceEpoch() - start.toMSecsSinceEpoch();
    const qint64 next = start.toMSecsSinceEpoch() + ((elapsed / intervalMs) + 1) * intervalMs;

    if (next >= end.toMSecsSinceEpoch())
        return start.addDays(1).toMSecsSinceEpoch();

    return next;
}

UNMutableNotificationContent *makeContent(const QString &title,
                                          const QString &text,
                                          const QString &soundName)
{
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = toNSString(title.isEmpty() ? QStringLiteral("DailyActions") : title);
    content.body = toNSString(text);
    content.sound = notificationSound(soundName);
    return content;
}

NSDateComponents *componentsForMs(qint64 ms)
{
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:double(ms) / 1000.0];
    return [[NSCalendar currentCalendar] components:NSCalendarUnitYear |
                                             NSCalendarUnitMonth |
                                             NSCalendarUnitDay |
                                             NSCalendarUnitHour |
                                             NSCalendarUnitMinute |
                                             NSCalendarUnitSecond
                                     fromDate:date];
}

NSDateComponents *dailyComponentsForHHMM(const QString &hhmm)
{
    const int minutes = parseHHMMToMinutes(hhmm);
    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.hour = qMax(0, minutes) / 60;
    components.minute = qMax(0, minutes) % 60;
    components.second = 0;
    return components;
}

bool addRequest(const QString &identifier,
                UNMutableNotificationContent *content,
                UNNotificationTrigger *trigger,
                QString *errorText)
{
    UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:toNSString(identifier)
                                             content:content
                                             trigger:trigger];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *blockError = nil;

    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:^(NSError *error) {
        blockError = error;
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));

    if (blockError) {
        if (errorText)
            *errorText = fromNSString(blockError.localizedDescription);
        return false;
    }

    return true;
}

void removePendingForId(int requestId)
{
    const NSString *prefix = toNSString(identifierPrefix(requestId));
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[UNUserNotificationCenter currentNotificationCenter] getPendingNotificationRequestsWithCompletionHandler:
     ^(NSArray<UNNotificationRequest *> *requests) {
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (UNNotificationRequest *request in requests) {
            if ([request.identifier isEqualToString:(NSString *)prefix] ||
                [request.identifier hasPrefix:[(NSString *)prefix stringByAppendingString:@"."]]) {
                [ids addObject:request.identifier];
            }
        }

        if (ids.count > 0) {
            [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:ids];
        }

        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
}

bool hasPendingForId(int requestId)
{
    const NSString *prefix = toNSString(identifierPrefix(requestId));
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block bool found = false;

    [[UNUserNotificationCenter currentNotificationCenter] getPendingNotificationRequestsWithCompletionHandler:
     ^(NSArray<UNNotificationRequest *> *requests) {
        for (UNNotificationRequest *request in requests) {
            if ([request.identifier isEqualToString:(NSString *)prefix] ||
                [request.identifier hasPrefix:[(NSString *)prefix stringByAppendingString:@"."]]) {
                found = true;
                break;
            }
        }
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
    return found;
}

void clearSettingsForId(int requestId)
{
    QSettings settings;
    settings.remove(keyNextAt(requestId));
    settings.remove(keyMode(requestId));
    settings.remove(keyFixedTime(requestId));
    settings.remove(keyStartTime(requestId));
    settings.remove(keyEndTime(requestId));
    settings.remove(keyIntervalSeconds(requestId));
}

void saveScheduleState(int requestId,
                       qint64 nextAtMs,
                       const QString &mode,
                       const QString &fixedTime,
                       const QString &startTime,
                       const QString &endTime,
                       int intervalSeconds)
{
    QSettings settings;
    settings.setValue(keyNextAt(requestId), nextAtMs);
    settings.setValue(keyMode(requestId), mode);
    settings.setValue(keyFixedTime(requestId), fixedTime);
    settings.setValue(keyStartTime(requestId), startTime);
    settings.setValue(keyEndTime(requestId), endTime);
    settings.setValue(keyIntervalSeconds(requestId), intervalSeconds);
}

} // namespace

SoundTaskManagerIos::SoundTaskManagerIos(QObject *parent)
    : ISoundTaskManager(parent)
{
    QSettings settings;
    m_nextId = settings.value(QStringLiteral("SoundTaskManagerIos/nextId"), m_nextId).toInt();
}

int SoundTaskManagerIos::nextId()
{
    QMutexLocker locker(&m_mutex);
    const int id = m_nextId++;

    QSettings settings;
    settings.setValue(QStringLiteral("SoundTaskManagerIos/nextId"), m_nextId);

    return id;
}

void SoundTaskManagerIos::ensure()
{
    auto *self = this;
    UNAuthorizationOptions options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:options
                                                                        completionHandler:^(BOOL granted, NSError *error) {
        if (error) {
            postLog(self, QStringLiteral("[iOS] notification permission error: %1")
                              .arg(fromNSString(error.localizedDescription)));
            return;
        }

        postLog(self, granted ? QStringLiteral("[iOS] notification permission granted")
                              : QStringLiteral("[iOS] notification permission denied"));
    }];
}

int SoundTaskManagerIos::startFixedSoundTask(const QString &rawSound,
                                             const QString &notificationTxt,
                                             qint64 fixedTimeMs,
                                             float volume01,
                                             int soundDurationSec)
{
    Q_UNUSED(volume01);
    Q_UNUSED(soundDurationSec);

    const int id = nextId();
    const QString fixedTime = QDateTime::fromMSecsSinceEpoch(fixedTimeMs).toLocalTime().time().toString(QStringLiteral("HH:mm"));
    const bool ok = scheduleWithParams(fixedTimeMs,
                                       rawSound,
                                       id,
                                       QStringLiteral("DailyActions"),
                                       notificationTxt,
                                       QStringLiteral("fixedTime"),
                                       fixedTime,
                                       QString(),
                                       QString(),
                                       0,
                                       1.0f,
                                       soundDurationSec);

    return ok ? id : -1;
}

int SoundTaskManagerIos::startIntervalSoundTask(const QString &rawSound,
                                                const QString &notificationTxt,
                                                qint64 startTimeMs,
                                                qint64 endTimeMs,
                                                int intervalSecs,
                                                float volume01,
                                                int soundDurationSec)
{
    Q_UNUSED(volume01);
    Q_UNUSED(soundDurationSec);

    if (intervalSecs <= 0)
        return -1;

    const int id = nextId();
    const QString startTime = QDateTime::fromMSecsSinceEpoch(startTimeMs).toLocalTime().time().toString(QStringLiteral("HH:mm"));
    const QString endTime = QDateTime::fromMSecsSinceEpoch(endTimeMs).toLocalTime().time().toString(QStringLiteral("HH:mm"));
    const qint64 firstAt = computeNextIntervalFireMs(QDateTime::currentMSecsSinceEpoch(),
                                                     startTime,
                                                     endTime,
                                                     intervalSecs);

    const bool ok = scheduleWithParams(firstAt,
                                       rawSound,
                                       id,
                                       QStringLiteral("DailyActions"),
                                       notificationTxt,
                                       QStringLiteral("interval"),
                                       QStringLiteral("00:00"),
                                       startTime,
                                       endTime,
                                       intervalSecs,
                                       1.0f,
                                       soundDurationSec);

    return ok ? id : -1;
}

bool SoundTaskManagerIos::scheduleWithParams(qint64 triggerAtMillis,
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
    Q_UNUSED(volume01);
    Q_UNUSED(durationSound);

    if (requestId <= 0)
        return false;

    removePendingForId(requestId);

    const QString normalizedMode = mode.compare(QStringLiteral("interval"), Qt::CaseInsensitive) == 0
                                       ? QStringLiteral("interval")
                                       : QStringLiteral("fixedTime");
    UNMutableNotificationContent *content = makeContent(title, text, soundName);
    QString errorText;
    bool ok = true;
    qint64 firstAt = triggerAtMillis;

    if (normalizedMode == QStringLiteral("interval")) {
        const int seconds = qMax(1, intervalSeconds);
        firstAt = firstAt > 0 ? firstAt : computeNextIntervalFireMs(QDateTime::currentMSecsSinceEpoch(),
                                                                    startTime,
                                                                    endTime,
                                                                    seconds);

        qint64 at = firstAt;
        for (int i = 0; i < kMaxPendingIntervalNotifications && at > 0; ++i) {
            UNCalendarNotificationTrigger *trigger =
                [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:componentsForMs(at)
                                                                         repeats:NO];
            ok = addRequest(intervalIdentifier(requestId, i), content, trigger, &errorText);
            if (!ok)
                break;

            at = computeNextIntervalFireMs(at + 1, startTime, endTime, seconds);
        }
    } else {
        if (firstAt <= 0)
            firstAt = computeNextFixedFireMs(QDateTime::currentMSecsSinceEpoch(), fixedTime);

        const QString fixedForTrigger = fixedTime.trimmed().isEmpty()
                                            ? QDateTime::fromMSecsSinceEpoch(firstAt).toLocalTime().time().toString(QStringLiteral("HH:mm"))
                                            : fixedTime;
        UNCalendarNotificationTrigger *trigger =
            [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:dailyComponentsForHHMM(fixedForTrigger)
                                                                     repeats:YES];
        ok = addRequest(fixedIdentifier(requestId), content, trigger, &errorText);
        firstAt = computeNextFixedFireMs(QDateTime::currentMSecsSinceEpoch(), fixedForTrigger);
    }

    if (!ok) {
        removePendingForId(requestId);
        emit logLine(QStringLiteral("[iOS] schedule id=%1 failed: %2").arg(requestId).arg(errorText));
        return false;
    }

    saveScheduleState(requestId,
                      firstAt,
                      normalizedMode,
                      fixedTime.trimmed().isEmpty()
                          ? QDateTime::fromMSecsSinceEpoch(firstAt).toLocalTime().time().toString(QStringLiteral("HH:mm"))
                          : fixedTime,
                      startTime,
                      endTime,
                      intervalSeconds);
    emit logLine(QStringLiteral("[iOS] schedule id=%1 mode=%2 first=%3 sound=%4")
                     .arg(requestId)
                     .arg(normalizedMode)
                     .arg(QDateTime::fromMSecsSinceEpoch(firstAt).toLocalTime().toString(Qt::ISODate))
                     .arg(normalizeSoundName(soundName)));
    return true;
}

void SoundTaskManagerIos::cancelAlarmTask(int alarmId)
{
    cancel(alarmId);
}

bool SoundTaskManagerIos::cancel(int requestId)
{
    if (requestId <= 0)
        return false;

    removePendingForId(requestId);
    clearSettingsForId(requestId);
    emit logLine(QStringLiteral("[iOS] cancel id=%1").arg(requestId));
    return true;
}

bool SoundTaskManagerIos::cancelAll(const QList<int> &ids)
{
    for (int id : ids) {
        if (id > 0)
            cancel(id);
    }

    emit logLine(QStringLiteral("[iOS] cancelAll count=%1").arg(ids.size()));
    return true;
}

bool SoundTaskManagerIos::isScheduled(int alarmId) const
{
    if (alarmId <= 0)
        return false;

    return hasPendingForId(alarmId);
}

qint64 SoundTaskManagerIos::getNextAtMs(int alarmId) const
{
    if (alarmId <= 0)
        return 0;

    QSettings settings;
    const qint64 stored = settings.value(keyNextAt(alarmId), 0).toLongLong();
    if (stored <= 0)
        return 0;

    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (stored > now)
        return stored;

    const QString mode = settings.value(keyMode(alarmId)).toString();
    if (mode == QStringLiteral("interval")) {
        return computeNextIntervalFireMs(now,
                                         settings.value(keyStartTime(alarmId)).toString(),
                                         settings.value(keyEndTime(alarmId)).toString(),
                                         settings.value(keyIntervalSeconds(alarmId), 1).toInt());
    }

    return computeNextFixedFireMs(now, settings.value(keyFixedTime(alarmId)).toString());
}
