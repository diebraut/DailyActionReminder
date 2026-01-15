#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QCoreApplication>
#include "AppStorage.h"

#include <cstdio>          // für std::fprintf
#ifdef _MSC_VER
#include <crtdbg.h>
#include <cstring>

static int __cdecl myCrtReportHook(int reportType, char* message, int* returnValue)
{
    if (reportType == _CRT_ASSERT && message) {
        if (std::strstr(message, "qaudiosystem_platform_stream_support.cpp") &&
            std::strstr(message, "m_stopRequested"))
        {
            if (returnValue) *returnValue = 0; // 0 = Ignore/weiterlaufen
            return 1;                           // handled -> kein Dialog
        }
    }
    return 0; // alles andere normal
}
#endif


static QtMessageHandler g_prevHandler = nullptr;

static void filteredMsgHandler(QtMsgType type, const QMessageLogContext &ctx, const QString &msg)
{
    // Nur diese nervigen Zeilen ausblenden:
    if (msg.contains("IAudioClient3::GetCurrentPadding failed") ||
        msg.contains("AUDCLNT_E_DEVICE_INVALIDATED") ||
        msg.contains("ASSERT: \"m_stopRequested\"") ||
        msg.contains("qaudiosystem_platform_stream_support.cpp"))
    {
        qDebug() << "catched <AUDCLNT_E_DEVICE_INVALIDATED>";
        return; // swallow
    }

    // Rest normal ausgeben
    if (g_prevHandler) {
        g_prevHandler(type, ctx, msg);
        return;
    }

    // Fallback
    const QByteArray b = msg.toLocal8Bit();
    std::fprintf(stderr, "%s\n", b.constData());
}

int main(int argc, char *argv[])
{
#ifdef _MSC_VER
#ifdef _DEBUG
    // Assert-Dialog abschalten, nach stderr umleiten:
    _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);

    // Und gezielt diesen einen Assert auto-ignorieren:
    _CrtSetReportHook(myCrtReportHook);
#endif
#endif
    // Optional: nicht-nativer Style, damit background/contentItem Customizing keine Warnungen bringt
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");

    QGuiApplication app(argc, argv);

    // gute Praxis (auch für AppDataLocation)
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
