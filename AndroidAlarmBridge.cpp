#include "AndroidAlarmBridge.h"

#include <QDebug>

#ifdef Q_OS_ANDROID
#include <QCoreApplication>
#include <QtCore/qnativeinterface.h>
#include <QJniObject>
#endif

AndroidAlarmBridge::AndroidAlarmBridge(QObject *parent)
    : QObject(parent)
{
}

void AndroidAlarmBridge::scheduleWithParams(qint64 triggerAtMs,
                                            const QString &soundName,
                                            int requestId,
                                            const QString &title,
                                            const QString &text,
                                            const QString &mode,
                                            const QString &fixedTime,
                                            const QString &startTime,
                                            const QString &endTime,
                                            int intervalMinutes)
{
#ifdef Q_OS_ANDROID
    // Qt6: QNativeInterface lives in <QtCore/qnativeinterface.h>
    // isActivityContext() existiert je nach Qt-Version nicht -> weglassen.
    QJniObject ctx = QNativeInterface::QAndroidApplication::context();
    if (!ctx.isValid()) {
        qWarning() << "AndroidAlarmBridge: Android context not valid";
        return;
    }

    QJniObject jsSound = QJniObject::fromString(soundName);
    QJniObject jsTitle = QJniObject::fromString(title);
    QJniObject jsText  = QJniObject::fromString(text);
    QJniObject jsMode  = QJniObject::fromString(mode);
    QJniObject jsFixed = QJniObject::fromString(fixedTime);
    QJniObject jsStart = QJniObject::fromString(startTime);
    QJniObject jsEnd   = QJniObject::fromString(endTime);

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "scheduleWithParams",
        "(Landroid/content/Context;JLjava/lang/String;ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;I)V",
        ctx.object<jobject>(),
        static_cast<jlong>(triggerAtMs),
        jsSound.object<jstring>(),
        static_cast<jint>(requestId),
        jsTitle.object<jstring>(),
        jsText.object<jstring>(),
        jsMode.object<jstring>(),
        jsFixed.object<jstring>(),
        jsStart.object<jstring>(),
        jsEnd.object<jstring>(),
        static_cast<jint>(intervalMinutes)
        );
#else
    Q_UNUSED(triggerAtMs)
    Q_UNUSED(soundName)
    Q_UNUSED(requestId)
    Q_UNUSED(title)
    Q_UNUSED(text)
    Q_UNUSED(mode)
    Q_UNUSED(fixedTime)
    Q_UNUSED(startTime)
    Q_UNUSED(endTime)
    Q_UNUSED(intervalMinutes)
#endif
}

void AndroidAlarmBridge::cancel(int requestId)
{
#ifdef Q_OS_ANDROID
    QJniObject ctx = QNativeInterface::QAndroidApplication::context();
    if (!ctx.isValid()) {
        qWarning() << "AndroidAlarmBridge: Android context not valid";
        return;
    }

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "cancel",
        "(Landroid/content/Context;I)V",
        ctx.object<jobject>(),
        static_cast<jint>(requestId)
        );
#else
    Q_UNUSED(requestId)
#endif
}
