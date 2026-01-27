#include "LogQML.h"

#ifdef Q_OS_ANDROID
#include <android/log.h>
#else
#include <QDebug>
#endif

#include <QByteArray>

LogQML::LogQML(QObject* parent)
    : QObject(parent), m_tag(QStringLiteral("QML"))
{}

void LogQML::setTag(const QString& tag)
{
    if (!tag.isEmpty())
        m_tag = tag;
}

void LogQML::logImpl(int prio, const QString& msg)
{
#ifdef Q_OS_ANDROID
    const QByteArray tag = m_tag.toUtf8();
    const QByteArray txt = msg.toUtf8();
    __android_log_print(prio, tag.constData(), "%s", txt.constData());
#else
    // Desktop fallback: geht in Qt Creator Application Output
    switch (prio) {
    case 3:  qDebug().noquote()   << m_tag << ":" << msg; break;   // DEBUG
    case 4:  qInfo().noquote()    << m_tag << ":" << msg; break;   // INFO
    case 5:  qWarning().noquote() << m_tag << ":" << msg; break;   // WARN
    default: qCritical().noquote()<< m_tag << ":" << msg; break;   // ERROR
    }
#endif
}

void LogQML::d(const QString& msg) { logImpl(3, msg); } // ANDROID_LOG_DEBUG
void LogQML::i(const QString& msg) { logImpl(4, msg); } // ANDROID_LOG_INFO
void LogQML::w(const QString& msg) { logImpl(5, msg); } // ANDROID_LOG_WARN
void LogQML::e(const QString& msg) { logImpl(6, msg); } // ANDROID_LOG_ERROR
