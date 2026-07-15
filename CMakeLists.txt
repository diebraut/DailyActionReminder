cmake_minimum_required(VERSION 3.16)

project(DailyActionReminder VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(IOS)
    enable_language(OBJCXX)
endif()

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

set(DAILY_ACTION_SOUND_FILES
    sounds/bell.wav
    sounds/pop_click.wav
    sounds/airy_whoosh.wav
    sounds/beep_short.wav
    sounds/beep_double.wav
    sounds/low_gong.wav
    sounds/marimba_hit.wav
    sounds/soft_chime.wav
    sounds/soft_chime_qt.wav
    sounds/triangle_ping.wav
    sounds/wood_tap.wav
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
        ${DAILY_ACTION_SOUND_FILES}
)

target_link_libraries(appDailyActionReminder
    PRIVATE
        Qt6::Quick
        Qt6::QuickControls2
        Qt6::Multimedia
)

set_target_properties(appDailyActionReminder PROPERTIES
    OUTPUT_NAME "DailyActions"
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE_BUNDLE_NAME "DailyActions"
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
        QT_ANDROID_APP_NAME "DailyActions"
    )
endif()

# iOS-only: native local notifications + sound files as real bundle resources.
if(IOS)
    target_sources(appDailyActionReminder PRIVATE
        soundtaskmanagerios.h
        soundtaskmanagerios.mm
        icons/Assets.xcassets
        ${DAILY_ACTION_SOUND_FILES}
    )

    set_source_files_properties(icons/Assets.xcassets
        PROPERTIES MACOSX_PACKAGE_LOCATION Resources
    )

    set_source_files_properties(${DAILY_ACTION_SOUND_FILES}
        PROPERTIES MACOSX_PACKAGE_LOCATION Resources
    )

    target_link_libraries(appDailyActionReminder PRIVATE
        "-framework AVFoundation"
        "-framework UserNotifications"
        "-framework WatchConnectivity"
    )

    set(QT_IOS_FFMPEG_DIR "${Qt6_DIR}/../../ffmpeg")
    get_filename_component(QT_IOS_FFMPEG_DIR "${QT_IOS_FFMPEG_DIR}" ABSOLUTE)

    foreach(ffmpeg_lib avformat avcodec avutil swresample swscale)
        target_link_libraries(appDailyActionReminder PRIVATE
            "-framework lib${ffmpeg_lib}"
        )
    endforeach()

    set_target_properties(appDailyActionReminder PROPERTIES
        XCODE_ATTRIBUTE_PRODUCT_NAME "DailyActions"
        XCODE_ATTRIBUTE_INFOPLIST_KEY_CFBundleDisplayName "DailyActions"
        XCODE_ATTRIBUTE_INFOPLIST_KEY_CFBundleName "DailyActions"
        XCODE_ATTRIBUTE_ASSETCATALOG_COMPILER_APPICON_NAME "AppIcon"
        XCODE_ATTRIBUTE_FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*] "$(inherited) ${QT_IOS_FFMPEG_DIR}/libavformat.xcframework/ios-arm64 ${QT_IOS_FFMPEG_DIR}/libavcodec.xcframework/ios-arm64 ${QT_IOS_FFMPEG_DIR}/libavutil.xcframework/ios-arm64 ${QT_IOS_FFMPEG_DIR}/libswresample.xcframework/ios-arm64 ${QT_IOS_FFMPEG_DIR}/libswscale.xcframework/ios-arm64"
        XCODE_ATTRIBUTE_FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] "$(inherited) ${QT_IOS_FFMPEG_DIR}/libavformat.xcframework/ios-x86_64-simulator ${QT_IOS_FFMPEG_DIR}/libavcodec.xcframework/ios-x86_64-simulator ${QT_IOS_FFMPEG_DIR}/libavutil.xcframework/ios-x86_64-simulator ${QT_IOS_FFMPEG_DIR}/libswresample.xcframework/ios-x86_64-simulator ${QT_IOS_FFMPEG_DIR}/libswscale.xcframework/ios-x86_64-simulator"
        XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"
    )

    add_custom_command(TARGET appDailyActionReminder POST_BUILD
        COMMAND /bin/sh -c "set -e
            slice=ios-arm64
            if [ \"\${PLATFORM_NAME}\" = \"iphonesimulator\" ]; then
                slice=ios-x86_64-simulator
            fi

            frameworks_dir=\"\${TARGET_BUILD_DIR}/\${FRAMEWORKS_FOLDER_PATH}\"
            mkdir -p \"\${frameworks_dir}\"

            for lib in avformat avcodec avutil swresample swscale; do
                src=\"${QT_IOS_FFMPEG_DIR}/lib\${lib}.xcframework/\${slice}/lib\${lib}.framework\"
                dst=\"\${frameworks_dir}/lib\${lib}.framework\"
                rm -rf \"\${dst}\"
                cp -R \"\${src}\" \"\${frameworks_dir}/\"

                if [ -n \"\${EXPANDED_CODE_SIGN_IDENTITY}\" ]; then
                    codesign --force --sign \"\${EXPANDED_CODE_SIGN_IDENTITY}\" --preserve-metadata=identifier,entitlements \"\${dst}\"
                fi
            done"
        VERBATIM
    )
endif()

include(GNUInstallDirs)
install(TARGETS appDailyActionReminder
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
