#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QCoreApplication>
#include <QQuickWindow>
#include <QTimer>
#include <QDateTime>
#include <QDebug>

#ifdef Q_OS_ANDROID
#include <android/log.h>
#include <QJniObject>
#include <QJniEnvironment>
#endif

#include "appstorage.h"
#include <cstdio>

#include <QDir>
#include <QStandardPaths>

#include "logqml.h"

#include "soundtaskmanager.h"

static QtMessageHandler g_prevHandler = nullptr;

// ------------------------------------------------------------
// 1) Globaler Message-Handler: fängt Qt + QML console.* ab
// ------------------------------------------------------------
static void myMessageHandler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    // Format: Zeit + Level + msg (+ optional file:line)
    const char* lvl = "DBG";

    switch (type) {
    case QtDebugMsg:    lvl = "DBG"; break;
    case QtInfoMsg:     lvl = "INF"; break;
    case QtWarningMsg:  lvl = "WRN"; break;
    case QtCriticalMsg: lvl = "CRT"; break;
    case QtFatalMsg:    lvl = "FTL"; break;
    }

    const QString ts = QDateTime::currentDateTime().toString("HH:mm:ss.zzz");
    QString line = QString("[%1] %2: %3").arg(ts, lvl, msg);

    // Optional: Quelle anhängen (hilft bei QML Zeilen)
    if (ctx.file && ctx.line > 0) {
        line += QString("  (%1:%2)").arg(ctx.file).arg(ctx.line);
    }

    // 1) Immer in stderr/Logcat
    fprintf(stderr, "%s\n", line.toUtf8().constData());
    fflush(stderr);

    // 2) Optional in Datei (Android: App-Datenverzeichnis)
    static QFile f;
    static bool inited = false;
    if (!inited) {
        inited = true;
        const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        (void)QDir().mkpath(dir);
        f.setFileName(dir + "/qml.log");
        (void)f.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text);
    }
    if (f.isOpen()) {
        QTextStream out(&f);
        out << line << "\n";
        out.flush();
    }

    if (type == QtFatalMsg) {
        abort();
    }
}


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


int main(int argc, char *argv[])
{
    qInstallMessageHandler(myMessageHandler);

    // Optional: nicht-nativer Style
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");

    QGuiApplication app(argc, argv);

    QCoreApplication::setOrganizationName("RolandPrinz");
    QCoreApplication::setOrganizationDomain("rolandprinz.local");
    QCoreApplication::setApplicationName("DailyActionReminder");

    AppStorage storage;

    QQmlApplicationEngine engine;
    auto* log = new LogQML(&engine);
    log->setTag("qml");   // dein Wunsch-Tag

    QObject::connect(&engine, &QQmlApplicationEngine::warnings,
                     [](const QList<QQmlError>& warnings){
                         for (const auto& w : warnings)
                             qWarning().noquote() << w.toString();
                     });

    qmlRegisterSingletonType<SoundTaskManager>(
        "DailyActions", 1, 0, "SoundTaskManager",
        [](QQmlEngine*, QJSEngine*) -> QObject* {
            return new SoundTaskManager();
        }
        );

    engine.rootContext()->setContextProperty("Storage", &storage);
    engine.rootContext()->setContextProperty("Log", log);

    // ------------------------------------------------------------
    // 3) Harter Check: wenn Main.qml nicht geladen werden kann
    //    (Parse/Import Fehler), sofort sichtbar + Exit-Code
    // ------------------------------------------------------------
    const QUrl url(QStringLiteral("qrc:/qt/qml/DailyActionReminder/Main.qml"));

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app,
                     [url](QObject *obj, const QUrl &objUrl) {
                         if (!obj && url == objUrl) {
                             qCritical().noquote() << "❌ Failed to load root QML:" << objUrl.toString();
                             QCoreApplication::exit(1);
                         }
                     }, Qt::QueuedConnection);

    engine.load(QUrl(QStringLiteral("qrc:/qt/qml/DailyActionReminder/Main.qml")));
    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}
