# Agent 笔记：终端聚焦时保留切换终端快捷键

状态：已实现

## 先说结论

终端有焦点时，用户配置的“切换终端”快捷键仍须关闭终端面板；其他纯 Control 组合键继续交给 shell。先根据当前有效键位识别命令，再决定是否让终端处理，不能按来源 IDE 或某个固定按键写特例。

## 问题

VS Code 的默认终端切换键是 Control 加反引号。导入后它能从编辑器打开终端，却不能从已聚焦的终端关闭，因为 #1360 为保护 shell 将所有纯 Control 组合键交给了终端。该保护仍然需要：Control-D 是结束输入，Control-R 常用于历史搜索。

## 决策

macOS 事件监听器复用当前有效注册，先识别命令；终端持有焦点且修饰键只有 Control 时，仅让绑定到 `toggle-terminal` 的键交给应用，其余按键交回终端。用户主动把终端切换设为 Control-D 时，该显式绑定会优先于终端输入；无绑定时不截获。输入法标记文字和 HTML 预览原有优先级保持不变。

正确例子：导入的 Control 加反引号能打开和关闭终端，Control-D 仍能结束未显式将它设为切换键的 shell。不要在监听器中对 VS Code 或反引号硬编码，也不要让所有已注册的 Control 组合键抢走 shell 输入。

## 考虑过的备选方案

- 所有 Control 组合键都交给应用：会恢复 #1360 的 shell 输入回归。
- 仅放行 Control 加反引号：会忽略用户自定义的终端切换键，且把来源 IDE 键位写死在事件监听器。

## 后果

用户显式指定的终端切换键在终端内有效，其他应用快捷键仍不抢终端 Control 输入。显式选择与 shell 功能相同的键时，该键会用于切换终端，这是可配置快捷键的直接结果。

## 验证

- `TerminalShortcutInputPolicyTests` 使用真实 AppKit 事件监听器验证切换、Control-D、Control-R 和普通应用组合键；输入法及 HTML 预览回归与其共同运行。
- 隔离的 macOS Release 包导入 VS Code 键位后，从编辑器按 Control 加反引号打开终端，终端有焦点时再次按下成功关闭；重开后 Control-D 结束测试 shell。包内文件清单和 SHA-256 在流程前后保持一致。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh` 和 `./scripts/agent-notes/verify-agent-notes.sh`。

## 适用范围

- ~~`macos/Sources/Lithe/Platform/MacOS/UI/MacShortcutDetector.swift`~~（已随 #1794 移除）
- ~~`macos/Tests/LitheTests/TerminalShortcutInputPolicyTests.swift`~~（已随 #1794 移除）
- `shared/platform-feature-matrix/features/terminal-interaction.json`
