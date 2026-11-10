# Agent 笔记：Viva 客户端的 Agent Markdown 回复与 AI 设置分组

状态：已实现

## 先说结论

Viva 客户端的 Agent 回复改用 Viva 自己的 Markdown 视图渲染，而不是 Core 返回的 HTML；因此支持的语法比旧客户端少，HTML、图片、数学公式和 Mermaid 不会显示。设置窗口的 AI 分组沿用 macOS 的归属规则，按“Agents → 指令 → 技能 → Hooks → MCP 配置 → IDE 连接”排列，新增 AI 相关页面只加进 `pageAI` 分组，不新增一级入口。已归档对话的搜索、服务商筛选和“从列表移除”都是本地呈现，Lithe 不读取也不改写 Agent 自己的记录。

## 问题

旧 macOS 和 Windows 客户端的 Agent 回复都用共享的 Markdown 渲染链路（Core `markdown.render` 产出 HTML，再由平台 WebView 显示）。Viva 桌面客户端没有 HTML 渲染器，也没有 WebView 控件。第一轮迁移把回复退成纯文本，代码块、列表和标题都看不出来，长回复难以阅读。

设置窗口在 Viva 里由 `desktop/internal/settingswindow` 重新实现。旧 macOS 的七组侧栏规则（见 [macOS 设置分类归属规则](2026-10-15-macos-settings-hierarchy.md)）仍是目标，但 Viva 页面和分组表是另一份代码。如果不把 AI 页面的归属写清楚，后续页面（例如 IDE 连接）会被放到顶层或“工具”组，侧栏顺序与旧客户端不一致。

已归档对话的列表、恢复和移除都是 Agent 的状态。旧客户端的“Removed conversations”只隐藏本地列表，不删除 Agent 记录。Viva 若把“移除”实现成调用 Agent 删除，会破坏用户无法从 IDE 恢复的数据。

## 决策

### Agent 回复用 Viva Markdown 视图

- 回复文本由 `components.MarkdownView` 解析并绘制，代码在 `desktop/internal/workbench/agent_markdown.go`。解析结果和布局宽度按消息缓存，流式回复只在文本增长时重新解析。
- 支持的语法以 Viva 解析器为准：标题、列表、引用、围栏代码、表格和 `http`/`https`/`mailto` 链接；不支持 HTML、图片、数学公式、Mermaid 和脚注。
- 无障碍缺口记录在代码注释：Viva 的 Markdown 视图不产出可读的无障碍节点，读屏器暂时读不到回复内容，等 Viva 上游 (#200–#204) 补齐后再补。
- 工具窗口里的 Markdown 预览使用同一套 Viva 视图，见 `desktop/internal/workbench/markdown_preview.go`；两处都不引入 HTML 渲染或第二套 Markdown 解析器。

### AI 设置分组

- 分组与顺序只在 `desktop/internal/settingswindow/model.go` 的 `parents` 表声明一次。AI 组当前包含：AI（服务商与提交/行内编辑生成选项）、Agents、指令、技能、Hooks、MCP 配置，IDE 连接页接在 MCP 之后。
- 新增 AI 页面时改三处并保持顺序一致：`pageID` 常量、`parents` 表、`titleOf` 与 `content` 的页面分支；侧栏、面包屑和搜索都从这张表推导。
- 页面内的说明放进信息提示（`w.card` 的 help），不平铺说明段落；界面文案必须走 `shared/i18n` 的 `desktop.*` 词条，中英齐全。
- 技能页按“全局/项目”分组显示，支持搜索、查看 SKILL.md 和原生目录导入；Hooks 页的搜索只过滤本地列表，删除必须在页面内确认后才写 Agent 配置。

### 已归档对话的本地视图

- 搜索按标题、session id 和服务商做本地匹配；服务商筛选的选项来自当前归档列表（含未知服务商），不读设置里的服务商目录。
- “从列表移除”只把 session id 写进本地 `agent-archive-hidden.json`（按项目根目录分组），不向 Agent 发送任何命令；“恢复到列表”只删除该 id。归档列表仍由 Agent 的 `listArchivedSessions` 提供，隐藏状态不会让 Agent 认为会话已删除。
- 恢复归档（`unarchiveSession`）仍需要用户确认，成功后同步清掉本地隐藏标记。

## 考虑过的备选方案

- **在 Viva 里内嵌 WebView 渲染 Core 的 HTML**：Viva 没有 WebView 控件，自己引入会带来第二条渲染栈和跨平台 WebView2/WKWebView 生命周期，超出这次迁移的范围，也违反“复用成熟上游能力”的前提。
- **继续用纯文本显示回复**：实现成本最低，但代码块、表格和列表的结构全部丢失，长回复不可读，无法作为可替换旧客户端的基线。
- **在 Go 里再写一份 Markdown 解析器**：与 Viva 自带的 `markdown` 包重复，后续两套解析行为会漂移，维护成本高于接受 Viva 的语法范围。
- **把 IDE 连接页放到顶层或“工具”组**：与 macOS 规则冲突，侧栏会出现两个入口表达同一能力；AI 分组已经承载 MCP，连接 IDE 的 MCP 服务属于同一领域。
- **把归档移除实现成 Agent 删除会话**：无法在 IDE 内恢复，且删除属于不可逆破坏，超出“本地列表管理”的语义。

## 后果

- 回复排版与旧客户端不再逐字节一致：HTML、图片、数学和 Mermaid 缺失，需要在功能矩阵里保持“部分实现”，不能宣称完全对齐。
- 回复视图的测量走自定义布局，滚动长对话时只重排可见行；解析和布局都缓存在消息上，但一次超长回复首次打开仍有解析成本。
- AI 页面的顺序由一张表控制，新增页面忘记改表时，侧栏/面包屑/搜索会不一致；`settingswindow` 的页面表测试会失败，而不是静默错位。
- 归档列表的隐藏集合是 Lithe 自己的偏好，删除 `agent-archive-hidden.json` 只会让隐藏项重新出现，不触碰 Agent 数据。

## 验证

- 回复渲染：`cd desktop && ../scripts/desktop/desktop-go.sh test -race ./internal/workbench/ -run 'Agent'`；覆盖流式回复解析、Markdown 布局与工具窗口预览。
- 设置分组与技能/Hooks 页面：`cd desktop && ../scripts/desktop/desktop-go.sh test -race ./internal/settingswindow/`。
- 文案：`node scripts/i18n/generate-i18n.mjs --check`、`node scripts/i18n/verify-app-language-localization.mjs`、`node --test --test-timeout=60000 scripts/i18n/test-i18n.mjs`。
- 归档本地移除：`TestAgentArchiveRowsFilterBySearchProviderAndLocalRemoval` 与 `TestAgentArchiveLocalRemovalPersistsPerProject` 覆盖搜索、服务商、未知服务商、隐藏与持久化。
- 原生窗口验收仍待做：回复里的链接、代码块滚动、长对话性能和读屏器行为需要在 macOS/Windows 真机确认。

## 适用范围

适用于 Viva 桌面客户端（`desktop/`）的 Agent 对话呈现、设置窗口 AI 分组与已归档对话列表。旧 SwiftUI/Tauri 客户端的 Markdown 与历史实现不在本文范围；迁移完成前仍以各自代码为准。
