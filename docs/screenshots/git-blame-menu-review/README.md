# Git Blame 行号右键菜单

这些截图用于 PR #1397 的交互和外观复核，使用受控的演示内容，不包含私人项目数据。

- [深色：注释关闭](blame-hidden-dark.png)、[注释开启](blame-shown-dark.png)
- [浅色：注释关闭](blame-hidden-light.png)、[注释开启](blame-shown-light.png)
- [深色中文：显示注释菜单](menu-zh-show-dark.png)、[隐藏注释菜单](menu-zh-hide-dark.png)
- [浅色中文：显示注释菜单](menu-zh-show-light.png)、[隐藏注释菜单](menu-zh-hide-light.png)

编辑器截图来自真实 WKWebView 工作台，Blame 作者与日期由探针提供固定样例。中文菜单使用仓库的本地化文本和实际共享原生呈现器。截图展示开关前后的状态，不是对旧版完整应用的重建截图，也不证明真实仓库的完整 Git 加载和调试流程已经人工验收。

设置 `LITHE_MONACO_REVIEW_SCREENSHOTS=1` 后运行：

```sh
./scripts/macos/probe/probe-macos-monaco.sh --workbench-tests
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter MonacoEditorContextMenuTests
```

原始截图分别写入 `.artifacts/monaco-workbench/test-results/` 和 `.artifacts/monaco-menu-review/`，仅作为本工作树的测试产物，不作为运行时资源或跨工作树缓存复用。
