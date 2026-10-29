# Agent 笔记：Windows 文件夹终端复用底部面板入口

状态：已实现

## 先说结论

Windows 文件树的“在终端中打开”和工具栏、菜单、快捷键都在底部终端面板创建会话。文件夹入口通过既有 `terminal-new` 事件携带工作目录，底部终端组件继续负责会话、默认 Shell 和启动配置；不要从文件树直接创建编辑区终端标签。

## 问题

文件夹右键原来调用编辑器的 `openTerminalBuffer`，全局入口则创建底部终端。因此用户没有拖动窗口，也会因入口不同看到终端出现在不同位置。仅把终端移到底部还不够：若丢失所选目录，或被自定义启动配置里的目录覆盖，命令会在错误位置执行。

## 决策

- 文件夹动作同步发送带 `workingDirectory` 的 `terminal-new`；没有目录的旧事件保持原有默认行为。
- `TerminalContainer` 沿用底部面板显隐、会话创建和焦点逻辑，明确传递目录给既有启动配置解析器。
- 面板全屏后通过菜单或快捷键隐藏时，保留全屏内容挂载，用原生 `hidden` 属性隐藏外层。不能返回 `null`，否则会移除终端事件监听器，使后续文件夹请求丢失；再次请求只恢复可见性，不重建会话容器。
- 文件夹显式目录优先于启动配置的默认目录，但继续使用默认 Shell 与启动命令。WSL（Windows 的 Linux 子系统）Shell 按最终目录决定，避免沿用上一个目录所属的发行版。
- 编辑区终端标签仍供用户主动拖动使用；本次不改变拖放、会话保存、关闭或本机子进程清理。

正确示例：右键 `project/service` 后，底部会话在该目录启动，即使 profile 的默认目录是别处。不要把这个动作接到 `openTerminalBuffer`，也不要在文件树里重写 Shell/profile 的解析。

## 考虑过的备选方案

- 在文件树直接创建并管理底部会话：会复制默认 Shell、启动命令与工作区状态的处理，后续容易与工具栏漂移。
- 创建编辑区标签后再移到底部：仍保留两套会话入口，还会不必要地改变编辑器标签与活动状态。

## 后果

入口位置一致，文件夹工作目录有明确优先级。代价是本地事件多了一个可选字段；消费方对空值和非字符串按旧的默认入口处理，不能把 UI 事件对象当成路径或 profile ID。

## 验证

- `terminal-launch-actions.test.ts` 通过真实事件边界验证文件夹与旧入口共用底部创建、一次动作一个会话、所选目录、默认 Shell/启动命令及无效目录回退；监听器必须在 finally 中清理。
- `terminal-profiles.test.ts` 验证显式本地/WSL 目录覆盖默认目录并选择正确 Shell；测试已登记到 Windows CI 的有界计时入口。
- `bottom-pane-terminal-lifecycle.test.tsx` 挂载真实底部面板和全屏外层，用代替本机终端的测试组件持有生产事件监听器，验证全屏 → 菜单/快捷键隐藏 → 文件夹或全局请求时，监听器没有卸载，请求消费一次并恢复显示。CI 用独立进程隔离模块替身。
- `./scripts/windows/verify/verify-windows-boundaries.sh`、`./scripts/macos/verify/verify-runtime-bundle-immutability.sh`、`./scripts/agent-notes/verify-agent-notes.sh`。
- 真实 Windows 窗口验证右键、工具栏、已有/隐藏终端、工作目录与主动拖放；验收状态以功能矩阵为准，组件测试不能代替发行包验证。

## 适用范围

- `windows/tauri/src/features/file-explorer/hooks/use-file-explorer-context-menu.tsx`
- `windows/tauri/src/features/terminal/components/terminal-container.tsx`
- `windows/tauri/src/features/terminal/utils/terminal-launch-actions.ts`
- `windows/tauri/src/features/terminal/utils/terminal-profiles.ts`
