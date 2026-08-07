cmake_minimum_required(VERSION 3.24)

project(LitheWindows LANGUAGES CXX)

include(CTest)
enable_testing()

if(WIN32)
    add_compile_definitions(NOMINMAX)
endif()

add_library(lithe_windows_core STATIC
    core/core_client.cpp
    core/core_dto.cpp
    core/core_worker_pool.cpp
    core/core_requests.cpp
    core/json_value.cpp
)

add_library(lithe_windows_adapters STATIC
    adapters/win32_archive_entry_reader.cpp
    adapters/win32_directory_watcher.cpp
    adapters/win32_file_system.cpp
    adapters/win32_file_storage.cpp
    adapters/win32_key_value_store.cpp
    adapters/win32_process_runner.cpp
    adapters/win32_process_session.cpp
    adapters/win32_runtime_locator.cpp
    adapters/win32_secure_store.cpp
    adapters/win32_authenticode_verifier.cpp
    adapters/win32_terminal_transport.cpp
    adapters/win32_http_transport.cpp
)

add_library(lithe_windows_adapter_ports INTERFACE)
target_include_directories(lithe_windows_adapter_ports INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)

target_include_directories(lithe_windows_core PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
)
target_compile_features(lithe_windows_core PUBLIC cxx_std_23)
target_include_directories(lithe_windows_adapters PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_compile_features(lithe_windows_adapters PUBLIC cxx_std_23)
if(WIN32)
    target_link_libraries(lithe_windows_adapters PRIVATE
        advapi32
        kernel32
        ole32
        shell32
        crypt32
        wintrust
        winhttp
    )
endif()

add_library(lithe_windows_algorithms STATIC
    app/algorithms/argument_tokenizer.cpp
    app/algorithms/diff_collapse.cpp
    app/algorithms/diff_pairing.cpp
    app/algorithms/diff_split_layout.cpp
    app/algorithms/diff_tokenizer.cpp
    app/algorithms/file_visibility_rules.cpp
    app/algorithms/git_graph_layout.cpp
    app/algorithms/git_reference_tree.cpp
    app/algorithms/inline_diff.cpp
    app/algorithms/semver.cpp
    app/algorithms/syntax_highlighter.cpp
    app/algorithms/terminal_buffer.cpp
)
target_include_directories(lithe_windows_algorithms PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/app/algorithms"
)
target_compile_features(lithe_windows_algorithms PUBLIC cxx_std_23)

add_library(lithe_windows_app STATIC
    app/features/document_feature.cpp
    app/features/git_feature.cpp
    app/features/history_feature.cpp
    app/features/maven_java_feature.cpp
    app/features/replacement_feature.cpp
    app/features/editor_position.cpp
    app/features/search_feature.cpp
    app/features/workspace_feature.cpp
    app/features/workbench_coordinator.cpp
    app/features/workspace_paths.cpp
    app/persistence/app_persistence.cpp
    app/services/maven_build_service.cpp
    app/services/java_run_service.cpp
    app/services/java_debug_service.cpp
    app/services/java_language_server.cpp
    app/services/project_runtime_service.cpp
    app/services/ai_commit_service.cpp
    app/services/windows_update_service.cpp
)
target_include_directories(lithe_windows_app PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/app/features"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_compile_features(lithe_windows_app PUBLIC cxx_std_23)
target_link_libraries(lithe_windows_app PUBLIC lithe_windows_core)

set(LITHE_RUST_CORE_LIBRARY "" CACHE FILEPATH "Path to the Rust lithe-core static library")

add_executable(lithe_windows_phase0_tests
    tests/windows_phase0_test.cpp
)
target_compile_features(lithe_windows_phase0_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_phase0_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_phase0_tests PRIVATE
    lithe_windows_core
    lithe_windows_adapters
)
if(WIN32)
    target_link_libraries(lithe_windows_phase0_tests PRIVATE advapi32 shell32)
endif()
add_test(NAME lithe_windows_phase0 COMMAND lithe_windows_phase0_tests)

add_executable(lithe_windows_algorithms_tests
    tests/windows_algorithms_test.cpp
)
target_compile_features(lithe_windows_algorithms_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_algorithms_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/algorithms"
)
target_link_libraries(lithe_windows_algorithms_tests PRIVATE lithe_windows_algorithms)
add_test(NAME lithe_windows_algorithms COMMAND lithe_windows_algorithms_tests)

add_executable(lithe_windows_app_tests
    tests/windows_app_test.cpp
)
target_compile_features(lithe_windows_app_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_app_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/features"
)
target_link_libraries(lithe_windows_app_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_app COMMAND lithe_windows_app_tests)

add_executable(lithe_windows_coordinator_tests
    tests/workbench_coordinator_test.cpp
)
target_compile_features(lithe_windows_coordinator_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_coordinator_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/features"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
)
target_link_libraries(lithe_windows_coordinator_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_coordinator COMMAND lithe_windows_coordinator_tests)

add_executable(lithe_windows_core_dto_tests
    tests/core_dto_test.cpp
)
target_compile_features(lithe_windows_core_dto_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_core_dto_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
)
target_link_libraries(lithe_windows_core_dto_tests PRIVATE lithe_windows_core)
add_test(NAME lithe_windows_core_dto COMMAND lithe_windows_core_dto_tests)

add_executable(lithe_windows_persistence_tests
    tests/persistence_test.cpp
)
target_compile_features(lithe_windows_persistence_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_persistence_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/persistence"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_persistence_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_persistence COMMAND lithe_windows_persistence_tests)

add_executable(lithe_windows_runtime_service_tests
    tests/runtime_service_test.cpp
)
target_compile_features(lithe_windows_runtime_service_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_runtime_service_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_runtime_service_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_runtime_service COMMAND lithe_windows_runtime_service_tests)

add_executable(lithe_windows_java_run_service_tests
    tests/java_run_service_test.cpp
)
target_compile_features(lithe_windows_java_run_service_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_java_run_service_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_java_run_service_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_java_run_service COMMAND lithe_windows_java_run_service_tests)

add_executable(lithe_windows_java_debug_service_tests
    tests/java_debug_service_test.cpp
)
target_compile_features(lithe_windows_java_debug_service_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_java_debug_service_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_java_debug_service_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_java_debug_service COMMAND lithe_windows_java_debug_service_tests)

add_executable(lithe_windows_java_language_server_tests
    tests/java_language_server_test.cpp
)
target_compile_features(lithe_windows_java_language_server_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_java_language_server_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_java_language_server_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_java_language_server COMMAND lithe_windows_java_language_server_tests)

add_executable(lithe_windows_ai_commit_service_tests
    tests/ai_commit_service_test.cpp
)
target_compile_features(lithe_windows_ai_commit_service_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_ai_commit_service_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_ai_commit_service_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_ai_commit_service COMMAND lithe_windows_ai_commit_service_tests)

add_executable(lithe_windows_update_service_tests
    tests/windows_update_service_test.cpp
)
target_compile_features(lithe_windows_update_service_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_update_service_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_update_service_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_update_service COMMAND lithe_windows_update_service_tests)

# The Rust library is supplied by the Windows packaging/toolchain layer. Keep
# this binding target independent so ABI and contract checks can run without Qt.
option(LITHE_BUILD_QT_UI "Build the Qt Widgets workspace workbench" OFF)
if(LITHE_BUILD_QT_UI AND NOT WIN32)
    message(FATAL_ERROR
        "LITHE_BUILD_QT_UI is a Windows-only target; configure it on a Windows toolchain")
endif()
if(LITHE_BUILD_QT_UI AND NOT LITHE_RUST_CORE_LIBRARY)
    message(FATAL_ERROR
        "LITHE_RUST_CORE_LIBRARY is required when LITHE_BUILD_QT_UI is enabled")
endif()
if(LITHE_BUILD_QT_UI)
    set(CMAKE_AUTOMOC ON)
    find_package(Qt6 REQUIRED COMPONENTS Widgets)
    add_executable(lithe_windows_qt
        qt/main.cpp
        qt/workbench_code_editor.cpp
        qt/workbench_code_editor.h
        qt/workbench_window.cpp
        qt/workbench_window.h
    )
    target_link_libraries(lithe_windows_qt PRIVATE
        lithe_windows_app
        lithe_windows_adapters
        lithe_windows_algorithms
        Qt6::Widgets
    )
    target_compile_features(lithe_windows_qt PRIVATE cxx_std_23)
    target_include_directories(lithe_windows_qt PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/core"
        "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
        "${CMAKE_CURRENT_SOURCE_DIR}/app/algorithms"
        "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
    )
    if(LITHE_RUST_CORE_LIBRARY)
        target_link_libraries(lithe_windows_qt PRIVATE "${LITHE_RUST_CORE_LIBRARY}")
        if(WIN32)
            target_link_libraries(lithe_windows_qt PRIVATE
                advapi32 bcrypt ntdll userenv ws2_32
            )
        endif()
    endif()
endif()

if(WIN32)
    add_executable(lithe_windows_update_helper WIN32
        packaging/update_helper.cpp
    )
    target_compile_features(lithe_windows_update_helper PRIVATE cxx_std_23)
    target_link_libraries(lithe_windows_update_helper PRIVATE shell32)
endif()

if(LITHE_RUST_CORE_LIBRARY)
    add_executable(lithe_windows_core_ping
        tests/core_ping_test.cpp
    )
    target_compile_features(lithe_windows_core_ping PRIVATE cxx_std_23)
    target_include_directories(lithe_windows_core_ping PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/core"
    )
    target_link_libraries(lithe_windows_core_ping PRIVATE
        lithe_windows_core
        "${LITHE_RUST_CORE_LIBRARY}"
    )
    if(WIN32)
        target_link_libraries(lithe_windows_core_ping PRIVATE
            advapi32 bcrypt ntdll userenv ws2_32
        )
    endif()
    add_test(NAME lithe_windows_core_ping COMMAND lithe_windows_core_ping)
endif()
