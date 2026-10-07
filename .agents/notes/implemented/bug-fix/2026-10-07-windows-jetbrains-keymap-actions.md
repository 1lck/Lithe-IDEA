# Agent 笔记：Windows JetBrains快捷键与选中Run/Debug动作

状态：已实现

## 先说结论

保留预设和用户覆盖的完整绑定列表，让当前编辑器/终端上下文决定分发，关闭动作也走有效绑定。常用JetBrains编辑与导航键映射既有命令，运行调试键复用选中配置和共享会话动作；菜单提示从同一有效绑定查询。

## 问题

预设合并丢失同命令别名和上下文，硬编码关闭快捷键抢占Ctrl+W，Windows启用nativeMenuBar又会跳过实际没有原生菜单处理的按键；菜单提示与有效绑定不一致。

## 决策

保留预设和用户覆盖的完整绑定列表，让当前编辑器/终端上下文决定分发，关闭动作也走有效绑定。常用JetBrains编辑与导航键映射既有命令，运行调试键复用选中配置和共享会话动作；菜单提示从同一有效绑定查询。

## 考虑过的备选方案

不覆盖用户绑定；不把编辑器快捷键应用于输入框或终端；不依赖硬编码Ctrl+W绕过预设；不复制调试清理状态机。

## 后果

测试覆盖实际键盘事件、多个别名、关闭/编辑冲突与上下文边界。只覆盖当前已有IDE动作，不引入新的代码分析或调试后端；不修改安装资源。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/keymaps/hooks/use-keymaps.integration.test.tsx`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/keymaps/utils/matcher.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/keymaps/utils/editor-keyboard-target.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/keymaps/defaults/default-keymaps.git-log.test.ts`

## 适用范围

- `windows/tauri/src/features/keymaps/commands/command-registry.ts`
- `windows/tauri/src/features/keymaps/commands/debug-command-actions.ts`
- `windows/tauri/src/features/keymaps/defaults/keybinding-presets.ts`
- `windows/tauri/src/features/keymaps/hooks/use-keymaps.integration.test.tsx`
- `windows/tauri/src/features/keymaps/hooks/use-keymaps.ts`
- `windows/tauri/src/features/keymaps/utils/effective-contexts.ts`
- `windows/tauri/src/features/keymaps/utils/effective-keymaps.ts`
- `windows/tauri/src/features/window/components/window-menu-bar.tsx`
