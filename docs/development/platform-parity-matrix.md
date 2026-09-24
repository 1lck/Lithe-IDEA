# macOS / Windows 功能对齐矩阵

> 本页由 `shared/platform-feature-matrix.json` 自动生成。不要直接编辑本文件；新增或变更功能时更新源数据，再运行 `node scripts/generate-platform-feature-matrix.mjs`。

- 最后复核：2026-09-24
- 功能项：18
- macOS：✅ 16 已实现，🟡 0 部分实现，❌ 1 未实现，🔍 0 待验证，🧩 1 平台专属
- Windows：✅ 16 已实现，🟡 0 部分实现，❌ 1 未实现，🔍 1 待验证，🧩 0 平台专属

## 状态定义

| 状态 | 含义 |
| --- | --- |
| ✅ 已实现 | 代码入口和产品接入均已存在；仍需按验证方式确认运行时行为。 |
| 🟡 部分实现 | 已有实现，但范围、入口、平台能力或用户体验仍不完全一致。 |
| ❌ 未实现 | 当前没有足够的实现入口或产品接入证据。 |
| 🔍 待验证 | 静态代码无法可靠判断完成度，必须补充指定的运行时验证。 |
| 🧩 平台专属 | 刻意只属于某个平台，不以跨平台对齐为目标。 |

## 功能矩阵

| 区域 | 功能 | macOS | Windows | 负责人 | 验证方式 |
| --- | --- | --- | --- | --- | --- |
| 工作区 | **工作区打开、项目切换与文件生命周期**<br><sub>workspace-lifecycle</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Workspace`、`macos/Sources/Lithe/Services/Workspace`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/workspace`、`windows/tauri/src/features/file-system`</sub> | Workspace | 打开多个项目，编辑、保存、外部修改和切换项目。 |
| 编辑器 | **多标签编辑、保存、撤销与语言基础能力**<br><sub>editor-documents</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Editor`、`macos/Sources/Lithe/Models/Editor`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/editor`、`frontend/editor`</sub> | Editor | 分别验证普通文本、Java、Markdown 和大文件的打开、编辑、保存与恢复。 |
| 编辑器 | **全局搜索、项目搜索、符号搜索与替换**<br><sub>search</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Search`、`macos/Sources/Lithe/Services/Language`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/global-search`、`windows/tauri/src/features/file-search`、`windows/tauri/src/features/quick-open`</sub> | Search | 使用同一 fixture 对比结果顺序、路径、行列号、替换预览和取消行为。 |
| 版本控制 | **Git 状态、提交、分支、历史、Diff、Rebase 与 Worktree**<br><sub>git</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Git`、`macos/Sources/Lithe/Services/GitHub`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/git`、`shared/contracts/application-boundary.md`</sub> | Git | 执行 status、commit、branch、history、diff、rebase 和 worktree fixture。 |
| 协作 | **GitHub Pull Request、Review、评论与远程操作**<br><sub>github</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/GitHub`、`macos/Sources/Lithe/Services/GitHub`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/github`、`shared/contracts/application-boundary.md`</sub> | GitHub | 使用测试仓库验证 PR 列表、详情、评论、Review 和浏览器跳转。 |
| AI | **AI 生成提交信息**<br><sub>ai-commit</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Application/Features/CommitWorkflowCoordinator.swift`、`macos/Sources/Lithe/Platform/MacOS/AI`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/git/services/ai-commit-service.ts`、`shared/contracts/ai-commit.md`</sub> | Git / AI | 用相同 diff、规则和 provider 配置比较请求计划、取消、错误和生成文本。 |
| AI | **AI 对话、历史与多 Provider**<br><sub>ai-chat</sub> | ❌ 未实现<br><sub>`macos/Sources/Lithe/Platform/MacOS/AI`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/ai/components/chat/ai-chat.tsx`、`windows/tauri/src/features/ai/services/ai-chat-service.ts`</sub> | AI | macOS 需要先定义产品范围；Windows 验证会话、历史、Provider、流式响应和取消。 |
| Java | **Java/Maven 项目识别、模块、依赖与构建**<br><sub>java-maven</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Run`、`macos/Sources/Lithe/Services/Java`、`shared/contracts/application-boundary.md`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/maven`、`windows/tauri/src/features/workspace`</sub> | Java / Maven | 使用单模块、多模块、profile 和依赖树 fixture 对比项目模型与构建输出。 |
| Java | **Spring 配置/Bean/Endpoint 与 MyBatis 导航**<br><sub>spring-mybatis</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Application/Features`、`macos/Sources/Lithe/Views/Run`、`shared/fixtures/spring`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/spring`、`windows/tauri/src/features/mybatis`、`shared/fixtures/spring`</sub> | Java / Spring | 使用同一 Spring/MyBatis fixture 对比索引、导航、刷新和失效处理。 |
| Java | **语言服务、LSP、诊断、补全、Hover 与语义导航**<br><sub>language-tooling</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Core/Language`、`macos/Sources/Lithe/Services/Language`、`shared/contracts/rust-core-api.md`</sub> | 🔍 待验证<br><sub>`windows/tauri/src/features`、`shared/fixtures/lsp`、`shared/contracts/application-boundary.md`</sub> | Language Tooling | 必须在 macOS 和 Windows 各启动真实 JDTLS，执行 project preparation、补全、诊断、跳转和重启。 |
| Java | **运行配置、Java/Test 运行与断点调试**<br><sub>run-debug</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Run`、`macos/Sources/Lithe/Views/Debug`、`shared/fixtures/debug`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/run`、`windows/tauri/src/features/debugger`、`shared/fixtures/debug`</sub> | Run / Debug | 验证保存前同步、Java main、测试、断点、变量分页、异常和 disconnect policy。 |
| 工作台 | **终端会话、标签、搜索与 Shell 配置**<br><sub>terminal</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Terminal`、`macos/Sources/Lithe/Services`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/terminal`、`windows/tauri/src-tauri`</sub> | Terminal | 验证默认 Shell、多个会话、调整大小、复制粘贴、搜索、关闭和子进程清理。 |
| 编辑器 | **Markdown 预览、富文本渲染与图片处理**<br><sub>markdown-preview</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Editor/MarkdownPreviewView.swift`、`macos/Sources/Lithe/Core/Ports/MarkdownRendering.swift`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/editor/markdown`、`windows/tauri/src/features/viewer`</sub> | Editor | 用包含 Mermaid、代码高亮、表格、图片和相对链接的 Markdown 对比渲染结果。 |
| 工作台 | **本地历史与项目快照恢复**<br><sub>local-history</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/History`、`macos/Sources/Lithe/Services`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/local-history`</sub> | Local History | 编辑同一文件多次，验证快照列表、Diff、恢复、删除和重启后持久化。 |
| 数据库 | **数据库连接、SQL、Schema、表浏览与数据操作**<br><sub>database</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Database`、`macos/Sources/Lithe/Services`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/database`</sub> | Database | 使用各支持数据库验证连接、SQL 历史、分页、表结构和 CRUD。 |
| 发行与更新 | **应用内更新、更新清单与回滚策略**<br><sub>updates</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/App/UpdateControl.swift`、`macos/Sources/Lithe/Platform/MacOS/Updates`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/layout/components/app-update-control.tsx`、`windows/tauri/src/features/settings/hooks/use-updater.ts`、`docs/releases/windows-updater.md`</sub> | Release | 分别使用 preview 更新清单验证检查、下载、失败、重试、重启和版本回退。 |
| 社区 | **LINUX DO 社区浏览**<br><sub>community</sub> | ✅ 已实现<br><sub>`macos/Sources/Lithe/Views/Community`、`macos/Sources/Lithe/Application/Features/Community`</sub> | ❌ 未实现<br><sub>`windows/tauri/src/features`</sub> | Community | Windows 需要补充功能入口和统一的 Discourse 请求/认证契约。 |
| Windows 专属 | **WSL 文件与工作区集成**<br><sub>wsl</sub> | 🧩 平台专属<br><sub>`macos/Sources/Lithe`</sub> | ✅ 已实现<br><sub>`windows/tauri/src/features/wsl`、`windows/tauri/src/features/file-system`</sub> | Windows Platform | Windows 验证本地文件、WSL 文件、跨发行版和跨边界移动/重命名的错误提示。 |

## 使用规则

1. 功能开发或修复的 PR 必须更新对应项的状态、证据路径和验证方式；如果两端行为只差 UI，不要标成未实现，应在验证方式中写清差异。
2. `已实现` 只表示两端都有代码入口和产品接入，不等于本机已经完成跨平台运行验证；真实运行结果用 `待验证` 或 PR 验证记录补充。
3. 新的共享行为先更新 `shared/contracts/` 和 fixture，再把矩阵状态从 `待验证` 推进到 `已实现`。
4. 每次发布前生成此页并检查 `未实现`、`部分实现` 和 `待验证` 项，避免 macOS 新功能无意中成为 Windows 隐藏缺口。
