# CI builds and test downloads

CI 构建缓存、架构并行、测试产物和 artifact 保留策略见
[`2026-09-13-ci-build-cache-and-artifact-strategy.md`](../.agents/notes/implemented/process/2026-09-13-ci-build-cache-and-artifact-strategy.md)。
本文只保留 CI 使用说明、下载方式和历史观测。

macOS CI uploads complete test packages when its package lane is selected.
Ordinary macOS Swift source changes run the complete Swift test lane without
also building two installers. Resource, dependency, toolchain, Rust bridge,
packaging, and other bundle-sensitive changes still select the package lane.
Windows PR CI runs frontend and Rust validation concurrently and does not build
an installer; Windows installers come from preview and stable release workflows.

- macOS PRs selected for package verification produce separate Apple Silicon
  (`arm64`) and Intel (`x86_64`) DMGs. The two jobs run concurrently when
  runners are available.
- macOS pushes to `main` and manual runs verify the default universal package,
  then assemble a universal DMG with the real Java tools using the same compiled
  outputs. The packaging smoke test's temporary Java fixtures are never uploaded.
- Windows preview and stable releases produce an NSIS `.exe` installer.
  Packaging performs the Release build and frontend type check once; there is
  no preceding `--no-bundle` build.
- Each package includes a SHA-256 checksum and the bundled Java tools. macOS
  apps are ad-hoc signed; Windows release workflows use Authenticode when a
  certificate is configured.
- Artifact links require GitHub sign-in and expire after 14 days. Downloading
  an artifact gives a ZIP containing the installer and checksum. The archive
  uses compression level 0 because DMGs and NSIS installers are already compressed.

The summary records the exact checked-out revision. For a pull request this is
normally GitHub's test merge commit. Check **macOS CI gate** or **Windows CI
gate** for the combined test result. A failed architecture still fails the
macOS gate; `fail-fast: false` lets the other architecture finish and upload its
package. To request a Windows installer for a branch, manually run **Release
Windows Preview** and provide that branch as `source_branch`.

The GitHub CLI can also download a particular run's packages:

```bash
gh run download <run-id> --repo 1lck/Lithe-IDEA --pattern 'Lithe-macos-*'
```

Rolling previews also have public, stable download URLs after publication:

- [Apple Silicon preview DMG](https://github.com/1lck/Lithe-IDEA/releases/download/preview-0.3.0/Lithe-0.3.0-arm64.dmg)
- [Intel preview DMG](https://github.com/1lck/Lithe-IDEA/releases/download/preview-0.3.0/Lithe-0.3.0-x86_64.dmg)
- [Windows x64 preview installer](https://github.com/1lck/Lithe-IDEA/releases/download/preview-0.3.0/Lithe-0.3.0-windows-x64.exe)

These URLs follow the current `PREVIEW_TAG` and `PREVIEW_VERSION` in the preview
workflows. They identify the latest published preview, rather than an arbitrary
PR. macOS preview jobs additionally expose their own artifact links before the
combined rolling Release publishes.

## Build time and caches

The September 12, 2026 investigation found two separate sources of delay:

| Observed run | Total elapsed | Main cost |
| --- | --- | --- |
| [macOS CI 34677881176](https://github.com/1lck/Lithe-IDEA/actions/runs/34677881176) | 37m 25s | Universal packaging 34m 37s; Swift tests ran concurrently and finished in about 10m |
| [macOS CI 34667794413](https://github.com/1lck/Lithe-IDEA/actions/runs/34667794413) | 43m 52s | Packaging job started about 10m after the run began, then ran for about 34m |
| [macOS Preview 34577516401](https://github.com/1lck/Lithe-IDEA/actions/runs/34577516401) | 54m 03s | Intel job started about 32m after source preparation, then ran for about 20m |

The first CI run compiled the Swift product twice (about 11m 27s and 9m 54s)
and spent another 12m compiling Rust Core and database helpers. Download caches
were already hitting, but macOS had no cache for compiled Rust dependencies.

The macOS package CI and preview workflows now cache Cargo fingerprints, build
script outputs, and dependency outputs for both `rust/target/macos` (Core) and
`rust/target` (database helpers). Keys include runner architecture, compiler,
Xcode/SDK/macOS versions, build flags, dependency manifests, and build scripts.
An architecture-specific job can restore the universal cache from its base
branch. Final executables are not cached; Cargo still runs before packaging.
An interrupted cache restore is discarded, leaving the existing verified
download cache as the fallback. Swift compilation products are not cached.

The change classifier also keeps Git performance and Git status observation
tests scoped to Git production code, their dedicated tests, and test-tooling
changes. The main Swift suite still compiles the complete Lithe target for
ordinary product changes; this removes unrelated specialty-test and installer
work without weakening compilation coverage.

Cold builds, compiler changes, and dependency changes still require compilation.
PR concurrency shortens the serial build path without promising the same
reduction in total runner minutes. It also needs two available macOS runners.
GitHub queue delays remain outside these build steps. Compare warm-cache runs
with these baselines before claiming a measured improvement. A runner pool
change should be evaluated separately if queueing continues to dominate.

### 独立工作树的本地编译

Git worktree 只共享 Git 对象，不共享各自的 `.artifacts` 目录。如果从一个
工作树单独创建另一个工作树进行编译，优先复用原工作树已经下载或构建完成的
资源，避免重复等待网络下载和资源准备。

在新工作树根目录运行资源复用脚本，并通过 `--source` 指向已有缓存的同仓库
工作树：

```bash
node scripts/reuse-worktree-resources.mjs --source /path/to/existing-worktree
```

脚本默认处理注册表中的全部资源，也可以重复传入 `--resource` 只处理指定资源：

```bash
node scripts/reuse-worktree-resources.mjs \
  --source /path/to/existing-worktree \
  --resource cargo \
  --resource jdtls \
  --resource jdk
```

`node scripts/reuse-worktree-resources.mjs --list` 可以查看当前注册资源。脚本只允许
同一 Git 仓库的 linked worktree 互相复用资源，不修改源工作树。它先把源资源
复制到目标工作树的临时目录，按照对应的 manifest、lockfile 或完整性清单校验，
再原子替换目标目录并进行第二次校验。目标已有不少于源缓存的有效文件时会保留
目标，不重复复制；校验失败的文件不会发布到目标缓存。

JDTLS 和 JDK 使用
[`third_party/jdtls/manifest.json`](../third_party/jdtls/manifest.json) 与
[`third_party/jdk/manifest.json`](../third_party/jdk/manifest.json) 中的
SHA-256；Cargo、SwiftPM 和 Bun 使用各自的 lockfile、版本与完整性清单。当前
自动复用的资源由 [`scripts/worktree-resources.json`](../scripts/worktree-resources.json)
统一注册：

- `.artifacts/cargo-home/registry/cache/`：Cargo crate 下载归档；按所有相关
  `Cargo.lock` 中的 checksum 校验。
- `.artifacts/swiftpm-cache/`：SwiftPM 依赖仓库；按 `Package.resolved`、
  `.swift-version` 和 `.lithe-integrity.json` 校验。
- `.artifacts/bun-cache/`：Bun 下载缓存；按 `bun.lock`、Bun 版本和缓存完整性
  清单校验。
- `.artifacts/jdtls-downloads/`：JDTLS、Lombok、Java Debug/Test 和 license。
- `.artifacts/jdk-downloads/`：各平台与架构的 bundled JDK 下载归档。

以下目录不应直接复制或跨工作树共享：

- `.artifacts/bun-tmp/`、下载或解压过程中的临时目录；
- `.artifacts/jdtls/`、`.artifacts/jdk-*` 等可以由已验证下载重新生成的解压输出；
- `.artifacts/editor/macos/` 和官方插件等尚未写入构建身份 stamp 的生成资源；
- `.build` 中的 SwiftPM 构建状态；
- `rust/target/` 中与当前源码、编译器或构建参数绑定的构建输出；
- LSP workspace `-data`、运行时数据库、测试报告和其他会被进程修改的状态。

PHP 插件包在 `.build/<triple>/<configuration>/OfficialPlugins` 中独立构建，绑定宿主 API、Swift 工具链、架构和签名，通过 `LitheOfficialPluginVerifier` 验证；无可靠 identity stamp，不跨工作树复制。PHPUnit 测试夹具的 `shared/fixtures/phpunit-project/vendor` 也由当前工作树独立安装。应用缓存下 `language-tools/<language>/<tool>` 是插件拥有的可变运行时资源，随插件卸载清理，不是构建缓存。以上项目在资源清单 `excludedResources` 中明确排除，复用脚本会拒绝显式复制请求。

如果后续新增可复用资源，必须同步更新注册表、校验器、脚本测试和本节说明。
生成资源只有在构建流程写入可验证的源码、配置、平台、架构和工具链 identity
stamp 后才能加入注册表，不能仅凭目录存在就跨 worktree 复制。

The artifact behavior and compression setting follow
[actions/upload-artifact](https://github.com/actions/upload-artifact), and cache
reuse follows GitHub's
[branch access restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).
