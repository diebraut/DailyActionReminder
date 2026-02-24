#pragma once
#include <QObject>
#include <QString>

class ISoundTaskManager : public QObject {
    Q_OBJECT
public:
    explicit ISoundTaskManager(QObject *parent=nullptr) : QObject(parent) {}
    ~ISoundTaskManager() override = default;

    // gleiche API wie bisher (damit QML/Call-Sites stabil bleiben)
    virtual bool isAndroid() const = 0;
    virtual void ensure() = 0;

    virtual int startFixedSoundTask(const QString &rawSound,
                                    const QString &notificationTxt,
                                    qint64 fixedTimeMs,
                                    float volume01,
                                    int soundDurationSec) = 0;

    virtual int startIntervalSoundTask(const QString &rawSound,
                                       const QString &notificationTxt,
                                       qint64 startTimeMs,
                                       qint64 endTimeMs,
                                       int intervalSecs,
                                       float volume01,
                                       int soundDurationSec) = 0;

    virtual void cancelAlarmTask(int alarmId) = 0;

    virtual bool scheduleWithParams(qint64 triggerAtMillis,
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
                                    int durationSound) = 0;

    virtual bool cancel(int requestId) = 0;
    virtual bool cancelAll(const QList<int> &ids) = 0;
    virtual bool isScheduled(int alarmId) const = 0;
    virtual qint64 getNextAtMs(int alarmId) const = 0;


signals:
    void logLine(const QString &line) const ;
};
