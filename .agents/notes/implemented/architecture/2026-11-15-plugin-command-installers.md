# Agent 笔记：插件声明的命令缺失时由宿主安装

状态：已实现

## 先说结论

很多插件不打包自己要运行的程序，而是用本机已有的命令：Go 插件的语言服务器是 `gopls`，调试器是 `dlv`。以前这些命令不在时，用户只看到“plugin package path is not usable: none of the plan's commands is available”这类原始错误，也不知道怎么装。现在插件可以在清单里用 `commandInstallers` 声明“用哪个工具、跑什么参数来安装哪些命令”。宿主在插件详情“功能”页的能力卡片上显示“未找到 xxx”和安装按钮，用户在对话框里选择安装位置、看清要运行的命令后确认，宿主运行安装并记录命令所在目录，之后该插件的启动都能找到它们。宿主里没有任何针对具体插件或具体工具的代码。

有的命令没有可以用来安装的工具，只以压缩包发布，例如调试器 CodeLLDB。这时插件改为声明“下载安装器”（download installer）：写明每个平台压缩包的固定地址和 SHA-256，宿主在用户确认后下载、校验、解压到受管目录。插件包里不带这个程序，用户第一次需要时才下载。

## 问题

- 插件的 `systemCommand` 启动（语言服务器、构建、版本控制、调试适配器、后端）只在 PATH 和工具默认目录里找命令。找不到时，启动失败的原因是英文原始错误，用户不知道缺什么、该装到哪。
- 安装命令的方式因工具而异（`go install`、`npm install -g`、`cargo install`……），装到哪里也因工具而异（`GOBIN`、`GOPATH/bin`）。宿主如果按工具写死安装逻辑，就违反了“宿主对具体插件和工具零依赖”。
- 安装会运行下载代码的程序，必须让用户看清要运行什么、会不会联网，并且可以取消。
- 发行包在运行时只读，装好的命令不能写进 app bundle 或安装目录。
- 有的命令只以压缩包发布，没有工具能装它。CodeLLDB 就是这样，它每个平台一个 VSIX 包。如果把它打进插件包，每个平台的插件包都会多出几十 MB，不调试的用户也要下载。如果让用户自己下载解压，又容易放错位置，也没人校验内容。

## 决策

对应计划编号 API-23（工具链与受管进程）。

**谁负责什么**

- **插件声明**：清单 `commandInstallers[]`（`requires.commandInstallers: 0`，权限 `commands.install`），每项写明安装哪些命令（必须是本清单某个 `systemCommand` 启动用到的命令，且每个命令只归一个安装器）、用哪个已注入的工具（`tool`，必须同时列在 `requiresTools`）、参数、环境、超时（1–3600 秒，默认 600）、是否可能联网，以及支持哪些目标：
  - `managed`：装进 Lithe 管理的目录。参数或环境里必须出现 `${installDirectory}`，可用 `commandDirectory` 指出命令在安装目录下的哪个相对子目录。
  - `toolDefault`：装进工具自己的默认位置。用最多 4 个只含字面参数的探测命令（例如 `go env GOBIN`，再退到 `go env GOPATH` 的第一项加 `bin`）找出那个目录。
- **下载安装器**（`requires.commandInstallers: 1`）：安装器不写 `tool`，改写 `download`。`download` 包含版本号、每个平台的地址、可选镜像、SHA-256、压缩格式（zip 或 tar.gz）、要去掉的顶层目录，以及命令在解压结果里的相对目录。下载安装器只能装进 `managed` 目标。
- **Core 校验与展开**（Lithe-core-rust#53）：`plugins.commandInstallers.requirements` 列出每个 `systemCommand` 启动和它的命令、能安装它的安装器；`plugins.commandInstallers.plan` 把一个目标展开成参数、环境和命令目录；`plugins.commandInstallers.defaultDirectory` 从探测输出里取出目录。宿主不自己解释清单字段。
  - 下载安装器（Lithe-core-rust#133）：宿主把自己的平台传给 `requirements` 和 `plan`。没有当前平台压缩包的安装器不出现在 `requirements` 里，界面也就不提供安装按钮。`plan` 返回选中的压缩包和一个缓存键（cache key）。缓存键由压缩包内容身份算出，地址、版本、校验值、格式或目录变化时都会换一个，镜像变化不影响它。
- **宿主执行**（`desktop/internal/workbench/command_installers.go`）：
  - 缺失检测：按启动自己的查找方式找命令。调试适配器用调试的查找（macOS 上还会问 `xcrun --find`），其他用插件运行器的查找。两者都会加上已记录的安装目录。只有“找不到命令”算缺失，别的失败不提示安装。
  - 解析工具：在打开的项目里解析，项目固定的工具版本就是安装用的版本。
  - 运行：经 `buildprocess` 直接启动工具，不经过 shell。工作目录是项目目录，输出逐行送到对话框（每行有上限），到超时就停止，用户取消就停止。
  - 核对：工具退出码为 0 之后，再确认每个命令确实落在目标目录里，才写记录。
  - 下载安装器不运行任何工具，而是复用受管运行时（managed runtimes）的 `pluginruntime.Manager.Prepare`。这样，镜像测速、SHA-256 校验、在私有暂存区解压、路径不能逃出解压根、大小和条目数上限、`ready.json` 完成记录都和受管运行时一致，宿主没有第二套下载代码。解压结果发布之前，先检查每个命令都在命令目录里（Unix 上还要有执行位）。缺命令时整次解压丢弃，错误里写出在压缩包的哪个位置找过，例如 `codelldb-darwin-arm64.vsix/extension/adapter`。
  - 下载安装的布局是 `commands/<安装器 ID>/<缓存键>/`，里面是校验过的压缩包和解压出的一代文件。记录写好后，宿主删除同一安装器下其他缓存键的目录，也就是插件升级前固定的旧版本。删不掉的（例如 Windows 上旧版本的适配器还在运行）留到下次安装再删，不影响这次安装的结果。
  - 失败原因分开报告：下载失败、校验值不符、压缩包无效、命令不在压缩包里、超时。用户取消不算失败，不写失败日志。
- **记录与查找**（`desktop/internal/pluginhost/commands.go` 的 `CommandStore`）：
  - 受管目录是 `<插件根目录>/.state/<插件 ID>/commands/<安装器 ID>`。
  - 记录文件是 `<插件根目录>/.state/<插件 ID>/commands.json`，读取上限 64 KiB，先写临时文件再改名替换。
  - 之后的启动通过 `CommandStore.Lookup` 和 `Backend.ResolveCommand` 先在记录的目录里找，再按原来的方式找。
- **界面**（`desktop/internal/settingswindow/command_install.go`）：
  - 能力卡片显示“未找到 xxx”和安装按钮。没有卡片的后端命令显示在横幅里。
  - 对话框列出两个位置。工具默认位置探测不到时，该选项不可选并说明原因。
  - 对话框还显示要运行的命令和环境、是否可能联网。下载安装器的对话框不显示命令，改为显示下载地址、镜像和 SHA-256，并说明下载会联网、校验通过才会安装。下载时显示已下载和总大小的进度条。
  - 安装输出实时显示，失败原因全部本地化。命令缺失导致的启动失败（调试、构建、版本控制）也改用本地化提示。

**运行时写入位置**：只写插件根目录下的 `.state`。它属于平台存储目录，不在 app bundle 或安装目录里，所以不影响代码签名，也不影响 Sparkle 增量包的源基线。卸载插件时，Core 的卸载计划包含删除状态目录的步骤（`core.PluginRemoveState`），受管目录和记录随之删除。`toolDefault` 只记录目录，工具装进默认位置的文件归用户和工具所有，卸载不删除。

正确做法：新插件需要本机命令时，在清单里声明 `commandInstallers`，安装方式写成该工具自己的参数；需要知道工具把命令装到哪，就用 `directory` 探测，不在宿主里加分支。命令只以压缩包发布时，声明 `download`，给每个平台写固定地址和 SHA-256；升级这个命令就是发一个改了地址和校验值的插件版本。

不要这样做：在宿主里写“缺 gopls 就运行 `go install golang.org/x/tools/gopls@latest`”；也不要让插件后端自己下载并解压命令到插件包目录，插件包和发行包一样，运行时只读。也不要把 CodeLLDB 这类只在调试时才用的程序打进插件包。

## 考虑过的备选方案

1. **宿主为常见工具内置安装方式**（Go、Node、Rust 各写一套）：最快，但每支持一个工具就要改宿主，违反宿主对工具零依赖；第三方插件也用不上。否决。
2. **插件后端自己下载并安装**：插件可以完全控制，但用户看不到将要运行什么，宿主也无法统一提供取消、超时、位置选择和本地化失败原因；后端还没启动时（缺的正是后端命令）就无从安装。否决。
3. **只提示“请手动运行 xxx”**：安全但麻烦，用户要自己找终端并设对 `GOBIN`；用户明确要求提供自动安装按钮。作为退路仍然可用：对话框始终显示要运行的命令和环境，安装失败后用户可以照着手动运行。
4. **只支持装进 Lithe 管理的目录**：最可控，但用户已有 `GOPATH/bin` 习惯时会装出第二份。按用户选择，两种位置都提供，由用户在对话框里选。
5. **把装好的命令写进插件包目录**：卸载时自然删除，但插件包要保持签名后的原样，运行时写入会破坏校验。否决，改为 `.state`。
6. **把只以压缩包发布的命令打进插件包**（每个平台一个插件包）：不需要下载逻辑，但每个平台的插件包都变大，不用这个命令的用户也要下载它；升级命令也必须重新打插件包。用户明确要求像 Go 插件的 `dlv` 一样按需下载。否决。
7. **用受管运行时（`managedRuntimes`）声明这个压缩包**：下载和校验代码已经现成，但受管运行时在安装插件提交前就准备好，会让每个装了插件的用户都下载；它也不和某个 `systemCommand` 启动绑定，能力卡片不知道缺的是它。否决，只复用它的下载、校验和解压实现，不复用它的触发时机。
8. **像受管运行时那样，旧缓存键的目录一直保留到卸载插件**：受管运行时这样做，是因为旧插件版本和仍在运行的进程还会按旧路径读取（见[受管插件运行时](2026-11-18-managed-plugin-runtimes.md)）。命令安装不同：每个安装器只记录一个目录，记录换成新目录后，任何启动都不再找旧目录，留着只占磁盘，调试器这类程序每次升级都会多留一份。所以记录写好后就删旧目录。代价是：正在运行的旧版本命令在 macOS 和 Linux 上会失去尚未加载的文件，在 Windows 上则删不掉、留到下次。只有用户在旧版本运行时安装新版本才会遇到。
9. **写一个工具安装器，让它调用 `curl` 和 `tar`**：不用改契约，但各平台自带的下载解压程序不同（Windows 不一定有），校验值要插件自己核对，用户在对话框里看到的是一串 shell 命令而不是地址和校验值。否决。

## 后果

- 收益：插件作者只写声明就能获得安装按钮、位置选择、取消和超时、本地化失败原因；宿主对 Go、Node 等工具没有任何特判。
- 收益：命令缺失导致的启动失败不再显示原始英文错误。
- 代价：打开“功能”页时，要为每个 `systemCommand` 启动查找一次命令。这一步在后台运行，有超时限制，不阻塞界面线程。
- 代价：安装会运行插件指定的工具和参数，所以需要 `commands.install` 权限，并在对话框里显示完整命令，由用户确认。
- 代价：`toolDefault` 装的文件不随插件卸载删除，用户需要自己清理。
- 收益：下载安装器让插件包保持小，只有用到这个命令的用户才下载；下载内容必须和插件固定的 SHA-256 一致。
- 代价：下载安装器的版本固定在插件清单里，命令要升级就要发插件版本；没有当前平台压缩包时（例如 CodeLLDB 没有 Windows arm64 版本）不提供安装。
- 尚未在原生窗口真机和 Windows 真机验证；`verificationStatus` 保持 pending。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'CommandInstall|CommandMissing|CommandOutput' -count=1`：合成插件 `dev.lithe.test.command-installers` 用复制出来的测试二进制当安装工具（不联网），覆盖缺失检测、两个目标的展开、受管安装后启动能找到命令、工具默认位置的探测与记录、非零退出/命令没落地/超时、取消停止工具且不留记录、拒绝插件没声明的目标、启动失败的本地化。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'CommandDownload' -count=1`：合成插件 `dev.lithe.test.command-downloads` 的下载经假的 HTTP 传输完成（不联网），覆盖打开对话框不发请求、解压后记录且之后能找到命令、删除旧缓存键、再次安装不再下载、校验值不符/下载失败/命令不在压缩包里/条目逃出解压根各报对应原因且不留记录、取消不写失败日志、超时停止。
- `scripts/desktop/desktop-go.sh test ./internal/settingswindow -run 'CommandInstall|CapabilityCard|DownloadInstaller' -count=1`：卡片状态、横幅、对话框内容（含下载地址、镜像、SHA-256 和下载进度）、安装输出、完成后卡片清除、取消、失败文案。
- `scripts/desktop/desktop-go.sh test ./internal/pluginhost ./internal/core -count=1`：记录文件的读写边界和 Core 封装。
- `LITHE_VISUAL_OUTPUT_DIR=<目录> scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' -run TestVisualCommandInstall ./internal/settingswindow -count=1`：深浅主题的卡片、对话框、下载对话框和下载进度截图。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：静态检查运行时只通过 `desktop/internal/installedpackage` 定位安装包。受管安装和下载落在插件根的 `.state/<插件 ID>/` 下；`pluginpkg` 的 `TestInstallLeavesTheInstalledPackageUnchanged` 从仿造的已安装程序包运行，确认插件根和状态目录都在用户目录下，且安装包文件清单不变。脚本要求这个测试一直存在。

## 适用范围

Viva 客户端（`desktop/`）中插件 `systemCommand` 启动的命令查找与安装：`desktop/internal/core/command_installers.go`、`desktop/internal/pluginhost/commands.go`、`desktop/internal/pluginhost/launch.go`、`desktop/internal/pluginbackend/`、`desktop/internal/workbench/command_installers.go`、`desktop/internal/pluginruntime/`（下载安装器复用）、`desktop/internal/settingswindow/command_install.go`。契约与展开规则以 Lithe-core-rust 的 `shared/plugins/contract/v1/` 为准。插件包内自带的程序（`packaged` 启动）不走这里。
