#pragma once

#include <QObject>
#include <QVariantMap>

class AppStorage : public QObject
{
    Q_OBJECT
public:
    explicit AppStorage(QObject* parent = nullptr);

    // returns: { ok: bool, allSoundsDisabled: bool, actionsJson: string }
    Q_INVOKABLE QVariantMap loadState() const;

    Q_INVOKABLE bool saveState(bool allSoundsDisabled, const QString& actionsJson) const;

private:
    QString statePath() const;
};
