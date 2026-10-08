#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
if (( $# > 1 )); then
    printf 'Usage: %s [case-name]\n' "$0" >&2
    exit 2
fi
TEST_CASE="${1:-}"
cases_run=0
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/scripts"
cp "$ROOT_DIR/scripts/classify-ci-changes.sh" "$TEST_ROOT/scripts/"
cd "$TEST_ROOT"

git init -q
git config user.email "ci@example.invalid"
git config user.name "CI Test"
git config commit.gpgsign false
mkdir -p \
    Casks \
    Plugins/mac/Official/GoSupport \
    Plugins/win/ExampleSupport \
    macos/Sources/Lithe/Platform/MacOS/Plugins \
    macos/Sources/Lithe/Views/Community \
    macos/Sources/Lithe/Views/Database \
    macos/Sources/Lithe/Core/Rust \
    macos/Sources/LitheCoreContracts \
    macos/Sources/LitheDatabaseModule \
    Plugins/mac/Official/GoSupport/Sources/LitheGoSupportModule \
    macos/Tests/LitheDatabaseModuleTests \
    Plugins/mac/Official/GoSupport/Tests/LitheGoSupportModuleTests \
    macos/Tests/LitheTests \
    macos/Sources/LitheGitModule \
    macos/Tests/LitheGitPerformanceTests \
    infra/docker/database-validation \
    rust/lithe-core/src/tests \
    rust/lithe-core/src/lsp/languages \
    rust/lithe-core/tests \
    rust/lithe-db-sidecar/src \
    shared/fixtures/core \
    shared/platform-feature-matrix/features \
    windows/tauri/src \
    windows/tauri/src-tauri/src
printf '%s\n' '//! Test module.' 'pub fn value() -> u8 { 1 }' > rust/lithe-core/src/lib.rs
printf '%s\n' '#[test]' 'fn source_test() { assert_eq!(1, 1); }' > rust/lithe-core/src/lsp/tests.rs
printf '%s\n' 'pub fn normalize() {}' > rust/lithe-core/src/lsp/languages/java_tests.rs
printf '%s\n' '#[test]' 'fn value_is_one() { assert_eq!(1, 1); }' > rust/lithe-core/tests/value.rs
printf '%s\n' 'fn main() {}' > rust/lithe-db-sidecar/src/main.rs
printf '%s\n' 'services: {}' > infra/docker/database-validation/compose.yaml
printf '%s\n' '#!/bin/zsh' 'print -- package' > scripts/verify-macos-package.sh
printf '%s\n' 'struct App {}' > macos/Sources/Lithe/App.swift
printf '%s\n' 'struct RustCoreBridge {}' > macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift
printf '%s\n' 'struct PluginManager {}' > macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginManager.swift
printf '%s\n' 'struct DatabaseView {}' > macos/Sources/Lithe/Views/Database/DatabaseView.swift
printf '%s\n' 'struct CoreContracts {}' > macos/Sources/LitheCoreContracts/CoreContracts.swift
printf '%s\n' 'struct DatabaseModule {}' > macos/Sources/LitheDatabaseModule/DatabaseModule.swift
printf '%s\n' 'struct GoSupportModule {}' > Plugins/mac/Official/GoSupport/Sources/LitheGoSupportModule/GoSupportModule.swift
printf '%s\n' 'struct AppTests {}' > macos/Tests/LitheTests/AppTests.swift
printf '%s\n' 'struct GitFeature {}' > macos/Sources/LitheGitModule/GitFeature.swift
printf '%s\n' 'struct GitPerformanceTests {}' > macos/Tests/LitheGitPerformanceTests/GitPerformanceTests.swift
printf '%s\n' 'struct PluginManagerTests {}' > macos/Tests/LitheTests/PluginManagerTests.swift
printf '%s\n' 'struct LitheCoreLogicTests {}' > macos/Tests/LitheTests/LitheCoreLogicTests.swift
printf '%s\n' 'struct DatabaseTests {}' > macos/Tests/LitheDatabaseModuleTests/DatabaseTests.swift
printf '%s\n' 'struct GoSupportTests {}' > Plugins/mac/Official/GoSupport/Tests/LitheGoSupportModuleTests/GoSupportTests.swift
printf '%s\n' '{"id":"dev.lithe.go-support"}' > Plugins/mac/Official/GoSupport/plugin.json
printf '%s\n' '{"id":"dev.lithe.win.example-support"}' > Plugins/win/ExampleSupport/plugin.json
printf '%s\n' '{"operation":"test"}' > shared/fixtures/core/test.json
printf '%s\n' '{"id":"sample","capability":"Sample"}' > shared/platform-feature-matrix/features/sample.json
printf '%s\n' '{"schemaVersion":4}' > shared/platform-feature-matrix/metadata.json
printf '%s\n' 'export const value = 1;' > windows/tauri/src/value.ts
printf '%s\n' 'fn main() {}' > windows/tauri/src-tauri/src/main.rs
printf '%s\n' '# Test' > README.md
printf '%s\n' 'cask "lithe" do' 'end' > Casks/lithe.rb
git add .
git commit -q -m base
BASE_REVISION="$(git rev-parse HEAD)"

classification() {
    local swift="$1"
    local plugins="$2"
    local swift_database="$3"
    local rust_core="$4"
    local rust_database="$5"
    local macos_release="$6"
    local windows="$7"
    local windows_rust="$8"
    local rust_comments="$9"
    local metadata="${10}"
    local git_validation="${11:-false}"
    local java_jdt="${12:-false}"
    local macos_rollback="${13:-false}"
    local editor_tests="${14:-false}"
    if [[ $# -lt 13 && "$swift" == true && "$macos_release" == true ]]; then
        macos_rollback=true
    fi

    printf 'swift=%s\n' "$swift"
    printf 'plugins=%s\n' "$plugins"
    printf 'swift_database=%s\n' "$swift_database"
    printf 'rust_core=%s\n' "$rust_core"
    printf 'rust_database=%s\n' "$rust_database"
    printf 'macos_release=%s\n' "$macos_release"
    printf 'windows=%s\n' "$windows"
    printf 'windows_rust=%s\n' "$windows_rust"
    printf 'java_jdt=%s\n' "$java_jdt"
    printf 'rust_comments=%s\n' "$rust_comments"
    printf 'metadata=%s\n' "$metadata"
    printf 'git_validation=%s\n' "$git_validation"
    printf 'macos_rollback=%s\n' "$macos_rollback"
    printf 'editor_tests=%s\n' "$editor_tests"
}

assert_classification() {
    local name="$1"
    local expected="$2"
    shift 2

    if [[ -n "$TEST_CASE" && "$TEST_CASE" != "$name" ]]; then
        return
    fi
    cases_run=$((cases_run + 1))
    git reset --hard -q "$BASE_REVISION"
    git clean -fdq
    "$@"
    git add .
    git commit -q -m "$name"

    local actual
    actual="$(scripts/classify-ci-changes.sh "$BASE_REVISION" HEAD 2> "$TEST_ROOT/classification.log")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Classifier case %s failed:\nExpected:\n%s\nActual:\n%s\n' \
            "$name" "$expected" "$actual" >&2
        exit 1
    fi
    if ! [[ -s "$TEST_ROOT/classification.log" ]]; then
        printf 'Classifier case %s produced no path diagnostics\n' "$name" >&2
        exit 1
    fi
}

modify_readme() { printf '%s\n' '# Updated' > README.md; }
modify_rust_comment() { printf '%s\n' '//! Updated test module.' 'pub fn value() -> u8 { 1 }' > rust/lithe-core/src/lib.rs; }
modify_rust_code() { printf '%s\n' '//! Test module.' 'pub fn value() -> u8 { 2 }' > rust/lithe-core/src/lib.rs; }
modify_rust_test() { printf '%s\n' '#[test]' 'fn value_is_two() { assert_eq!(2, 2); }' > rust/lithe-core/tests/value.rs; }
modify_rust_source_test() { printf '%s\n' '#[test]' 'fn source_test() { assert_eq!(2, 2); }' > rust/lithe-core/src/lsp/tests.rs; }
modify_database_rust() { printf '%s\n' 'fn main() { println!("updated"); }' > rust/lithe-db-sidecar/src/main.rs; }
modify_database_docker() { printf '%s\n' 'services:' '  mariadb: {}' > infra/docker/database-validation/compose.yaml; }
modify_macos_package_verifier() { printf '%s\n' '#!/bin/zsh' 'print -- updated-package' > scripts/verify-macos-package.sh; }
modify_localization_packaging() { printf '%s\n' '#!/bin/zsh' 'print -- localizations' > scripts/package-macos-localizations.sh; }
modify_macos_performance_baseline() { printf '%s\n' '#!/bin/zsh' 'print -- baseline' > scripts/measure-macos-performance-baseline.sh; }
modify_unknown_script() { printf '%s\n' '#!/bin/zsh' 'print -- unknown' > scripts/unclassified-fixture.sh; }
modify_swift_source() { printf '%s\n' 'struct UpdatedApp {}' > macos/Sources/Lithe/App.swift; }
modify_swift_bridge() { printf '%s\n' 'struct UpdatedRustCoreBridge {}' > macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift; }
modify_git_source() { printf '%s\n' 'struct UpdatedGitFeature {}' > macos/Sources/LitheGitModule/GitFeature.swift; }
modify_git_performance_test() { printf '%s\n' 'struct UpdatedGitPerformanceTests {}' > macos/Tests/LitheGitPerformanceTests/GitPerformanceTests.swift; }
modify_swift_test() { printf '%s\n' 'struct UpdatedAppTests {}' > macos/Tests/LitheTests/AppTests.swift; }
modify_plugin_manifest() { printf '%s\n' '{"id":"dev.lithe.go-support","version":"2.0.0"}' > Plugins/mac/Official/GoSupport/plugin.json; }
modify_plugin_source() { printf '%s\n' 'struct UpdatedGoSupportModule {}' > Plugins/mac/Official/GoSupport/Sources/LitheGoSupportModule/GoSupportModule.swift; }
modify_plugin_test() { printf '%s\n' 'struct UpdatedGoSupportTests {}' > Plugins/mac/Official/GoSupport/Tests/LitheGoSupportModuleTests/GoSupportTests.swift; }
modify_windows_plugin_manifest() { printf '%s\n' '{"id":"dev.lithe.win.example-support","version":"2.0.0"}' > Plugins/win/ExampleSupport/plugin.json; }
modify_plugin_host_source() { printf '%s\n' 'struct UpdatedPluginManager {}' > macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginManager.swift; }
modify_plugin_host_test() { printf '%s\n' 'struct UpdatedPluginManagerTests {}' > macos/Tests/LitheTests/PluginManagerTests.swift; }
modify_shared_swift_contract() { printf '%s\n' 'struct UpdatedCoreContracts {}' > macos/Sources/LitheCoreContracts/CoreContracts.swift; }
modify_database_swift() { printf '%s\n' 'struct UpdatedDatabaseModule {}' > macos/Sources/LitheDatabaseModule/DatabaseModule.swift; }
modify_database_swift_test() { printf '%s\n' 'struct UpdatedDatabaseTests {}' > macos/Tests/LitheDatabaseModuleTests/DatabaseTests.swift; }
modify_database_app_source() { printf '%s\n' 'struct UpdatedDatabaseView {}' > macos/Sources/Lithe/Views/Database/DatabaseView.swift; }
modify_mixed_core_logic_test() { printf '%s\n' 'struct UpdatedLitheCoreLogicTests {}' > macos/Tests/LitheTests/LitheCoreLogicTests.swift; }
modify_shared_fixture() { printf '%s\n' '{"operation":"updated"}' > shared/fixtures/core/test.json; }
modify_windows_frontend() { printf '%s\n' 'export const value = 2;' > windows/tauri/src/value.ts; }
modify_windows_rust() { printf '%s\n' 'fn main() { println!("updated"); }' > windows/tauri/src-tauri/src/main.rs; }
modify_download_cache_validator() { printf '%s\n' 'console.log("updated");' > scripts/verify-download-cache.mjs; }
modify_worktree_resource_registry() { printf '%s\n' '{"schemaVersion":1,"resources":[]}' > scripts/worktree-resources.json; }
modify_test_stability_runner() {
    mkdir -p .agents/skills/write-stable-tests/scripts
    printf '%s\n' '#!/bin/zsh' 'print -- test-stability' > .agents/skills/write-stable-tests/scripts/test-stability-macos.sh
}
modify_macos_cache_action() {
    mkdir -p .github/actions/prepare-macos-dependency-cache
    printf '%s\n' 'name: updated' > .github/actions/prepare-macos-dependency-cache/action.yml
}
modify_metadata() { printf '%s\n' 'cask "lithe" do' '  version "1.0.0"' 'end' > Casks/lithe.rb; }
modify_classifier() { printf '%s\n' '# classifier test change' >> scripts/classify-ci-changes.sh; }
modify_java_jdt() { printf '%s\n' 'pub fn normalize() { let _ = 1; }' > rust/lithe-core/src/lsp/languages/java_tests.rs; }
modify_swift_and_database() {
    modify_swift_source
    modify_database_swift
}
rename_rust_to_markdown() {
    mkdir -p docs
    git mv rust/lithe-core/src/lib.rs docs/lib.md
}
modify_feature_record() { printf '%s\n' '{"id":"sample","capability":"Updated"}' > shared/platform-feature-matrix/features/sample.json; }
add_feature_record() { printf '%s\n' '{"id":"another"}' > shared/platform-feature-matrix/features/another.json; }
delete_feature_record() { rm shared/platform-feature-matrix/features/sample.json; }
modify_feature_metadata() { printf '%s\n' '{"schemaVersion":5}' > shared/platform-feature-matrix/metadata.json; }
modify_nested_feature_record() {
    mkdir -p shared/platform-feature-matrix/features/nested
    printf '%s\n' '{}' > shared/platform-feature-matrix/features/nested/sample.json
}
modify_unknown_shared_path() { printf '%s\n' '{}' > shared/unknown.json; }
modify_swift_and_feature_record() { modify_swift_source; modify_feature_record; }
modify_windows_and_feature_record() { modify_windows_frontend; modify_feature_record; }
modify_rust_and_feature_record() { modify_rust_code; modify_feature_record; }
modify_fixture_and_feature_record() { modify_shared_fixture; modify_feature_record; }
rename_feature_record() { git mv shared/platform-feature-matrix/features/sample.json shared/platform-feature-matrix/features/renamed.json; }
rename_feature_to_fixture() { git mv shared/platform-feature-matrix/features/sample.json shared/fixtures/core/sample.json; }
rename_fixture_to_feature() { git mv shared/fixtures/core/test.json shared/platform-feature-matrix/features/test.json; }
delete_shared_fixture() { rm shared/fixtures/core/test.json; }
modify_shared_editor() {
    mkdir -p frontend/editor/src
    printf '%s\n' 'export const value = 1;' > frontend/editor/src/source-text.ts
}
modify_macos_editor() {
    mkdir -p macos/EditorFrontend
    printf '%s\n' 'export const value = 1;' > macos/EditorFrontend/context-menu.ts
}
modify_editor_build() { printf '%s\n' '#!/bin/zsh' 'print -- editor' > scripts/build-editor.sh; }
modify_editor_boundary_verifier() { printf '%s\n' 'console.log("editor");' > scripts/verify-editor-boundaries.mjs; }
modify_web_workspace() { printf '%s\n' '{"workspaces":["frontend/editor","windows/tauri"]}' > package.json; }
modify_bun_lock() { printf '%s\n' '{"lockfileVersion":1}' > bun.lock; }
modify_bun_config() { printf '%s\n' '[install]' 'linker="isolated"' > bunfig.toml; }
modify_windows_worker_build() { printf '%s\n' 'console.log("worker");' > scripts/build-windows-php-plugin.ts; }
modify_windows_worker_verifier() { printf '%s\n' 'console.log("worker");' > scripts/verify-windows-plugin-isolation.mjs; }
modify_unknown_frontend() {
    mkdir -p frontend/unknown
    printf '%s\n' 'export const value = 1;' > frontend/unknown/value.ts
}
modify_update_source() {
    mkdir -p macos/Sources/Lithe/Platform/MacOS/Updates
    printf '%s\n' 'struct UpdateChecker {}' > macos/Sources/Lithe/Platform/MacOS/Updates/UpdateChecker.swift
}
modify_process_runner() {
    mkdir -p macos/Sources/Lithe/Platform/MacOS/Process
    printf '%s\n' 'struct ProcessRunner {}' > macos/Sources/Lithe/Platform/MacOS/Process/MacProcessRunner.swift
}
modify_rollback_test() { printf '%s\n' 'struct StableRollbackTests {}' > macos/Tests/LitheTests/StableRollbackTests.swift; }
modify_shared_test_gate() { printf '%s\n' 'struct TestGate {}' > macos/Tests/LitheTests/TestGate.swift; }
modify_editor_and_rust() { modify_shared_editor; modify_rust_code; }
modify_editor_and_database() { modify_shared_editor; modify_database_swift; }

assert_classification shared-editor \
    "$(classification true false false false false true true false false false false false true true)" modify_shared_editor
assert_classification macos-editor \
    "$(classification true false false false false true false false false false)" modify_macos_editor
assert_classification editor-build \
    "$(classification true false false false false true false false false false)" modify_editor_build
assert_classification editor-boundary-verifier \
    "$(classification true false false false false true true false false false false false true true)" modify_editor_boundary_verifier
assert_classification web-workspace \
    "$(classification true false false false false true true false false false false false true true)" modify_web_workspace
assert_classification bun-lock \
    "$(classification true false false false false true true false false false false false true true)" modify_bun_lock
assert_classification bun-config \
    "$(classification true false false false false true true false false false false false true true)" modify_bun_config
assert_classification windows-worker-build \
    "$(classification false false false false false false true false false false)" modify_windows_worker_build
assert_classification windows-worker-verifier \
    "$(classification false false false false false false true false false false)" modify_windows_worker_verifier
assert_classification unknown-frontend \
    "$(classification true true true true true true true true false false true true true true)" modify_unknown_frontend
assert_classification update-source \
    "$(classification true false false false false false false false false false false false true)" modify_update_source
assert_classification process-runner \
    "$(classification true false false false false false false false false false false false true)" modify_process_runner
assert_classification rollback-test \
    "$(classification true false false false false false false false false false false false true)" modify_rollback_test
assert_classification shared-test-gate \
    "$(classification true false false false false false false false false false false false true)" modify_shared_test_gate
assert_classification editor-and-rust \
    "$(classification true false false true false true true true false false false false true true)" modify_editor_and_rust
assert_classification editor-and-database \
    "$(classification true false true false false true true false false false false false true true)" modify_editor_and_database

assert_classification feature-record \
    "$(classification false false false false false false false false false false)" modify_feature_record
assert_classification add-feature-record \
    "$(classification false false false false false false false false false false)" add_feature_record
assert_classification delete-feature-record \
    "$(classification false false false false false false false false false false)" delete_feature_record
assert_classification feature-metadata \
    "$(classification true false false true false false true true false false)" modify_feature_metadata
assert_classification nested-feature-record \
    "$(classification true false false true false false true true false false)" modify_nested_feature_record
assert_classification unknown-shared-path \
    "$(classification true false false true false false true true false false)" modify_unknown_shared_path
assert_classification swift-and-feature-record \
    "$(classification true false false false false false false false false false)" modify_swift_and_feature_record
assert_classification windows-and-feature-record \
    "$(classification false false false false false false true false false false)" modify_windows_and_feature_record
assert_classification rust-and-feature-record \
    "$(classification false false false true false true true true false false)" modify_rust_and_feature_record
assert_classification fixture-and-feature-record \
    "$(classification true false false true false false true true false false)" modify_fixture_and_feature_record
assert_classification rename-feature-record \
    "$(classification false false false false false false false false false false)" rename_feature_record
assert_classification rename-feature-to-fixture \
    "$(classification true false false true false false true true false false)" rename_feature_to_fixture
assert_classification rename-fixture-to-feature \
    "$(classification true false false true false false true true false false)" rename_fixture_to_feature
assert_classification delete-shared-fixture \
    "$(classification true false false true false false true true false false)" delete_shared_fixture

assert_classification readme \
    "$(classification false false false false false false false false false false)" \
    modify_readme
assert_classification rust-comment \
    "$(classification false false false false false false false false true false)" \
    modify_rust_comment
assert_classification rust-code \
    "$(classification false false false true false true true true false false)" \
    modify_rust_code
assert_classification rust-test \
    "$(classification false false false true false false false false false false)" \
    modify_rust_test
assert_classification rust-source-test \
    "$(classification false false false true false false false false false false)" \
    modify_rust_source_test
assert_classification database-rust \
    "$(classification false false false false true true false false false false)" \
    modify_database_rust
assert_classification database-docker \
    "$(classification false false false false true false false false false false)" \
    modify_database_docker
assert_classification macos-package-verifier \
    "$(classification false false false false false true false false false false)" \
    modify_macos_package_verifier
assert_classification swift-source \
    "$(classification true false false false false false false false false false)" \
    modify_swift_source
assert_classification swift-bridge \
    "$(classification true false false false false true false false false false)" \
    modify_swift_bridge
assert_classification git-source \
    "$(classification true false false false false false false false false false true)" \
    modify_git_source
assert_classification git-performance-test \
    "$(classification true false false false false false false false false false true)" \
    modify_git_performance_test
assert_classification localization-packaging \
    "$(classification true false false false false true false false false false)" \
    modify_localization_packaging
assert_classification macos-performance-baseline \
    "$(classification false false false false false true false false false false)" \
    modify_macos_performance_baseline
assert_classification unknown-script \
    "$(classification true true true true true true true true false false true true true true)" \
    modify_unknown_script
assert_classification swift-test \
    "$(classification true false false false false false false false false false)" \
    modify_swift_test
assert_classification plugin-manifest \
    "$(classification false true false false false false false false false false)" \
    modify_plugin_manifest
assert_classification plugin-source \
    "$(classification false true false false false false false false false false)" \
    modify_plugin_source
assert_classification plugin-test \
    "$(classification false true false false false false false false false false)" \
    modify_plugin_test
assert_classification windows-plugin-manifest \
    "$(classification false false false false false false true true false false)" \
    modify_windows_plugin_manifest
assert_classification plugin-host-source \
    "$(classification true true false false false true false false false false)" \
    modify_plugin_host_source
assert_classification plugin-host-test \
    "$(classification false true false false false false false false false false)" \
    modify_plugin_host_test
assert_classification shared-swift-contract \
    "$(classification true true true false false true false false false false)" \
    modify_shared_swift_contract
assert_classification database-swift \
    "$(classification false false true false false true false false false false)" \
    modify_database_swift
assert_classification database-swift-test \
    "$(classification false false true false false false false false false false)" \
    modify_database_swift_test
assert_classification database-app-source \
    "$(classification false false true false false true false false false false)" \
    modify_database_app_source
assert_classification mixed-core-logic-test \
    "$(classification true false true false false false false false false false)" \
    modify_mixed_core_logic_test
assert_classification swift-and-database \
    "$(classification true false true false false true false false false false)" \
    modify_swift_and_database
assert_classification shared-fixture \
    "$(classification true false false true false false true true false false)" \
    modify_shared_fixture
assert_classification windows-frontend \
    "$(classification false false false false false false true false false false)" \
    modify_windows_frontend
assert_classification windows-rust \
    "$(classification false false false false false false true true false false)" \
    modify_windows_rust
assert_classification java-jdt \
    "$(classification false false false true false true true true false false false true)" \
    modify_java_jdt
assert_classification download-cache-validator \
    "$(classification true true true true false true true true false false)" \
    modify_download_cache_validator
assert_classification worktree-resource-registry \
    "$(classification true true true true false true true true false false)" \
    modify_worktree_resource_registry
assert_classification test-stability-runner \
    "$(classification true true true true false false true true false false true true false true)" \
    modify_test_stability_runner
modify_swift_version() { printf '%s\n' '6.3.3' > .swift-version; }
modify_macos_toolchain_action() {
    mkdir -p .github/actions/setup-macos-toolchain
    printf '%s\n' 'name: Toolchain fixture' > .github/actions/setup-macos-toolchain/action.yml
}
assert_classification swift-version \
    "$(classification true true true true false true false false false false true)" \
    modify_swift_version
assert_classification macos-toolchain-action \
    "$(classification true true true true false true false false false false true)" \
    modify_macos_toolchain_action
assert_classification macos-cache-action \
    "$(classification true true true true false true false false false false true)" \
    modify_macos_cache_action
assert_classification metadata \
    "$(classification false false false false false false false false false true)" \
    modify_metadata
assert_classification classifier \
    "$(classification true true true true true true true true false false true true true true)" \
    modify_classifier
assert_classification rename-rust-to-markdown \
    "$(classification false false false true false true true true false false)" \
    rename_rust_to_markdown


modify_windows_java_view() {
    mkdir -p windows/tauri/src/features/editor/components
    printf '%s\n' 'export const value = 1;' > windows/tauri/src/features/editor/components/java-view.tsx
}
modify_macos_java_view() {
    mkdir -p macos/Sources/Lithe/Views/Community
    printf '%s\n' 'struct JavaView {}' > macos/Sources/Lithe/Views/Community/JavaView.swift
}
modify_java_documentation() {
    mkdir -p macos/Sources/Lithe/Platform/MacOS/Process
    printf '%s\n' '# Process notes' > macos/Sources/Lithe/Platform/MacOS/Process/README.md
    mkdir -p windows/tauri/java
    printf '%s\n' '# Java usage' > windows/tauri/java/README.md
}
modify_jdt_transport() {
    mkdir -p rust/lithe-core/src/lsp/interface
    printf '%s\n' '//! Transport boundary.' 'pub fn connect() {}' > rust/lithe-core/src/lsp/interface/transport.rs
}
modify_real_jdt_test() {
    mkdir -p rust/lithe-core/src/lsp/interface
    printf '%s\n' '#[test]' 'fn real_jdt_test() {}' > rust/lithe-core/src/lsp/interface/engine_real_jdt_tests.rs
}
modify_java_comment() {
    printf '%s\n' '// Java normalization.' 'pub fn normalize() {}' > rust/lithe-core/src/lsp/languages/java_tests.rs
}
rename_swift_source() { git mv macos/Sources/Lithe/App.swift macos/Sources/Lithe/RenamedApp.swift; }
rename_windows_to_swift() { git mv windows/tauri/src/value.ts macos/Sources/Lithe/Moved.swift; }
rename_to_unknown() { git mv macos/Sources/Lithe/App.swift unknown-source.swift; }
modify_macos_ci() {
    mkdir -p .github/workflows
    printf '%s\n' 'name: macOS CI' > .github/workflows/ci-macos.yml
}
assert_classification windows-java-view \
    "$(classification false false false false false false true false false false)" modify_windows_java_view
assert_classification macos-java-view \
    "$(classification true false false false false false false false false false)" modify_macos_java_view
assert_classification java-documentation \
    "$(classification false false false false false false false false false false)" modify_java_documentation
assert_classification jdt-transport \
    "$(classification false false false true false true true true false false false true)" modify_jdt_transport
assert_classification real-jdt-test \
    "$(classification false false false true false false false false false false false true)" modify_real_jdt_test
assert_classification java-comment \
    "$(classification false false false false false false false false true false)" modify_java_comment
assert_classification rename-swift-source \
    "$(classification true false false false false false false false false false)" rename_swift_source
assert_classification rename-windows-to-swift \
    "$(classification true false false false false false true false false false)" rename_windows_to_swift
assert_classification rename-to-unknown \
    "$(classification true true true true true true true true false false true true true true)" rename_to_unknown
assert_classification macos-ci \
    "$(classification true true true true true true false false false false true false true true)" modify_macos_ci

modify_windows_selector() { printf '%s\n' 'export const version = 1;' > scripts/select-windows-ci-tests.mjs; }
modify_windows_selector_test() { printf '%s\n' 'export const version = 1;' > scripts/select-windows-ci-tests.test.ts; }
modify_windows_suite_registry() { printf '%s\n' '{}' > scripts/windows-ci-test-suites.json; }
modify_ci_reporter() { printf '%s\n' 'export const version = 1;' > scripts/report-ci-tool-tests.mjs; }
modify_ci_orchestration_test() { printf '%s\n' 'export const version = 1;' > scripts/test-ci-workflows.mjs; }
assert_classification windows-selector \
    "$(classification false false false false false false true false false false)" modify_windows_selector
assert_classification windows-selector-test \
    "$(classification false false false false false false true false false false)" modify_windows_selector_test
assert_classification windows-suite-registry \
    "$(classification false false false false false false true false false false)" modify_windows_suite_registry
assert_classification ci-report-tool \
    "$(classification false false false false false false false false false false)" modify_ci_reporter
assert_classification ci-orchestration-test \
    "$(classification false false false false false false false false false false)" modify_ci_orchestration_test

if (( cases_run == 0 )); then
    printf 'Unknown classifier test case: %s\n' "$TEST_CASE" >&2
    exit 2
fi
printf 'CI change classifier tests passed (%s cases)\n' "$cases_run"
