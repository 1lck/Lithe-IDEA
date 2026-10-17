# Agent 笔记：CI 构建缓存与测试产物策略

状态：已实现

## 先说结论

CI 缓存的是经过版本和依赖约束的中间构建结果，不缓存最终安装包。普通
PR 先通过编译和测试获得快速反馈；macOS 仅在包敏感改动时生成测试包，
Windows PR 不再生成安装包。Windows 安装包由 preview 和稳定版发布工作流
负责，避免发布产物阻塞日常代码验证。组织使用 GitHub Free 计划，全组织同时
最多运行 5 个 GitHub 托管 macOS job，另有自建 Mac mini 的三个槽位。每次推送占用的 macOS runner 数量本身就是
需要控制的成本：同一份 Swift 测试编译只做一次，PR 只打 arm64 包，Draft PR
不占 macOS/Windows runner。

## 问题

Lithe 同时构建 macOS 双架构产品、通用 macOS 包和 Windows 安装包。Swift、
Rust Core、数据库辅助 crate 和前端构建的耗时来源不同；如果只缓存最终
可执行文件，容易复用错误的构建结果，也无法稳定获得测试安装包。

## 决策

macOS CI 与发布工作流统一使用 Xcode 26.6，编译器
固定为 `.swift-version` 中的 Swift 6.3.3。共用的 `setup-macos-toolchain` action
选择 Xcode 后校验实际编译器版本；不一致就立即失败，不能悄悄使用 runner 的
默认版本。SwiftPM 缓存键与完整性校验都读取这个版本文件。这个基线不能因为
某台开发机升级了 Xcode 27 而改变，否则仍在 macOS 15 上工作的开发者会被迫
升级开发环境。

日常 CI 的 Swift 测试、Rust Core 测试、应用打包验证和插件测试可以运行在
带有 `lithe-mac-mini` 标签的自托管执行器上，包括 fork 提交到本仓库的 PR。
同一台 M4/16 GB Mac mini 注册三个独立 runner，各自占用独立工作目录，
提供三个任务槽位；三并发已由维护者实测。发布流程（正式版、AutoBuild、
官方插件发布）需要签名证书和发布密钥，始终保留 GitHub 托管执行器。

GitHub 在创建 job 时固定 `runs-on`，job 排队后不能改投另一个池，
`runs-on` 数组也只能表示“同时具备所有标签”。因此每个 CI 工作流的 Linux
分类 job 运行 `scripts/select-macos-ci-runners.mjs`：用只读的
`actions: read` 权限列出本仓库正在运行和排队的 job，按标签统计两边占用，
再为本次选中的 lane 依次分配池。PR 优先占用空闲的 Mac mini（同样的任务
更快），Mac mini 满了再用空闲的托管槽位；两边都满时进入相对容量更短的
队列。push 到 `preview` 和手动运行只用 Mac mini，即使它忙也排队等待，
避免合并后的复验占用 PR 正在等待的托管槽位。API 读取失败或没有令牌时
退回固定分配（Rust Core、打包在 Mac mini，Swift、插件在托管池），不阻塞 CI。

同一个 PR 的后续 push 按 lane 复用之前的结果。观察到的问题是：作者补一个很小的
提交，或者为了同步 `preview` 更新分支，所有 lane 都会重新完整运行，而结果大概率
不变。`scripts/plan-ci-lane-reuse.mjs` 在 macOS CI、插件 CI 和 Windows CI 的分类 job
中逐个 lane 判断：找到这个 PR 之前真正执行过该 lane 的最近一次运行，job 已通过或
仍在运行，并且 PR 自己在此之后的改动（按现有分类规则）不影响这个 lane，就复用
那次结果。只看 PR 自己的改动：用“每个文件的 PR 版本”比较两个修订，从 base 同步
进来的改动不算；但只要 base 在两次运行之间带来了 CI 基础设施的改动（workflow、
action、分类和 runner 脚本、测试基础设施、`Package.swift`/`Package.resolved`、Cargo
清单与锁文件），全部 lane 重跑。这里同时检查作者合入的 base 改动和 GitHub 合并
提交在 base 前进后自动带上的改动（用 API 取得之前那次运行开始时的 base 头）。
失败或被取消的结果从不复用。

GitHub 只能取消整个 workflow 运行，不能取消单个 job，所以 PR 运行不再按分支自动
互相取消：规划步骤取消没有任何 lane 复用的旧运行，被复用、仍在运行的旧运行保留
到结束。gate 确认被复用的 job 已经通过（仍在运行时最多等 90 分钟），并检查每个被
选中的 lane 要么本轮运行、要么有复用结果，避免计划缺失时空跑通过。规划出错一律
回退为全部运行；push 和手动运行不复用。被否方案：把每个 lane 拆成独立 workflow
（必需检查和分支规则都要改，触发次数翻倍）；只按“这次 push 新增的提交”分类
（同步 `preview` 时会把别人的改动算进来，正是要避免的全量重跑）。接受的风险：
复用的结果没有测过“PR + 新的 base”这个组合，由合并后的 universal 打包
兜底。

合并之后只运行 PR 观察不到的部分。PR 是合入 `preview` 的门槛，完整验证在 PR
上完成；合并后的 push 只在改动涉及打包内容时构建 universal 包。这是 x86_64
唯一一次编译和链接，也会编译“各自通过的 PR 合在一起”的组合，PR 自己的 CI
覆盖不到这两点。`preview` → `main` 的 PR 不跑任何 lane，只核对同一提交在
`preview` 的 push 上已经通过 macOS CI；push 到 `main` 不触发 CI。分类脚本用
`LITHE_CI_SCOPE`（`pull_request`、`post_merge`、`release_promotion`）区分这些
场景。被否方案：合并后完全不跑 CI（Intel 编译和 PR 组合问题会一直留到 AutoBuild
或发布时才暴露）；要求 PR 与 `preview` 保持最新后再合并（并行 PR 多时每次合并
都要重跑完整 CI，总用量反而更高）。Windows CI 因此不再在 `preview` push 上运行，
代价是 Windows 的 GitHub 缓存只由 PR 刷新，`Cargo.lock` 变化后的几个 PR 会从
较旧的前缀命中开始编译。

自托管 runner 同时装有带更新 macOS SDK 的 Command Line Tools。首次在 Mac mini 上
构建 universal 包时，链接 x86_64 时解析到了 `CommandLineTools/SDKs/MacOSX27.0.sdk`，
Xcode 26.6 的链接器无法读取其中的 `libSystem.B.tbd`。`setup-macos-toolchain` 因此在
自托管 runner 上把 `SDKROOT` 固定为所选 Xcode 自带的 SDK，并拒绝解析到 Xcode
之外的 SDK。

Swift 测试 lane 和其他 lane 一样可以分到 Mac mini。首轮在 Mac mini 上运行时，
`DesktopIsolationTests` 因 WindowServer 两秒内没有登记原生窗口而失败。逐项排查后
确认原因是 macOS 27：在 Mac mini（macOS 27.0.1）上 `CGWindowListCopyWindowInfo`
整体返回 NULL，连 `.optionAll` 也一样；同一段代码在 macOS 26.3.1 上没有录屏权限
也能返回窗口。排查中给三个 runner 自带的 `externals/node<N>/bin/node`（macOS 把
测试进程归属到它）授予了录屏权限，并关闭了远程软件断开时的锁屏，两项都确认
生效（`kTCCServiceScreenCapture` 为允许，`IOConsoleLocked = No`），但都不改变
结果。这个接口自 macOS 15 起被弃用，产品代码没有使用它。

处理方式是只拆出无法执行的那一项检查，而不是整体跳过或固定托管池：原测试拆成
两条，可见性和像素绘制始终运行；读取 WindowServer 透明度的那条用
`.enabled(if:)` 在窗口列表不可用时跳过，测试报告里写明原因（#1278）。为了不让
隔离逻辑的改动失去这项检查，分类脚本在 `macos/Tests/LitheTestDesktopIsolation*`
变化时输出 `swift_hosted`，选择器通过 `LITHE_HOSTED_ONLY_LANES` 把这次运行的
Swift lane 留在托管的 macOS 26 runner 上。被否方案：Swift lane 一律固定托管池
（托管池满时它是 PR 最慢的一环，10/16 排队 16 分钟）；在 Mac mini 上整体跳过这条
测试（会连同仍然可验证的排列和绘制一起丢掉）。苹果提供可读取透明度的替代接口
后，恢复在 macOS 27 上的完整检查。同一轮还暴露出编辑器字体
目录把声明了等宽但拉丁字符不等宽的字体（兰亭黑 `Lantinghei TC`）列为等宽，
那是产品缺陷，单独修复。

这个选择是一次性的近似判断：只统计本仓库的 job，看不到组织内其他仓库对
托管池的占用；多个 PR 同时进入分类时也可能看到同一个空槽位。它解决的是
“一边排队、另一边空闲”的常见情况，而不是精确调度。被否方案：用管理员
令牌查询 runner 在线状态（fork PR 拿不到密钥，PR 工作流也不应持有管理
权限）；排队超时后取消重投（浪费已排队时间，实现复杂）。

三个 runner 共用物理资源，不等于三台机器。自建任务通过
`prepare-macos-ci-runner` 安装 Node 24，检查系统工具并记录整机资源快照；
设置 `CARGO_BUILD_JOBS=2` 与 `LITHE_SWIFT_BUILD_JOBS=2`，SwiftPM 入口统一
加载 `scripts/macos-swift-build-options.sh`，本地和官方任务未设置变量时保持原并发。
这限制编译器调度，不限制所有测试子进程，也不放宽原有测试期限。
自建 Xcode 由管理员预先选择，CI 只校验固定版本并设置 job 内的
`DEVELOPER_DIR`，不让三个任务并发修改机器级 Xcode 选择。

正确做法：三个 runner 都带同一标签、分别使用自己的 checkout、构建输出和
临时目录。不要这样做：把 `.build`、`rust/target` 或整个 `.artifacts` 链接为
跨 runner 的共享目录来省磁盘，这会把并发 PR 的可变状态混在一起。

每个 runner 在自己的工作目录内保留增量编译结果。自托管 job 的
`actions/checkout` 使用 `clean: false`，随后 `prepare-macos-ci-runner` 调用
`scripts/reuse-macos-runner-build-state.sh`：`git clean -ffdx` 删除所有未跟踪
文件（否则上一个 PR 留下的 Swift 源文件会被 SwiftPM 的目录扫描编进去），只排除
`.build`、`rust/target` 和四个依赖下载目录。Xcode、Swift 或 CPU 架构变化时
丢弃编译输出；编译状态超过 40 GB 或磁盘剩余不足 25 GB 时也整体丢弃重建。
首轮观察到，三个 runner 随机接任务时，打包（release 编译）和插件测试
（debug 测试编译）经常轮流落到同一台机器，保留的状态几乎用不上。因此 runner
再按编译配置分组：两台带 `lithe-mac-mini-debug`（Swift、插件、Rust Core 测试共用
debug 测试编译和 debug Rust Core），一台带 `lithe-mac-mini-release`（打包）。
选择器优先把 lane 分到自己的组，该组满了先借另一组的空闲 runner，再溢出到
托管池；只带共享标签的旧 job 可能占用任意一台，所以整池容量仍然约束总数。
同一时刻一个 runner 只跑一个 job，状态不跨 runner、不跨 worktree，因此不违反
“可变构建状态不得共享”的规则；它只是让同一个工作目录不再每次从零编译。
自托管 job 跳过 GitHub cache 的恢复与保存：本地目录已经保留了这些内容，
而 Mac mini 的系统版本与托管 runner 不同，它保存的 Cargo 编译缓存键托管
runner 永远不会命中。保留下来的依赖目录仍经过
`validate-macos-dependency-caches.sh` 的同一套校验，不合格就清空回退。

保留 `pull_request` 事件、只读仓库权限及原有审批策略，不改为
`pull_request_target`，不向 fork 提供发布密钥。保留构建状态意味着 fork PR
的编译输出会留在 runner 上被后续 job 增量使用；`.build` 与 `rust/target`
只包含编译产物，后续 job 重新编译改动的源码，但这不是对恶意代码的隔离边界。
如果需要接受不受信任的 fork 代码，应改为每个 job 前清空构建状态，或为 fork
保留托管池。

Swift 测试 job 同时承担 Rust Core 的 Swift 链接验证：
`scripts/verify-rust-core-swift-bridge.sh --skip-build` 复用该 job 已编译的
测试产物，检查 C ABI、链接符号、Git execution 集成和桥接测试；Rust Core
job 只运行 `scripts/verify-rust-core-crates.sh` 的纯 Rust 检查。此前两个 job
各自完整编译一次 Swift，同一个 PR 同时改 Swift 和 Rust 时会重复占用一个
macOS 槽位约十分钟。只改 Rust 时 Swift 测试 job 仍会启动，但只编译并运行
桥接验证，不跑完整单元测试。本地 `scripts/verify-rust-core.sh` 依次运行两半，
入口不变。

此前在旧 runner 上通过 Swiftly 安装独立工具链失败，测试未能启动。因此继续
使用完整 Xcode，让 Swift、链接器和 SDK 保持匹配。Xcode 27/SDK 27 只作为
开发者本机的兼容路径，不进入 CI 基线；`MacOS13SDKCompatibility.h` 仅在
macOS 13 SDK 上补充缺失的 `NSView.clipsToBounds` 声明，SDK 14 及更高版本
不会重复导入 AppKit，也不会触发模块定义冲突。这个修复同时覆盖旧 SDK 和
SDK 27。升级工具链不改变应用的 Swift 5 语言模式、测试的 Swift 6 语言模式
或 macOS 13 最低运行版本。

部分新版 SwiftPM 会把 `--triple` 的默认产品放在 `.build/out/Products`，
不再自动隔离 arm64 与 x86_64。构建脚本先读取 `swift build --show-bin-path`
判断实际布局：只有检测到这个新版布局时才使用 `.build/<triple>` 作为独立
scratch path；Xcode 26.6/Swift 6.3.3 继续使用原来的默认路径。插件构建同时
兼容旧版的 `Modules/` 目录和新版直接放在产品目录中的模块文件。

路径分类器先决定 PR 需要哪些验证。普通 `macos/Sources/` 改动由 Swift 测试
负责完整编译，不再重复生成两个 DMG。资源、SwiftPM 图、Rust bridge、平台
组合、打包脚本和工具链等改动只产出 Apple Silicon（`arm64`）包；Intel
（`x86_64`）的编译、链接和打包改由合并到 `preview` 后的 universal 包验证，
它会用 `lipo` 检查两个架构切片。需要在合并前拿到 Intel 包时，开发者手动
运行 macOS CI 工作流。

macOS runner（GitHub 托管的 Mac 构建机）按组织共享，Free 计划同时只能跑
5 个 macOS job，超出的 job 只能排队。排队不是配额耗尽，也不是滥用信号，
但会拖慢所有 PR 的反馈。因此：

- 主 Swift 测试和数据库 Swift 测试共用 macOS CI 的 **Swift tests** job，只执行
  一次 `./scripts/test-macos.sh list` 编译，再按分类结果运行各自的过滤测试。
  过去数据库 job 单独编译约 10 分钟，只为运行十几秒测试。Database CI 只保留
  Linux 上的 Rust 数据库测试和 gate。
- 插件测试保留在独立的 macOS Plugin CI，只有分类器选中插件 lane 时才申请
  macOS runner。多数 PR 不改插件，独立 job 时整条 lane 直接跳过；合进共用
  job 则需要为少数插件 PR 额外拉长主 Swift job，收益更小。
- `shared/platform-feature-matrix/` 是规划数据，产品代码不读取，由 Verify
  Platform Feature Matrix 工作流单独校验。几乎每个功能 PR 都要更新它；过去它
  落入 `shared/*` 规则，只改 macOS 界面的 PR 也会触发 Windows CI 和 macOS 上
  17 分钟的 Rust Core 测试。现在矩阵文件和 Markdown 一样走文本流程：只做
  `git diff --check` 和矩阵自身校验，不选择任何 runner lane。`shared/contracts/`
  下的 JSON schema 与 `shared/fixtures/` 会被各平台代码和测试读取，仍按共享
  契约选择 Swift、Rust Core 和 Windows lane。
- 高频改动路径按真实消费方选择 lane，不落入“未知路径全量验证”的兜底分支：
  `frontend/editor/` 与根目录 `package.json`、`bun.lock` 只被 macOS 打包 lane
  （Bun 测试和 WebKit 工作台探针）与 Windows 前端 lane 使用；本地化
  `*.lproj` 与 `WorkbenchView.swift` 不再选择独立插件 lane。插件相关的本地化
  断言放在 Swift lane 会运行的 `AppLocalizationTests` 中，测试名不能包含
  `Plugin`，否则会被 Swift lane 的插件过滤跳过。按上周 18 个 PR 提交回放，
  Rust Core 从 18 次降到 3 次，Windows Rust 与真实 JDT 降到 3 次。
- 分类脚本读取 `LITHE_CI_DRAFT_PULL_REQUEST`。Draft PR 关闭所有 macOS 和
  Windows lane，只保留 Linux 上的分类、diff、Rust 数据库、注释和元数据检查；
  PR 标记为 ready for review 时，macOS CI、Windows CI 和 macOS Plugin CI 重新
  触发完整分类。

正确做法：新增 Swift 专项测试时，在共用 **Swift tests** job 里加一个按分类
结果执行的过滤步骤。不要这样做：新建一个 macOS job 再跑一遍
`./scripts/test-macos.sh list`，这会让每次推送多占一个 macOS runner 约
10 分钟。

Git 性能基线和 Git 状态观察属于专项验证。只有 Git 生产代码、对应专项测试或
测试工具链发生变化时才运行；普通搜索、编辑器或设置界面改动不会为无关的
Git 性能测试增加等待时间。推送到 `main` 或手动运行时，再使用相同编译产物
组装通用 DMG。Windows PR 把前端验证与 Rust 测试放在两个独立 job 中并行
执行；Windows x64 NSIS 安装包只由 preview 和稳定版发布工作流生成。

Git 图形的离屏帧采样保留完整 1,000 行历史，但每次只绘制 40 行的可见区域，
分别覆盖开头、中间和末尾。绘制前把该区域的坐标映射到小位图，绘制后检查
实际有图形像素，避免中段被裁剪为空时得到虚假的快速结果。完整 1,000/5,000
行图结构、顺序和签名仍由独立用例与 Release 验证器检查；单帧中位数和整个
测试的时间上限保持不变。

正确做法：模拟滚动窗口的一帧，把可见区域作为绘制输入。不要把全部历史
重复绘制 220 次当作单帧采样：这会把画面之外的工作混进测试总耗时，在共享
runner 上可能出现断言都通过、计时工具仍因超过十秒而失败的情况。

CI 缓存 Cargo fingerprints、build script outputs 和依赖 outputs，不缓存
最终可执行文件。缓存覆盖 `rust/target/macos` 的 Rust Core 和 `rust/target`
的数据库辅助 crate；缓存键必须包含运行器架构、编译器、Xcode/SDK/macOS
版本、构建参数、依赖 manifest 和 build script。最终打包仍然重新运行必要的
构建步骤，确保产物来自当前验证过的源代码。

Cargo 编译缓存只在准备阶段恢复，保存由
`.github/actions/save-macos-cargo-build-cache` 以 `if: always()` 单独执行。
`actions/cache` 的 post 步骤在失败或取消时会被跳过：2026-10-13 一次依赖改动
让 universal 精确键失效，旧 universal 条目又因仓库缓存超过 10 GB 被淘汰，
冷构建约 45 分钟，超过 40 分钟上限被取消后什么也没保存，随后每次 preview
推送都从冷启动开始并继续超时。现在的做法：

- 成功的 job 保存精确键；失败、超时或被新推送取消的 job 保存
  `<精确键>-partial-<run_id>-<attempt>`，下一次通过精确键的前缀匹配续用，
  精确键留给第一次完整成功的构建。Cargo 只在单元编译成功后写 fingerprint，
  被中断的产物会重新编译，不会被当作有效结果。
- universal 构建找不到 universal 条目时回退到同一工具链身份的 arm64、
  x86_64 单架构条目（来自 preview 发布工作流），至少复用一半 Rust 编译和
  宿主侧 build script。单架构构建不回退到另一架构的条目，那份目标产物用不上。
- PR 只恢复不保存：PR ref 作用域的条目 preview 读不到，却每个约 565 MB，
  会把 preview 自己的条目挤出配额。
- macOS CI 的 release-build 超时为 60 分钟，覆盖冷 universal 构建，不需要
  拆成两个并行 job，也就不多占 macOS runner。

每个安装包同时提供 SHA-256 校验和。artifact 默认保留 14 天；DMG 和 NSIS
本身已经压缩，因此包裹 artifact 使用压缩级别 0。macOS CI 使用临时 ad-hoc
签名；Windows preview 与稳定版发布工作流分别执行各自的签名策略。

PR 的测试合并提交必须在构建摘要中可追溯。被分类器选中的 macOS 任一架构
失败都使 macOS gate 失败；架构任务使用 `fail-fast: false`，以便另一架构仍可
完成并上传诊断产物。Windows gate 分别检查前端和 Rust job：被选中的 job 必须
成功，未被选中的 job 必须跳过。需要 Windows 安装包时手动运行 preview 发布
工作流，不在 PR CI 中等待完整 Release 编译和 NSIS 打包。

并发缓存主要缩短串行等待和反馈时间，不承诺减少总 runner 分钟；队列等待
和可用 runner 数量属于 CI 基础设施因素，不能与编译优化混为一谈。

Windows 安装器失败时，Bun 可能已经退出，但并行的生命周期脚本仍在运行，
继续占用依赖目录；直接删除目录会让原本可以重试的下载故障变成文件锁错误。
每次安装现在由独立 PowerShell worker 拥有：启动 Bun 前把 worker 加入
Job Object（Windows 用于管理整棵子进程树的对象），设置最后一个句柄关闭时
终止成员进程。句柄不继承给子进程，由 worker 的进程生命周期持有；worker
正常结束、失败或被取消时，系统释放句柄并终止残留脚本；每次安装还有默认
300 秒的 worker 内部期限，超时退出码为 124，不能只依赖 CI 总超时。父安装器再清理
部分缓存和依赖。文件系统释放锁可能稍晚，删除重试有单调计时的 10 秒期限，
超时明确失败，不无限等待。缓存清理后撤销旧 verified 标记，冷安装成功才
重新生成完整性清单。只重试一次，不把永久安装错误隐藏成成功。

正确做法：worker 拥有 Bun 及其脚本，结束后再清理当前工作树生成目录；
不要按进程名结束所有 Node/Bun，因为用户其他工作树或应用可能正在使用它们。
这些句柄和安装目录属于本次安装，不新增可复用资源；只有经过锁文件、Bun
版本与完整性清单校验的下载缓存可以跨工作树复制，安装包仍只读。

## 考虑过的备选方案

### 在旧 runner 上用 Swiftly 安装独立编译器

这能单独选择 Swift，但安装器失败会阻断所有后续验证，且 SDK 与编译器可能
来自不同版本。当前需要的 Swift 已随 Xcode 26.6 提供，所以使用预装 Xcode，
不再额外下载工具链。runner 删除固定 Xcode 时，工作流会明确报错，届时重新
验证并升级版本组合。

### 缓存最终可执行文件

可以减少部分打包时间，但容易受到源码、编译器、SDK 和构建参数变化影响，
也会掩盖当前提交是否真正完成构建，因此不采用。

### 把 universal 包拆成 arm64、x86_64 两个并行 job

单次耗时会变短，但每次 preview 推送多占一个 macOS runner，与组织 5 个
macOS 并发上限冲突，也会和 PR、Swift 测试互相排队，因此不采用；改为保证
缓存在任何结局下都能保存，并放宽超时覆盖冷构建。

### 对 preview 推送关闭 cancel-in-progress

能让每次推送都跑完并保存缓存，但连续合并时 runner 分钟数成倍增加，
后续推送要排队等待前一次完成。always() 保存部分缓存已经让被取消的运行
留下进度，因此保留取消旧运行。

### 只缓存下载依赖

能减少网络等待，但无法覆盖 Rust Core 和数据库辅助 crate 的主要编译成本，
因此扩展为缓存 Cargo 的中间输出和 build script 结果。

### 失败后仅限制安装并发或等待固定时间

不采用。相同 Bun 版本的本地生命周期探针表明，串行选项也不能保证失败后
没有残留脚本；固定等待则无法证明进程结束。直接结束全部 Node 还会影响
其他任务。Windows Job Object 提供系统级所有权和取消清理，代价是每次安装
多启动一个 PowerShell worker，安装路径的回归测试需要在 Windows 上运行。

### 所有分支都只构建一个 macOS 架构

可以降低 CI 成本，但无法发现另一架构上的编译、链接和打包问题，因此不采用。
现在的折中是 PR 只打 arm64 包，`preview` 推送和手动运行仍构建 universal 包，
覆盖 x86_64。代价是 Intel 专属的问题要在合并后才暴露，需要由 `preview` 上的
macOS CI 失败来修复。

### 把插件测试也并入共用 Swift job

可以再省一次插件 PR 的编译，但插件 lane 只在少数 PR 中被选中。并入后会把
插件过滤测试和官方插件打包验证串进主 Swift job，延长包含插件改动的 PR 的
主反馈路径，因此插件 CI 保持独立并依赖分类器跳过。

### 用 workflow 的 `paths` 过滤跳过插件或数据库 CI

`Plugin CI gate` 和 `Database CI gate` 是 `preview` ruleset 的必需检查。
workflow 被 `paths` 过滤掉后不会上报状态，PR 会一直等待这个检查，因此继续
使用“Linux 分类 job + gate”的方式：未选中时 gate 在 Linux 上几秒内通过。

### 为所有 CI 任务强制上传完整安装包

会增加文档-only 或不需要产品包的构建时间和存储成本。macOS 只在产品构建
lane 被选中时上传测试包；Windows PR 不上传安装包。

Windows PR 曾经只要命中产品 lane 就先生成完整 NSIS 包，导致前端与 Rust
测试必须等待 Release 编译结束。安装包不是合并判断的输入，且 preview 发布
工作流已经提供可安装产物，因此 Windows PR 完全移除打包步骤，而不是仅把它
挪到另一个仍会阻塞 gate 的 job。

### 为每个 Swift 源码 PR 强制生成双架构安装包

Swift 测试已经编译完整 Lithe 目标。再生成两个 DMG 会在普通界面或业务逻辑
改动上重复消耗约二十分钟 macOS runner 时间，并把必要反馈推迟到最慢的打包
任务结束。双架构验证因此保留给真正影响包内容和构建边界的改动；开发者需要
临时安装包时使用手动工作流。

### 提高 Git 帧采样的总时间上限

这能容纳重复绘制完整历史的耗时，却保留了与可见窗口不符的工作量，也削弱
其他测试的时间门禁。因此修正采样范围与位图坐标，继续使用原有上限；完整
图的正确性检查不减少，批量绘制不能替代可见区域的帧成本测量。

## 后果

- 普通 macOS Swift PR 更快得到必需检查结果；被选中的打包改动在 PR 中获得
  arm64 安装物，x86_64 在合并后的 universal 构建中验证。
- 一次涉及数据库的推送少占一个 macOS runner，PR 打包少占一个 macOS runner；
  Draft PR 迭代期间不占 macOS/Windows runner。
- Git 专项验证不会再延长无关 Swift 改动的反馈时间。
- 帧采样只绘制可见区域，减少与屏幕无关的测试工作；它不衡量完整历史的一次
  批量导出，也不等同于需要显式开启的真实窗口帧率采样。
- Windows 前端失败与 Rust 失败可以独立、并行反馈，不再等待 NSIS 安装包。
- 缓存命中时可减少 Rust 相关重复编译，同时通过完整缓存键避免跨环境误复用。
- artifact、校验和、合并提交与 gate 结果共同提供可追溯的测试交付物。
- 冷构建、编译器变化、依赖变化和 runner 排队仍可能很慢，不能把缓存策略
  当作总耗时保证。
- 构建工作流调整时必须同步检查缓存键、包架构、gate 依赖和 artifact 保留期。

## 验证

- `node --test scripts/macos-swift-build-options.test.mjs`：覆盖默认并发、有效预算及无效输入。
- `node --test scripts/select-macos-ci-runners.test.mjs`：覆盖空闲优先、满载溢出、push 只用
  Mac mini、跳过当前 run 以及 API 失败时的固定分配。
- `node --test scripts/reuse-macos-runner-build-state.test.mjs`：覆盖保留编译输出、清除其他
  未跟踪文件、工具链变化丢弃编译输出及参数校验。

- `actionlint .github/workflows/ci-macos.yml .github/workflows/ci-windows.yml .github/workflows/ci-database.yml .github/workflows/ci-plugins.yml`
- `./scripts/test-classify-ci-changes.sh`：包含 Draft PR 关闭 runner lane、保留 Linux lane 的用例。
- `./scripts/test-classify-ci-changes.sh` 覆盖 `save-macos-cargo-build-cache` 改动触发全部 macOS lane。
- `actionlint .github/workflows/ci-macos.yml .github/workflows/release-preview-macos.yml`
- `./scripts/test-macos.sh`
- `./scripts/test-git-performance-baseline.sh`
- `./scripts/build-macos.sh --configuration debug --triple arm64-apple-macosx`
- `./scripts/build-macos.sh --configuration debug --triple x86_64-apple-macosx`
- `./scripts/build-official-plugins.sh --configuration debug --triple arm64-apple-macosx`
- `./scripts/build-official-plugins.sh --configuration debug --triple x86_64-apple-macosx`
- `./scripts/verify-rust-core.sh`
- `./scripts/verify-windows-boundaries.sh`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory . --max-ms 30000 --report .artifacts/test-stability/windows-dependency-install.json -- scripts/windows-frontend-install.test.ts`：Windows 无网络夹具用 IPC 确认子进程占用目录，再让安装失败，验证清理后冷重试成功、永久失败仍报错、成功退出也不留子进程、超时触发本地期限，且不清除有效缓存。
- `gh run download <run-id> --repo 1lck/Lithe-IDEA --pattern 'Lithe-macos-*'`
- `gh workflow run release-preview-windows.yml -f source_branch=<branch>`

具体下载方式、工作流入口和历史耗时记录见
[`docs/ci-builds.md`](../../../../docs/ci-builds.md)。

## 适用范围

- `docs/ci-builds.md`
- `.github/workflows/ci-macos.yml`
- `.github/workflows/ci-windows.yml`
- `.github/workflows/ci-database.yml`
- `.github/workflows/ci-plugins.yml`
- `scripts/classify-ci-changes.sh`
- `scripts/install-windows-frontend-dependencies.ps1`
- `scripts/invoke-windows-bun-install.ps1`
- `scripts/windows-frontend-install.test.ts`
- `scripts/test-classify-ci-changes.sh`
- `scripts/build-macos.sh`
- `scripts/build-official-plugins.sh`
- `scripts/verify-rust-core.sh`
- `scripts/MacOS13SDKCompatibility.h`
- `rust/`
- `macos/`
- `windows/tauri/`
