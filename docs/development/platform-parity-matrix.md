# macOS / Windows 功能对齐矩阵

> 本页由 `shared/platform-feature-matrix.json` 自动生成。不要直接编辑本文件；新增或变更功能时更新源数据，再运行 `node scripts/generate-platform-feature-matrix.mjs`。

- 最后复核：2026-09-24
- 盘点状态：initial-static-inventory（根据 macOS Views/Application/Services、Windows features/extensions 和共享契约的代码入口进行初版盘点；未替代真实运行验收。）
- 功能项：82
- macOS：实现：✅ 70 已实现，🟡 3 部分实现，❌ 7 未实现，🧩 2 平台专属；验证：✔️ 0 已验证，🔍 73 待验证，— 9 不适用
- Windows：实现：✅ 76 已实现，🟡 4 部分实现，❌ 2 未实现，🧩 0 平台专属；验证：✔️ 0 已验证，🔍 80 待验证，— 2 不适用

## 实现状态定义

| 状态 | 含义 |
| --- | --- |
| ✅ 已实现<br><sub>implemented</sub> | 代码入口和产品接入均已存在。 |
| 🟡 部分实现<br><sub>partial</sub> | 已有实现，但范围、入口、平台能力或用户体验仍不完全一致。 |
| ❌ 未实现<br><sub>missing</sub> | 当前没有足够的实现入口或产品接入证据。 |
| 🧩 平台专属<br><sub>platform-specific</sub> | 刻意只属于某个平台，不以跨平台对齐为目标。 |

## 验证状态定义

| 状态 | 含义 |
| --- | --- |
| ✔️ 已验证<br><sub>verified</sub> | 已按该能力点的验证方式完成运行时验证。 |
| 🔍 待验证<br><sub>pending</sub> | 静态代码无法替代运行时验证，仍需按验证方式确认。 |
| — 不适用<br><sub>not-applicable</sub> | 当前没有可运行的实现入口，暂不适用运行时验证。 |

## 功能矩阵

> 每一行对应一个可以单独验收的用户能力；区域和功能组只用于导航，不作为状态统计单位。单元格第一行是实现状态，第二行是验证状态。

<details>
<summary><strong>工作区</strong> · 7 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 工作区生命周期 | **打开工作区与切换项目**<br><sub>workspace-open-switch</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workspace`、`macos/Sources/Lithe/Services/Workspace`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/workspace`</sub> | Workspace | 打开多个项目并在项目之间切换，确认当前项目、文件树和编辑器状态正确。 |  |
| 工作区生命周期 | **文件树与文件操作**<br><sub>workspace-files</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workspace`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/file-system`</sub> | Workspace | 新建、移动、重命名、删除文件和目录，并确认相对路径与错误提示一致。 |  |
| 工作区生命周期 | **脏状态、保存与外部修改**<br><sub>workspace-document-sync</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Models/Editor`、`macos/Sources/Lithe/Services/Workspace`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/editor`、`windows/tauri/src/features/file-system`</sub> | Workspace | 编辑未保存文件、外部修改文件并重启应用，确认冲突、保存和恢复行为。 |  |
| 工作区生命周期 | **多项目与多标签**<br><sub>workspace-tabs-projects</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workspace`、`macos/Sources/Lithe/Views/Editor`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/workspace`、`windows/tauri/src/features/tabs`</sub> | Workspace | 同时打开多个项目和文件，确认标签、项目上下文和关闭恢复行为。 |  |
| 项目浏览 | **项目文件树与资源打开**<br><sub>file-explorer</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workspace/ProjectSidebarView.swift`、`macos/Sources/Lithe/Models/Workspace`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/file-explorer`、`windows/tauri/src/features/sidebar`</sub> | Workspace | 浏览目录、展开/折叠、打开资源并在文件变更后刷新树。 |  |
| 项目浏览 | **项目依赖与模块浏览**<br><sub>dependency-browser</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workspace/DependencySidebarView.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/maven`、`windows/tauri/src/features/sidebar`</sub> | Workspace / Java | 打开 Maven 项目依赖和模块树，验证导航、刷新和空项目状态。 |  |
| 远程开发 | **远程连接与远程路径工作区**<br><sub>remote-workspace</sub> | ❌ 未实现<br><sub>— 不适用</sub><br><sub>`macos/Sources/Lithe/Services`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/remote`、`windows/tauri/src/features/file-system`</sub> | Remote | Windows 验证连接、密码提示、远程路径、断线和重连；macOS 需要补充产品入口或明确不支持。 |  |

</details>

<details>
<summary><strong>编辑器</strong> · 11 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 文本编辑 | **文本编辑与标签生命周期**<br><sub>editor-text-tabs</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Editor`、`macos/Sources/Lithe/Models/Editor`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/editor`、`windows/tauri/src/features/tabs`</sub> | Editor | 打开、编辑、保存、关闭和恢复多个文本文件，确认光标、脏状态和标签状态。 |  |
| 文本编辑 | **语法高亮与编辑器模型**<br><sub>editor-language-basics</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Editor`、`macos/Sources/Lithe/Models/Editor`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/editor`、`frontend/editor`、`windows/tauri/src/features/editor/engines/monaco/theme.ts`</sub> | Editor | 分别打开 Java、Markdown 和普通文本，确认语言识别、语法高亮和模型切换；开启缩略图并滚动，确认滚动条轨道不透出编辑器代码。 |  |
| 文本编辑 | **多行标签与标签导航**<br><sub>editor-multiline-tabs</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Editor`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/tabs`</sub> | Editor | 打开足够多文件触发多行标签，确认滚动、切换、关闭和活动文件保持。 |  |
| Markdown | **Markdown 预览与富文本渲染**<br><sub>markdown-rendering</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Editor/MarkdownPreviewView.swift`、`macos/Sources/Lithe/Core/Ports/MarkdownRendering.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/editor/markdown`</sub> | Editor | 使用代码高亮、表格、Mermaid、链接和相对路径 fixture 对比渲染结果。 |  |
| Markdown | **图片导入与链接定位**<br><sub>markdown-images-links</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Services/Markdown`、`macos/Sources/Lithe/Platform/MacOS/MarkdownPreviewWebView.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/editor/markdown`、`windows/tauri/src/features/viewer`</sub> | Editor | 验证本地图片、远程图片、相对链接和打开源文件行为。 |  |
| 代码结构 | **当前文件 Outline 与符号树**<br><sub>outline-symbols</sub> | 🟡 部分实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Language`、`macos/Sources/Lithe/Views/Search`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/outline`</sub> | Language Tooling | 使用 Java 文件验证符号树、展开折叠、排序和跳转；确认 macOS 是否提供同等独立 Outline 入口。 |  |
| 代码结构 | **引用结果面板与引用跳转**<br><sub>references-pane</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Language/JavaReferencesView.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/references`</sub> | Language Tooling | 从符号发起引用查询，验证结果分组、文件定位、关闭和重新查询。 |  |
| 资源预览 | **HTML、SVG、媒体、PDF 与二进制预览**<br><sub>embedded-viewers</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Editor/HTMLPreviewView.swift`、`macos/Sources/Lithe/Views/Editor/MediaViewerView.swift`、`macos/Sources/Lithe/Views/Editor/SVGPreviewView.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/viewer`</sub> | Editor | 分别打开 HTML、SVG、图片、PDF 和二进制文件，验证缩放、错误和源文件返回。 |  |
| 编辑模式 | **Vim 模式与命令状态**<br><sub>vim-mode</sub> | ❌ 未实现<br><sub>— 不适用</sub><br><sub>`macos/Sources/Lithe/Views/Editor`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/vim`、`windows/tauri/src/features/editor`</sub> | Editor | Windows 验证 Normal/Insert/Visual 模式、命令执行和设置持久化；macOS 需要确认产品范围。 |  |
| 文本编辑 | **按指定编码重新打开文本文件**<br><sub>editor-file-encoding-reopen</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workbench/WorkbenchView.swift`、`macos/Sources/Lithe/Views/Editor/StandaloneEditorView.swift`、`macos/Sources/Lithe/Application/Features/DocumentFeatureModel.swift`、`macos/Sources/Lithe/Platform/MacOS/FileSystem/MacDocumentEncoding.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/command-palette/components/encoding-picker.tsx`、`windows/tauri/src/features/editor/services/document-encoding-workflow.ts`、`windows/tauri/crates/project/src/document_file.rs`</sub> | Editor | 在 macOS 和 Windows 实机验证 UTF-8、UTF-8 BOM 与 GBK/GB18030 的自动识别，并分别验证 Shift JIS、Windows-1252 的指定编码重新打开、编码转换保存、脏文件选择和外部修改保护。 |  |
| 文本编辑 | **按指定编码保存文本文件**<br><sub>editor-file-encoding-save</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workbench/WorkbenchView.swift`、`macos/Sources/Lithe/Views/Editor/StandaloneEditorView.swift`、`macos/Sources/Lithe/Application/Features/DocumentFeatureModel.swift`、`macos/Sources/Lithe/Platform/MacOS/FileSystem/MacDocumentEncoding.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/command-palette/components/encoding-picker.tsx`、`windows/tauri/src/features/editor/stores/editor-app.store.ts`、`windows/tauri/crates/project/src/document_file.rs`</sub> | Editor | 在 macOS 和 Windows 实机验证 UTF-8、UTF-8 BOM 与 GBK/GB18030 的自动识别，并分别验证 Shift JIS、Windows-1252 的指定编码重新打开、编码转换保存、脏文件选择和外部修改保护。 |  |

</details>

<details>
<summary><strong>搜索</strong> · 4 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 搜索与导航 | **快速打开文件与符号**<br><sub>search-quick-open</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Search`、`macos/Sources/Lithe/Views/Workbench`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/quick-open`</sub> | Search | 使用文件名、路径和符号查询，确认排序、键盘导航和打开位置。 |  |
| 搜索与导航 | **项目范围文本搜索**<br><sub>search-project</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Search`、`macos/Sources/Lithe/Services/Language`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/file-search`</sub> | Search | 使用同一项目和查询 fixture 对比命中路径、行号、列号和结果排序。 |  |
| 搜索与导航 | **全局命令与设置搜索**<br><sub>search-global</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Search`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/global-search`、`windows/tauri/src/features/command-palette`</sub> | Search | 使用快捷键搜索命令、设置和工作区内容，确认结果来源和跳转行为。 |  |
| 搜索与导航 | **项目替换与取消**<br><sub>search-replace</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Search`、`macos/Sources/Lithe/Services/Language`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/file-search`</sub> | Search | 执行替换预览、确认替换和取消操作，确认未保存文件与异常文件不会被静默覆盖。 |  |

</details>

<details>
<summary><strong>版本控制</strong> · 7 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| Git | **状态、暂存与提交**<br><sub>git-status-commit</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Git`、`macos/Sources/Lithe/Services`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/git`、`shared/contracts/application-boundary.md`</sub> | Git | 修改、暂存、取消暂存并提交文件，确认状态、提交消息和错误回显。 |  |
| Git | **分支、标签与远程**<br><sub>git-branches-remotes</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Git`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/git`</sub> | Git | 创建、切换、合并分支并查看标签和远程，确认冲突与认证失败可恢复。 |  |
| Git | **Diff 与变更审查**<br><sub>git-diff-review</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Git`、`macos/Sources/Lithe/Views/Diff`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/git`、`windows/tauri/src/features/viewer`</sub> | Git | 验证新增、删除、重命名、二进制和多文件 Diff 的展示与定位；从源代码管理打开已修改和未跟踪文件的工作区 Diff 后保持静止，确认 Diff 不会自动关闭，且只在文件不再出现在 Git 状态中时关闭。 |  |
| Git | **提交历史与图谱**<br><sub>git-history</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Git`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/git`</sub> | Git | 分页浏览提交历史、分支图谱和提交详情，确认日期、作者和文件列表一致。 |  |
| Git | **Rebase 与 Stash**<br><sub>git-rebase-stash</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Git`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/git`</sub> | Git | 执行交互式 Rebase 和 Stash 保存/恢复，确认中断、冲突和继续操作。 |  |
| Git | **Worktree 管理**<br><sub>git-worktrees</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Git`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/git`</sub> | Git | 列出、创建、切换和删除 Worktree，确认路径、分支和安全检查。 |  |
| Git | **多仓库引用面板：分组、配色与引用操作**<br><sub>git-multi-repository-references</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Git`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/git`</sub> | Git | 在多仓库工作区打开 Git Log：确认按仓库分组、仓库配色、非活动仓库分组只读，点其它仓库的引用会切换活动仓库且只加载一次，Pull 弹窗可选择远程分支与策略。 |  |

</details>

<details>
<summary><strong>协作</strong> · 2 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| GitHub | **Pull Request 列表与详情**<br><sub>github-prs</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/GitHub`、`macos/Sources/Lithe/Services/GitHub`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/github`、`shared/contracts/application-boundary.md`</sub> | GitHub | 使用测试仓库验证 PR 列表、筛选、详情、分支比较和浏览器跳转。 |  |
| GitHub | **Review 与评论**<br><sub>github-reviews-comments</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/GitHub`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/github`</sub> | GitHub | 创建、查看和回复 Review/评论，确认权限错误和网络失败不会丢失草稿。 |  |

</details>

<details>
<summary><strong>AI</strong> · 4 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| AI 提交信息 | **Provider 配置与提交信息生成**<br><sub>ai-commit-generation</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Application/Features/CommitWorkflowCoordinator.swift`、`macos/Sources/Lithe/Platform/MacOS/AI`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/git/services/ai-commit-service.ts`、`shared/contracts/ai-commit.md`</sub> | Git / AI | 用相同 diff、规则和 Provider 配置比较请求计划、取消、错误和生成文本。 |  |
| AI 对话 | **对话会话与流式响应**<br><sub>ai-chat-session</sub> | ❌ 未实现<br><sub>— 不适用</sub><br><sub>`macos/Sources/Lithe/Platform/MacOS/AI`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/ai/components/chat/ai-chat.tsx`、`windows/tauri/src/features/ai/services/ai-chat-service.ts`</sub> | AI | Windows 验证新建会话、流式输出、取消和失败恢复；macOS 需要先定义产品范围。 |  |
| AI 对话 | **对话历史、置顶与归档**<br><sub>ai-chat-history</sub> | ❌ 未实现<br><sub>— 不适用</sub><br><sub>`macos/Sources/Lithe/Platform/MacOS/AI`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/ai/services/ai-chat-history-service.ts`、`windows/tauri/src/features/layout/components/sidebar/sidebar-history.tsx`</sub> | AI | Windows 验证历史加载、重命名、置顶、归档、删除和重启后持久化。 |  |
| AI 对话 | **多 Provider 与工作区范围**<br><sub>ai-chat-providers</sub> | ❌ 未实现<br><sub>— 不适用</sub><br><sub>`macos/Sources/Lithe/Platform/MacOS/AI`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/ai/services/providers`、`windows/tauri/src/features/ai/lib/ai-workspace-scope.ts`</sub> | AI | Windows 验证 Provider 切换、凭据边界、工作区范围和模型错误提示。 |  |

</details>

<details>
<summary><strong>Java</strong> · 12 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| Java/Maven | **JDK 与 Maven 工具链发现**<br><sub>java-runtime-discovery</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Services/Java`、`macos/Sources/Lithe/Views/Run`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/maven`、`windows/tauri/src/features/workspace`</sub> | Java / Maven | 配置多个 JDK/Maven 候选，验证发现、选择、版本不匹配和错误提示。 |  |
| Java/Maven | **项目根、模块与源码集识别**<br><sub>java-maven-project</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Services/Java`、`shared/contracts/application-boundary.md`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/maven`、`windows/tauri/src/features/workspace`</sub> | Java / Maven | 使用单模块、多模块和非标准源码目录 fixture 对比项目模型。 |  |
| Java/Maven | **Profile 与依赖树**<br><sub>java-maven-profiles-dependencies</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Run`、`macos/Sources/Lithe/Services/Java`、`macos/Sources/LitheExecutionModule/Services/MavenService.swift`、`macos/Sources/Lithe/Platform/MacOS/Persistence/MacMavenDependencyOutputStore.swift`、`rust/lithe-core/src/project/maven_dependency_tree.rs`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/maven`、`windows/tauri/src-tauri/src/maven.rs`、`rust/lithe-core/src/project/maven_dependency_tree.rs`</sub> | Java / Maven | 切换 Maven profile 并刷新依赖树，确认模块归属、顺序、版本冲突/重复/依赖管理标注和错误边界；在依赖节点超过 6,000 个的项目中确认依赖树完整加载。 |  |
| Java/Maven | **Maven 工具栏图标悬停说明**<br><sub>java-maven-toolbar-tooltips</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Run/MavenView.swift`、`macos/Sources/Lithe/Views/Workbench/WorkbenchHoverTooltip.swift`、`macos/Tests/LitheTests/WorkbenchHoverTooltipTests.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/maven/components/maven-pane.tsx`</sub> | Java / Maven | 在 macOS 和 Windows 的 Maven 工具窗口逐一悬停运行、执行目标、重新加载、跳过测试、折叠和设置图标，确认提示与动作一致、提示框宽度适配文字；再检查禁用按钮和窄窗口中的提示换行与边缘约束。 |  |
| Java/Maven | **构建输出与编译诊断**<br><sub>java-build-diagnostics</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Run`、`macos/Sources/Lithe/Services/Diagnostics`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/maven`、`windows/tauri/src/features/diagnostics`</sub> | Java / Maven | 使用成功、编译失败和进程失败构建 fixture，对比诊断位置、输出和退出状态。 |  |
| Spring / MyBatis | **Spring 配置、Bean 与 Endpoint 索引**<br><sub>spring-index</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Application/Features`、`macos/Sources/Lithe/Views/Run`、`shared/fixtures/spring`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/spring`、`shared/fixtures/spring`</sub> | Java / Spring | 使用 Spring fixture 对比配置、Bean、Endpoint 索引、刷新和失效处理。 |  |
| Spring / MyBatis | **Spring 符号导航与代码关联**<br><sub>spring-navigation</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Application/Features`、`macos/Sources/Lithe/Views/Language`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/spring`</sub> | Java / Spring | 从 Bean、配置和 Endpoint 结果跳转到源代码并返回，确认行列号一致。 |  |
| Spring / MyBatis | **MyBatis Mapper/XML 导航**<br><sub>mybatis-navigation</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Application/Features/MybatisFeatureModel.swift`、`macos/Sources/Lithe/Application/Composition/DocumentFeatureComposition.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/mybatis`</sub> | Java / MyBatis | 使用 Mapper/XML fixture 对比索引、导航、文件变更刷新和失效处理。 |  |
| 语言服务 | **LSP/JDTLS 启动与工作区准备**<br><sub>lsp-lifecycle</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Core/Language`、`macos/Sources/Lithe/Services/Language`、`rust/lithe-core/src/lsp/languages/jdt_configuration.rs`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features`、`windows/tauri/src-tauri/src/lsp.rs`、`rust/lithe-core/src/lsp/languages/jdt_configuration.rs`、`shared/fixtures/lsp`</sub> | Language Tooling | 在两端启动真实 JDTLS，验证项目准备、重启、超时、取消和资源清理，并确认典型工作流后已安装程序包（macOS app bundle、Windows 安装目录）的文件清单不变。 |  |
| 语言服务 | **补全与 Hover**<br><sub>lsp-completion-hover</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Core/Language`、`shared/fixtures/lsp`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features`、`shared/fixtures/lsp`</sub> | Language Tooling | 在相同 Java fixture 中验证补全、Hover、排序、超时和空结果。 |  |
| 语言服务 | **诊断与编译错误定位**<br><sub>lsp-diagnostics</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Core/Language`、`macos/Sources/Lithe/Services/Diagnostics`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/diagnostics`、`shared/fixtures/lsp`</sub> | Language Tooling | 制造语法和类型错误，比较诊断等级、消息、行列号和清理行为。 |  |
| 语言服务 | **跳转、引用、语义标记与编辑**<br><sub>lsp-navigation-edits</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Core/Language`、`shared/contracts/rust-core-api.md`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features`、`shared/fixtures/lsp`</sub> | Language Tooling | 验证定义、引用、语义标记和 UTF-16 文本编辑的坐标转换。 |  |

</details>

<details>
<summary><strong>运行与调试</strong> · 6 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 运行配置 | **入口点与运行配置发现**<br><sub>run-discovery</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Run`、`shared/fixtures/run-configuration`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/run`、`shared/fixtures/run-configuration`</sub> | Run | 验证 Spring Boot、Java、Maven、Gradle、npm、Cargo、Go、Python 和 Docker Compose 入口识别；多模块项目把服务工作目录改成模块目录后，服务仍留在列表中并以该目录启动；填写不存在的目录或 ${workspaceFolder} 等变量时，保存被拒绝并提示原因。 |  |
| 运行配置 | **保存前同步与工具链解析**<br><sub>run-save-toolchain</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Run`、`macos/Sources/Lithe/Services/Java`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/run`、`windows/tauri/src/features/maven`</sub> | Run | 修改未保存文件后运行，验证同步、JDK/Maven 选择和版本不匹配诊断。 |  |
| 运行配置 | **Java main 与测试运行**<br><sub>run-java-test</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Run`、`shared/fixtures/debug`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/run`、`shared/fixtures/debug`</sub> | Run | 运行 main、单测试和测试类，验证参数、输出、失败状态和终端策略。 |  |
| 调试器 | **启动调试与断点**<br><sub>debug-breakpoints</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Debug`、`shared/fixtures/debug`</sub> | 🟡 部分实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/debugger`、`shared/fixtures/debug`</sub> | Debug | 设置、命中、禁用和重新定位断点，确认调试会话生命周期。 | Windows 真实调试产品链路仍在 #466 跟进。 |
| 调试器 | **变量、异常与断开策略**<br><sub>debug-state</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Debug`、`shared/fixtures/debug`</sub> | 🟡 部分实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/debugger`、`shared/fixtures/debug`</sub> | Debug | 验证变量分页、异常信息、step filters、暂停/继续和 disconnect policy。 | Windows 真实调试产品链路仍在 #466 跟进。 |
| 项目运行 | **Docker / Compose 项目识别与运行**<br><sub>docker-compose</sub> | 🟡 部分实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Run/RunConfigurationIcon.swift`、`macos/Sources/Lithe/Services/Java`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/docker`、`windows/tauri/src/features/run`</sub> | Run / Docker | 使用 Dockerfile 和 Compose fixture 验证识别、命令参数、输出和进程停止；确认 macOS 是否只有入口识别。 |  |

</details>

<details>
<summary><strong>工作台</strong> · 9 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 终端 | **Shell 发现与配置**<br><sub>terminal-shell</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Terminal`、`macos/Sources/Lithe/Services`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/terminal`、`windows/tauri/src-tauri`</sub> | Terminal | 验证默认 Shell、环境变量、工作目录和不可用 Shell 的错误提示。 |  |
| 终端 | **多会话与标签**<br><sub>terminal-sessions</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Terminal`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/terminal`</sub> | Terminal | 创建多个终端会话并切换、重命名、关闭，确认子进程生命周期和资源清理。 |  |
| 终端 | **复制粘贴、搜索与调整大小**<br><sub>terminal-interaction</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Terminal`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/terminal`</sub> | Terminal | 验证复制粘贴、终端搜索、调整面板大小和高频输入不丢失。 |  |
| 本地历史 | **快照列表与 Diff**<br><sub>history-snapshots</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/History`、`macos/Sources/Lithe/Services`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/local-history`</sub> | Local History | 编辑同一文件多次，比较快照时间、内容 Diff 和文件范围。 |  |
| 本地历史 | **恢复、删除与持久化**<br><sub>history-restore</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/History`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/local-history`</sub> | Local History | 验证恢复、删除、应用重启后持久化和失败回滚。 |  |
| 命令与布局 | **命令面板与全局动作**<br><sub>command-palette</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Models/Keymap/LitheCommandCatalog.swift`、`macos/Sources/Lithe/Views/Search/SearchEverywhereView.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/command-palette`</sub> | Workbench | 搜索并执行打开面板、运行、Git 和设置命令，确认快捷键和不可用命令状态。 |  |
| 命令与布局 | **分栏、面板与工具窗布局**<br><sub>workbench-panes</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workbench`、`macos/Sources/Lithe/Views/Components/LitheSplitPaneView.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/panes`、`windows/tauri/src/features/layout`</sub> | Workbench | 打开、关闭、移动和调整面板，验证布局持久化及高频拖动稳定性；在 macOS 启用背景图后检查项目栏、编辑器、底部及右侧工具窗之间是否仍有清晰的分割区间。 |  |
| 工作台布局 | **活动栏图标的稳定悬停说明**<br><sub>workbench-activity-tooltips</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workbench/WorkbenchHoverTooltip.swift`、`macos/Sources/Lithe/Views/Workbench/WorkbenchView.swift`、`macos/Tests/LitheTests/WorkbenchHoverTooltipTests.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/layout/components/sidebar/sidebar-pane-selector.tsx`、`windows/tauri/src/features/layout/components/footer/footer-tab-control.tsx`、`windows/tauri/src/features/layout/components/plugin-activity-rail.tsx`</sub> | Workbench | 逐一悬停左上导航、左下工具入口及右侧通知/插件/Maven，快速切换图标并移出活动栏；确认始终只显示当前图标说明，面板更新和滚动后不残留旧提示，禁用入口可显示说明，短文字自适应且提示不超出窗口边缘。 |  |
| 工作台布局 | **活动栏贴合窗口外沿**<br><sub>workbench-activity-rail-window-edge</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Workbench/WorkbenchView.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/layout/components/main-layout.tsx`、`windows/tauri/src/features/layout/components/plugin-activity-rail.tsx`、`windows/tauri/src/features/layout/components/sidebar/main-sidebar.tsx`</sub> | Workbench | 打开工作区，检查左右活动栏与窗口外沿齐平，外侧没有留白、圆角或边框；缩放窗口并切换活动面板后确认布局仍贴边。 |  |

</details>

<details>
<summary><strong>数据库</strong> · 4 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 数据库工作区 | **连接配置与 Provider**<br><sub>database-connections</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Database`、`macos/Sources/Lithe/Services`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/database`</sub> | Database | 创建、编辑、测试和删除各支持数据库连接，确认凭据和错误边界。 |  |
| 数据库工作区 | **Schema、表与列浏览**<br><sub>database-schema</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Database`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/database`</sub> | Database | 展开数据库、Schema、表和列，验证刷新、筛选和空结果展示。 |  |
| 数据库工作区 | **SQL 查询、历史与分页**<br><sub>database-query-history</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Database`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/database`</sub> | Database | 执行查询、取消查询、查看 SQL 历史和分页结果，确认长结果不阻塞界面。 |  |
| 数据库工作区 | **表数据编辑、CRUD 与导出**<br><sub>database-crud-export</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Database`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/database`</sub> | Database | 验证新增、编辑、删除、事务失败、复制和结果导出。 |  |

</details>

<details>
<summary><strong>可观测性</strong> · 4 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 诊断与日志 | **工作区诊断与问题面板**<br><sub>diagnostics-workspace</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Application/Features/DiagnosticsFeatureModel.swift`、`macos/Sources/Lithe/Views/Language/JavaProblemsView.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/diagnostics`、`windows/tauri/src/features/logging`、`windows/tauri/src/ui/dialog.tsx`</sub> | Diagnostics | 制造多个来源的错误和警告，验证筛选、排序、定位和清除。 |  |
| 诊断与日志 | **诊断包导出与脱敏**<br><sub>diagnostics-export</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/Diagnostics/DiagnosticsExportSheet.swift`、`macos/Sources/Lithe/Services/Diagnostics`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/diagnostics`</sub> | Diagnostics | 导出诊断包，确认敏感路径、凭据和大文件被正确脱敏或限制；检查预览说明和文件列表在确认弹窗内完整显示、长内容正常换行且不溢出。 |  |
| 通知与资源 | **操作通知、错误提示与自动消失**<br><sub>workbench-notifications</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Application/Features/WorkbenchNotificationFeatureModel.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/notifications`</sub> | Workbench | 触发成功、警告和失败通知，验证队列、关闭、超时和重复通知。 |  |
| 通知与资源 | **应用与语言服务内存监控**<br><sub>memory-monitor</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Services/Monitoring/MemoryUsageMonitor.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/layout/services/memory-api.ts`、`windows/tauri/src/platform/tauri-core.ts`</sub> | Workbench | 打开内存指标并观察应用、语言服务和总内存变化，确认采样失败不会阻塞工作台。 |  |

</details>

<details>
<summary><strong>设置</strong> · 2 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 应用配置 | **应用、项目与运行设置**<br><sub>application-settings</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/LitheApp.swift`、`macos/Sources/Lithe/Views/App/SettingsView.swift`、`macos/Sources/Lithe/Views/App/ProjectRuntimeSettingsView.swift`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/settings`</sub> | Settings | 修改应用级和项目级设置，验证持久化、迁移、重启恢复和无效值提示；macOS 保持设置窗口打开切换亮色、暗色和跟随系统模式，并改变系统外观，确认标题栏与面板背景同色、窗口按钮可用且可拖动；关闭后重开再检查。 |  |
| 应用配置 | **快捷键查看与自定义**<br><sub>keymap-customization</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/App/KeyboardShortcutSettingsView.swift`、`macos/Sources/Lithe/Models/Keymap`</sub> | 🟡 部分实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/keymaps`</sub> | Settings | 修改快捷键、制造冲突并恢复默认，确认命令实际执行。 | Windows 快捷键设置仍有占位交互，见 #718。 |

</details>

<details>
<summary><strong>扩展</strong> · 1 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 插件与主题 | **插件、语言服务与主题管理**<br><sub>plugin-extension-management</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/App/PluginManagementView.swift`、`macos/Sources/Lithe/Platform/MacOS/Plugins`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/extensions`、`windows/tauri/src/features/settings`</sub> | Extensions | 启用、禁用和恢复插件/主题，确认启动加载、失败隔离和设置持久化。 |  |

</details>

<details>
<summary><strong>启动与窗口</strong> · 1 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 首次启动 | **欢迎页、项目入口与首次启动引导**<br><sub>onboarding-welcome</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/App/WelcomeView.swift`、`macos/Sources/Lithe/Views/Workspace`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/onboarding`、`windows/tauri/src/features/bootstrap`</sub> | Onboarding | 清空首次启动状态，验证打开项目、克隆项目、最近项目和跳过引导。 |  |

</details>

<details>
<summary><strong>发行与更新</strong> · 2 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 应用更新 | **检查、下载与安装更新**<br><sub>updates-check-download</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Views/App/UpdateControl.swift`、`macos/Sources/Lithe/Platform/MacOS/Updates`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/layout/components/app-update-control.tsx`、`windows/tauri/src/features/settings/hooks/use-updater.ts`</sub> | Release | 使用 preview 更新清单验证检查、下载、校验、安装和重启。 |  |
| 应用更新 | **失败重试与回滚**<br><sub>updates-failure-rollback</sub> | 🟡 部分实现<br><sub>🔍 待验证</sub><br><sub>`macos/Sources/Lithe/Platform/MacOS/Updates`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`docs/releases/windows-updater.md`、`windows/tauri/src/features/settings/hooks/use-updater.ts`</sub> | Release | 模拟清单错误、下载失败和安装失败，确认重试、回滚和用户提示。 | macOS 回退更新方案仍在 #734 跟进。 |

</details>

<details>
<summary><strong>社区</strong> · 2 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| LINUX DO 社区 | **主题列表与详情**<br><sub>community-feed</sub> | ❌ 未实现<br><sub>— 不适用</sub><br><sub>`macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginPackageStore.swift`</sub> | ❌ 未实现<br><sub>— 不适用</sub><br><sub>`windows/tauri/src/features`</sub> | Community | 如果重新引入社区入口，在 macOS 和 Windows 验证 Latest/Top、主题详情、分页和浏览器跳转。 | macOS 的 LINUX DO 插件已退役，当前两端均无社区入口。 |
| LINUX DO 社区 | **社区认证与请求失败处理**<br><sub>community-auth</sub> | ❌ 未实现<br><sub>— 不适用</sub><br><sub>`macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginPackageStore.swift`、`shared/fixtures/community`</sub> | ❌ 未实现<br><sub>— 不适用</sub><br><sub>`windows/tauri/src/features`</sub> | Community | 如果重新引入社区入口，在 macOS 和 Windows 验证认证、过期、限流和网络错误。 | macOS 的 LINUX DO 插件已退役，现存 fixture 不代表产品接入。 |

</details>

<details>
<summary><strong>Windows 专属</strong> · 2 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| WSL | **WSL 文件与工作区路径**<br><sub>wsl-paths</sub> | 🧩 平台专属<br><sub>— 不适用</sub><br><sub>`macos/Sources/Lithe`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/wsl`、`windows/tauri/src/features/file-system`</sub> | Windows Platform | Windows 验证本地文件、WSL 文件、发行版识别和工作区打开。 |  |
| WSL | **跨 WSL 边界移动与重命名**<br><sub>wsl-boundaries</sub> | 🧩 平台专属<br><sub>— 不适用</sub><br><sub>`macos/Sources/Lithe`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`windows/tauri/src/features/wsl`、`windows/tauri/src/features/file-system`</sub> | Windows Platform | Windows 验证本地、同发行版、跨发行版移动/重命名及明确错误提示。 |  |

</details>

<details>
<summary><strong>语言支持</strong> · 2 个能力点</summary>

| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| PHP | **PHP 按需安装与插件生命周期**<br><sub>php-optional-plugin</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`Plugins/mac/Official/PhpSupport`、`scripts/official-plugin-distribution.mjs`、`macos/Sources/Lithe/Platform/MacOS/Plugins`</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`Plugins/win/Official/PhpSupport`、`windows/tauri/src/extensions/registry/extension-store-lifecycle.ts`、`windows/tauri/src-tauri/src/language_tools.rs`、`windows/tauri/src/extensions/packages/local-extension-package.ts`、`scripts/verify-windows-plugin-isolation.mjs`</sub> | PHP Support | 在干净安装上确认没有 PHP 插件运行时；显式安装并启用后验证补全、诊断，安装中取消、运行中禁用、关闭工作区和卸载后确认无插件进程，用户工具保留。 Windows 从独立 .lithe-extension 文件导入，默认禁用；启用后重启确认能恢复，卸载后重启确认不恢复。 |  |
| PHP | **PHP 插件运行与 PHPUnit 测试**<br><sub>php-run-test</sub> | ✅ 已实现<br><sub>🔍 待验证</sub><br><sub>`Plugins/mac/Official/PhpSupport/Sources/LithePhpSupportModule/Capabilities/PhpExecutionCapability.swift`、`macos/Tests/LitheTests/RealPhpIntegrationTests.swift`</sub> | 🟡 部分实现<br><sub>🔍 待验证</sub><br><sub>`Plugins/win/Official/PhpSupport/plugin.ts`、`windows/tauri/src/extensions/run`、`windows/tauri/src/extensions/ui/services/ui-extension-worker-runtime.test.ts`</sub> | PHP Support | macOS 运行 PHP 文件和单条/整套 PHPUnit；Windows 运行字符串/数组 Composer script 和整套 PHPUnit。禁用后菜单消失、运行进程退出，特殊文件名保持原样。Windows 暂不支持单方法发现。 |  |

</details>


## 使用规则

1. 功能开发或修复的 PR 必须更新对应能力点的实现状态、验证状态、证据路径和验证方式；如果一项功能包含多个独立用户动作，应拆成多行。
2. `implementationStatus` 和 `verificationStatus` 分别表达实现程度和运行验证结果；只有实现状态为 `implemented` 且验证状态为 `verified` 才能表示已完成验收。
3. 代码入口存在但没有真实运行验证时，保留实现状态并将验证状态设为 `pending`；不要把静态盘点写成 `verified`。
4. 新的共享行为先更新 `shared/contracts/` 和 fixture，再按验证方式完成两端验证后将验证状态推进到 `verified`。
5. 功能 PR 必须同时包含源数据变更；纯重构如确实没有用户可观察变化，可由 reviewer 添加 `matrix-exempt` label 作为显式例外。
