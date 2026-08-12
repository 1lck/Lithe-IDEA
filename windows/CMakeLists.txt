cmake_minimum_required(VERSION 3.24)

project(LitheWindows LANGUAGES CXX)

set(LITHE_VERSION "0.1.11" CACHE STRING "Lithe application version")

include(CTest)
enable_testing()

if(MSVC)
    add_compile_options(/utf-8)
endif()

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
    app/algorithms/fuzzy_match.cpp
    app/algorithms/git_graph_layout.cpp
    app/algorithms/git_reference_tree.cpp
    app/algorithms/gutter_hit_test.cpp
    app/algorithms/inline_diff.cpp
    app/algorithms/semver.cpp
    app/algorithms/syntax_highlighter.cpp
    app/algorithms/terminal_buffer.cpp
    app/algorithms/text_diff.cpp
)
target_include_directories(lithe_windows_algorithms PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/app/algorithms"
)
target_compile_features(lithe_windows_algorithms PUBLIC cxx_std_23)

add_library(lithe_windows_app STATIC
    app/features/document_feature.cpp
    app/features/git_feature.cpp
    app/features/history_feature.cpp
    app/features/shelf_feature.cpp
    app/features/maven_java_feature.cpp
    app/features/replacement_feature.cpp
    app/features/editor_position.cpp
    app/features/search_feature.cpp
    app/features/terminal_feature.cpp
    app/features/workspace_feature.cpp
    app/features/workspace_write_lifecycle.cpp
    app/features/workbench_coordinator.cpp
    app/features/workspace_paths.cpp
    app/persistence/app_persistence.cpp
    app/presentation/workbench_layout_persistence.cpp
    app/presentation/workbench_ui_state.cpp
    app/services/maven_build_service.cpp
    app/services/java_run_service.cpp
    app/services/java_debug_service.cpp
    app/services/java_language_server.cpp
    app/services/project_runtime_service.cpp
    app/services/project_detection_service.cpp
    app/services/ai_commit_service.cpp
    app/services/windows_update_service.cpp
)
target_include_directories(lithe_windows_app PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/app/features"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
    "${CMAKE_CURRENT_SOURCE_DIR}/app/persistence"
    "${CMAKE_CURRENT_SOURCE_DIR}/app/presentation"
    "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
)
target_compile_features(lithe_windows_app PUBLIC cxx_std_23)
target_link_libraries(lithe_windows_app PUBLIC lithe_windows_core lithe_windows_algorithms)

add_library(lithe_windows_workbench STATIC
    winui/workbench_session.cpp
)
target_include_directories(lithe_windows_workbench PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/winui"
    "${CMAKE_CURRENT_SOURCE_DIR}/core"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
    "${CMAKE_CURRENT_SOURCE_DIR}/app/features"
    "${CMAKE_CURRENT_SOURCE_DIR}/app/persistence"
    "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
)
target_compile_features(lithe_windows_workbench PUBLIC cxx_std_23)
target_compile_definitions(lithe_windows_workbench PRIVATE
    LITHE_VERSION="${LITHE_VERSION}"
)
target_link_libraries(lithe_windows_workbench PUBLIC
    lithe_windows_app
    lithe_windows_adapters
)

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

add_executable(lithe_windows_terminal_feature_tests
    tests/terminal_feature_test.cpp
)
target_compile_features(lithe_windows_terminal_feature_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_terminal_feature_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/features"
)
target_link_libraries(lithe_windows_terminal_feature_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_terminal_feature COMMAND lithe_windows_terminal_feature_tests)

add_executable(lithe_windows_workspace_write_lifecycle_tests
    tests/workspace_write_lifecycle_test.cpp
)
target_compile_features(lithe_windows_workspace_write_lifecycle_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_workspace_write_lifecycle_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/features"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_workspace_write_lifecycle_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_workspace_write_lifecycle
         COMMAND lithe_windows_workspace_write_lifecycle_tests)

add_executable(lithe_windows_workbench_ui_state_tests
    tests/workbench_ui_state_test.cpp
)
target_compile_features(lithe_windows_workbench_ui_state_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_workbench_ui_state_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/presentation"
)
target_link_libraries(lithe_windows_workbench_ui_state_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_workbench_ui_state COMMAND lithe_windows_workbench_ui_state_tests)

add_executable(lithe_windows_workbench_layout_persistence_tests
    tests/workbench_layout_persistence_test.cpp
)
target_compile_features(lithe_windows_workbench_layout_persistence_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_workbench_layout_persistence_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/presentation"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_workbench_layout_persistence_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_workbench_layout_persistence
    COMMAND lithe_windows_workbench_layout_persistence_tests)

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

add_executable(lithe_windows_project_detection_tests
    tests/project_detection_test.cpp
)
target_compile_features(lithe_windows_project_detection_tests PRIVATE cxx_std_23)
target_include_directories(lithe_windows_project_detection_tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
    "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
)
target_link_libraries(lithe_windows_project_detection_tests PRIVATE lithe_windows_app)
add_test(NAME lithe_windows_project_detection COMMAND lithe_windows_project_detection_tests)


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
    set(CMAKE_AUTORCC ON)
    find_package(Qt6 REQUIRED COMPONENTS Widgets)
    add_executable(lithe_windows_qt WIN32
        qt/main.cpp
        qt/lithe.qrc
        qt/project_import_dialog.cpp
        qt/project_import_dialog.h
        qt/ui_theme.cpp
        qt/ui_theme.h
        qt/ui_translation.cpp
        qt/ui_translation.h
        qt/workbench_code_editor.cpp
        qt/workbench_code_editor.h
        qt/workbench_editor_area.cpp
        qt/workbench_editor_area.h
        qt/workbench_sidebar.cpp
        qt/workbench_sidebar.h
        qt/workbench_tool_window.cpp
        qt/workbench_tool_window.h
        qt/workbench_window.cpp
        qt/workbench_window.h
        packaging/lithe.rc
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
        "${CMAKE_CURRENT_SOURCE_DIR}/app/persistence"
        "${CMAKE_CURRENT_SOURCE_DIR}/app/presentation"
        "${CMAKE_CURRENT_SOURCE_DIR}/app/services"
    )
    add_executable(lithe_windows_ui_translation_tests
        tests/ui_translation_test.cpp
        qt/lithe.qrc
        qt/ui_translation.cpp
        qt/ui_translation.h
    )
    target_compile_features(lithe_windows_ui_translation_tests PRIVATE cxx_std_23)
    target_include_directories(lithe_windows_ui_translation_tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/qt"
        "${CMAKE_CURRENT_SOURCE_DIR}/app/persistence"
        "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
    )
    target_link_libraries(lithe_windows_ui_translation_tests PRIVATE
        lithe_windows_app
        Qt6::Widgets
    )
    add_test(NAME lithe_windows_ui_translation COMMAND lithe_windows_ui_translation_tests)
    add_executable(lithe_windows_ui_theme_tests
        tests/ui_theme_test.cpp
        qt/ui_theme.cpp
        qt/ui_theme.h
    )
    target_compile_features(lithe_windows_ui_theme_tests PRIVATE cxx_std_23)
    target_include_directories(lithe_windows_ui_theme_tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/qt"
    )
    target_link_libraries(lithe_windows_ui_theme_tests PRIVATE Qt6::Widgets)
    add_test(NAME lithe_windows_ui_theme COMMAND lithe_windows_ui_theme_tests)
    set_tests_properties(lithe_windows_ui_theme PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
    )
    add_executable(lithe_windows_terminal_transport_tests
        tests/win32_terminal_transport_test.cpp
    )
    target_compile_features(lithe_windows_terminal_transport_tests PRIVATE cxx_std_23)
    target_include_directories(lithe_windows_terminal_transport_tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/adapters"
    )
    target_link_libraries(lithe_windows_terminal_transport_tests PRIVATE
        lithe_windows_adapters
    )
    add_test(NAME lithe_windows_terminal_transport COMMAND lithe_windows_terminal_transport_tests)
    add_executable(lithe_windows_workbench_sidebar_tests
        tests/workbench_sidebar_test.cpp
        qt/lithe.qrc
        qt/ui_translation.cpp
        qt/ui_translation.h
        qt/workbench_sidebar.cpp
        qt/workbench_sidebar.h
    )
    target_compile_features(lithe_windows_workbench_sidebar_tests PRIVATE cxx_std_23)
    target_include_directories(lithe_windows_workbench_sidebar_tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/qt"
        "${CMAKE_CURRENT_SOURCE_DIR}/app/persistence"
    )
    target_link_libraries(lithe_windows_workbench_sidebar_tests PRIVATE
        lithe_windows_app
        Qt6::Widgets
    )
    add_test(NAME lithe_windows_workbench_sidebar COMMAND lithe_windows_workbench_sidebar_tests)
    set_tests_properties(lithe_windows_workbench_sidebar PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
    )
    add_executable(lithe_windows_workbench_editor_area_tests
        tests/workbench_editor_area_test.cpp
        qt/workbench_editor_area.cpp
        qt/workbench_editor_area.h
        qt/workbench_code_editor.cpp
        qt/workbench_code_editor.h
    )
    target_compile_features(lithe_windows_workbench_editor_area_tests PRIVATE cxx_std_23)
    target_include_directories(lithe_windows_workbench_editor_area_tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/qt"
        "${CMAKE_CURRENT_SOURCE_DIR}/app/algorithms"
    )
    target_link_libraries(lithe_windows_workbench_editor_area_tests PRIVATE
        lithe_windows_algorithms
        Qt6::Widgets
    )
    add_test(NAME lithe_windows_workbench_editor_area
        COMMAND lithe_windows_workbench_editor_area_tests)
    set_tests_properties(lithe_windows_workbench_editor_area PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
    )
    add_executable(lithe_windows_workbench_code_editor_tests
        tests/workbench_code_editor_test.cpp
        qt/workbench_code_editor.cpp
        qt/workbench_code_editor.h
    )
    target_compile_features(lithe_windows_workbench_code_editor_tests PRIVATE cxx_std_23)
    target_include_directories(lithe_windows_workbench_code_editor_tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/qt"
        "${CMAKE_CURRENT_SOURCE_DIR}/app/algorithms"
    )
    target_link_libraries(lithe_windows_workbench_code_editor_tests PRIVATE
        lithe_windows_algorithms
        Qt6::Widgets
    )
    add_test(NAME lithe_windows_workbench_code_editor
        COMMAND lithe_windows_workbench_code_editor_tests)
    set_tests_properties(lithe_windows_workbench_code_editor PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
    )
    add_executable(lithe_windows_workbench_tool_window_tests
        tests/workbench_tool_window_test.cpp
        qt/lithe.qrc
        qt/ui_translation.cpp
        qt/ui_translation.h
        qt/workbench_tool_window.cpp
        qt/workbench_tool_window.h
    )
    target_compile_features(lithe_windows_workbench_tool_window_tests PRIVATE cxx_std_23)
    target_include_directories(lithe_windows_workbench_tool_window_tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/qt"
        "${CMAKE_CURRENT_SOURCE_DIR}/app/persistence"
    )
    target_link_libraries(lithe_windows_workbench_tool_window_tests PRIVATE
        lithe_windows_app
        Qt6::Widgets
    )
    add_test(NAME lithe_windows_workbench_tool_window
        COMMAND lithe_windows_workbench_tool_window_tests)
    set_tests_properties(lithe_windows_workbench_tool_window PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
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

# Keep assertions enabled for CTest binaries in Release builds so a failed
# expectation reports its source location instead of cascading into UB.
set(LITHE_WINDOWS_TEST_TARGETS
    lithe_windows_phase0_tests
    lithe_windows_algorithms_tests
    lithe_windows_app_tests
    lithe_windows_terminal_feature_tests
    lithe_windows_workspace_write_lifecycle_tests
    lithe_windows_workbench_ui_state_tests
    lithe_windows_workbench_layout_persistence_tests
    lithe_windows_coordinator_tests
    lithe_windows_core_dto_tests
    lithe_windows_persistence_tests
    lithe_windows_runtime_service_tests
    lithe_windows_project_detection_tests
    lithe_windows_java_run_service_tests
    lithe_windows_java_debug_service_tests
    lithe_windows_java_language_server_tests
    lithe_windows_ai_commit_service_tests
    lithe_windows_update_service_tests
)
if(TARGET lithe_windows_core_ping)
    list(APPEND LITHE_WINDOWS_TEST_TARGETS lithe_windows_core_ping)
endif()
if(TARGET lithe_windows_workbench_sidebar_tests)
    list(APPEND LITHE_WINDOWS_TEST_TARGETS lithe_windows_workbench_sidebar_tests)
endif()
if(TARGET lithe_windows_workbench_editor_area_tests)
    list(APPEND LITHE_WINDOWS_TEST_TARGETS lithe_windows_workbench_editor_area_tests)
endif()
if(TARGET lithe_windows_workbench_code_editor_tests)
    list(APPEND LITHE_WINDOWS_TEST_TARGETS lithe_windows_workbench_code_editor_tests)
endif()
if(TARGET lithe_windows_workbench_tool_window_tests)
    list(APPEND LITHE_WINDOWS_TEST_TARGETS lithe_windows_workbench_tool_window_tests)
endif()
if(TARGET lithe_windows_ui_theme_tests)
    list(APPEND LITHE_WINDOWS_TEST_TARGETS lithe_windows_ui_theme_tests)
endif()
if(TARGET lithe_windows_ui_translation_tests)
    list(APPEND LITHE_WINDOWS_TEST_TARGETS lithe_windows_ui_translation_tests)
endif()
if(TARGET lithe_windows_terminal_transport_tests)
    list(APPEND LITHE_WINDOWS_TEST_TARGETS lithe_windows_terminal_transport_tests)
endif()
if(MSVC)
    set(LITHE_UNDEFINE_NDEBUG_FLAG /UNDEBUG)
else()
    set(LITHE_UNDEFINE_NDEBUG_FLAG -UNDEBUG)
endif()
foreach(test_target IN LISTS LITHE_WINDOWS_TEST_TARGETS)
    target_compile_options(${test_target} PRIVATE ${LITHE_UNDEFINE_NDEBUG_FLAG})
endforeach()
