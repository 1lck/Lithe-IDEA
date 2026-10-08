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
java_jdt=false
rust_comments=false
metadata=false
git_validation=false
macos_rollback=false
editor_tests=false

enable_all_validation() {
    editor_tests=true
    swift=true
    plugins=true
    swift_database=true
    rust_core=true
    rust_database=true
    macos_release=true
    windows=true
    windows_rust=true
    java_jdt=true
    git_validation=true
    macos_rollback=true
}

enable_shared_validation() {
    swift=true
    rust_core=true
    windows=true
    windows_rust=true
}

validation_lanes=(swift plugins swift_database rust_core rust_database macos_release windows windows_rust java_jdt rust_comments metadata git_validation macos_rollback editor_tests)
combined_validation=()

record_classification() {
    local index lane selected=""
    # Within an already selected Swift lane, package-sensitive changes also
    # exercise the signed disk-image boundary. Packaging-only lanes retain
    # their own bundle checks without adding a second Swift compilation.
    if [[ "$macos_release" == true && "$swift" == true ]]; then
        macos_rollback=true
    fi
    for index in "${!validation_lanes[@]}"; do
        lane="${validation_lanes[$index]}"
        if [[ "${!lane}" == true ]]; then
            combined_validation[$index]=true
            selected="${selected:+$selected,}$lane"
        fi
    done
    # Keep GitHub output on stdout machine-readable; each path's independent
    # selection goes to the Actions log, including lanes already selected earlier.
    printf 'CI classification: status=%q path=%q destination=%q rule=%s selected=%s\n' \
        "$status" "$first_path" "${second_path:-}" "$rule" "${selected:-none}" >&2
}

classify_path() {
    for lane in "${validation_lanes[@]}"; do
        printf -v "$lane" '%s' false
    done
    rule=product-path
    path="$1"
    first_path="$path"
    lowercase_path="${path,,}"

    case "$lowercase_path" in
        macos/sources/lithe/platform/macos/updates/*|macos/sources/lithe/platform/macos/process/*|macos/sources/lithe/core/ports/processrunner.swift|macos/sources/lithe/views/app/stablerollbackcontrol.swift|macos/sources/lithe/views/app/updatecontrol.swift|macos/tests/lithetests/stablerollback*|macos/tests/lithetests/updatecheckertests.swift|macos/tests/lithetests/testgate.swift|macos/tests/lithetests/testprocess.swift|macos/tests/lithetests/support/*)
            macos_rollback=true
            ;;
    esac

    case "$lowercase_path" in
        .github/workflows/ci-windows.yml|third_party/jdtls/*|third_party/jdk/*|scripts/prepare-jdtls.*|scripts/prepare-jdk.*|rust/lithe-core/src/lsp/interface/*|rust/lithe-core/src/lsp/mod.rs|rust/lithe-core/src/lsp/languages/*)
            java_jdt=true
            ;;
    esac

    case "$lowercase_path" in
        *.md|*.mdx)
            # Text-only documentation still receives git diff validation in the
            # workflow, but does not reserve a macOS or Windows runner.
            rule=documentation
            java_jdt=false
            macos_rollback=false
            ;;
        casks/*|scripts/update-homebrew-cask.rb)
            metadata=true
            rule=release-metadata
            ;;
        scripts/select-windows-ci-tests.mjs|scripts/select-windows-ci-tests.test.ts|scripts/windows-ci-test-suites.json)
            windows=true
            rule=windows-test-selection
            ;;
        scripts/report-ci-tool-tests.mjs|scripts/test-ci-workflows.mjs)
            # Classification jobs run these Node regressions without product builds.
            rule=ci-orchestration-tooling
            ;;
        scripts/classify-ci-changes.sh|scripts/test-classify-ci-changes.sh)
            # A classifier change must exercise every lane that it can select.
            enable_all_validation
            rule=classifier
            ;;
        .github/workflows/ci-macos.yml)
            plugins=true
            swift_database=true
            rust_database=true
            editor_tests=true
            swift=true
            rust_core=true
            macos_release=true
            git_validation=true
            ;;
        .github/workflows/ci-plugins.yml)
            plugins=true
            ;;
        .github/workflows/ci-database.yml)
            swift_database=true
            rust_database=true
            ;;
        .github/workflows/ci-windows.yml)
            editor_tests=true
            windows=true
            windows_rust=true
            ;;
        .github/workflows/release-macos.yml|.github/workflows/release-preview-macos.yml)
            macos_release=true
            ;;
        .github/workflows/release-windows.yml|.github/workflows/release-preview-windows.yml)
            windows=true
            ;;
        .github/actions/prepare-macos-dependency-cache/*|.github/actions/setup-macos-toolchain/*|.swift-version)
            swift=true
            plugins=true
            swift_database=true
            rust_core=true
            macos_release=true
            git_validation=true
            ;;
        .agents/skills/write-stable-tests/scripts/*)
            editor_tests=true
            java_jdt=true
            # Test policy and timing infrastructure can select or reject every
            # product test lane, but does not affect release packaging.
            swift=true
            plugins=true
            swift_database=true
            rust_core=true
            windows=true
            windows_rust=true
            git_validation=true
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
            git_validation=true
            ;;
        frontend/editor/*|package.json|bun.lock|bunfig.toml|scripts/verify-editor-boundaries.mjs)
            editor_tests=true
            # The shared Monaco package feeds both web hosts, not native Rust
            # or the isolated database/plugin modules. macOS packaging owns
            # shared editor tests and the real WebKit probe.
            swift=true
            macos_release=true
            windows=true
            rule=shared-editor
            ;;
        macos/editorfrontend/*|macos/experiments/monaco/*|scripts/build-editor.sh|scripts/package-macos-monaco.sh|scripts/probe-macos-monaco.sh)
            swift=true
            macos_release=true
            rule=macos-editor
            ;;
        scripts/build-windows-php-plugin.ts|scripts/verify-windows-plugin-isolation.mjs)
            # These scripts build and verify browser worker packages; native
            # Rust and the macOS plugin implementation do not consume them.
            windows=true
            rule=windows-worker-plugin
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
        macos/tests/lithetests/nativepluginloadertests.swift|macos/tests/lithetests/pluginmanagementpresentationtests.swift|macos/tests/lithetests/pluginmanagertests.swift|macos/tests/lithetests/pluginpackagestoretests.swift)
            plugins=true
            ;;
        macos/sources/lithe/litheapp.swift|macos/sources/lithe/application/features/pluginmanagement.swift|macos/sources/lithe/core/language/pluginlanguageprovidercatalogsource.swift|macos/sources/lithe/models/appmodel/appmodel+pluginmanagement.swift|macos/sources/lithe/platform/macos/plugins/*|macos/sources/lithe/views/app/pluginmanagementview.swift|macos/sources/lithe/views/workbench/workbenchmoduleuicomposition.swift|macos/sources/litheapplicationkernel/plugins/*|macos/sources/lithemoduleapi/catalog/bundledlanguageplugincatalog.swift|macos/sources/lithemoduleapi/plugins/*)
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
        macos/sources/lithe/core/rust/rustgit*|macos/sources/lithe/core/rust/rustcorebridge+git*)
            swift=true
            macos_release=true
            git_validation=true
            ;;
        macos/sources/lithe/core/rust/*)
            # Swift bridge changes affect the release linkage boundary.
            swift=true
            macos_release=true
            ;;
        macos/sources/lithegitmodule/*|macos/sources/lithe/application/composition/gitmodulecoordinator.swift|macos/sources/lithe/models/appmodel/appmodel+git*|macos/sources/lithe/models/bridges/gitmodulebridges.swift|macos/sources/lithe/platform/macos/storage/macgit*|macos/sources/lithe/views/git/*)
            swift=true
            git_validation=true
            ;;
        macos/sources/*)
            # Swift tests compile the complete Lithe target. Ordinary product
            # source changes do not also need two complete PR installer builds.
            swift=true
            ;;
        macos/resources/*)
            # Resource assembly is observable only in the packaged app, so keep
            # both architecture package checks for these changes.
            swift=true
            macos_release=true
            ;;
        macos/tests/lithegitperformancetests/*|macos/tests/lithegitperformancesupport/*|macos/tests/lithegitperformanceverifier/*|macos/tests/lithetests/gitstatusobservationtests.swift)
            swift=true
            git_validation=true
            ;;
        macos/tests/*)
            swift=true
            ;;
        rust/lithe-core/src/*.rs)
            # Comment-only Rust Core edits use the documentation verifier but
            # skip unit tests and integrated release builds.
            if [[ "$status" == M* ]] && rust_diff_is_comment_only "$path"; then
                rust_comments=true
                java_jdt=false
            else
                rust_core=true
                if [[ "$lowercase_path" != rust/lithe-core/src/tests/* && "$lowercase_path" != */tests.rs && "$lowercase_path" != rust/lithe-core/src/lsp/interface/engine_real_jdt_tests.rs ]]; then
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
        shared/platform-feature-matrix/features/*.json)
            # Only canonical capability records are descriptive data. Unknown
            # names and nested paths retain shared-contract coverage.
            if [[ "$path" =~ ^shared/platform-feature-matrix/features/[a-z0-9]+(-[a-z0-9]+)*\.json$ ]]; then
                rule=feature-record
            else
                enable_shared_validation
                rule=shared-contract
            fi
            ;;
        shared/*)
            # Non-Markdown shared contracts and fixtures are compatibility
            # surfaces consumed by Swift, Rust Core, and the Windows product.
            enable_shared_validation
            rule=shared-contract
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
            git_validation=true
            ;;
        scripts/package-macos-localizations.sh)
            # Localization assembly has Swift regression tests and is shared by
            # release, preview, and performance bundles; it cannot affect Windows.
            swift=true
            macos_release=true
            ;;
        scripts/measure-macos-performance-baseline.sh)
            # The baseline harness assembles a macOS release app, without changing
            # shared Core behavior or the isolated database/plugin test lanes.
            macos_release=true
            ;;
        scripts/verify-official-plugins.sh|scripts/build-official-plugins.sh)
            plugins=true
            ;;
        scripts/verify-rust-core.sh|scripts/verify-rust-core-comments.sh|scripts/verify-rust-core-layout.sh|scripts/build-rust-core.sh|scripts/rustcorebridgeverification.swift)
            rust_core=true
            macos_release=true
            ;;
        scripts/build-ide-mcp.sh|scripts/build-windows-ide-mcp.mjs|scripts/test-ide-mcp.mjs)
            rust_core=true
            macos_release=true
            windows=true
            windows_rust=true
            ;;
        scripts/build-database-mcp.sh|scripts/build-database-sidecar.sh)
            rust_database=true
            macos_release=true
            ;;
        scripts/database-sidecar-smoke.sh|scripts/database-validation-smoke.sh)
            rust_database=true
            ;;
        scripts/*sparkle*|scripts/import-macos-signing.sh|scripts/build-macos.sh|scripts/verify-macos-app-build-safety.sh|scripts/verify-runtime-bundle-immutability.sh|scripts/verify-macos-package.sh|scripts/macos13sdkcompatibility.h|scripts/ld-macos13-compat.sh|scripts/package-app.sh|scripts/preview.sh|scripts/stamp-macos-app-build-info.sh|scripts/create-dmg.sh|scripts/create-macos-update-manifest.rb|scripts/test-macos-update-manifest.rb|scripts/prepare-jdtls.sh|scripts/prepare-jdk.sh)
            macos_release=true
            ;;
        scripts/verify-download-cache.mjs|scripts/test-verify-download-cache.mjs|scripts/reuse-worktree-resources.mjs|scripts/test-reuse-worktree-resources.mjs|scripts/worktree-resources.json)
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
        scripts/build-windows.ps1|scripts/verify-windows-boundaries.ps1|scripts/verify-windows-boundaries.sh|scripts/prepare-jdtls.ps1|scripts/prepare-jdk.ps1|scripts/package-windows.ps1|scripts/install-windows-frontend-dependencies.ps1|scripts/invoke-windows-bun-install.ps1|scripts/windows-frontend-install.test.ts|scripts/invoke-windows-tauri-build.ps1|scripts/create-windows-updater-manifest.ps1|scripts/test-windows-updater-manifest.ps1)
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
            rule=unknown-path
            ;;
    esac
    record_classification
}

while IFS=$'\t' read -r status first_path second_path; do
    original_path="$first_path"
    destination_path="${second_path:-}"
    classify_path "$original_path"
    if [[ "$status" == R* || "$status" == C* ]]; then
        # A move must retain the old owner's validation and validate the new
        # owner too. Unknown endpoints still select all product lanes.
        [[ -n "$destination_path" ]]
        classify_path "$destination_path"
    fi
done < <(git diff --name-status --find-renames "$BASE_REVISION" "$HEAD_REVISION")

for index in "${!validation_lanes[@]}"; do
    printf -v "${validation_lanes[$index]}" '%s' "${combined_validation[$index]:-false}"
done

# Mixed paths can select Swift and packaging independently; their union also
# needs the disk-image integration step in the selected Swift job.
if [[ "$swift" == true && "$macos_release" == true ]]; then
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
