#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
    printf 'Usage: %s <base-revision> <head-revision>\n' "$0" >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BASE_REVISION="$1"
HEAD_REVISION="$2"
cd "$ROOT_DIR"

git cat-file -e "${BASE_REVISION}^{commit}"
git cat-file -e "${HEAD_REVISION}^{commit}"

rust_diff_is_comment_only() {
    local path="$1"
    local in_hunk=false
    local saw_change=false
    local line content

    while IFS= read -r line; do
        if [[ "$line" == @@* ]]; then
            in_hunk=true
            continue
        fi
        if [[ "$in_hunk" == true && ( "$line" == +* || "$line" == -* ) ]]; then
            saw_change=true
            content="${line:1}"
            if [[ ! "$content" =~ ^[[:space:]]*(//.*)?$ ]]; then
                return 1
            fi
        fi
    done < <(git diff --no-color --unified=0 "$BASE_REVISION" "$HEAD_REVISION" -- "$path")

    [[ "$saw_change" == true ]]
}

swift=false
plugins=false
swift_database=false
rust_core=false
rust_database=false
macos_release=false
windows=false
windows_rust=false
rust_comments=false
metadata=false

enable_all_validation() {
    swift=true
    plugins=true
    swift_database=true
    rust_core=true
    rust_database=true
    macos_release=true
    windows=true
    windows_rust=true
}

while IFS=$'\t' read -r status first_path _; do
    if [[ "$status" == R* || "$status" == C* ]]; then
        # Renames and copies can cross ownership boundaries, so classify them
        # conservatively instead of trusting only the destination extension.
        enable_all_validation
        break
    fi

    path="$first_path"
    lowercase_path="${path,,}"

    case "$lowercase_path" in
        *.md|*.mdx)
            # Text-only documentation still receives git diff validation in the
            # workflow, but does not reserve a macOS or Windows runner.
            ;;
        casks/*|scripts/update-homebrew-cask.rb)
            metadata=true
            ;;
        scripts/classify-ci-changes.sh|scripts/test-classify-ci-changes.sh)
            # A classifier change must exercise every lane that it can select.
            enable_all_validation
            ;;
        .github/workflows/ci-macos.yml)
            swift=true
            rust_core=true
            macos_release=true
            ;;
        .github/workflows/ci-plugins.yml)
            plugins=true
            ;;
        .github/workflows/ci-database.yml)
            swift_database=true
            rust_database=true
            ;;
        .github/workflows/ci-windows.yml)
            windows=true
            windows_rust=true
            ;;
        .github/workflows/release-macos.yml|.github/workflows/release-preview-macos.yml)
            macos_release=true
            ;;
        .github/workflows/release-windows.yml|.github/workflows/release-preview-windows.yml)
            windows=true
            ;;
        .github/actions/prepare-macos-dependency-cache/*)
            swift=true
            plugins=true
            swift_database=true
            rust_core=true
            macos_release=true
            ;;
        .agents/skills/write-stable-tests/scripts/*)
            # Test policy and timing infrastructure can select or reject every
            # product test lane, but does not affect release packaging.
            swift=true
            plugins=true
            swift_database=true
            rust_core=true
            windows=true
            windows_rust=true
            ;;
        .github/*|docs/*|.agents/*|.idea/*|.gitignore|license)
            ;;
        package.swift|package.resolved)
            # SwiftPM graph changes can affect the main suite and both isolated
            # module suites even when no source path changes.
            swift=true
            plugins=true
            swift_database=true
            macos_release=true
            ;;
        plugins/mac/*|macos/tests/litheofficialpluginverifier/*)
            plugins=true
            ;;
        plugins/win/*)
            # Windows plugin packages may contain frontend and native host code.
            # Until their per-language layout is narrower, validate both lanes.
            windows=true
            windows_rust=true
            ;;
        macos/tests/lithetests/nativepluginloadertests.swift|macos/tests/lithetests/pluginmanagementpresentationtests.swift|macos/tests/lithetests/pluginmanagertests.swift|macos/tests/lithetests/pluginpackagestoretests.swift|macos/tests/lithetests/linuxdoanonymouswebsessiontests.swift|macos/tests/lithetests/linuxdocommunityformattingtests.swift|macos/tests/lithetests/macexternalauthorizationcallbackroutertests.swift|macos/tests/lithetests/webkitintegrationtests.swift)
            plugins=true
            ;;
        macos/sources/lithe/litheapp.swift|macos/sources/lithe/application/features/pluginmanagement.swift|macos/sources/lithe/core/language/pluginlanguageprovidercatalogsource.swift|macos/sources/lithe/models/appmodel/appmodel+pluginmanagement.swift|macos/sources/lithe/platform/macos/community/*|macos/sources/lithe/platform/macos/plugins/*|macos/sources/lithe/views/app/pluginmanagementview.swift|macos/sources/lithe/views/community/*|macos/sources/lithe/views/workbench/workbenchmoduleuicomposition.swift|macos/sources/litheapplicationkernel/plugins/*|macos/sources/lithemoduleapi/catalog/bundledlanguageplugincatalog.swift|macos/sources/lithemoduleapi/plugins/*)
            # Host-side plugin APIs are product code, while their focused
            # behavior is owned by the plugin lane.
            swift=true
            plugins=true
            macos_release=true
            ;;
        macos/tests/litheapplicationkerneltests/moduleruntimetests.swift|macos/tests/lithelanguageintelligencemoduletests/languageintelligencemoduletests.swift|macos/tests/lithetests/applocalizationtests.swift)
            swift=true
            plugins=true
            ;;
        macos/sources/lithedatabasemodule/*|macos/tests/lithedatabasemoduletests/*)
            swift_database=true
            if [[ "$lowercase_path" == macos/sources/* ]]; then
                macos_release=true
            fi
            ;;
        macos/sources/lithe/platform/macos/persistence/macdatabaserecoverystore.swift|macos/sources/lithe/platform/macos/process/macdatabasesidecarlocator.swift|macos/sources/lithe/platform/macos/storage/macdatabaseadapters.swift|macos/sources/lithe/theme/databasebrandicon.swift|macos/sources/lithe/views/database/*|macos/resources/databaseicons/*)
            swift_database=true
            macos_release=true
            ;;
        macos/sources/lithe/models/appmodel/appmodel.swift)
            # This is a shared app composition point for the database module.
            swift=true
            swift_database=true
            macos_release=true
            ;;
        macos/sources/lithe/platform/macos/macservicecontainer.swift)
            # The service container composes both database and plugin runtime dependencies.
            swift=true
            plugins=true
            swift_database=true
            macos_release=true
            ;;
        macos/sources/lithe/views/workbench/workbenchview.swift)
            # The root workbench composes both database and plugin-owned UI.
            swift=true
            plugins=true
            swift_database=true
            macos_release=true
            ;;
        macos/sources/lithemoduleapi/catalog/builtinmodulecatalog.swift)
            swift=true
            plugins=true
            swift_database=true
            macos_release=true
            ;;
        macos/sources/lithemoduleapi/*|macos/sources/litheapplicationkernel/*|macos/sources/lithecorecontracts/*)
            # These contracts and runtime primitives are direct dependencies of
            # both isolated Swift module suites.
            swift=true
            plugins=true
            swift_database=true
            macos_release=true
            ;;
        macos/sources/lithelanguageintelligencemodule/*)
            # Go support is an official plugin and depends on this runtime.
            swift=true
            plugins=true
            macos_release=true
            ;;
        macos/tests/lithetests/lithecorelogictests.swift)
            # This legacy mixed suite still contains the database integration
            # tests; both filtered lanes must run until the suite is separated.
            swift=true
            swift_database=true
            ;;
        macos/resources/*.lproj/*)
            # Localization files contain both database and plugin-facing copy.
            swift=true
            plugins=true
            swift_database=true
            macos_release=true
            ;;
        macos/sources/litherustcore/*)
            rust_core=true
            swift=true
            macos_release=true
            ;;
        macos/sources/*|macos/resources/*)
            swift=true
            macos_release=true
            ;;
        macos/tests/*)
            swift=true
            ;;
        rust/lithe-core/src/*.rs)
            # Comment-only Rust Core edits use the documentation verifier but
            # skip unit tests and integrated release builds.
            if [[ "$status" == M* ]] && rust_diff_is_comment_only "$path"; then
                rust_comments=true
            else
                rust_core=true
                if [[ "$lowercase_path" != rust/lithe-core/src/tests/* && "$lowercase_path" != */tests.rs ]]; then
                    macos_release=true
                    windows=true
                    windows_rust=true
                fi
            fi
            ;;
        rust/lithe-core/tests/*)
            rust_core=true
            ;;
        rust/lithe-core/cargo.toml|rust/lithe-core/include/*)
            rust_core=true
            macos_release=true
            windows=true
            windows_rust=true
            ;;
        rust/cargo.toml|rust/cargo.lock)
            rust_core=true
            rust_database=true
            macos_release=true
            windows=true
            windows_rust=true
            ;;
        rust/lithe-db-mcp/*|rust/lithe-db-sidecar/*)
            rust_database=true
            # Database helpers are shipped as macOS executables, so Linux crate
            # tests are not sufficient to validate their production target.
            macos_release=true
            ;;
        rust/*)
            # Unknown Rust workspace paths fail closed across all Rust-backed
            # products because workspace configuration can affect every crate.
            rust_core=true
            rust_database=true
            macos_release=true
            windows=true
            windows_rust=true
            ;;
        shared/*)
            # Non-Markdown shared contracts and fixtures are compatibility
            # surfaces consumed by Swift, Rust Core, and the Windows product.
            swift=true
            rust_core=true
            windows=true
            windows_rust=true
            ;;
        windows/tauri/src-tauri/*.rs|windows/tauri/src-tauri/cargo.toml|windows/tauri/src-tauri/cargo.lock|windows/tauri/crates/*)
            windows=true
            windows_rust=true
            ;;
        windows/*)
            windows=true
            ;;
        scripts/test-macos.sh|scripts/test-git-performance-baseline.sh|scripts/run-git-performance-verifier.mjs)
            swift=true
            plugins=true
            swift_database=true
            ;;
        scripts/verify-official-plugins.sh|scripts/build-official-plugins.sh)
            plugins=true
            ;;
        scripts/verify-rust-core.sh|scripts/verify-rust-core-comments.sh|scripts/verify-rust-core-layout.sh|scripts/build-rust-core.sh|scripts/rustcorebridgeverification.swift)
            rust_core=true
            macos_release=true
            ;;
        scripts/build-database-mcp.sh|scripts/build-database-sidecar.sh)
            rust_database=true
            macos_release=true
            ;;
        scripts/database-sidecar-smoke.sh|scripts/database-validation-smoke.sh)
            rust_database=true
            ;;
        scripts/build-macos.sh|scripts/verify-macos-app-build-safety.sh|scripts/verify-macos-package.sh|scripts/macos13sdkcompatibility.h|scripts/ld-macos13-compat.sh|scripts/package-app.sh|scripts/preview.sh|scripts/stamp-macos-app-build-info.sh|scripts/create-dmg.sh|scripts/create-macos-update-manifest.rb|scripts/test-macos-update-manifest.rb|scripts/prepare-jdtls.sh|scripts/prepare-jdk.sh)
            macos_release=true
            ;;
        scripts/verify-download-cache.mjs|scripts/test-verify-download-cache.mjs)
            swift=true
            plugins=true
            swift_database=true
            rust_core=true
            macos_release=true
            windows=true
            windows_rust=true
            ;;
        scripts/validate-windows-build-caches.ps1|scripts/invoke-cargo-with-cache-fallback.ps1)
            windows=true
            windows_rust=true
            ;;
        scripts/validate-macos-dependency-caches.sh|scripts/prepare-macos-dependencies.sh)
            swift=true
            plugins=true
            swift_database=true
            rust_core=true
            macos_release=true
            ;;
        scripts/build-windows.ps1|scripts/verify-windows-boundaries.ps1|scripts/verify-windows-boundaries.sh|scripts/prepare-jdtls.ps1|scripts/prepare-jdk.ps1|scripts/package-windows.ps1|scripts/install-windows-frontend-dependencies.ps1|scripts/invoke-windows-tauri-build.ps1|scripts/create-windows-updater-manifest.ps1|scripts/test-windows-updater-manifest.ps1)
            windows=true
            ;;
        scripts/prepare-lithe-pr-review.mjs|scripts/test-prepare-lithe-pr-review.mjs|scripts/run-lithe-codex-with-timeout.sh|scripts/update-repo-charts.py)
            ;;
        infra/docker/*)
            rust_database=true
            ;;
        *)
            # New or unclassified repository areas are validated conservatively
            # until their ownership is made explicit above.
            enable_all_validation
            ;;
    esac
done < <(git diff --name-status --find-renames "$BASE_REVISION" "$HEAD_REVISION")

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
