# Agent 笔记：插件声明的命令缺失时由宿主安装

状态：已实现

## 先说结论

很多插件不打包自己要运行的程序，而是用本机已有的命令：Go 插件的语言服务器是 `gopls`，调试器是 `dlv`。以前这些命令不在时，用户只看到“plugin package path is not usable: none of the plan's commands is available”这类原始错误，也不知道怎么装。现在插件可以在清单里用 `commandInstallers` 声明“用哪个工具、跑什么参数来安装哪些命令”。宿主在插件详情“功能”页的能力卡片上显示“未找到 xxx”和安装按钮，用户在对话框里选择安装位置、看清要运行的命令后确认，宿主运行安装并记录命令所在目录，之后该插件的启动都能找到它们。宿主里没有任何针对具体插件或具体工具的代码。

## 问题

- 插件的 `systemCommand` 启动（语言服务器、构建、版本控制、调试适配器、后端）只在 PATH 和工具默认目录里找命令。找不到时，启动失败的原因是英文原始错误，用户不知道缺什么、该装到哪。
- 安装命令的方式因工具而异（`go install`、`npm install -g`、`cargo install`……），装到哪里也因工具而异（`GOBIN`、`GOPATH/bin`）。宿主如果按工具写死安装逻辑，就违反了“宿主对具体插件和工具零依赖”。
- 安装会运行下载代码的程序，必须让用户看清要运行什么、会不会联网，并且可以取消。
- 发行包在运行时只读，装好的命令不能写进 app bundle 或安装目录。

## 决策

对应计划编号 API-23（工具链与受管进程）。

**谁负责什么**

- **插件声明**：清单 `commandInstallers[]`（`requires.commandInstallers: 0`，权限 `commands.install`），每项写明安装哪些命令（必须是本清单某个 `systemCommand` 启动用到的命令，且每个命令只归一个安装器）、用哪个已注入的工具（`tool`，必须同时列在 `requiresTools`）、参数、环境、超时（1–3600 秒，默认 600）、是否可能联网，以及支持哪些目标：
  - `managed`：装进 Lithe 管理的目录。参数或环境里必须出现 `${installDirectory}`，可用 `commandDirectory` 指出命令在安装目录下的哪个相对子目录。
  - `toolDefault`：装进工具自己的默认位置。用最多 4 个只含字面参数的探测命令（例如 `go env GOBIN`，再退到 `go env GOPATH` 的第一项加 `bin`）找出那个目录。
- **Core 校验与展开**（Lithe-core-rust#53）：`plugins.commandInstallers.requirements` 列出每个 `systemCommand` 启动和它的命令、能安装它的安装器；`plugins.commandInstallers.plan` 把一个目标展开成参数、环境和命令目录；`plugins.commandInstallers.defaultDirectory` 从探测输出里取出目录。宿主不自己解释清单字段。
- **宿主执行**（`desktop/internal/workbench/command_installers.go`）：
  - 缺失检测：按启动自己的查找方式找命令。调试适配器用调试的查找（macOS 上还会问 `xcrun --find`），其他用插件运行器的查找。两者都会加上已记录的安装目录。只有“找不到命令”算缺失，别的失败不提示安装。
  - 解析工具：在打开的项目里解析，项目固定的工具版本就是安装用的版本。
  - 运行：经 `buildprocess` 直接启动工具，不经过 shell。工作目录是项目目录，输出逐行送到对话框（每行有上限），到超时就停止，用户取消就停止。
  - 核对：工具退出码为 0 之后，再确认每个命令确实落在目标目录里，才写记录。
- **记录与查找**（`desktop/internal/pluginhost/commands.go` 的 `CommandStore`）：
  - 受管目录是 `<插件根目录>/.state/<插件 ID>/commands/<安装器 ID>`。
  - 记录文件是 `<插件根目录>/.state/<插件 ID>/commands.json`，读取上限 64 KiB，先写临时文件再改名替换。
  - 之后的启动通过 `CommandStore.Lookup` 和 `Backend.ResolveCommand` 先在记录的目录里找，再按原来的方式找。
- **界面**（`desktop/internal/settingswindow/command_install.go`）：
  - 能力卡片显示“未找到 xxx”和安装按钮。没有卡片的后端命令显示在横幅里。
  - 对话框列出两个位置。工具默认位置探测不到时，该选项不可选并说明原因。
  - 对话框还显示要运行的命令和环境、是否可能联网。
  - 安装输出实时显示，失败原因全部本地化。命令缺失导致的启动失败（调试、构建、版本控制）也改用本地化提示。

**运行时写入位置**：只写插件根目录下的 `.state`。它属于平台存储目录，不在 app bundle 或安装目录里，所以不影响代码签名，也不影响 Sparkle 增量包的源基线。卸载插件时，Core 的卸载计划包含删除状态目录的步骤（`core.PluginRemoveState`），受管目录和记录随之删除。`toolDefault` 只记录目录，工具装进默认位置的文件归用户和工具所有，卸载不删除。

正确做法：新插件需要本机命令时，在清单里声明 `commandInstallers`，安装方式写成该工具自己的参数；需要知道工具把命令装到哪，就用 `directory` 探测，不在宿主里加分支。

不要这样做：在宿主里写“缺 gopls 就运行 `go install golang.org/x/tools/gopls@latest`”；也不要让插件后端自己下载并解压命令到插件包目录，插件包和发行包一样，运行时只读。

## 考虑过的备选方案

1. **宿主为常见工具内置安装方式**（Go、Node、Rust 各写一套）：最快，但每支持一个工具就要改宿主，违反宿主对工具零依赖；第三方插件也用不上。否决。
2. **插件后端自己下载并安装**：插件可以完全控制，但用户看不到将要运行什么，宿主也无法统一提供取消、超时、位置选择和本地化失败原因；后端还没启动时（缺的正是后端命令）就无从安装。否决。
3. **只提示“请手动运行 xxx”**：安全但麻烦，用户要自己找终端并设对 `GOBIN`；用户明确要求提供自动安装按钮。作为退路仍然可用：对话框始终显示要运行的命令和环境，安装失败后用户可以照着手动运行。
4. **只支持装进 Lithe 管理的目录**：最可控，但用户已有 `GOPATH/bin` 习惯时会装出第二份。按用户选择，两种位置都提供，由用户在对话框里选。
5. **把装好的命令写进插件包目录**：卸载时自然删除，但插件包要保持签名后的原样，运行时写入会破坏校验。否决，改为 `.state`。

## 后果

- 收益：插件作者只写声明就能获得安装按钮、位置选择、取消和超时、本地化失败原因；宿主对 Go、Node 等工具没有任何特判。
- 收益：命令缺失导致的启动失败不再显示原始英文错误。
- 代价：打开“功能”页时，要为每个 `systemCommand` 启动查找一次命令。这一步在后台运行，有超时限制，不阻塞界面线程。
- 代价：安装会运行插件指定的工具和参数，所以需要 `commands.install` 权限，并在对话框里显示完整命令，由用户确认。
- 代价：`toolDefault` 装的文件不随插件卸载删除，用户需要自己清理。
- 尚未在原生窗口真机和 Windows 真机验证；`verificationStatus` 保持 pending。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'CommandInstall|CommandMissing|CommandOutput' -count=1`：合成插件 `dev.lithe.test.command-installers` 用复制出来的测试二进制当安装工具（不联网），覆盖缺失检测、两个目标的展开、受管安装后启动能找到命令、工具默认位置的探测与记录、非零退出/命令没落地/超时、取消停止工具且不留记录、拒绝插件没声明的目标、启动失败的本地化。
- `scripts/desktop/desktop-go.sh test ./internal/settingswindow -run 'CommandInstall|CapabilityCard' -count=1`：卡片状态、横幅、对话框内容、安装输出、完成后卡片清除、取消、失败文案。
- `scripts/desktop/desktop-go.sh test ./internal/pluginhost ./internal/core -count=1`：记录文件的读写边界和 Core 封装。
- `LITHE_VISUAL_OUTPUT_DIR=<目录> scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' -run TestVisualCommandInstall ./internal/settingswindow -count=1`：深浅主题的卡片与对话框截图。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：安装与启动后 app bundle 文件清单不变。

## 适用范围

Viva 客户端（`desktop/`）中插件 `systemCommand` 启动的命令查找与安装：`desktop/internal/core/command_installers.go`、`desktop/internal/pluginhost/commands.go`、`desktop/internal/pluginhost/launch.go`、`desktop/internal/pluginbackend/`、`desktop/internal/workbench/command_installers.go`、`desktop/internal/settingswindow/command_install.go`。契约与展开规则以 Lithe-core-rust 的 `shared/plugins/contract/v1/` 为准。插件包内自带的程序（`packaged` 启动）不走这里。
