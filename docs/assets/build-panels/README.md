# 构建与运行工具窗口测试截图

来自生产 Viva Page 的无头渲染，使用隔离的临时项目和配置。工作区里有五个示例构建系统实例
（Maven、Gradle、Cargo、Go Modules、npm），模型由测试直接注入，不代表任何真实插件的输出。
深色使用中文、浅色使用英文。截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 右侧构建窗口（运行配置列表和按父子项目嵌套的构建树）与底部运行窗口（只显示构建控制台）：Maven 的唯一根项目 shop 由构建系统行代表，子模块 shop-core、shop-web 嵌套在它下面，各自列出 Lifecycle、Plugins 和依赖；展开了 shop-core 的 Plugins / compiler 和 shop-web 的 Lifecycle，其余文件夹保持默认折叠 | [截图](build-and-run-dark.png) | [截图](build-and-run-light.png) |
| 构建窗口按名称筛选：只保留命中的节点和通往它的项目与文件夹，没有命中的构建系统不显示 | [截图](build-filter-dark.png) | [截图](build-filter-light.png) |
| Go 模块的 Targets 文件夹展开：目标以完整导入路径命名，行上只显示所在目录；可运行的目标和任务行首是绿色运行按钮，依赖标题旁有 ⓘ | [截图](build-go-targets-dark.png) | [截图](build-go-targets-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，通过 `scripts/desktop/desktop-go.sh test
-tags vivahead,lithevisual ./internal/workbench -run '^TestVisualBuildPanels'
-count=1 -timeout 180s` 生成。
