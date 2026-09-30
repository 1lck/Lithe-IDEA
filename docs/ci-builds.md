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

Git 路径往返集成测试 `rust/lithe-core/tests/git_path_roundtrip.rs` 需要 Git 和
Node.js 22.6+（用于直接加载实际前端 TypeScript 路径规范化函数），不需要安装
Bun 或前端依赖。CI 复用计时脚本已使用的 runner Node.js，本地运行时需满足
上述最低版本；该测试随 SharedRust 计时测试执行，结果写入现有
`.artifacts/test-stability/` 报告。

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

### macOS Git 真实窗口性能采样

普通 `./scripts/test-macos.sh` 和 `./scripts/test-git-performance-baseline.sh`
默认跳过两个 WindowServer/display-link 真实窗口采样用例，继续运行 Git 图布局、
离屏绘制和其他性能回归验证。真实窗口采样需要 macOS 14+ 和可用的桌面显示；
只在专门测量滚动帧率时显式开启：

```bash
LITHE_RUN_GIT_COMPOSITOR_TESTS=1 \
  ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
  -- --filter 'GitGraphPerformanceBaselineTests.*[wW]indowCompositorFrameSample'
```

此命令会短暂显示两个有标题、不透明的普通层级测试窗口，不强制激活程序或抢占
焦点。用例在成功、跳过或超时后关闭窗口、停止显示链接，并恢复原激活策略。
没有可用显示或没有收到显示链接回调时，用例输出未采样原因，不能将其计为真实
帧率验证。不要在普通开发验证或无人值守 CI 中默认设置该环境变量。

Swift 文本文件策略直接调用 Rust Core，因此 `scripts/test-macos.sh` 会先构建并链接
当前工作树的 Core 静态库。它复用现有 `rust/target/macos` 构建路径；这是可变编译状态，
不允许跨工作树复制或共享，也没有新增可复用资源目录。依赖下载仍按下文清单复用。
Swift 单元、插件和数据库 CI 通道复用已有 Cargo 下载缓存；包含冷构建的套件总时限
为 960 秒，外层步骤为 17 分钟，给超时清理与报告留出一分钟。单测试预算和无输出
看门狗仍由原计时工具控制。

### 独立工作树的本地编译

IDE MCP helper 由 `scripts/build-ide-mcp.sh`（macOS）和
`scripts/build-windows-ide-mcp.mjs`（Windows Tauri 构建前）从当前源码与
`rust/Cargo.lock` 构建。`dist/ide-mcp/`、`rust/target/windows-ide-mcp/` 和
`windows/tauri/src-tauri/helpers/` 没有可靠 identity stamp，不允许跨工作树复用；
目标架构、Rust 工具链及签名由各自打包流程验证，复制只发生在本次构建的打包阶段。
`<platform-app-data>/mcp/` 保存项目连接凭据和实例锁，属于运行时私有状态，
不能进入安装包、缓存复用或版本控制；运行时不修改打包的 helper。

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
- `.artifacts/php-language-server-downloads/`：按
  `Plugins/mac/Official/PhpSupport/language-server.json` 下载并校验的
  Intelephense tarball；它只服务当前工作树的插件打包，不能复制解压结果。

以下目录不应直接复制或跨工作树共享：

- Agent CLI 的用户级安装与下载缓存：npm 的 global prefix/cache、Homebrew 的
  Cellar/Caskroom/cache、用户目录下 `.local/share/claude/versions`。它们由运行时
  `PATH` 和原安装器决定，不属于工作树；包版本、平台与架构由原安装器校验，
  没有工作树构建身份 stamp，任何复制阶段都禁止复用。注册表的
  `excludedResources.agent-cli-runtime` 记录此边界，脚本显式拒绝选择它。

- Agent 历史注释：平台偏好设置键 `lithe.agent-history.v1.<workspace-agent-digest>` 保存收藏、自定义标题和隐藏状态，按标准化工作区与 Agent ID 隔离。它是用户可变状态，不受版本、平台、架构或工具链构建身份约束，不存在可验证的构建 stamp；Markdown 导出写到用户选择的位置。两者都禁止在任何复制阶段跨工作树复用，`excludedResources.agent-history-metadata` 由资源脚本显式拒绝。

- `.artifacts/bun-tmp/`、下载或解压过程中的临时目录；
- `.artifacts/jdtls/`、`.artifacts/jdk-*` 等可以由已验证下载重新生成的解压输出；
- `.artifacts/editor/macos/` 和官方插件等尚未写入构建身份 stamp 的生成资源；
- `.build` 中的 SwiftPM 构建状态；
- `rust/target/` 中与当前源码、编译器或构建参数绑定的构建输出；
- LSP workspace `-data`、运行时数据库、测试报告和其他会被进程修改的状态。
- 平台缓存中 JDT `-data/.lithe/maven/` 的 settings 副本：按工作区隔离，可能含凭据，
  在缓存过期或重建索引时清理；文件内容哈希不是版本、平台、架构或工具链构建
  identity stamp，任何复制阶段都禁止共享。资源清单 `jdt-maven-settings` 显式排除，
  复用脚本直接拒绝该资源，不进入下载或生成物校验路由。

PHP 插件包在 `.build/<triple>/<configuration>/OfficialPlugins` 中独立构建，绑定宿主 API、Swift 工具链、架构和签名，通过 `LitheOfficialPluginVerifier` 验证；无可靠 identity stamp，不跨工作树复制。插件安装后的 Intelephense 位于
`<app-support>/Lithe/Plugins/<plugin-id>/versions/<version>/PhpSupport.bundle/Contents/Resources/LanguageServers/php`；插件声明的 SDK 位于
`<app-support>/Lithe/Toolchains/<plugin-id>/<toolchain-id>/<version>/<architecture>`。两者都由插件生命周期拥有，重装、回滚和卸载随插件一起处理，不是工作树构建缓存。PHPUnit 测试夹具的 `shared/fixtures/phpunit-project/vendor` 也由当前工作树独立安装。以上项目在资源清单 `excludedResources` 中明确排除，复用脚本会拒绝显式复制请求。

如果后续新增可复用资源，必须同步更新注册表、校验器、脚本测试和本节说明。
生成资源只有在构建流程写入可验证的源码、配置、平台、架构和工具链 identity
stamp 后才能加入注册表，不能仅凭目录存在就跨 worktree 复制。

The artifact behavior and compression setting follow
[actions/upload-artifact](https://github.com/actions/upload-artifact), and cache
reuse follows GitHub's
[branch access restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).

Windows PHP Worker 插件使用 `bun scripts/build-windows-php-plugin.ts` 单独构建到
`.artifacts/windows-plugins/`，通过 `node scripts/verify-windows-plugin-isolation.mjs`
检查入口独立性。它绑定包格式、宿主 SDK 和当前 Bun 构建版本，没有 identity stamp，
在资源清单中注册为不可复用；不随 Windows 应用构建复制。用户导入后的源码与状态
位于 WebView 用户配置的 `lithe.worker-package:<id>`，也禁止跨 worktree 复用。
CI 在 Windows frontend lane 构建并上传独立包，同时运行包、Worker 协议和生命周期测试。
