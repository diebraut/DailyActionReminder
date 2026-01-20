#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QCoreApplication>
#include <QQuickWindow>
#include <QTimer>
#include <QDateTime>

#ifdef Q_OS_ANDROID
#include <android/log.h>
#include <QJniObject>
#include <QJniEnvironment>
#endif

#include "AppStorage.h"
#include <cstdio>
#include <cstdarg>

static QtMessageHandler g_prevHandler = nullptr;

static void filteredMsgHandler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    if (msg.contains("IAudioClient3::GetCurrentPadding failed") ||
        msg.contains("AUDCLNT_E_DEVICE_INVALIDATED") ||
        msg.contains("ASSERT: \"m_stopRequested\"") ||
        msg.contains("qaudiosystem_platform_stream_support.cpp"))
    {
        return;
    }

    if (g_prevHandler) {
        g_prevHandler(type, ctx, msg);
        return;
    }

    const QByteArray b = msg.toLocal8Bit();
    std::fprintf(stderr, "%s\n", b.constData());
}

#ifdef Q_OS_ANDROID
static void alogW(const char* fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    __android_log_vprint(ANDROID_LOG_WARN, "DailyActionReminder", fmt, ap);
    va_end(ap);
}

static void alogE(const char* fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    __android_log_vprint(ANDROID_LOG_ERROR, "DailyActionReminder", fmt, ap);
    va_end(ap);
}

static QJniObject getQtActivity()
{
    // org.qtproject.qt.android.QtNative.activity(): Activity
    return QJniObject::callStaticObjectMethod(
        "org/qtproject/qt/android/QtNative",
        "activity",
        "()Landroid/app/Activity;"
        );
}

// ------------------------------------------------------------------
// 1) ensureNotificationPermission(Activity) - bleibt NO-OP bei dir
// ------------------------------------------------------------------
static void callAlarmSchedulerEnsure()
{
    alogW("JNI: calling AlarmScheduler.ensureNotificationPermission(Activity)");

    QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        alogW("JNI: QtNative.activity() invalid -> ensure skipped");
        return;
    }

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "ensureNotificationPermission",
        "(Landroid/app/Activity;)V",
        activity.object<jobject>()
        );

    QJniEnvironment env;
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        alogW("JNI: ensureNotificationPermission -> EXCEPTION");
    } else {
        alogW("JNI: ensureNotificationPermission -> OK");
    }
}

// ------------------------------------------------------------------
// 2) Echter Wrapper für scheduleWithParams(...)
//    Du kannst den später aus deinem C++ (AppStorage o.ä.) aufrufen.
// ------------------------------------------------------------------
static void callAlarmSchedulerSchedule(
    qint64 triggerAtMillis,
    const QString &soundName,
    int requestId,
    const QString &title,
    const QString &text,
    const QString &mode,
    const QString &fixedTime,
    const QString &startTime,
    const QString &endTime,
    int intervalMinutes,
    float volume01
    )
{
    QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        alogW("JNI: schedule: no Activity -> abort");
        return;
    }

    const float v = std::max(0.0f, std::min(1.0f, volume01));

    QJniObject jSound = QJniObject::fromString(soundName);
    QJniObject jTitle = QJniObject::fromString(title);
    QJniObject jText  = QJniObject::fromString(text);
    QJniObject jMode  = QJniObject::fromString(mode);
    QJniObject jFixed = QJniObject::fromString(fixedTime);
    QJniObject jStart = QJniObject::fromString(startTime);
    QJniObject jEnd   = QJniObject::fromString(endTime);

    alogW("JNI: calling AlarmScheduler.scheduleWithParams id=%d inMs=%lld sound=%s vol=%.2f",
          requestId,
          (long long)(triggerAtMillis - QDateTime::currentMSecsSinceEpoch()),
          soundName.toUtf8().constData(),
          v);

    QJniObject::callStaticMethod<void>(
        "org/dailyactions/AlarmScheduler",
        "scheduleWithParams",
        "(Landroid/content/Context;JLjava/lang/String;ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;IF)V",
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
        (jint)intervalMinutes,
        (jfloat)v
        );

    QJniEnvironment env;
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        alogW("JNI: scheduleWithParams -> EXCEPTION");
    } else {
        alogW("JNI: scheduleWithParams -> OK");
    }
}
#endif // Q_OS_ANDROID

#ifdef Q_OS_ANDROID
static void scheduleBeepEvery10s()
{
    alogW("JNI: scheduleBeepEvery10s() entered");

    QJniObject activity = getQtActivity();
    if (!activity.isValid()) {
        alogW("JNI: scheduleBeepEvery10s: no Activity");
        return;
    }

    static int counter = 0;

    // QTimer lebt im Qt-Eventloop => once app.exec() läuft, kommt alle 10s ein Alarm
    QTimer *t = new QTimer(qApp);
    t->setInterval(10'000);

    QObject::connect(t, &QTimer::timeout, [activity]() mutable {
        counter++;

        jlong triggerAt = QDateTime::currentMSecsSinceEpoch() + 1500; // 1.5s in Zukunft (sauber)
        jint requestId = 20000 + (counter % 5000);                    // wechselnde IDs

        QJniObject soundName = QJniObject::fromString("bell");        // muss in res/raw existieren
        QJniObject title = QJniObject::fromString("TEST");
        QJniObject text  = QJniObject::fromString("BEEP #" + QString::number(counter));

        QJniObject mode = QJniObject::fromString("test");
        QJniObject fixedTime = QJniObject::fromString("");
        QJniObject startTime = QJniObject::fromString("");
        QJniObject endTime   = QJniObject::fromString("");

        jint intervalMin = 0;
        jfloat volume01 = 1.0f;

        alogW("JNI: scheduling beep #%d requestId=%d triggerAt=%lld", counter, requestId, (long long)triggerAt);

        QJniObject::callStaticMethod<void>(
            "org/dailyactions/AlarmScheduler",
            "scheduleWithParams",
            "(Landroid/content/Context;JLjava/lang/String;ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;IF)V",
            activity.object<jobject>(),
            triggerAt,
            soundName.object<jstring>(),
            requestId,
            title.object<jstring>(),
            text.object<jstring>(),
            mode.object<jstring>(),
            fixedTime.object<jstring>(),
            startTime.object<jstring>(),
            endTime.object<jstring>(),
            intervalMin,
            volume01
            );

        QJniEnvironment env;
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
            alogW("JNI: scheduleWithParams -> EXCEPTION");
        } else {
            alogW("JNI: scheduleWithParams -> OK");
        }
    });

    t->start();
    alogW("JNI: scheduleBeepEvery10s timer started");
}
#endif


int main(int argc, char *argv[])
{
#ifdef Q_OS_ANDROID
    __android_log_print(ANDROID_LOG_ERROR, "DailyActionReminder", "### MAIN ENTERED ###");
#endif

    // Optional: nicht-nativer Style
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");

    QGuiApplication app(argc, argv);

#ifdef Q_OS_ANDROID
    QTimer::singleShot(0, [](){
        //callAlarmSchedulerEnsure();     // optional (NO-OP)
        scheduleBeepEvery10s();         // <-- das ist der neue Test
    });
#endif

    QCoreApplication::setOrganizationName("RolandPrinz");
    QCoreApplication::setOrganizationDomain("rolandprinz.local");
    QCoreApplication::setApplicationName("DailyActionReminder");

    AppStorage storage;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("Storage", &storage);
    engine.load(QUrl(QStringLiteral("qrc:/Main.qml")));

    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}
