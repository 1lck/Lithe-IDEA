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

- macOS PRs selected for package verification produce an Apple Silicon
  (`arm64`) DMG only. Intel (`x86_64`) compilation, linking, and packaging are
  verified after merge by the universal package on `preview`; run **macOS CI**
  manually on a branch when an Intel build is needed before merge.
- macOS pushes to `preview` and manual runs verify the default universal package,
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
gate** for the combined test result. The macOS **Swift tests** job builds the
Swift tests once and runs the main and database suites selected by the
classifier, so **macOS CI gate** also owns the Swift database result;
**Database CI gate** checks the Linux Rust database lane. **macOS Plugin CI**
stays separate: it only reserves a macOS runner when the classifier selects the
plugin lane, and otherwise **Plugin CI gate** passes on Linux in seconds.
A failed architecture still fails the macOS gate; `fail-fast: false` lets the
other architecture finish and upload its package. To request a Windows installer
for a branch, manually run **Release AutoBuild** and provide that branch as
`source_branch`; the Windows workflow is reusable and only builds an artifact
for that caller.

### Reusing lane results within a pull request

A new push to a pull request does not rerun every lane. In **macOS CI**,
**macOS Plugin CI** and **Windows CI**, the classify job runs
`scripts/plan-ci-lane-reuse.mjs`, which decides per lane (Swift tests, Rust Core
tests, packaging, plugin tests, Windows frontend, Windows Rust, real JDT):

- It finds the latest earlier run of the same pull request that actually ran
  the lane. If that job passed or is still running, and none of the pull
  request's **own** changes since then affect the lane (by the same classifier
  rules), the lane is reused instead of run. Changes that only arrived from the
  base branch, whether merged in or picked up by GitHub's merge commit, do not
  count, unless they touch CI infrastructure (workflows, actions, the
  classifier and runner scripts, test infrastructure, `Package.swift`,
  `Package.resolved`, every Cargo manifest and lock file including member
  crates, Rust toolchain files) that the planned workflow reads; then every
  lane of that workflow runs.
- Infrastructure is scoped per workflow. Workflow files and local actions count
  only for the workflow that references them, directly or through a composite
  action. Windows crates, toolchain and frontend manifests and Windows scripts
  count only for Windows CI. macOS Swift packages and build scripts count for
  macOS CI and the plugin CI, which builds through the same actions and
  `scripts/test-macos.sh`. Rust workspace manifests under `rust/`, the
  classifier and planner, and the root Bun workspace count for every workflow.
  The step summary lists the infrastructure paths that caused a rerun and those
  ignored because they only reach other workflows.
- A file counts as changed when its content or its mode differs, so an
  executable bit change alone reruns the lanes the file affects. Paths are read
  raw (NUL-separated), so Chinese and other escaped file names are compared
  and classified correctly.
- A failed or cancelled earlier result is never reused.
- Pull request runs are no longer cancelled per branch. The planner cancels the
  earlier runs that no lane reuses; an earlier run with a reused lane still in
  progress keeps running, because GitHub cannot cancel a single job. Only runs
  with a smaller run number than the current one are considered, so a planner
  that starts late never cancels or reuses a run for a newer push.
- The gate accepts a reused lane only after confirming that the earlier job
  passed, waiting up to 90 minutes for one still running. It also fails if a
  selected lane neither ran nor has a reused result.
- Any planner error runs every selected lane. Pushes and manual runs never
  reuse results.

The **Lane reuse** section of the classify job summary lists each lane's
decision and links to a reused job.
A reused lane appears as skipped in the new run; its result is the linked
job, which the gate checks. If the current workflow is cancelled, its gate is
skipped too, rather than adding a failure for the cancelled upstream jobs.
Cancellation is not a passing validation: the replacement run still checks all
selected lanes. An active run fails its gate when classification, a selected
job, or a reused source fails; a cancelled reused source also fails the gate.

The real-JDT lane runs on Windows and is selected by shared Java/JDT engine
changes, bundled JDK/JDT resources, preparation scripts, and Windows Java
consumers. Swift Java adapters and tests are covered by the Swift lane; a
macOS path containing `Java` alone does not select Windows real-JDT. Shared Core
and contract changes still select the relevant cross-platform checks.

### What runs after a pull request merges

A pull request into `preview` carries the full verification, and merging it
requires that verification. Later events run only what the pull request could
not observe:

| Event | What runs |
| --- | --- |
| Pull request into `preview` | Every lane the classifier selects |
| Push to `preview` (the merge) | **macOS CI** builds the universal package when the merge touched anything packaged; nothing else. The universal build is the only Intel (`x86_64`) compile and link, and it also compiles the merged combination of pull requests that each passed on their own. Light Linux checks (platform feature matrix, Agent Notes board deployment) still run. |
| Pull request from `preview` into `main` | No lane. **macOS CI** checks that the same commit already passed **macOS CI** as a `preview` push; re-run the job once that push run has succeeded. |
| Push to `main` | Nothing. |

The classifier implements this through `LITHE_CI_SCOPE` (`pull_request`,
`post_merge`, or `release_promotion`). Windows CI no longer runs on `preview`
pushes, so its GitHub cache entries are refreshed only by pull requests; a
`Cargo.lock` change makes the next pull requests restore an older prefix match.

### macOS runners

Every macOS lane (**Swift tests**, **Rust Core tests**, **Release package
verification**, and **Plugin tests and package verification**) runs on the
GitHub-hosted `macos-26` runner, including pull requests from forks. Release
workflows also use GitHub-hosted runners because they hold signing material.

Self-hosted Mac mini runners were tried from 2026-10-16 to 2026-10-18 and have
been retired. The reasons and the lessons for any future attempt are in
[the rejected Agent Note](../.agents/notes/rejected/process/2026-10-18-self-hosted-mac-mini-ci-runners.md).

#### Rust Core bridge checks reuse the Swift build

**Rust Core tests** run only the Rust checks in
`scripts/verify-rust-core-crates.sh`. The Swift-linked checks (C ABI probe, Core
symbols in the linked app, Git execution integration, and the Git console and
Maven bridge tests) run in **Swift tests** through
`scripts/verify-rust-core-swift-bridge.sh --skip-build`, reusing that job's test
build. A Rust-only change therefore starts **Swift tests** to build and run the
bridge checks, without the full Swift unit suites. Locally,
`scripts/verify-rust-core.sh` still runs both halves.

### macOS runner budget

The `Lithe-IDEA` organization uses the GitHub Free plan, which runs at most
five GitHub-hosted macOS jobs at a time across every workflow and pull request. Queued macOS
jobs mean this pool is full; it is a concurrency limit, not a quota or abuse
signal. Keep macOS jobs per push low:

- Do not add a macOS job that repeats `./scripts/test-macos.sh list` for every
  Swift change; add a filtered step to the shared **Swift tests** job instead.
  The plugin lane is the deliberate exception because most pull requests do
  not select it.
- Open pull requests that are still being iterated on as drafts. Draft pull
  requests run only the Linux lanes; marking one ready for review reruns the
  classifier and the selected macOS and Windows lanes.
- Each new push cancels earlier runs of the same pull request whose results it
  does not reuse, so batch review fixes into fewer pushes when possible.
- Merging or closing a pull request cancels its pull request runs that are
  still queued or running (**Cancel CI of closed pull requests**), including
  admin merges that skip the checks. The post-merge `preview` push run is not
  cancelled.

The GitHub CLI can also download a particular run's packages:

```bash
gh run download <run-id> --repo 1lck/Lithe-IDEA --pattern 'Lithe-macos-*'
```

After the combined publication succeeds, download the latest Apple Silicon DMG,
Intel DMG or Windows x64 installer from the fixed
[AutoBuild release page](https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild).

The release tag is exactly **AutoBuild**; its title and body display
**AutoBuild — 构建自 YYYY-MM-DD HH:mm:ss UTC**. Prepare reads the package version
from `windows/tauri/src-tauri/tauri.conf.json` at the pinned source revision and
passes it to all three platform builds. Installer filenames contain that source
version; the workflow does not maintain a separate preview version. AutoBuild
identity and update ordering use the build timestamp.
The release keeps only the latest two macOS DMGs and Windows x64 installer with
checksums, current Sparkle full ZIPs and deltas targeting the current build,
appcasts, and the latest downloadable version of each registered official plugin
with SHA-256 sidecars. No previous installer, plugin version or update history is
retained. macOS jobs expose artifact links before the combined release publishes.

⚠️ 风险提示：AutoBuild 未经过稳定版验证，可能包含缺陷或导致数据丢失；普通用户建议使用 Stable 稳定版。

⚠️ Risk warning: AutoBuild is an automatically built prerelease and may contain bugs or cause data loss. Ordinary users should use the Stable release.

### AutoBuild 每日发布

定时任务使用默认分支 `main` 中的工作流，再检出 `preview` 源码。修复发布
工作流时必须把改动合入 `main`；只修改 `preview` 不会更新每天执行的流程。
保留 `release-preview-macos.yml` 文件；prepare 只采样一次 UTC，从同一秒导出
`YYYYMMDD.HHMMSS` build（例如 `20261015.124354`）及标准 ISO 时间，并固定源码 SHA
和版本。顺序来自构建时间，旧 `58.1` 仅兼容作为历史基线。
两个 macOS 架构与可复用 Windows 工作流并行使用该身份；Windows 没有独立定时任务
或发布权限。publish 必须等待三个平台全部成功，并检出 `github.workflow_sha`
执行发布脚本，不能从 `preview` 检出不存在或未经本次工作流审查的 helper。
工作流与源码的选择方式及插件签名边界见
[应用内更新的签名与发布策略](../.agents/notes/implemented/process/2026-09-13-macos-update-signing-and-release-strategy.md)。

合并修复后，可等待下一次定时任务，或由仓库所有者手动重新构建并发布：

```bash
gh workflow run release-preview-macos.yml \
  --repo 1lck/Lithe-IDEA \
  --ref main \
  -f source_branch=preview
```

不要直接重跑旧的失败任务，它仍然使用旧工作流。确认两个 macOS 架构、Windows
和 publish job 均成功，再检查安装包和 `appcast-preview-*.xml` 的更新时间。
公开渠道使用 `autobuild`，基础设施兼容内部 `preview` 开关与既有 appcast 文件名。
固定 tag 为 `AutoBuild`，标题与正文显示本次 UTC 构建时间。滚动 Release 的最初发布日期
不代表本次构建日期；以标题、appcast 与安装包中的共享时间为准。

发布器验证三个平台的源码、版本、build、ISO 时间完全一致，且 build 精确对应 ISO 秒。
任何远端写入前下载双架构已有 appcast，要求新时间严格晚于每份基线且 build 数值递增；
只要旧 `preview-0.3.0` release 仍存在，就同时校验其双架构 appcast；即使 AutoBuild 已创建
但为空或只留下未完成的检查点，也不能跳过旧入口的时间顺序。
新发布同秒或时钟倒退直接拒绝，不补造计数。没有历史入口才允许首次发布；已有 ZIP
却缺失 feed、损坏 feed 或时间身份不一致均拒绝发布。同一次发布的恢复由下述检查点约束，
不能仅凭相同时间或 tag 源码放行。

发布器在全部输入与双架构基线验证后，先上传 `autobuild-publication.json`：包含仓库、
源码 SHA、版本、build、ISO 时间及按名称排序的全部目标文件大小与 SHA-256。
重跑只有在本地生成的检查点与远端逐字节一致时，才允许继续同一次发布；当前 feed
必须与本地逐字节一致，否则仍走严格递增校验。该恢复允许补齐被中断替换删除的 feed
或空的 `starter` 上传残片。同时间但源码、插件、安装包或 feed 字节不同，以及更旧
身份遇到较新检查点，都会在远端变更前失败。没有有效检查点不能跳过时间顺序。

`publish-autobuild.mjs` 从 prepare SHA 用 `git fetch/show` 把
`Plugins/marketplace/official-plugins.json` 和 `index.json` 固定到本次临时目录，
按数值语义版本选择每个已注册可下载插件的最新版本，保留全部下载变体并去重。
只下载索引指向的 `Lithe-IDEA` 组织 GitHub Release ZIP；仓库重命名重定向由 gh
处理。Go/PHP 已迁移为 Lithe Store 社区插件，当前没有可下载官方插件，内置 Java 也不属于镜像。先按索引 SHA-256
验证原始 ZIP，再生成旁路 checksum；不构建、重签插件，也不需要插件私钥。
索引和上游 canonical URL 不修改，AutoBuild 只是方便手动下载的镜像架。

发布器验证全部本地输入与基线后，先持久化检查点，再上传所有数据，最后替换两个 XML；通过 GitHub asset
SHA-256 digest（缺失时重新下载校验）验证所有目标资源后，显式 force PATCH
`git/refs/tags/AutoBuild` 到源码 SHA，更新并复查 release 元数据，最后按完整目标
清单删除所有过期资产，包括旧版本 DMG、Windows 安装包和插件。任何下载、哈希、
上传或完整性验证失败均不会触发过期资产清理。GitHub 固定 tag 的多文件替换不是
原子操作，失败可能留下部分新文件；保留相同构建 artifacts 重跑 publish 可恢复，
不需要给原字节另造时间。检查点本身也参与最终完整性验证并保留到下次发布。
旧资产只有成功后才清理。

只有 AutoBuild 全部发布、校验和清理成功后，才退役 `preview-0.3.0` release 与 tag。
旧客户端需要手动重装一次 AutoBuild，不保留第二个兼容 tag。历史缓存 feed 引用
可能失效；旧 build 重新检查后使用当前全量包，通常仅上一份幸存基线能生成 delta。
稳定版 release、组织插件 release 和 canonical marketplace 索引都不受清理影响。
这些命令只应由正式工作流执行；本地验证使用 mock，不运行远程发布。

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
A universal build without a universal entry falls back to an arm64 or
x86_64 entry with the same toolchain identity; single-slice builds do not fall
back to the other slice. An interrupted cache restore is
discarded, leaving the existing verified download cache as the fallback. Swift
compilation products are not cached.

Compilation outputs are restored by `prepare-macos-dependency-cache` and saved
by `save-macos-cargo-build-cache` with `if: always()`. A successful job saves
the exact key; a failed, timed-out, or superseded job saves
`<key>-partial-<run_id>-<attempt>`, which the next build restores through the
primary-key prefix match. Pull requests restore preview's entries without
saving, so PR-scoped copies do not push preview's entries past the 10 GB
repository cache quota. The macOS CI package job allows 60 minutes, enough for
a cold universal build (about 45 minutes) on a single runner.

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

### macOS 测试窗口的桌面隔离

普通 `./scripts/test-macos.sh` 和计时测试默认使用 `LITHE_TEST_WINDOW_MODE=isolated`。
界面用例照常运行，真实窗口的原生排序、布局、弹窗和事件处理保留，但测试进程内
的窗口完全透明，该进程也不会主动切换前台应用。原生视图截图仍可生成。
隔离模块只由测试目标依赖，直接运行 `swift test` 也默认隔离，不进入发行程序。

需要观察测试窗口或验证真实桌面效果时显式选择：

```bash
LITHE_TEST_WINDOW_MODE=visible ./scripts/test-macos.sh --filter AgentActivityPresentationTests
```

可见模式使用原始 AppKit 行为。真实桌面合成、硬件输入和跨应用激活测试应在独立
macOS 登录会话或虚拟机中运行可见模式。独立启动的产品进程不加载测试隔离模块。
隔离模式不跳过现有界面测试；`alphaValue` 表示隔离后的透明度，需要断言产品
请求的透明度时使用测试模块的 `LitheTestRequestedWindowAlpha`。
这项功能只有测试源码与运行参数，没有新增下载或跨工作树复用资源。

### macOS Git 真实窗口性能采样

普通 `./scripts/test-macos.sh` 和 `./scripts/test-git-performance-baseline.sh`
默认跳过两个 WindowServer/display-link 真实窗口采样用例，继续运行 Git 图布局、
离屏绘制和其他性能回归验证。图形离屏帧采样保留完整 1,000 行历史，分别在
开头、中间、末尾采样 40 行可见区域，并检查位图确实绘制了图形。完整图的
结构和 Release 基线仍覆盖 1,000/5,000 行；单帧与测试总耗时上限保持不变。
真实窗口采样需要 macOS 14+ 和可用的桌面显示；
只在专门测量滚动帧率时显式开启：

```bash
LITHE_RUN_GIT_COMPOSITOR_TESTS=1 \
  ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
  -- --filter 'GitGraphPerformanceBaselineTests.*[wW]indowCompositorFrameSample'
```

此命令会短暂显示两个有标题、不透明的普通层级测试窗口，不强制激活程序或抢占
焦点，并自动选择可见模式；同时强制 `LITHE_TEST_WINDOW_MODE=isolated` 会明确报错。
用例在成功、跳过或超时后关闭窗口、停止显示链接，并恢复原激活策略。
没有可用显示或没有收到显示链接回调时，用例输出未采样原因，不能将其计为真实
帧率验证。不要在普通开发验证或无人值守 CI 中默认设置该环境变量。

Swift 文本文件策略直接调用 Rust Core，因此 `scripts/test-macos.sh` 会先构建并链接
当前工作树的 Core 静态库。它复用现有 `rust/target/macos` 构建路径；这是可变编译状态，
不允许跨工作树复制或共享，也没有新增可复用资源目录。依赖下载仍按下文清单复用。
Swift 单元、插件和数据库 CI 通道复用已有 Cargo 下载缓存。先通过
`./scripts/test-macos.sh list` 构建并发现测试，独立步骤上限为 20 分钟；随后计时工具
传入 `--skip-build`，测试阶段保留 960 秒总时限及 17 分钟外层步骤时限，给超时清理
与报告留出一分钟。冷构建不再消耗测试执行预算；单测试预算和无输出看门狗保持不变。

### 独立工作树的本地编译

`Lithe-Dev` 的运行时用户状态不属于可复用构建缓存。macOS 用
`app.lithe.desktop.dev` 隔离偏好和钥匙串，并在系统 Application Support、Caches、
Logs 及临时目录下使用同名子目录；Windows 用 `app.lithe.windows.dev` 隔离
应用数据、WebView 存储及凭据。正式版保留历史路径。资源注册表将这些位置登记为
`distribution-runtime-state`，复用脚本的 exclusion 路由在任何复制阶段都拒绝它；
不根据版本、架构或工具链注册 validator。
只有应用启动入口允许一次性配置迁移：首次安装的开发版尚无用户设置或工作区时，
从正式版独立复制白名单偏好和工作区，完成后写版本化标记，已有开发版数据不合并。
macOS 的 Application Support 临时快照 `.lithe-dev-profile-import-<transaction>/`、
开发版根内 `.stable-profile-import-v1.plist`，以及 Windows Local AppData 开发版根内
`.stable-profile-import-v1` / `.stable-profile-import-v1-staging/` 都是用户运行状态，
不进入资源复用清单的可复制项。Windows 只复制关闭后的 localStorage 数据库和
原生设置/Maven JSON，必须在创建 WebView 之前完成；占用或复制失败不写成功标记，
中断后重试。渠道、跳过版本、旧日志位置、浏览器缓存、索引和锁不迁移。
系统凭据不批量导出，相关登录可能需要重新认证；之后两版各自写自己的存储。
偏好、插件状态、恢复文件和日志由所属发行身份持有，临时文件与缓存可由系统清理；
这些目录没有可靠 identity stamp，不进入工作树缓存或安装包，不改变代码签名及增量更新基线。
同一发行身份的多个源码工作树仍会使用同一用户域；本地测试应注入临时目录与独立偏好域。

模块日志和诊断包暂存目录登记为 `application-log-state`，不允许跨工作树复用。
日志根目录下的 `application`、`language`、`run`、`git`、`plugins`、`performance`
子目录、旧版 `lithe.log`、macOS 缓存中的 `Lithe/diagnostics-export/<snapshot>/`
以及导出目标旁的临时 ZIP（macOS 的 `.lithe-diagnostics-<snapshot>.zip`
和 Windows 的 `<destination>.lithe-<process>-<snapshot>.tmp`）都属于本次运行的用户状态，没有可验证的版本、平台、
架构或工具链 identity stamp。复用脚本在解析工作树与复制之前拒绝这些位置；
不存在允许复制的阶段。Windows 的确认快照仅保存在内存中，最多四份、五分钟有效；
macOS 的暂存目录由导出成功、失败或取消清理。测试必须注入各自的临时日志根目录，
不要复用真实用户日志。这些数据不进入 app bundle、Windows 安装目录或签名基线。

#### 日志与诊断的原生界面检查

编译 macOS 测试后运行 `./scripts/probe-macos-logging-ui.sh --skip-build`，或省略
`--skip-build` 先构建测试。脚本使用当前 Xcode 的 SwiftPM runner，在系统临时目录
创建一次性的 `Lithe Logging UI.app`，并复用产品本地化打包脚本装入中英文字符串表。
它运行真实原生页面的四种语言/明暗组合，生成 `.artifacts/test-stability/logging-*.png`
和计时 HTML/JUnit；不会启动用户工作区，也不会改写 Xcode 或已安装的 Lithe。

临时宿主由脚本创建并在退出时删除，截图留在当前工作树的测试报告中。
`agent-ui-test-evidence` 将两者都列为不可复用资源：身份只覆盖当前源版本、Xcode
runner、产品字符串表、外观和测试参数，没有可跨工作树迁移的可靠 identity stamp。
复用脚本在复制前直接拒绝这类资源，不复制、不校验后发布，也不共享原生测试宿主。


功能矩阵生成物 `.artifacts/platform-feature-matrix/`（CI Pages 使用
`<runner-temp>/lithe-agent-notes-site/platform-feature-matrix/`）不允许跨工作树复用。
它依赖当前 checkout 的能力记录、证据路径及提交信息，没有可靠的版本、平台、
架构或工具链 identity stamp；任何复制阶段都应排除。资源清单的
`excludedResources.platform-feature-matrix` 由复用脚本直接拒绝。目标工作树运行
`node scripts/generate-platform-feature-matrix.mjs`，校验源数据后重新生成。

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
  Windows 的每次依赖安装在独立 worker 中执行；worker 在启动 Bun 前加入
  Job Object（Windows 用于管理整棵子进程树的对象），退出时终止残留安装脚本。
  每次安装默认有 300 秒本地期限，超时终止 worker 及其子进程；
  安装失败后先释放子进程，再清理部分依赖与缓存，并只进行一次冷安装重试；
  文件锁释放有 10 秒本地期限。`node_modules`、两个 workspace 的依赖目录和
  `.artifacts/bun-tmp` 是安装过程的可变状态，不跨 worktree 复制；进程句柄只在
  worker 内存中存活，不增加下载目录，不写发行资源，也不影响签名或增量更新。
- `.artifacts/jdtls-downloads/`：JDTLS、Lombok、Java Debug/Test 和 license。
- `.artifacts/jdk-downloads/`：各平台与架构的 bundled JDK 下载归档。

Inter 4.1 的 18 个静态 OTF（内部版本 4.001）及许可、JetBrains Mono 2.304 的 16 个静态 TTF、OFL 和作者信息位于 Git 跟踪的
`macos/Resources/Fonts`。同目录增加 Nerd Fonts v3.5.1 的 JetBrains Mono Nerd Font Mono 四个完整 TTF（常规、粗体、斜体、粗斜体）及 OFL 许可，终端可直接选择这些字型而不依赖用户安装；来源、版本和固定 SHA-256 记录于 `NOTICE.txt`。它们与平台架构和工具链无关，随工作树检出，不从另一个
工作树的产物或已签名 app 复用；注册表将 `bundled-ui-fonts` 排除，复用脚本拒绝
复制。打包脚本在签名前复制到 `Contents/Resources/Fonts`，资源门禁检查全部字型；
`BundledUIFontTests` 检查版本、CoreText process 注册、字号/字重、SwiftUI 字体及
注册前后的文件清单与 SHA-256。运行时仅只读注册和 WebKit 加载，不修改 bundle，
不影响 Sparkle delta 的发布基线。

以下目录不应直接复制或跨工作树共享：

- AutoBuild 插件镜像与发布校验 staging：
  `<RUNNER_TEMP>/lithe-autobuild-<invocation>/{marketplace,plugins,baselines,verification}/`。
  源码 SHA、固定索引中的 SHA-256、组织 release/tag/asset、当前 build/ISO 时间与本次发布共同决定输入；
  根目录生成 `autobuild-publication.json`，`baselines/AutoBuild/` 保存当前入口的检查点与
  双架构 appcast；旧入口仍存在时，`baselines/preview-0.3.0/` 另存其双架构 appcast。
  两组基线用于本次严格时间排序，只有 AutoBuild 接受匹配检查点的精确恢复。
  检查点绑定全部目标字节，不是可跨工作树复制的构建缓存；远端发布资产仅供本次调用下载验证。
  ZIP 的平台/架构由索引下载变体约束，复用现有签名，不依赖本地工具链重新构建。
  缺少可跨工作树复用的 identity stamp，`autobuild-plugin-mirror-staging` 注册在
  `excludedResources` 并由复用脚本的通用排除路由拒绝，任何复制阶段都不共享。
  每次 gh 子进程有 120 秒期限，暂时性故障最多三次尝试，每次重试先清除本次残片；
  本地输入全部验证后才上传。发布器的 `finally` 删除自己创建的精确 mkdtemp 目录，
  成功和失败都不留下 staging，不写运行时 app bundle，不影响签名与 Sparkle 基线。
  本地工作树只运行 `node --test scripts/test-publish-autobuild.mjs` 和资源复用测试，
  不复制别的工作树 staging，也不把正式发布命令当作验证命令。

- 插件 UI 图标：包内声明的 SVG/PNG 属于安装版本的签名或社区内容摘要，
  macOS 在安装与启动时校验路径、大小、静态 SVG 子集和原生解码。资源在安装
  阶段随包复制，运行时只读，内存图像随当前进程目录释放；不创建磁盘缓存。
  `excludedResources.plugin-ui-icons` 通过复用脚本已有的排除资源路由拒绝复制，
  `scripts/test-reuse-worktree-resources.mjs` 验证该路由。
  没有可复用的版本/平台/架构/工具链 identity stamp，不得从安装包、已签名 app
  或其他工作树搬运图标；仓库内官方源资源从 Git 获取，构建打包时才复制。
  校验与渲染不会修改 bundle，因而不改变代码签名或 Sparkle delta 基线。


- 插件市场运行时状态：拉取的索引缓存 `<app-cache>/Lithe/PluginMarketplace/<source-id>/index.json`、
  用户的插件仓库列表 `<app-support>/Lithe/PluginMarketplace/sources.json`，以及下载与解压
  插件归档的临时目录 `<system-temp>/lithe-plugin-transfer-*`、`<system-temp>/lithe-plugin-download-*`。
  索引由 Rust Core 校验，归档按索引 SHA-256 校验。市场和磁盘 ZIP 在解压前把唯一文件、
  显式目录及隐式父目录统一计入条目上限；规范化路径的累计 UTF-8 字节上限取归档字节预算与
  16 MiB 的较小值，避免中央目录中少量深层文件放大预检内存。通过预检不产生可复用身份。
  这些都是每个用户、每次运行的状态，
  不是工作树构建产物，没有版本、平台、架构或工具链 identity stamp；
  `excludedResources.plugin-marketplace-state` 由复用脚本直接拒绝。官方索引只从 Git 跟踪的
  `Plugins/marketplace/index.json` 在打包阶段复制为只读的 `Contents/Resources/PluginMarketplace/index.json`，
  运行时刷新只写 Caches，不改写 app bundle，也不影响签名和 Sparkle delta。
  官方插件归档由 `.github/workflows/release-official-plugins.yml` 按插件独立 tag 发布，
  不进入 app 构建或工作树缓存。

- 本地社区插件磁盘安装：`MacServiceContainer` 把 `fileStorage.temporaryDirectory()`
  注入 `MacPluginDiskPackageImporter`，每次选择 ZIP 或解包目录后，先在该平台可写根下创建
  私有的 `lithe-plugin-disk-<UUID>/`（权限 `0700`）。ZIP 的 `archive.zip` 和复制/解压后的
  `package/` 只属于这次安装，原始输入保持只读；审查与安装针对快照，不重新从原始路径取包。
  ZIP 摘要取自复制后的 `archive.zip`；目录没有归档摘要。内容 digest 与完整 canonical
  `approvedPrograms` 绑定用户批准的字节，不能当作远端仓库/发布者认证，也没有可复用的
  版本、平台、架构或工具链 identity stamp。
  `excludedResources.plugin-disk-install-state` 同时排除快照、
  `<app-support>/Lithe/Plugins/.staging/<transaction>/`、用户级版本目录和 `installation.json`
  中当前/上一版本的磁盘审批；任何复制阶段都不共享、不打包、不软链接。复用脚本在解析
  工作树及进入 validator 前拒绝该 ID，不能新增“摘要相同即可复用”的校验路由。
  importer 负责复制失败和取消的清理；准备成功后 service 负责审查取消、安装成功/失败时
  discard 本次快照；关闭插件页会结束安装 session 并清理已有及迟到的快照。
  store 负责安装暂存和持久版本生命周期，并在 staging、扫描、回滚时
  重验摘要。`PluginDiskProvenance` 与 marketplace provenance 分开，市场同 ID 条目不能
  自动接管本地包的更新来源。本地磁盘社区首次安装、更新和同版本替换每次确认完整权限/程序，
  官方固定 ID、命名空间及签名要求与 DEBUG 开发包例外不变。
  验证运行 `node scripts/test-reuse-worktree-resources.mjs`，确认排除项不在 `--list` 且
  混合复制请求在任何工作树访问前失败；运行 `./scripts/verify-runtime-bundle-immutability.sh`
  检查两端发行资源路径。macOS 产品验收另比较典型安装/取消/失败工作流前后的发行 bundle
  文件清单和哈希；运行时只写平台临时目录及 Application Support，不改变代码签名或
  Sparkle delta。Windows 尚未实现此声明式磁盘安装流程，不能把边界说明视为实现证据。

- Sparkle 差分基线的单次发布临时目录：
  `<system-temp>/<sparkle-run>/archives/.baseline-<attempt>/` 保存每次 `gh`
  下载尝试，只有命令成功且文件非空才移入同次发布的 `archives/<selected-baseline>.zip`。
  输入由 GitHub Release 中选定的仓库、tag、stable/preview 渠道和 macOS 架构决定；
  成功下载不是可复用的版本、平台、架构或工具链 identity stamp，也不替代后续
  Sparkle 归档、签名与 appcast 校验。失败或取消时先结束所属下载进程，再删除
  该次 staging；发布脚本退出时删除整个系统临时目录，不写已安装 app。
  `excludedResources.sparkle-baseline-staging` 经排除路由直接拒绝，任何复制阶段
  都不得跨工作树复用；每次发布仍从选定的 GitHub Release 下载基线。

- Java 启动临时文件：`<system-temp>/lithe-run/launch-<pid>-<counter>.argfile`
  和同目录的 `.classpath.jar` 由平台启动 adapter 为单次执行独占创建，包含该次
  执行的绝对类路径、工作目录、JDK 版本及编码语义，没有可复用的版本、平台、架构
  或工具链 identity stamp。准备失败、准备完成前已取消、启动失败或进程退出后由
  所有者删除；系统临时目录由平台解析，不写安装包或 JDK，不影响签名或增量更新。
  `excludedResources.java-launch-temporaries` 经复用脚本的排除路由直接拒绝，任何
  复制阶段都不得共享；内容哈希相同也不能转移进程所有权。

- Agent CLI 的用户级安装与下载缓存：npm 的 global prefix/cache、Homebrew 的
  Cellar/Caskroom/cache、用户目录下 `.local/share/claude/versions`。它们由运行时
  `PATH` 和原安装器决定，不属于工作树；包版本、平台与架构由原安装器校验，
  没有工作树构建身份 stamp，任何复制阶段都禁止复用。注册表的
  `excludedResources.agent-cli-runtime` 记录此边界，脚本显式拒绝选择它。

- Codex 短重连配置及历史上下文 helper：`<system-temp>/lithe-codex-retry-<UUID>/` 由单次
  Agent 连接独占，内容来自当前 Rust Host 内嵌的一方源码，原生 CLI 路径和预算
  经非敏感环境字段传递，密钥仍只走标准输入。系统临时目录由平台解析；准备、
  启动失败、取消或进程树结束后删除。它没有可复用的版本、平台、架构、工具链
  stamp，任何复制阶段都不得共享；`excludedResources.codex-retry-relay` 走脚本
  的排除路由。订阅连接也复用同一 helper 获取原生历史用量，但不改重试策略；单次连接的回环监听器、随机访问令牌及每次加载票据只存在内存中，随连接关闭，不进入复制阶段。helper 不修改已安装适配器、用户配置、app bundle 或 Windows 安装
  目录，因此不改变代码签名和 Sparkle delta 的发布基线。

- 测试 JFR 录制：`<system-temp>/lithe-jfr-<recording-uuid>/recording.jfr` 属于单次运行和
  精确工作 JVM（PID 加启动身份），由该 JDK 写入，最大64MiB、最长120秒。关闭/替换
  运行或销毁监控 Feature 时停止命名录制并删除目录；它没有版本/平台/架构/工具链构建
  stamp，任何复制阶段都不共享。`excludedResources.test-jfr-recordings` 通过复用脚本的
  通用排除路由拒绝，应用 bundle、插件包、签名及 Sparkle 增量基线保持只读。
- Agent 历史注释：平台偏好设置键 `lithe.agent-history.v1.<workspace-agent-digest>` 保存收藏、自定义标题和隐藏状态，按标准化工作区与 Agent ID 隔离。它是用户可变状态，不受版本、平台、架构或工具链构建身份约束，不存在可验证的构建 stamp；Markdown 导出写到用户选择的位置。两者都禁止在任何复制阶段跨工作树复用，`excludedResources.agent-history-metadata` 由资源脚本显式拒绝。

- `.artifacts/bun-tmp/`、下载或解压过程中的临时目录；
- `.artifacts/jdtls/`、`.artifacts/jdk-*` 等可以由已验证下载重新生成的解压输出；
- `.artifacts/editor/macos/` 和官方插件等尚未写入构建身份 stamp 的生成资源；
- `.build` 中的 SwiftPM 构建状态；
- `rust/target/` 中与当前源码、编译器或构建参数绑定的构建输出；
- LSP workspace `-data`、运行时数据库、测试报告和其他会被进程修改的状态。
- Agent 原生界面截图：macOS unit lane 通过已有的 `LITHE_AGENT_ACTIVITY_SCREENSHOTS`、
  `LITHE_AGENT_SELECTOR_SCREENSHOTS` 与 `LITHE_AGENT_EDITOR_LAYOUT_SCREENSHOTS` 将夹具截图
  写入 `.artifacts/test-stability/`，随 `test-stability-macos` 报告上传，覆盖输入区、
  模型/Effort、任务/子代理/文件摘要及窄宽布局和主题。只用受控测试数据，不捕获用户桌面。
  截图身份取决于源码 revision、平台、主题、视口和夹具参数，没有构建 identity stamp，
  不允许任何阶段跨 worktree 复用。`excludedResources.agent-ui-test-evidence` 通过已有
  排除路由拒绝；截图归测试与 CI artifact 保留策略所有，不打包、不写发行 bundle，
  不影响代码签名或 Sparkle delta。
- 平台缓存中 JDT `-data/.lithe/maven/` 的 settings 副本：按工作区隔离，可能含凭据，
  在缓存过期或重建索引时清理；文件内容哈希不是版本、平台、架构或工具链构建
  identity stamp，任何复制阶段都禁止共享。资源清单 `jdt-maven-settings` 显式排除，
  复用脚本直接拒绝该资源，不进入下载或生成物校验路由。

可下载的官方插件包是声明式插件包（只含 `plugin.json` 和它声明的资源，不含宿主加载的代码，与架构无关；自带运行时的 Java Support 见下文），在 `.build/<triple>/<configuration>/OfficialPlugins` 中独立组装，`--triple` 只决定输出目录和签名工具的构建布局；组装后通过 `LitheOfficialPluginVerifier` 验证声明、打包的可执行文件和“Mach-O 原生代码只出现在清单声明的运行时目录内”；发布配置还要求 repository secret `LITHE_PLUGIN_PACKAGE_PRIVATE_KEY`，由 `LithePluginPackageSigner` 对完整包生成 `lithe-plugin-signature.json`，客户端按宿主内置官方插件策略和 publisher 公钥验证后才允许安装。该 secret 的值是与客户端内置公钥匹配的 base64 编码 32 字节 Ed25519 私钥，可用 `gh secret set LITHE_PLUGIN_PACKAGE_PRIVATE_KEY --repo 1lck/Lithe-IDEA < /secure/path/lithe-plugin-package-private-key.base64` 配置；私钥文件和 shell 历史都不得进入仓库或日志。没有该 key 时，普通 debug 全量构建会跳过 publisher 签名包，指定其中一个包 ID 的构建会失败，不会留下缺少签名文档的目录。本地调试插件时可以显式传入 `--development-unsigned`（仅 debug 配置可用），生成不含签名文档的开发包，只能由 debug 构建的 Lithe 从磁盘安装；这类开发包同样不跨工作树复用。无可靠 identity stamp，不跨工作树复制。插件安装后打包的语言服务器位于
`<app-support>/Lithe/Plugins/<plugin-id>/versions/<version>/language-server`，由插件版本目录拥有，运行时只读，重装、回滚和卸载随插件一起处理，不是工作树构建缓存。Go Support 和 PHP Support 已迁移为 Lithe Store 社区插件（`Lithe-IDEA/lithe-plugin-go`、`Lithe-IDEA/lithe-plugin-php`），不再由本仓库构建。PHPUnit 测试夹具的 `shared/fixtures/phpunit-project/vendor` 也由当前工作树独立安装。以上项目在资源清单 `excludedResources` 中明确排除，复用脚本会拒绝显式复制请求。

Java Support（`dev.lithe.plugin.java-support`）是唯一随 Lithe.app 发行的官方插件包，
也是唯一自带运行时的包，因此它与架构有关：

- **资源路径**：组装结果在 `.build/<triple>/<configuration>/OfficialPlugins/dev.lithe.plugin.java-support/`，
  打包后位于 `Lithe.app/Contents/Resources/OfficialPlugins/` 下。包内 `language-server/` 是固定版本的
  JDT LS 及 Lombok、Java Debug、Java Test 扩展，`runtime/<arch>/` 是它运行所用的 JDK。
- **组装入口**：`Plugins/mac/Official/JavaSupport/assemble-package.sh`，由
  `scripts/build-official-plugins.sh` 调用，`--arch arm64|x86_64|universal` 决定带哪些架构的 JDK
  和 Equinox 配置。应用本身不再包含 `Contents/Resources/LanguageServers`。
- **是否允许跨 worktree 复用**：组装后的包不允许复用。它由 `jdtls` 和 `jdk` 两个可复用的下载缓存
  生成，新工作树应复用这两个缓存后在本地重新组装。
- **身份约束与校验来源**：JDT LS 的版本、下载地址和校验值来自 `third_party/jdtls/manifest.json`，
  JDK 来自 `third_party/jdk/manifest.json`；`plugin.json` 精确写出入口 jar 的文件名，升级 JDT LS
  后文件名不一致会在组装时失败。组装结果由 `LitheOfficialPluginVerifier` 校验：入口和各架构的
  `bin/java` 存在，包内没有符号链接，Mach-O 只出现在清单声明的 `runtime/` 目录内。
- **运行时状态**：语言服务器的可写状态在 `<app-support>/Lithe/PluginState/<plugin-id>/`，
  JDT LS 的工作区索引和 Equinox 配置区仍在 `<cache>/Lithe/language-servers/`（`jdtls/`、`jdtls-configuration/`），
  由 `jdt` 宿主集成在启动时发现没有未卸载的插件声明它后删除。两者都是单次安装的
  可变状态，任何阶段都不得复制或跨 worktree 共享。

插件网页的宿主持久状态通过平台存储 adapter 写到
`<app-support>/Lithe/PluginState/<plugin-id>/web-state/<window-id>/<workspace-digest>.json`，
每个窗口和工作区最多 64 KiB。它属于当前安装中的插件，卸载时随 `PluginState` 清理；
包内网页、脚本和 app bundle 始终只读，因此不改变签名或 Sparkle delta 的源基线。
这类用户 JSON 没有版本、平台、架构或工具链 identity stamp，工作区摘要只是存储键，
任何复制阶段都不得复用或共享。`excludedResources.plugin-web-state` 通过复用脚本的
排除路由直接拒绝，由 `scripts/test-reuse-worktree-resources.mjs` 验证，不能给它增加缓存校验器。

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
