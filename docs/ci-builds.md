# CI builds and test downloads

CI 构建缓存、架构并行、测试产物和 artifact 保留策略见
[`2026-09-13-ci-build-cache-and-artifact-strategy.md`](../.agents/notes/implemented/process/2026-09-13-ci-build-cache-and-artifact-strategy.md)。
本文只保留 CI 使用说明、下载方式和本地资源复用规则。

仓库里的桌面端工作流只有三个，都位于 `.github/workflows/`：

| 工作流 | 触发 | 内容 |
| --- | --- | --- |
| **Desktop CI**（`desktop-ci.yml`） | PR（Draft 只跑 Linux 作业，`ready_for_review` 时补跑完整矩阵）、推送到 `main`、手动运行 | `pins` 校验固定版本；`linux`（Format and script tests）运行 gofmt、ShellCheck、本地化校验、安装资源路径检查和脚本测试；`linux-test` 通过 `scripts/desktop/check.sh` 运行 Linux 的 vet 和测试；`macos`（`macos-26`）、`windows`（`windows-2022`）同样运行 vet 和测试，只在非 Draft 时执行 |
| **Desktop Release**（`desktop-release.yml`） | 推送 `desktop-v*.*.*` 标签，或手动运行并填写版本 | 打包并校验 macOS、Windows、Linux 产物，核对校验和，然后创建或更新 GitHub prerelease。手动版本必须与 `desktop/viva.toml` 中的版本一致 |
| **Desktop AutoBuild**（`desktop-autobuild.yml`） | 每天 UTC 10:00 定时，或手动运行 | 构建 macOS arm64 与 x64、Windows x64、Linux x64 和 arm64，发布到滚动预发布 `desktop-AutoBuild`。同一提交已经发布时，定时运行不会重复构建 |

- Draft PR 只运行 Linux 检查：macOS 和 Windows 作业带有 `draft == false` 条件。标记为 ready 后，才运行完整的 Desktop CI。
- `Desktop CI gate` 汇总固定版本、Linux 格式与脚本、Linux 测试、macOS 测试和 Windows 测试；普通 PR 必须全部成功，Draft 只允许跳过 macOS 和 Windows。更换已有 PR 的目标分支后，保留 Draft 状态；需要评审时标记为 ready 以针对新基线重新运行完整检查。单纯修改标题或正文不触发平台 runner。
- Desktop CI 通过 `scripts/desktop/check.sh` 执行 Go 检查，Rust 内核由 `scripts/desktop/build-desktop-core.sh` 按 `PINNED_CORE_REVISION` 固定的 Lithe-core-rust 修订构建。
- Desktop Release 的打包脚本是 `scripts/ci/desktop-release/package-release.sh`，AutoBuild 的打包和发布脚本位于 `scripts/ci/desktop-autobuild/`。
- 两条发布入口共用 `scripts/desktop/package-desktop.sh`，通过 Viva 的 `--cgo` 选项保留 Rust Core 原生桥接；`desktop-go.sh` 提供目标编译器、静态库及头文件。Linux 发布包由 Ubuntu 22.04 构建，其系统库兼容性需要单独验证，不能按 Viva 的默认纯 Go 包假设没有 glibc 依赖。
- 本地复现与 CI 相同的检查见 [`desktop-getting-started.md`](development/desktop-getting-started.md) 的“提交前检查”。

### AutoBuild 每日发布

`desktop-autobuild.yml` 每天 UTC 10:00（北京时间 18:00）定时运行，也可以在 Actions 页手动运行，并通过 `source_branch` 选择要构建的分支（默认 `main`）。定时任务使用默认分支 `main` 上的工作流文件，并构建 `main` 的源码；手动运行可以通过 `source_branch` 覆盖源码分支。工作流修复通过 PR 直接合入 `main`。

流程分三步：

1. `prepare` 固定源码提交并记录身份。版本取自 `desktop/viva.toml` 的 `[app] version`，build 号由同一时刻的 UTC 时间生成（`YYYYMMDD.HHMMSS`），并记录标准 ISO 时间。定时运行发现 `desktop-AutoBuild` 标签已指向该提交时直接跳过，不重复构建。
2. `build` 在 macOS arm64 与 x64（`macos-26`）、Windows x64（`windows-2022`）、Linux x64 和 arm64 上检出同一提交，运行 `scripts/ci/desktop-autobuild/package-autobuild.sh` 打包。macOS 有完整证书时使用 Developer ID 签名，否则使用 Viva 的临时签名（ad hoc）封装完整应用包，并在上传前校验签名。临时签名不等于 Apple 公证，首次打开仍可能被系统拦截；Windows 没有证书时保持未签名。每个平台只拿到自己的签名密钥。打包产物作为 artifact 保留 3 天。
3. `publish` 等全部平台构建成功后，检出 `github.workflow_sha`（工作流自身所在提交）中的 `scripts/ci/desktop-autobuild/publish-autobuild.sh`，把安装包发布到滚动预发布 `desktop-AutoBuild`。该 Release 始终是 prerelease，不会标记为 latest。并发组保证同一时间只有一次发布。

正式版由 `desktop-release.yml` 发布：推送 `desktop-v*.*.*` 标签，或手动运行并填写与 `desktop/viva.toml` 一致的版本。它打包并校验三个平台的产物后创建 prerelease，与 AutoBuild 的 Release 互不替换。

合并修复后，可等待下一次定时任务，或由仓库所有者及 `LITHE_RELEASE_ACTOR` 中的授权发布者手动重新构建并发布：

```bash
gh workflow run desktop-autobuild.yml \
  --repo 1lck/Lithe-IDEA \
  --ref main \
  -f source_branch=main
```

不要直接重跑旧的失败任务，它仍然使用旧的工作流文件。确认各平台 build job 与 publish job 均成功后，再检查 `desktop-AutoBuild` Release 的更新时间和资产。

Desktop Release 与 AutoBuild 共同读取 `scripts/ci/common/desktop-packages.mjs`，系统、架构和下载格式必须相同：

| 系统与架构 | 下载格式 |
| --- | --- |
| macOS Apple 芯片（ARM64） | DMG、ZIP |
| macOS Intel（x64） | DMG、ZIP |
| Windows x64 | 安装版 EXE、便携版 ZIP |
| Linux x64 | DEB、RPM、tar.gz |
| Linux ARM64 | DEB、RPM、tar.gz |

总共 12 个包和 12 个 `.sha256` 校验文件。RPM 架构名分别是 `x86_64` 和 `aarch64`。两个流程发布前都按完整清单校验文件名、非空内容和 SHA-256；少包、多包、旧包或哈希不一致均停止发布。Desktop Release 额外检查 RPM 内的版本、发行号和架构，以及 RPM 内部摘要。RPM 使用固定 Viva 打包器声明必需的文字与 XCB 共享库依赖，包管理器按共享库能力选择当前发行版的提供者。

macOS 的本地手动打包可用 `package-desktop.sh --ad-hoc-sign` 生成有完整资源签名的测试包；此选项不代替 Developer ID 或 Apple 公证，首次打开仍按 README 手动放行。所有签名只在构建阶段执行，应用运行时不修改安装目录。新增格式仍使用原有 `dist/desktop/` 和 `dist/autobuild/` 输出，没有新增可复用缓存或运行时资源。

### 独立工作树的本地编译

Viva 编辑器性能基线 `scripts/desktop/perf/editor-bench.sh` 把每次运行的原始输出和 Markdown 预算报告写入当前工作树的 `.artifacts/editor-perf/`（`run-<UTC 时间戳>.txt`、`record-<UTC 时间戳>.txt` 及同名 `.md`，以及开发者用 `--out` 指定在该目录下的文件）。它们只属于这一次运行，受源码修订、机器、CPU、运行时负载、Go 工具链和大文档大小（默认 10 MiB，可用 `LITHE_EDITOR_PERF_LARGE_BYTES` 或 `--large-bytes` 修改）影响；没有可验证的跨树身份 stamp。`editor-perf-reports` 排除路由在任何复制阶段拒绝复用，由开发者在本地清理；该基线不是 CI 必跑项，CI 不运行基准，也没有 artifact。随仓库提交的历史记录 `desktop/benchmarks/history/*.jsonl` 由 Git 跟踪，属于源码而不是下载或生成资源，各工作树从 Git 检出，不经复用脚本复制。这些文件都不进入安装包，也不会改变代码签名或增量更新。

Viva 的 Core 源码检出、Cargo 目标目录和暂存静态库位于当前工作树的
`.artifacts/desktop/lithe-core-rust/` 与 `.artifacts/desktop/lithe-core/`。暂存身份记录包含
修订、目标、profile 与编译器；Windows GNU 构建还固定设置上游 winapi 的
`WINAPI_NO_BUNDLED_LIBRARIES=1`，直接链接已安装 MinGW 的系统导入库，并记录
`winapi-import-libraries=mingw-system`。这避免 cgo 依赖 Cargo 私有路径中的
`libwinapi_*` 归档；不增加下载、缓存目录或运行期资源。该身份尚不是可跨工作树复用的完整密封清单，故资源清单中的
`viva-core-build-state` 明确拒绝复制；每个工作树独立构建和校验。Core 仓库恢复的 `scripts/rust-core/verify-rust-core-comments.sh` 先用固定词法器检查真实注释，再检查 Rustdoc；调用方应沿用本工作树的 `CARGO_TARGET_DIR`。独立 Core 检出未提供该变量时，输出只进入该检出的 `.artifacts/rust-core-checks/`（桌面默认检出内为 `.artifacts/desktop/lithe-core-rust/source/.artifacts/rust-core-checks/`）。词法器二进制、Cargo 状态与 Rustdoc 受 Core 修订、helper Cargo.lock、目标、编译器及环境约束，和已有 Core build state 一起排除，不注册复用 validator；只在构建/验证阶段生成，不进入安装包，不影响签名或增量更新。
Viva 的 IDE API 辅助程序 `lithe-mcp` 由 `scripts/desktop/build-desktop-core.sh` 在同一固定 Core 检出上以 `features=mcp` 编到暂存目录的 `bin/`。`package-desktop.sh` 在 `viva package` 前把它复制成 `desktop/internal/idehelp/lithe-mcp.bin`，以 `lithe_bundled_helper` 构建标签嵌入客户端二进制，打包结束或失败时删除该生成文件；文件被 Git 忽略并在资源清单 `desktop-embedded-ide-helper` 中拒绝跨工作树复用。运行期客户端把嵌入的字节原子安装到应用数据目录的 `ide-host/bin/` 再启动，安装包本身不增加可执行文件、不被写入，也不改变签名或增量更新基线；开发运行由 `desktop-go.sh` 用暂存目录里的辅助程序通过 `LITHE_IDE_HELPER` 提供，不读取安装目录。

Viva 的 `desktop-go.sh` 把暂存 Core 静态库、头文件、原生链接参数和实际选中的 Windows import archive 的 SHA-256 纳入 cgo 编译参数。只改 Rust 或 Core pin 也会使 Go 构建缓存失效；相同字节仍复用 Go 缓存，不清空用户缓存。这个摘要只是本地构建身份，不是跨工作树资源密封清单。`scripts/desktop/desktop-core-cache.test.mjs` 在系统临时目录创建独占的 `lithe core-cache-*` 夹具，只替换 C 静态库来验证真实 Go 编译结果；子进程有本地时限，结束后删除夹具。该目录和 Core 构建状态一起排除复用，不进入安装包；三个原生 CI 车道都运行此回归。

Viva 文件与项目树图标的 SVG 和生成的 Go 数据由 Git 管理，生成脚本限定 Python 3.9 或 3.11、
picosvg 与直接依赖以及 Viva 编译器版本，在本工作树重建；没有自动发现受支持的 Python 时可用
`LITHE_ICON_PYTHON` 指定受支持的解释器，该变量不是缓存路径。临时转换目录退出时删除。它们不是跨工作树的可复制缓存，
`viva-file-icons` 在资源复用入口拒绝复制。运行期图标只读编译数据，不写入安装包，因而不改变
代码签名或增量更新基线。只更新树的展开箭头时，使用生成脚本的 `--tree-only`，
避免重新生成其他文件类型图标。完整生成器在 SVG 未变时仍可能改变既有曲线，原因和完整
工具链可重复性由 [#1801](https://github.com/1lck/Lithe-IDEA/issues/1801) 跟踪。固定工具链后，
macOS 上用 Python 3.9 和 3.11 完整生成的 95 个旧图标向量与提交基线一致，两份生成文件
逐字节相同；Windows 和其他架构的依赖包已确认可获取，
但还未在目标机器完成生成比对，不能据此判定跨平台可重复。

Viva 的市场包传输由操作系统提供的临时目录持有，目录形如
`<file-storage-temp>/lithe-plugin-transfer-<random>/archive.zip`。它是一次下载私有状态，
不具备平台、架构或工具链可复用身份：下载时逐块限额并对照 Core 校验过的索引 SHA-256，
未完成的下载在失败或取消时清理。设置窗口打开期间最多保留最近一个已校验的完整包
（沿用 `MaxArchiveBytes` 的 512 MiB 上限），取消准备或审查后重试可复用同一临时文件，
不重复下载，也不把归档内容保存在内存。更换摘要、关闭设置或退出应用时释放保留的文件；
正在准备包的借用者完成或取消后才释放自己的文件所有权，避免清理正在读取的文件。
每次准备仍在同一打开句柄上重新校验 SHA-256 再解压；校验失败会淘汰保留包，
用户取消或超时不会把已完整下载的包当作损坏包。
摘要只证明包与索引一致。首次安装或没有匹配历史批准的市场包应在校验后展示完整权限和程序，
用户确认后才安装。本地包始终需要审查和确认。归档复用只减少网络传输，不授予安装批准。
它不进入 app bundle、插件包或任何 worktree 复制阶段，不影响签名和
增量更新基线；`plugin-marketplace-state` 在资源复用入口显式拒绝该状态。

Viva 桌面端（`desktop/`，Go）的构建状态位于 `.artifacts/desktop/`，只由
`scripts/desktop/build-desktop-core.sh` 和 `scripts/desktop/desktop-go.sh` 写入，登记为
`desktop-core-build-state`，所有复用阶段均拒绝复制，复用脚本没有为它注册 validator：
`lithe-core-rust/` 是 Lithe-core-rust 的源码检出和 `CARGO_TARGET_DIR` 指向的 Cargo 编译目录（数 GB），
`lithe-core/<debug|release>/` 是暂存给 cgo 的 `include/lithe_core.h`、`lib/liblithe_core.a`、
`native-static-libs.txt` 和 `identity.txt`（单个 profile 约 700 MB），`bin/` 是本工作树构建的桌面端二进制。
默认从构建脚本中固定的 Lithe-core-rust 提交检出；联调尚未合入的 core 改动时，设置
`LITHE_CORE_RUST_DIR=/path/to/Lithe-core-rust` 改用本地检出（脚本只读取它，不修改该检出）。
`desktop-go.sh` 每次运行前都调用构建脚本重新暂存，固定提交变了或本地检出改了都不会继续链接旧库；
没有变化时 git 和 cargo 都判定为最新，这一步约一秒。固定检出和 `LITHE_CORE_RUST_DIR` 共用同一个 Cargo 编译目录，
而 cargo 按成员在工作区内的相对路径计算哈希，不看检出所在位置：两个检出把每个工作区成员（例如事件目录所在的
`lithe-diagnostics`）编译到同一组文件、同一份指纹，新旧只按修改时间判断，切回原检出时会把另一个检出的代码当作
本检出暂存。构建脚本因此按 target 和 profile 在编译目录里记录上次编译工作区成员的检出
（`lithe-core-built-from-<target>-<profile>.txt`），换了检出就先 `cargo clean --workspace`，只重新编译工作区成员，
registry 依赖仍然命中缓存。`LITHE_DESKTOP_CORE_PROFILE=release` 选择暂存的 profile。
`identity.txt` 记录 core 提交、`core-worktree`（clean/dirty）、`core-source`（pinned/override）、rustc 版本、
target、profile 和 macOS deployment target，但它只描述本工作树最近一次构建：override 构建包含未提交的 core 改动，
提交号无法复现；二进制又随本工作树的 `desktop/` 源码变化。因此它不是可以授权跨工作树复制的封存身份，
也没有复制阶段，每个工作树自行构建（`.artifacts/` 被 `.gitignore` 忽略，不提交）。
这些目录只在构建时由上述脚本写入，应用运行时不写，也不进入 app bundle 或安装目录，
不影响代码签名和增量更新基线。

共享翻译源文件位于 `shared/i18n/`，桌面端生成文件是 Git 跟踪的 `desktop/internal/i18n/shared.generated.go`。每个工作树通过 Git 获取源文件和生成文件，然后运行 `node scripts/i18n/generate-i18n.mjs --check` 校验。修改源翻译后运行不带 `--check` 的同一命令，在当前工作树重新生成。资源身份由当前语言清单、词条和翻译共同决定，不需要下载，也没有独立的工具链或可复用 identity stamp。`scripts/resources/worktree-resources.json` 将它登记为 `shared-i18n` 不可复用项，复用脚本拒绝所有复制阶段。不要从其他工作树复制生成文件。生成文件随源码编译，不写入安装资源，也不改变签名和增量更新基线。维护步骤见 [共享翻译说明](../shared/i18n/README.md)。

插件仓库自己的构建输出、发布包、测试夹具和 CI 状态（例如插件仓库的 `dist/`、`.artifacts/`）
归插件仓库所有，不登记到本仓库的资源复用清单，本仓库也不下载、组装或测试任何具体插件。
官方插件 SDK 在 Core 仓库的 `shared/plugins/sdk/` 下维护和发布：
SDK 的构建输出，以及对当前工作树的 Core 运行的端到端测试
（`node shared/plugins/scripts/sdk-e2e.mjs`）都属于 Core 仓库，
本仓库不构建 SDK，也不把这些目录登记为可复用资源。

模块日志和诊断包暂存目录登记为 `application-log-state`，不允许跨工作树复用。日志会话位于 `desktop/internal/logstore` 按平台选择的用户日志目录（`dir_darwin.go`、`dir_other.go`、`dir_windows.go`）下的 `sessions/<name>/`。没有可验证的版本、平台、架构或工具链 identity stamp，复用脚本在解析工作树与复制之前拒绝这些位置，不存在允许复制的阶段。测试必须注入各自的临时日志根目录，不要复用真实用户日志。这些数据不进入安装包或签名基线。

#### 日志窗口的视觉截图检查

`desktop/internal/logwindow/visual_capture_test.go` 用合成记录渲染生产环境的日志页面，并分别截取深色和浅色主题。测试带有 `vivahead` 与 `lithevisual` 构建标签，要求设置 `LITHE_VISUAL_OUTPUT_DIR`，未设置时跳过。运行方式：

```bash
LITHE_VISUAL_OUTPUT_DIR=/path/to/output scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual -run TestVisualLogs ./internal/logwindow/
```

截图写入开发者指定的目录，不属于可复用资源，也不进入安装包。

功能矩阵生成物 `.artifacts/platform-feature-matrix/`（CI Pages 使用
`<runner-temp>/lithe-agent-notes-site/platform-feature-matrix/`）不允许跨工作树复用。
它依赖当前 checkout 的能力记录、证据路径及提交信息，没有可靠的版本、平台、
架构或工具链 identity stamp；任何复制阶段都应排除。资源清单的
`excludedResources.platform-feature-matrix` 由复用脚本直接拒绝。目标工作树运行
`node scripts/platform-feature-matrix/generate-platform-feature-matrix.mjs`，校验源数据后重新生成。

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
  --resource cargo
```

`node scripts/resources/reuse-worktree-resources.mjs --list` 可以查看当前注册资源。脚本只允许
同一 Git 仓库的 linked worktree 互相复用资源，不修改源工作树。它先把源资源
复制到目标工作树的临时目录，按照对应的 manifest、lockfile 或完整性清单校验，
再原子替换目标目录并进行第二次校验。目标已有不少于源缓存的有效文件时会保留
目标，不重复复制；校验失败的文件不会发布到目标缓存。

Cargo 的下载归档按 `Cargo.lock` 中的 checksum 校验。当前自动复用的资源由 [`scripts/resources/worktree-resources.json`](../scripts/resources/worktree-resources.json) 统一注册：

- `.artifacts/cargo-home/registry/cache/`：Cargo crate 下载归档；按所有相关
  `Cargo.lock` 中的 checksum 校验。

Inter 4.1 的 18 个静态 OTF（内部版本 4.001）及许可、JetBrains Mono 2.304 的 16 个静态 TTF、OFL 和作者信息，
以及 Nerd Fonts v3.5.1 的 JetBrains Mono Nerd Font Mono 四个完整 TTF（常规、粗体、斜体、粗斜体）及 OFL 许可，
位于 Git 跟踪的 `desktop/internal/bundledfont/fonts`；来源、版本和每个字型的固定 SHA-256 记录于 `NOTICE.txt`，
`TestTheFontFolderMatchesItsManifest` 按它核对目录。它们与平台架构和工具链无关，随工作树检出，不从另一个
工作树的产物、已签名 app 或运行时缓存复用；注册表将 `bundled-ui-fonts` 排除，复用脚本拒绝复制。
`scripts/desktop/package-desktop.sh` 以 `lithe_bundled_fonts` 构建标签把整个目录（含许可）编译进 macOS 可执行文件，
app bundle 中没有字体文件，运行时也不读取安装目录；不带该标签的开发和测试构建不含字体，回退系统字体。
Viva 的 `app.RegisterFont` 把字型按内容摘要暂存到用户缓存目录，再以 process 范围注册到 CoreText，
不安装到用户字体库，不修改 bundle，不影响增量更新的发布基线。带标签运行
`desktop-go.sh test -tags lithe_bundled_fonts ./internal/bundledfont/` 核对嵌入内容与真实注册的字体族。

以下目录不应直接复制或跨工作树共享：

- 插件运行的临时文件：`<system-temp>/lithe-run-<random>/`。插件在 `run/start` 的
  `temporaryFiles` 里给出文件时，桌面端运行服务为这次运行单独创建这个目录，按插件给的
  文本或字节写入文件。文件内容和编码都由插件决定，只属于该次运行，没有可复用的版本、平台、架构或工具链
  identity stamp。Core 拒绝启动、进程无法启动或运行结束后，运行服务删除整个目录；
  系统临时目录由平台解析，不写安装包或工具链目录，不影响签名或增量更新。
  `excludedResources.run-temporary-files` 经复用脚本的排除路由直接拒绝，任何复制阶段
  都不得共享；内容哈希相同也不能转移进程所有权。

- LSP workspace `-data`、运行时数据库、测试报告和其他会被进程修改的状态。

可下载的官方插件包是声明式插件包（只含 `plugin.json` 和它声明的资源，不含宿主加载的代码，与架构无关），在 `.build/<triple>/<configuration>/OfficialPlugins` 中独立组装，`--triple` 只决定输出目录和签名工具的构建布局；组装后通过 `LitheOfficialPluginVerifier` 验证声明、打包的可执行文件和“Mach-O 原生代码只出现在清单声明的运行时目录内”；发布配置还要求 repository secret `LITHE_PLUGIN_PACKAGE_PRIVATE_KEY`，由 `LithePluginPackageSigner` 对完整包生成 `lithe-plugin-signature.json`，客户端按宿主内置官方插件策略和 publisher 公钥验证后才允许安装。该 secret 的值是与客户端内置公钥匹配的 base64 编码 32 字节 Ed25519 私钥，可用 `gh secret set LITHE_PLUGIN_PACKAGE_PRIVATE_KEY --repo 1lck/Lithe-IDEA < /secure/path/lithe-plugin-package-private-key.base64` 配置；私钥文件和 shell 历史都不得进入仓库或日志。没有该 key 时，普通 debug 全量构建会跳过 publisher 签名包，指定其中一个包 ID 的构建会失败，不会留下缺少签名文档的目录。本地调试插件时可以显式传入 `--development-unsigned`（仅 debug 配置可用），生成不含签名文档的开发包，只能由 debug 构建的 Lithe 从磁盘安装；这类开发包同样不跨工作树复用。无可靠 identity stamp，不跨工作树复制。插件安装后打包的语言服务器位于
`<app-support>/Lithe/Plugins/<plugin-id>/versions/<version>/language-server`，由插件版本目录拥有，运行时只读，重装、回滚和卸载随插件一起处理，不是工作树构建缓存。以上项目在资源清单 `excludedResources` 中明确排除，复用脚本会拒绝显式复制请求。

Build Provider 的模型与依赖快照位于插件根（`pluginpkg.DefaultRoot`）下的 `.state/<plugin-id>/<version>/build/<workspace-digest>/`。会话拥有其缓存、日志和临时输出；模型失效可重建，插件卸载随所属状态清理。工作区摘要只是归属键，不是构建身份。
它属于具体插件、构建系统和工作区的可变上游状态，没有版本/平台/架构/工具链 identity stamp，
复用清单 `official-plugin-packages` 和脚本的排除路由拒绝任何复制阶段共享。
Provider 状态经平台 adapter 写 Application Support；插件安装目录和发行 bundle 只读，
不改变代码签名或增量更新的源基线。

插件网页的宿主持久状态（Viva 的 `pluginservice.SetPageState`）写到每用户插件根目录
（`pluginpkg.DefaultRoot`）下的
`<plugin-root>/.state/<plugin-id>/pages/workspaces/<workspace-key>/<window-digest>.json`，
每个窗口和工作区最多 64 KiB。它属于插件，与同目录下插件后端的工作区状态生命周期相同；
包内网页、脚本和 app bundle 始终只读，因此不改变签名或增量更新的源基线。
这类用户 JSON 没有版本、平台、架构或工具链 identity stamp，工作区摘要只是存储键，
任何复制阶段都不得复用或共享。`excludedResources.plugin-web-state` 通过复用脚本的
排除路由直接拒绝，由 `scripts/resources/test-reuse-worktree-resources.mjs` 验证，不能给它增加缓存校验器。

如果后续新增可复用资源，必须同步更新注册表、校验器、脚本测试和本节说明。
生成资源只有在构建流程写入可验证的源码、配置、平台、架构和工具链 identity
stamp 后才能加入注册表，不能仅凭目录存在就跨 worktree 复制。

The artifact behavior and compression setting follow
[actions/upload-artifact](https://github.com/actions/upload-artifact), and cache
reuse follows GitHub's
[branch access restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).

共享 Build 调用偏好 `.lithe/build/options.json` 是用户维护的工作区文件，团队共享值随普通源文件流转。这些内容没有构建产物 identity stamp，不能作为资源从其他工作树复制、链接或发布；资源清单 `build-project-preferences` 与复用脚本直接拒绝它们。普通检测和设置页读取不创建文件；不写 app 或插件安装目录，不改变签名与增量更新基线。

Viva stdio Debug 的临时状态位于可写插件根的
`.state/<plugin-id>/<version>/desktop-debug-<session>/`。仅在启动时按 Core
返回的 requiredDirectories 创建，进程退出且启动任务结束后删除；已安装的插件版本目录
只读，不影响签名或增量更新。此状态沿用 `official-plugin-packages` 不可复用路由，
没有 identity stamp，发现、校验和复制阶段均禁止跨工作树共享；复用脚本无 validator，
其注册与拒绝由 `scripts/resources/test-reuse-worktree-resources.mjs` 验证。

### Viva 编辑器的用户数据

`store.Open` 选择平台用户配置目录，`Lithe Desktop/EditorRecovery/<document-digest>.draft`
保存编辑器恢复副本及 Scratch。小型 JSON 头与原始 UTF-8 内容在同一临时文件
`.checkpoint-*` 中流式写入、同步后原子替换，避免把整篇内容序列化成 JSON。
普通文件保存成功后移除副本；Scratch 关闭标签后仍保留，直到另存为或明确丢弃。
Core 定义单文档、总磁盘和条数限制，原生适配器负责执行配额、私有权限和序列化写入。
`editor-recent-<workspace-digest>.json` 保存最近文件和位置；`settings.json` 保存编辑器显示偏好
与快捷键方案。它们没有可用于版本、平台、架构或工具链验证的构建身份，资源清单
`viva-editor-user-state` 在所有复制阶段拒绝共享或复用。测试使用各自临时配置目录。
这些数据不进入安装包或签名输入，运行时也不修改安装资源，不影响增量更新。
