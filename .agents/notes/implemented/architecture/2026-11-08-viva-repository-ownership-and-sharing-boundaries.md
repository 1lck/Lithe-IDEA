# Agent 笔记：Viva 客户端的仓库所有权与共享边界

状态：已实现

## 先说结论

Viva 桌面客户端使用同一套 Go 界面代码适配 macOS、Windows 和 Linux，并通过 C ABI 调用独立仓库中的 Rust Core。可共享的解析、校验、状态转换和列表规则仍由 Core 持有；Go 层负责界面呈现、输入和必要的操作系统适配。迁移还在进行，目录存在或某个桥接方法可调用，不代表原有产品功能都已迁完。

## 问题

旧客户端分别使用 Swift 和 React/Tauri，平台代码与公共规则容易重复。更换界面框架时，如果界面层重新实现共享状态规则，不仅会造成结果漂移，还会让后续替换框架再次重写业务。另一方面，目录选择、窗口、焦点和文件监听必须调用平台能力，不能假装 Rust Core 本身能够代替这些接口。

## 决策

- `desktop/` 持有 Viva 界面、桌面组合和平台适配器；`desktop/internal/core/` 是调用 Core 的类型化桥接。具体功能的完成度以 `shared/platform-feature-matrix/` 和实际验证为准。
- Rust Core 位于 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust)，桌面构建脚本固定源码修订并链接其 C ABI。Core 命令的共享契约和夹具位于 `shared/`。插件源码和插件市场由对应的 Lithe-IDEA 组织仓库持有，不因为客户端重构而在本仓库重新维护一份。
- 调用操作系统、Viva 或文件监听 API 的代码留在平台适配器；视图可以持有焦点、悬停、滚动偏移等短暂呈现状态。其余可共享规则，包括解析、过滤、排序、树和列表投影、选择规则及业务状态转换，放在 Rust Core。具体判断和 Rust Core 注释要求以 `develop-lithe` Skill 为准。
- 欢迎页最近项目菜单捕获项目路径而非列表位置；移除只调用 Core 的最近项目归约并保存结果，不删除用户目录。保存成功后才替换显示的列表；保存失败时保留旧列表并报告错误。定位文件夹由平台接口执行。菜单的悬停、键盘焦点、Tab 循环和 Esc 后的焦点恢复属于短暂界面状态，不能用它们重建最近项目的排序或持久化规则。
- 欢迎页显示分支时，平台在后台读取最多 4 KiB 的 `.git` 指针和 `HEAD`，由 Core 解释分支与 worktree 指针；非 Git 目录不显示分支。只允许一个读取任务，最近列表变化时取消旧任务并丢弃旧结果，避免退出或移除项目后出现过期分支。普通文件适配器拒绝最终符号链接、设备和超限文件；文件系统调用本身仍可能被底层网络挂载延迟，不能声称它拥有硬实时退出保证。工作台项目切换菜单目前仍通过完整 Git 状态获取分支，跟踪 [#1808](https://github.com/1lck/Lithe-IDEA/issues/1808)。
- 欢迎页和项目菜单的克隆操作由窗口拥有：目录选择走平台接口，源地址和目标路径交给 Core 的 `git.write`，不在 Go 层执行 Git。目标名称必须是所选原生目录下的单个路径分量。对话框在后台操作完成前不允许开始第二次克隆；取消会请求 Core 停止，失败或取消留下的部分目录不自动删除。窗口关闭时取消任务；成功后仍需经过当前项目的关闭检查才打开新目录。当前尚未接入根据 URL 建议文件夹名称，弹窗也未完成原版视觉对齐。
- 正确做法：界面把工作区路径交给 Core 列出目录，再呈现结果；文件变化由平台监听并交给 Core 过滤。不要在 Go 中额外发明一套隐藏文件规则，也不要为了先展示多选而在界面层复制选择范围算法。
- 旧实现中仍可能有未下沉规则。迁移某个功能时要检查其实际归属；不能因使用了 Viva 或同一套 Go 代码就把所有共享规则视为已下沉。尚未迁移的行为保持未完成状态，不能用占位成功冒充实现。
- 安装后的应用包只读；缓存、插件状态、日志和临时文件使用平台可写目录。界面文案走 `shared/i18n/` 的统一生成接口；Go 的中英文类型目录已改为读取共享词库，带参数的模板由 `SharedFormat` 一次性替换，参数内容不会再次解释。Go 检查核对共享接口的固定 key、格式参数名、旧目录手写值和常见界面控件的直接字符串；其他界面 API 和间接传递的文案仍不能由这些静态检查完全证明，后续覆盖工作见 [#1807](https://github.com/1lck/Lithe-IDEA/issues/1807)。
- 编辑器从旧的 Monaco/Web 宿主迁向 Viva 原生组件（见 [#1794](https://github.com/1lck/Lithe-IDEA/issues/1794)）；原实验的增量版本校验、保存前等待和冲突保护等数据安全约束仍需在新实现中验证，不能把原实验结果当作新编辑器的验收。

## 考虑过的备选方案

### 继续维护两套平台客户端

各平台可以保留原生框架，但需要重复实现和验证工作台行为。Viva 提供共享桌面界面，仍为必须调用操作系统的能力保留适配器。旧架构及当时的取舍已归档，不能作为当前目录结构。

### 将共享规则放在 Go 界面中

短期接线较少，但会把状态规则绑到当前客户端，并与 Rust Core 的其他消费者产生不同结果。共享规则应先在 Core 定义并验证，再由界面接入。

## 后果

一个桌面界面实现可以复用布局和交互，但 macOS、Windows 和 Linux 的窗口、文件监听、终端及打包差异仍需各自验证。外部 Core 的修订、契约和本仓库桥接需要协调更新；现有桥接与索引读取不代表插件安装、后端宿主或全部 IDE 能力已经完成。

## 验证

- `./scripts/desktop/desktop-go.sh test ./...`
- `./scripts/desktop/desktop-go.sh test ./internal/core ./internal/workbench -run 'TestGitCloneUsesCoreAndPreservesExistingDestination|TestWelcomeClonesRepositoryThroughRealCore|TestClone|TestWelcomeMoreMenuClosesOnEscape'`：用本地仓库验证克隆、已有目标保护、选择目录、取消与失败；不代替真实远程认证及 Windows 原生验收。
- `./scripts/desktop/desktop-go.sh test -race ./internal/core ./internal/documentio ./internal/gitmetadata ./internal/workbench -run 'TestCheckoutMetadataUsesSharedFixture|TestReadFileLimitEnforcesSmallMetadataBudget|TestNativeGitMetadataReadsBoundedNormalAndWorktreeFiles|TestRecentBranchReadsNormalAndWorktreeMetadata|TestWelcomeBranchRowsGrowAndDoNotOverlap|TestWelcomeDiscardsStaleBranchReadAfterRecentListChanges' -count=2`：验证共享夹具、有界读取、worktree 与过期结果隔离；不代替 Windows 欢迎页原生验收。
- `go test -count=3 ./internal/documentio ./internal/gitmetadata ./internal/icons ./internal/appicon`：在 Windows 实机的隔离副本运行，验证文件适配器和相对、绝对 worktree 路径；该测试使用 Core 解析结果替身，不证明 Windows 下真实 Core 或窗口已完成验收。
- Windows 隔离环境使用真实 GNU 目标 Core 运行 `scripts/desktop/desktop-go.sh test -count=1 ./internal/core ./internal/workbench -run 'TestBuildDesktopCoreChecksOutFreshPinnedRevision|TestCheckoutMetadataUsesSharedFixture|TestRecentBranchReadsNormalAndWorktreeMetadata|TestWelcome'`，并用 Viva Windows 无头渲染检查普通仓库分支行；这不是完整原生窗口工作流验收。
- `./scripts/desktop/desktop-go.sh test -race ./internal/appicon ./internal/workbench -run '^(TestWelcome|TestLogEventsMatchCatalog)' -count=3`：覆盖欢迎页菜单、焦点、错误日志及图标数据；不替代原版视觉与 Windows 实机验收。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `node scripts/i18n/verify-app-language-localization.mjs`
- `node scripts/i18n/generate-i18n.mjs --check`
- `./scripts/agent-notes/verify-agent-notes.sh`：当前迁移分支仍有旧 Note 引用待清理，须通过后才能提交相关笔记。
- 受影响的平台还需要运行对应的原生窗口和功能回归；无头测试不能代替实机验收。

## 适用范围

- `desktop/internal/workbench/`
- `desktop/internal/core/`
- `shared/contracts/`
- `shared/platform-feature-matrix/`
- `scripts/desktop/`
- [Lithe-core-rust 固定修订](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust)
