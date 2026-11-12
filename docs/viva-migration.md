# Viva 迁移清单（冻结）

本文冻结 #1794 / #1799 的迁移范围，来源与口径如下。状态只记事实，查不到的写“未找到”。

- 基线：分支分叉点 `5a54c41`（`origin/preview` 与本分支的 merge-base）上的功能矩阵，250 项；本分支新增 4 项（`agent-minimal-conversation`、`editor-line-operations`、`runtime-package-integrity`、`viva-debug-session`），合计 254 项，基线列写“本分支新增”。
- Viva 现状：以本分支 `shared/platform-feature-matrix/features/*.json` 与 `desktop/internal/` 实际代码为准。JSON 仍为 unassessed 但 desktop/ 里确有实现的行，按代码改判为“部分”，依据写在说明列；JSON 为 unassessed 且 desktop/ 里没有对应代码的，记“未开始”。
- 缺口编号 C01–C12 取自 PR #1799 描述“当前源码差异”一节：C01 插件后端反向宿主调用；C02 Java LSP/TCP Debug；C03 编辑器剩余语言操作；C04 项目生成器；C05 插件工具窗口/页面；C06 SVN、快捷键导入、Go/PHP/Lua 执行入口；C07 设置占位页与构建配置控件；C08 Git Log 四个占位操作；C09 Maven/Gradle 配置贡献；C10 Java 插件内部尾项；C11 插件跨平台打包；C12 能力准入与 Core pin。

## 分类规则

| 分类 | 规则 |
| --- | --- |
| 必须迁移 | preview 基线里任一端为 implemented/partial、且属于日常 IDE 工作流的用户能力；本分支新增行也归此类 |
| 平台专属 | 只在一端存在且依赖系统特性（WSL、Windows 窗口标题/任务栏、macOS 输入法/登录 shell 环境等），在对应平台保留 |
| 插件提供 | 能力归属插件（Java/Maven/Gradle/Go/PHP/Docker/数据库/SVN 等工具知识），宿主只提供扩展点；说明列写依赖的扩展点 |
| 不纳入 | 两端基线都是 missing |
| 放弃 | 旧客户端有、但不值得迁移（被新设计取代的过渡实现、Monaco 或旧控件专属实现）；逐条理由见下文“放弃” |

## 汇总

| 分类 | 数量 |
| --- | --- |
| 必须迁移 | 153 |
| 插件提供 | 34 |
| 平台专属 | 11 |
| 放弃 | 54 |
| 不纳入 | 2 |
| 合计 | 254 |

必须迁移 152 项的 Viva 现状：

| 现状 | 数量 |
| --- | --- |
| 完成 | 42 |
| 部分 | 106 |
| 未开始 | 5 |

2026-11-12 起 Agent 对话整体放弃，原先唯一“完成”的 `agent-minimal-conversation` 随之移入“放弃”。

2026-11-12 按功能矩阵 JSON 与代码重新核对一遍现状列：“完成”是两端（平台专属行只看对应平台）在 JSON 里都为 implemented，即代码已接通，原生窗口验收仍为 pending；“部分”含 JSON 为 partial 的行与按代码改判的行；说明列原写“无 desktop/ 证据”的行改写为主要实现文件，具体缺口见对应 JSON 的 notes。仍未开始的 5 项：远程开发两项、构建 Provider 原生配置与只读模型输入，以及依赖 webview、按用户决定暂缓的 `embedded-viewers`。

## 主表（254 项，按 area 分组）

列说明：基线为 5a54c41 上 macOS/Windows 的实现状态（实现/部分/缺/专属/插件/未盘）；Viva 现状为完成（代码接通、验收 pending）/部分/未开始，“—”表示该分类不迁移。

### AI（47）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `ai-chat-history` | 对话历史、置顶与归档 | 放弃 | 缺/实现 | — | 见“放弃”表 |
| `ai-chat-providers` | 多 Provider 与工作区范围 | 放弃 | 缺/实现 | — | 见“放弃”表 |
| `ai-chat-session` | 对话会话与流式响应 | 放弃 | 缺/实现 | — | 见“放弃”表 |
| `ai-commit-generation` | Provider 配置与提交信息生成 | 必须迁移 | 实现/实现 | 部分 | `workbench/aicommit.go` |
| `agent-acp-conversation` | 可选 ACP Agent 对话 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-approval-mode-presentation` | Agent 权限模式呈现 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-archived-conversation-history` | 当前工作区的 Codex 归档历史 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-chat-editor-placement` | 在编辑区标签页与 AI 工具窗口之间移动对话（按钮、右键菜单或把 A… | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-claude-api-key-authentication` | Claude API Key 鉴权 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-claude-desktop-mechanisms` | 在 Lithe 中打开 Claude Desktop 开始的 Cla… | 放弃 | 实现/部分 | — | 见“放弃”表 |
| `agent-claude-subscription` | Claude 供应商可选官方订阅 | 放弃 | 实现/部分 | — | 见“放弃”表 |
| `agent-codex-subscription` | Codex 供应商选择官方订阅 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-connection-model-switching` | Agent 与模型切换 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-context-limits` | Agent 上下文长度与自动压缩阈值 | 放弃 | 实现/部分 | — | 见“放弃”表 |
| `agent-context-usage` | Agent 上下文用量与会话详情共用发送旁单一入口（未上报显示信息图… | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-conversation-history` | CC GUI 风格历史页 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-entry-discoverability` | 新安装及模块关闭时仍显示 Agent 侧栏入口，打开项目不自动恢复 … | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-file-context-actions` | 从编辑器文件标签或项目树右键把文件添加到当前或指定 Agent 会话… | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-file-references` | 从 Finder 或项目树拖入文件、⌘V 粘贴 Finder 文件或… | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-global-instructions` | 全局指令卡片 | 放弃 | 实现/部分 | — | 见“放弃”表 |
| `agent-hooks` | Hook 资源库 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-management` | Agent 管理 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-mid-turn-steering` | 回复过程中发送补充指令 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-minimal-conversation` | Agent 最小会话纵向切片 | 放弃 | 本分支新增 | — | 见“放弃”表 |
| `agent-mode-sync` | Agent 自行切换模式时同步权限选择器 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-model-call-statistics` | Agent 发送旁单一入口按需展开的上下文与会话详情（有用量显示圆环… | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-opened-workspace-context` | 当前打开项目的明确上下文 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-plan-display` | 任务以紧凑状态行显示 Agent 上报计划（ACP plan）的已完… | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-provider-configuration` | Agent 供应商管理 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-reasoning-display` | 每轮思考、过程说明和工具调用合成一个默认折叠的过程入口，流式时也由用… | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-reply-markdown` | Agent 回复的 Markdown 渲染 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-skill-management` | 技能设置 | 放弃 | 实现/部分 | — | 见“放弃”表 |
| `agent-slash-commands` | 输入框以 / 开头（或以 $ 开头选择 Skill）时，按 Agen… | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-subagent-monitoring` | 原生子代理监视 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-subscription-multi-account` | Claude 与 Codex 官方订阅支持多个账号 | 放弃 | 实现/部分 | — | 见“放弃”表 |
| `agent-subscription-quota` | Codex 订阅额度 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-thinking-level-labels` | Agent 思考强度英文呈现 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-tool-activity-timeline` | 每轮工具调用与思考、过程说明放进同一个默认折叠的过程区 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-toolbar-brand-marks` | Agent 品牌标志 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `agent-turn-statistics` | 发送后实时计时；每轮回复下方固定显示复制回复、用量胶囊（耗时 · t… | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `ide-api-environment` | 插件与 MCP 查询和修改项目 Java/Maven 默认环境，并返… | 必须迁移 | 实现/实现 | 部分 | `workbench/ide_api_dispatch.go` |
| `ide-api-maven` | 插件与 MCP 按已接通工作流发现工具 | 必须迁移 | 实现/实现 | 部分 | `workbench/ide_api_dispatch.go` |
| `ide-api-run-output` | 插件与 MCP 列举运行配置、启动重启，按执行 ID 查询和停止 R… | 必须迁移 | 实现/实现 | 完成 | `workbench/ide_api_dispatch.go` |
| `ide-mcp-connection` | 从设置侧栏独立的 MCP 配置页按项目开启连接，分别授权配置与执行，… | 必须迁移 | 实现/实现 | 部分 | `workbench/ide_api.go` |
| `mcp-registry-discovery` | 同页上方管理服务器资源库，下方默认显示离线可用的内置精选 | 放弃 | 实现/缺 | — | 见“放弃”表 |
| `mcp-server-library` | 在设置页统一发现、合并、编辑并删除 Codex 与 Claude C… | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `ai-inline-edit` | AI 行内编辑 | 必须迁移 | 专属/实现 | 部分 | `workbench/inlineedit.go` |

### Java（19）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `java-gradle-project-import` | 在 Gradle 工作区显式声明 Buildship 导入开关，并把… | 插件提供 | 插件/实现 | 未开始 | C09 扩展点：buildSystems/buildProviders、languageImport.settings(pluginFunctions)；无 desktop/ 证据 |
| `java-build-diagnostics` | 构建输出与编译诊断 | 插件提供 | 实现/实现 | 未开始 | 扩展点：buildProviders、Problems 诊断；无 desktop/ 证据 |
| `java-maven-profiles-dependencies` | Profile 与 Provider 依赖树 | 插件提供 | 插件/实现 | 未开始 | 扩展点：buildProviders、declarative ui；无 desktop/ 证据 |
| `java-maven-project` | 项目根、模块与源码集识别 | 插件提供 | 插件/实现 | 未开始 | 扩展点：buildSystems/buildProviders；无 desktop/ 证据 |
| `java-maven-project-settings` | 项目与子项目工具链使用 canonical Run local.js… | 插件提供 | 插件/实现 | 未开始 | 扩展点：settings2、toolchains；无 desktop/ 证据 |
| `java-maven-settings-reach-jdt` | Maven 设置与重新加载实时作用于 Java 语言服务，并展示依赖… | 插件提供 | 插件/实现 | 未开始 | C09 扩展点：languageImport.settings、pluginFunctions；无 desktop/ 证据 |
| `java-maven-toolbar-tooltips` | Maven 工具栏提示 | 插件提供 | 部分/实现 | 未开始 | 扩展点：declarative ui(工具栏)；无 desktop/ 证据 |
| `java-runtime-discovery` | JDK、Maven / mvnd 工具链发现、安装设置同步及按项目要… | 插件提供 | 插件/实现 | 未开始 | 扩展点：toolDefinitions/toolchains；无 desktop/ 证据 |
| `maven-user-settings-editing` | Maven 设置页在没有打开项目时也能编辑用户级 ~/.m2/set… | 插件提供 | 缺/实现 | 未开始 | 扩展点：settings2、文件编辑 API；无 desktop/ 证据 |
| `mybatis-navigation` | MyBatis Mapper/XML 导航 | 插件提供 | 插件/实现 | 未开始 | 扩展点：editor providers、virtual source；无 desktop/ 证据 |
| `spring-endpoints-search` | Spring HTTP 接口筛选与源码跳转 | 插件提供 | 插件/实现 | 未开始 | 扩展点：pluginFunctions、搜索结果贡献；无 desktop/ 证据 |
| `spring-index` | Spring 配置、Bean 与 Endpoint 索引 | 插件提供 | 插件/实现 | 未开始 | 扩展点：pluginFunctions、backend；无 desktop/ 证据 |
| `spring-navigation` | Spring 符号导航与代码关联 | 插件提供 | 实现/实现 | 未开始 | 扩展点：editor providers；无 desktop/ 证据 |
| `java-import-on-open-policy` | 设置“打开 Java 项目时导入” | 插件提供 | 缺/实现 | 未开始 | 扩展点：settings2、backend 激活；无 desktop/ 证据 |
| `java-import-progress-feedback` | 状态栏显示 Java 导入百分比、细进度条、当前模块与正在下载的依赖… | 插件提供 | 缺/实现 | 未开始 | 扩展点：进度/状态栏贡献；无 desktop/ 证据 |
| `lsp-completion-hover` | 补全与 Hover | 必须迁移 | 实现/实现 | 部分 | C03 |
| `lsp-diagnostics` | 诊断与编译错误定位 | 必须迁移 | 实现/实现 | 部分 | — |
| `lsp-lifecycle` | 语言服务器启动与工作区准备 | 必须迁移 | 实现/实现 | 部分 | C02 |
| `lsp-navigation-edits` | 跳转、引用、语义标记与编辑 | 必须迁移 | 实现/实现 | 部分 | C03 |

### Run/Debug（2）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `java-service-devtools-update` | 运行中的 Spring Boot DevTools 服务手动保存并编… | 插件提供 | 实现/实现 | 未开始 | 扩展点：run/start 后端调用、运行动作；无 desktop/ 证据 |
| `java-service-hot-code-replace` | 本地 Java Debug 服务手动编译并热替换代码 | 插件提供 | 实现/实现 | 未开始 | 扩展点：debug 动作、后端调用；无 desktop/ 证据 |

### Windows 专属（2）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `wsl-boundaries` | 跨 WSL 边界移动与重命名 | 平台专属 | 专属/实现 | 未开始 | Windows 专属：WSL 边界移动 |
| `wsl-paths` | WSL 文件与工作区路径 | 平台专属 | 专属/实现 | 未开始 | Windows 专属：WSL 路径 |

### 协作（5）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `ai-pull-request-description` | AI 生成 Pull Request 标题与描述 | 必须迁移 | 实现/部分 | 完成 | `workbench/github_create.go` |
| `github-device-authorization` | GitHub 设备授权 | 必须迁移 | 实现/缺 | 完成 | `workbench/github_account.go` |
| `github-prs` | Pull Request 列表与详情 | 必须迁移 | 实现/部分 | 完成 | `workbench/github_prs.go` |
| `github-pull-request-checkout` | GitHub 拉取请求安全检出 | 必须迁移 | 实现/缺 | 完成 | `workbench/github_prs.go` |
| `github-reviews-comments` | Review 与评论 | 必须迁移 | 实现/实现 | 部分 | `workbench/github_checks.go` |

### 发行（1）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `runtime-package-integrity` | 运行时不改变已安装程序包，保持更新所需的文件基线 | 必须迁移 | 本分支新增 | 部分 | — |

### 发行与更新（2）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `updates-check-download` | 检查、下载与安装更新 | 必须迁移 | 实现/部分 | 部分 | C07 |
| `updates-failure-rollback` | 失败重试与回滚 | 必须迁移 | 部分/实现 | 部分 | C07 |

### 可观测性（4）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `diagnostics-export` | 类型化会话日志筛选、保留与快照诊断包导出 | 必须迁移 | 实现/缺 | 部分 | logwindow/export.go、logstore/ |
| `diagnostics-workspace` | 工作区诊断与问题面板 | 必须迁移 | 实现/实现 | 部分 | problems.go（诊断来自插件 LSP） |
| `memory-monitor` | 应用与语言服务内存监控 | 必须迁移 | 实现/实现 | 部分 | sysinfo/（仅系统信息；语言服务内存监控未找到） |
| `workbench-notifications` | 操作通知、错误提示与自动消失，重复消息合并计数 | 必须迁移 | 实现/实现 | 部分 | `workbench/notifications.go`：四种类型、重复计数、最多三条 toast、悬停暂停、通知历史与铃铛（含欢迎页）；后台暂停、“还有 N 条”、语言切换重排与 InlineBanner 未做 |

### 启动与窗口（1）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `onboarding-welcome` | 欢迎页、项目入口与首次启动引导 | 必须迁移 | 实现/实现 | 部分 | — |

### 工作区（15）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `windows-taskbar-project-titles` | Windows 任务栏与 Alt+Tab 显示项目展示名和活动文件，… | 平台专属 | 专属/实现 | 未开始 | Windows 任务栏标题 |
| `workspace-document-sync` | 脏状态、保存与外部修改 | 必须迁移 | 实现/实现 | 部分 | — |
| `workspace-files` | 文件树与文件操作 | 必须迁移 | 实现/实现 | 部分 | filetree.go、filetree_watch.go；创建/重命名/删除/批量操作未找到 |
| `workspace-indexing-exclusions` | 目录索引排除与 Git 自动排除 | 必须迁移 | 部分/部分 | 部分 | `core/workspace.go` |
| `workspace-open-switch` | 打开工作区与切换项目 | 必须迁移 | 实现/实现 | 部分 | — |
| `workspace-tabs-projects` | 多项目与多标签 | 必须迁移 | 实现/实现 | 部分 | editorgroups.go、tabstrip.go；仅单项目（workspace-open-switch） |
| `workspace-tree-batch-files` | 项目树独立多选、范围选择及批量拖动移动、复制、重复和移到废纸篓 | 必须迁移 | 实现/缺 | 部分 | `workbench/filetree_menu.go` |
| `remote-development-workspace` | 在 SSH 主机、容器和远程 Mac 上打开并开发项目 | 必须迁移 | 部分/缺 | 未开始 | 无 desktop/ 证据 |
| `remote-workspace` | 远程连接与远程路径工作区 | 必须迁移 | 部分/实现 | 未开始 | 无 desktop/ 证据 |
| `plugin-project-generators` | 新建项目窗口按 IDEA 的布局列出“新建项目”和“生成器”两组条目 | 必须迁移 | 实现/缺 | 部分 | C04 |
| `dependency-browser` | 项目依赖与模块浏览 | 必须迁移 | 实现/实现 | 部分 | — |
| `file-explorer` | 项目文件树与资源打开 | 必须迁移 | 实现/实现 | 部分 | — |
| `file-explorer-copy-path-for-terminal` | 把项目树中的文件或目录以路径形式送入集成终端（复制后粘贴，或直接拖拽） | 必须迁移 | 缺/实现 | 部分 | `workbench/filetree_menu.go` |
| `file-open-selected` | F4 打开焦点文件与搜索位置 | 必须迁移 | 缺/实现 | 部分 | `shortcuts/shortcuts.go`（可改绑）、`workbench/search_view.go`、`workbench/filetree_view.go`（树等 Lithe-IDEA/viva#9） |
| `file-open-with` | 项目文件通过系统打开方式选择外部应用 | 必须迁移 | 实现/缺 | 完成 | `workbench/filetree_open.go` |

### 工作台（30）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `macos-shared-tree-list-control` | macOS 原生树与列表使用完整公共入口，统一焦点、两侧留白、悬停、… | 必须迁移 | 实现/缺 | 部分 | — |
| `command-palette` | 命令面板与全局动作 | 必须迁移 | 实现/实现 | 完成 | `workbench/commands.go` |
| `windows-file-menu-settings` | Windows 文件菜单在“关闭标签页”上方提供带齿轮图标的“设置”… | 平台专属 | 专属/实现 | 未开始 | Windows 文件菜单 |
| `workbench-compact-menu-bar` | 紧凑菜单栏可在标题栏左侧原位展开完整水平菜单，并在点击外部或按 Es… | 平台专属 | 专属/实现 | 未开始 | Windows 紧凑菜单栏 |
| `workbench-panes` | 分栏、面板与工具窗布局 | 必须迁移 | 实现/实现 | 部分 | editorgroups.go、dockdrag.go |
| `workbench-settings-entry` | 从工作台 chrome 打开设置 | 必须迁移 | 实现/实现 | 部分 | chrome.go、settingswindow/ |
| `workbench-tool-window-docking` | 工具窗口拖动、分组、排序与布局恢复 | 必须迁移 | 实现/部分 | 部分 | catalog.go 六区停靠、dockdrag.go、workbench-layout-v2.json |
| `shared-action-button-style` | 普通文字动作按钮采用欢迎页完整几何与间距 | 必须迁移 | 实现/部分 | 部分 | sheet/、icons/（按钮几何未逐项核） |
| `workbench-islands-appearance` | IntelliJ Islands 外观 | 必须迁移 | 部分/实现 | 部分 | `workbench/theme.go` |
| `workbench-project-color-gradient` | 用颜色区分项目 | 必须迁移 | 部分/实现 | 部分 | `workbench/identity.go` |
| `workbench-activity-rail-window-edge` | 活动栏贴合窗口外沿 | 必须迁移 | 实现/实现 | 完成 | `workbench/chrome_view.go` |
| `workbench-activity-tooltips` | 活动栏图标的稳定悬停说明 | 必须迁移 | 实现/实现 | 完成 | `workbench/chrome_view.go` |
| `history-restore` | 恢复、删除与持久化 | 必须迁移 | 实现/实现 | 完成 | `workbench/local_history.go` |
| `history-snapshots` | 快照列表与 Diff | 必须迁移 | 实现/实现 | 部分 | `workbench/local_history.go`、`local_history_settings.go`、`settingswindow/local_history_view.go`（Diff 与设置已做；全项目时间线、手动标记条目未做） |
| `macos-shared-scrollbar-style` | macOS 共享滚动条样式 | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `macos-shared-selection-focus` | macOS 普通选中行主题与区域和窗口焦点 | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `window-controls` | 标题栏控制窗口最小化、最大化/还原与关闭 | 必须迁移 | 实现/实现 | 部分 | — |
| `window-title-active-file` | Windows 原生窗口标题显示「项目名 – 当前编辑文件」，编辑区… | 平台专属 | 专属/实现 | 未开始 | Windows 原生窗口标题 |
| `windows-startup-feedback` | Windows 启动和新窗口在页面渲染前就用当前主题背景色，不再闪白屏 | 平台专属 | 专属/实现 | 未开始 | Windows 启动防闪白 |
| `terminal-canvas-compositing` | macOS 终端 Metal 画布按预乘语义清屏 | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `terminal-copy-shortcut` | Windows 终端在有选中内容时用 Ctrl+C 复制，无选中时仍… | 平台专属 | 专属/实现 | 未开始 | Windows 终端 Ctrl+C 语义 |
| `terminal-extended-keyboard` | 终端向 TUI 程序传递带修饰键的按键（如 Shift+Enter … | 必须迁移 | 实现/实现 | 部分 | term/keyboard.go、win32input*.go |
| `terminal-interaction` | 复制粘贴、搜索、调整大小、终端 Control 输入与切换快捷键及 … | 必须迁移 | 实现/实现 | 完成 | term/、termview/（选择、搜索、键盘、鼠标）、workbench/fonts.go（终端 Nerd Font） |
| `terminal-long-command-input` | Windows Shell 超长命令输入 | 平台专属 | 专属/实现 | 未开始 | Windows Shell 长命令输入 |
| `terminal-native-palette` | macOS 终端 ANSI 配色逐项按与 Lithe 编辑器背景的 … | 必须迁移 | 实现/专属 | 完成 | `nativeterm/nativeterm.go` |
| `terminal-sessions` | 多会话与标签 | 必须迁移 | 实现/实现 | 部分 | — |
| `terminal-shell` | Shell 发现与终端配置(默认 Shell、回滚行数) | 必须迁移 | 实现/实现 | 完成 | terminal_shells.go、localshell/ |
| `project-file-type-icons` | 项目树、标签页和搜索结果为常见项目文件显示专用图标 | 必须迁移 | 实现/实现 | 完成 | fileicons/ |
| `project-sidebar-header-icons` | 项目侧边栏标题与项目树行块左缘对齐，只显示右侧 IDEA Commu… | 必须迁移 | 实现/专属 | 部分 | — |
| `project-sidebar-tree-disclosure-icons` | 项目树展开与折叠箭头使用 IDEA Community 明暗 SVG… | 放弃 | 实现/专属 | — | 见“放弃”表 |

### 扩展（21）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `build-model-project-presentation` | 搜索模块标签与编辑器测试源角色消费插件构建模型，按最深路径匹配并拒绝… | 必须迁移 | 实现/缺 | 部分 | — |
| `build-native-configuration` | Build Provider 协议 7 读取原生配置的实际来源、原值… | 必须迁移 | 实现/缺 | 未开始 | C07 |
| `build-provider-readonly-model-inputs` | 已启用的构建 Provider 可显式发布只读项目、目标和内容目录及… | 必须迁移 | 实现/缺 | 未开始 | — |
| `build-provider-refresh-and-tool` | 构建 Provider 请求区分首次加载与重新加载，并带上宿主解析好… | 必须迁移 | 实现/缺 | 完成 | — |
| `build-system-plugins` | 构建系统插件（API 3 buildSystems） | 必须迁移 | 部分/缺 | 部分 | — |
| `cargo-build-plugin` | Cargo 社区构建插件 | 插件提供 | 实现/缺 | 未开始 | C11,C12 扩展点：buildSystems/buildProviders；无 desktop/ 证据 |
| `declarative-plugin-contract` | 声明式插件契约 v1（插件不在宿主进程内运行代码），API 2 支持… | 必须迁移 | 实现/部分 | 部分 | C12 |
| `plugin-backend-run-start` | 插件后端发起原生运行 | 必须迁移 | 实现/缺 | 部分 | C01 无 desktop/ 证据 |
| `plugin-backend-workspace-context` | 插件后端 v2 与工作区上下文 | 必须迁移 | 部分/缺 | 部分 | C01 无 desktop/ 证据 |
| `plugin-cross-plugin-function-calls` | 插件函数的跨插件调用（API-35 第一阶段） | 必须迁移 | 部分/缺 | 部分 | C01 无 desktop/ 证据 |
| `plugin-editor-actions` | 普通工具插件的独立编辑器动作 | 必须迁移 | 部分/缺 | 完成 | C03 无 desktop/ 证据 |
| `plugin-editor-grammars` | 独立插件语法高亮与编辑配置 | 必须迁移 | 部分/缺 | 部分 | — |
| `plugin-editor-providers` | 普通工具插件的编辑器语言功能 | 必须迁移 | 部分/缺 | 部分 | C03 无 desktop/ 证据 |
| `plugin-extension-management` | 插件、语言服务与主题管理 | 必须迁移 | 实现/实现 | 部分 | pluginmanager/、settings_plugins.go、plugininstall/ |
| `plugin-functions` | 插件私有函数 | 必须迁移 | 部分/部分 | 完成 | C01 |
| `plugin-host-editor-file-window-services` | 插件公共宿主服务 | 必须迁移 | 部分/缺 | 部分 | C01 无 desktop/ 证据 |
| `plugin-injected-toolchains` | Viva 从已启用插件的 toolDefinitions 声明发现工… | 必须迁移 | 部分/部分 | 部分 | C12 |
| `plugin-language-server-sessions` | 插件自有语言服务器会话与后端决定启动方式 | 必须迁移 | 实现/缺 | 部分 | C01,C02 无 desktop/ 证据 |
| `plugin-marketplace` | 插件市场、插件仓库源与社区插件市场/磁盘安装 | 必须迁移 | 实现/部分 | 部分 | C12 |
| `plugin-native-terminals` | 插件自有原生终端（API-24） | 必须迁移 | 实现/缺 | 部分 | C01 无 desktop/ 证据 |
| `plugin-output-link-matchers` | 插件声明输出链接匹配器 | 必须迁移 | 实现/缺 | 部分 | C01 无 desktop/ 证据 |

### 插件（5）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `declarative-native-plugin-ui` | 插件声明原生树/列表、工具栏按钮及右键菜单，由宿主统一样式 | 必须迁移 | 实现/缺 | 部分 | C05 无 desktop/ 证据 |
| `plugin-web-tool-windows` | 插件可以在宿主管理的工具窗口里显示自己包内的 HTML 页面（ui … | 必须迁移 | 实现/部分 | 部分 | C05 无 desktop/ 证据 |
| `declarative-plugin-settings` | 声明式插件通过 Core 校验的设置声明提供整数、枚举、布尔、多选、… | 必须迁移 | 实现/部分 | 部分 | C12 |
| `plugin-detail-tabs` | 已安装插件详情分为概览、功能、设置、权限与程序、版本与来源五个页签，… | 必须迁移 | 实现/缺 | 部分 | `settingswindow/marketplace_view.go` |
| `plugin-registered-settings-pages` | 插件通过 settings 2 在 plugin.json 里把设置… | 必须迁移 | 实现/缺 | 部分 | `settingswindow/settings_surfaces.go` |

### 插件与扩展（1）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `ide-api-plugins` | 插件调用已授权项目的环境、Maven 与运行 API | 必须迁移 | 实现/实现 | 部分 | `pluginservice/contexts.go` |

### 搜索（4）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `search-global` | 全局命令与设置搜索 | 必须迁移 | 实现/实现 | 部分 | — |
| `search-project` | 项目范围文本搜索 | 必须迁移 | 实现/实现 | 部分 | — |
| `search-quick-open` | 快速打开文件与符号 | 必须迁移 | 实现/实现 | 部分 | — |
| `search-replace` | 项目替换与取消 | 必须迁移 | 实现/实现 | 完成 | — |

### 数据库（6）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `database-connections` | 连接配置与 Provider（由社区插件提供） | 插件提供 | 实现/缺 | 未开始 | C05,C11 扩展点：ui.toolWindows、credentials、pluginFunctions；无 desktop/ 证据 |
| `database-crud-export` | 表数据编辑、CRUD 与导出（由社区插件提供） | 插件提供 | 实现/缺 | 未开始 | C05,C11 扩展点：ui.toolWindows、文件导出；无 desktop/ 证据 |
| `database-multi-schema-tree` | 连接下多数据库独立展开与显示范围选择（由社区插件提供） | 插件提供 | 实现/缺 | 未开始 | C05,C11 扩展点：ui.toolWindows；无 desktop/ 证据 |
| `database-plugin-migration` | 内置数据库模块的连接迁入插件与安装提示 | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `database-query-history` | SQL 查询、历史与分页（由社区插件提供） | 插件提供 | 实现/缺 | 未开始 | C05,C11 扩展点：ui.toolWindows、pluginState；无 desktop/ 证据 |
| `database-schema` | Schema、表与列浏览及结构编辑（由社区插件提供） | 插件提供 | 实现/缺 | 未开始 | C05,C11 扩展点：ui.toolWindows；无 desktop/ 证据 |

### 版本控制（20）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `git-branches-remotes` | 分支、标签与远程 | 必须迁移 | 实现/实现 | 部分 | branch.go、branch_view.go、gitsync.go、core/gitbranch.go；标题栏分支弹窗可签出（含智能/强制签出）、新建、重命名、删除分支，按修订签出，列出标签；获取（含选项与进度）、更新当前或指定分支已接入，分叉时可选合并或变基；把分支合并/变基到当前分支、新建/删除标签、远程管理未找到 |
| `git-commit-sidebar-toolbar-icons` | macOS Commit/Shelf 标签采用共享选中与悬停样式、1… | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `git-diff-review` | Diff 与变更审查（含未暂存修改块的暂存/取消暂存/回退操作；块级… | 必须迁移 | 实现/实现 | 部分 | difftab.go、difftab_view.go：Diff 为编辑区标签页，支持并排/统一、差异跳转、折叠未更改与文件切换；块级包含/排除（暂存/取消暂存）与回退修改块已接入；编辑器 gutter 可暂存修改块（git_gutter.go）；其余项未与旧版逐项核对 |
| `git-explorer-context-actions` | 项目文件树右键 Git 操作 | 必须迁移 | 实现/实现 | 部分 | `core/git_untracked.go` |
| `git-history` | 提交历史与图谱 | 必须迁移 | 实现/实现 | 部分 | C08 |
| `git-large-untracked-directories` | 大型未跟踪目录汇总与按需展开 | 必须迁移 | 实现/实现 | 部分 | `core/git_untracked.go` |
| `git-line-history` | 行级修改历史 | 必须迁移 | 缺/实现 | 部分 | `core/git_blame.go` |
| `git-local-changelists` | 本地 ChangeList | 必须迁移 | 实现/实现 | 部分 | changelists.go、changelists_view.go、core/changelists.go；多选/目录批量移动未做 |
| `git-metadata-observation` | Git 元数据变化观察与刷新 | 必须迁移 | 实现/实现 | 部分 | `workbench/git_observation.go` |
| `git-multi-repository-change-groups` | 多仓库变更折叠分组 | 必须迁移 | 实现/实现 | 部分 | `core/changelists.go` |
| `git-multi-repository-references` | 多仓库引用面板 | 必须迁移 | 实现/实现 | 部分 | — |
| `git-rebase-stash` | Rebase 与 Stash | 必须迁移 | 实现/实现 | 部分 | stash.go、stash_view.go：Commit 工具窗口暂存页可查看、应用、弹出、删除与新建 stash；拉取分叉时可选变基（gitsync.go）；独立 Rebase（含交互式）未找到 |
| `git-repository-discovery` | 仓库自动发现排除隐藏目录与构建缓存 | 必须迁移 | 实现/实现 | 部分 | core/repository_colors.go、gitmetadata/ |
| `git-status-colors-idea-alignment` | Windows 默认主题 Git 状态配色与 IDEA 对齐（修改/… | 必须迁移 | 专属/实现 | 部分 | theme.go 新增 GitModified/GitModifiedStaged/GitRenamed/GitAdded/GitFileDeleted/GitUntracked 与 Gutter* 令牌（IDEA expUI 明暗值）；commit_view.go、gitlog_details_view.go 统一走 palette.gitStatusColor，删除文件改灰、未跟踪改暖红、暂存修改用浅蓝；documents.go 的 gutter 改用浅色令牌。未做：项目文件树与 Git Log 文件树尚未按状态着色（filetree 缺少状态字段） |
| `git-status-commit` | 状态、暂存与提交 | 必须迁移 | 实现/实现 | 完成 | commit.go、commit_view.go、core/gitcommit.go；“提交选项”可加 Sign-off、指定作者（必须是 `Name <email>`，否则 Core 以 `git_commit_author_invalid` 拒绝，作者在提交成功后清空）；Git 控制台（gitconsole.go、core/gitconsole.go）除自动刷新、监听这类后台命令外记录全部 Git 命令，含读取状态的内部查询，查询的答案型非零退出显示为预期；Commit 工具窗口、Diff 标签和分支弹窗发起的写操作会切到控制台页，Log 与工作树页的不切换 |
| `git-submodule-commit-plan` | 子模块先提交与推送、自动更新父引用、计划变化再次确认 | 必须迁移 | 实现/实现 | 部分 | `core/gitcommit.go` |
| `git-workspace-commit-retry` | 失败后只重试未完成的提交或推送步骤 | 必须迁移 | 实现/实现 | 部分 | commit.go `retryCommit`：本项目仓库的提交失败后可重试剩余步骤，先显示复核；多仓库批量提交未接（见 `git-workspace-staged-commit`） |
| `git-workspace-staged-commit` | 按文件所属仓库批量提交及推送，保留每仓库结果 | 必须迁移 | 实现/实现 | 部分 | `core/gitcommit.go` |
| `git-worktrees` | Worktree 管理 | 必须迁移 | 实现/实现 | 部分 | gitworktree.go、gitworktree_view.go、core/gitworktree.go；在新窗口打开、悬停信息、设置页未做 |
| `vcs-subversion-and-plugin-providers` | 统一 VCS 模型与插件 VCS Provider | 插件提供 | 部分/缺 | 部分 | C06 扩展点：vcsProviders；vcs.go、vcs_view.go、core/vcs.go：每个 Provider 一个工具窗口，状态、提交、回滚、更新、标记解决、清理、历史、只读 Diff；Annotate、单文件历史、gutter、元数据监听、fileOperations、项目树状态未做 |

### 界面（3）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `macos-shared-hover-tooltip-style` | macOS 侧边栏与工具栏悬浮提示共用 IDEA Islands 的… | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `macos-shared-product-dropdowns` | macOS 全部产品操作菜单、选值下拉框与自定义弹窗使用 Git L… | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `macos-bundled-default-ui-font` | macOS 界面默认使用随安装包分发的 Inter，编辑器、终端和显… | 必须迁移 | 实现/专属 | 完成 | `bundledfont/`（`lithe_bundled_fonts` 标签编进可执行文件）、`workbench/fonts_bundled.go` |

### 社区（2）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `community-auth` | 社区认证与请求失败处理 | 不纳入 | 缺/缺 | — | 两端基线均缺失 |
| `community-feed` | 主题列表与详情 | 不纳入 | 缺/缺 | — | 两端基线均缺失 |

### 编辑器（32）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `editor-git-blame-menu` | 行号及左侧 gutter 区域右键打开精简菜单 | 必须迁移 | 实现/实现 | 部分 | `core/git_blame.go` |
| `editor-git-gutter-peek` | 编辑器 Git 行变更标记、点击预览与变更导航 | 必须迁移 | 实现/实现 | 完成 | `workbench/git_gutter.go`（标记、气泡、上/下一处变更） |
| `editor-git-gutter-setting` | 设置中开关编辑器 Git 变更标记 | 必须迁移 | 专属/实现 | 完成 | `workbench/git_gutter.go` |
| `editor-git-gutter-stage` | 从编辑器行变更入口暂存单处修改 | 必须迁移 | 实现/实现 | 完成 | `workbench/git_gutter.go` |
| `editor-inline-git-blame` | Windows 行尾 Git Blame 默认关闭 | 必须迁移 | 缺/实现 | 完成 | `workbench/git_gutter.go` |
| `markdown-images-links` | 图片导入与链接定位 | 必须迁移 | 实现/实现 | 完成 | `workbench/markdown_preview.go`、`markdown_images.go`（本地与 http(s) 图片、链接与锚点） |
| `markdown-preview-outline` | Markdown 预览目录默认展开、全高滚动与标题跳转 | 必须迁移 | 实现/缺 | 完成 | `workbench/markdown_preview.go` |
| `markdown-rendering` | Markdown 预览与富文本渲染 | 必须迁移 | 实现/实现 | 部分 | `workbench/markdown_preview.go` |
| `outline-symbols` | 当前文件 Outline 与符号树 | 必须迁移 | 部分/实现 | 完成 | `core/plugin_symbols.go` |
| `references-pane` | 引用结果面板与引用跳转 | 必须迁移 | 实现/实现 | 完成 | C03 无 desktop/ 证据 |
| `editor-go-to-line` | 跳转到行或行列并选择目标 | 必须迁移 | 实现/实现 | 完成 | — |
| `editor-font-family` | 代码编辑器可选择已安装的等宽编程字体族，未安装时回退到随包分发的默认… | 必须迁移 | 实现/实现 | 部分 | — |
| `editor-global-appearance` | 所有项目的源码编辑器共享字体、字号、行间距、高亮配色和常用显示偏好，… | 必须迁移 | 实现/部分 | 部分 | `settingswindow/fonts_view.go` |
| `editor-ide-settings-import` | macOS 导入 IDE 外观、编辑器偏好、受支持的自定义快捷键及全… | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `editor-cursor-history` | 键盘移动后优先撤销光标，并支持独立光标撤销与重做 | 必须迁移 | 部分/实现 | 完成 | `core/navigation_history.go` |
| `editor-file-encoding-reopen` | 按指定编码重新打开文本文件 | 必须迁移 | 实现/实现 | 完成 | — |
| `editor-file-encoding-save` | 按指定编码保存文本文件 | 必须迁移 | 实现/实现 | 完成 | — |
| `editor-language-basics` | 语法高亮与编辑器模型、关闭或切换模型后丢弃过期符号高亮回调 | 必须迁移 | 实现/实现 | 部分 | editor/syntax、editor/textmate |
| `editor-macos-ime-presentation` | macOS 中文组合输入层遮住原文字，输入和删除候选文字时不透出整行… | 平台专属 | 实现/专属 | 未开始 | macOS 输入法组合层 |
| `editor-multiline-tabs` | 多行标签与标签导航 | 必须迁移 | 实现/实现 | 部分 | — |
| `editor-pointer-selection` | 鼠标与触控板点击、选词和拖选 | 必须迁移 | 实现/实现 | 完成 | editorview/input.go |
| `editor-semantic-highlighting` | LSP 语义高亮 | 必须迁移 | 实现/实现 | 部分 | C03 无 desktop/ 证据 |
| `editor-tab-limit` | 标签数量上限与自动关闭策略 | 必须迁移 | 缺/实现 | 完成 | `workbench/tab_limit.go` |
| `editor-text-tabs` | 文本编辑与标签生命周期 | 必须迁移 | 实现/实现 | 部分 | editorview/、tabstrip.go |
| `editor-unicode-confusable-highlight` | 编辑器不把中文全角标点标记为易混淆字符 | 放弃 | 实现/实现 | — | 见“放弃”表 |
| `editor-unicode-text-classification` | 中文 properties 与未知扩展名文本的一致打开和恢复 | 必须迁移 | 实现/实现 | 完成 | `core/documents.go` |
| `editor-scrollbar-style` | 编辑器滚动条与文件树一致的细圆头样式 | 放弃 | 专属/实现 | — | 见“放弃”表 |
| `editor-wallpaper-overview-ruler` | macOS 工作台壁纸模式下，编辑器概览标尺与代码缩略图随编辑器背景… | 放弃 | 实现/专属 | — | 见“放弃”表 |
| `editor-line-operations` | 行注释、复制、删除与上下移动 | 必须迁移 | 本分支新增 | 完成 | — |
| `vim-mode` | Vim 模式与命令状态 | 必须迁移 | 缺/实现 | 完成 | `workbench/vim_mode.go` |
| `lsp-status-logs` | LSP 状态栏控制与按服务器查看日志 | 必须迁移 | 实现/缺 | 部分 | — |
| `embedded-viewers` | HTML、SVG、媒体、PDF 与二进制预览 | 必须迁移 | 实现/实现 | 未开始 | — |

### 设置（3）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `application-settings` | 应用、项目与运行设置及设置窗口操作 | 必须迁移 | 实现/实现 | 部分 | C07 |
| `keymap-customization` | 快捷键查看与自定义 | 必须迁移 | 实现/实现 | 完成 | C06,C07 无 desktop/ 证据 |
| `shared-i18n` | 共享内置翻译完整来源 | 必须迁移 | 实现/实现 | 部分 | — |

### 语言支持（5）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `go-support-plugin` | Go 社区插件 | 插件提供 | 实现/缺 | 未开始 | C06,C11 扩展点：languageServers、executionProviders；无 desktop/ 证据 |
| `java-support-plugin` | Java 语言支持由独立插件 io.github.lithe-ide… | 插件提供 | 插件/缺 | 未开始 | C02,C09,C10,C11 扩展点：languageServers(tcp)、backend、generators、debugAdapters |
| `php-optional-plugin` | PHP 插件按需安装与生命周期（macOS 为 Lithe Stor… | 插件提供 | 实现/实现 | 未开始 | 扩展点：插件生命周期、languageServers；无 desktop/ 证据 |
| `php-run-test` | PHP 插件运行与 PHPUnit 测试 | 插件提供 | 实现/部分 | 未开始 | C06 扩展点：executionProviders；无 desktop/ 证据 |
| `lsp-control-center-performance` | 大型工作区的 LSP 设置页后台识别、快照缓存与可及时取消的页面等待 | 放弃 | 实现/专属 | — | 见“放弃”表 |

### 语言智能（1）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `lsp-document-identity` | 语言服务器文档路径与 URI 身份 | 必须迁移 | 实现/实现 | 部分 | — |

### 运行与调试（21）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `build-provider-jvm-debug` | Maven 框架服务调试通过 Provider 准备当前目标，保留框… | 插件提供 | 插件/缺 | 未开始 | C02 扩展点：debugAdapters(tcp)、buildProviders |
| `debug-breakpoints` | 启动调试与断点 | 必须迁移 | 实现/部分 | 部分 | — |
| `debug-disassembly` | 汇编级调试 | 必须迁移 | 实现/缺 | 部分 | — |
| `debug-java-runtime` | Java 调试与运行使用同一个 JDK | 插件提供 | 插件/缺 | 未开始 | C02 扩展点：toolchains、debugAdapters |
| `debug-performance` | 调试与测试目标进程树的实时 CPU 与内存图表 | 必须迁移 | 实现/缺 | 部分 | — |
| `debug-state` | 变量、异常与断开策略 | 必须迁移 | 实现/部分 | 部分 | — |
| `debug-tcp-transport` | 普通 TCP 调试适配器连接与有界生命周期 | 必须迁移 | 实现/缺 | 部分 | C02 |
| `debug-variable-json-view` | 调试变量默认JSON与树形切换 | 必须迁移 | 实现/缺 | 完成 | — |
| `plugin-debug-adapters` | 插件提供调试适配器 | 必须迁移 | 实现/缺 | 部分 | C02,C12 debug.go、debug_launch.go |
| `plugin-debug-start-and-adapter-features` | 插件后端发起调试并声明适配器行为 | 必须迁移 | 实现/缺 | 部分 | C01,C02 无 desktop/ 证据 |
| `viva-debug-session` | Viva 调试面板使用插件声明的 stdio 调试适配器 | 必须迁移 | 本分支新增 | 部分 | C02,C12 |
| `process-termination-policy` | 退出前逐个确认仍在运行程序的终端和 Agent 后台任务（Agent… | 必须迁移 | 部分/缺 | 部分 | C07 `workbench/process_exit.go`、`workbench/startup_sweep.go`、`settingswindow/process_termination_view.go` |
| `run-processes-end-with-ide` | 退出 IDE 时结束它启动的全部运行、终端、服务、测试、语言服务器和… | 必须迁移 | 实现/部分 | 部分 | `workbench/startup_sweep.go`、`processledger/processledger.go`（启动清扫仅 macOS） |
| `run-output-snapshot` | 运行输出快照 | 必须迁移 | 缺/实现 | 完成 | `workbench/runs.go` |
| `login-shell-environment` | 从 Finder / Dock 启动时继承登录 shell 的环境 | 平台专属 | 实现/专属 | 完成 | `loginenv/loginenv_unix.go`、`cmd/lithe/main.go` |
| `run-discovery` | 入口点与运行配置发现 | 必须迁移 | 实现/实现 | 部分 | `core/run_discovery.go` |
| `run-java-long-classpath` | 超长 Java 类路径自动缩短 | 插件提供 | 插件/实现 | 未开始 | 扩展点：executablePlan/argfile；无 desktop/ 证据 |
| `run-java-test` | Java main 与测试运行 | 插件提供 | 实现/实现 | 未开始 | 扩展点：executionProviders、test 模型；无 desktop/ 证据 |
| `run-node-launch-path` | Node 生态运行脚本的启动 PATH | 必须迁移 | 实现/实现 | 部分 | `workbench/toolchains.go` |
| `run-save-toolchain` | 保存前同步与工具链解析 | 必须迁移 | 实现/实现 | 部分 | `workbench/toolchains.go` |
| `docker-compose` | Docker / Compose 项目识别与运行 | 插件提供 | 部分/实现 | 未开始 | C11 扩展点：toolWindows、executionProviders；无 desktop/ 证据 |

### 通用（1）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `network-proxy-settings` | 在设置 › 外观与行为 › 网络配置应用自身 HTTP 流量的代理 | 必须迁移 | 实现/专属 | 部分 | `workbench/network.go`、`netproxy/netproxy.go`、`settingswindow/network_view.go`（测试连接已做；Digest/NTLM 认证、旧密码导入未做） |

### 项目（1）

| id | 能力 | 分类 | 基线 mac/win | Viva 现状 | 缺口 / 说明 |
| --- | --- | --- | --- | --- | --- |
| `windows-java-new-menu` | Windows New菜单与Java类型/包创建 | 插件提供 | 专属/实现 | 未开始 | C04 扩展点：projectGenerators；无 desktop/ 证据 |

## 放弃（17 项，2026-11-10 用户确认）

| id | 能力 | 基线 mac/win | 理由 |
| --- | --- | --- | --- |
| `ai-chat-history` | 对话历史、置顶与归档 | 缺/实现 | Windows 自带 AI Chat 的对话历史；macOS 基线也只是缺失。原计划由 ACP Agent 会话与历史取代，Agent 对话已于 2026-11-12 一并放弃 |
| `ai-chat-providers` | 多 Provider 与工作区范围 | 缺/实现 | Windows 自带 AI Chat 的多 Provider；保留的 AI 生成提交信息与内联编辑只读取用户 Codex/Claude 配置，不另做供应商管理 |
| `ai-chat-session` | 对话会话与流式响应 | 缺/实现 | Windows 自带 AI Chat 会话与流式响应；Viva 桌面端不做对话（Agent 对话也已于 2026-11-12 放弃） |
| `macos-shared-scrollbar-style` | macOS 共享滚动条样式 | 实现/专属 | 旧 AppKit 滚动条样式规格；Viva 用 hscroll/共享控件统一绘制，不再逐平台复刻 |
| `macos-shared-selection-focus` | macOS 普通选中行主题与区域和窗口焦点 | 实现/专属 | 旧 macOS 原生列表选中行与焦点样式；Viva treelist 自带活动/失焦选择色 |
| `terminal-canvas-compositing` | macOS 终端 Metal 画布按预乘语义清屏 | 实现/专属 | 旧 macOS 终端 Metal 画布清屏语义；Viva termview 自绘，不再有该合成路径 |
| `project-sidebar-tree-disclosure-icons` | 项目树展开与折叠箭头使用 IDEA Community 明暗 SVG… | 实现/专属 | 旧 macOS 树展开/折叠箭头 SVG 规格；Viva 公共 treelist 已自带展开图标 |
| `database-plugin-migration` | 内置数据库模块的连接迁入插件与安装提示 | 实现/专属 | 旧内置数据库模块的连接迁入插件的过渡实现；Viva 从未内置数据库模块，旧连接迁移放入数据来源清单（database.profiles.v1） |
| `git-commit-sidebar-toolbar-icons` | macOS Commit/Shelf 标签采用共享选中与悬停样式、1… | 实现/专属 | 旧 macOS Commit/Shelf 标签的样式规格；Viva commit_view 已重做界面 |
| `macos-shared-hover-tooltip-style` | macOS 侧边栏与工具栏悬浮提示共用 IDEA Islands 的… | 实现/专属 | 旧 SwiftUI/AppKit 悬浮提示样式；Viva 使用统一控件，样式随 Viva 设计验收 |
| `macos-shared-product-dropdowns` | macOS 全部产品操作菜单、选值下拉框与自定义弹窗使用 Git L… | 实现/专属 | 旧 SwiftUI 下拉菜单/弹窗实现规格；Viva 以自己的弹出控件重做 |
| `editor-ide-settings-import` | macOS 导入 IDE 外观、编辑器偏好、受支持的自定义快捷键及全… | 实现/专属 | 旧 macOS 一次性导入 IDE 外观/偏好；快捷键导入由 keymap-import 插件承接，其余不单独迁移 |
| `editor-unicode-confusable-highlight` | 编辑器不把中文全角标点标记为易混淆字符 | 实现/实现 | Monaco unicodeHighlight 专属配置（不把全角标点标为易混淆字符）；Viva 原生编辑器没有该提示机制 |
| `editor-scrollbar-style` | 编辑器滚动条与文件树一致的细圆头样式 | 专属/实现 | 旧 Windows 编辑器滚动条细圆头样式；Viva 编辑器滚动条由 editorview/scrollbar.go 自绘 |
| `editor-wallpaper-overview-ruler` | macOS 工作台壁纸模式下，编辑器概览标尺与代码缩略图随编辑器背景… | 实现/专属 | 旧 macOS 壁纸模式下概览标尺透明处理；Viva 中未找到壁纸模式，随该模式一并不迁 |
| `lsp-control-center-performance` | 大型工作区的 LSP 设置页后台识别、快照缓存与可及时取消的页面等待 | 实现/专属 | 旧 macOS LSP 设置页的后台识别/快照优化；Viva 设置页重做，按新页面另行评估性能 |

## 放弃：MCP 配置与库（2026-11-12 用户决定）

MCP 管理随 Agent 对话失去消费者后，本轮整块删除，后续重新设计。Rust Core 删除 `mcp` 模块与 `mcp.parseConfiguration`、`mcp.parseRegistry`、`mcp.featuredRegistry`、`mcp.planWrite`、`mcp.toolPolicy`、`mcp.commandLine`、`mcp.librarySnapshot`、`mcp.validateDraft`、`mcp.batchPlan` 九个命令，以及 `rust/fixtures/mcp` 与 `rust/contracts/mcp-registry-page.json`。本仓库删除 `shared/fixtures/mcp`、`shared/contracts/mcp-registry-page.json`、67 条仅旧客户端使用的 MCP 词条与两个能力记录（`mcp-registry-discovery`、`mcp-server-library`），服务器库 Note 移入 `.agents/notes/archived/`。

保留 `ide-mcp-connection`：Lithe 对外提供的 IDE API MCP 服务端（`lithe-mcp`、`shared/fixtures/ide-api/mcp-protocol.json`）不依赖被删的配置管理能力。

## 放弃：Agent 对话（38 项，2026-11-12 用户决定）

用户决定 Viva 桌面端不做 Agent 对话。#1799 删除了助手面板、会话与历史、卡片、Agent 安装与管理、自定义 Agent，以及 AI 设置下的 Agents、Instructions、Skills、Hooks、MCP 配置页。保留 AI 生成提交信息（`ai-commit-generation`）、编辑器内联 AI 编辑（`ai-inline-edit`）和 IDE 连接（`ide-mcp-connection`），它们读取用户 Codex/Claude 配置的服务商发现移到 `desktop/internal/workbench/ai_provider.go`。Rust Core 中的 Agent 代码与 `shared/fixtures/agent`、`shared/fixtures/mcp` 契约当时暂留，随后已分别由 Lithe-core-rust#18 与 #19 删除。

第二轮清理删掉了只描述放弃能力的记录：`shared/i18n/` 里 593 条含 `agent` 的词条（唯一还被引用的 `agent.state.cancel` 改用通用 `ui.cancel`）、功能矩阵的 36 个 `agent-*.json` 条目（矩阵从 255 条降到 219 条），以及旧客户端 Agent 对话的 15 篇 Note（移入 `.agents/notes/archived/`）。下表保留为放弃清单，不再对应矩阵文件。

| id | 能力 | 基线 mac/win | 理由 |
| --- | --- | --- | --- |
| `agent-acp-conversation` | 可选 ACP Agent 对话 | 实现/实现 | Agent 对话整体放弃 |
| `agent-approval-mode-presentation` | Agent 权限模式呈现 | 实现/实现 | Agent 对话整体放弃 |
| `agent-archived-conversation-history` | 当前工作区的 Codex 归档历史 | 实现/实现 | Agent 对话整体放弃 |
| `agent-chat-editor-placement` | 在编辑区标签页与 AI 工具窗口之间移动对话（按钮、右键菜单或把 A… | 实现/实现 | Agent 对话整体放弃 |
| `agent-claude-api-key-authentication` | Claude API Key 鉴权 | 实现/实现 | Agent 对话整体放弃 |
| `agent-claude-desktop-mechanisms` | 在 Lithe 中打开 Claude Desktop 开始的 Cla… | 实现/部分 | Agent 对话整体放弃 |
| `agent-claude-subscription` | Claude 供应商可选官方订阅 | 实现/部分 | Agent 对话整体放弃 |
| `agent-codex-subscription` | Codex 供应商选择官方订阅 | 实现/实现 | Agent 对话整体放弃 |
| `agent-connection-model-switching` | Agent 与模型切换 | 实现/实现 | Agent 对话整体放弃 |
| `agent-context-limits` | Agent 上下文长度与自动压缩阈值 | 实现/部分 | Agent 对话整体放弃 |
| `agent-context-usage` | Agent 上下文用量与会话详情共用发送旁单一入口（未上报显示信息图… | 实现/实现 | Agent 对话整体放弃 |
| `agent-conversation-history` | CC GUI 风格历史页 | 实现/实现 | Agent 对话整体放弃 |
| `agent-entry-discoverability` | 新安装及模块关闭时仍显示 Agent 侧栏入口，打开项目不自动恢复 … | 实现/实现 | Agent 对话整体放弃 |
| `agent-file-context-actions` | 从编辑器文件标签或项目树右键把文件添加到当前或指定 Agent 会话… | 实现/实现 | Agent 对话整体放弃 |
| `agent-file-references` | 从 Finder 或项目树拖入文件、⌘V 粘贴 Finder 文件或… | 实现/实现 | Agent 对话整体放弃 |
| `agent-global-instructions` | 全局指令卡片 | 实现/部分 | Agent 对话整体放弃 |
| `agent-hooks` | Hook 资源库 | 实现/实现 | Agent 对话整体放弃 |
| `agent-management` | Agent 管理 | 实现/实现 | Agent 对话整体放弃 |
| `agent-mid-turn-steering` | 回复过程中发送补充指令 | 实现/实现 | Agent 对话整体放弃 |
| `agent-minimal-conversation` | Agent 最小会话纵向切片 | 本分支新增 | Agent 对话整体放弃 |
| `agent-mode-sync` | Agent 自行切换模式时同步权限选择器 | 实现/实现 | Agent 对话整体放弃 |
| `agent-model-call-statistics` | Agent 发送旁单一入口按需展开的上下文与会话详情（有用量显示圆环… | 实现/实现 | Agent 对话整体放弃 |
| `agent-opened-workspace-context` | 当前打开项目的明确上下文 | 实现/实现 | Agent 对话整体放弃 |
| `agent-plan-display` | 任务以紧凑状态行显示 Agent 上报计划（ACP plan）的已完… | 实现/实现 | Agent 对话整体放弃 |
| `agent-provider-configuration` | Agent 供应商管理 | 实现/实现 | Agent 对话整体放弃 |
| `agent-reasoning-display` | 每轮思考、过程说明和工具调用合成一个默认折叠的过程入口，流式时也由用… | 实现/实现 | Agent 对话整体放弃 |
| `agent-reply-markdown` | Agent 回复的 Markdown 渲染 | 实现/实现 | Agent 对话整体放弃 |
| `agent-skill-management` | 技能设置 | 实现/部分 | Agent 对话整体放弃 |
| `agent-slash-commands` | 输入框以 / 开头（或以 $ 开头选择 Skill）时，按 Agen… | 实现/实现 | Agent 对话整体放弃 |
| `agent-subagent-monitoring` | 原生子代理监视 | 实现/实现 | Agent 对话整体放弃 |
| `agent-subscription-multi-account` | Claude 与 Codex 官方订阅支持多个账号 | 实现/部分 | Agent 对话整体放弃 |
| `agent-subscription-quota` | Codex 订阅额度 | 实现/实现 | Agent 对话整体放弃 |
| `agent-thinking-level-labels` | Agent 思考强度英文呈现 | 实现/实现 | Agent 对话整体放弃 |
| `agent-tool-activity-timeline` | 每轮工具调用与思考、过程说明放进同一个默认折叠的过程区 | 实现/实现 | Agent 对话整体放弃 |
| `agent-toolbar-brand-marks` | Agent 品牌标志 | 实现/实现 | Agent 对话整体放弃 |
| `agent-turn-statistics` | 发送后实时计时；每轮回复下方固定显示复制回复、用量胶囊（耗时 · t… | 实现/实现 | Agent 对话整体放弃 |
| `mcp-registry-discovery` | 同页上方管理服务器资源库，下方默认显示离线可用的内置精选 | 实现/缺 | Agent 对话整体放弃 |
| `mcp-server-library` | 在设置页统一发现、合并、编辑并删除 Codex 与 Claude C… | 实现/专属 | Agent 对话整体放弃 |

## 矩阵之外的能力

对照旧代码（5a54c41）与 #1794 第 10 节“容易被漏掉的能力”。下列已在矩阵内的不再重复：Windows Vim（`vim-mode`）、WSL（`wsl-paths`、`wsl-boundaries`）、行内 blame（`editor-inline-git-blame`）、标签上限（`editor-tab-limit`）、运行输出快照（`run-output-snapshot`）、行历史（`git-line-history`）、插件原生 UI（`declarative-native-plugin-ui`）、编辑器动作与 Provider（`plugin-editor-actions`、`plugin-editor-providers`）、插件终端（`plugin-native-terminals`）、远程上下文（`remote-workspace`）、退出回收（`run-processes-end-with-ide`）、本地历史（`history-*`）、GitHub（`github-*`）、命令面板（`command-palette`）、Diff（`git-diff-review`）。

下列在矩阵里没有独立行（或只被其他行顺带提及）：

| 能力 | 旧代码位置 | 归类 | Viva 现状（desktop/） |
| --- | --- | --- | --- |
| 编辑器内查找/替换 | Monaco 内置，`frontend/editor/src/editor-commands.ts` | 必须迁移 | 未找到（只有项目级 Find in Files，`search.go`） |
| 多光标 | Monaco 内置（addSelectionToNextFindMatch 等） | 必须迁移 | 未找到 |
| 代码折叠、括号匹配、格式化文档等 Monaco 内置编辑能力 | Monaco | 必须迁移（逐项确认后拆行） | 未找到；格式化属 C03 |
| 虚拟/只读源码（非 file URI 内容，如 jar 内源码） | macOS 虚拟源码；C03 | 必须迁移 | 未找到 |
| 未保存文档恢复（崩溃/退出后恢复缓冲区） | 专用恢复存储未找到；Windows `buffer.store.ts` 有相关处理 | 必须迁移 | 未找到；有外部修改冲突处理（`document_conflict.go`） |
| 插件权限确认与签名/摘要校验 | `MacPluginPackageStore.swift`（批准时摘要）；`plugin_host/store.rs` | 必须迁移 | 部分：`plugintrust/`、`plugininstall/` 已有批准记录；完整可信安装流程未验收 |
| 应用菜单栏 / Dock 菜单 | macOS `LitheApp.swift`（命令菜单、NSApplicationDelegate 相关代码，Dock 菜单未单独核对） | 平台专属（macOS） | 未找到 |
| 文件关联 / 文档类型 | macOS `Info.plist` CFBundleDocumentTypes；Windows tauri bundle | 平台专属 | 未找到 |
| URL scheme / 深链接 | Windows `tauri_plugin_deep_link`；macOS Info.plist 未找到 URL scheme | 平台专属（Windows） | 未找到 |
| 单实例与项目窗口注册 | Windows `tauri_plugin_single_instance`、`project_window_registry.rs`；macOS `MacProcessLifecycle.swift` | 必须迁移 | 未找到；`workspace-open-switch` 当前只保留一个项目 |
| 崩溃报告收集 | macOS `MacCrashReportCollector.swift` | 平台专属（macOS） | 未找到（`signal_guard_darwin.go` 仅为信号保护） |
| Git Shelf（搁置） | macOS `ShelveService.swift`；Windows `shelf_storage.rs` | 必须迁移 | 未找到 |
| HTML 预览打印/缩放 | macOS `HTMLPreviewPrint.swift`、`HTMLPreviewZoom.swift` | 放弃（依赖 WebKit，Viva 无嵌入网页；2026-11-10 确认） | 未找到 |
| 开发版配置迁入（Dev 取 Stable 配置） | macOS `MacDevelopmentProfileMigration.swift`；Windows `profile_migration.rs` | 放弃（内部并行试用用；新客户端与旧 Lithe 的关系见下文数据清单开头） | 未找到 |

## 旧客户端数据来源清单

新客户端与旧 Lithe 的关系（2026-11-10 确定）：

- 新客户端（`app.lithe.viva`，产品名 Lithe Desktop）是新产品，与旧 Lithe 并行安装，不做原地升级，也不衔接旧 Sparkle 更新链。
- 旧 Lithe 停止更新，直到迁移完成；在此之前旧客户端仍会被使用，它的数据必须保持可用。
- 新客户端不自动读取、改写或删除旧客户端的任何数据。下表“迁移建议”列描述的都是**用户主动触发的可选导入**：只读旧来源，写入新位置并读回成功才算完成，不修改旧数据。这类导入不是首个预发布的前置条件。
- 已实现的导入：插件凭据（macOS，设置齿轮菜单“从旧版 Lithe 导入插件凭据”）；旧版插件清单（同一对话框列出，经插件市场重新安装）；应用偏好与最近项目（设置齿轮菜单“从旧版 Lithe 导入设置…”，`desktop/internal/legacyimport` 只读读取，`workbench/legacy_import.go` 列出找到的项供逐项勾选，经设置页同一组 setter 写入后读回 `settings.json` 与 `recent-projects.json` 校验）。其余各项尚未实现。
- 偏好导入的映射：界面语言、主题（跟随系统/浅色/深色）、编辑器小地图、编辑器标签单行/多行、终端 Shell（macOS 的路径覆盖优先，`zsh`/`bash` 取 `/bin/zsh`、`/bin/bash`，`system` 为自动）、进程终止选项（退出时终止 Run 服务、退出时终止忙碌终端、关闭忙碌终端标签前确认）、编辑器字体与终端字体（只占用各自作用域，未给字号时沿用当前字号）。旧值不在新客户端取值范围内的项不列出。macOS 经 `/usr/bin/defaults export app.lithe.desktop -` 读取（经 cfprefsd，读到旧客户端最后写入的值，不改文件）；Windows 读 `%APPDATA%\app.lithe.windows\settings.json`，其最近项目在 WebView localStorage 中，暂不读取。
- 不导入：自定义日志目录（与仍在使用的旧客户端共用目录会混写两个产品的日志）；快捷键、会话、本地历史、Shelf（新客户端尚无对应存储，随功能实现再定）。

口径：旧 macOS 的 bundle id 为 `app.lithe.desktop`（Dev 渠道 `app.lithe.desktop.dev`，Dev 的 Application Support/Logs 根多一层 `app.lithe.desktop.dev/`，见 `MacAppIdentity.swift`）；旧 Windows Tauri 标识为 `app.lithe.windows`（Dev `app.lithe.windows.dev`）。Tauri 目录按其默认规则推出：`app_data_dir` 与 `app_config_dir` 为 `%APPDATA%\<标识>`，`app_local_data_dir` 为 `%LOCALAPPDATA%\<标识>`，`app_log_dir` 为 `%LOCALAPPDATA%\<标识>\logs`；这些路径由代码调用加规则推出，未在 Windows 机器上实测。

新客户端存储根（`desktop/internal/store`）：用户配置目录下的 `Lithe Desktop`，macOS `~/Library/Application Support/Lithe Desktop`，Windows `%APPDATA%\Lithe Desktop`（`os.UserConfigDir()`）。

| 数据类别 | macOS 旧位置 | Windows 旧位置 | 写入的旧代码 | 新客户端当前位置 | 迁移建议 |
| --- | --- | --- | --- | --- | --- |
| 应用偏好 | UserDefaults 域 `app.lithe.desktop`（`~/Library/Preferences/app.lithe.desktop.plist`）；Sparkle 另用域 `app.lithe.desktop.sparkle.<channel>` | Tauri store `settings.json`（`%APPDATA%\app.lithe.windows\settings.json`），另有 WebView localStorage（zustand 持久化） | macOS `MacUserDefaultsStore.swift`、`Models/Settings/AppSettings.swift`；Windows `features/settings/lib/settings-persistence.ts` | `Lithe Desktop/settings.json`（`workbench/app.go` `settingsFile`） | 已实现可选导入（见上方“偏好导入的映射”）；不删除或改写旧来源；无对应取值的旧项不列出 |
| 最近项目 | UserDefaults 键 `lithe.recent-projects` | WebView localStorage 键 `lithe-code-recent-folders`、`lithe-recent-files` | macOS `Services/Workspace/RecentProjectsStore.swift`；Windows `features/file-system/stores/recent-folders.store.ts`、`recent-files.store.ts` | `Lithe Desktop/recent-projects.json`（`workbench/app.go`，排序由 Core 决定） | macOS 已实现：导入路径与 openedAt（旧值为 2001 起算的秒），与当前列表合并后经 Core `normalize` 去重、排序、限量；已不存在的目录按现有 missing 标记处理。Windows 来源在 localStorage，未实现 |
| 窗口/布局 | UserDefaults 键前缀 `lithe.workbench-layout.<工作区路径>`；会话（已开标签）键前缀 `lithe.workspace-session.<工作区路径>` | 布局与标签状态的持久化位置未找到（WebView localStorage 内的 zustand 存储，键名未逐一核对） | macOS `Services/Workbench/WorkbenchLayoutStore.swift`、`Services/Workspace/WorkspaceSessionStore.swift` | 布局 `Lithe Desktop/workbench-layout-v2.json`（`workbench/catalog.go`）；工作区会话：未找到 | 旧布局语义与 v2 不同（旧为面板排布，v2 为六区停靠），只映射可对应项；会话恢复需新增存储 |
| 快捷键 | 存储键未找到（代码在 `Models/Keymap/`）；macOS 导入 IDE 快捷键走 keymap-import 插件 | WebView localStorage 键 `keymaps-storage`（`features/keymaps/stores/keymaps.store.ts`） | 同左 | 未找到（设置页快捷键为占位，C07） | 先定义新存储，再导入显式覆盖项；与插件快捷键导入共用冲突预览 |
| 插件安装目录 | `~/Library/Application Support/Lithe/Plugins/<id>/<版本>/`（含 `plugin.json`、`installation.json`）；另有 `.removed-bundled-plugins.json` | `%LOCALAPPDATA%\app.lithe.windows\plugins\<id>\<版本>\`；内置官方包在安装目录 `OfficialPlugins/`（只读资源） | macOS `Platform/MacOS/Plugins/MacPluginPackageStore.swift`；Windows `plugin_host/store.rs`、`install.rs` | macOS `~/Library/Application Support/Lithe Desktop/plugins`；Windows `%LOCALAPPDATA%\Lithe Desktop\plugins`（`pluginpkg/dirs_*.go`） | 已实现：导入对话框列出旧版安装过、新客户端尚未安装的插件（macOS 读 `<id>/installation.json` 的 `pluginID`、`activeVersion`、`origin`、`status`，跳过 bundled 与待卸载；Windows 读 `pluginId`、`version`；名称取 `<版本>/plugin.json` 的 `displayName`），并给出“打开插件市场”。不复制旧安装包：旧包按旧宿主契约签发与批准，经市场重新安装才会按本版本检查兼容性与签名 |
| 插件启用状态 | 安装记录与 `.removed-bundled-plugins.json`；字段未逐项核对 | `installation.json` 的启用位；旧 TS 扩展的禁用列表在 WebView localStorage（`extension-enabled-state.ts`） | 同上 | `Lithe Desktop/plugin-state.json`（`pluginstate/pluginstate.go`） | 未导入。macOS 旧启用状态按模块存于 UserDefaults `lithe.modules.<模块ID>.enabled`，模块与插件 ID 的对应未核对；插件经市场重新安装后由用户在插件页设定 |
| 插件授权记录 | 社区包的批准摘要记录在安装记录（`MacPluginPackageStore.swift` 注释：批准时的文件摘要），独立授权文件未找到；`Application Support/Lithe/PluginHost/root-id.key` 为 root id 密钥 | 授权记录位置未找到 | 同上 | `Lithe Desktop/plugin-approvals.json`（`plugintrust/store.go`） | 摘要不同的包按未批准处理，不沿用旧批准；root-id.key 不应复制 |
| 插件设置 | 全局值 UserDefaults（`MacPluginSettingsStore.swift`，键未逐项核对）；项目覆盖 `<工作区>/.lithe/plugin-settings.json` | 全局 `%LOCALAPPDATA%\app.lithe.windows\plugin-settings\<pluginID>.json`；项目覆盖同样 `.lithe/plugin-settings.json` | Windows `plugin_host/settings.rs` | 项目 `.lithe/plugin-settings.json`（`pluginsettings/store.go`，两端一致可直接沿用）；全局：经 `pluginsettings` 偏好存储，具体文件名未核对 | 项目层不迁；全局层读旧值、按 Core 校验后写入，校验不过的保留旧文件 |
| 插件私有状态 | `Application Support/Lithe/PluginState`，Web 状态 `MacPluginWebStateStore.swift` | `%LOCALAPPDATA%\app.lithe.windows\plugin-state\<pluginID>`（`plugin_host/store.rs`） | 同上 | 未找到 | 属于插件，建议按插件 ID 原样复制目录，缺失则让插件重建 |
| 插件市场来源 | `Application Support/Lithe/PluginMarketplace/sources.json` | 未找到 | `MacPluginMarketplaceService.swift` | 未找到（`marketplace/` 读取固定官方与社区索引） | 自定义源导入后再提示用户确认，不静默加入 |
| 凭据：GitHub / 代理 / 数据库 / 远程 / 插件 | Keychain service：`app.lithe.desktop.github`（键 `oauth-token`）、`app.lithe.desktop.proxy`（键 `proxy.password`）、`app.lithe.desktop.database`、`app.lithe.desktop.remote`、`app.lithe.desktop.plugin-credentials`（按 pluginID 追加） | Windows 凭据管理器（keyring crate）：service 为应用标识 `app.lithe.windows`，用户名为调用方键（如 `ai-provider-token/<id>`） | macOS `MacServiceContainer.swift`、`MacKeychainSecureStore.swift`、`MacPluginCredentialStore.swift`；Windows `secure_storage.rs` | 插件凭据：`desktop/internal/credentials`，service `app.lithe.viva.plugin-credentials.<插件ID>`（macOS 钥匙串，Windows 凭据管理器，Linux Secret Service）；GitHub、代理、数据库、远程凭据：未找到 | 插件凭据已实现导入：用户在设置齿轮菜单确认后，列出旧 `app.lithe.desktop.plugin-credentials.<插件ID>`（及 `.dev`）下的项，逐项读取（系统可能请求允许访问），只填补新位置没有的值，旧项不改不删；平时 `get`/`delete` 不碰旧项。旧 Windows 没有插件凭据。其余凭据随对应功能实现同样的可选导入；不得导出明文 JSON |
| 凭据：AI/Agent | Keychain 键 `lithe.<来源>.imported.apiKey`；回退文件 `Application Support/Lithe/ai-secrets.json`（`MacLocalSecretStore.swift`）；Agent 数据目录 `Application Support/Lithe`（`AgentAccounts/<agent>/` 订阅账号，`agents/<id>` 适配器安装） | Tauri store `settings.json` 的 `agentPanel`；凭据在凭据管理器；Rust agent-host 数据目录 | macOS `AppModel+AgentAccounts.swift`、`AppModel+AgentConversation.swift`；Windows `agent_provider_settings.rs`、`ai-token-service.ts` | Core `agent.*` 接口接收调用方传入的 dataDirectory，Viva 传入的默认目录未找到；Agent 会话历史由 Codex/Claude CLI 自己保存，Viva 通过 `listSessions` 读取 | 订阅账号目录是官方 CLI 的独立配置目录，建议原路径只读复用；密钥按上一行处理 |
| 数据库连接（旧内置模块） | UserDefaults `database.profiles.v1`、`database.connection-folders.v1`、`database.sql-history.v1`；迁移标记 `lithe.databasePluginMigration.v1` | 未找到 | `MacDatabasePluginMigration.swift` | 不适用（数据库由 Lithe Store 社区插件提供） | 由数据库插件负责导入；宿主不自动读取旧键与旧钥匙串，旧值只经用户触发的导入取得（插件凭据导入见“凭据：GitHub / 代理 / 数据库 / 远程 / 插件”行） |
| 远程工作区 | `Application Support/Lithe/RemoteWorkspaces/<连接>/<路径哈希>/`；连接 `connections.json` | 未找到 | `MacRemoteWorkspaceRoots.swift` | 未找到 | 随远程功能迁移时再定 |
| 未保存文档恢复 | 专用恢复存储未找到 | 未找到（`buffer.store.ts` 仅内存/localStorage 处理，未定位具体键） | — | 未找到 | 在新客户端设计恢复记录；不能丢旧未保存正文，但旧侧没有可迁移文件 |
| 本地历史 | `Application Support/Lithe/LocalHistory`（`MacLocalHistoryAdapters.swift`，Rust Core 存取） | 未找到（`shelf_storage.rs` 的 `app_data_dir/git-shelves/<身份>` 是 Git Shelf，不是本地历史） | `RustLocalHistoryOperations.swift` | 未找到 | 保留旧目录只读，Viva 实现本地历史后按工作区相对身份导入 |
| Git Shelf | `Application Support/Lithe/` 下版本化 JSON（`ShelveService.swift`） | `%APPDATA%\app.lithe.windows\git-shelves\<身份>` | 同左；Windows `shelf_storage.rs` | 未找到 | 随 Shelf 功能迁移 |
| 运行配置 / 工具链 | 工作区内 `.lithe/run/configurations.json`、`.lithe/run/local.json`、`.lithe/toolchains/local.json`；macOS 另有 UserDefaults 键 `buildSystemPluginID`、`buildSystemID` | 同工作区文件 | Rust Core `execution/configuration.rs`；macOS `MacRunConfigurationStore.swift` | 工作区文件无需迁移；Viva 的 `toolchain/pins.go` 写 `.lithe/toolchains/local.json`；运行配置编辑入口未找到 | 工作区文件两端共用，不动；UserDefaults 键只在需要时转为新偏好 |
| 日志目录 | `~/Library/Logs/Lithe`（Dev 多一层 `app.lithe.desktop.dev/`）；自定义目录偏好存于旧偏好 | `%LOCALAPPDATA%\app.lithe.windows\logs`；自定义目录在 `%APPDATA%\app.lithe.windows\lithe-log-settings.json` | macOS `MacLogDirectoryProvider.swift`；Windows `logging.rs` | macOS `~/Library/Logs/Lithe Desktop`；Windows `%LOCALAPPDATA%\Lithe Desktop\Logs`；目录偏好 `Lithe Desktop/logging.json`（`logstore/`） | 日志不迁移；自定义目录也不导入：旧客户端仍在使用该目录，共用会混写两个产品的日志，用户可在日志窗口另选 |
| Windows WebView 缓存 | — | `%LOCALAPPDATA%\app.lithe.windows\EBWebView\`（含 localStorage leveldb） | `profile_migration.rs` 已有读取 `EBWebView/Default/Local Storage/leveldb` 的先例 | 不适用 | 迁移期间需关闭旧应用后只读快照；上表标注 localStorage 的项目都经此读取 |

## 打包、更新与应用身份对照

| 项目 | 旧 macOS | 旧 Windows | 新客户端（desktop/） | 是否一致 |
| --- | --- | --- | --- | --- |
| 应用标识 | bundle id `app.lithe.desktop`（Dev `app.lithe.desktop.dev`），`macos/Resources/Info.plist`；Dev 由 `scripts/macos/package/configure-sparkle-app.sh` 在签名前改写 | Tauri `identifier` `app.lithe.windows`（Dev `app.lithe.windows.dev`），`windows/tauri/src-tauri/tauri.conf.json`、`tauri.autobuild.conf.json` | `desktop/viva.toml` `[app] id = "app.lithe.viva"` | 否。有意区分：新客户端是新产品，与旧 Lithe 并行安装，不做原地升级。旧钥匙串 service、UserDefaults 域、Tauri 数据目录仍按旧标识命名，只经用户触发的可选导入只读访问（见“旧客户端数据来源清单”开头） |
| 应用名 / 版本 | `CFBundleName` Lithe，版本 0.1.0（Info.plist），发布时覆盖 | `productName` Lithe，0.3.0 | `name = "Lithe Desktop"`，`version = "0.7.0"` | 否（产品名不同，版本线独立） |
| macOS 更新 | Sparkle：`SUFeedURL` 与 `SUPublicEDKey` 在构建时由 `configure-sparkle-app.sh` 写入。Stable 源 `https://github.com/<仓库>/releases/latest/download/appcast-<arch>.xml`；AutoBuild 源 `https://github.com/<仓库>/releases/download/AutoBuild/appcast-preview-<arch>.xml`；公钥来自仓库变量 `SPARKLE_PUBLIC_KEY`（值未在仓库内，未找到）；`SURequireSignedFeed`、`SUVerifyUpdateBeforeExtraction` 为 true；说明见 `docs/architecture/macos-updates.md` | — | `viva.toml` 与 `scripts/desktop/package-desktop.sh` 中未找到 Sparkle、appcast、feed、公钥任何配置 | 否。新客户端自建更新通道（新的 appcast 与签名公钥），不衔接旧 Sparkle 增量链；尚未实现（`updates-check-download` 为未开始） |
| Windows 安装与更新 | — | Tauri 打包 `nsis`、`msi`（`tauri.conf.json` `bundle.targets`）；Tauri updater 插件，`tauri.conf.json` 中 `pubkey` 为空串、`endpoints` 为空；稳定版发布工作流 `release-windows.yml` 用 secret `TAURI_SIGNING_PRIVATE_KEY` 与变量 `TAURI_UPDATER_PUBLIC_KEY` 签名，产出 `Lithe-<版本>-windows-x64-updater.exe` | `viva.toml [windows]`：`scope = "user"`、`publisher = "Lithe contributors"`；`package-desktop.sh` Windows 默认格式 `nsis,zip`；更新机制未找到 | 部分。同为 NSIS；没有 MSI、更新器与签名公钥配置 |
| 发布工作流 | `release-macos.yml`、`release-preview-macos.yml` | `release-windows.yml`、`release-preview-windows.yml` | `.github/workflows/desktop-release.yml`，标签 `desktop-v*.*.*`，作为 prerelease 发布，避免旧客户端的更新器读到 | 独立 |
| 运行时只读边界 | 发行 bundle 运行期不可写（AGENTS.md） | 安装目录只读 | `package-desktop.sh` 注释声明运行时写入不落在 app 或安装目录；`runtime-package-integrity` 仅 macOS 夹具验证 | 一致于规则；Windows/最终包验证未完成 |
