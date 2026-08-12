# Windows 功能追平开发计划

本文是 Windows 端追平 macOS 功能的唯一开发计划。它面向继续实现
`windows/` 的开发者，记录剩余工作、依赖关系和开发侧完成标准。

这份计划只覆盖开发交付。真实 Windows 场景、完整 UI 回归、安装升级、签名和
兼容性验收由测试人员负责，不计入开发排期。

## 使用唯一的 Windows 技术路线

Windows 端以 `windows/winui/` 下的 WinUI 3、C++/WinRT、C++23、Win32 adapters
和 Rust core C ABI 实现为唯一开发基线。后续任务必须在这套分层上继续，不再并行
维护 Qt、Electron、Node.js 或其他桌面运行时实现。共享行为继续进入
`rust/lithe-core` 和 `shared/contracts`，Windows UI 与平台能力继续留在
`windows/`。`windows/qt/` 只在迁移验证期间作为行为参考保留，不是发布入口。

## 当前集成状态（2026-08-10）

`feat/windows-git-parity` 是 Windows 多人开发的集成基线。W0 已在本地完成以下
收口：

- 合入 `origin/main` 的 `2d5bbf8`，消除开始并行开发前的主线落后。
- 修复 Shelf 测试的泛型结果断言和 macOS 系统临时目录符号链接误判。
- 确保 Project Detection 和 UI Translation 测试在 Release 构建中保留断言。
- 当时将 Qt Widgets、C++23、Win32 adapters 和 Rust core ABI 冻结为 Windows 路线；
  2026-08-11 起表现层迁移到 WinUI 3，应用层和平台边界保持不变。
- 通过 38 个 Rust 测试、Debug 和 Release 各 15 个跨平台 C++ 测试、58 个 Swift
  测试，以及 Windows 边界、共享契约和 Rust/Swift bridge 检查。

这些结果仍不等同于真实 Windows 验证。分支改动推送后，必须通过 Windows CI 的
MSVC、WinUI 3、Win32 和 Rust 测试，才能把 W0 标记为远端完成。

### 已完成并提交

- `7720cd9 docs(windows): replace parity planning documents`
  - 用本文替换旧的 Windows 追平计划和容易过期的进度文档。
- `799e27e feat(windows): add advanced Git contract DTOs`
  - 补齐 `git.checkoutPreflight`、`git.pullPreflight`、
    `git.integrationPreflight`、`git.conflictMarkers` 和
    `git.operationState` 的 Windows 请求编码与响应解码。
  - `GitCommandDto` 已解码结构化 `stashRestore`；`GitWriteRequestDto` 已支持
    `force` 和 `autoStash`。
  - `shared/contracts/rust-core-api.md` 已同步新增命令、操作值和实际字段名
    `hunkId`。
- `8565e38 feat(windows): wire advanced Git state queries`
  - 五个安全状态查询已接入 `WorkbenchCoordinator`，各自使用 workspace epoch 和
    operation generation 丢弃陈旧结果。
  - `GitFeatureState` 已能保存 checkout/pull/integration preflight、冲突标记、
    进行中的 Git 操作、stash 恢复冲突和去重后的冲突筛选路径。
  - stash 恢复冲突会跨后续普通写结果保留，直到调用
    `clearStashRestoreConflict()` 明确清除。

本机已通过 `lithe_windows_core_dto`、`lithe_windows_coordinator` 和
`scripts/verify-windows-boundaries.sh`。这些结果只证明平台无关的 C++ 逻辑和边界，
不代表真实 Windows WinUI 3 交互已经验收。

源码收口审计（2026-08-11）确认：Git revision checkout、Cherry-pick、Revert、
Reset、分支创建/重命名/删除，以及 checkout/integration 的 pending 冲突状态都已
接入 `WorkbenchSession`、`GitFeatureModel`、Rust core 和 WinUI 菜单。旧版清单中
这些项目的未勾选状态属于文档滞后；最终 Windows CI 和实机验收仍按本文末尾执行。

### 接手者优先完成

1. 完成 Git preflight 状态机：增加带目标上下文的 pending checkout、pending pull
   和 pending integration，只有 preflight 清空后才能执行对应写操作。
2. 为所有 Git 写操作增加统一、可嵌套的 begin/end 生命周期。最外层 begin 停止
   watcher，最外层 end 只触发一次 workspace、Git status、operation state 和必要的
   history 刷新；工作区切换和陈旧回调必须正确收尾。
3. 增加 checkout、pull、merge/rebase、cherry-pick/revert、continue/abort/skip
   的 feature model 测试，覆盖阻塞路径、stash 恢复冲突、非零退出码和陈旧结果。
4. 提交前同时检查 unmerged 状态和 `git.conflictMarkers`，不能只依赖 Git 的自然
   语言错误输出。
5. 再接 WinUI 入口：checkout/integration 冲突对话框、进行中操作栏、冲突筛选、
   fetch/push/merge/rebase/cherry-pick/revert/reset 和破坏性操作确认。
6. 完成版本化 Lithe Shelf service 与测试，再接 Changes 面板；恢复失败时必须保留
   Shelf，staged patch 和 working-tree patch 必须分开存储。

阶段 1 到阶段 4 的第一阶段范围已经完成源码接入。Git checkout 已接入机器可读
preflight 和统一 watcher 写入生命周期；WinUI 资源、对话框和静态契约检查也已
收口。真实 Windows 构建和交互验收完成前，不把这些开发侧结果视为最终验收通过。

当前明确排除：Java/Maven/JDT LS 完整体验、项目真实编译与运行、Run/Debug 和断点。
这些能力保留在实验性服务和 UI 入口中，但不属于本轮交付标准。

## 先按开发完成标准交付

一个功能只有同时满足以下条件，才能从计划中勾选：

- Windows 应用层和 WinUI 界面已有可到达的完整操作路径。
- 错误、取消、工作区切换和陈旧结果都有明确处理。
- 纯逻辑、DTO 和状态机有自动化测试；不能自动化的交互已写入测试交接说明。
- `Windows CI` 可以构建 Rust core、C++、WinUI，并通过 CTest、Rust 测试和边界检查。
- 没有通过修改 macOS 专属实现来绕过 Windows 缺口。

开发完成不代表测试通过。以下工作由测试人员在开发交接后执行：

- 在真实 Windows 设备上完成端到端功能回归。
- 覆盖不同 Git、JDK、Maven、Shell 和系统版本组合。
- 检查 UI 呈现、键盘操作、性能和长时间运行稳定性。
- 验证安装、升级、卸载、签名和更新包替换流程。

## 以当前 macOS 功能面为基线

Windows 已具备独立的 C++23、WinUI 3 和 Win32 实现，并通过 Rust C ABI 复用
共享核心。现有基础包括工作区、编辑保存、搜索、基础 Git/Diff、Local History
读取、Java 运行与调试、JDT LS、AI 提交信息、更新服务和 Windows CI。

当前还不能宣称功能追平。剩余开发集中在以下范围：

| 范围          | 当前 Windows 状态                          | 追平目标                                     |
| ------------- | ------------------------------------------ | -------------------------------------------- |
| Git 工作流    | 集成操作、冲突状态、stash/Shelf 和安全确认可用 | 补齐 Shelve 策略与统一 watcher 生命周期   |
| 文件安全      | 干净重读、脏文件冲突选择和外部删除保护可用 | 补齐项目关闭与重命名场景的统一保护           |
| 项目替换      | 预览、选择、安全应用、历史留档和失败汇总可用 | Windows 交互验收与大项目性能验证           |
| Local History | 可读取历史内容                             | 并排比较、文件与项目级恢复、恢复前留档       |
| Java/Maven    | 服务层和基础操作可用                       | 配置选择编辑、Profiles、模块树和统一运行入口 |
| 终端          | 多个隔离 ConPTY 会话及完整基础操作可用     | 独立 feature model、逐会话 Shell 与测试覆盖  |
| 工作台        | 主流程可操作                               | 补齐命令、关闭保护、导航和 gutter 行为       |

如果 macOS 在开发期间新增功能，先把它登记到上表或对应工作流，再决定是否进入
本轮范围。不要用新增功能默默扩大现有任务。

## 按依赖顺序推进

开发顺序如下：

1. 冻结契约和功能清单。
2. 并行推进 Git 工作流与文件安全。
3. 在文件安全和持久化稳定后补 Java/Maven 配置体验。
4. 补终端和工作台交互。
5. 完成开发侧收口并交给测试人员。

Git 与文件安全可以由两名开发者并行。Java/Maven 会复用设置、会话和错误展示，
应在文件安全的状态模型确定后接入。终端改造相对独立，但最终要和工作台布局、
项目关闭流程一起集成。

## 阶段 0：冻结契约和追平清单

预计 1–2 个开发日。

### 对齐共享契约

- [x] 以当前 `Sources/Lithe/`、`rust/lithe-core/src/` 和
      `shared/contracts/rust-core-api.md` 为准，核对 Windows 已消费的命令和字段。
- [ ] 为 Windows 尚未消费的 Git 冲突、操作状态和 stash 恢复字段补 DTO fixture。
- [x] 明确哪些能力由 Rust 提供，哪些必须留在 Windows app/service 层。
- [x] 给每个剩余功能指定 WinUI 入口、feature model、service/adapter 和测试文件。

### 保持计划可维护

- [ ] 每个开发 PR 更新本文的对应复选框。
- [ ] 新增共享行为时先增加 fixture 或契约测试，再修改两个平台。
- [x] 不记录容易过期的代码行数和完成百分比；以可执行路径和测试为准。

完成本阶段后，开发者不需要再从旧的审计、handoff 或 DTO 快照中推断现状。

## 阶段 1：补齐 Git 工作流

预计 6–9 个开发日。这是当前优先级最高、状态组合最多的一组工作。

### 扩展协议和状态模型

- [x] 核对 Windows DTO 对当前 Rust Git 响应的覆盖，包括冲突路径、操作状态和
      stash 恢复冲突。
- [x] 在 `GitFeatureState` 中加入 pending checkout、pending integration、
      operation in progress、stash restore conflict、shelf 和冲突筛选状态。
- [x] 所有写操作通过统一的 begin/end 生命周期冻结 watcher；最外层操作结束后
      只刷新一次工作区和 Git 状态。
- [x] 提交前阻止仍含 unmerged 状态或冲突标记的文件进入提交。

### 实现安全的分支和集成操作

- [x] Fetch 和 Push。
- [x] Merge 和 Rebase。
- [x] Continue、Abort 和 Skip。
- [x] Checkout revision、Cherry-pick、Revert 和 Reset。
- [x] 分支重命名、删除；当前分支更新通过 Pull（ff-only/Merge/Rebase）入口完成。
- [x] Commit and Push。
- [x] 在 checkout、merge、rebase、cherry-pick 和 revert 前执行机器可读的 preflight。
- [x] 不通过匹配本地化 Git 文案决定控制流；使用退出码、porcelain 输出和集合运算。

### 接入 stash 冲突和 Lithe Shelve

- [x] stash apply/pop 冲突后保留 stash 引用和冲突路径，并持续展示恢复提示。
- [x] 为 Windows 增加版本化 Shelf 存储，分开保存 staged patch 和 working-tree patch。
- [x] 支持创建、恢复和删除 Shelf；失败时保留原 Shelf。
- [x] 让集成操作可以选择 Git stash 或 Lithe Shelf 保存本地改动，并持久化延迟恢复状态。
- [x] 中途进入 merge/rebase 状态时，延迟恢复本地改动，直到 continue 或 abort 完成。

### 完成 WinUI 入口

- [x] 增加 checkout 和 integration 冲突对话框。
- [x] 支持打开冲突文件 Diff、筛选阻塞文件、单文件回滚和经过 preflight 的安全重试。
- [x] 在 Changes 面板展示 Git stashes 和 Lithe shelves，并提供对应操作。
- [x] 在分支和提交入口补齐 merge、rebase、push、cherry-pick、revert 和 reset 命令。
- [x] 对破坏性操作提供确认，并在结果不确定时保留用户数据。

### 覆盖开发侧测试

- [ ] DTO 测试覆盖新增和缺失字段、`null` 与键缺失的差异。
- [ ] feature model 测试覆盖 preflight、冲突、恢复、continue/abort 和陈旧结果。
- [ ] Shelf 测试覆盖 staged/unstaged 分离、恢复失败保留和仓库隔离。
- [x] watcher 冻结测试覆盖嵌套 Git 操作和一次性刷新。

## 阶段 2：补齐文件安全、项目替换和 Local History

预计 5–7 个开发日。这一阶段负责防止静默覆盖和不可恢复的数据丢失。

### 处理外部文件冲突

- [x] 为文档状态记录已保存内容或磁盘版本标识，以及 `hasExternalConflict`。
- [x] watcher 检测到干净文件变化时自动重读。
- [x] watcher 检测到脏文件变化时保留编辑器内容，并显示冲突状态。
- [x] 提供 **保留编辑器版本** 和 **加载磁盘版本** 两条明确操作。
- [x] 删除、重命名和项目关闭不能绕过未保存内容保护。

### 完成项目级替换

- [x] 在 WinUI 中增加 Replace in Project 入口和对话框。
- [x] 支持大小写、整词、正则、Preserve Case 和文件掩码。
- [x] 展示按文件分组的预览，并允许选择全部、部分或取消文件。
- [x] 应用前为每个目标文件写 Local History。
- [x] 逐文件应用并汇总成功、失败和跳过结果；部分失败不能回报为全部成功。
- [x] 应用后刷新打开文档、工作区索引和 Git 状态。

### 完成 Local History 恢复

- [x] 文件级历史显示当前内容与历史内容的并排 Diff。
- [x] 项目级历史支持按文件浏览、选择版本和打开 Diff。
- [x] 恢复前自动记录当前版本，再写入选中的历史内容。
- [x] 恢复成功后同步编辑器、文档状态、watcher 和 Git 状态。
- [x] 重命名和删除前记录历史，并保持 history relocate 行为一致。

### 覆盖开发侧测试

- [ ] 文档状态机测试覆盖外部变化、脏缓冲区、保留和重载。
- [ ] replacement 测试覆盖选择、Preserve Case、部分失败和历史写入顺序。
- [ ] history 测试覆盖恢复前留档、文件重定位和大小/保留规则。

## 阶段 3：补齐 Java、Maven 和运行配置

预计 5–8 个开发日。现有服务层继续复用，新增业务状态不能堆进
`WorkbenchWindow`。

### 增加运行配置管理

- [ ] 在工作台增加运行配置选择器。
- [ ] 支持 Current File、Spring Boot 和 Maven Module 三类配置。
- [ ] 增加配置编辑器，覆盖 JDK Home、工作目录、VM 参数、程序参数和 Maven Profiles。
- [ ] 按项目和配置 ID 持久化选项，并清理已失效配置。
- [ ] 展示端口冲突，并允许用户定位冲突配置。
- [ ] Run 和 Debug 使用同一个配置选择和运行时解析结果。

### 完成 Maven 工具窗口

- [ ] 展示 Maven 根项目、模块、Profiles 和 Lifecycle 树。
- [ ] Profiles 使用可持久化的复选状态。
- [ ] Lifecycle 请求带上选中模块和 Profiles。
- [ ] 构建输出识别可定位的编译错误，并打开对应源码位置。
- [ ] 多模块运行输出和停止操作能定位到正确会话。

### 收紧 JDT LS 和调试接入

- [ ] 问题和引用面板在工作区切换后丢弃旧结果。
- [ ] 定义、引用、`jdt://`、`src.zip` 和 decompile fallback 使用同一导航入口。
- [ ] 当前文件、Spring Boot/Maven 和 Remote JDWP 使用一致的配置与错误展示。
- [ ] 停止和关闭项目时终止 Java、Maven、JDT LS、jdb 及其进程树。

### 覆盖开发侧测试

- [ ] 配置持久化测试覆盖三类配置和项目隔离。
- [ ] Maven 请求测试覆盖模块、排序后的 Profiles 和环境变量。
- [ ] Run/Debug 状态测试覆盖配置切换、停止、端口冲突和陈旧回调。
- [ ] LSP 测试覆盖 UTF-16 位置、外部源码 fallback 和工作区切换。

## 阶段 4：补齐终端和工作台交互

预计 4–6 个开发日。

### 将终端改成多会话

- [x] 用 terminal feature model 管理会话集合和当前会话 ID。
- [x] 每个会话独立持有 ConPTY transport、缓冲区、标题、Shell 和退出状态。
- [x] 增加新建、选择、关闭和切换终端标签。
- [x] 支持选择 Shell、Clear、Interrupt 和 Restart。
- [x] 关闭项目和退出应用时停止全部终端进程树。
- [x] 会话销毁后不能再向已释放的 WinUI 控件发送回调。

### 补齐工作台入口

- [x] 关闭脏编辑器标签时提供保存、放弃和取消。
- [x] 命令面板补齐关闭项目、项目替换、Local History、工具窗口切换和文件管理器定位。
- [x] 命令搜索使用与 Search Everywhere 一致的模糊子序列规则。
- [x] 完成行号、断点、blame、code vision、inlay 和导航 gutter 的点击行为。
- [x] 保存并恢复编辑器标签、活动文件、展开目录、工具窗口和分隔条布局。
- [x] 将通用确认/输入对话框拆出 `windows/winui/ui_dialogs.*`，并由 Git
      操作复用统一尺寸、换行、默认按钮和破坏性操作策略；后续大型工具窗口
      仍以最终 Windows 视觉检查结果决定是否继续拆分。

### 覆盖开发侧测试

- [x] terminal feature 测试覆盖创建、切换、关闭、重启和工作区关闭。
- [x] workspace session 测试覆盖无效路径过滤、项目隔离和布局恢复。
- [ ] 命令注册表测试保证 macOS 基线动作在 Windows 有对应入口或明确的平台例外。

## 阶段 5：完成开发收口并交给测试人员

预计 2–3 个开发日。此阶段不执行人工验收。

### 清理实现

- [x] 删除不再使用的旧状态、重复请求拼装和临时 UI 路径；旧 Qt 状态已移到
      `app/presentation`，Qt 工作台仅保留为迁移期行为参考。
- [x] 确认依赖方向仍为 `winui -> app -> adapters/core`。
- [x] 确认 `app/algorithms` 和 `app/services` 不包含 WinUI、Qt 或 Win32 头文件。
- [x] 更新 `windows/README.md`、本文和 UI parity contract 中的最终开发状态。

### 固化自动化检查

- [ ] Windows CI 构建 Rust core、C++ 和 WinUI。
- [ ] CTest、Rust 测试和 Windows 边界脚本全部通过。
- [ ] 新增 DTO 和共享行为有 fixture 或契约测试。
- [x] Git diff 没有格式错误，生成目录和安装包没有进入仓库。

### 准备测试交接

- [x] 为每个功能列出入口、准备条件、预期状态和错误路径，见
      `docs/architecture/windows-testing-handoff.md`。
- [x] 标出需要真实 Git 仓库、JDK、Maven、JDT LS、ConPTY 或网络的场景。
- [x] 列出开发阶段未能自动验证的 Win32 和 WinUI 行为。
- [x] 记录已知限制，但不把未测试行为标记为通过。

## 保持这些架构约束

后续实现必须继续遵守以下约束：

- Rust core 调用在固定 worker 上从头执行到尾。取消作用域依赖线程局部状态，
  不能改成会迁移任务的通用线程池。
- `operationId` 在调用点生成；交互请求、扫描和历史请求使用明确超时。
- coordinator 同时使用 workspace epoch 和操作域 generation 丢弃陈旧结果，并清理
  loading 状态。
- WinUI 不直接 include `core_client.h`，也不拼 Core JSON。请求编码和响应解码留在
  core/app 边界。
- 文件系统路径使用 `std::filesystem::path`；核心相对路径和 Git ref 使用不同类型，
  即使两者都采用 `/` 也不能混用。
- 编辑器内部位置统一为零基行号和 UTF-16 列，只在 DTO 边界转换。
- 增量 UTF-8 解码、LSP frame 重组和进程流切分留在 adapter 层。
- Core error、ABI error 和 JSON parse error 保持不同类型，不能吞成“没有结果”。
- Rust 的 `hunkId` 必须按实际字段名解码；`data: null` 和键缺失必须区分。
- Git 控制流不依赖自然语言输出。用户数据可能受影响时，失败路径优先保留数据和
  可重试状态。

共享线格式以 `rust/lithe-core/src/`、`rust/lithe-core/include/lithe_core.h` 和
`shared/contracts/rust-core-api.md` 为准。不要再维护一份手工复制的完整 DTO 清单。

## 按可审查的 PR 边界提交

建议把实现拆成以下 PR，避免一个 PR 同时修改所有状态机和 UI：

1. 契约 fixture、Windows DTO 和基础状态类型。
2. Git preflight、操作状态机和 watcher freeze。
3. stash 冲突、Shelf service 和 Git WinUI 入口。
4. 外部文件冲突和关闭保护。
5. 项目替换和 Local History 恢复。
6. 运行配置、Maven 树和统一 Run/Debug。
7. 多终端会话和工作台入口补齐。
8. 开发收口、文档和测试交接材料。

每个 PR 都应独立通过 Windows CI，并在描述中列出交给测试人员的新增场景。

## 使用这份排期

| 阶段 | 内容                   | 单人估算 | 可并行条件                   |
| ---- | ---------------------- | -------- | ---------------------------- |
| 0    | 契约和清单             | 1–2 天   | 必须先完成                   |
| 1    | Git 工作流             | 6–9 天   | 可与阶段 2 并行              |
| 2    | 文件安全、替换和历史   | 5–7 天   | 可与阶段 1 并行              |
| 3    | Java、Maven 和运行配置 | 5–8 天   | 阶段 2 状态模型稳定后        |
| 4    | 终端和工作台           | 4–6 天   | 终端可提前并行，最终统一集成 |
| 5    | 开发收口和测试交接     | 2–3 天   | 阶段 1–4 完成后              |

单人串行估算为 23–35 个开发日。两名开发者可以分别负责 Git/终端与
文件安全/Java-Maven，目标是在 3–4 周内形成可交给测试人员的版本。排期不包含
人工验收、缺陷回归轮次和正式发布操作。
