#pragma once

#include <QObject>
#include <QString>

class LogQML : public QObject
{
    Q_OBJECT
public:
    explicit LogQML(QObject* parent = nullptr);

    Q_INVOKABLE void d(const QString& msg); // debug
    Q_INVOKABLE void i(const QString& msg); // info
    Q_INVOKABLE void w(const QString& msg); // warn
    Q_INVOKABLE void e(const QString& msg); // error

    // optional: Tag setzen (default: "QML")
    Q_INVOKABLE void setTag(const QString& tag);

private:
    QString m_tag;
    void logImpl(int prio, const QString& msg);
};
