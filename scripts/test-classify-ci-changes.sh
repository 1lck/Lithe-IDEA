#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/scripts"
cp "$ROOT_DIR/scripts/classify-ci-changes.sh" "$TEST_ROOT/scripts/"
cd "$TEST_ROOT"

git init -q
git config user.email "ci@example.invalid"
git config user.name "CI Test"
mkdir -p \
    Casks \
    Plugins/mac/Official/GoSupport \
    Plugins/win/ExampleSupport \
    macos/Sources/Lithe/Platform/MacOS/Plugins \
    macos/Sources/Lithe/Views/Community \
    macos/Sources/Lithe/Views/Database \
    macos/Sources/LitheCoreContracts \
    macos/Sources/LitheDatabaseModule \
    Plugins/mac/Official/GoSupport/Sources/LitheGoSupportModule \
    macos/Tests/LitheDatabaseModuleTests \
    Plugins/mac/Official/GoSupport/Tests/LitheGoSupportModuleTests \
    macos/Tests/LitheTests \
    infra/docker/database-validation \
    rust/lithe-core/src/tests \
    rust/lithe-core/src/lsp \
    rust/lithe-core/tests \
    rust/lithe-db-sidecar/src \
    shared/fixtures/core \
    windows/tauri/src \
    windows/tauri/src-tauri/src
printf '%s\n' '//! Test module.' 'pub fn value() -> u8 { 1 }' > rust/lithe-core/src/lib.rs
printf '%s\n' '#[test]' 'fn source_test() { assert_eq!(1, 1); }' > rust/lithe-core/src/lsp/tests.rs
printf '%s\n' '#[test]' 'fn value_is_one() { assert_eq!(1, 1); }' > rust/lithe-core/tests/value.rs
printf '%s\n' 'fn main() {}' > rust/lithe-db-sidecar/src/main.rs
printf '%s\n' 'services: {}' > infra/docker/database-validation/compose.yaml
printf '%s\n' '#!/bin/zsh' 'print -- package' > scripts/verify-macos-package.sh
printf '%s\n' 'struct App {}' > macos/Sources/Lithe/App.swift
printf '%s\n' 'struct PluginManager {}' > macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginManager.swift
printf '%s\n' 'struct LinuxDoCommunityView {}' > macos/Sources/Lithe/Views/Community/LinuxDoCommunityView.swift
printf '%s\n' 'struct DatabaseView {}' > macos/Sources/Lithe/Views/Database/DatabaseView.swift
printf '%s\n' 'struct CoreContracts {}' > macos/Sources/LitheCoreContracts/CoreContracts.swift
printf '%s\n' 'struct DatabaseModule {}' > macos/Sources/LitheDatabaseModule/DatabaseModule.swift
printf '%s\n' 'struct GoSupportModule {}' > Plugins/mac/Official/GoSupport/Sources/LitheGoSupportModule/GoSupportModule.swift
printf '%s\n' 'struct AppTests {}' > macos/Tests/LitheTests/AppTests.swift
printf '%s\n' 'struct PluginManagerTests {}' > macos/Tests/LitheTests/PluginManagerTests.swift
printf '%s\n' 'struct LinuxDoCommunityFormattingTests {}' > macos/Tests/LitheTests/LinuxDoCommunityFormattingTests.swift
printf '%s\n' 'struct WebKitIntegrationTests {}' > macos/Tests/LitheTests/WebKitIntegrationTests.swift
printf '%s\n' 'struct LitheCoreLogicTests {}' > macos/Tests/LitheTests/LitheCoreLogicTests.swift
printf '%s\n' 'struct DatabaseTests {}' > macos/Tests/LitheDatabaseModuleTests/DatabaseTests.swift
printf '%s\n' 'struct GoSupportTests {}' > Plugins/mac/Official/GoSupport/Tests/LitheGoSupportModuleTests/GoSupportTests.swift
printf '%s\n' '{"id":"dev.lithe.go-support"}' > Plugins/mac/Official/GoSupport/plugin.json
printf '%s\n' '{"id":"dev.lithe.win.example-support"}' > Plugins/win/ExampleSupport/plugin.json
printf '%s\n' '{"operation":"test"}' > shared/fixtures/core/test.json
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

    printf 'swift=%s\n' "$swift"
    printf 'plugins=%s\n' "$plugins"
    printf 'swift_database=%s\n' "$swift_database"
    printf 'rust_core=%s\n' "$rust_core"
    printf 'rust_database=%s\n' "$rust_database"
    printf 'macos_release=%s\n' "$macos_release"
    printf 'windows=%s\n' "$windows"
    printf 'windows_rust=%s\n' "$windows_rust"
    printf 'rust_comments=%s\n' "$rust_comments"
    printf 'metadata=%s\n' "$metadata"
}

assert_classification() {
    local name="$1"
    local expected="$2"
    shift 2

    git reset --hard -q "$BASE_REVISION"
    git clean -fdq
    "$@"
    git add .
    git commit -q -m "$name"

    local actual
    actual="$(scripts/classify-ci-changes.sh "$BASE_REVISION" HEAD)"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Classifier case %s failed:\nExpected:\n%s\nActual:\n%s\n' \
            "$name" "$expected" "$actual" >&2
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
modify_swift_source() { printf '%s\n' 'struct UpdatedApp {}' > macos/Sources/Lithe/App.swift; }
modify_swift_test() { printf '%s\n' 'struct UpdatedAppTests {}' > macos/Tests/LitheTests/AppTests.swift; }
modify_plugin_manifest() { printf '%s\n' '{"id":"dev.lithe.go-support","version":"2.0.0"}' > Plugins/mac/Official/GoSupport/plugin.json; }
modify_plugin_source() { printf '%s\n' 'struct UpdatedGoSupportModule {}' > Plugins/mac/Official/GoSupport/Sources/LitheGoSupportModule/GoSupportModule.swift; }
modify_plugin_test() { printf '%s\n' 'struct UpdatedGoSupportTests {}' > Plugins/mac/Official/GoSupport/Tests/LitheGoSupportModuleTests/GoSupportTests.swift; }
modify_windows_plugin_manifest() { printf '%s\n' '{"id":"dev.lithe.win.example-support","version":"2.0.0"}' > Plugins/win/ExampleSupport/plugin.json; }
modify_plugin_host_source() { printf '%s\n' 'struct UpdatedPluginManager {}' > macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginManager.swift; }
modify_plugin_host_test() { printf '%s\n' 'struct UpdatedPluginManagerTests {}' > macos/Tests/LitheTests/PluginManagerTests.swift; }
modify_linux_do_source() { printf '%s\n' 'struct UpdatedLinuxDoCommunityView {}' > macos/Sources/Lithe/Views/Community/LinuxDoCommunityView.swift; }
modify_linux_do_test() { printf '%s\n' 'struct UpdatedLinuxDoCommunityFormattingTests {}' > macos/Tests/LitheTests/LinuxDoCommunityFormattingTests.swift; }
modify_plugin_webkit_test() { printf '%s\n' 'struct UpdatedWebKitIntegrationTests {}' > macos/Tests/LitheTests/WebKitIntegrationTests.swift; }
modify_shared_swift_contract() { printf '%s\n' 'struct UpdatedCoreContracts {}' > macos/Sources/LitheCoreContracts/CoreContracts.swift; }
modify_database_swift() { printf '%s\n' 'struct UpdatedDatabaseModule {}' > macos/Sources/LitheDatabaseModule/DatabaseModule.swift; }
modify_database_swift_test() { printf '%s\n' 'struct UpdatedDatabaseTests {}' > macos/Tests/LitheDatabaseModuleTests/DatabaseTests.swift; }
modify_database_app_source() { printf '%s\n' 'struct UpdatedDatabaseView {}' > macos/Sources/Lithe/Views/Database/DatabaseView.swift; }
modify_mixed_core_logic_test() { printf '%s\n' 'struct UpdatedLitheCoreLogicTests {}' > macos/Tests/LitheTests/LitheCoreLogicTests.swift; }
modify_shared_fixture() { printf '%s\n' '{"operation":"updated"}' > shared/fixtures/core/test.json; }
modify_windows_frontend() { printf '%s\n' 'export const value = 2;' > windows/tauri/src/value.ts; }
modify_windows_rust() { printf '%s\n' 'fn main() { println!("updated"); }' > windows/tauri/src-tauri/src/main.rs; }
modify_download_cache_validator() { printf '%s\n' 'console.log("updated");' > scripts/verify-download-cache.mjs; }
modify_macos_cache_action() {
    mkdir -p .github/actions/prepare-macos-dependency-cache
    printf '%s\n' 'name: updated' > .github/actions/prepare-macos-dependency-cache/action.yml
}
modify_metadata() { printf '%s\n' 'cask "lithe" do' '  version "1.0.0"' 'end' > Casks/lithe.rb; }
modify_classifier() { printf '%s\n' '# classifier test change' >> scripts/classify-ci-changes.sh; }
modify_swift_and_database() {
    modify_swift_source
    modify_database_swift
}
rename_rust_to_markdown() {
    mkdir -p docs
    git mv rust/lithe-core/src/lib.rs docs/lib.md
}

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
    "$(classification true false false false false true false false false false)" \
    modify_swift_source
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
assert_classification linux-do-source \
    "$(classification true true false false false true false false false false)" \
    modify_linux_do_source
assert_classification linux-do-test \
    "$(classification false true false false false false false false false false)" \
    modify_linux_do_test
assert_classification plugin-webkit-test \
    "$(classification false true false false false false false false false false)" \
    modify_plugin_webkit_test
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
assert_classification download-cache-validator \
    "$(classification true true true true false true true true false false)" \
    modify_download_cache_validator
assert_classification macos-cache-action \
    "$(classification true true true true false true false false false false)" \
    modify_macos_cache_action
assert_classification metadata \
    "$(classification false false false false false false false false false true)" \
    modify_metadata
assert_classification classifier \
    "$(classification true true true true true true true true false false)" \
    modify_classifier
assert_classification rename-rust-to-markdown \
    "$(classification true true true true true true true true false false)" \
    rename_rust_to_markdown

printf '%s\n' 'CI change classifier tests passed'
