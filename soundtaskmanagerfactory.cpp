#include "soundtaskmanagerfactory.h"
#include "i_soundtaskmanager.h"

#ifdef Q_OS_ANDROID
#include "soundtaskmanagerandroid.h"
#else
#include "soundtaskmanagerdesktop.h"
#endif

ISoundTaskManager* SoundTaskManagerFactory::create(QObject *parent)
{
#ifdef Q_OS_ANDROID
    return new SoundTaskManagerAndroid(parent);
#else
    return new SoundTaskManagerDesktop(parent);
#endif
}
