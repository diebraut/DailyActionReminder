#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QCoreApplication>

#include "AppStorage.h"

int main(int argc, char *argv[])
{
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
