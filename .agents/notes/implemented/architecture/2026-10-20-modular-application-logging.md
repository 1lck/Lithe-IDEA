# Agent 笔记：双端模块日志与诊断快照

状态：已实现

## 先说结论

macOS 和 Windows 使用同一组模块分类、脱敏和筛选规则，文件写入仍由各自平台负责。
查看日志时可以选择模块、当前或上一次会话、级别、时间范围和文本；导出使用确认时
已经冻结的脱敏内容。新增业务日志应记录操作阶段和结果，不记录源码、终端历史、
完整环境或协议正文。

## 问题

原来的 macOS 日志持续追加到一个文件，语言服务错误留在内存中；切换日志目录后，
诊断导出仍读取默认目录。Windows 已有队列和轮转，但嵌套 JSON 先转成字符串会漏掉
凭据，错误风暴还会从后台队列退回调用线程写盘。两端各自扩展会让隐私规则和排障
步骤继续分化。

## 决策

### 共享规则，保留平台所有权

Rust Core 的 `diagnostics` 模块只处理传入的数据，不读写文件、不启动线程。
它负责固定分类、递归清理结构化字段、限制内容大小，以及合并和筛选已经收集的
日志片段。平台适配器负责队列、时钟、会话身份、目录解析、原生文件操作和导出。
现有 Windows 缓冲写入与轮转继续复用；macOS 使用原有平台 writer 的独立后台队列。
不引入新的日志服务或第二套语言服务状态。

分类固定为应用运行、编辑器与语言服务、构建运行、Git、插件和性能。
具体功能通过范围标签（scope，例如 `language.java`）细分，不把调用方字符串直接
拼成目录。记录包含版本、UTC 时间、级别、进程、会话、顺序号；有操作或窗口身份的
入口继续提供这些关联字段。Git 只记录阶段、退出码和耗时，进程日志不复制命令输出。
语言服务入口持久化经过脱敏的生命周期信息，同时保留原来的最近 100 条 UI 日志。

正确示例：记录 `git.execution`、操作编号、退出码和耗时。
不要这样做：为了排查一次 Git 失败，把所有命令参数、凭据响应或文件正文写入日志。

### 双端使用一个日志与诊断入口

两端的用户入口都是“设置 → 工具 → 日志与诊断”。macOS 保留原来的 `Diagnostics`
导航身份，Windows 保留 `logs`，只统一展示名称和搜索词；通用设置不再重复放日志。
页面顺序统一为时间线、详细诊断、日志位置、保留与清理、诊断包。现有应用菜单的
导出按钮继续作为快捷入口，不成为另一套导出流程。

用户选择模块后开启详细诊断，复现问题，再预览并导出。诊断状态显示实际启用的
模块，改变查看筛选条件不会暗中重启或改名诊断会话；十五分钟到期由平台执行，
页面说明刷新可读取当前状态。预览固定点击时的筛选条件，并在确认中展示模块、
会话和最低级别。页面最多显示最近 2000 行及 200000 个字符，省略时明确提示。

清理影响有效目录中所有模块和会话的托管文件，不受查看筛选限制；确认文案必须
明确这点。目录切换成功后才保存 macOS 偏好，切换与清理后刷新时间线。失败保持
可重试状态，不让过期结果覆盖新筛选条件，也不让按钮一直停留在忙碌状态。
共享界面验收数据见 `shared/fixtures/diagnostics/logging-ui-v1.json`。

### 先脱敏，再序列化

结构化对象逐层清理凭据、源码内容、缓冲区、历史和环境字段，再转换成字符串。
自由文本和旧版转义 JSON 仍经过共享规则二次清理；字符串、数组、层级及单行都有
明确上限。导出前再次脱敏，防止旧版日志混入原始凭据。

### 控制生命周期和磁盘占用

两端单文件轮转阈值为 10 MiB，全局预算为 100 MiB，性能预算为 20 MiB，日志保留
30 天。macOS 在轮转及周期维护时检查容量；Windows 每累计写入 1 MiB 检查全局预算，
因此维护前可有短暂超额。活动文件不参与清理。文件大小从文件系统读取，不能复用
Foundation URL 对活动文件首次查询时缓存的大小。

普通日志记录关键阶段及告警、错误；详细诊断只覆盖选定模块，并在 15 分钟后关闭。
队列满时记录省略数量，不能改成调用线程等待磁盘。双端合并相邻重复记录，保留首次、最近发生时间及次数；
刷新、导出或正常退出前发布聚合结果。没有把原生崩溃机制扩展成新的崩溃采集器。

用户选定的日志根目录与发行身份一同决定数据归属。有效目录失败时回退到平台默认
目录；查看和导出读取有效目录，不另行推导默认文件。收集和删除必须严格识别本模块
生成的完整文件名，不能把自定义目录里所有 `lithe.*.log` 都当作可清理文件。旧版平铺日志可通过全部会话
选择读取。所有文件都属于用户运行状态，不进入签名包，不影响 Sparkle 增量更新。
资源清单的 `application-log-state` 禁止跨工作树复制日志与导出暂存目录。

### 让确认对应最终内容

每次收集读取有上限的文件尾部，丢弃首条不完整记录；单文件最多读取 2 MiB，日志
总输入最多 10 MiB。先选择模块和会话，再应用 200 文件上限；超过上限也要报告截断。
模块文件可合并为时间线，选择条件同时用于预览和导出。时间比较使用解析后的时间值，
避免小数精度或等价时区写法改变筛选结果。
诊断包的 `collection-status.txt` 记录截断、丢弃和写入失败，不能把不完整证据表示为完整。

macOS 复用原有缓存暂存目录与代际检查，取消或过期结果清理自己的目录。
Windows 预览只保存已经脱敏的内存快照，最多四份、五分钟有效，导出一次性消费编号；
取消显式释放，过期或超出容量时释放旧快照。导出先写目标旁的临时 ZIP，成功后原子
发布，失败删除暂存文件，避免破坏已有目标。预览后源日志发生变化不影响已确认内容。

## 考虑过的备选方案

- 只拆文件：无法关联跨模块操作，也不能解决漏收、过载或脱敏不一致。
- 每个类或插件各自实现 writer：会重复维护线程、限额与隐私规则，文件数量也会失控。
- 把原生文件系统实现全部放进 Rust Core：违反平台边界；跨平台需要共享语义，不需要
  把原生存储生命周期变成纯计算核心的责任。
- 导出确认后重新读取：可能导出未预览的数据，因此保存已经确认的脱敏快照。

## 后果

收益是双端可使用同一套筛选与诊断步骤，语言服务和正式版编辑器错误进入收集链路，
目录切换、容量和隐私规则有回归测试。代价是平台仍分别维护文件适配器，旧文本日志
缺少新关联字段；窗口和操作身份只能由实际拥有该上下文的入口提供，不能推测。

## 验证

- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-rust-core-comments.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-agent-notes.sh`
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'MacApplicationLogWriterTests|DiagnosticsExportServiceTests|StableRollbackTests'`
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope WindowsRust`
- `node scripts/test-reuse-worktree-resources.mjs`
- `./scripts/test-macos.sh --filter DiagnosticsWorkflowTests`
- `./scripts/probe-macos-logging-ui.sh --skip-build`

本地原生截图通过临时宿主加载产品字符串表。SwiftPM 默认 runner 不包含产品翻译，
不能把它输出的英文截图当成中文渲染证据。探针只复制当前 Xcode 的 runner 和构建时
编译的翻译表到临时 app，使用原测试、真实控件和桌面隔离；退出时删除临时 app。
截图在 `.artifacts/test-stability/`，不进入安装包，不参与代码签名或增量更新基线，
且与一次源版本、工具链、语言和外观绑定，禁止跨工作树复用。

## 适用范围

- `rust/lithe-core/src/diagnostics/`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/diagnostics/logging-v1.json`
- `macos/Sources/Lithe/Platform/MacOS/Logging/`
- `macos/Sources/Lithe/Services/Diagnostics/`
- `macos/Sources/Lithe/Views/Diagnostics/`
- `windows/tauri/src-tauri/src/logging.rs`
- `windows/tauri/src-tauri/src/diagnostics.rs`
- `windows/tauri/src/features/settings/components/log-settings-panel.tsx`
- `scripts/worktree-resources.json`
