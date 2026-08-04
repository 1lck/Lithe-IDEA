cmake_minimum_required(VERSION 3.24)

project(LitheWindows LANGUAGES CXX)

add_library(lithe_windows_core STATIC
    core/core_client.cpp
)

add_library(lithe_windows_adapters STATIC
    adapters/win32_directory_watcher.cpp
    adapters/win32_file_system.cpp
    adapters/win32_key_value_store.cpp
    adapters/win32_process_runner.cpp
    adapters/win32_process_session.cpp
    adapters/win32_runtime_locator.cpp
    adapters/win32_terminal_transport.cpp
)

add_library(lithe_windows_adapter_ports INTERFACE)
target_include_directories(lithe_windows_adapter_ports INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)

target_include_directories(lithe_windows_core PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
)
target_compile_features(lithe_windows_core PUBLIC cxx_std_20)
target_include_directories(lithe_windows_adapters PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_compile_features(lithe_windows_adapters PUBLIC cxx_std_20)
if(WIN32)
    target_link_libraries(lithe_windows_adapters PRIVATE kernel32)
endif()

# The Rust library is supplied by the Windows packaging/toolchain layer. Keep
# this binding target independent so ABI and contract checks can run without Qt.
option(LITHE_BUILD_QT_UI "Build the Qt Widgets workspace workbench" OFF)
if(LITHE_BUILD_QT_UI)
    set(CMAKE_AUTOMOC ON)
    find_package(Qt6 REQUIRED COMPONENTS Widgets)
    add_executable(lithe_windows_qt
        qt/main.cpp
        qt/workbench_window.cpp
        qt/workbench_window.h
    )
    target_link_libraries(lithe_windows_qt PRIVATE lithe_windows_core lithe_windows_adapters Qt6::Widgets)
    target_include_directories(lithe_windows_qt PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/core"
        "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
    )
    set(LITHE_RUST_CORE_LIBRARY "" CACHE FILEPATH "Path to the Rust lithe-core static library")
    if(LITHE_RUST_CORE_LIBRARY)
        target_link_libraries(lithe_windows_qt PRIVATE "${LITHE_RUST_CORE_LIBRARY}")
    endif()
endif()
