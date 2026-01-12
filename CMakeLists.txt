cmake_minimum_required(VERSION 3.16)

project(DailyActionReminder VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick Multimedia)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(appDailyActionReminder
    main.cpp
)

qt_add_qml_module(appDailyActionReminder
    URI DailyActionReminder
    QML_FILES

        QML_FILES ActionDelegate.qml
        RESOURCES
        SOURCES appstorage.h appstorage.cpp
)
qt_add_resources(appDailyActionReminder
    "qml"
    PREFIX "/"
    FILES
        Main.qml
        ActionDelegate.qml
        sounds/bell.wav
)

# Qt for iOS sets MACOSX_BUNDLE_GUI_IDENTIFIER automatically since Qt 6.1.
# If you are developing for iOS or macOS you should consider setting an
# explicit, fixed bundle identifier manually though.
set_target_properties(appDailyActionReminder PROPERTIES
#    MACOSX_BUNDLE_GUI_IDENTIFIER com.example.appDailyActionReminder
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

find_package(Qt6 REQUIRED COMPONENTS
    Quick
    QuickControls2
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
