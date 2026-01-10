#include "AppStorage.h"

#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QSaveFile>
#include <QJsonDocument>
#include <QJsonObject>

AppStorage::AppStorage(QObject* parent) : QObject(parent) {}

QString AppStorage::statePath() const
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(base);
    return base + QDir::separator() + "state.json";
}

QVariantMap AppStorage::loadState() const
{
    QVariantMap out;
    out["ok"] = false;
    out["allSoundsDisabled"] = false;
    out["actionsJson"] = QString();

    QFile f(statePath());
    if (!f.exists())
        return out;

    if (!f.open(QIODevice::ReadOnly))
        return out;

    const QByteArray data = f.readAll();
    f.close();

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(data, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject())
        return out;

    const QJsonObject o = doc.object();
    out["allSoundsDisabled"] = o.value("allSoundsDisabled").toBool(false);
    out["actionsJson"] = o.value("actionsJson").toString();
    out["ok"] = true;
    return out;
}

bool AppStorage::saveState(bool allSoundsDisabled, const QString& actionsJson) const
{
    QSaveFile f(statePath());
    if (!f.open(QIODevice::WriteOnly))
        return false;

    QJsonObject o;
    o["version"] = 1;
    o["allSoundsDisabled"] = allSoundsDisabled;
    o["actionsJson"] = actionsJson;

    const QByteArray payload = QJsonDocument(o).toJson(QJsonDocument::Compact);
    if (f.write(payload) != payload.size())
        return false;

    // commit() ist atomar + flush
    return f.commit();
}
