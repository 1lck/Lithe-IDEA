# Lithe 桌面端开发启动指南（macOS / Windows / Linux）

本文说明如何在 macOS、Windows 和 Linux 上从源码构建并启动 Lithe 桌面客户端（`desktop/`，基于 Viva 的 Go 客户端），以及日常开发中常用的命令。

> `desktop/` 客户端目前在 [#1799](https://github.com/1lck/Lithe-IDEA/pull/1799) 的 `feature/1794-viva-workbench-shell` 分支上开发；该 PR 合入前，`preview` 分支里还没有 `desktop/` 目录。

## 目录

- [一、构建流程概览](#一构建流程概览)
- [二、三个平台共同需要的工具](#二三个平台共同需要的工具)
- [三、macOS](#三macos)
- [四、Windows](#四windows)
- [五、Linux](#五linux)
- [六、日常开发命令](#六日常开发命令)
- [七、开发版的数据目录](#七开发版的数据目录)
- [八、在多个 worktree 中开发](#八在多个-worktree-中开发)
- [九、提交前检查](#九提交前检查)
- [十、常见问题](#十常见问题)

## 一、构建流程概览

桌面客户端由两部分组成：

| 部分 | 语言 | 来源 |
| --- | --- | --- |
| 界面与平台适配（`desktop/`） | Go + [Viva](https://github.com/vivaui/viva)，经 [Lithe-IDEA/viva](https://github.com/Lithe-IDEA/viva) 固定到 commit（见 `desktop/go.mod` 的 `replace`） | 本仓库 |
| 共享内核 `liblithe_core.a` 和 IDE API 辅助程序 `lithe-mcp` | Rust | [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust)，修订固定在 `scripts/desktop/build-desktop-core.sh` 的 `PINNED_CORE_REVISION` |

Viva 由 `desktop/go.mod` 的 `replace` 固定到 Lithe-IDEA/viva 的 commit，修复先进 fork 再向上游提 PR，规则见 [Viva fork 维护与 commit 固定](../../.agents/notes/implemented/process/2026-11-11-viva-fork-maintenance-and-commit-pin.md)。

Go 通过 cgo 静态链接 Rust 内核，所以**不能直接运行 `go build` 或 `go test`**，否则会因为找不到 `lithe_core.h` 或 `liblithe_core.a` 而失败。所有 Go 命令都要经过 `desktop/Makefile` 或 `scripts/desktop/desktop-go.sh`，它们会：

1. 调用 `scripts/desktop/build-desktop-core.sh`：首次运行时把固定修订的 Lithe-core-rust 克隆到 `.artifacts/desktop/lithe-core-rust/source/`，用 Cargo 编译静态库和 `lithe-mcp`，再把头文件、静态库和链接参数暂存到 `.artifacts/desktop/lithe-core/<Rust target>/<profile>/`；
2. 设置 `CGO_CFLAGS`、`CGO_LDFLAGS` 等环境变量指向暂存目录；
3. 在 `desktop/` 目录中执行对应的 `go` 命令。

**首次构建需要从零编译 Rust 内核**（约 330 个 crate），之后只增量编译。耗时取决于机器：在一台 Apple 芯片 Mac 上，从克隆内核到产出客户端约 2 分钟；核数少的机器和 CI runner 会慢得多。首次构建需要能访问 GitHub（克隆 Lithe-core-rust、下载 Go 模块）和 crates.io。

只支持在本机系统上构建本机系统的程序，不支持跨操作系统构建。支持的组合如下：

| 系统 | 架构 | Rust target |
| --- | --- | --- |
| macOS | arm64（Apple 芯片）、amd64（Intel） | `aarch64-apple-darwin`、`x86_64-apple-darwin` |
| Windows | 仅 amd64 | `x86_64-pc-windows-gnu` |
| Linux | amd64、arm64 | `x86_64-unknown-linux-gnu`、`aarch64-unknown-linux-gnu` |

## 二、三个平台共同需要的工具

| 工具 | 版本要求 | 用途 |
| --- | --- | --- |
| Git | 任意较新版本 | 克隆本仓库和 Lithe-core-rust |
| Go | **1.27.3**（`desktop/go.mod` 的 `toolchain` 行） | 编译桌面客户端 |
| Rust | stable，通过 rustup 安装 | 编译 Rust 内核 |
| C 编译器 | 见各平台章节 | cgo 编译和链接 |
| GNU make 和 Bash | — | 运行 `desktop/Makefile` 和 `scripts/desktop/*.sh` |
| Node.js | 20.11 或更新，推荐当前 LTS | 只用于 i18n 和脚本检查，构建和运行客户端不需要 |

关于 Go 版本：不同 Go 版本的 `gofmt` 输出不同（1.27 对齐长 map 键的方式与 1.26 不一样），CI 用 `go.mod` 里的 1.27.3 检查格式。请安装 **Go 1.27.3**，并确认 `go` 和 `gofmt` 来自同一个安装：

```bash
cd desktop
go version          # 应输出 go1.27.3
command -v go gofmt # 两者应在同一个目录
```

本机装的是更旧的 Go 时，`go` 命令会按 `toolchain` 行自动下载 1.27.3，但 `make fmt` 直接调用的 `gofmt` 仍是旧版本；装的是更新的 Go 时，`go` 不会降级。这两种情况都会导致本地格式化结果和 CI 不一致。

## 三、macOS

客户端按 macOS 13.0 及以上编译（`MACOSX_DEPLOYMENT_TARGET=13.0`），Apple 芯片和 Intel 机器都可以开发。

### 1. 安装工具

```bash
# Xcode 命令行工具：提供 clang、make、git，以及 Rust 内核构建时 bindgen 需要的 libclang
xcode-select --install

# Go 和 Node.js（以 Homebrew 为例；也可以从 https://go.dev/dl/ 下载 go1.27.3 安装包）
brew install go node

# Rust（官方安装脚本）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

安装 Rust 后，重新打开终端或执行 `source "$HOME/.cargo/env"`。

检查：

```bash
clang --version && make --version | head -1 && go version && rustc --version && node --version
```

### 2. 克隆并启动

```bash
git clone https://github.com/1lck/Lithe-IDEA.git
cd Lithe-IDEA
git switch feature/1794-viva-workbench-shell

make -C desktop run
```

`make run`（等同于 `make dev`）会以 `dev` 构建标签编译 `.artifacts/desktop/bin/lithe` 并在前台启动。开发版的 Dock 图标带 “Dev” 角标，界面中的产品名不变。关闭窗口或按 ⌘Q 退出后，命令结束。

## 四、Windows

只支持 x86_64（amd64）Windows；`GOARCH=arm64` 会被构建脚本拒绝。

Rust 内核在 Windows 上必须编成 `x86_64-pc-windows-gnu` 目标，因为 cgo 无法链接 MSVC 的 `.lib` 静态库。下面的配置和 CI（`.github/workflows/desktop-ci.yml` 的 Windows 车道）一致：rustup 使用默认的 MSVC 主机工具链编译构建脚本和过程宏，再额外安装 GNU 目标，由 MinGW-w64 的 gcc 负责 cgo 编译和最终链接。

**以下所有命令都在 Git Bash 中执行**（Makefile 和构建脚本都是 Bash 脚本）；安装软件的命令可以在 PowerShell 中执行。

### 1. 安装工具

在 PowerShell 中：

```powershell
# Git for Windows（提供 Git Bash）
winget install --id Git.Git -e

# Go：从 https://go.dev/dl/ 下载 go1.27.3.windows-amd64.msi 安装。
# winget 安装的是最新版，可能高于 1.27.3，见第二节“关于 Go 版本”。

# rustup；首次运行 rustup-init 时按提示安装 Visual Studio 生成工具
winget install --id Rustlang.Rustup -e

# Visual Studio 生成工具的 C++ 工作负载（如果 rustup 没有帮你安装）
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"

# Node.js LTS
winget install --id OpenJS.NodeJS.LTS -e
```

在**以管理员身份运行**的 PowerShell 中，通过 [Chocolatey](https://chocolatey.org/install) 安装 MinGW-w64（与 CI 相同，同时提供 `gcc` 和 `mingw32-make`）：

```powershell
choco install mingw -y
```

打开一个新的 Git Bash，添加 Rust 的 GNU 目标：

```bash
rustup default stable
rustup target add x86_64-pc-windows-gnu
```

检查：

```bash
go version                       # go1.27.3 windows/amd64
rustc -vV | grep host            # host: x86_64-pc-windows-msvc
rustup target list --installed   # 包含 x86_64-pc-windows-gnu
gcc --version
mingw32-make --version
node --version
```

如果 `gcc` 找不到，先找到 `gcc.exe` 所在目录，再把它加入 `PATH`（可以写进 `~/.bashrc`）：

```bash
find /c/ProgramData/chocolatey/lib/mingw /c/ProgramData/mingw64 /c/tools/mingw64 /c/mingw64 \
  -type f -name gcc.exe -print -quit 2>/dev/null
export PATH="/c/<上一步输出的目录>:$PATH"
```

### 2. 克隆并启动

`.gitattributes` 没有为 `*.sh` 固定换行符。Git for Windows 默认的 `core.autocrlf=true` 会把脚本检出成 CRLF，Bash 运行时会报 `$'\r': command not found`。克隆时为本仓库关闭换行转换：

```bash
git clone -c core.autocrlf=false https://github.com/1lck/Lithe-IDEA.git
cd Lithe-IDEA
git switch feature/1794-viva-workbench-shell

mingw32-make -C desktop run
```

产物是 `.artifacts/desktop/bin/lithe.exe`。Windows 上 MinGW 提供的 GNU make 叫 `mingw32-make`，下文出现的 `make` 在 Windows 上都换成 `mingw32-make`。

## 五、Linux

Viva 的 Linux 后端通过 XCB 和 Vulkan 绘制，运行时用 `dlopen` 加载系统库，不捆绑任何库。因此：

- 需要 X11 会话；Wayland 会话下通过 XWayland 运行（需要设置了 `DISPLAY`）。
- 需要可用的 Vulkan 驱动。没有 GPU 的虚拟机可以使用 Mesa 的软件实现 lavapipe（Debian/Ubuntu 的 `mesa-vulkan-drivers` 包含它）。
- 中文输入法通过 IBus 协议组字（IBus，或 Fcitx5 的 IBus 前端）；不支持 XIM。

### 1. 安装系统包

Debian / Ubuntu（与 `desktop/viva.toml` 中 deb 包声明的依赖一致）：

```bash
# 构建所需
sudo apt update
sudo apt install -y build-essential git curl

# 运行所需：Viva 动态加载的 XCB、Vulkan、Cairo、Pango、Fontconfig 和 GLib
sudo apt install -y \
  libxcb1 libxcb-cursor0 libxcb-randr0 libxcb-render0 libxcb-shape0 libxcb-sync1 \
  libvulkan1 mesa-vulkan-drivers \
  libcairo2 libfontconfig1 libglib2.0-0 \
  libpango-1.0-0 libpangocairo-1.0-0 libpangoft2-1.0-0
```

Ubuntu 24.04 及更新版本中 `libglib2.0-0` 已改名为 `libglib2.0-0t64`，apt 会自动选择新包名。

可选组件：

| 包 | 用途 |
| --- | --- |
| `libgtk-3-0`、`libwebkit2gtk-4.1-0` | 在 Viva 中承载系统网页视图，首次打开网页内容时才加载 |
| `gnome-keyring`，或 KDE 的 KWallet | 提供 Secret Service，保存插件凭据需要 |
| `vulkan-tools` | 提供 `vulkaninfo`，用于排查 Vulkan 驱动问题 |

其他发行版可以按库名安装对应的包（以下映射未经 CI 验证）：

| 发行版 | 命令 |
| --- | --- |
| Fedora | `sudo dnf install gcc make git libxcb xcb-util-cursor vulkan-loader mesa-vulkan-drivers cairo fontconfig glib2 pango` |
| Arch Linux | `sudo pacman -S --needed base-devel git libxcb xcb-util-cursor vulkan-icd-loader cairo fontconfig glib2 pango`，再按显卡安装 `vulkan-radeon`、`vulkan-intel` 或 `nvidia-utils`（软件渲染用 `vulkan-swrast`） |

### 2. 安装 Go、Rust 和 Node.js

发行版仓库里的 Go 通常不是 1.27.3，建议使用官方压缩包（arm64 机器把 `amd64` 换成 `arm64`）：

```bash
curl -LO https://go.dev/dl/go1.27.3.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.27.3.linux-amd64.tar.gz
echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.bashrc

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Node.js 可以用发行版包或 [nvm](https://github.com/nvm-sh/nvm) 安装。重新打开终端后检查：

```bash
gcc --version && make --version | head -1 && go version && rustc --version && node --version
```

### 3. 克隆并启动

```bash
git clone https://github.com/1lck/Lithe-IDEA.git
cd Lithe-IDEA
git switch feature/1794-viva-workbench-shell

make -C desktop run
```

## 六、日常开发命令

在仓库根目录用 `make -C desktop <目标>`，或在 `desktop/` 目录中直接 `make <目标>`（Windows 用 `mingw32-make`）：

| 命令 | 作用 |
| --- | --- |
| `make run` / `make dev` | 编译开发版（`dev` 标签）并启动 |
| `make build` | 只编译开发版，输出到 `.artifacts/desktop/bin/lithe[.exe]` |
| `make core` | 只编译并暂存 debug 版 Rust 内核 |
| `make test` | 运行全部 Go 测试 |
| `make vet` | 运行 `go vet` |
| `make fmt` / `make fmt-check` | 用 `gofmt` 格式化全部文件 / 只列出需要格式化的文件 |
| `make check` | `fmt-check`、`vet` 和 `test`，与 macOS CI 车道相同 |
| `make package NO_SIGN=1` | 编译不带 `dev` 标签的发布版，并打包到 `dist/desktop/<os>-<arch>/` |
| `make version` | 打印 `desktop/viva.toml` 中的版本号 |
| `make clean` | 删除客户端构建和安装包（保留 Rust 内核缓存） |

只跑某个包或某个测试时，直接调用 `desktop-go.sh`。它会自己切换到 `desktop/` 目录，所以包路径相对于 `desktop/`：

```bash
scripts/desktop/desktop-go.sh test ./internal/editor -run TestName -count=1
```

常用环境变量：

| 变量 | 作用 |
| --- | --- |
| `LITHE_CORE_RUST_DIR=<Lithe-core-rust 检出目录>` | 使用本地的 Lithe-core-rust 检出，而不是固定修订，用于同时修改 Rust 内核 |
| `LITHE_DESKTOP_CORE_PROFILE=release` | 用 release profile 编译 Rust 内核，默认是 `debug` |

例如同时调试本地内核：

```bash
LITHE_CORE_RUST_DIR=$HOME/Dev/Lithe-core-rust make -C desktop run
```

暂存目录里的 `identity.txt` 记录了本次链接的内核修订、是否有未提交改动、来源（`pinned` 或 `override`）、rustc 版本、target 和 profile，可以用来确认实际用的是哪份内核。

打包说明：

- `make package` 默认产出 macOS 的 `app,zip,dmg`、Windows 的 `nsis,zip`、Linux 的 `tar.gz,deb`；用 `FORMAT=zip` 等只生成指定格式。
- 在 Apple 芯片的 Mac 上打 Intel 包：先 `rustup target add x86_64-apple-darwin`，再 `make package ARCH=amd64 NO_SIGN=1`。
- Windows 生成 NSIS 安装包需要 NSIS（`choco install nsis -y`）。

退出开发版后，确认没有残留进程：

```bash
pgrep -fl '.artifacts/desktop/bin/lithe'      # macOS / Linux
tasklist //FI "IMAGENAME eq lithe.exe"        # Windows（Git Bash）
```

## 七、开发版的数据目录

`dev` 标签只给 Dock 图标加 “Dev” 角标，**开发版和已安装的正式版 Lithe Desktop 读写同一套偏好、插件和日志目录**。调试会改写偏好或插件的功能前，先备份下表中的目录。

| 内容 | macOS | Windows | Linux |
| --- | --- | --- | --- |
| 偏好 | `~/Library/Application Support/Lithe Desktop/` | `%APPDATA%\Lithe Desktop\` | `~/.config/Lithe Desktop/` |
| 已安装插件 | `~/Library/Application Support/Lithe Desktop/plugins/` | `%LOCALAPPDATA%\Lithe Desktop\plugins\` | `~/.config/lithe-desktop/plugins/` |
| 日志 | `~/Library/Logs/Lithe Desktop/` | `%LOCALAPPDATA%\Lithe Desktop\Logs\` | `$XDG_STATE_HOME/lithe-desktop/logs/`，未设置时为 `~/.local/state/lithe-desktop/logs/` |

Linux 的偏好目录和插件目录按 `$XDG_CONFIG_HOME` 解析，表中是未设置该变量时的默认位置。

## 八、在多个 worktree 中开发

- 每个 worktree 有自己的 `.artifacts/desktop/`（Rust 内核检出、Cargo 输出和暂存库）。这些构建状态在 `scripts/resources/worktree-resources.json` 中登记为 `viva-core-build-state`，**不允许跨 worktree 复制**，所以每个新 worktree 第一次构建都要完整编译一次 Rust 内核。不要手工复制或共享 `.artifacts/`。
- Cargo 的 crate 下载缓存（`~/.cargo/registry`）和 Go 的模块缓存是全局共享的，新 worktree 不会重复下载依赖。
- 详细说明见 [`docs/ci-builds.md` 的“独立工作树的本地编译”](../ci-builds.md#独立工作树的本地编译)。

## 九、提交前检查

在本地运行与 CI 相同的检查：

```bash
make -C desktop check                                      # gofmt、vet 和测试
node scripts/i18n/verify-app-language-localization.mjs     # 界面文案都走 i18n
node scripts/i18n/generate-i18n.mjs --check                # i18n 生成结果是最新的
./scripts/macos/verify/verify-runtime-bundle-immutability.sh
```

- 新增或修改界面文案时，先在 `shared/i18n/` 补齐中英词条，再运行 `node scripts/i18n/generate-i18n.mjs`，规则见 [`shared/i18n/README.md`](../../shared/i18n/README.md)。
- 改动编辑器模块（`desktop/internal/editor/**`、`desktop/internal/editorview/**`）时，按 [编辑器性能基线](../../.agents/skills/develop-lithe/references/editor-performance.md) 在改动前后各运行一次 `scripts/desktop/perf/editor-bench.sh run`，把对比写进 PR 说明。
- PR 默认以 Draft 提交，Draft 只运行 Linux 检查；本地验证通过、可以评审时再用 `gh pr ready` 触发完整 CI。

## 十、常见问题

**直接 `go build` 或 `go test` 报 `lithe_core.h: No such file or directory` 或 `undefined reference to lithe_...`**

没有经过构建脚本，cgo 找不到 Rust 内核。改用 `make -C desktop build`，或 `scripts/desktop/desktop-go.sh <go 子命令>`。

**`Cross-OS builds are not supported`**

设置了与本机不同的 `GOOS`。只能在目标系统上构建该系统的程序。

**`No Lithe-core-rust target is configured for GOOS=... GOARCH=...` 或 `Windows arm64 is not supported`**

当前系统和架构不在第一节的支持列表中。

**`make fmt-check` 在本地通过、CI 失败，或反过来**

本地 `gofmt` 不是 1.27.3，见第二节“关于 Go 版本”。

**首次构建长时间停在 `git clone` / `git fetch`，或下载依赖很慢**

首次构建需要访问 GitHub、Go 模块代理和 crates.io。Go 模块可以改用国内代理：`go env -w GOPROXY=https://goproxy.cn,direct`；Cargo 可以按所选镜像站的说明在 `~/.cargo/config.toml` 配置 crates.io 镜像。克隆 Lithe-core-rust 仍需要能访问 GitHub。

**macOS：`xcrun: error: invalid active developer path`**

没有安装 Xcode 命令行工具，运行 `xcode-select --install`。

**macOS：链接时出现 `ld: warning: ignoring duplicate libraries: '-lSystem', ...`**

可以忽略。Rust 内核声明的系统库与 Go 自带的链接参数有重复，链接器去重后照常产出程序。

**Windows：`$'\r': command not found` 或 `set: pipefail: invalid option name`**

脚本被检出成了 CRLF。在仓库中执行：

```bash
git config core.autocrlf false
git rm -r --cached -q . && git reset --hard
```

注意 `git reset --hard` 会丢弃未提交的修改，先提交或备份。

**Windows：`cgo: C compiler "gcc" not found` 或 `exec: "gcc": executable file not found`**

MinGW-w64 的 `bin` 目录不在 Git Bash 的 `PATH` 中，见第四节“如果 `gcc` 找不到”。

**Windows：`linker 'link.exe' not found`**

缺少 Visual Studio 生成工具的 C++ 工作负载，rustup 的 MSVC 主机工具链编译构建脚本时需要它。按第四节安装。也可以改用 GNU 主机工具链（`rustup default stable-x86_64-pc-windows-gnu`）免装 Visual Studio，但这种配置未经 CI 验证。

**Windows：``can't find crate for `std` `` 或 `the x86_64-pc-windows-gnu target may not be installed`**

运行 `rustup target add x86_64-pc-windows-gnu`。

**Windows：`cgo cannot link the MSVC .lib archive`**

环境里把 `LITHE_CORE_TARGET` 设成了 `*-windows-msvc`。取消该变量（`unset LITHE_CORE_TARGET`），构建脚本会自动选择 `x86_64-pc-windows-gnu`。

**Linux：启动后没有窗口，或报 Vulkan、XCB 相关错误**

1. 确认第五节的运行库都已安装。
2. 确认在 X11 或 XWayland 下运行：`echo $DISPLAY` 应有输出。
3. 安装 `vulkan-tools` 后运行 `vulkaninfo --summary`，确认至少有一个可用设备；虚拟机中应能看到 `llvmpipe`（lavapipe）。

**Linux：无法输入中文**

确认输入法框架是 IBus，或 Fcitx5 启用了 IBus 前端。XIM 不受支持。
