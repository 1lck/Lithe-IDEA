# 插件设置表单只剩一层滚动

来自生产 Viva Page 的无头渲染，用的是插件契约里的 `view-panel` 示例插件（`dev.lithe.fixture.view-panel`），
配置目录是固定的假路径，不代表任何真实插件或用户数据。窗口高度 760 点，中文浅色主题，打开「插件 →
已安装 → View Panel → 设置」，再把滚轮停在右侧详情里一直向下滚到底。

| 场景 | 截图 |
| --- | --- |
| 改动前：详情滚到底之后，插件声明的设置行还在自己的小滚动区域里，最后一行「Watch files」被下边缘截断，要在这块区域里再滚一次才能看到 | [截图](plugin-settings-before-zh-light.png) |
| 改动后：效果预览和设置行一起随页面滚动，滚到底时最后一行「Watch files」完整显示，右侧只有一条滚动条 | [截图](plugin-settings-after-zh-light.png) |

「改动前」来自本次改动的父提交，用一次性的无头脚手架截取，脚手架没有提交。行为本身由
`desktop/internal/settingswindow` 的 `TestSettingsDynamicPageFormScrollsWithThePageAndShowsItsRowsWhole`
和 `TestInstalledSettingsTabFormScrollsWithTheDetail` 覆盖，这两个测试在改动前都会失败。

截图不代表 macOS、Windows 原生窗口验收。
