#pragma once

#include <QObject>
#include <QString>

class AndroidAlarmBridge : public QObject
{
    Q_OBJECT
public:
    explicit AndroidAlarmBridge(QObject *parent = nullptr);

    Q_INVOKABLE void scheduleWithParams(qint64 triggerAtMs,
                                        const QString &soundName,
                                        int requestId,
                                        const QString &title,
                                        const QString &text,
                                        const QString &mode,
                                        const QString &fixedTime,
                                        const QString &startTime,
                                        const QString &endTime,
                                        int intervalMinutes);

    Q_INVOKABLE void cancel(int requestId);
};
