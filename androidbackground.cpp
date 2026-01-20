#include "AndroidBackground.h"

#ifdef Q_OS_ANDROID
#include <QCoreApplication>
#include <QtCore/qnativeinterface.h>
#include <QJniObject>
#endif

AndroidBackground::AndroidBackground(QObject *parent) : QObject(parent) {}

void AndroidBackground::setEnabled(bool enabled)
{
#ifdef Q_OS_ANDROID
    if (!QNativeInterface::QAndroidApplication::isActivityContext())
        return;

    QJniObject ctx = QNativeInterface::QAndroidApplication::context();
    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "setEnabled",
        "(Landroid/content/Context;Z)V",
        ctx.object<jobject>(),
        (jboolean)enabled);
#else
    Q_UNUSED(enabled);
#endif
}

void AndroidBackground::scheduleAction(
    int requestId,
    qint64 triggerAtMs,
    const QString &mode,
    const QString &fixedTime,
    const QString &startTime,
    const QString &endTime,
    int intervalMinutes,
    bool soundEnabled,
    const QString &soundName,
    float volume01,
    const QString &title,
    const QString &text)
{
#ifdef Q_OS_ANDROID
    if (!QNativeInterface::QAndroidApplication::isActivityContext())
        return;

    QJniObject ctx = QNativeInterface::QAndroidApplication::context();

    QJniObject jMode = QJniObject::fromString(mode);
    QJniObject jFixed = QJniObject::fromString(fixedTime);
    QJniObject jStart = QJniObject::fromString(startTime);
    QJniObject jEnd = QJniObject::fromString(endTime);
    QJniObject jSound = QJniObject::fromString(soundName);
    QJniObject jTitle = QJniObject::fromString(title);
    QJniObject jText = QJniObject::fromString(text);

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "scheduleAction",
        "(Landroid/content/Context;JILjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;IZLjava/lang/String;FLjava/lang/String;Ljava/lang/String;)V",
        ctx.object<jobject>(),
        (jlong)triggerAtMs,
        (jint)requestId,
        jMode.object<jstring>(),
        jFixed.object<jstring>(),
        jStart.object<jstring>(),
        jEnd.object<jstring>(),
        (jint)intervalMinutes,
        (jboolean)soundEnabled,
        jSound.object<jstring>(),
        (jfloat)volume01,
        jTitle.object<jstring>(),
        jText.object<jstring>()
        );
#else
    Q_UNUSED(requestId); Q_UNUSED(triggerAtMs); Q_UNUSED(mode); Q_UNUSED(fixedTime);
    Q_UNUSED(startTime); Q_UNUSED(endTime); Q_UNUSED(intervalMinutes); Q_UNUSED(soundEnabled);
    Q_UNUSED(soundName); Q_UNUSED(volume01); Q_UNUSED(title); Q_UNUSED(text);
#endif
}

void AndroidBackground::cancelAction(int requestId)
{
#ifdef Q_OS_ANDROID
    if (!QNativeInterface::QAndroidApplication::isActivityContext())
        return;

    QJniObject ctx = QNativeInterface::QAndroidApplication::context();

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "cancel",
        "(Landroid/content/Context;I)V",
        ctx.object<jobject>(),
        (jint)requestId);
#else
    Q_UNUSED(requestId);
#endif
}

void AndroidBackground::cancelActions(int firstRequestId, int count)
{
#ifdef Q_OS_ANDROID
    if (!QNativeInterface::QAndroidApplication::isActivityContext())
        return;

    QJniObject ctx = QNativeInterface::QAndroidApplication::context();

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "cancelActions",
        "(Landroid/content/Context;II)V",
        ctx.object<jobject>(),
        (jint)firstRequestId,
        (jint)count);
#else
    Q_UNUSED(firstRequestId);
    Q_UNUSED(count);
#endif
}
