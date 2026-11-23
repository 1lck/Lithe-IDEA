# Agent 笔记：Viva 控件的身份键

状态：已实现

## 先说结论

Viva 用 `Key` 和 `Part` 给接下来声明的控件或容器指定身份，以便跨帧识别它。把键放在实际接收它的控件上，并在确定控件会显示时才设置。桌面 CI 的 `dev` 测试会把未被接收的键报为错误。

## 问题

关于页的面包屑给静态文本设置了键，工作台工具条的上下文菜单也设置了键。菜单从锚点继承身份，遗留的键直到下一次绘制间距时才报错。跳过控件的条件分支也会留下键，例如没有调试适配器时直接返回的选择器。

旧版 Viva 的可选中文本视图（`textview`）也会在菜单关闭时遗留键。桌面固定到已收到上游修复的 fork 提交。参见 [Lithe-viva #58](https://github.com/Lithe-IDEA/Lithe-viva/pull/58)。

## 决策

文本、图标和间距等静态元素直接使用当前上下文。上下文菜单继续使用触发按钮的锚点。组件可能提前返回时，把键从调用组件的位置移到实际绘制控件的位置。例如，仅在有适配器时调用 `ui.Select(c.Part("adapter"), …)`。

## 考虑过的备选方案

在每段静态文本或间距外包一层容器也能让键有接收者，但会增加布局节点，并让静态标记参加身份管理。直接去掉这些键，继续使用原有布局元素。

## 后果

设置页和工作台继续使用原有的布局及菜单锚点。新组件增加空状态或提前返回的分支后，需检查键是否仍在同一分支被消费。

## 验证

- `scripts/desktop/desktop-go.sh test -tags dev ./internal/settingswindow ./internal/pluginview ./internal/workbench`。修复前，关于页和默认工作台在身份键检查处报错。既有回归测试覆盖这两条渲染路径和空适配器状态。

## 适用范围

- `desktop/internal/settingswindow/window_view.go`
- `desktop/internal/workbench/chrome_view.go`
- `desktop/internal/workbench/debug_view.go`
- `desktop/go.mod`
- `scripts/desktop/check.sh`
