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

# Android-Only Quellen (JNI / android/log.h) -> nur auf Android bauen
if(ANDROID)
    target_sources(appDailyActionReminder PRIVATE


    )
    # für __android_log_vprint / logcat
    target_link_libraries(appDailyActionReminder PRIVATE log)
endif()

# QML-Modul (QML wird unter qrc:/qt/qml/DailyActionReminder/... abgelegt)
qt_add_qml_module(appDailyActionReminder
    URI DailyActionReminder
    QML_FILES
        Main.qml
        ActionDelegate.qml
        QML_FILES TestScheduling.qml
        SOURCES
        SOURCES
        SOURCES soundtaskmanagerandroid.h
        SOURCES soundtaskmanagerandroid.cpp
)

# ✅ Variante B: Root-QRC, damit qrc:/sounds/... weiter funktioniert
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

set_target_properties(appDailyActionReminder PROPERTIES
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

target_link_libraries(appDailyActionReminder
    PRIVATE
        Qt6::Quick
        Qt6::QuickControls2
        Qt6::Multimedia
)

include(GNUInstallDirs)
install(TARGETS appDailyActionReminder
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

if(ANDROID)
    set_target_properties(appDailyActionReminder PROPERTIES
        QT_ANDROID_PACKAGE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/android"
    )
endif()
