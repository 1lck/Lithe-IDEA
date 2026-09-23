# Agent 笔记：Linux 产品复用 Tauri 工作台

状态：已实现

## 先说结论

Linux 版 Lithe 不再新建一套工作台，而是复用 `windows/tauri` 这套 React + Tauri
产品，通过 `src-tauri/tauri.linux.conf.json` 覆盖平台差异。开发者今后在
`windows/tauri` 里写的前端代码同时服务 Windows 和 Linux；只有真正平台相关
的行为（进程结束方式、字体枚举、内存采样、随包 JDK/JDTLS 配置目录、打包目标）
才允许按平台分支。Linux 上尚未实现的能力继续保持关闭，不返回假成功。

## 问题

Lithe 已有 macOS（Swift）和 Windows（React/Tauri）两套产品。要为 Linux
交付同等能力（终端、Git、LSP/JDTLS、Maven、运行/调试、文件、搜索、本地历史），
有两条路：写第三套产品，或让现有的 React + Tauri 产品跨平台。

写第三套产品的代价很高：工作台状态、编辑器集成、命令面板、设置界面和
`platform_invoke` 边界都要再实现一遍，共享的 `rust/lithe-core` 命令会出现
第三个消费者，任何前端行为变更都要改三处。而 Windows 产品本来就跑在
Tauri 上，Tauri 自身支持 Linux（WebKitGTK），因此真正的差异集中在少量
原生适配点，而不是整套界面。

## 决策

Linux 产品复用 `windows/tauri`。平台差异用 Tauri 的分层配置表达，不用
运行时判断堆在一起。

### 正确做法

- 打包与标识：`src-tauri/tauri.linux.conf.json` 负责 Linux 专属配置——
  标识符 `app.lithe.linux`、产物名 `lithe-linux`（`mainBinaryName`）、
  打包目标 `deb`/`appimage`、以及和 Windows 相同的无边框窗口。Windows 的
  标识符 `app.lithe.windows`、`nsis`/`msi` 目标移入 `tauri.windows.conf.json`，
  保证 Windows 用户的数据目录和安装包名字不变。基础 `tauri.conf.json`
  只保留两端共用的字段。
- 随包运行时：Linux 的 JDTLS 与 JDK 通过 `tauri.linux-jdtls.conf.json` 从
  `.artifacts/jdtls-linux`、`.artifacts/jdk-linux` 打进 `LanguageServers/`。
  这两个目录由 `scripts/prepare-jdtls-linux.sh`、`scripts/prepare-jdk-linux.sh`
  从 `third_party/` 清单下载校验后暂存；不要手工拷贝，也不要让 Linux 打包
  复用 macOS 的 `.artifacts/jdtls`。
- 随包 JDK 的权限：Temurin Linux 压缩包把部分文件标记为只读，Tauri 复制资源时
  会保留这些权限，于是第二次打包无法覆盖 `target/` 下的只读副本并报
  `Permission denied`。`prepare-jdk-linux.sh` 在解压后对整个目录执行
  `chmod -R u+w`，保证重复打包可用。
- 平台分支位置：进程结束统一走 `run.rs` 的 `terminate_process_tree`——Windows
  用 `taskkill /T`，Linux 先给进程组发 `SIGTERM` 再升级到 `SIGKILL`；因此
  启动子进程时必须在 Unix 上调用 `process_group(0)`，否则负 pid 会误伤自身
  进程组。字体枚举在 Linux 走 `fc-list`，内存采样读 `/proc`，JDTLS 的
  `config_linux`、无扩展名的 `bin/java`、Linux 的工具链根目录都按
  `cfg(target_os = "linux")` 分支。
- 凭据存储：`keyring` 必须是目标平台依赖——Windows 用 `windows-native`，
  Linux 用 `linux-native-sync-persistent` + `crypto-rust`，macOS 用
  `apple-native`。如果把 `windows-native` 留在通用依赖里，Linux 上会静默
  退化成内存 mock store，用户以为保存了密钥其实没有。
- 能力对齐：Linux 的能力集合对齐 macOS。WSL、Docker、GitHub、数据库、远程
  在 Linux 上仍由 `backend-capabilities.ts` 关闭，对应 invoke 直接拒绝；
  不要为了让界面“看起来能用”而返回空成功值。

### 不要这样做

- 不要在 `windows/tauri` 之外复制一份 React 工作台。共享命令、契约和夹具
  会立刻出现第三份消费者，`shared/contracts/` 的兼容性验证无法覆盖。
- 不要用运行时 `if (IS_LINUX)` 覆盖 Windows 专属路径的语义。例如把
  `.artifacts/jdtls` 和 `.artifacts/jdtls-linux` 混用，或在 Linux 上继续
  拼 `config_win`：语言服务器会启动失败或读到错误的配置目录。
- 不要把 Linux 的窗口做成 `transparent: true` 后继续套用玻璃外观。Linux
  窗口配置是不透明的，`platform-linux` 刻意不命中 `window-transparency.css`
  的玻璃规则。
- 不要假设 `bin/java.exe`。Linux 的随包 JDK 只有 `bin/java`，判断 JDK 根
  目录时必须允许无扩展名的可执行文件。

## 考虑过的备选方案

### 新建独立的 `linux/` 产品目录

这样两端互不影响，Linux 可以自由选择技术栈。但界面、状态、命令边界会与
Windows 版本分叉，共享行为需要第三份实现，`rust/lithe-core` 的契约验证
也要覆盖新消费者。当前真正的差异只有少量原生适配点，因此不采用。

### 保持 `windows/` 目录名，只把 crate 改名为通用名字

这样目录语义更准确，也不会让读者误以为只服务 Windows。但改名会波及
CI 路径分类、发布工作流、打包脚本和 `Cargo.lock`，收益只是命名。当前
用 `windows/README.md` 说明它同时服务两个平台，等目录重组有独立需求时再评估。

### 在 Linux 上继续用 `windows-native` 凭据后端

这样不需要改 `Cargo.toml`，代码能编译通过。但 `keyring` 在缺少平台后端时
会退化成内存 mock store，保存的密钥重启后消失且没有错误提示，属于伪造
成功。因此改为按目标平台声明后端。

### 让 `mainBinaryName` 只在 Linux 生效而不动基础配置

这样 Windows 产物名完全不受影响，代价最小。但它把“基础配置是 Windows 专属”
这个事实藏得更深。当前选择是把 Windows 专属字段显式移入
`tauri.windows.conf.json`，让基础配置真的中立；Linux 通过
`mainBinaryName: "lithe-linux"` 得到自己的产物名。

## 后果

- 收益：Linux 与 Windows 共用工作台、共享命令边界和 `lithe-core`，前端行为
  只需维护一份；平台差异集中在配置文件和少量 `cfg` 分支。
- 代价：`windows/` 这个名字不再只描述 Windows；`cargo check`/测试在 Linux
  上会执行 Windows 分支之外的代码路径，Windows 专属的 `cfg` 和测试必须
  显式标注，否则会在另一端产生假失败或死代码。
- 代价：Linux 打包依赖 WebKitGTK 4.1 及 Tauri 的系统包，`prepare-*-linux.sh`
  需要 `python3`、`curl`、`sha256sum`，与 macOS 的 `plutil`/zsh 脚本不共用实现。
- 需要重新评估的触发条件：Tauri 对 Linux 透明窗口或 `mainBinaryName` 的
  行为变化；Linux 需要独立的产品目录或独立发布节奏；WebKitGTK 之外的
  Linux WebView 方案被采纳。

## 验证

- `./scripts/prepare-jdk-linux.sh`
- `./scripts/prepare-jdtls-linux.sh`
- `./scripts/build-linux.sh`
- `./scripts/verify-windows-boundaries.sh`

`prepare-*-linux.sh` 校验下载产物的 sha256 并输出暂存目录；`build-linux.sh`
调用两者后执行 `bun install --frozen-lockfile`、`bun run typecheck`、
`bun run build` 和 `tauri build`，最后断言产物
`src-tauri/target/<triple>/{debug,release}/lithe-linux` 存在。
`cargo check`/`cargo test` 在 Linux 上必须零警告通过，Windows 分支由
`verify-windows-boundaries.sh` 与 Windows CI 保持。

## 适用范围

- `windows/tauri/`
- `windows/tauri/src-tauri/`
- `windows/tauri/src/platform/`
- `scripts/prepare-jdtls-linux.sh`
- `scripts/prepare-jdk-linux.sh`
- `scripts/build-linux.sh`
- `third_party/jdk/manifest.json`
