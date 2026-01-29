#pragma once

class QObject;
class ISoundTaskManager;

struct SoundTaskManagerFactory {
    static ISoundTaskManager* create(QObject *parent = nullptr);
};
