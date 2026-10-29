#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
    printf 'Usage: %s <base-revision> <head-revision>\n' "$0" >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
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
    done < <(git diff --no-color --unified=0 "$BASE_REVISION" "$HEAD_REVISION" -- ":(literal)$path")

    [[ "$saw_change" == true ]]
}

swift=false
plugins=false
rust_core=false
rust_remote=false
macos_release=false
windows=false
windows_rust=false
java_jdt=false
rust_comments=false
metadata=false
git_validation=false

enable_all_validation() {
    swift=true
    plugins=true
    rust_core=true
    rust_remote=true
    macos_release=true
    windows=true
    windows_rust=true
    java_jdt=true
    git_validation=true
}

classify_path() {
    local status="$1"
    local path="$2"
    local lowercase_path="${path,,}"

    case "$lowercase_path" in
        .github/workflows/ci-windows.yml|third_party/jdtls/*|third_party/jdk/*|scripts/macos/prepare/prepare-jdtls.*|scripts/macos/prepare/prepare-jdk.*|scripts/windows/prepare/prepare-jdtls.*|scripts/windows/prepare/prepare-jdk.*|rust/lithe-core/src/lsp/interface/engine.rs|rust/lithe-core/src/lsp/interface/engine_real_jdt_tests.rs|rust/lithe-core/src/lsp/languages/java*|rust/lithe-core/src/lsp/languages/jdt*|windows/*java*)
            java_jdt=true
            ;;
    esac

    case "$lowercase_path" in
        *.md|*.mdx|shared/platform-feature-matrix/*)
            # Text-only documentation still receives git diff validation in the
            # workflow, but does not reserve a macOS or Windows runner. The
            # cross-platform feature matrix is planning data that no product
            # target reads; Verify Platform Feature Matrix validates its schema.
            ;;
        casks/*|scripts/release/macos/update-homebrew-cask.rb)
            metadata=true
            ;;
        scripts/ci/common/classify-ci-changes.sh|scripts/ci/common/test-classify-ci-changes.sh|scripts/ci/common/plan-ci-lane-reuse.mjs|scripts/ci/common/plan-ci-lane-reuse.test.mjs|scripts/ci/common/verify-reused-ci-jobs.mjs|scripts/ci/common/verify-reused-ci-jobs.test.mjs)
            # A classifier change must exercise every lane that it can select.
            enable_all_validation
            ;;
        .github/workflows/ci-macos.yml)
            swift=true
            rust_core=true
            macos_release=true
            git_validation=true
            ;;
        .github/workflows/ci-plugins.yml)
            plugins=true
            ;;
        .github/workflows/ci-remote.yml|scripts/remote/verify-remote-workspace.sh)
            rust_remote=true
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
        .github/actions/prepare-macos-dependency-cache/*|.github/actions/save-macos-cargo-build-cache/*|.github/actions/setup-macos-toolchain/*|.swift-version)
            swift=true
            plugins=true
            rust_core=true
            macos_release=true
            git_validation=true
            ;;
        .agents/skills/write-stable-tests/scripts/*)
            # Test policy and timing infrastructure can select or reject every
            # product test lane, but does not affect release packaging.
            swift=true
            plugins=true
            rust_core=true
            rust_remote=true
            windows=true
            windows_rust=true
            git_validation=true
            ;;
        .github/*|docs/*|.agents/*|.idea/*|.gitignore|license)
            ;;
        package.swift|package.resolved)
            # SwiftPM graph changes can affect the main and plugin suites even
            # when no source path changes.
            swift=true
            plugins=true
            macos_release=true
            git_validation=true
            ;;
        plugins/mac/*)
            # Official declarative manifests are validated by the Rust Core
            # contract tests as well as by the packaged plugin lane.
            plugins=true
            rust_core=true
            ;;
        macos/tests/litheofficialpluginverifier/*)
            plugins=true
            ;;
        plugins/win/*)
            # Windows plugin packages may contain frontend and native host code.
            # Until their per-language layout is narrower, validate both lanes.
            windows=true
            windows_rust=true
            ;;
        macos/tests/lithetests/declarativeplugintestsupport.swift|macos/tests/lithetests/pluginlocaldevelopmenttests.swift|macos/tests/lithetests/pluginmanagementpresentationtests.swift|macos/tests/lithetests/pluginmanagertests.swift|macos/tests/lithetests/pluginpackagestoretests.swift)
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
        macos/sources/lithe/models/appmodel/appmodel.swift)
            # The app model composes every workbench feature, so a change is
            # also verified in the packaged app.
            swift=true
            macos_release=true
            ;;
        macos/sources/lithe/platform/macos/macservicecontainer.swift)
            # The service container composes the plugin runtime dependencies.
            swift=true
            plugins=true
            macos_release=true
            ;;
        macos/sources/lithe/views/workbench/workbenchview.swift)
            # The root workbench composes plugin-owned UI.
            # Plugin tests cover plugin models and packages rather than this
            # view, and it is edited by most workbench pull requests, so the
            # Swift lane's full compile covers it without the plugin runner.
            swift=true
            macos_release=true
            ;;
        macos/sources/lithemoduleapi/*|macos/sources/litheapplicationkernel/*|macos/sources/lithecorecontracts/*)
            # These contracts and runtime primitives are direct dependencies of
            # both the main and the plugin Swift suites.
            swift=true
            plugins=true
            macos_release=true
            ;;
        macos/sources/lithelanguageintelligencemodule/*)
            # Go support is an official plugin and depends on this runtime.
            swift=true
            plugins=true
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
            rust_remote=true
            macos_release=true
            windows=true
            windows_rust=true
            ;;
        rust/lithe-remote/*)
            # Core links the client/protocol; the dedicated Linux lane also
            # exercises host adapters that macOS runners cannot execute.
            rust_core=true
            rust_remote=true
            macos_release=true
            windows=true
            windows_rust=true
            ;;
        rust/*)
            # Unknown Rust workspace paths fail closed across all Rust-backed
            # products because workspace configuration can affect every crate.
            rust_core=true
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
        frontend/editor/*|package.json|bun.lock)
            # The shared Monaco editor and the Bun workspace are consumed by the
            # macOS package (Bun tests and the WebKit workbench probe run in the
            # package lane) and by the Windows frontend lane. Swift, Rust, and
            # JDT lanes do not read them.
            macos_release=true
            windows=true
            ;;
        windows/tauri/src-tauri/*.rs|windows/tauri/src-tauri/cargo.toml|windows/tauri/src-tauri/cargo.lock|windows/tauri/crates/*)
            windows=true
            windows_rust=true
            ;;
        windows/*)
            windows=true
            ;;
        scripts/macos/test/test-macos.sh|scripts/macos/perf/test-git-performance-baseline.sh|scripts/macos/perf/run-git-performance-verifier.mjs)
            swift=true
            plugins=true
            git_validation=true
            ;;
        scripts/macos/package/package-macos-localizations.sh)
            # Localization assembly has Swift regression tests and is shared by
            # release, preview, and performance bundles; it cannot affect Windows.
            swift=true
            macos_release=true
            ;;
        scripts/macos/perf/measure-macos-performance-baseline.sh)
            # The baseline harness assembles a macOS release app, without changing
            # shared Core behavior or the isolated plugin test lane.
            macos_release=true
            ;;
        scripts/plugins/verify-official-plugins.sh|scripts/plugins/build-official-plugins.sh)
            plugins=true
            ;;
        scripts/rust-core/verify-rust-core.sh|scripts/rust-core/verify-rust-core-crates.sh|scripts/rust-core/verify-rust-core-swift-bridge.sh|scripts/rust-core/verify-rust-core-comments.sh|scripts/rust-core/verify-rust-core-layout.sh|scripts/rust-core/build-rust-core.sh|scripts/rust-core/rustcorebridgeverification.swift)
            rust_core=true
            macos_release=true
            ;;
        scripts/ide-mcp/build-ide-mcp.sh|scripts/ide-mcp/build-windows-ide-mcp.mjs|scripts/ide-mcp/test-ide-mcp.mjs)
            rust_core=true
            macos_release=true
            windows=true
            windows_rust=true
            ;;
        scripts/release/sparkle/*sparkle*|scripts/macos/package/*sparkle*|scripts/release/macos/import-macos-signing.sh|scripts/macos/build/build-macos.sh|scripts/macos/verify/verify-macos-app-build-safety.sh|scripts/macos/verify/verify-runtime-bundle-immutability.sh|scripts/macos/verify/verify-macos-package.sh|scripts/macos/build/macos13sdkcompatibility.h|scripts/macos/build/ld-macos13-compat.sh|scripts/macos/package/package-app.sh|scripts/macos/build/preview.sh|scripts/macos/package/stamp-macos-app-build-info.sh|scripts/macos/package/create-dmg.sh|scripts/release/macos/create-macos-update-manifest.rb|scripts/release/macos/test-macos-update-manifest.rb|scripts/macos/prepare/prepare-jdtls.sh|scripts/macos/prepare/prepare-jdk.sh)
            macos_release=true
            ;;
        scripts/resources/verify-download-cache.mjs|scripts/resources/test-verify-download-cache.mjs|scripts/resources/reuse-worktree-resources.mjs|scripts/resources/test-reuse-worktree-resources.mjs|scripts/resources/worktree-resources.json)
            swift=true
            plugins=true
            rust_core=true
            macos_release=true
            windows=true
            windows_rust=true
            ;;
        scripts/windows/prepare/validate-windows-build-caches.ps1|scripts/windows/build/invoke-cargo-with-cache-fallback.ps1)
            windows=true
            windows_rust=true
            ;;
        scripts/macos/prepare/validate-macos-dependency-caches.sh|scripts/macos/prepare/prepare-macos-dependencies.sh)
            swift=true
            plugins=true
            rust_core=true
            macos_release=true
            ;;
        scripts/windows/build/build-windows.ps1|scripts/windows/verify/verify-windows-boundaries.ps1|scripts/windows/verify/verify-windows-boundaries.sh|scripts/windows/prepare/prepare-jdtls.ps1|scripts/windows/prepare/prepare-jdk.ps1|scripts/windows/package/package-windows.ps1|scripts/windows/build/install-windows-frontend-dependencies.ps1|scripts/windows/build/invoke-windows-bun-install.ps1|scripts/windows/test/windows-frontend-install.test.ts|scripts/windows/build/invoke-windows-tauri-build.ps1|scripts/release/windows/create-windows-updater-manifest.ps1|scripts/release/windows/test-windows-updater-manifest.ps1)
            windows=true
            ;;
        scripts/prepare-lithe-pr-review.mjs|scripts/test-prepare-lithe-pr-review.mjs|scripts/run-lithe-codex-with-timeout.sh|scripts/ci/update-repo-charts/update-repo-charts.py)
            ;;
        *)
            # New or unclassified repository areas are validated conservatively
            # until their ownership is made explicit above.
            enable_all_validation
            ;;
    esac
}

# LITHE_CI_ONLY_PATHS names a file with one repository path per line. When set,
# only diff entries touching one of those paths are classified; the lane-reuse
# planner uses it to classify a pull request's own new changes between two of
# its revisions while ignoring changes that arrived from the base branch.
only_paths_file="${LITHE_CI_ONLY_PATHS:-}"
if [[ -n "$only_paths_file" && ! -f "$only_paths_file" ]]; then
    printf 'LITHE_CI_ONLY_PATHS does not name a file: %s\n' "$only_paths_file" >&2
    exit 2
fi
path_selected() {
    [[ -z "$only_paths_file" ]] && return 0
    grep -Fxq -- "$1" "$only_paths_file"
}

# NUL-separated output keeps every path raw: the default text output quotes
# and escapes non-ASCII paths such as Chinese file names, which would then
# miss both the path patterns below and the LITHE_CI_ONLY_PATHS filter.
while IFS= read -r -d '' status; do
    IFS= read -r -d '' first_path
    second_path=""
    if [[ "$status" == R* || "$status" == C* ]]; then
        IFS= read -r -d '' second_path
    fi
    if [[ -n "$only_paths_file" ]] && ! path_selected "$first_path" && ! { [[ -n "$second_path" ]] && path_selected "$second_path"; }; then
        continue
    fi
    if [[ "$status" == R* || "$status" == C* ]]; then
        # Renames and copies can cross ownership boundaries, so both endpoints
        # select their own lanes. Neither side is a comment-only modification.
        classify_path "$status" "$first_path"
        classify_path "$status" "$second_path"
    else
        classify_path "$status" "$first_path"
    fi
done < <(git diff -z --name-status --find-renames "$BASE_REVISION" "$HEAD_REVISION")

if [[ "${LITHE_CI_DRAFT_PULL_REQUEST:-false}" == "true" ]]; then
    # Draft pull requests keep the Linux-only lanes but defer every macOS and
    # Windows runner lane. The organization shares five macOS runners, so
    # iterative draft pushes would otherwise queue every ready pull request.
    # Marking the pull request ready for review triggers a full classification.
    swift=false
    plugins=false
    rust_core=false
    macos_release=false
    windows=false
    windows_rust=false
    java_jdt=false
    git_validation=false
fi

# Note: .agents/notes/implemented/process/2026-09-13-ci-build-cache-and-artifact-strategy.md
# Pull requests into preview carry the full verification. Afterwards only what
# a pull request cannot observe still runs: the post-merge push builds the
# universal package (pull requests build arm64 only), which also compiles the
# merged combination of pull requests. Promoting preview to main reruns
# nothing, because the same commit already passed on preview.
ci_scope="${LITHE_CI_SCOPE:-pull_request}"
case "$ci_scope" in
    pull_request) ;;
    post_merge)
        package_affected=false
        for lane in "$swift" "$plugins" "$rust_core" "$macos_release"; do
            if [[ "$lane" == true ]]; then package_affected=true; fi
        done
        swift=false
        plugins=false
        rust_core=false
        rust_remote=false
        macos_release="$package_affected"
        windows=false
        windows_rust=false
        java_jdt=false
        rust_comments=false
        metadata=false
        git_validation=false
        ;;
    release_promotion)
        swift=false
        plugins=false
        rust_core=false
        rust_remote=false
        macos_release=false
        windows=false
        windows_rust=false
        java_jdt=false
        rust_comments=false
        metadata=false
        git_validation=false
        ;;
    *)
        printf '%s\n' "LITHE_CI_SCOPE must be pull_request, post_merge, or release_promotion" >&2
        exit 2
        ;;
esac

printf 'swift=%s\n' "$swift"
printf 'plugins=%s\n' "$plugins"
printf 'rust_core=%s\n' "$rust_core"
printf 'rust_remote=%s\n' "$rust_remote"
printf 'macos_release=%s\n' "$macos_release"
printf 'windows=%s\n' "$windows"
printf 'windows_rust=%s\n' "$windows_rust"
printf 'java_jdt=%s\n' "$java_jdt"
printf 'rust_comments=%s\n' "$rust_comments"
printf 'metadata=%s\n' "$metadata"
printf 'git_validation=%s\n' "$git_validation"
printf 'ci_scope=%s\n' "$ci_scope"
