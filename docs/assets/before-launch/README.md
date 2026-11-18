# 运行配置“执行前”测试截图

这些截图是生产 Viva Page 的无头渲染，在 macOS 上生成，由 `TestVisualBeforeLaunchSteps` 输出。项目是隔离的临时项目 ServiceDemo，
项目文件里有三个 Shell 运行 generate、frontend、docs，和一个程序运行 Server；Server 的执行前步骤依次是 generate、frontend。
深色界面用中文，浅色界面用英文，窗口 1200×820。控制台内容是步骤和配置真实打印的输出。
无头截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 编辑 Server：和 IDEA 一样，“执行前”在编辑器最底下、横跨整个表单。标题行是折叠箭头、标题、ⓘ 和分隔线；下面是带框列表，顶部工具栏 + − ✎ ↑ ↓，没有选中行时只有“+”可用；每行是配置图标和“运行“名称”” | [截图](before-launch-editor-dark.png) | [截图](before-launch-editor-light.png) |
| 选中第二步后点“+”→“运行另一个配置”：弹出“选择要执行的配置”，只列出列表里还没有的 docs；选中行整行高亮 | [截图](before-launch-choose-dark.png) | [截图](before-launch-choose-light.png) |
| 第一次运行项目文件里写的步骤前，询问是否运行这些步骤 | [截图](before-launch-confirm-dark.png) | [截图](before-launch-confirm-light.png) |
| 确认后，步骤和 Server 的输出依次写在同一个 Run 控制台里 | [截图](before-launch-run-output-dark.png) | [截图](before-launch-run-output-light.png) |
