cmake_minimum_required(VERSION 3.20)
project(NppBeads LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR        "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE  "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

add_library(NppBeads SHARED
    src/NppBeads.mm
    src/BeadsPanel.mm
    src/JsonlDataSource.mm
    src/BeadsProjectScanner.mm
    src/BeadsWatcher.mm
    src/BeadsSchemeHandler.mm
    src/BdCommandRunner.mm
    src/BdDataSource.mm
    src/BeadsPoll.mm
)
target_include_directories(NppBeads PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
    src)
target_link_libraries(NppBeads PRIVATE
    "-framework Cocoa"
    "-framework WebKit"
    "-framework UniformTypeIdentifiers")
target_compile_options(NppBeads PRIVATE
    -Wall -Wno-unused-parameter
    -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(NppBeads PROPERTIES PREFIX "" SUFFIX ".dylib")

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.notepad++/plugins/NppBeads")
install(TARGETS NppBeads DESTINATION "${PLUGIN_INSTALL_DIR}")
install(DIRECTORY resources/ DESTINATION "${PLUGIN_INSTALL_DIR}/resources"
    PATTERN ".git"       EXCLUDE
    PATTERN ".github"    EXCLUDE
    PATTERN ".DS_Store"  EXCLUDE
    PATTERN ".gitignore" EXCLUDE)
install(FILES resources/toolbar.png DESTINATION "${PLUGIN_INSTALL_DIR}")
