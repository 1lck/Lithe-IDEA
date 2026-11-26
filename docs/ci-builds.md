# CI builds and test downloads

CI 构建缓存、架构并行、测试产物和 artifact 保留策略见
[`2026-09-13-ci-build-cache-and-artifact-strategy.md`](../.agents/notes/implemented/process/2026-09-13-ci-build-cache-and-artifact-strategy.md)。
本文只保留 CI 使用说明、下载方式和本地资源复用规则。

仓库里会单独触发的桌面端工作流只有三个，都位于 `.github/workflows/`；第四个文件 `desktop-remote-server.yml` 只能被它们调用（`workflow_call`），负责构建并冒烟测试远端服务：

| 工作流 | 触发 | 内容 |
| --- | --- | --- |
| **Desktop CI**（`desktop-ci.yml`） | PR（Draft 只跑 Linux 作业，`ready_for_review` 时补跑完整矩阵）、推送到 `main`、手动运行 | `pins` 校验固定版本；`linux`（Format and script tests）运行 gofmt、ShellCheck、本地化校验、安装资源路径检查和脚本测试；`linux-test` 通过 `scripts/desktop/check.sh` 运行 Linux 的 vet 和测试；`remote-server`（Remote server）调用可复用工作流 `desktop-remote-server.yml`，分两步：Build for linux amd64 and arm64 任务在一台 x86_64 runner 上编译两种架构的 Linux musl 远端服务，只检查静态链接、ELF 架构、清单与 SHA-256（不运行），上传产物 `remote-server-linux-musl` 并把体积写进任务摘要；随后 Test on linux amd64（`ubuntu-24.04`）和 Test on linux arm64（`ubuntu-24.04-arm`）两个任务并行下载同一份产物，重新校验并各自运行本架构的冒烟测试，两种架构都在原生硬件上运行，不用模拟器；`macos`（`macos-26`）、`windows`（`windows-2022`）同样运行 vet 和测试，只在非 Draft 时执行 |
| **Desktop Release**（`desktop-release.yml`） | 推送 `desktop-v*.*.*` 标签，或手动运行并填写版本 | 先调用 `desktop-remote-server.yml` 编译并在两种架构上冒烟测试远端服务，再打包并校验 macOS、Windows、Linux 产物（每个包都嵌入这一份远端服务），核对校验和，然后创建或更新 GitHub prerelease，再签名发布正式版更新源。手动版本必须与 `desktop/viva.toml` 中的版本一致 |
| **Desktop AutoBuild**（`desktop-autobuild.yml`） | 每天 UTC 10:00 定时，或手动运行 | 与 Release 一样先调用 `desktop-remote-server.yml`，再构建 macOS arm64 与 x64、Windows x64、Linux x64 和 arm64，发布到滚动预发布 `desktop-AutoBuild`。同一提交已经发布时，定时运行不会重复构建 |

- Draft PR 只运行 Linux 检查：macOS 和 Windows 作业带有 `draft == false` 条件。标记为 ready 后，才运行完整的 Desktop CI。
- `Desktop CI gate` 汇总固定版本、Linux 格式与脚本、Linux 测试、远端服务（可复用工作流里的构建任务和 amd64、arm64 两个测试任务都成功，`remote-server` 才算成功）、macOS 测试和 Windows 测试；普通 PR 必须全部成功，Draft 只允许跳过 macOS 和 Windows。更换已有 PR 的目标分支后，保留 Draft 状态；需要评审时标记为 ready 以针对新基线重新运行完整检查。单纯修改标题或正文不触发平台 runner。
- Desktop CI 通过 `scripts/desktop/check.sh` 执行 Go 检查：gofmt，带与不带 `dev` 标签各 vet 一次全部包；测试时 `settingswindow`、`pluginview`、`workbench` 三个界面包只在 `dev` 标签下跑一次，其余包不带标签跑，`buildinfo` 两种标签都跑。对这三个包，`dev` 标签只换掉两个文件：Viva 的属性检查只会多报错误；`buildinfo.Development` 只影响 Dock 角标（只在真实窗口里设置）和已安装的更新渠道（测试构建不带打包信息，两种标签下都为空）。所以不带标签再跑一遍检查不到更多问题，只会让 macOS 和 Windows 多花约 8 分钟。Windows 的 `workbench` 用例按顶层测试名分三组串行运行，三组合起来覆盖全部用例，每组仍遵守 Go 默认的 10 分钟上限。Rust 内核由 `scripts/desktop/build-desktop-core.sh` 按 `PINNED_CORE_REVISION` 固定的 Lithe-core-rust 修订构建。
- Linux 测试作业也运行 `TestVisualLSPActions`，覆盖中英文与明暗主题的代码操作、签名帮助和内联提示失败重试。全量测试失败时仍采集截图。结果作为 `lsp-editor-visual-<系统>-<架构>` artifact 保留 14 天。
- Desktop Release 的打包脚本是 `scripts/ci/desktop-release/package-release.sh`，AutoBuild 的打包和发布脚本位于 `scripts/ci/desktop-autobuild/`。
- 两条发布入口共用 `scripts/desktop/package-desktop.sh`，通过 Viva 的 `--cgo` 选项保留 Rust Core 原生桥接；`desktop-go.sh` 提供目标编译器、静态库及头文件。Linux 发布包由 Ubuntu 22.04 构建，其系统库兼容性需要单独验证，不能按 Viva 的默认纯 Go 包假设没有 glibc 依赖。
- 本地复现与 CI 相同的检查见 [`desktop-getting-started.md`](development/desktop-getting-started.md) 的“提交前检查”。

### AutoBuild 每日发布

`desktop-autobuild.yml` 每天 UTC 10:00（北京时间 18:00）定时运行，也可以在 Actions 页手动运行，并通过 `source_branch` 选择要构建的分支（默认 `main`）。定时任务使用默认分支 `main` 上的工作流文件，并构建 `main` 的源码；手动运行可以通过 `source_branch` 覆盖源码分支。工作流修复通过 PR 直接合入 `main`。

流程分三步：

1. `prepare` 固定源码提交并记录身份。版本取自 `desktop/viva.toml` 的 `[app] version`，build 号由同一时刻的 UTC 时间生成（`YYYYMMDD.HHMMSS`），并记录标准 ISO 时间。定时运行发现 `desktop-AutoBuild` 标签已指向该提交时直接跳过，不重复构建。
2. `build` 在 macOS arm64 与 x64（`macos-26`）、Windows x64（`windows-2022`）、Linux x64 和 arm64 上检出同一提交，运行 `scripts/ci/desktop-autobuild/package-autobuild.sh` 打包。macOS 有完整证书时使用 Developer ID 签名，否则使用 Viva 的临时签名（ad hoc）封装完整应用包，并在上传前校验签名。临时签名不等于 Apple 公证，首次打开仍可能被系统拦截；Windows 没有证书时保持未签名。每个平台只拿到自己的签名密钥。打包产物作为 artifact 保留 3 天。
3. `publish` 等全部平台构建成功后，检出 `github.workflow_sha`（工作流自身所在提交）中的 `scripts/ci/desktop-autobuild/publish-autobuild.sh`，把安装包发布到滚动预发布 `desktop-AutoBuild`。该 Release 始终是 prerelease，不会标记为 latest。并发组保证同一时间只有一次发布。

正式版由 `desktop-release.yml` 发布：推送 `desktop-v*.*.*` 标签，或手动运行并填写与 `desktop/viva.toml` 一致的版本。它打包并校验三个平台的产物后创建 prerelease，与 AutoBuild 的 Release 互不替换。 发布前必须先提交并校验 `docs/releases/v<version>.md`；版本解析器和发布步骤读取同一个文件，不能把 `desktop-v` 标签前缀当成发布说明文件名。正式包显示纯版本号，GitHub prerelease 标记仍用于隔离旧客户端的更新渠道。

正式版的应用内更新读取滚动 Release `desktop-update-feed` 中的 `stable.json`、`stable.json.sig` 和 `stable.notes.md`。`publish` 把安装包上传到版本 Release 后，`update-feed` 作业运行 `scripts/ci/desktop-release/publish-update-feed.sh`：

- 用 `scripts/desktop/build-viva-tool.sh` 编译 `desktop/go.mod` 固定的 Viva fork，再用 `viva feed` 写出更新源。更新源列出本版的 macOS zip、Windows 安装程序和 zip、Linux tar.gz，下载地址指向版本 Release；dmg、deb 和 rpm 不进更新源。
- 增量补丁以当前更新源提供的版本为基线：下载该版本 Release 中各平台的 zip 或 tar.gz，同时核对更新源里的摘要和 Release 的 `.sha256`，一致后传给 `viva feed -patch-from`，生成的 `.patch` 上传到本版 Release。下载失败或摘要不符的平台只发完整包；还没有更新源时全部发完整包。更新源已经提供更新的版本时保持不变；对同一版本重新运行时，沿用原补丁的基线版本。
- Windows 客户端安装 NSIS 安装程序，补丁只挂在同平台的 zip 上；两者的文件布局相同，客户端对 NSIS 安装版使用 zip 的补丁。
- `stable.notes.md` 是 `docs/releases/v<version>.md`，首行为 `<!-- lithe-update-notes version=<version> -->`。更新对话框在用户决定下载前显示它；它不签名，安装哪个文件只由签名的更新源决定。
- 私钥是 Actions secret `VIVA_UPDATE_KEY`（`viva update-keygen` 生成，base64），只交给这一个作业里的 `viva feed`；打包作业只拿到公钥 `vars.LITHE_UPDATE_PUBLIC_KEYS`。没有私钥时跳过更新源发布，Release 照常完成。同一时间只有一次运行写更新源。
- `LITHE_UPDATE_PUBLIC_KEYS` 里还要有一把备用公钥，对应的私钥离线保存，不进 GitHub。客户端接受任何一把内置公钥签的更新源。私钥丢失时，换用备用私钥签名。私钥泄露时，从变量里删掉对应的公钥，并尽快发布一个用剩下那把钥签名的版本；只加新公钥不会撤销旧钥。完整步骤见 [Agent 笔记第 7 节](../.agents/notes/implemented/feature/2026-11-15-desktop-update-channels-and-dialog.md)。

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

编辑器显示偏好仍存放在 `<os.UserConfigDir()>/Lithe Desktop/settings.json`。同目录的 `.settings.lock` 由原生设置存储持有，只协调各客户端进程的读取与原子保存；关闭事务句柄或进程退出即释放 OS 锁，空文件留在用户配置目录避免锁身份变化。每个进程对该目录最多保留一个非递归原生观察器，最后一个工作台关闭时释放。它们属于用户运行时状态，不跨工作树复制，不写应用安装目录，不影响代码签名或增量更新基线。

标题栏远程连接状态的链条和断链图标由 `scripts/desktop/generate-desktop-icons.sh` 从固定的 Lucide 0.469.0 下载 SVG，用 `desktop/go.mod` 固定的 Viva 编译器生成 `desktop/internal/icons/icons.go`；生成数据由 Git 管理。SVG 和编译器仅在本次生成器的临时目录中存活，退出即删除，不作为跨工作树缓存复制。运行期只读取编译进程序的图标，不下载、不生成文件，不改变安装包签名或增量更新基线。`TestVisualRemoteWorkspace` 的主机下拉和切换文件夹截图可写入本检出的 `.artifacts/visual/remote-host-switcher/`；截图绑定本次源码、Core/Viva 修订、平台、语言和主题，不跨检出复制、不进入发行包，由开发者或 CI 清理。

远程身份核验当前在平台临时目录创建随机的 `lithe-evidence-<random>/ssh.log`，目录仅当前用户可访问；它由这次连接尝试持有并在释放时清理，不是编译缓存，不跨工作树复制，也不写入 app bundle 或 Windows 安装目录。读取最多 64 KiB，但 OpenSSH 的持续写入尚未有界，连接仍持有已删除文件的情况也是待修复的发行阻塞。远端的 `<installRoot>/target-identity-v1` 是账户服务状态，由远端账户持有、随该状态目录删除；不得复制到另一目标作为缓存，否则可能复制目标身份。这些路径不属于本地签名或更新基线；新增 Core 临时证据路径的安装包内运行验证尚未完成。

文件关联的打包声明由 `scripts/desktop/generate-file-associations.sh` 读取编辑器内置高亮元数据并调用 Core 生成，作为 `desktop/viva.toml` 的一部分由 Git 管理；打包前以 `--check` 拒绝目录漂移。生成器始终使用构建主机架构执行，即使包的目标架构不同；最终应用和辅助程序仍使用所选目标架构。它是构建输入，不是可跨工作树复制的缓存。运行期只读取系统默认应用，明确应用后写入 LaunchServices 或当前用户的 Windows 注册表，不生成偏好副本，也不改写 bundle、安装目录或插件资源，因此不影响签名和增量更新基线。`TestVisualFileAssociations` 的真实系统读取截图通过 `LITHE_VISUAL_OUTPUT_DIR` 写到当前检出的 `.artifacts/visual/file-associations/`，绑定本次源码、Core/Viva 修订、平台、语言和主题，不跨工作树复制、不进入发行包，由开发者或 CI 清理。

插件市场 SVG 由网络适配器有界读取，在后台编译为 Viva 图标；下载字节只活到本次编译结束，编译结果与失败仅保存在当前市场页的内存缓存中（最多64项、同时读取最多4个、每次最多256 KiB和10秒）。滚动离屏取消未完成的读取，刷新索引、离开市场标签或关闭设置窗口释放缓存；没有磁盘缓存，不跨工作树复制，不写安装目录，也不影响代码签名或增量更新基线。`TestVisualMarketplaceSVG` 的中英文、明暗主题及加载前后截图写入本工作树的 `.artifacts/marketplace-icons-visual/`，绑定当前源码、固定 Viva/Core 修订、语言、主题和渲染环境，不跨工作树复制，由开发者清理，不进入发行包。

插件市场的增量基线存放在 `<os.UserCacheDir()>/Lithe/PluginArchives/<sha256>.zip`。缓存由桌面市场下载层持有，只保留已校验的原始 ZIP，单包最多 64 MiB，总预算 256 MiB 和 128 项，按最早写入淘汰。删除缓存后下一次更新会下载完整包。补丁和重建 ZIP 位于平台临时目录的独占目录，操作结束即清理。批准的后台更新暂存在平台插件数据根的 `.pending-updates/`，启动时复核当前版本和审批后发布进版本目录。下载缓存和暂存属于用户运行时状态，均不跨工作树复制。所有写入都在应用安装目录之外，安装包签名和桌面增量更新基线保持完整。

同一缓存目录内的 `.archive-cache.lock` 串行化各进程的淘汰、临时写入和发布。退出临界区时关闭文件句柄，进程退出时由操作系统释放锁。空锁文件留在缓存目录供其他进程使用。锁不可用时跳过归档缓存写入并保留已下载的包。锁属于用户缓存，与缓存一起清理，不跨工作树复制，也不影响代码签名或桌面增量更新基线。

插件数据根下的 `.package-changes.lock` 由插件服务持有。激活、发布、禁用和卸载结束后关闭文件句柄，操作系统也会在进程退出时释放锁。空锁文件留在插件数据根供其他进程使用。它属于用户运行时状态，位置在发行目录外，无需在工作树间复制，也不影响代码签名或桌面增量更新基线。

CLI 用户启动器由 `desktop/internal/cli` 在明确注册时生成到 `<os.UserConfigDir()>/Lithe/cli/bin/lithe`（Windows 为 `lithe.cmd`）。它绑定用户机器与当前应用可执行路径，随用户移除注册删除；它不是编译缓存，不跨工作树复制，不写安装目录，也不影响代码签名和增量更新基线。CLI 与单文件模式的无头截图可写入当前检出的 `.artifacts/cli-single-file/`；它们绑定本次源码、语言、主题、Viva/Core 修订和渲染环境，不跨工作树复制，由开发者或 CI 清理，不进入发行包。

TextMate 首行元数据随各插件归档发布，从已安装版本目录只读加载。宿主的匹配缓存只保留当前进程内的编译结果，没有可跨工作树复用的状态。加载过程不写入应用或插件包，不改变签名和增量更新基线。

搜索偏好 `<platform-preferences>/search.json` 由桌面原生存储适配器持有，最多64 KiB；只在用户应用/恢复默认时条件原子写回，打开页面不创建文件。它是用户状态，没有源码、版本、平台、架构或工具链复用身份，不跨工作树复制。搜索索引和未保存快照仅在当前进程内，绑定工作区、可见性与读取预算，关闭项目后释放，不写入安装目录。它们不改变代码签名或增量更新基线。`TestVisualSearchResults` 和 `TestVisualSearchPreferences` 的截图写入当前检出的 `.artifacts/search-visual/`，绑定本次源码、语言、主题和渲染环境，不跨工作树复制；Linux Desktop CI上传后由runner清理，不进入发行包。

工具链提供方回包只在窗口进程内短期缓存。缓存由当前插件版本、工作区上下文和工具输入决定，关闭项目或停用插件时清理。原生文件观察器随缓存释放。该状态没有可复制的编译身份，不跨工作树复用，也不写入插件包或发行目录。 Linux Desktop CI 的工具链提供方截图写入当前检出的 `.artifacts/toolchain-provider-visual/`，按语言分目录，绑定本次源码、Go 工具链与固定的 Viva 和 Core 版本。截图上传后由运行器清理，不跨工作树复制，也不进入安装包。

Desktop CI 的 LSP 无头截图由 `TestVisualLSPActions` 写入当前工作树的 `.artifacts/lsp-editor-visual/`。截图是当前提交与当前渲染环境的验证产物，绑定源码、平台、Go 工具链和固定的 Viva 与 Core 版本，不跨工作树复用。CI 上传后由运行器清理工作树，截图不进入安装包。

通用插件工作流的无头截图由 `TestVisualPluginWorkflow` 写入当前检出的 `.artifacts/plugin-workflow-visual/`，覆盖输出与预览、进度菜单、只读对比和快速选择面板的中英文、明暗主题。截图绑定本次提交、平台、Go 工具链和固定的 Viva 与 Core 版本，必须在当前检出重新生成，不跨工作树复制作为验证证据。Linux Desktop CI 通过系统包管理器安装 `fonts-noto-cjk` 到 runner 的系统字体目录，供真实字体回退使用；字体由 runner 持有并随其销毁，不属于检出缓存，不跨工作树复制，也不打包进应用。CI 将 PNG 上传为 `plugin-workflow-visual-<系统>-<架构>` artifact，保留 14 天；本地输出由开发者或 CI 清理，不进入安装包，也不影响代码签名或增量更新基线。

Desktop CI 的 Build 命令发现截图由 `TestVisualBuildCommandDiscovery` 写入当前工作树的 `.artifacts/build-command-discovery-visual/`。该结果绑定提交、平台、Go 工具链和固定的 Viva 与 Core 版本，上传后由 CI 清理，不跨工作树复制，也不进入安装包。

项目树失焦后的选择由 `TestVisualProjectTreeMissingFile` 验证。Linux Desktop CI 将明暗主题和中英文截图写入当前工作树的 `.artifacts/project-tree-visual/`，上传后保留 14 天。截图对应本次提交、主题、语言、渲染平台、Go 工具链和固定的 Viva 与 Core 版本，不跨工作树复制。运行器清理本地输出，截图不进入安装包。

Viva 编辑器性能基线 `scripts/desktop/perf/editor-bench.sh` 把每次运行的原始输出和 Markdown 预算报告写入当前工作树的 `.artifacts/editor-perf/`（`run-<UTC 时间戳>.txt`、`record-<UTC 时间戳>.txt` 及同名 `.md`，以及开发者用 `--out` 指定在该目录下的文件）。它们只属于这一次运行，受源码修订、机器、CPU、运行时负载、Go 工具链和大文档大小（默认 10 MiB，可用 `LITHE_EDITOR_PERF_LARGE_BYTES` 或 `--large-bytes` 修改）影响；没有可验证的跨树身份 stamp，不跨工作树复制，由开发者在本地清理；该基线不是 CI 必跑项，CI 不运行基准，也没有 artifact。随仓库提交的历史记录 `desktop/benchmarks/history/*.jsonl` 由 Git 跟踪，属于源码而不是下载或生成资源，各工作树从 Git 检出。这些文件都不进入安装包，也不会改变代码签名或增量更新。

Viva 的 Core 源码检出、Cargo 目标目录和暂存静态库位于当前工作树的
`.artifacts/desktop/lithe-core-rust/` 与 `.artifacts/desktop/lithe-core/`。暂存身份记录包含
修订、目标、profile 与编译器；Windows GNU 构建还固定设置上游 winapi 的
`WINAPI_NO_BUNDLED_LIBRARIES=1`，直接链接已安装 MinGW 的系统导入库，并记录
`winapi-import-libraries=mingw-system`。这避免 cgo 依赖 Cargo 私有路径中的
`libwinapi_*` 归档；不增加下载、缓存目录或运行期资源。能否把这些构建状态复制到另一个工作树，见下文 `.artifacts/desktop/` 一段。Core 仓库恢复的 `scripts/rust-core/verify-rust-core-comments.sh` 先用固定词法器检查真实注释，再检查 Rustdoc；调用方应沿用本工作树的 `CARGO_TARGET_DIR`。独立 Core 检出未提供该变量时，输出只进入该检出的 `.artifacts/rust-core-checks/`（桌面默认检出内为 `.artifacts/desktop/lithe-core-rust/source/.artifacts/rust-core-checks/`）。词法器二进制、Cargo 状态与 Rustdoc 受 Core 修订、helper Cargo.lock、目标、编译器及环境约束，随 Core 构建状态一起处理；只在构建/验证阶段生成，不进入安装包，不影响签名或增量更新。
Viva 的 IDE API 辅助程序 `lithe-mcp` 由 `scripts/desktop/build-desktop-core.sh` 在同一固定 Core 检出上以 `features=mcp` 编到暂存目录的 `bin/`。`package-desktop.sh` 在 `viva package` 前把它复制成 `desktop/internal/idehelp/lithe-mcp.bin`，以 `lithe_bundled_helper` 构建标签嵌入客户端二进制，打包结束或失败时删除该生成文件；文件被 Git 忽略，不跨工作树复制。运行期客户端把嵌入的字节原子安装到应用数据目录的 `ide-host/bin/` 再启动，安装包本身不增加可执行文件、不被写入，也不改变签名或增量更新基线；开发运行由 `desktop-go.sh` 用暂存目录里的辅助程序通过 `LITHE_IDE_HELPER` 提供，不读取安装目录。
远端工作区服务 `lithe-remote-server`（#2231）也嵌入客户端二进制：`package-desktop.sh` 在 `viva package` 前取得一个暂存目录（CI 通过 `LITHE_REMOTE_SERVER_STAGE` 给出可复用工作流已经冒烟测试过的产物，用 `--require-pinned` 校验；本地打包运行 `build-remote-server.sh` 重新编译，不要求固定提交），用 `verify-remote-server-artifacts.mjs` 校验后，再逐个核对体积和 SHA-256，复制成 `desktop/internal/remoteserver/<目标>.bin` 和 `remote-server-manifest.json`，以 `lithe_bundled_remote_server` 构建标签嵌入；校验后字节有变化就停止打包。这些生成文件被 Git 忽略，打包开始前先删掉上一次中断留下的旧文件，打包结束或失败时再删除，不跨工作树复制。运行期由 `remoteserver.Install` 在远程开发窗口连接主机时把与清单哈希一致的字节原子安装到用户缓存目录 `<os.UserCacheDir()>/Lithe/remote-server/<目标>/lithe-remote-server`（目录 0700、文件 0600，字节相同就复用），再交给 Core 上传到远程主机；它不执行这个文件，不写安装目录，安装包里也不多出文件，签名和增量更新基线不受影响（`remoteserver` 的 `TestResolveLeavesTheInstalledPackageUnchanged` 从仿造的已安装程序包运行这一流程，并比较包内文件清单）。删除该缓存目录是安全的，下次连接会重新安装。开发运行由 `desktop-go.sh` 在 `.artifacts/desktop/remote-server/` 有清单时导出 `LITHE_REMOTE_SERVER_STAGE`，客户端直接读取暂存目录并按清单校验，不复制；打包版只用嵌入的字节，忽略该变量。

打开的远程工作区以本机占位目录作为项目根（`desktop/internal/remoteplaceholder`）。所有占位目录都在锚点文件 `<os.UserCacheDir()>/Lithe/remote-workspaces` 之下：它是一个空的只读普通文件（0444，所在目录 0700），第一次打开远程工作区时创建，之后每次使用都检查它仍是普通文件，是目录、链接或其他类型就拒绝打开。占位目录因此永远无法在本机列出或创建，没走 Core 的本机文件调用会以 ENOTDIR（Windows 上为 ERROR_PATH_NOT_FOUND）失败，不会读写一个看起来像项目的本机文件夹。锚点不含数据、不随工作区关闭删除；手动删除是安全的，下次打开会重新创建。它属于用户缓存目录，不在任何检出或安装目录里，不跨工作树复制，也不影响签名和增量更新基线（`remoteplaceholder` 的 `TestEnsureLeavesTheInstalledPackageUnchanged` 从仿造的已安装程序包创建锚点，并比较包内文件清单）。
`viva package` 的链接参数是固定的，不能用 `-X` 注入构建信息，所以 `package-desktop.sh` 每次打包都生成 `desktop/internal/buildinfo/package_info.go`，以 `lithe_package_info` 构建标签编进客户端。文件记录更新渠道（`--stable` 为正式版，`--autobuild` 为 AutoBuild，本地包为空，不会自我更新）、构建时间（`LITHE_BUILD_TIME`，缺省为打包时刻）、提交（`LITHE_BUILD_COMMIT`，缺省为 `git HEAD`），以及验证更新源签名的公钥（`LITHE_UPDATE_PUBLIC_KEYS`，逗号分隔，只含公钥）。打包结束或失败时删除这个文件；它被 Git 忽略，不跨工作树复制。它只改变可执行文件本身，安装包里不会多出文件，签名和增量更新基线也不受影响。

打包和更新源签名用的 `viva` 命令由 `scripts/desktop/build-viva-tool.sh` 按 `desktop/go.mod` 的 `replace` 从 Viva fork 编译，放在当前工作树的 `.artifacts/desktop/tools/viva-<模块版本>/`；`replace` 指向本地目录时没有版本，放在 `viva-local/` 并每次重新编译。目录名只固定 Viva 源码，不记录 Go 工具链和主机平台；随 `.artifacts/desktop/` 一起复制时，必须满足下文的前提（含相同的 Go 工具链和主机平台），否则删掉该目录，由脚本在本工作树重新编译。它只在打包（`package-desktop.sh`）和签名更新源（`publish-update-feed.sh`）时使用，不进入安装包，不影响签名或增量更新基线。

Viva 的 `desktop-go.sh` 把暂存 Core 静态库、头文件、原生链接参数和实际选中的 Windows import archive 的 SHA-256 纳入 cgo 编译参数。只改 Rust 或 Core pin 也会使 Go 构建缓存失效；相同字节仍复用 Go 缓存，不清空用户缓存。这个摘要只是本地构建身份，不是跨工作树资源密封清单。`scripts/desktop/desktop-core-cache.test.mjs` 在系统临时目录创建独占的 `lithe core-cache-*` 夹具，只替换 C 静态库来验证真实 Go 编译结果；子进程有本地时限，结束后删除夹具。该目录只属于一次测试，不跨工作树复制，不进入安装包；三个原生 CI 车道都运行此回归。

Viva 文件与项目树图标的 SVG（含 `desktop/internal/fileicons/svg/gradle*.svg`）和生成的 Go 数据
（含 `desktop/internal/fileicons/icons.go`）由 Git 管理。生成脚本限定 Python 3.9 或 3.11、
picosvg 与直接依赖以及 Viva 编译器版本，在本工作树重建；没有自动发现受支持的 Python 时可用
`LITHE_ICON_PYTHON` 指定受支持的解释器，该变量不是缓存路径。临时转换目录退出时删除。它们不是跨工作树的可复制缓存，
不跨工作树复制。运行期图标只读编译数据，不写入安装包，因而不改变
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
它不进入 app bundle 或插件包，也不跨工作树复制，不影响签名和
增量更新基线。

Viva 桌面端（`desktop/`，Go）的构建状态位于 `.artifacts/desktop/`，只由
`scripts/desktop/build-desktop-core.sh`、`scripts/desktop/desktop-go.sh`、上文的 `build-viva-tool.sh`
和下文的 `build-remote-server.sh` 写入：
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
提交号无法复现；二进制又随本工作树的 `desktop/` 源码变化。因此它不是封存身份，不能单凭它判断复制来的产物可用。
整个 `.artifacts/desktop/` 可以在满足前提时复制到新工作树，省去第一次编译 Core 的时间：两个工作树的
`PINNED_CORE_REVISION`、`desktop/go.mod` 固定的 Viva 版本、平台、架构和工具链都相同，源工作树没有在编译，
且不使用 `LITHE_CORE_RUST_DIR` override。在 macOS 用 APFS 克隆复制（`cp -cR`），不用链接或共用目录；复制后照常运行
`desktop-go.sh`，built-from 记录的检出路径不同，构建脚本会 `cargo clean --workspace` 并只重编工作区成员。
2026-11-16 的实验中，克隆 4.9 GB 约 4 秒，随后 Core 构建 33 秒、桌面客户端链接 31 秒，第三方依赖没有重编。
结果异常时删掉复制的目录重新编译。做法见 `develop-lithe` Skill 的“检出与编译缓存复用”一节（`.artifacts/` 被 `.gitignore` 忽略，不提交）。
这些目录只在构建时由上述脚本写入，应用运行时不写，也不进入 app bundle 或安装目录，
不影响代码签名和增量更新基线。

远端工作区的服务端 `lithe-remote-server` 由 `scripts/desktop/build-remote-server.sh` 编译（#2231）。它复用
`build-desktop-core.sh --checkout-only` 准备的同一份 Core 检出（固定提交或 `LITHE_CORE_RUST_DIR`）和同一个 Cargo 编译目录，
只开启 `lithe-remote` 的 `server` 特性，按 Core 的 release profile 和 `--locked` 编译 `x86_64-unknown-linux-musl` 与
`aarch64-unknown-linux-musl`；两者都用 Rust 自带的 `rust-lld` 链接，不需要 Docker、zig 或交叉 C 工具链，但要先
`rustup target add` 这两个目标。中间产物在 `lithe-core-rust/target/<目标>/release/`，与桌面 Core 一样按目标记录
built-from 检出，换检出时只清理工作区成员。全部目标编译成功后，脚本删掉并重建 `.artifacts/desktop/remote-server/`，
放入 `<目标>/lithe-remote-server` 和 `remote-server-manifest.json`（Core 提交、`coreWorktree`、`coreSource`、服务版本、rustc，
以及每个文件的体积和 SHA-256）。`scripts/desktop/verify/verify-remote-server-artifacts.mjs` 读取这个目录：检查清单字段、
文件哈希、ELF 架构和静态链接（没有解释器、没有动态库依赖），在同架构的 Linux 上再跑 `--identity`、`--version` 和一次
`server.hello`；不同架构的文件不交给模拟器运行，只报告跳过。`--smoke <目标>` 只对该目标做冒烟测试，并要求它在本机跑通，
可重复，其余目标只做文件检查、报告“not run here”；`all` 表示全部目标，`none` 表示一个都不运行；不传时对本机能运行的目标都做冒烟测试。`--require-pinned` 要求清单来自固定提交且工作区干净。体积只记录在报告和
CI 任务摘要里，不设上限（#2231 的 D9）。随 `.artifacts/desktop/` 复制到另一个工作树时，除上一段的前提外，还要满足 Rust
工具链和已安装目标相同、源工作树不在编译，并在使用前运行一次验证脚本确认清单哈希仍然一致；否则删掉 `remote-server/`，
重新运行构建脚本。这个目录本身是构建状态：它不作为独立文件进入安装包，打包时按上文嵌入客户端二进制；开发运行只读取它，
不写入。Desktop CI、Release 和 AutoBuild 都先调用 `desktop-remote-server.yml` 构建一次并在两种架构上测试，之后才开始编译应用：
Release 与 AutoBuild 的每个打包任务下载这一份产物（artifact 不保留可执行位，下载后恢复 0755），通过 `LITHE_REMOTE_SERVER_STAGE` 交给 `package-desktop.sh`，
所以同一次运行的所有安装包嵌入相同的、已在两种架构上冒烟测试过的字节。

共享翻译源文件位于 `shared/i18n/`，桌面端生成文件是 Git 跟踪的 `desktop/internal/i18n/shared.generated.go`。每个工作树通过 Git 获取源文件和生成文件，然后运行 `node scripts/i18n/generate-i18n.mjs --check` 校验。修改源翻译后运行不带 `--check` 的同一命令，在当前工作树重新生成。资源身份由当前语言清单、词条和翻译共同决定，不需要下载，也没有独立的工具链或可复用 identity stamp。不要从其他工作树复制生成文件。生成文件随源码编译，不写入安装资源，也不改变签名和增量更新基线。维护步骤见 [共享翻译说明](../shared/i18n/README.md)。

插件仓库自己的构建输出、发布包、测试夹具和 CI 状态（例如插件仓库的 `dist/`、`.artifacts/`）
归插件仓库所有，本仓库不记录它们，也不下载、组装或测试任何具体插件。
官方插件 SDK 在 Core 仓库的 `shared/plugins/sdk/` 下维护和发布：
SDK 的构建输出，以及对当前工作树的 Core 运行的端到端测试
（`node shared/plugins/scripts/sdk-e2e.mjs`）都属于 Core 仓库，
本仓库不构建 SDK，也不复制这些目录。

Windows 工具链和批处理模型的集成测试在 Go `t.TempDir()` 下创建含空格或中文的用户目录、安装目录与项目目录。合成工具只读地硬链接当前测试可执行文件；跨文件系统等情况下回退为复制，脚本与私有工具链配置也只属于该测试。子进程由有界上下文和工作台清理关闭后，Go 删除临时目录。它们不是下载缓存或可封存构建产物，不跨工作树复制或共享，不进入安装包，不改真实用户配置、代码签名或增量更新基线。

全局 SDK 登记与工作区项目内工具环境信任记录 `<platform-preferences>/toolchains/global.json` 属于本机用户设置，最多 256 KiB、64 个工具、每个工具 32 个目录，并按规范化工作区根路径保存用户显式授予的 `projectCodeAllowed` 信任记录（不写入工作区内的 `.lithe/`）；读取不创建来源，确认保存或更新信任时才条件原子写入并重新解析。没有可复用的构建身份，不允许跨工作树复制，不进入安装包，也不写入 SDK 或签名及增量更新基线。

原生插件设置的暂存目录：
`<system-temp>/lithe-source-settings-<random>/` 只属于一次确认后的保存操作。
目录权限为 0700，已有的暂存文件为 0600；原生适配器在写回前校验来源版本、
工作区与插件身份和 SHA-256，再按原文件元数据进行条件原子替换，并重新读取。
私有来源快照每个文件最多 2 MiB、总计 8 MiB；所有结束路径均清理暂存。
这些数据没有可复用的版本、平台、架构或工具链身份，不跨工作树复制。
来源只限用户工作区；应用安装目录和插件安装目录受只读边界保护，不影响代码签名或 Sparkle delta。

模块日志和诊断包暂存目录不允许跨工作树复制。日志会话位于 `desktop/internal/logstore` 按平台选择的用户日志目录（`dir_darwin.go`、`dir_other.go`、`dir_windows.go`）下的 `sessions/<name>/`。没有可验证的版本、平台、架构或工具链 identity stamp。测试必须注入各自的临时日志根目录，不要复用真实用户日志。这些数据不进入安装包或签名基线。

#### 日志窗口的视觉截图检查

`desktop/internal/logwindow/visual_capture_test.go` 用合成记录渲染生产环境的日志页面，并分别截取深色和浅色主题。测试带有 `vivahead` 与 `lithevisual` 构建标签，要求设置 `LITHE_VISUAL_OUTPUT_DIR`，未设置时跳过。运行方式：

```bash
LITHE_VISUAL_OUTPUT_DIR=/path/to/output scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual -run TestVisualLogs ./internal/logwindow/
```

截图写入开发者指定的目录，不属于可复用资源，也不进入安装包。

功能矩阵生成物 `.artifacts/platform-feature-matrix/`（CI Pages 使用
`<runner-temp>/lithe-agent-notes-site/platform-feature-matrix/`）不允许跨工作树复用。
它依赖当前 checkout 的能力记录、证据路径及提交信息，没有可靠的版本、平台、
架构或工具链 identity stamp，不跨工作树复制。目标工作树运行
`node scripts/platform-feature-matrix/generate-platform-feature-matrix.mjs`，校验源数据后重新生成。

`.artifacts/desktop/` 只有留在同一个检出里才能增量复用，所以默认不新建工作树：先在空闲的主检出或空闲的已有工作树里
切分支，都被占用才新建，判定方法见 `develop-lithe` Skill 的“检出与编译缓存复用”一节。
Git worktree 只共享 Git 对象，不共享各自的 `.artifacts` 目录，仓库也不提供跨工作树复制资源的脚本（#2002 已删除）。
Go 的构建缓存（`go env GOCACHE`）和模块缓存（`go env GOMODCACHE`）、`~/.cargo/registry` 都在用户目录，所有工作树共用同一份，
不为工作树另设位置，也不复制或清空。新工作树第一次编译会重编 `desktop/` 下的包和 cgo 包（缓存键含包目录和带工作树路径的
cgo 参数），其余包命中缓存，模块不重新下载。
新工作树第一次编译前，按 `develop-lithe` Skill 的“检出与编译缓存复用”一节判断能否从已有工作树复制
`.artifacts/desktop/`（前提和实验结果见上文）；其他目录按本节各段的说明处理，写明不复制的就在本工作树重新生成。

Dev Container 的显式集成验证可以把官方 `@devcontainers/cli` 安装到本检出的
`.artifacts/desktop/devcontainer-cli/`，通过仅该测试子进程的 `PATH` 使用，不修改全局 npm 安装。
2026-11-26 的验证固定为 0.91.0，需要 Node.js 20 或更新版本；此目录是开发者拥有的可删除下载缓存，
不是宿主打包资源，也不是运行时自动安装机制。只有 CLI 版本、Node 支持范围、平台和架构均匹配，且目录完整时
才可复制到另一个空闲工作树；不同平台或有原生 npm 依赖时重新安装，不共享可写目录。
真实集成测试的临时工作区、容器、日志和截图属于本次测试，不复制：按唯一工作区标签清理测试容器，
断开服务并删除临时工作区。用户确认创建的 `.devcontainer/devcontainer.json` 属于用户工作区，随工作区保存，
不作为编译缓存搬运；创建、探测及 CLI 状态均不得写入 app bundle 或 Windows 安装目录。

Inter 4.1 的 18 个静态 OTF（内部版本 4.001）及许可、JetBrains Mono 2.304 的 16 个静态 TTF、OFL 和作者信息，
以及 Nerd Fonts v3.5.1 的 JetBrains Mono Nerd Font Mono 四个完整 TTF（常规、粗体、斜体、粗斜体）及 OFL 许可，
位于 Git 跟踪的 `desktop/internal/bundledfont/fonts`；来源、版本和每个字型的固定 SHA-256 记录于 `NOTICE.txt`，
`TestTheFontFolderMatchesItsManifest` 按它核对目录。它们与平台架构和工具链无关，随工作树检出，不从另一个
工作树的产物、已签名 app 或运行时缓存复制。
`scripts/desktop/package-desktop.sh` 以 `lithe_bundled_fonts` 构建标签把整个目录（含许可）编译进 macOS 可执行文件，
app bundle 中没有字体文件，运行时也不读取安装目录；不带该标签的开发和测试构建不含字体，回退系统字体。
Viva 的 `app.RegisterFont` 把字型按内容摘要暂存到用户缓存目录，再以 process 范围注册到 CoreText，
不安装到用户字体库，不修改 bundle，不影响增量更新的发布基线。带标签运行
`desktop-go.sh test -tags lithe_bundled_fonts ./internal/bundledfont/` 核对嵌入内容与真实注册的字体族。

Windows 本地终端使用的 ConPTY 二进制位于 Git 跟踪的 `desktop/internal/localshell/conpty`：
Microsoft.Windows.Console.ConPTY 1.25.260930003（microsoft/terminal v1.25.2733.0，MIT）中未修改的
`conpty.dll`（win-x64、win-arm64）和 `OpenConsole.exe`（x64、arm64），连同许可 `LICENSE.txt`。
每个文件和 nupkg 的 SHA-256 记录于 `NOTICE.md`，`TestTheConPTYFolderMatchesItsNotice` 核对哈希和 PE 机器类型。
`conpty.dll` 跟随程序架构，`OpenConsole.exe` 跟随系统内核架构，所以 x64 构建同时嵌入 arm64 的控制台宿主。
Go 构建在 windows/amd64 和 windows/arm64 上用 `go:embed` 把它们编译进可执行文件，安装目录里没有 ConPTY 文件，
签名基线和增量更新不受影响。进程第一次打开终端时，客户端把本架构的文件写到
`<user cache>/Lithe/conpty/<digest>/`（`%LocalAppData%\Lithe\conpty\`），目录按文件集摘要命名，已有相同字节就不再写；
写入或加载失败时回退系统自带 ConPTY，并记录 `app.background.operation_failed`（operation `terminal_conpty`）。
旧摘要目录不删除，因为另一个版本的运行中客户端可能已加载它。它们随工作树检出，不从另一个工作树的产物、
已安装客户端或该缓存复制。

以下目录不应直接复制或跨工作树共享：

- 插件运行的临时文件：`<system-temp>/lithe-run-<random>/`。插件在 `run/start` 的
  `temporaryFiles` 里给出文件时，桌面端运行服务为这次运行单独创建这个目录，按插件给的
  文本或字节写入文件。文件内容和编码都由插件决定，只属于该次运行，没有可复用的版本、平台、架构或工具链
  identity stamp。Core 拒绝启动、进程无法启动或运行结束后，运行服务删除整个目录；
  系统临时目录由平台解析，不写安装包或工具链目录，不影响签名或增量更新。
  任何时候都不得跨工作树共享；内容哈希相同也不能转移进程所有权。

- LSP workspace `-data`、运行时数据库、测试报告和其他会被进程修改的状态。

已安装插件目录由 `desktop/internal/pluginpkg`（`pluginpkg.DefaultRoot()`）按平台管理：macOS 为 `~/Library/Application Support/Lithe Desktop/plugins`，Windows 为 `%LOCALAPPDATA%\Lithe Desktop\plugins`，Linux 为 `<os.UserConfigDir()>/lithe-desktop/plugins`。各个插件由自己的仓库负责构建、校验、签名与发布，桌面主仓库不内置插件打包器或签名密钥；宿主下载校验并经用户批准后，先在 `<plugin-root>/.staging/` 解压，再原子重命名到 `<plugin-root>/<plugin-id>/<version>/`，卸载时先移入 `<plugin-root>/.trash/` 再删除，可写状态统一落在 `<plugin-root>/.state/<plugin-id>/`。已安装版本目录在运行时只读，重装、回滚和卸载均由插件安装流程统一处理，且位于 app bundle 和 Windows 安装目录之外，不改变代码签名或桌面增量更新基线；它们属于用户运行时目录而非工作树构建缓存，任何情况下都不得跨 Git 工作树复制或共享。

Build Provider 的模型与依赖快照位于插件根（`pluginpkg.DefaultRoot`）下的 `.state/<plugin-id>/<version>/build/<workspace-digest>/`。会话拥有其缓存、日志和临时输出；模型失效可重建，插件卸载随所属状态清理。工作区摘要只是归属键，不是构建身份。
它属于具体插件、构建系统和工作区的可变上游状态，没有版本/平台/架构/工具链 identity stamp，
不跨工作树复制或共享。
Provider 状态经平台 adapter 写 Application Support；插件安装目录和发行 bundle 只读，
不改变代码签名或增量更新的源基线。命令式测试发现把这次命令的 JSON 报告写入同一工作区状态下的
`test-discovery-*/tests.json`。宿主为每个操作创建独立目录，在成功、失败或取消后清理，
报告不能跨工作树复用。

显式声明 `requires.managedRuntimes: 0` 和 `runtimes.install` 权限的插件，可以让宿主在安装提交前
准备经过插件校验的依赖。下载来源、SHA-256、平台和目录布局属于插件清单及程序审批摘要；
宿主不保存任何特定语言的版本或下载地址。Core 选出当前平台的归档并生成依赖身份摘要，
原生下载与解压结果位于 `<plugin-root>/.state/<plugin-id>/runtimes/<cache-key>/`，
其中 `archive` 是校验过的归档，`install-<random>/` 是完成校验后发布的只读一代文件，
`ready.json` 记录当前完成的一代及文件清单，`.lock` 协调跨进程写入。
下载、解压和资格检查在私有暂存区完成；取消或失败删除本次未发布的文件，已发布的一代仍可供旧进程读取。
正常启动检查文件清单和插件要求；安装、升级以及修复同时核对内容哈希。

该目录由插件身份拥有，不含插件版本号。插件代码升级而依赖声明不变时复用同一目录和归档；
依赖、平台或校验值变化时使用另一身份，不覆盖旧文件。完整且符合插件要求的外部安装可以直接复用，
宿主只下载缺失项；外部目录不属于宿主，不在卸载时删除。插件禁用会取消准备任务并停止进程，
保留已完成依赖；卸载先等待准备任务和进程退出，再随整个插件状态删除受管归档与各代文件。
这些目录是用户运行时状态，不是工作树构建输入，不跨工作树复制或共享，不写插件包、app bundle
或 Windows 安装目录。归档压缩大小上限为 512 MiB，展开总量 4 GiB、条目数 50,000，完成记录上限 32 MiB；
路径和链接不能逃出解压根。相关边界见
[受管插件运行时](../.agents/notes/implemented/architecture/2026-11-18-managed-plugin-runtimes.md)。

插件用 `commandInstallers` 声明的下载安装器（`requires.commandInstallers: 1`，权限 `commands.install`）
在用户点击安装并确认后，才下载插件固定地址和 SHA-256 的压缩包。结果位于
`<plugin-root>/.state/<plugin-id>/commands/<installer-id>/<cache-key>/`，布局与上面的受管运行时相同
（`archive`、`install-<random>/`、`ready.json`、`.lock`），大小和路径上限也相同；
命令所在目录记录在 `<plugin-root>/.state/<plugin-id>/commands.json`。缓存键由 Core 按压缩包内容身份
（地址、版本、平台、校验值、格式和目录）生成，镜像不参与。记录新缓存键后，宿主删除同一安装器下的其他缓存键目录；
删不掉的留到下次安装。卸载插件时随插件状态一起删除。它是用户运行时状态，不是工作树构建输入，
不跨工作树复制或共享，也不写插件包、app bundle 或 Windows 安装目录。决策见
[插件声明的命令缺失时由宿主安装](../.agents/notes/implemented/architecture/2026-11-15-plugin-command-installers.md)。

插件网页的宿主持久状态（Viva 的 `pluginservice.SetPageState`）写到每用户插件根目录
（`pluginpkg.DefaultRoot`）下的
`<plugin-root>/.state/<plugin-id>/pages/workspaces/<workspace-key>/<window-digest>.json`，
每个窗口和工作区最多 64 KiB。它属于插件，与同目录下插件后端的工作区状态生命周期相同；
包内网页、脚本和 app bundle 始终只读，因此不改变签名或增量更新的源基线。
这类用户 JSON 没有版本、平台、架构或工具链 identity stamp，工作区摘要只是存储键，
不得跨工作树复制或共享。

新增下载、解压、生成或缓存资源时，在本节写清路径、归属、生命周期，以及能否跨工作树复制、复制的前提。
生成资源没有可验证的源码、配置、平台、架构和工具链 identity stamp，也没有构建脚本在复制后重新校验时，
不能仅凭目录存在就跨 worktree 复制。

The artifact behavior and compression setting follow
[actions/upload-artifact](https://github.com/actions/upload-artifact), and cache
reuse follows GitHub's
[branch access restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).

共享 Build 调用偏好 `.lithe/build/options.json` 是用户维护的工作区文件，团队共享值随普通源文件流转。这些内容没有构建产物 identity stamp，不能作为资源从其他工作树复制、链接或发布。普通检测和设置页读取不创建文件；不写 app 或插件安装目录，不改变签名与增量更新基线。

Viva stdio Debug 的临时状态位于可写插件根的
`.state/<plugin-id>/<version>/desktop-debug-<session>/`。仅在启动时按 Core
返回的 requiredDirectories 创建，进程退出且启动任务结束后删除；已安装的插件版本目录
只读，不影响签名或增量更新。此状态
没有 identity stamp，不得跨工作树复制或共享。

### Viva 编辑器的用户数据

`store.Open` 选择平台用户配置目录，`Lithe Desktop/EditorRecovery/<document-digest>.draft`
保存编辑器恢复副本及 Scratch。小型 JSON 头与原始 UTF-8 内容在同一临时文件
`.checkpoint-*` 中流式写入、同步后原子替换，避免把整篇内容序列化成 JSON。
普通文件保存成功后移除副本；Scratch 关闭标签后仍保留，直到另存为或明确丢弃。
Core 定义单文档、总磁盘和条数限制，原生适配器负责执行配额、私有权限和序列化写入。
`editor-recent-<workspace-digest>.json` 保存最近文件和位置；`settings.json` 保存编辑器显示偏好
与快捷键方案。它们没有可用于版本、平台、架构或工具链验证的构建身份，不跨工作树复制或共享。测试使用各自临时配置目录。
这些数据不进入安装包或签名输入，运行时也不修改安装资源，不影响增量更新。
