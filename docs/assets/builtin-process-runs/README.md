# 内置脚本与程序运行测试截图

这些截图是生产 Viva Page 的无头渲染，跑在 macOS 上，使用隔离的临时项目 ScriptDemo 和临时配置，没有安装任何插件。
深色界面用中文，浅色界面用英文，窗口 1200×760。
测试内核不带插件宿主，所以构建窗口和运行下拉会显示“此窗口无法使用构建插件。”；
截图同时说明，插件不可用时内置运行照常列出、照常运行。
Shell 脚本在系统 shell 里真实运行，控制台内容是真实输出，日期来自测试的虚拟时钟。
无头截图不代表 macOS/Windows 原生窗口验收。

| 场景 | 深色中文 | 浅色英文 |
| --- | --- | --- |
| 新建 Shell 脚本，执行方式为脚本文件。勾选了“存为项目文件”，填了脚本路径、脚本选项、项目内的工作目录和一个环境变量。解释器路径没填，显示的自动值取自脚本首行的 `#!/bin/bash` | [截图](builtin-run-shell-file-dark.png) | [截图](builtin-run-shell-file-light.png) |
| 同一配置换成脚本文本，出现多行文本框。文本没有首行 `#!`，解释器自动值变为 `/bin/sh` | [截图](builtin-run-shell-text-dark.png) | [截图](builtin-run-shell-text-light.png) |
| 点击对话框的运行后，配置写入 `.lithe/run/configurations.yaml`，Run 窗口自动打开并选中这次运行。控制台打印脚本输出，执行树以“进程已结束，退出码 0。”结束；标题栏改选 Greet | [截图](builtin-run-run-output-dark.png) | [截图](builtin-run-run-output-light.png) |
| 构建窗口的运行配置列表：Greet 在“脚本与程序”组下，“+”菜单列出 macOS 提供的三类内置运行，没有 cmd 批处理 | [截图](builtin-run-new-menu-dark.png) | [截图](builtin-run-new-menu-light.png) |
| 新建 PowerShell 脚本：macOS 上的解释器自动值是 pwsh，解释器选项自动值是 `-NoLogo -NoProfile`。“绕过执行策略（-ExecutionPolicy Bypass）”默认勾选，ⓘ 说明只在 Windows 生效 | [截图](builtin-run-powershell-dark.png) | [截图](builtin-run-powershell-light.png) |
| 新建可执行程序：程序路径、程序参数（含带引号的空格参数）、工作目录和环境变量 | [截图](builtin-run-executable-dark.png) | [截图](builtin-run-executable-light.png) |
| 一个插件的运行配置文件 `.lithe/run/plugin/dev.example.engine.toml` 写坏后，标题栏运行下拉仍列出 Greet，并多出一项“未读取 dev.example.engine.toml 中的运行配置”，点击在编辑器中打开该文件 | [截图](builtin-run-run-menu-dark.png) | [截图](builtin-run-run-menu-light.png) |

复验：设置 `LITHE_VISUAL_OUTPUT_DIR`，运行 `scripts/desktop/desktop-go.sh test
-tags 'vivahead lithevisual' ./internal/workbench -run '^TestVisualBuiltInProcessRuns$'
-count=1 -timeout 180s` 生成。
