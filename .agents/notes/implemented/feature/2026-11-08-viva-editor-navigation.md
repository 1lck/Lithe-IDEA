# Agent 笔记：Viva 编辑器行列跳转

状态：已实现

## 先说结论

Viva 的状态栏和 ⌘L 使用 Rust Core 的 `editor.parseNavigationInput`，行列从 1 开始显示，Core 返回的坐标从 0 开始且列以 UTF-16 计数。只输入行号选择整行内容，输入列号放置光标；越界位置按当前文档限制，半个代理项落到字符前的 UTF-8 边界。

## 问题

输入验证和编辑器可见文本不在同一层，用户可以在验证期间继续输入、关闭窗口或切换文档；过期结果不能跳转其他文档。长行的列数如果逐字节查找 Rope，会在状态栏重绘时增加主线程开销。

## 决策

输入合并 75 毫秒后在后台调用 Core；输入变更或对话框关闭时取消，结果按代次、原始文本、项目和文档身份检查。回车早于验证时保留确认意图，但只接受匹配当前输入的有效结果。输入法组合期间不截获输入或移动编辑器光标。关闭弹层时将焦点交回仍然选中的原文档；Tab 保持在弹层内。

列转换遍历 Rope 的片段而不是每个字节重新查询树。状态栏缓存当前文本和光标的列，普通单行插入和删除增量更新；换行、撤销等其他修改按实际文本重新计算。状态栏缓存只保留一个文档快照，随视图释放。

## 考虑过的备选方案

- 在 Go 里再实现一套输入解析会与共享 fixture 和其他宿主漂移，因此只消费 Core 结果。
- 每次重绘都扫描长行会放大输入延迟，因此缓存不变位置并增量更新普通编辑。
- 使用现有 Viva 通用对话框有焦点约束，但其固定布局不能复现原版面板；当前使用有界弹层并显式处理键盘焦点。原生窗口语义和逐像素外观仍需后续验收。

## 后果

Viva 复用共享输入规则，同时承担活动文档检查、焦点和坐标转换；原生菜单入口、平台窗口行为及 Windows 完整产品验证仍需补齐。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core ./internal/editorview ./internal/workbench -run 'Test(ParseNavigationInputSharedFixtures|GoToNavigationUTF16AndWholeLine|CaretUTF16TracksEditsAndUndo|Navigation)'`：共享 fixture、代理项、整行、无效输入、异步旧结果、文档切换与焦点循环。
- 原版 macOS 弹窗和 Viva 无头截图已对照并调整尺寸、输入框及按钮；这不是原生窗口的逐像素验收，Windows 完整产品验收仍待完成。
- macOS 上对 100 万字节单行进行三次微基准：逐字节 Rope 查询约 17.5 ms/次，按片段冷计算约 0.60 ms/次，缓存读取约 28 ns/次；这是列计算的局部测量，不是完整编辑工作流或跨平台性能基线。

## 适用范围

- `desktop/internal/core/navigation.go`
- `desktop/internal/editorview/view.go`
- `desktop/internal/workbench/navigation.go`
