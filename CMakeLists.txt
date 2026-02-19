cmake_minimum_required(VERSION 3.16)

project(DailyActionReminder VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick QuickControls2 Multimedia)
qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(appDailyActionReminder
    main.cpp
    appstorage.h appstorage.cpp
    logqml.h logqml.cpp

    i_soundtaskmanager.h
    soundtaskmanager.h soundtaskmanager.cpp
    soundtaskmanagerfactory.h soundtaskmanagerfactory.cpp
    soundtaskmanagerdesktop.h soundtaskmanagerdesktop.cpp
)

# QML-Modul (NUR QML-Dateien hier rein; keine Android-C++ SOURCES!)
qt_add_qml_module(appDailyActionReminder
    URI DailyActionReminder
    QML_FILES
        Main.qml
        ActionDelegate.qml
        TestScheduling.qml
)

# Root-QRC, damit qrc:/sounds/... funktioniert
qt_add_resources(appDailyActionReminder "app_root_qrc"
    PREFIX "/"
    FILES
        sounds/bell.wav
        sounds/pop_click.wav
        sounds/airy_whoosh.wav
        sounds/beep_short.wav
        sounds/beep_double.wav
        sounds/low_gong.wav
        sounds/marimba_hit.wav
        sounds/soft_chime.wav
        sounds/triangle_ping.wav
        sounds/wood_tap.wav
)

target_link_libraries(appDailyActionReminder
    PRIVATE
        Qt6::Quick
        Qt6::QuickControls2
        Qt6::Multimedia
)

set_target_properties(appDailyActionReminder PROPERTIES
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

# Android-only: C++ Quellen + Package-Dir
if(ANDROID)
    target_sources(appDailyActionReminder PRIVATE
        soundtaskmanagerandroid.h
        soundtaskmanagerandroid.cpp
    )

    # für __android_log_* (logcat)
    target_link_libraries(appDailyActionReminder PRIVATE log)

    # Java/Manifest/Gradle unter ./android (android/src/org/dailyactions/...)
    set_target_properties(appDailyActionReminder PROPERTIES
        QT_ANDROID_PACKAGE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/android"
    )
endif()

include(GNUInstallDirs)
install(TARGETS appDailyActionReminder
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
