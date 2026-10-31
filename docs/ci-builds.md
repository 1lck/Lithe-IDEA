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
Swift tests once and runs the suites selected by the classifier;
**Remote Workspace CI gate** checks the Linux remote workspace lane (`scripts/remote/verify-remote-workspace.sh`),
which draft pull requests keep because it uses no macOS runner. **macOS Plugin CI**
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
`scripts/ci/common/plan-ci-lane-reuse.mjs`, which decides per lane (Swift tests, Rust Core
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
  `scripts/macos/test/test-macos.sh`. Rust workspace manifests under `rust/`, the
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
`scripts/rust-core/verify-rust-core-crates.sh`. The Swift-linked checks (C ABI probe, Core
symbols in the linked app, Git execution integration, and the Git console and
Maven bridge tests) run in **Swift tests** through
`scripts/rust-core/verify-rust-core-swift-bridge.sh --skip-build`, reusing that job's test
build. A Rust-only change therefore starts **Swift tests** to build and run the
bridge checks, without the full Swift unit suites. Locally,
`scripts/rust-core/verify-rust-core.sh` still runs both halves.

### macOS runner budget

The `Lithe-IDEA` organization uses the GitHub Free plan, which runs at most
five GitHub-hosted macOS jobs at a time across every workflow and pull request. Queued macOS
jobs mean this pool is full; it is a concurrency limit, not a quota or abuse
signal. Keep macOS jobs per push low:

- Do not add a macOS job that repeats `./scripts/macos/test/test-macos.sh list` for every
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
手动运行的 `--ref` 选择工作流版本，`source_branch=preview` 只选择产品源码；
修复合入 `preview` 后可用 `--ref preview` 验证，但每日发布仍需同步到 `main`。
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
macOS 的稳定版与 AutoBuild 共用 75 分钟 job、35 分钟打包、30 分钟 Sparkle
生成的有界预算；原 30 分钟总上限可能在 Intel 打包成功后取消更新包生成。
这些期限分别定义在两个工作流中，由同一组离线测试检查，不会随源码分支自动同步。
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
或空的 `starter` 上传残片。同时间但源码、安装包或 feed 字节不同，以及更旧
身份遇到较新检查点，都会在远端变更前失败。没有有效检查点不能跳过时间顺序。

`scripts/release/autobuild/publish-autobuild.mjs` 只发布应用安装包和 Sparkle 更新资源，
不读取或校验官方插件 registry/index，不下载、校验或镜像独立插件包，也不需要插件私钥。
插件是否上架、暂停发布或其下载服务是否可用，都不影响应用发布。
插件继续由各自的发布流程和市场管理；独立发布及客户端安装的签名、哈希和兼容性校验不变。
这不是把未经验证的插件上传到 AutoBuild，而是将插件从应用发布目标清单中移除。

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
`rust/target` (the `lithe-mcp` helper). Keys include runner architecture, compiler,
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

普通 `./scripts/macos/test/test-macos.sh` 和计时测试默认使用 `LITHE_TEST_WINDOW_MODE=isolated`。
界面用例照常运行，真实窗口的原生排序、布局、弹窗和事件处理保留，但测试进程内
的窗口完全透明，该进程也不会主动切换前台应用。原生视图截图仍可生成。
隔离模块只由测试目标依赖，直接运行 `swift test` 也默认隔离，不进入发行程序。

需要观察测试窗口或验证真实桌面效果时显式选择：

```bash
LITHE_TEST_WINDOW_MODE=visible ./scripts/macos/test/test-macos.sh --filter AgentActivityPresentationTests
```

可见模式使用原始 AppKit 行为。真实桌面合成、硬件输入和跨应用激活测试应在独立
macOS 登录会话或虚拟机中运行可见模式。独立启动的产品进程不加载测试隔离模块。
隔离模式不跳过现有界面测试；`alphaValue` 表示隔离后的透明度，需要断言产品
请求的透明度时使用测试模块的 `LitheTestRequestedWindowAlpha`。
这项功能只有测试源码与运行参数，没有新增下载或跨工作树复用资源。

### macOS Git 真实窗口性能采样

普通 `./scripts/macos/test/test-macos.sh` 和 `./scripts/macos/perf/test-git-performance-baseline.sh`
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

Swift 文本文件策略直接调用 Rust Core，因此 `scripts/macos/test/test-macos.sh` 会先构建并链接
当前工作树的 Core 静态库。它复用现有 `rust/target/macos` 构建路径；这是可变编译状态，
不允许跨工作树复制或共享，也没有新增可复用资源目录。依赖下载仍按下文清单复用。
Swift 单元和插件 CI 通道复用已有 Cargo 下载缓存。先通过
`./scripts/macos/test/test-macos.sh list` 构建并发现测试，独立步骤上限为 40 分钟；随后计时工具
传入 `--skip-build`，测试阶段保留 960 秒总时限及 17 分钟外层步骤时限，给超时清理
与报告留出一分钟。构建失败时不生成合并报告，避免同一失败被重复计为“未生成测试
报告”；构建成功而报告缺失仍会失败。冷构建不再消耗测试执行预算；单测试预算和无
输出看门狗保持不变。

### 独立工作树的本地编译

Windows 插件正式验收的默认、LSP、设置和文本模式均使用完整源码库存及 EXE/配置/目标身份；`-SkipBuild` 必须匹配构建时的全部输入，旧 marker 缺失库存时应重新构建，不能补写为可复用证据。

资源复用每次子校验默认最多 300 秒；文件很多的冷缓存可显式传入
`--validation-timeout-seconds 1200`（整数 1～1200 秒）。这只调整本次校验的有界时限，
临时副本、既有目标及原子发布后仍执行相同完整身份、文件清单和哈希校验；源工作树始终只读。
超过时限仍失败并清理自己的 staging，不降低验证强度或复用可变安装状态。
Bun 封存和校验最多并行打开 8 个哈希流，保留原文件顺序和逐文件 SHA-256 比较；
失败先等待已开始的读取结束，再把错误交给 staging 清理，避免删除仍在读取的目录。

根工作区使用 Bun 1.3.14；`bunfig.toml` 与 `bun.lock` 的显式 tarball URL 均使用
`https://registry.npmjs.org`。不要假定 `--registry` 会替换 lock 中的显式地址。
仅迁移来源也会改变 lock 原字节，旧 Bun 缓存 seal 必须重新校验；版本、完整依赖图和
SRI 保持不变。仍通过既有 `bun` 路由校验复制下载缓存，不复制 `node_modules` 或
`.artifacts/bun-tmp`。两个 tree-sitter-cli 的 GitHub lifecycle 二进制不属于 npm
tarball SRI 的认证范围，尤其官方 digest 为 null 时不得登记为跨工作树二进制缓存。
Bun 1.3.14 的官方修复覆盖 TLS 握手停滞及 isolated linker 下载/摘要错误后挂起；
这里只升级安装工具，产品依赖精确版本不变。Windows 路径过长时可在本次调用独占的
空闲 SUBST 盘符运行同一工作树，结束后移除自己创建的映射，不修改系统 long-path
设置、不使用其他任务的盘符。工具候选的 npm metadata/tgz/EXE 和独立安装探针仅放
ignored 诊断目录，不进入工作树下载缓存或资源复用清单。

Windows 安装 worker 为 tree-sitter-cli 的原始 `install.js` 加载专用代理适配器；
有 HTTPS 代理时要求 Node 22.21+ 或 24.5+，由 Node 的原生 `https.Agent({proxyEnv})`
负责 CONNECT/TLS。适配器只在该生命周期进程中移除上游手动代理分支读取的两个变量，
其它包与父进程环境不变，不禁用 TLS、SRI 或 lifecycle。无代理时沿用上游直连。
代理变量按 Node 的 `https_proxy || HTTPS_PROXY` 选择；不支持的协议、非法 URL 或
凭据编码会在变更前脱敏失败，修正配置后重试，不会静默改为直连。
该适配器不下载、解压或缓存文件；输出仍归本次 Job-owned 安装状态，安装结束由既有
流程封存允许复用的 Bun 下载缓存。运行时不写发行资源，不影响签名或增量更新基线。
安装生命周期回归的 `<os-temp>/lithe Windows install */` 保存假工具、原生句柄等待器和
进程身份凭据；每个 case 在对应子进程仍等待握手时保留其句柄，退出后关闭句柄、服务及
连接才清理目录。这些临时生成物走 `frontend-install-state` 拒绝路由，所有阶段禁止复用。

SwiftPM 的 `.build/`、资源 bundle 和 `.lithe-swift-toolchain` 标记登记为
`swiftpm-build-state`，所有工作树复用阶段均拒绝复制。编译器标记只用于本工作树
缓存失效，不是可转移的源码、平台、架构、SDK 和工具链完整性证明；只复用经过校验的
`.artifacts/swiftpm-cache` 下载缓存。构建脚本在实际 scratch 目录保存带策略版本的
完整编译器身份：新版 SwiftPM 的 `.build/<triple>/` 各自独立，旧布局仍用 `.build/`。
身份未知或变化时，用同一 scratch 参数执行 `swift package clean`，保留它的依赖下载
和 checkout，再生成资源、签名；清理失败不更新标记。不要手工合并旧的平铺资源与
新 `Contents/Resources` 布局，也不要通过关闭 codesign 规避旧资源污染。状态生命周期
由本工作树 SwiftPM 清理管理；这些操作仅作用于构建目录，不修改已安装应用、签名
发行基线或 Sparkle delta。

`scripts/windows/perf/run-windows-perf.mjs` 的生产构建、本地基线和 CPU profile 写入
`.artifacts/windows-perf/`，登记为 `windows-perf-state`，所有复用阶段均拒绝复制。这些内容
跟随所在工作树的源码和机器，没有 identity stamp；工具在本工作树重新构建，不写 app bundle、
安装目录或 Sparkle delta 基线。

共享翻译源文件位于 `shared/i18n/`。每个工作树通过 Git 获取源文件和已提交的
macOS 字符串表、`AppLanguage.generated.swift`、Windows `shared.generated.ts`，
然后运行 `node scripts/i18n/generate-i18n.mjs --check` 校验。修改源翻译后运行不带
`--check` 的同一命令，在当前工作树重新生成。资源身份由当前语言清单、词条、翻译
共同决定，跨平台和架构均不需要下载；没有独立的工具链或
可复用 identity stamp。`scripts/resources/worktree-resources.json` 将它登记为 `shared-i18n` 不可复用项，
复用脚本拒绝所有复制阶段。不要从其他工作树或已签名应用复制生成文件。
macOS 打包只在本次构建的目标目录转换为二进制字符串表，签名前完成；应用运行时
只读取，不产生缓存或修改安装资源。维护步骤见 [共享翻译说明](../shared/i18n/README.md)。

共享指令的 `Lithe/AgentInstructions/Shared.md`、`.sync.lock` 和同目录原子保存暂存文件登记为
`agent-instruction-library-state`，由平台 storage adapter 的 Application Support 根目录提供。
它们是可变用户配置，不具有版本/平台/架构/工具链身份；所有工作树复用阶段均拒绝复制，
不从其他工作树或发行包导入。原生 Agent 指令文件同样保留用户归属；暂存文件随保存完成或失败清理，
空锁文件属于用户资料的生命周期。运行时不写 app bundle、安装目录或 Sparkle delta 基线。

MCP 工具检测会话、工具描述、原生规则快照和工具排除所有权登记为 `mcp-tool-probe-state`。
这些内容属于用户资料和一次页面操作，没有版本/平台/架构/工具链 identity stamp，所有复用阶段均拒绝复制。
官方 SDK 沿用 Cargo 锁定版本构建，stdio/HTTP 检测只在用户主动操作时运行；
HTTP/SSE 响应体和 stdio 元数据限制为 2 MiB，原生文件由现有平台 adapter 条件替换并备份到 Application Support。
工具名称所有权保存在平台偏好中，不存令牌；Codex 移除服务器后，允许/禁用工具名保留在
同一用户资料的服务器账本 `toolFilters`，重新添加时恢复，不作为活动文件的所有权证明。
这些保留值随资料持久化，不能复制到其他工作树；取消/离页释放进程与内存，不写 app bundle 或安装目录。
用户明确运行包命令可能产生的 npm/uv 缓存归上游运行时管理，不属于可跨工作树复用的 Lithe 构建资源。

随 App 附带的远端工作区服务登记为 `remote-server-artifacts`。`scripts/remote/build-remote-servers.sh`
每次打包都从 `rust/lithe-remote/` 用 `--no-default-features --features server`
只构建 `lithe-remote-server` 可执行文件，不编译客户端；两个 Linux musl 静态版输出到
`rust/target/remote-servers/`，再复制到 `Contents/Resources/RemoteServers/`；构建机需要
`x86_64-unknown-linux-musl` 和 `aarch64-unknown-linux-musl` 两个 Rust 目标。清单只记录服务版本，
不带工具链或源码身份，所以不跨工作树复用。运行时只读取这份副本并上传给 SSH 主机，
不写 bundle，不影响签名和 Sparkle delta。

远程开发的用户状态登记为 `remote-connection-state`：偏好中的 SSH 连接列表、钥匙串服务
`remote` 中记住的密码或口令、`Application Support/Lithe/RemoteWorkspaces/` 下打开远程文件夹时
创建的空占位根目录，以及远端主机上 `~/.lithe-server/bin/` 中按 SHA-256 校验后复用的服务。
它们属于用户资料或远端主机，没有构建身份，所有复用阶段均拒绝复制。
远端常驻服务的 socket、锁和日志使用“会话键 + 完整二进制 SHA-256”的散列作为身份；
即使版本号不变，重新构建后也不会连回旧二进制启动的服务。这些路径仍属于远端用户状态，
不复制进工作树或应用安装目录。

远程 Git 的临时索引、行历史快照，以及连接内存中的运行时、Shell、Git 可执行文件和搜索索引
登记为 `remote-workspace-session-state`。临时文件通过主机的临时目录或 Git common directory
创建，由单次操作清理；本地占位根目录不保存远端文件。探测与索引快照按连接隔离，显式刷新或
替换连接后重建。它们没有可校验的构建身份，所有复用阶段在调用校验器前拒绝复制。
运行时写入仅发生在远端可写目录或进程内存中，不影响签名、安装资源或 Sparkle delta。
文件树复制还会在远端目标父目录创建 `.lithe-copy-<pid>-<sequence>/` 私有暂存目录，
操作完成后清理；它与文件监听的连接资源同属 `remote-workspace-session-state`，没有复用阶段。
移到废纸篓的内容和恢复元数据属于主机账户（Linux 的 XDG 数据目录/卷废纸篓，macOS 的系统 Trash），
由系统和用户保管，不是缓存或构建输入，也不复制到本机工作树。

远端构建输出、插件运行快照和分块上传同样登记在 `remote-workspace-session-state`，
没有跨工作树复制阶段。上传在目标父目录用 `.lithe-upload-<pid>-<sequence>` 暂存，
按连接持有，失败、断线或五分钟期限后删除；SHA-256 与架构校验只授权本次运行。
完整插件快照位于远端 `~/.lithe-server/plugin-runs/<UUID>/package`，由 `fs.createRunDirectory`
登记为会话所有，进程销毁后按同一身份释放；非驻留断线、会话关闭和空闲到期时由服务端回收。
常驻会话短暂断线保留快照；客户端崩溃后按会话空闲期限回收。远端服务被强制杀死后的安全回收仍为 TODO，
不能按目录年龄删除其他会话或仍有进程使用的输入，也不接管旧版未登记目录。插件配置、索引等持久状态位于远端
`~/.lithe-server/state/plugins/<plugin-hash>/<provider-scope>/<provider-hash>/workspaces/<root-hash>`，
由该工作区和提供者持有，构建临时输出按运行清理。异平台包下载复用市场下载器，
在平台临时目录解压，传输完成或失败后删除；校验来源包括市场归档 SHA-256、安装来源、
已批准命令、声明逐字节一致性和签名。上述内容没有版本/平台/架构/工具链构建 stamp，
复用脚本在校验和复制前拒绝这些路径；运行时不改写本机或远端安装资源，不影响签名或 Sparkle delta。

MCP 编辑器、工具面板和指令页的原生验收截图分别输出到
`.artifacts/test-stability/mcp-ui/` 与 `.artifacts/test-stability/instructions-ui/`，随
`test-stability-macos` artifact 提供给评审下载。截图只渲染隔离 fixture 的实际产品视图，
不读取桌面或真实用户配置；按 `agent-ui-test-evidence` 排除于所有工作树资源复制阶段，
本地随报告保留，CI 按 artifact retention 回收，不进入发行包。

MCP 发现页读取的官方 Registry 在线响应登记为 `mcp-registry-metadata`，仅在当前进程内存中保存。
响应最多 1 MiB，由 Rust Core 校验；按搜索、分页和取消请求管理生命周期，没有持久缓存、
平台/架构/工具链身份或允许复制的阶段。资源复用脚本明确拒绝该项，不下载服务器包或图片，
也不写入 app bundle 或 Windows 安装目录，因此不改变签名和 Sparkle delta 基线。
内置精选 `rust/lithe-core/src/mcp/featured.json` 属于 Git 跟踪的编译输入，随本工作树
源码编译进 Core，运行时只读；不从缓存或其他工作树复制，不登记为下载/生成资源。
查询路由默认使用系统代理，显式直连只改变当前页面的内存请求，不产生可复用状态。

精选品牌图标 `macos/Sources/Lithe/Resources/McpIcons` 也是 Git 跟踪的固定输入，
`NOTICE.json` 记录每个来源与 SHA-256，随 SwiftPM 资源 bundle 在构建时打包。
该目录与精选 JSON 一起归入 `mcp-registry-metadata` 的不可复用说明：没有下载缓存、
生成 identity stamp 或跨工作树复制阶段；版本由当前 Git 源码和清单哈希决定，
不从其他工作树或已安装应用提取。运行时只读并在内存缓存解码结果，不访问图标网络，
不改写签名包或 Sparkle delta 基线；Windows 未消费此 macOS 资源目录。
Cargo 社区插件在 [独立仓库](https://github.com/Lithe-IDEA/lithe-plugin-cargo) 中构建，
最终 ZIP、摘要、vendored Node SDK 和集成测试产物由该仓库的 `dist/`、`.artifacts/` 持有，
不作为 Lithe 主仓库的下载缓存或可复用资源。Cargo 专属清单、模型金样与兼容性测试也由
插件仓库持有：其 CI 按 `sdk.lock.json` 固定的宿主提交检出独立的 `.artifacts/lithe-core`，
用公开 JSON API 验证清单、安装审查、识别、解码与任务计划，并实际执行 Core 生成的 Cargo 命令。
宿主依赖按其 Cargo.lock 下载，测试工程的 Cargo 命令使用离线模式；固定基线不代表持续验证未来 preview。
`.artifacts/core-target` 是插件 checkout 私有可变编译状态，不进入主仓库资源复用清单，
不跨 worktree 共享，也不进入发布 ZIP。主仓库保留通用插件契约回归，不下载或组装 Cargo 插件。
插件仓库每次打包校验 `sdk.lock.json` 固定的 SDK 源码提交与文件 SHA-256，
SDK 复制只发生在打包阶段，安装目录保持只读。
官方插件 SDK 已移到 [lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs)：
SDK 的 Maven 构建输出和端到端测试使用的 Lithe 稀疏检出（`.artifacts/lithe`）都属于该仓库，
主仓库不再构建 SDK，也不把这些目录登记为可复用资源。

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

编译 macOS 测试后运行 `./scripts/macos/probe/probe-macos-logging-ui.sh --skip-build`，或省略
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
`node scripts/platform-feature-matrix/generate-platform-feature-matrix.mjs`，校验源数据后重新生成。

IDE MCP helper 由 `scripts/ide-mcp/build-ide-mcp.sh`（macOS）和
`scripts/ide-mcp/build-windows-ide-mcp.mjs`（Windows Tauri 构建前）从当前源码与
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
node scripts/resources/reuse-worktree-resources.mjs --source /path/to/existing-worktree
```

脚本默认处理注册表中的全部资源，也可以重复传入 `--resource` 只处理指定资源：

```bash
node scripts/resources/reuse-worktree-resources.mjs \
  --source /path/to/existing-worktree \
  --resource cargo \
  --resource jdtls \
  --resource jdk
```

`node scripts/resources/reuse-worktree-resources.mjs --list` 可以查看当前注册资源。脚本只允许
同一 Git 仓库的 linked worktree 互相复用资源，不修改源工作树。它先把源资源
复制到目标工作树的临时目录，按照对应的 manifest、lockfile 或完整性清单校验，
再原子替换目标目录并进行第二次校验。目标已有不少于源缓存的有效文件时会保留
目标，不重复复制；校验失败的文件不会发布到目标缓存。

JDTLS 和 JDK 使用
[`third_party/jdtls/manifest.json`](../third_party/jdtls/manifest.json) 与
[`third_party/jdk/manifest.json`](../third_party/jdk/manifest.json) 中的
SHA-256；Cargo、SwiftPM 和 Bun 使用各自的 lockfile、版本与完整性清单。当前
自动复用的资源由 [`scripts/resources/worktree-resources.json`](../scripts/resources/worktree-resources.json)
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
- `.artifacts/conpty-downloads/`：Windows Terminal 发布的
  `Microsoft.Windows.Console.ConPTY` NuGet 包，按
  `third_party/conpty/manifest.json` 固定版本与 SHA-256。包内 x64/arm64 的
  `conpty.dll` 与 `OpenConsole.exe` 解出后写入 `.artifacts/conpty/`，供
  `build.rs` 复制到可执行文件同目录，并由 `tauri.conf.json` 的 bundle
  resources 打进安装包。该校验只接受 manifest 指定版本的那一个归档，
  其余文件直接删除并重新下载。
- `.artifacts/php-language-server-downloads/`：按
  `Plugins/mac/Official/PhpSupport/language-server.json` 下载并校验的
  Intelephense tarball；它只服务当前工作树的插件打包，不能复制解压结果。

Inter 4.1 的 18 个静态 OTF（内部版本 4.001）及许可、JetBrains Mono 2.304 的 16 个静态 TTF、OFL 和作者信息位于 Git 跟踪的
`macos/Resources/Fonts`。同目录增加 Nerd Fonts v3.5.1 的 JetBrains Mono Nerd Font Mono 四个完整 TTF（常规、粗体、斜体、粗斜体）及 OFL 许可，终端可直接选择这些字型而不依赖用户安装；来源、版本和固定 SHA-256 记录于 `NOTICE.txt`。它们与平台架构和工具链无关，随工作树检出，不从另一个
工作树的产物或已签名 app 复用；注册表将 `bundled-ui-fonts` 排除，复用脚本拒绝
复制。打包脚本在签名前复制到 `Contents/Resources/Fonts`，资源门禁检查全部字型；
`BundledUIFontTests` 检查版本、CoreText process 注册、字号/字重、SwiftUI 字体及
注册前后的文件清单与 SHA-256。运行时仅只读注册和 WebKit 加载，不修改 bundle，
不影响 Sparkle delta 的发布基线。

以下目录不应直接复制或跨工作树共享：

- AutoBuild 应用发布校验 staging：
  `<RUNNER_TEMP>/lithe-autobuild-<invocation>/{baselines,verification}/`。
  源码 SHA、应用 release/tag/asset、当前 build/ISO 时间与本次发布共同决定输入；
  根目录生成 `autobuild-publication.json`，`baselines/AutoBuild/` 保存当前入口的检查点与
  双架构 appcast；旧入口仍存在时，`baselines/preview-0.3.0/` 另存其双架构 appcast。
  两组基线用于本次严格时间排序，只有 AutoBuild 接受匹配检查点的精确恢复。
  检查点绑定全部目标字节，不是可跨工作树复制的构建缓存；远端发布资产仅供本次调用下载验证。
  应用产物的平台/架构由共享构建身份及 appcast 约束，保留现有签名，不在发布阶段重新构建。
  不再生成插件目录或下载插件包。缺少可跨工作树复用的 identity stamp，`autobuild-publication-staging` 注册在
  `excludedResources` 并由复用脚本的通用排除路由拒绝，任何复制阶段都不共享。
  每次 gh 子进程有 120 秒期限，暂时性故障最多三次尝试，每次重试先清除本次残片；
  本地输入全部验证后才上传。发布器的 `finally` 删除自己创建的精确 mkdtemp 目录，
  成功和失败都不留下 staging，不写运行时 app bundle，不影响签名与 Sparkle 基线。
  本地工作树只运行 `node --test scripts/release/autobuild/test-publish-autobuild.mjs` 和资源复用测试，
  不复制别的工作树 staging，也不把正式发布命令当作验证命令。

- 插件 UI 图标：包内声明的 SVG/PNG 属于安装版本的签名或社区内容摘要，
  macOS 在安装与启动时校验路径、大小、静态 SVG 子集和原生解码。资源在安装
  阶段随包复制，运行时只读，内存图像随当前进程目录释放；不创建磁盘缓存。
  `excludedResources.plugin-ui-icons` 通过复用脚本已有的排除资源路由拒绝复制，
  `scripts/resources/test-reuse-worktree-resources.mjs` 验证该路由。
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

- Windows 项目生成器归档事务：用户选择可写父目录后，原生事务独占创建同级
  `.<project-name>.lithe-creating-<operation-id>/`，仅在其内通过 `create_new` 写入
  `.lithe-project-archive-<nonce>.zip`。每次受限 HTTPS 下载把重定向响应体计入同一个
  128 MiB 预算、使用最长 120 秒的下载期限和同一取消 token；同步调用既有 Core
  `project.extractArchive` 时保留原 operation ID 与操作剩余期限。Core 在写入前校验路径、
  链接及显式/隐式目录预算，展开内容最多 512 MiB、20,000 个路径节点、64 层，累计路径
  UTF-8 字节最多 16 MiB。ZIP 描述符关闭后即删除；全部写入者结束、校验通过后才原子
  不覆盖发布。失败或取消清理失败时保留 staging 与插件租约重试，无法确认写入者结束时
  不能删除目录或声称清理完成。`excludedResources.project-generator-transactions` 在任何
  工作树访问或复制前直接拒绝；HTTPS 内容没有固定摘要、版本、平台、架构或工具链
  identity stamp，不能复用、共享、软链接或打包。运行
  `node --test --test-timeout=60000 scripts/resources/test-reuse-worktree-resources.mjs` 验证排除路由。
  全程只写用户选择的目录，不改动安装资源、代码签名或 Sparkle delta 基线。
  capability 仍关闭，完整 Windows 原生及实机验证仍待完成。

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
  验证运行 `node scripts/resources/test-reuse-worktree-resources.mjs`，确认排除项不在 `--list` 且
  混合复制请求在任何工作树访问前失败；运行 `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
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

- Agent 粘贴图片保存在 `<platform-app-cache>/agent/pasted-images/pasted-<UUID>.<扩展名>`；放弃的批次立即删除自身文件，已接受的附件保留供历史会话引用。撤销新建文件时，原生文件 adapter 先移动到同目录 `.lithe-agent-recovery-<pid>-<sequence>-<filename>` 再回收，失败则恢复；若原路径被重新创建，保留恢复文件并向用户报告位置。两类资源均是用户运行时可变状态，没有版本、平台、架构、工具链 identity stamp，任何复制阶段都禁止共享。清单 `agent-edit-and-paste-state` 和复用脚本的排除路由直接拒绝；应用安装资源保持只读，不影响签名和更新基线。

- `.artifacts/bun-tmp/`、下载或解压过程中的临时目录；
- `.artifacts/jdtls/`、`.artifacts/jdk-*` 等可以由已验证下载重新生成的解压输出；
- `.artifacts/editor/macos/`、Monaco probe/workbench 资源与其中的主题许可证、NOTICE，
  由 `editor-theme-assets` 排除路由拒绝复用。它们与当前源码、上游色表固定提交、Monaco/Bun
  版本绑定，没有可靠构建身份 stamp；各工作树构建时一起生成 JS 并复制许可证，不在任何阶段
  跨树复制。运行时只读，不改变签名和 Sparkle delta。官方插件等尚未写入构建身份 stamp 的
  生成资源同样不得复用；
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

### Java Support 独立下载安装与迁移

Java Support 当前仍随应用发行，独立下载的构建配置已登记，但
`Plugins/marketplace/official-plugins.json` 中的 `releaseEnabled: false` 暂停自动发布。
等支持 `packageTrust: 1` 的宿主发行、迁移验收和真实下载包验证完成后，再单独启用发布；
不要在基础设施 PR 中提前上架旧宿主无法安装的包。

`bundledUntilPublishedVersion: 1.1.0` 控制过渡副本的退出条件：只有仓库官方索引
包含达到门槛且 API/能力匹配的完整双架构版本，应用才跳过 JDT/JDK 准备及 Java 插件组装。
空索引或缺少某个架构仍内置；损坏索引会中止构建，不能静默省去插件。安装使用同一 ID，
启用、禁用、旧卸载标记及设置保留；打开 Java 文件/项目或新建项目时有明确安装入口，
离线可使用可信磁盘包。当前无线上发布，默认构建仍保留过渡包。

构建输入 `LITHE_OFFICIAL_PLUGIN_INDEX` 默认为 `Plugins/marketplace/index.json`，只读，
同时决定内置分发和应用内嵌索引；传给 `scripts/plugins/build-official-plugins.sh --marketplace-index`。
没有下载或缓存步骤，不允许从其他工作树的生成索引或用户运行时索引复用。
`scripts/macos/verify/verify-macos-package.sh --slim` 在本次临时目录生成双架构索引 fixture，并验证在缺少
JDT/JDK 输入时仍能生成不含 Java 资源的 universal app 和 DMG；fixture 不是可发布索引，
随测试目录清理，不影响签名或 Sparkle 发行基线。

同一份清单要求下载版的 `publisherPackage` 签名，并声明内置副本的
`bundledSignatureRequirement: sameTeamAsHost`。应用组装必须显式用 `--bundled-only`，
由 app 自身签名封住完整包；普通单插件构建在正式配置中始终要求发布者私钥。
本地开发只能用 debug + `--development-unsigned`，不能把开发包用于正式发布。
原生 JDK 使用构建时固定、校验过的上游签名，包内最终字节完成后再生成 Ed25519 签名。

发布计划包含 `darwin-arm64` 和 `darwin-x64` 两个 ZIP，各自一个 SHA-256；
源码和资源输入变化后需要新的插件版本。重试索引发布时，从对应 tag 读取
配置、清单和 API/`requires`，下载并计算全部资产哈希后一次写入版本，不能读取
当前工作树的清单来描述历史包。目录如下：

- `dist/packages/<arch>/<plugin-id>/`：本次发布组装的最终签名包。
- `dist/verify/<arch>/<plugin-id>/`：归档解压后的签名验证副本。
- `dist/Lithe-Java-Support-<version>-darwin-<arch>.zip`：按架构的发布归档。
- `.artifacts/java-plugin-distribution/`：本地真实资源组装、归档、签名和启动检查输出。

这些输出和 `.build/.../OfficialPlugins` 一样没有可跨工作树转移的 identity stamp，
全部进入 `official-plugin-packages` 排除路由；不允许复制或共享。需要复用的只有
经既有 `jdtls` / `jdk` 路由核验的下载缓存，再在目标工作树重新组装。
临时验证副本由本次验证清理，发布 runner 的 `dist` 随 job 结束回收；持久安装的
版本包由宿主包管理器负责，运行时保持只读。它们不改变应用签名或 Sparkle 源基线。

Java Support（`dev.lithe.plugin.java-support`）是过渡期唯一随 Lithe.app 发行的官方插件包，
也是唯一自带运行时的包，因此它与架构有关：

- **资源路径**：组装结果在 `.build/<triple>/<configuration>/OfficialPlugins/dev.lithe.plugin.java-support/`，
  打包后位于 `Lithe.app/Contents/Resources/OfficialPlugins/` 下。包内 `language-server/` 是固定版本的
  JDT LS 及 Lombok、Java Debug、Java Test 扩展，`runtime/<arch>/` 是它运行所用的 JDK。
  `icons/` 和 `templates/` 是新建项目窗口里 Java、Maven Archetype、Spring Boot 条目的图标和模板，
  从源码目录直接复制，不下载、与架构无关；模板只读，新项目先写进用户所选目录下的临时目录，
  完成后整体移动到位，不写 app bundle 或插件包，不影响代码签名和 Sparkle delta。
- **组装入口**：`Plugins/mac/Official/JavaSupport/assemble-package.sh`，由
  `scripts/plugins/build-official-plugins.sh` 调用，`--arch arm64|x86_64|universal` 决定带哪些架构的 JDK
  和 Equinox 配置。应用本身不再包含 `Contents/Resources/LanguageServers`。
- **是否允许跨 worktree 复用**：组装后的包不允许复用。它由 `jdtls` 和 `jdk` 两个可复用的下载缓存
  生成，新工作树应复用这两个缓存后在本地重新组装。
- **身份约束与校验来源**：JDT LS 的版本、下载地址和校验值来自 `third_party/jdtls/manifest.json`，
  JDK 来自 `third_party/jdk/manifest.json`；`plugin.json` 精确写出入口 jar 的文件名，升级 JDT LS
  后文件名不一致会在组装时失败。组装结果由 `LitheOfficialPluginVerifier` 校验：入口和各架构的
  `bin/java` 存在，包内没有符号链接，Mach-O 只出现在清单声明的 `runtime/` 目录内。Rust Core 测试
  `project_generators` 用源码目录里的模板生成每个生成器的计划。
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
排除路由直接拒绝，由 `scripts/resources/test-reuse-worktree-resources.mjs` 验证，不能给它增加缓存校验器。

Windows 的 Lithe 根映射保存在平台 adapter 返回的
`<windows-app-local-data>/vcs-roots/<native-workspace-identity-sha256>.json`，
只在用户明确保存时创建；每个来源最多 1 MiB、64 条选择。它保留未知 JSON 字段和权限，
以原始字节版本拒绝外部冲突，复用设置 adapter 的同目录 `.tmp` 与 `.backup` 替换/恢复流程。
工作区及选中根的原生目录身份防止相同路径的新目录继承旧选择；活动监听另按窗口、工作区登记、
incarnation 与扫描代次隔离，关闭或插件撤销即释放。映射是 Lithe 自有偏好，不写 SVN/Git 配置。
它们没有可复用的版本、平台、架构或工具链 stamp，`excludedResources.vcs-root-mappings`
在任何复制阶段都由脚本排除路由拒绝；临时文件、恢复备份和内存监听 lease 同样禁止共享。
平台可写应用数据与只读安装资源分离，因此不影响代码签名或 Sparkle delta 基线。

插件宿主的 `<app-support>/Lithe/PluginHost/root-id.key` 是安装级密钥，
`<app-support>/Lithe/PluginState/<plugin-id>/backend/workspaces/<workspace-digest>/`
是按插件、工作区归属的可变状态。二者都没有版本/平台/架构/工具链复用身份，
任何复制阶段都不得共享；`excludedResources.plugin-host-runtime-state` 走拒绝路由，
由资源复用测试验证。运行期仅写平台 Application Support，不改签名包或 Sparkle 源基线。

如果后续新增可复用资源，必须同步更新注册表、校验器、脚本测试和本节说明。
Windows 的插件源配置、按源与平台缓存的原始索引、摘要绑定的临时下载和按工作区保存的构建选项，
同属 `plugin-marketplace-state` 排除路由：由运行时平台 adapter 注入用户可写根，
取消或失败清理临时文件，持久配置由当前用户实例管理；没有可复用的版本/架构/工具链 identity，
不得在任何 worktree 复制阶段共享，也不写入发行资源或改变签名及增量更新基线。
Windows 命令模型的 `<windows-app-local-data>/plugin-state/<plugin-id>/build-<pid>-<operation-sequence>.model.json`
及依赖输出的同目录 `build-<pid>-<operation-sequence>.dependencies.json`
按 `official-plugin-packages` 排除路由处理：由当前窗口、工作区代次和操作独占，确认后以
`create_new` 创建，进程树清理完成后删除；清理失败时与原 owner 一起保留，崩溃遗留由插件状态/卸载流程回收。
二者均无版本/平台/工具链复用身份，不跨工作树复制，不改变发行资源、签名或增量更新基线。
显式 SVN move 诊断入口 `python -B scripts/plugins/host-acceptance/vcs_move_diagnostic.py --inputs <fixed-inputs.json> --output <new-evidence-directory>` 只接受固定 Provider、历史 SDK、已校验 VisualSVN ZIP/解压树和诊断 gate。它在 OS 临时目录创建 suite-owned runtime，以及每 case 独立的 repo/WC 和 profile；这些状态及显式 ignored 输出均走 `plugin-host-acceptance-state` 排除路由，不跨 worktree 复制。源码字节身份只证明本次诊断输入，不是可复用构建 stamp。Job 零成员证明成立后移除临时状态，保留诊断证据；清理未获证明时保留隔离目录并停止恢复读取，不承诺已清理。不写发行资源、不影响签名或 Sparkle delta。该入口不下载、不构建、不运行产品，不代表 move 准入。

ui:2 Web 回退夹具由 `web_bridge_fallback_fixture.py --output .artifacts/plugin-host-acceptance/web-bridge-fallback-fixture` 在目标工作树重新生成。静态 unsigned ZIP、工作区、source plan、私有页 CDP paused-request 决定、transport descriptor/回调 Map 观察及资源快照均属于 `plugin-host-acceptance-state`，没有可迁移的安装审批或可复用构建 identity；所有复用阶段拒绝，不新增下载校验路由。显式 `web_bridge_fallback_acceptance.py --help` 的执行入口消费同基线的隔离 x64 Release identity，使用 AppSession 保留句柄和本地 deadline，在失败路径释放 Fetch/CDP、退出产品并移除隔离 profile。CDP 仅令一次精确 IPC POST 失败；不改写 JS transport，不写发行镜像和已安装包，签名及增量更新基线不变。受控 ui:2 子集通过仍保留完整 M10、其他能力和平台 pending。

ui:1 字面文本验收由 `text_window_acceptance.py` 为本次已绑定端口的计数服务生成完整 unsigned API3 `requires.ui=1` 包。`text-window-fixture*` 的 ZIP、工作区、source plan，私有宿主文本页的 DOM/CSP、预加载请求、桥 descriptor/回调 Map 及计数器正向控制和零字面 URL 请求证据，均属于 `plugin-host-acceptance-state`；没有版本/平台/架构/工具链可复用 stamp，所有复制阶段拒绝，不新增下载校验器。计数服务、浏览器观察、产品与 profile 仅由本次调用所有，失败路径也有界收尾；证据随本地审查或 CI retention 回收。运行时不写发行镜像或插件安装包，不影响签名与增量更新；受控 x64 文本子集不代表签名完整包或完整 M10。

执行入口为 `pwsh -NoProfile -File scripts/plugins/test-windows-declarative-plugin-host.ps1 -TextWindow`，与 marketplace/LSP/settings 模式互斥。入口保存构建前后的完整源码库存，确认相同后写入隔离宿主 identity；`-SkipBuild -TextWindow` 只能消费已有且源码、配置、EXE 哈希均匹配的 identity，旧 marker 缺失库存时必须重建，不能事后补填。源码扫描共用 300 秒截止时间，运行驱动由外层 900 秒 deadline 约束。浏览器网络观察不能计数原生 postMessage IPC，报告明确保留该限制，不能把回调排空解释为精确零 IPC。R19 仅完成工具及离线失败边界，lane 构建超时且未产出验收 EXE，真实产品步骤仍 pending。

正式 Windows 构建与插件宿主验收入口接受 `-NativeBunPath <native-bun.exe>`；
该参数只选择已有的原生可执行文件，不安装 Bun。入口先检查其版本与目标工作树的
`packageManager` 固定版本一致，再把所在目录加入继承的 PATH，确保 Node 资源校验器及
安装子进程找到原生 Bun；PowerShell/npm shim 本身不能作为 Node 的执行目标。
`-InstallTimeoutSeconds` 默认为 300，范围为 1～1200 秒，逐层传到既有安装 worker；
这是每次安装尝试的时限，缓存失败后的既有无缓存重试各自使用该值，不能当作整个构建时限。

Tauri 构建包装器保留原始 `Cargo.toml` 字节。动作结束后，只有内容恰好等于原始字节的
CRLF→LF 转换才允许恢复；比较和恢复使用同一个独占文件句柄，未改动的字节和写入时间不变。
其它语义改动、删除或被并发进程锁定的文件保持现状并使构建失败，不能重新创建或覆盖它们；
若构建动作和恢复检查同时失败，两条诊断均保留。该边界不允许以 TOML 等价或文本摘要
代替构建前后源码的精确字节身份。

离线准备回归 `build_preflight_test.py` 使用 `<os-temp>/lithe-build-preflight-*/` 的一次性
副本、伪 Bun/IPC 子进程、可变 manifest 和记录 stub；不调用 Cargo、Tauri 或产品。
JDTLS 解压回归还在同一临时树生成小型 tar.gz/VSIX、前置 PATH 的假 tar 和提取产物，
全部保持一次性 owner，拒绝跨 worktree 复用。Windows JDTLS 准备直接从平台
`[Environment]::SystemDirectory` 选择原生 tar，不依赖 MSYS/GNU tar 的 PATH 顺序；
缺少原生工具时在缓存或输出变更前失败，解压非零立即保留原生错误并停止后续复制。
测试套件使用 180 秒预算，CI 与正式验收入口另有 190 秒的既有保留句柄进程 owner；
单项等待仍各自有界，超时按原进程身份回收。报告为
`.artifacts/test-stability/plugin-build-preflight.{json,html,junit.xml}`，
临时树和伪工具按 `plugin-host-acceptance-state` 排除路由拒绝所有 worktree 复制，
没有可复用的版本、平台、架构或工具链 stamp，退出时清理本次资源。
这些离线检查只能证明准备流程和失败边界，真实 `ui:1` 产品步骤仍须另外验收。

原生插件验收的 `.artifacts/plugin-host-acceptance/`（含市场 ZIP/索引、构建夹具的包、工具、工作区及 plan、`settings-functions-fixture*` 的包/工作区/身份 plan、设置与函数验收资源快照、隔离运行镜像和报告）及
`app.lithe.windows.host-acceptance` 用户配置走 `plugin-host-acceptance-state` 排除路由：
每次在目标工作树重新生成，无可复用 identity，不跨 worktree 复制；驱动回收监听器、进程和隔离用户数据，
报告留在本次验证目录。HTTPS 使用已有可信证书，不复制私钥或改系统信任，也不改发行资源及签名基线。
设置/函数入口先运行 `python -B scripts/plugins/host-acceptance/settings_functions_fixture.py --output .artifacts/plugin-host-acceptance/settings-functions-fixture`，
再用 `settings_functions_acceptance.py --fixture-root <该目录> --report <报告路径>` 做离线预检（pending 返回 2，输入错误返回 1，不启动产品）。
真实执行由已有 `test-windows-declarative-plugin-host.ps1 -SkipBuild -SettingsFunctions -SettingsFunctionsFixtureRoot <该目录>` 消费隔离宿主 identity；
plan、当前 checkout 和隔离宿主的提交标识必须一致；切换提交后重新生成输入，不得清理该输入目录后冒用旧 plan。
`-SkipBuild` 同时检查目标架构、已冻结配置和可执行文件哈希，并保留该配置；配置或提交变化时重新构建隔离宿主。驱动先恢复原生 invoke 并有界等待已观测调用结束，再退出本次产品进程，最后比较资源快照；退出失败或调用未结束不能报告资源工作流通过。
驱动在插件详情验证普通设置，再经已注册的语言设置页保存 reload；受控设置子集通过不会把缺少兼容签名包、关闭中的 Provider 能力、arm64 或人工视觉验收算作通过。

项目生成器的 `generator_fixture.py` 在本工作树生成完整 unsigned 社区包、模板、空工作区、
项目输出目录及绑定当前源码清单的 plan。显式 HTTPS 集成输入还须提供原 ZIP 和 receipt
（仓库、固定提交、许可、URL、SHA-256、字节/条目数与预期打开文件），例如：

```powershell
python -B scripts/plugins/host-acceptance/generator_fixture.py --output .artifacts/plugin-host-acceptance/generator-fixture-current --archive-url <fixed-HTTPS-ZIP> --archive-open-file <relative-path> --archive-reference <downloaded-ZIP> --archive-receipt <receipt.json>
python -B scripts/plugins/host-acceptance/generator_acceptance.py --fixture-root .artifacts/plugin-host-acceptance/generator-fixture-current --report .artifacts/test-stability/plugin-generator-preflight.json --preflight
```

预检不启动产品，未执行返回 2；真实创建子集由
`test-windows-declarative-plugin-host.ps1 -SkipBuild -ProjectGenerators -ProjectGeneratorsFixtureRoot <fixture>`
消费已冻结的隔离 x64 Release identity，当前源码清单、配置、提交和 EXE 字节必须一致。
驱动使用既有 assign-before-release Windows Job，600 秒总期限包含产品及子进程；工作流
留出清理余量，原进程退出和真实向导卸载须早于命令的自然期限，未知 marker PID 不授权清理。
实际 HTTPS 解压的每个上游文件与固定参考 ZIP 比较；下载内容不执行。失败保留首次记录，
退出后比较实际运行镜像、已安装包和原完整 fixture ZIP；受控子集不代表完整 M8/M10。

`generator-fixture*` ZIP/plan/项目、`generator-archive-input` 固定归档/receipt、
进程与清理证据均归既有 `plugin-host-acceptance-state`；没有可复用的版本、平台、架构或
工具链身份，所有复制阶段拒绝。重新在目标工作树生成，不能从来源工作树拷贝安装审批、
用户配置或项目。它们只写本次 artifact、隔离用户配置与用户工作区，不影响代码签名或
Sparkle 增量更新基线。报告依本地审查或 CI retention 保留，临时应用和配置按 owner 清理。

原生动作组、表单栅格和树菜单的受控浏览器回归使用目标工作树的前端依赖和 Python Playwright 1.60.0
（与原生验收驱动共用 `psutil==7.2.2`），不由 runner 安装或下载工具。Windows CI 在已有
Python 依赖步骤后独立运行以下命令；本地已有 Edge 时可复用相同入口：

```powershell
$playwrightModule = python -c "from pathlib import Path; import playwright; print(Path(playwright.__file__).parent / 'driver/package/index.mjs')"
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the configured Playwright driver' }
node scripts/plugins/test-windows-native-plugin-ui-browser.mjs --browser msedge --playwright-module $playwrightModule --timeout-ms 120000 --report .artifacts/test-stability/native-panel-browser.json
if ($LASTEXITCODE -ne 0) { throw 'Action-group browser regression failed' }
node scripts/plugins/test-windows-native-plugin-ui-browser.mjs --mode native-tree --browser msedge --playwright-module $playwrightModule --timeout-ms 120000 --report .artifacts/test-stability/native-tree-browser.json
if ($LASTEXITCODE -ne 0) { throw 'Native-tree browser regression failed' }
node scripts/plugins/test-windows-native-plugin-ui-browser.mjs --mode form-grid --browser msedge --playwright-module $playwrightModule --timeout-ms 120000 --report .artifacts/test-stability/native-form-grid-browser.json
if ($LASTEXITCODE -ne 0) { throw 'Form-grid browser regression failed' }
node scripts/plugins/test-windows-native-plugin-ui-browser.mjs --mode controls-input --browser msedge --playwright-module $playwrightModule --timeout-ms 120000 --report .artifacts/test-stability/native-controls-input-browser.json
if ($LASTEXITCODE -ne 0) { throw 'Controls-input browser regression failed' }
node scripts/plugins/test-windows-native-plugin-ui-browser.mjs --mode workbench --browser msedge --playwright-module $playwrightModule --timeout-ms 120000 --report .artifacts/test-stability/native-workbench-browser.json
if ($LASTEXITCODE -ne 0) { throw 'Workbench browser regression failed' }
foreach ($failure in @('worker-exit', 'worker-hang')) {
  node scripts/plugins/test-windows-native-plugin-ui-browser.mjs --mode lifecycle --inject-failure $failure --timeout-ms 25000 --report ".artifacts/test-stability/native-browser-$failure.json"
  if ($LASTEXITCODE -ne 0) { throw "Lifecycle regression failed: $failure" }
}
```

动作组、栅格和树模式加载生产样式及真实 React 组件，使用官方 Tauri mocks；动作组检查六阶段
几何、状态、焦点、禁用提示与单次完整值提交，树模式由 Playwright 的浏览器键盘输入
检查菜单触发、导航、关闭、焦点和一次性动作。栅格模式固定浏览器 viewport，只调整夹具容器，
检查 12 列/span 在 639px、640px 和宽容器的几何、同一 DOM、草稿、焦点、禁用说明、公共
readOnly 原语及完整 values 单次提交；不把 typed port 的可选 selectedID 当作下游 JSON null。
控件输入模式在同一完整夹具上验证 select、checkbox、search/clear、editor、segmented、stepper
的实际浏览器交互、按原 onCommit 语义自动提交或仅保留草稿、禁用组拒绝输入和最终完整 values。
所有模式均通过公共控件的可访问角色定位实际编辑节点，不把隐藏校验 input 当成用户输入。
工作台模式复用真实 MainLayout、活动入口、公共控件及三个既有槽，连贯检查打开、输入、树动作、
替换、移动、隐藏重开、工作区切换、迟到准备取消和关闭清理。原生 I/O、审批、终端内容及外部包/
窗口身份仍为受控边界；单页重建不能作为两个产品窗口验收。工作台报告与日志也属于不可复用资源。
五个组件模式各有 120 秒整体时限；
生命周期模式不加载 Vite 或浏览器，用提前退出和挂起的受控 worker 验证独立 owner 的清理，
25 秒整体时限中保留 20 秒收尾。Windows CI 的组合步骤另有 12 分钟外层上限。
各模式成功或失败都生成独立 JSON、HTML 和 JUnit，不代表产品 WebView2、物理键盘、IME
或 `ui:3` 准入。
生命周期的预期红报告留在报告父目录的 `expected-failures/` 子目录，普通报告只记录
实际验证失败分类、子进程启动、Job 零成员证明和临时目录清理的正向断言；
不能把预期红报告混入顶层通过总数，也不能把一次注入失败解释为产品验收通过。
每次调用独占 `.artifacts/native-browser-*/` 下的 `profile/`、Vite `cache/`、
`worker-evidence.json`、`job-result.json` 和 `worker.log`；退出后把 worker 日志复制到
报告同名的 `.worker.log`，便于 scratch 删除后诊断。进程先受 Windows Job Object
约束再执行，整体时限包含清理预留。只有进程树终止得到证明后才能删除 scratch，
无证明则失败并保留隔离目录。报告由本地审查或 CI retention 回收。
这些路径及显式报告没有版本、平台、架构或工具链构建 stamp，
`excludedResources.native-browser-regression-state` 通过复用脚本的排除路由在任何复制阶段拒绝，
在目标工作树重新生成，不能共享浏览器 profile、优化缓存或进程所有权。
所有写入都在本次工作树的忽略目录，不写安装包、发行资源或签名和 Sparkle delta 基线。

Windows 项目生成器的 `<workspace-parent>/.<project-name>.lithe-creating-<token>/` 暂存及最终用户项目
走 `plugin-generator-transactions` 排除路由：由当前窗口和原生操作独占，先在用户选择的目标旁生成，
验证后原子不覆盖发布；取消或失败清理同一 staging，清理失败保留操作与 NativeLease 供重试。
没有版本/平台/架构/工具链复用身份，任何复制阶段均拒绝；不写插件包或发行资源，不影响签名与更新基线。
Windows 插件设置的 `<windows-app-local-data>/plugin-settings/<plugin-id>.json`、工作区
`.lithe/plugin-settings.json` 及同源 `<settings-source>.json.<pid>-<sequence>.tmp/.backup`
走 `plugin-settings-state` 排除路由。真实偏好由当前用户持有，保存事务持有临时文件和恢复备份；
打开只读，确认保存时比较原始字节、保留无关值与权限、原子替换并重读。失败清除自己的临时文件，
恢复不能确认时保留唯一备份并提示恢复。没有构建 identity，不能跨工作树共享；不写发行目录、签名或更新基线。
生成资源只有在构建流程写入可验证的源码、配置、平台、架构和工具链 identity
stamp 后才能加入注册表，不能仅凭目录存在就跨 worktree 复制。

The artifact behavior and compression setting follow
[actions/upload-artifact](https://github.com/actions/upload-artifact), and cache
reuse follows GitHub's
[branch access restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).

Windows PHP Worker 插件使用 `bun scripts/windows/build/build-windows-php-plugin.ts` 单独构建到
`.artifacts/windows-plugins/`，通过 `node scripts/windows/verify/verify-windows-plugin-isolation.mjs`
检查入口独立性。它绑定包格式、宿主 SDK 和当前 Bun 构建版本，没有 identity stamp，
在资源清单中注册为不可复用；不随 Windows 应用构建复制。用户导入后的源码与状态
位于 WebView 用户配置的 `lithe.worker-package:<id>`，也禁止跨 worktree 复用。
CI 在 Windows frontend lane 构建并上传独立包，同时运行包、Worker 协议和生命周期测试。

### Agent Hook 用户状态

`<app-support>/Lithe/AgentHooks/`（Windows 为平台 app-data 根目录下的
`AgentHooks/`）保存 `hooks.json` 和 `.sync.lock`。资源库包含用户命令及原生
配置条目的写入前所有权记录；它没有版本、平台、架构或工具链构建身份，
任何复制阶段都禁止跨 worktree 复用。仅显式保存、启停、删除或重试会写入。
每次原子替换产生的 `.lithe-instructions-<UUID>.tmp` 由共用文件 adapter
在成功和失败后清理；空锁随用户资源库保留。Codex `hooks.json`、Claude
`settings.json` 仍属于对应用户配置，不属于构建资源。Hook 执行与信任由
原生 Agent 负责；所有状态都在可写用户目录，运行时不改变发行 bundle、
代码签名或 Sparkle delta 基线。

原生 UI 截图位于 `.artifacts/test-stability/hooks-ui/`，绑定本次源码、主题、
语言和窗口尺寸，不作为可复用资源。运行 `node --test scripts/resources/test-reuse-worktree-resources.mjs`
验证 `agent-hook-library-state` 被复用入口拒绝。
