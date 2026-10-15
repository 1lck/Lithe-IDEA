# Agent 笔记：Windows 设置页共用选择和表单控件

状态：已实现

## 先说结论

Windows 设置页的固定选项和可搜索选项统一通过 `SettingsSelect` 使用现有 `Select`，由共享组件负责触发按钮、菜单表面、选中态和键盘操作。设置页不再使用原生下拉框，也不再各自选择按钮字号和表面样式。文本、多行文本和复选框复用现有表单控件，保存时机仍由对应设置功能负责。

## 问题

常规、编辑器、终端、Git、运行配置和 AI 提交混用浏览器原生下拉框与自定义菜单，字体、边框、菜单颜色和选中反馈不同。已有自定义选择控件也混用三种密度；AI 提交、Maven 和 MCP 还有各自手写的输入框与复选框。

## 决策

- `windows/tauri/src/ui/settings-select.tsx` 规定设置页的触发按钮密度、默认宽度和菜单内搜索。字体、快捷键等可搜索选择器也使用同样的按钮，避免关闭时仍呈现另一套输入框圆角和边框。菜单、搜索、定位、关闭和键盘操作继续交给既有 `Select` 与 Base UI（现有的无障碍交互组件库）。调用处可以按内容调整宽度，不能另画菜单外框或重新选择按钮字号。
- 固定列表提供选项数组，可搜索列表保留原来的搜索与自定义值能力。AI 服务商和模型选择器的设置外观使用同一入口，聊天输入区继续使用自己的紧凑布局。
- 空字符串可以代表“自动选择”。存在对应选项时，选择组件必须把空字符串作为有效选中值，而不是没有选择。例如从指定工具链切回自动配置后，自动项仍应显示选中态，保存的值仍为空字符串。
- 带 `id` 的选择控件保留外部标签的命名作用；未提供标签关系的设置行显式提供可访问名称。不能用通用的“请选择”覆盖已经关联的字段标签。
- AI 提交与 Maven 的文本框使用 `Input`，多行输入使用 `Textarea`，AI 提交、Git 和 MCP 的复选框使用 `Checkbox`。保留 AI 提交数值草稿的失焦提交和 Maven 的显式应用行为。
- 项目 JDK 和 Maven 路径通过 `SettingsPathInput` 使用既有可编辑 `Combobox` 的候选菜单。每次输入立即更新页面草稿，任意未列出的路径也必须保留，不能等选中候选或按 Enter 才把文本交给页面保存。Esc 用于退出候选交互，组件取消 Base UI 在关闭状态下产生的清空事件，保留已经编辑的路径；用户直接删除文本仍可选择自动配置。

正确做法是给 `SettingsSelect` 提供当前值、选项和修改回调；不要在页面重新编写原生 `select` 或传入另一套字号、圆角和菜单背景。

## 考虑过的备选方案

只给原生 `select` 设置 CSS 可以统一关闭时的按钮，却不能控制系统展开菜单的外观。重新实现菜单会重复现有组件的键盘、焦点与弹层逻辑，所以只增加一个设置用途的薄封装。

## 后果

设置页采用相同的表单密度与主题反馈，功能页继续拥有保存逻辑。自定义选择菜单会增加少量组件渲染；宽度仍按内容区分，长路径不能强行缩成短枚举的宽度。项目路径保留可编辑输入框，候选菜单采用共享外观，空值仍代表自动配置。

按钮、开关与数值步进器已经有共享组件。设置分组、行间距、分类树和外观分段选择的统一见 [Windows 设置分层](../feature/2026-10-08-windows-settings-hierarchy.md)；运行保存范围仍保留原来的独立选择语义。

## 验证

- `scripts/build-windows.ps1 -Configuration Release` 验证类型、前端与 Windows 应用构建。
- `.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend` 验证现有设置路由、持久化与新增的空值选择回归。
- `windows/tauri/src/ui/settings-select.test.tsx` 验证自动配置选中态、切换后恢复自动配置、禁用选项和外部标签；此回归不能由类型检查证明。
- `windows/tauri/src/ui/settings-path-input.test.tsx` 通过实际输入和 Esc 键盘事件验证任意路径草稿保留、继续编辑及手动清空，并以独立进程接入 Windows CI（持续集成），避免其他组件测试的浏览器环境干扰。
- `scripts/verify-windows-boundaries.sh`、`scripts/verify-platform-feature-matrix.sh`、`scripts/verify-runtime-bundle-immutability.sh` 与 `scripts/verify-agent-notes.sh` 检查边界和文档。
- 在实际设置窗口检查深浅色、普通与可搜索列表、键盘选择与 Esc、点击外部关闭、切换分类、长列表滚动和选项持久化。

## 适用范围

- `windows/tauri/src/ui/settings-select.tsx`
- `windows/tauri/src/ui/settings-path-input.tsx`
- `windows/tauri/src/ui/settings-path-input.test.tsx`
- `windows/tauri/src/ui/select.tsx`
- `windows/tauri/src/features/settings/components/`
- `windows/tauri/src/features/ai/components/selectors/`
- `windows/tauri/src/features/ai/integrations/codex/codex-settings.tsx`
- `windows/tauri/src/features/run/components/run-configuration-editor.tsx`
- `windows/tauri/src/features/host-api/mcp-settings.tsx`
