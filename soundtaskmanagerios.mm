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

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

static NSMutableArray<AVAudioPlayer *> *dailyActionsActivePlayers()
{
    static NSMutableArray<AVAudioPlayer *> *players = [[NSMutableArray alloc] init];
    return players;
}

static void playNotificationSoundFromUserInfo(NSDictionary *userInfo)
{
    NSString *soundName = userInfo[@"soundName"];
    NSNumber *volumeNumber = userInfo[@"volume"];
    if (soundName.length == 0)
        return;

    NSURL *url = [[NSBundle mainBundle] URLForResource:[soundName stringByDeletingPathExtension]
                                         withExtension:[soundName pathExtension]];
    if (!url)
        return;

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    if (!player || error)
        return;

    player.volume = volumeNumber ? qBound(0.0f, volumeNumber.floatValue, 1.0f) : 1.0f;
    [dailyActionsActivePlayers() addObject:player];
    [player play];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [dailyActionsActivePlayers() removeObject:player];
    });
}

@interface DailyActionsNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation DailyActionsNotificationDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    Q_UNUSED(center);

    playNotificationSoundFromUserInfo(notification.request.content.userInfo);

    completionHandler(UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList |
                      UNNotificationPresentationOptionSound);
}

@end

namespace {

constexpr int kMaxPendingIntervalNotifications = 60;

QString keyNextAt(int id) { return QStringLiteral("SoundTaskManagerIos/nextAtMs_%1").arg(id); }
QString keyMode(int id) { return QStringLiteral("SoundTaskManagerIos/mode_%1").arg(id); }
QString keyFixedTime(int id) { return QStringLiteral("SoundTaskManagerIos/fixedTime_%1").arg(id); }
QString keyStartTime(int id) { return QStringLiteral("SoundTaskManagerIos/startTime_%1").arg(id); }
QString keyEndTime(int id) { return QStringLiteral("SoundTaskManagerIos/endTime_%1").arg(id); }
QString keyStartAnchorTime(int id) { return QStringLiteral("SoundTaskManagerIos/startAnchorTime_%1").arg(id); }
QString keyIntervalSeconds(int id) { return QStringLiteral("SoundTaskManagerIos/intervalSeconds_%1").arg(id); }

NSString *toNSString(const QString &value)
{
    return [NSString stringWithUTF8String:value.toUtf8().constData()];
}

QString fromNSString(NSString *value)
{
    return value ? QString::fromUtf8([value UTF8String]) : QString();
}

void postLog(SoundTaskManagerIos *self, const QString &line);

DailyActionsNotificationDelegate *notificationDelegate()
{
    static DailyActionsNotificationDelegate *delegate = [[DailyActionsNotificationDelegate alloc] init];
    return delegate;
}

void configureAudioSession(SoundTaskManagerIos *self)
{
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];

    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error]) {
        postLog(self, QStringLiteral("[iOS] audio session category failed: %1")
                          .arg(fromNSString(error.localizedDescription)));
        return;
    }

    error = nil;
    if (![session setActive:YES error:&error]) {
        postLog(self, QStringLiteral("[iOS] audio session activate failed: %1")
                          .arg(fromNSString(error.localizedDescription)));
        return;
    }

    postLog(self, QStringLiteral("[iOS] audio session ready"));
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

UNNotificationSound *notificationSound(SoundTaskManagerIos *self, const QString &soundName)
{
    const QString normalized = normalizeSoundName(soundName);
    NSString *name = toNSString(normalized);
    if ([[NSBundle mainBundle] URLForResource:[name stringByDeletingPathExtension]
                                withExtension:[name pathExtension]]) {
        return [UNNotificationSound soundNamed:name];
    }
    postLog(self, QStringLiteral("[iOS] notification sound not in bundle, using default: %1").arg(normalized));
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
    if (okH && okM && h == 24 && m == 0)
        return 24 * 60;

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
                                 const QString &startAnchorTime,
                                 qint64 startAnchorMs,
                                 int intervalSeconds)
{
    if (intervalSeconds <= 0)
        return 0;

    const int startMinRaw = parseHHMMToMinutes(startTime);
    const int endMinRaw = parseHHMMToMinutes(endTime);
    const int anchorMinRaw = parseHHMMToMinutes(startAnchorTime);
    const int startMin = startMinRaw >= 0 ? startMinRaw : 0;
    const int endMin = endMinRaw >= 0 ? endMinRaw : 24 * 60;

    const QDateTime now = QDateTime::fromMSecsSinceEpoch(nowMs).toLocalTime();
    const int currentMin = now.time().hour() * 60 + now.time().minute();
    const int anchorMin = anchorMinRaw >= 0
                              ? anchorMinRaw
                              : now.time().hour() * 60 + now.time().minute();
    QDateTime start = dateAtMinutes(now, startMin);
    QDateTime end = dateAtMinutes(now, endMin);
    QDateTime anchor = startAnchorMs > 0
            ? QDateTime::fromMSecsSinceEpoch(startAnchorMs).toLocalTime()
            : dateAtMinutes(now, anchorMin);

    if (endMin == startMin) {
        end = end.addDays(1);
    } else if (endMin < startMin) {
        if (currentMin < endMin) {
            start = start.addDays(-1);
            if (anchorMin >= startMin)
                anchor = anchor.addDays(-1);
        } else {
            end = end.addDays(1);
        }
    }

    if (now >= end) {
        start = start.addDays(1);
        end = end.addDays(1);
    }

    const qint64 intervalMs = qMax<qint64>(1000, qint64(intervalSeconds) * 1000);

    if (anchor > now && anchor >= start && anchor < end) {
        const qint64 firstAfterStart = anchor.toMSecsSinceEpoch() + intervalMs;
        if (firstAfterStart < end.toMSecsSinceEpoch())
            return firstAfterStart;
    }

    const qint64 searchFrom = qMax(now.toMSecsSinceEpoch(), start.toMSecsSinceEpoch());
    qint64 k = (searchFrom - anchor.toMSecsSinceEpoch() + intervalMs - 1) / intervalMs;
    if (k < 0)
        k = 0;
    qint64 next = anchor.toMSecsSinceEpoch() + k * intervalMs;

    if (next < start.toMSecsSinceEpoch()) {
        k = (start.toMSecsSinceEpoch() - anchor.toMSecsSinceEpoch() + intervalMs - 1) / intervalMs;
        next = anchor.toMSecsSinceEpoch() + k * intervalMs;
    }

    if (next >= end.toMSecsSinceEpoch()) {
        start = start.addDays(1);
        k = (start.toMSecsSinceEpoch() - anchor.toMSecsSinceEpoch() + intervalMs - 1) / intervalMs;
        next = anchor.toMSecsSinceEpoch() + k * intervalMs;
    }

    return next;
}

UNMutableNotificationContent *makeContent(const QString &title,
                                          const QString &text,
                                          const QString &soundName,
                                          float volume01,
                                          SoundTaskManagerIos *self)
{
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = toNSString(title.isEmpty() ? QStringLiteral("DailyActions") : title);
    content.body = toNSString(text);
    content.sound = notificationSound(self, soundName);
    const QString normalized = normalizeSoundName(soundName);
    content.userInfo = @{
        @"soundName": toNSString(normalized),
        @"volume": @(qBound(0.0f, volume01, 1.0f))
    };
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

qint64 nextPendingAtForId(int requestId)
{
    const NSString *prefix = toNSString(identifierPrefix(requestId));
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block qint64 bestMs = 0;

    [[UNUserNotificationCenter currentNotificationCenter] getPendingNotificationRequestsWithCompletionHandler:
     ^(NSArray<UNNotificationRequest *> *requests) {
        for (UNNotificationRequest *request in requests) {
            if (![request.identifier isEqualToString:(NSString *)prefix] &&
                ![request.identifier hasPrefix:[(NSString *)prefix stringByAppendingString:@"."]]) {
                continue;
            }

            NSDate *nextDate = nil;
            if ([request.trigger isKindOfClass:[UNCalendarNotificationTrigger class]]) {
                nextDate = [(UNCalendarNotificationTrigger *)request.trigger nextTriggerDate];
            } else if ([request.trigger isKindOfClass:[UNTimeIntervalNotificationTrigger class]]) {
                nextDate = [(UNTimeIntervalNotificationTrigger *)request.trigger nextTriggerDate];
            }
            if (!nextDate)
                continue;

            const qint64 candidateMs = qint64([nextDate timeIntervalSince1970] * 1000.0);
            if (candidateMs <= nowMs)
                continue;

            if (bestMs <= 0 || candidateMs < bestMs)
                bestMs = candidateMs;
        }
        dispatch_semaphore_signal(sem);
    }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
    return bestMs;
}

void clearSettingsForId(int requestId)
{
    QSettings settings;
    settings.remove(keyNextAt(requestId));
    settings.remove(keyMode(requestId));
    settings.remove(keyFixedTime(requestId));
    settings.remove(keyStartTime(requestId));
    settings.remove(keyEndTime(requestId));
    settings.remove(keyStartAnchorTime(requestId));
    settings.remove(keyIntervalSeconds(requestId));
}

void saveScheduleState(int requestId,
                       qint64 nextAtMs,
                       const QString &mode,
                       const QString &fixedTime,
                       const QString &startTime,
                       const QString &endTime,
                       const QString &startAnchorTime,
                       int intervalSeconds)
{
    QSettings settings;
    settings.setValue(keyNextAt(requestId), nextAtMs);
    settings.setValue(keyMode(requestId), mode);
    settings.setValue(keyFixedTime(requestId), fixedTime);
    settings.setValue(keyStartTime(requestId), startTime);
    settings.setValue(keyEndTime(requestId), endTime);
    settings.setValue(keyStartAnchorTime(requestId), startAnchorTime);
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

    dispatch_async(dispatch_get_main_queue(), ^{
        configureAudioSession(self);

        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        center.delegate = notificationDelegate();

        UNAuthorizationOptions options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
        [center requestAuthorizationWithOptions:options
                              completionHandler:^(BOOL granted, NSError *error) {
            if (error) {
                postLog(self, QStringLiteral("[iOS] notification permission error: %1")
                                  .arg(fromNSString(error.localizedDescription)));
                return;
            }

            postLog(self, granted ? QStringLiteral("[iOS] notification permission granted")
                                  : QStringLiteral("[iOS] notification permission denied"));
        }];
    });
}

int SoundTaskManagerIos::startFixedSoundTask(const QString &rawSound,
                                             const QString &notificationTxt,
                                             qint64 fixedTimeMs,
                                             float volume01,
                                             int soundDurationSec)
{
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
                                       QString(),
                                       0,
                                       volume01,
                                       soundDurationSec);

    return ok ? id : -1;
}

int SoundTaskManagerIos::startIntervalSoundTask(const QString &rawSound,
                                                const QString &notificationTxt,
                                                qint64 startTimeMs,
                                                qint64 endTimeMs,
                                                qint64 startAnchorTimeMs,
                                                int intervalSecs,
                                                float volume01,
                                                int soundDurationSec)
{
    Q_UNUSED(soundDurationSec);

    if (intervalSecs <= 0)
        return -1;

    const int id = nextId();
    const QString startTime = QDateTime::fromMSecsSinceEpoch(startTimeMs).toLocalTime().time().toString(QStringLiteral("HH:mm"));
    const QString endTime = QDateTime::fromMSecsSinceEpoch(endTimeMs).toLocalTime().time().toString(QStringLiteral("HH:mm"));
    const QString startAnchorTime = QDateTime::fromMSecsSinceEpoch(startAnchorTimeMs > 0 ? startAnchorTimeMs : QDateTime::currentMSecsSinceEpoch()).toLocalTime().time().toString(QStringLiteral("HH:mm"));
    const qint64 firstAt = computeNextIntervalFireMs(QDateTime::currentMSecsSinceEpoch(),
                                                     startTime,
                                                     endTime,
                                                     startAnchorTime,
                                                     startAnchorTimeMs,
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
                                       startAnchorTime,
                                       intervalSecs,
                                       volume01,
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
                                             const QString &startAnchorTime,
                                             int intervalSeconds,
                                             float volume01,
                                             int durationSound)
{
    Q_UNUSED(durationSound);

    if (requestId <= 0)
        return false;

    removePendingForId(requestId);

    const QString normalizedMode = mode.compare(QStringLiteral("interval"), Qt::CaseInsensitive) == 0
                                       ? QStringLiteral("interval")
                                       : QStringLiteral("fixedTime");
    UNMutableNotificationContent *content = makeContent(title, text, soundName, volume01, this);
    QString errorText;
    bool ok = true;
    qint64 firstAt = triggerAtMillis;
    int scheduledCount = 0;

    if (normalizedMode == QStringLiteral("interval")) {
        const int seconds = qMax(1, intervalSeconds);
        firstAt = firstAt > 0 ? firstAt : computeNextIntervalFireMs(QDateTime::currentMSecsSinceEpoch(),
                                                                    startTime,
                                                                    endTime,
                                                                    startAnchorTime,
                                                                    0,
                                                                    seconds);

        qint64 at = firstAt;
        for (int i = 0; i < kMaxPendingIntervalNotifications && at > 0; ++i) {
            UNCalendarNotificationTrigger *trigger =
                [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:componentsForMs(at)
                                                                         repeats:NO];
            ok = addRequest(intervalIdentifier(requestId, i), content, trigger, &errorText);
            if (!ok)
                break;

            scheduledCount++;
            const qint64 nextAt = computeNextIntervalFireMs(at + 1, startTime, endTime, startAnchorTime, firstAt, seconds);
            if (nextAt <= at)
                break;
            at = nextAt;
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
        scheduledCount = ok ? 1 : 0;
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
                      startAnchorTime,
                      intervalSeconds);
    emit logLine(QStringLiteral("[iOS] schedule id=%1 mode=%2 first=%3 anchor=%4 count=%5 sound=%6")
                     .arg(requestId)
                     .arg(normalizedMode)
                     .arg(QDateTime::fromMSecsSinceEpoch(firstAt).toLocalTime().toString(Qt::ISODate))
                     .arg(startAnchorTime)
                     .arg(scheduledCount)
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
    const qint64 now = QDateTime::currentMSecsSinceEpoch();

    if (stored > now)
        return stored;

    const qint64 pending = nextPendingAtForId(alarmId);
    if (pending > 0) {
        settings.setValue(keyNextAt(alarmId), pending);
        return pending;
    }

    if (stored <= 0)
        return 0;

    const QString mode = settings.value(keyMode(alarmId)).toString();
    if (mode == QStringLiteral("interval")) {
        return computeNextIntervalFireMs(now,
                                         settings.value(keyStartTime(alarmId)).toString(),
                                         settings.value(keyEndTime(alarmId)).toString(),
                                         settings.value(keyStartAnchorTime(alarmId)).toString(),
                                         0,
                                         settings.value(keyIntervalSeconds(alarmId), 1).toInt());
    }

    return computeNextFixedFireMs(now, settings.value(keyFixedTime(alarmId)).toString());
}
