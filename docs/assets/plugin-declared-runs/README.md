# 插件声明的运行类型测试截图

这些截图是生产 Viva Page 的无头渲染，在 macOS 上生成。项目是隔离的临时项目 RunTypesDemo，装了一个只在测试里存在的合成插件
`dev.lithe.test.run-types`：它的构建系统 Fixture Runs 声明了运行类型 Fixture Run，字段有“模式”（慢速/快速）、“详细输出”（勾选后加 `-v`）和必填的“目标”；
还声明了一个启动前任务 Fixture Task，字段是必填的“任务目标”。
插件包里带一份中文翻译。深色界面用中文，读插件的中文翻译；浅色界面用英文，读插件清单的原文。窗口 1200×760。
运行的是测试二进制本身，控制台内容是它真实打印的参数，日期来自测试的虚拟时钟。
无头截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 打开“运行/调试配置”并展开“+”菜单：四类内置运行之后列出插件声明的“夹具运行”。每类一行，有说明的类型在名称后面显示 ⓘ，鼠标停在 ⓘ 上才显示说明（插件写的“运行夹具工具。”） | [截图](declared-run-new-menu-dark.png) | [截图](declared-run-new-menu-light.png) |
| 新建一条夹具运行：配置树里“夹具运行”单独一组；右侧是插件字段（模式、详细输出、目标），标题和选项名都来自插件翻译，下面是宿主统一提供的程序参数、工作目录和环境变量；最底下是横跨表单的“执行前”：标题带折叠箭头和 ⓘ，下面是带框列表，顶部工具栏是 + − ✎ ↑ ↓，没有任务时居中显示“启动前没有要运行的任务”。名称行勾选了“存为项目文件”和“允许多个实例” | [截图](declared-run-form-dark.png) | [截图](declared-run-form-light.png) |
| 点“执行前”工具栏的“+”：弹出“添加新任务”，标题居中加粗，第一项“运行另一个配置”打开可运行配置的列表，后面是插件声明的启动前任务“夹具任务” | [截图](declared-run-before-launch-menu-dark.png) | [截图](declared-run-before-launch-menu-light.png) |
| 选“夹具任务”后弹出任务自己的表单：标题“添加任务：夹具任务”，下面是插件写的说明和插件翻译的字段“任务目标”；点“确定”由 Core 检查值后才加入列表 | [截图](declared-run-task-form-dark.png) | [截图](declared-run-task-form-light.png) |
| 点“确定”保存后连续运行两次：Run 窗口里有两个 Fixture Alpha 标签，两个实例都在运行，控制台打印 `run-type ran: fast -v alpha one two`，即 Core 按字段值拼出的参数。旁边的“同步 Fixture Runs”是打开项目时读取构建模型的会话 | [截图](declared-run-two-instances-dark.png) | [截图](declared-run-two-instances-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR` 后运行：

```sh
scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/workbench \
  -run '^TestVisualPluginDeclaredRuns$' -count=1 -timeout 300s
```
