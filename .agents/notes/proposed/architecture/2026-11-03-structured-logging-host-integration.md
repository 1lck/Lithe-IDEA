# Agent 笔记：结构化日志宿主接入与独立窗口

状态：提议中

## 先说结论

macOS 写入器、引擎日志与插件启动接线已通过 PR2/PR3 接入 v2，决策见已实现 Note。PR3 阶段 C 已明确 Core 生命周期扩展原有 stateChanged 而不新增 v1 行、宿主源头阶段事件和 Core 计算段的边界，见已实现 Note。这里仅保留应用级日志窗口与导出的后续方案，不能据此声称整机漏收、性能或查看体验已验收。

## 问题

纯计算能力不会自动接管系统日志、引擎 stderr（标准错误输出）或 LSP（语言服务器协议）消息。旧 writer 逐事件跨语言调用，两个查看界面还分别依赖磁盘和内存；只增加格式契约不能解决这些运行时问题。

## 提案

已落地规则见 [结构化日志通道与事件目录](../../implemented/architecture/2026-11-03-structured-logging-channels.md)。下面按实施阶段划分责任，阶段编号用于说明依赖，不作为完成标记。

### PR4：一个应用级日志窗口与导出

日志窗口属于应用，所有项目共用一个功能模型。工具栏齿轮菜单的“日志…”（位于“插件…”与“主题…”之间，前后各一条分隔线）、应用菜单、默认 ⌥⌘L 的可改键命令、语言服务“查看日志”和设置按钮发出同一个打开请求，可携带定位通道；删除旧语言服务编辑器标签及独立的 100 条内存日志。

窗口提供 v2 会话、通道树、级别、本地时间预设与日期选择、搜索与字段筛选、操作关联和跟随。原生表格只呈现可见行，详情能定位字段与文件位置；跟随消费 writer 已编码广播，历史查询与合并使用 Core，不能滚动一次就重新读全量日志。插件 files 节点仅展示受限只读尾部，不用 v2 解析器解释任意文本。

设置页保留打开窗口、详细诊断、目录、占用和清理、诊断包。预览和导出按会话收集，继续冻结确认时的脱敏内容，并在 collection-status.txt 报告截断、丢弃和失败。界面文案走共享 i18n。Windows 继续使用 v1，实现与验证状态分别登记，不因 Core 支持 v2 就标为已迁移。

## 考虑过的备选方案

- 保留编辑器标签页和设置时间线两套浏览：来源和生命周期继续不同，无法回答“导出的是否就是看到的”。
- 每事件单独调用 Core、每次打开文件：实现简单，但保留现有高频边界成本；选择有界批量和句柄缓存。
- 每插件实现自己的宿主 writer：会分裂队列、脱敏和预算；只允许插件原生文件使用宿主管理的 files 区。
- 一次迁移两端：扩大验证范围并阻塞 macOS，选择保留 v1 兼容后再单独迁移 Windows。

## 验收标准

- PR4：真实 Java 项目和失败的 Git fetch 可从同一窗口定位、筛选、跟随和关联操作；导出等于已确认快照，不完整证据有明确状态；验证中英文、深浅色与长列表滚动，结束后清理本次应用及辅助进程。
- 每阶段验证 Windows 的 Rust v1 API 兼容、macOS 不显示和导出 v1 且旧文件按龄清理，以及 Windows Rust 调用点，运行相关边界检查；更新平台能力矩阵，未做目标平台运行验证时保持 pending。落地后把对应决策迁入 implemented，不在已实现 Note 中保留待办。

## 风险

批量与句柄缓存引入退出刷新、取消和资源清理责任，不能只验证正常路径。插件原生文件是独立隐私边界，宿主必须限制读取与导出；当前会话保护可能使磁盘预算暂时无法满足。新日志规范先于全面迁移生效，存量基线必须持续减少，不能成为新增绕过点的入口。

## 验证

实现阶段采用以下已有入口，并补充对应真实工作流证据；本提案不声称这些验收已通过：

- `node scripts/logging/generate-log-events.mjs --check`
- `node scripts/logging/verify-log-usage.mjs`
- `./scripts/macos/test/test-macos.sh --filter DiagnosticsWorkflowTests`
- `./scripts/macos/probe/probe-macos-logging-ui.sh --skip-build`
- `./scripts/architecture/verify-service-boundaries.sh`
- `./scripts/architecture/verify-shared-contracts.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/windows/verify/verify-windows-boundaries.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`

现有 UI 探针需随窗口实现调整，不能把旧设置页截图当成新窗口证据。

## 适用范围

- `macos/Sources/LitheModuleAPI/Logging/`
- `macos/Sources/Lithe/Platform/MacOS/Logging/`
- `macos/Sources/Lithe/Services/Diagnostics/`
- `macos/Sources/Lithe/Views/Diagnostics/`
- `rust/lithe-core/src/lsp/interface/engine.rs`
- `rust/lithe-core/src/plugins/declarative.rs`
- `shared/contracts/plugins/v1/`
