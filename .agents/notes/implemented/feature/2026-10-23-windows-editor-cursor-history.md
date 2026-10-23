# Agent 笔记：Windows 编辑器优先回退误移动的光标

状态：已实现

## 先说结论

Windows 编辑器误按方向键后，第一次 Ctrl+Z 恢复最近一次键盘移动前的位置，保留刚输入的代码；再按一次才撤销代码。
光标和文本仍使用 Monaco 各自的历史，Lithe 只判断本次撤销该调用哪种动作。
另提供 Ctrl+U 回退、Ctrl+Shift+U 重做光标，命令面板和快捷键设置均可找到这两个独立动作。

## 问题

用户编辑后误按向下箭头，希望恢复光标，却通过文本撤销丢失刚才的修改。
现有导航历史只记录显式跳转和鼠标手势，不能替代逐次方向键移动与多选区的恢复。
Monaco 原生提供光标历史，但原来的 Ctrl+Z 只调用文本撤销，也缺少可发现的产品命令入口。

## 决策

复用固定 Monaco 0.55.1 的 `cursorUndo` / `cursorRedo`。
上游实现位于 `src/vs/editor/contrib/cursorUndo/browser/cursorUndo.ts`，由每个编辑视图保存最多 50 个光标、选区和滚动状态；文本修改或切换模型后清空，避免旧坐标误用。
Windows 的 `createCursorAwareUndo` 仅保存待执行动作类型，不保存坐标或另一份历史。
同一文档版本中的键盘选区变化启用一次光标撤销；文本变化、模型切换和鼠标或 API 移动会取消它。
光标恢复后，Ctrl+Shift+Z 或 Ctrl+Y 可以恢复该次移动；若先继续 Ctrl+Z 撤销文本，则之后重做文本。
连续多次方向键移动也只优先恢复最近一次，避免用户一直无法撤销代码。

策略随活动视图适配器安装、卸载，切换文件或分屏不沿用其他视图的待执行状态。
只读与预览视图允许恢复光标，仍禁止修改文本。
独立光标命令也经过活动编辑适配器的同一策略执行：Ctrl+U 实际恢复选区后，普通重做应恢复光标；Ctrl+Shift+U 消费这次恢复状态。空光标历史不抢占文本重做。其他平台仍使用共享 `runEditorCommand` 的原生动作映射。

Windows 注册稳定命令 ID `editor.cursorUndo` / `editor.cursorRedo`，供快捷键设置和命令面板使用。
默认快捷键仅在编辑区生效，普通输入框、查找输入框和终端沿用原有处理。
正确做法是“输入代码 → 方向键移动 → Ctrl+Z 恢复光标 → Ctrl+Z 撤销输入”。
不要在文本撤销栈或工作区跳转历史中插入每次光标移动。

## 考虑过的备选方案

- 只暴露独立 Ctrl+U 不满足用户明确选择的 Ctrl+Z 行为，未采用。
- 让连续 Ctrl+Z 逐个耗尽所有光标移动，会推迟文本撤销，未采用；仅优先消费最近一次移动。
- 将每次方向键移动加入工作区跳转历史，会混合跨文件导航与视图内多选区，并重复实现 Monaco 的边界处理，未采用。
- 自建光标栈需要跟随文档版本、只读、多光标与视图销毁同步，上游能力已经完整覆盖，未采用。

## 后果

用户可以独立恢复光标，也能使用重做恢复刚才的移动。
光标历史属于视图，不跨文件、分屏共享，不写入会话或发行目录。
编辑内容后历史清空是上游的版本保护行为，并非长期位置书签。
此行为改变 Windows 的文本撤销入口，键盘导航后需多按一次才能撤销文本。
macOS 已加载原生 Monaco 动作；本次的 Ctrl+Z 策略和产品命令入口仅接入 Windows。

## 验证

- 快捷键集成测试覆盖默认回退/重做与文本撤销分别分发、自定义快捷键和查找输入框隔离。
- 策略测试覆盖一次光标恢复后进入文本撤销、对应重做、历史失效、只读、视图隔离和监听器释放。
- 真实 Monaco 验证输入后移动、回退、重做、选区和滚动恢复、空栈不改文本、编辑与切换模型清空历史以及不同视图隔离。
- 运行 Windows Frontend 计时检查、Windows 构建、功能矩阵校验、Agent Notes 校验和发行目录只读检查；浏览器探针不能替代 Windows WebView2 与 macOS 原生按键验收。

## 适用范围

- `frontend/editor/src/editor-commands.ts`
- `windows/tauri/src/features/editor/engines/monaco/cursor-aware-undo.ts`
- `windows/tauri/src/features/editor/components/monaco-editor.tsx`
- `windows/tauri/src/features/keymaps`
- `windows/tauri/src/features/command-palette/constants/navigation-actions.tsx`
- `windows/tauri/src/i18n/locale.ts`
