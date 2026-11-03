# Agent 笔记：结构化日志宿主接入与独立窗口

状态：提议中

## 先说结论

PR1 只提供规则和生成类型；生产日志仍通过现有链路写入。后续分三阶段把 macOS 写入器、引擎日志与插件、应用级日志窗口接到同一份会话证据上。这里的方案和验收要求没有落地，不能据此声称漏收、性能或查看体验已经改善。

## 问题

纯计算能力不会自动接管系统日志、引擎 stderr（标准错误输出）或 LSP（语言服务器协议）消息。旧 writer 逐事件跨语言调用，两个查看界面还分别依赖磁盘和内存；只增加格式契约不能解决这些运行时问题。

## 提案

已落地规则见 [结构化日志通道与事件目录](../../implemented/architecture/2026-11-03-structured-logging-channels.md)。下面按实施阶段划分责任，阶段编号用于说明依赖，不作为完成标记。

### PR2：macOS 写入器和调用点

用 `MacLogStore` 承接类型化输入，在入队前读取级别与详细诊断通道快照，尽早排除不需要的 DEBUG。队列有上限，为 WARN/ERROR 预留容量，满载时累计丢弃数量，不退回调用线程写盘。每 100 ms 或 256 条批量交给 Core 编码；同时连接目录字段校验和共享脱敏，不在 Swift 重写格式或隐私策略。

文件句柄缓存最多 32 个，以最近使用次序淘汰；重复合并使用事件身份和字段，不逐条 JSON 序列化判重。正常刷新、导出和退出发布聚合结果；超时任务必须有取消或代际保护，不能超时后继续修改状态。保留最近已编码记录供跟随订阅，内存有界。

迁移现有字符串 record、NSLog、直接 stderr 及现有专用诊断闭包到生成事件，保留机器协议消费者需要的语义，同步削减基线。旧字符串 API 在其调用方全部迁移后删除。先完成字段类型、脱敏和队列边界，再把生产日志切到会话目录。

### PR3：引擎身份、上游诊断与插件目录

引擎事件携带插件身份、角色和 Core 决定的通道，宿主不再把所有引擎拼成 language scope。按行处理 stderr，单行最多 4 KiB，每引擎会话每秒最多 200 行，超额汇总为丢弃记录。接入 window/logMessage 与 window/showMessage；协议跟踪只在所选通道的详细诊断中开启，并经过限长与脱敏。Core 的直接打印通过运行时事件流交给宿主，不能另开文件 writer。

`${logDir}` 是提供给插件的启动变量，指向当前会话 `plugins/<id>/files/`。宿主在启动前创建可写目录，插件可以把无法接入结构化事件的原生日志写到这里；宿主观察到的生命周期和 stderr 继续写 `plugins/<id>/host.log`。正确做法是传入宿主管理的 files 目录；不要从插件安装位置推导可写日志目录，或让每插件另建宿主日志队列。

PR1 只有 `plugin_files_path` 和保留规则，尚无启动变量与契约接入。PR3 必须一起修改插件契约，在 lithe-plugin-docs 验证 Node 和 Java 两个 SDK 的示例后端；合并后按仓库约定同步 lithe-plugin-docs。插件文件内容不是 v2 记录，不假装完成解析或等同于已脱敏事件；预览和导出仍要执行既有隐私边界。会话期间超额告警去重，启动时按 Core 计划清理非活动会话文件。

### PR4：一个应用级日志窗口与导出

日志窗口属于应用，所有项目共用一个功能模型。工具栏齿轮菜单的“日志…”（位于“插件…”与“主题…”之间，前后各一条分隔线）、应用菜单、默认 ⌥⌘L 的可改键命令、语言服务“查看日志”和设置按钮发出同一个打开请求，可携带定位通道；删除旧语言服务编辑器标签及独立的 100 条内存日志。

窗口提供会话（含只读旧版日志）、通道树、级别、本地时间预设与日期选择、搜索与字段筛选、操作关联和跟随。原生表格只呈现可见行，详情能定位字段与文件位置；跟随消费 writer 已编码广播，历史查询与合并使用 Core，不能滚动一次就重新读全量日志。插件 files 节点仅展示受限只读尾部，不用 v2 解析器解释任意文本。

设置页保留打开窗口、详细诊断、目录、占用和清理、诊断包。预览和导出按会话收集，继续冻结确认时的脱敏内容，并在 collection-status.txt 报告截断、丢弃和失败。界面文案走共享 i18n。Windows 继续使用 v1，实现与验证状态分别登记，不因 Core 支持 v2 就标为已迁移。

## 考虑过的备选方案

- 保留编辑器标签页和设置时间线两套浏览：来源和生命周期继续不同，无法回答“导出的是否就是看到的”。
- 每事件单独调用 Core、每次打开文件：实现简单，但保留现有高频边界成本；选择有界批量和句柄缓存。
- 每插件实现自己的宿主 writer：会分裂队列、脱敏和预算；只允许插件原生文件使用宿主管理的 files 区。
- 一次迁移两端：扩大验证范围并阻塞 macOS，选择保留 v1 兼容后再单独迁移 Windows。

## 验收标准

- PR2：真实调用经过目录校验、共享脱敏与编码后进入会话文件；有界队列、丢弃汇总、轮转和句柄释放可验证；基线对应减少，超时任务不继续改状态；对比批量前后的跨语言调用次数和写盘开销。
- PR3：真实语言服务的 logMessage 和按行 stderr 可定位到正确身份；Core 事件到达宿主；插件获得会话 files 路径且安装目录不变；限流、告警去重和契约同步有证据。
- PR4：真实 Java 项目和失败的 Git fetch 可从同一窗口定位、筛选、跟随和关联操作；导出等于已确认快照，不完整证据有明确状态；验证中英文、深浅色与长列表滚动，结束后清理本次应用及辅助进程。
- 每阶段验证 v1 兼容和 Windows Rust 调用点，运行相关边界检查；更新平台能力矩阵，未做目标平台运行验证时保持 pending。落地后把对应决策迁入 implemented，不在已实现 Note 中保留待办。

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
