# 内置脚本与程序运行测试截图

这些截图是生产 Viva Page 的无头渲染，在 macOS 上生成。项目是隔离的临时项目 ScriptDemo，配置也是临时的，没有装任何插件。
深色界面用中文，浅色界面用英文，窗口 1200×760。
测试内核不带插件宿主，所以运行下拉会显示“此窗口无法使用构建插件。”。
这也说明插件不可用时，内置运行照常列出、照常运行。
Shell 脚本在系统 shell 里真实运行，控制台内容是真实输出，日期来自测试的虚拟时钟。
无头截图不代表 macOS/Windows 原生窗口验收。

运行配置在“运行/调试配置”对话框里新建和编辑。标题栏运行下拉的“新建运行配置…”和“编辑运行配置…”都打开这个对话框。
对话框左侧是工具栏（+ 新建、− 删除、复制、新建文件夹、按字母顺序排序）和按类型分组的配置树，右侧是选中配置的编辑器。
配置树的图标是各类型的彩色文件图标：Shell 脚本、PowerShell 脚本、批处理脚本和程序各不相同。
底部左边是“运行”，右边是“取消 / 应用 / 确定”。
编辑器的名称行右侧是“存为项目文件”和“允许多个实例”；勾选后者的配置再次运行时，在旁边另开一个实例，不先停掉正在运行的那个（两个实例同时运行的截图在 `docs/assets/plugin-declared-runs/`）。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 还没有配置时打开对话框，和 IDEA 一样：左侧是“未添加运行配置。”和链接“添加新… ⌃N”，右侧是链接“添加新的运行配置…”和“或选择要编辑的运行配置”。两个链接和 ⌃N 都打开类型菜单 | [截图](builtin-run-dialog-empty-dark.png) | [截图](builtin-run-dialog-empty-light.png) |
| 新建 Shell 脚本，执行方式为脚本文件：勾选了“存为项目文件”，填了脚本路径、脚本选项、项目内的工作目录和一个环境变量。解释器路径选的是“自动”，下拉框显示自动值，取自脚本首行的 `#!/bin/bash`。脚本选项、解释器路径和解释器选项旁的 ⓘ 说明各自传给谁 | [截图](builtin-run-shell-file-dark.png) | [截图](builtin-run-shell-file-light.png) |
| 同一配置换成脚本文本，出现多行文本框。文本没有首行 `#!`，解释器自动值变为 `/bin/sh` | [截图](builtin-run-shell-text-dark.png) | [截图](builtin-run-shell-text-light.png) |
| 展开解释器路径下拉：第一项是“自动（/bin/sh）”，然后是终端检测到的 POSIX shell（zsh、bash），最后是“自定义…”。截图用固定的 shell 列表（zsh、bash、pwsh），pwsh 不属于 Shell 脚本这一类，所以不列出 | [截图](builtin-run-interpreter-list-dark.png) | [截图](builtin-run-interpreter-list-light.png) |
| 选“自定义…”后，下拉下方出现“自定义解释器”输入框，可以填命令名（按 PATH 查找）或路径，右侧按钮用来选择文件。这里填了 `/opt/homebrew/bin/bash`；改回“自动”或选某个 shell 后，输入框收起 | [截图](builtin-run-interpreter-custom-dark.png) | [截图](builtin-run-interpreter-custom-light.png) |
| 点击对话框的“运行”后：配置写入 `.lithe/run/configurations.yaml`，对话框关闭，Run 窗口打开并选中这次运行。控制台打印脚本输出，执行树以“进程已结束，退出码 0。”结束；标题栏改选 Greet | [截图](builtin-run-run-output-dark.png) | [截图](builtin-run-run-output-light.png) |
| 再次打开对话框并展开“+”菜单：列出四类内置运行，批处理脚本下注明“仅 Windows” | [截图](builtin-run-new-menu-dark.png) | [截图](builtin-run-new-menu-light.png) |
| 新建 PowerShell 脚本：macOS 上的解释器自动值是 pwsh，解释器选项自动值是 `-NoLogo -NoProfile`。“绕过执行策略（-ExecutionPolicy Bypass）”默认勾选，ⓘ 说明只在 Windows 生效 | [截图](builtin-run-powershell-dark.png) | [截图](builtin-run-powershell-light.png) |
| 新建可执行程序：程序路径、程序参数（含带引号的空格参数）和工作目录 | [截图](builtin-run-executable-dark.png) | [截图](builtin-run-executable-light.png) |
| 在 macOS 上新建批处理脚本：能编辑、能保存，编辑器顶部提示“批处理脚本只能在 Windows 上运行；在这台电脑上可以编辑和保存，但不能运行。”。配置树里这一行带警告图标，对话框的“运行”置灰 | [截图](builtin-run-batch-dark.png) | [截图](builtin-run-batch-light.png) |
| 点“确定”保存全部四个配置后，标题栏选中 Package：运行按钮置灰；按下时只提示原因，不会启动 | [截图](builtin-run-title-unavailable-dark.png) | [截图](builtin-run-title-unavailable-light.png) |
| 选中 Greet 点“新建文件夹”，改名为 Scripts，再关掉“按字母顺序排序”：Shell 脚本下先列文件夹 Scripts，Greet 在里面；排序按钮不再高亮 | [截图](builtin-run-folders-dark.png) | [截图](builtin-run-folders-light.png) |
| 选中文件夹 Scripts：右侧是文件夹名称框和说明“文件夹只用来整理列表，随其中的配置一起保存；空文件夹不会保存。” | [截图](builtin-run-folder-pane-dark.png) | [截图](builtin-run-folder-pane-light.png) |
| 选中 Tool 点复制：副本“Tool（副本）”排在 Tool 后面，编辑器里的字段和原配置一致，按“应用”或“确定”才保存 | [截图](builtin-run-copy-dark.png) | [截图](builtin-run-copy-light.png) |
| 标题栏运行下拉：Package 带警告图标，下方注明“仅 Windows”，仍可选中。插件运行配置文件 `.lithe/run/plugin/dev.example.engine.toml` 写坏后，下拉多出一项“未读取 dev.example.engine.toml 中的运行配置”，点击后在编辑器中打开该文件 | [截图](builtin-run-run-menu-dark.png) | [截图](builtin-run-run-menu-light.png) |

`docs/assets/run-config-empty/` 是另一组截图，展示项目没有可用运行配置时的标题栏下拉和对话框。
它们由 `TestVisualTitleRunWithoutConfigurations` 生成。

复验：设置 `LITHE_VISUAL_OUTPUT_DIR` 后运行下面的命令，两组截图都会生成。

```sh
scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/workbench \
  -run '^(TestVisualBuiltInProcessRuns|TestVisualTitleRunWithoutConfigurations)$' -count=1 -timeout 300s
```
