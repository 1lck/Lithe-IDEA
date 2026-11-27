# Agent 笔记：CI 构建缓存与测试产物策略

状态：已实现

> 2026-11-08 Viva 迁移：下文的 CI 门禁以当前工作流为准。`desktop-ci.yml` 对 Draft PR 只运行 Linux 格式、脚本和桌面测试，非 Draft 另运行 macOS 与 Windows 测试；旧的 Swift/Tauri 工作流、分片和 lane 复用的 CI 接线尚未迁移，不能当作当前门禁；资源复用脚本已在 #2002 删除。

## 先说结论

CI 缓存的是经过版本和依赖约束的中间构建结果（Core 的编译输出和下载依赖），不缓存最终安装包或可执行文件。Draft PR 只跑 Linux 检查，不占用 macOS 和 Windows runner；标记为 ready 后才运行完整的平台测试。组织使用 GitHub Free 计划，全组织同时最多运行 5 个 GitHub 托管 macOS job，所以每次推送占用的 macOS runner 数量本身就是需要控制的成本。

## 问题

Viva 桌面端要在 macOS、Windows 和 Linux 上构建，Rust Core 和 Go 桌面端的耗时来源不同。如果只缓存最终可执行文件，容易复用错误的构建结果，也无法稳定获得测试安装包。

## 决策

- 日常开发只使用 `main` 作为基线：新分支从最新 `origin/main` 创建，PR 直接合入 `main`。每日 AutoBuild 默认构建 `main`，Agent Notes 和功能矩阵网页也跟随 `main`；`preview` 不再承担集成或发布源码入口。预发布渠道、标签和 appcast 名称是产品更新协议，不随源码分支改名。
- main 的合并保护统一放在一个规则集中，默认需要 CODEOWNER 审批、最后一次推送后批准以及 `Desktop CI gate`。只有 `1lck` 和 `xiaoyumuxi` 能在 PR 页面选择绕过审批和 CI；豁免只用于 PR，不允许直接推送、强推或删除 main。授权发布者由仓库所有者和 `LITHE_RELEASE_ACTOR` 决定，定时 AutoBuild 仍自动执行。其他 Write 协作者的 GitHub 手工 Release 权限不是工作流名单能限制的，不能宣称该名单覆盖手工发布。
- `Desktop CI gate` 必须读取五个明确依赖的结果；普通 PR 和 main 推送要求五项全部成功，缺失、失败、取消或意外跳过均失败。Draft 只允许 macOS 和 Windows 两项被跳过，Linux 格式、脚本、测试及固定版本检查仍必须成功。Linux 作业同时检查 Agent Notes、功能矩阵源数据及平台变更对应的能力记录，使文档路径过滤不会绕过必需门禁。
- 例如功能分支应从 `origin/main` 创建并向 main 提 PR；不要继续向 preview 合并后再提升到 main，也不要把旧 `macOS CI gate` 设为必需检查，它属于已移除客户端。切换已有 PR 的目标分支后先保留 Draft，需要评审时再标记为 ready，针对新基线重跑完整 CI。标题和正文编辑不触发 CI，避免同一提交的跳过结果覆盖先前失败的门禁。
- Core 的缓存键必须包含运行器的系统与架构、工具链身份、构建目标、发布或调试配置，以及构建脚本的哈希。发布工作流与自动构建使用同一个 release 档 Core 缓存键，因此自动构建通常能复用前一晚的 Core 编译结果。
- 只缓存 Cargo 的依赖、编译中间产物和构建脚本输出，不缓存最终可执行文件，也不缓存整个增量编译目录。最终打包仍然重新运行必要的构建步骤，保证产物来自当前源码。
- Draft PR 关闭所有 macOS 和 Windows 测试，只保留 Linux 上的分类、格式、脚本和桌面测试；PR 标记为 ready for review 时重新触发完整检查。
- 关闭或合并 PR 时，清理工作流按来源仓库、来源分支和关闭时间查找所有历史运行，不能只查最后一次提交。清理使用 GitHub 的强制取消接口，避免旧运行继续占用托管 runner。取消失败只有在运行已经结束时才视为正常竞争；权限或 API 故障必须使清理检查失败，不能伪装成清理成功。保留关闭后创建的运行、其他来源仓库和非 PR 事件。
- 同一个 PR 的运行共享 concurrency group，新提交取消旧运行。`main` 的 push 使用独立的 concurrency group，`cancel-in-progress: false`，每个提交都完整运行。
- 取消不算验证通过。当前工作流未被取消时，即使测试失败，汇总检查也必须执行并失败；不能在 shell 中把取消结果转换为成功。
- Windows 的 Core 克隆使用 `--no-checkout`。即使克隆的 HEAD 已经等于固定修订，也必须在没有 Git 索引时检出工作树；否则 Cargo 清单不存在。这个恢复不使用 `--force`，冲突的未跟踪文件会阻止检出。已有索引的工作树如果缺少清单则报错，不静默恢复用户删除的文件。
- Windows 的 Rust 静态库依赖 Cargo crate 提供的导入库，不能只传系统库名称给 Go 链接器。桌面构建入口读取对应 target/profile 的 Cargo 构建输出，把实际使用的导入库目录加入链接搜索路径；相同库名对应不同字节时拒绝构建，避免误用旧缓存。路径按 Go 的参数解析规则整体引用，包含空格的目录也可使用。
- Windows 打包工具的版本检查通过 Git Bash 启动原生 NSIS 时，用单次命令的 `MSYS2_ARG_CONV_EXCL=/VERSION` 保留版本开关；否则 Git Bash 会把 `/VERSION` 转成 Git 安装目录下的路径，NSIS 误以为是安装脚本并终止。不要全局关闭路径转换，后续真实文件参数仍需要正常处理；共享工具准备 action 的 PATH、x86 与 x64 查找路径都适用这一约束。
- `setup-desktop-windows-build-tools` 始终准备并检查 MinGW-w64；`nsis` 输入默认 `true`，保持 Desktop Release 和 AutoBuild 的安装包构建行为。设置 `nsis: false` 时只准备 MinGW-w64，不查找、安装或检查 NSIS，desktop-ci 的 Windows 测试任务使用此模式。本地 action 必须在 checkout 之后调用。
- Lithe 的发布包必须显式用 Viva 的 `--cgo` 构建选项：Linux 和 Windows 默认的纯 Go 打包会关闭 cgo，使 Rust Core 的 C ABI 桥接文件不参与编译。宿主打包入口继续由 `desktop-go.sh` 提供目标编译器、静态库和头文件，再将公开选项传给 Viva；不在宿主修改 Viva 源码或增加缺失桥接的空实现。这个选项不增加运行时资源路径，也不改变资源所有权；安装包仍然只读。Linux 的最低系统库要求由实际构建镜像及原生库决定，不能因为 Viva 默认纯 Go 就宣称 Lithe 安装包不依赖 glibc。
- macOS 没有 Developer ID 证书时，AutoBuild 和 Desktop Release 显式调用 Viva 的临时签名（ad hoc）功能，并无条件校验完整 app bundle。只保留 Go 链接器生成的可执行文件签名，会漏掉 Info.plist 与资源封装，实际下载包报“code has no resources but signature indicates they must be present”；不能以“没有证书”为由跳过完整性校验。临时签名不提供 Apple 开发者身份或公证，Gatekeeper 仍可能拦截，下载说明必须如实说明；不能把临时签名包装成免提示分发。
- RPM 的运行依赖必须包含 Viva 通过 `dlopen` 打开的 Pango、Fontconfig、GObject 和 XCB 扩展库。它们不会出现在普通 ELF 动态依赖扫描中；固定的 Viva 打包器使用 `lib…so…()(64bit)` 共享库能力声明，让 RPM 系统选择对应提供者。不能只列 Vulkan/XCB/Cairo 后假定文字库总已安装，也不能在宿主解包改写 RPM 元数据。GTK、输入法、WebKit 等可选集成不作为所有应用的强制依赖。
- Desktop Release 和 AutoBuild 必须共用 `scripts/ci/common/desktop-packages.mjs` 定义的构建矩阵、格式和下载文件名，不能各维护一套清单。macOS 两种芯片各提供 DMG/ZIP，Windows x64 提供 EXE/ZIP，Linux 两种架构各提供 DEB/RPM/tarball，共 12 个包和 12 个校验文件。两条流程在任何发布写操作前检查完整清单和 SHA-256，不能只检查“下载到的文件”而漏掉未生成的包。RPM 使用 Viva 已有的打包能力；正式发布另外用 rpm 工具检查内部摘要和版本/发行号/架构。它是 runner 上的验证工具，不进入安装包，不增加可复用资源路径。
- Desktop Release 的标签是 `desktop-v<version>`，发布说明的唯一文件却是 `docs/releases/v<version>.md`：两者用途不同，解析版本与上传 Release 必须按版本读取同一文件。不能另存一份带 `desktop-v` 前缀的副本来迁就读者，否则双语说明会漂移；离线解析回归只创建规范文件，缺失、空白或 manifest 版本不符时仍拒绝发布。
- 对二进制做流式校验时，匹配到目标后仍必须读完生产者的输出：`strings | grep -q` 会提前关闭管道，使 macOS `strings` 报 flush 错误，再被 `pipefail` 当成缺少版本。发布检查使用完整行匹配并把 grep 输出丢到 `/dev/null`，不关闭 `pipefail`、不忽略生产者退出码；回归同时覆盖大输出正常匹配、无匹配和匹配后的读取失败。
- 菜单无头测试先按 `gfx.RoleMenuItem` 角色过滤，再从菜单项中选择最深层；Linux/Windows 的窗口按钮可能比所有菜单层更高，不能直接把最高层的全部控件当作菜单。用合成的高层窗口按钮回归这个选择边界，保留原有远程目录、顺序与分支动作断言，不通过跳过平台或放宽预期让 CI 变绿。
- 只有 Node 脚本、没有外部依赖的工作流不为了打开 `cache` 而引入不存在的 lockfile；Bun 的真实依赖缓存保留。

## 考虑过的备选方案

### 缓存最终可执行文件

可以减少部分打包时间，但容易受到源码、编译器、SDK 和构建参数变化影响，也会掩盖当前提交是否真正完成构建，因此不采用。

### 只缓存下载依赖

能减少网络等待，但无法覆盖 Rust Core 的主要编译成本，因此扩展为缓存 Cargo 的中间输出和构建脚本结果。

### 保留 preview 作为长期集成分支

会让审核、必需检查、定时构建和文档基线分成两套，并且需要额外的 preview 到 main 提升 PR。两条分支完成历史整合后改为 main 单一基线，减少权限和源码来源漂移；代价是 main 同时承载日常集成，稳定发布仍通过版本标签区分。

### 所有 PR 都强制生成完整安装包

会增加文档和不需要产品包的改动的构建时间与存储成本。安装包不是合并判断的输入，因此 PR 只运行测试，需要安装包时手动运行发布工作流。

### 在 PR 中等待完整的 Release 编译

Release 编译和打包会把反馈推迟到最慢的任务结束。Draft PR 和普通 PR 只需要测试结果，发布工作流负责产出安装包。

## 后果

- 普通 PR 更快得到检查结果；Draft PR 迭代期间不占 macOS 和 Windows runner。
- 缓存命中可以减少 Core 的重复编译，同时通过完整缓存键避免跨环境误复用。
- 冷构建、编译器变化、依赖变化和 runner 排队仍可能很慢，不能把缓存策略当作总耗时保证。
- 工作流调整时必须同步检查缓存键、gate 依赖和平台矩阵。

## 验证

- `node --test scripts/ci/desktop-release/resolve-release-version.test.mjs`：纯版本与 desktop-v 标签都读取规范文件；缺失、无效说明及 manifest 不符均拒绝。

- `node --test scripts/ci/common/desktop-packages.test.mjs scripts/ci/desktop-release/package-release.test.mjs`：验证两条流程共用五个目标、12 个下载包，缺 Intel/RPM 或校验错误时拒绝发布，并用离线夹具验证 Linux 两种架构的正式打包与 RPM 元数据拒绝。

- `node --test scripts/ci/desktop-autobuild/package-autobuild.test.mjs`：离线验证 Linux 双架构 RPM 收集及校验和、macOS 临时签名选择和无效签名拒绝发布。

- `node --test --test-timeout=60000 scripts/ci/desktop-ci/verify-ci-gate.test.mjs`：离线验证五项结果汇总、Draft 原生检查延期、失败/取消/缺失结果拒绝，以及命令入口的输入校验。
- `actionlint`：核对当前工作流的事件、依赖和表达式；GitHub 上还要确认 main 的 `Desktop CI gate` 为必需检查，且只有两个指定账号拥有 PR 豁免。
- `make -C desktop check`：当前 macOS 本机的格式、vet 和 Go 测试；它不证明 GitHub Actions 或 Windows 已通过。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^TestDesktopGoFindsWindowsCargoImportLibraries$'`：受控 Cargo 输出夹具验证导入库发现、带空格路径和冲突拒绝；Windows 实机仍须编译与链接实际 Core。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^TestBuildDesktopCoreChecksOutFreshPinnedRevision$'`：使用本地 Git 仓库和编译器替身验证空工作树检出，并确认不会恢复已有工作树中主动删除的文件。
- `node --test scripts/ci/cancel-closed-pr-runs/cancel-closed-pr-runs.test.mjs`：用离线 GitHub CLI 替身验证关闭清理，覆盖分页历史运行、来源隔离、关闭时间、取消竞争和 API 失败传播。
- 真实的 CI 和发布流程需要在 GitHub 上分别验收，离线测试不能替代。

## 适用范围

- `.github/workflows/desktop-ci.yml`
- `.github/workflows/desktop-release.yml`
- `.github/workflows/desktop-autobuild.yml`
- `.github/actions/setup-desktop-windows-build-tools/action.yml`
- `scripts/desktop/build-desktop-core.sh`
- `scripts/desktop/desktop-go.sh`
- `scripts/ci/cancel-closed-pr-runs/`
- `docs/ci-builds.md`
