# Agent 笔记：Viva 确认安装即启用插件，卸载先停进程再清理状态目录

状态：已实现

## 先说结论

Viva 客户端从插件市场装好插件后，插件默认是禁用的，用户要再去打开开关，语言服务器才会启动；卸载后，插件写进 `<插件根>/.state/<插件 ID>` 的文件（例如解压出来的 JDK 源码）还留在磁盘上。现在的做法是：用户在审查框确认安装，就等于选择使用这个插件，插件直接启用，但用户以前明确禁用过的选择保持不变。卸载时先停掉插件的语言服务器和后端，再删除插件包、批准记录、启用选择和整个 `.state/<插件 ID>`。禁用插件时，同样停掉它的后端。

## 问题

旧 macOS 客户端早就规定“确认的首次安装会把插件记为启用，更新和重装不改已有选择”（见[Java 语言服务器是一个声明式插件](../architecture/2026-10-13-java-language-server-as-declarative-plugin.md)的“默认启用”和[Go 与 PHP 社区插件](../architecture/2026-10-20-go-php-community-plugins.md)）。Viva 重写插件管理时没有带上这条规则：`pluginstate` 规定“没有记录就是禁用”，确认安装后也不写记录。实测从 Lithe Store 安装 Java Navigation 后，打开 Java 文件状态栏一直是“LSP 未启动”，F12 没有反应。

卸载的问题有三层：

1. `pluginpkg.Uninstall` 只删版本目录，注释写明“状态目录不动”，`Manager.Uninstall` 也没有删 `.state/<插件 ID>`。
2. 工作台先在后台删包，删完才停语言服务器。服务器还在运行时，可能把刚删掉的状态再写回来；Windows 上，正在运行的可执行文件所在目录无法移动，删包会失败。
3. 插件后端（`BackendHost` 里的会话）在禁用、卸载时都没有停：`pluginservice.DetachBackend` 没有任何调用方，只有关闭项目时才全部停止。[Viva 插件后端按需激活](../architecture/2026-11-10-viva-plugin-host-services-and-backend-sessions.md)写的“插件停用或卸载时会话先摘除再停止”，此前并没有成立。

## 决策

启用规则和每个动作的步骤顺序由 Core 命令 `plugins.installed.lifecycle` 决定（实现在 Core 的 `rust/crates/plugin-lifecycle`，规则表和用例在 `rust/fixtures/plugins/installed-lifecycle.json`）。客户端只保存用户的选择、插件包和批准记录，把它们的身份交给 Core，再按 Core 返回的步骤逐条执行文件和进程操作。这样 Windows、macOS 和以后换的界面外壳共用同一套规则，不会各自再写一份。

- **谁是“启用”**：Core 按“插件”而不是“版本”回答启用状态，没有用户选择就是禁用。`pluginstate` 只读写选择（`SetEnabled`、`Forget`、`List`），不再自己判断启用；`pluginmanager.Manager.Installed` 用 Core 的回答。
- **确认安装即启用**：确认安装时，没有选择 Core 才返回“记录启用”这一步，有选择（无论启用还是禁用）就没有步骤。工作台在 `confirmPluginInstall` 提交成功后（包括只是批准记录写入失败的 `ApprovalError`）调用一次 `Manager.EnableInstalled`。卸载时 Core 返回“忘掉选择”，所以“卸载后重装”又会启用。
- **卸载顺序**：Core 返回的步骤依次是：停止插件程序 → 删除每个已安装版本（删成功才删它的批准记录）→ 忘掉选择 → 删除状态目录。`pluginmanager.Manager.Apply` 按顺序执行并汇总每个失败，“停止插件程序”由调用方传入：`pluginservice.Service.Uninstall(ctx, id, server)` 传的是先摘除并停止后端、再停止语言服务器（`Runner.Stop` 等到 Core 销毁会话才返回，进程此时已经退出）。工作台在窗口线程先用 `detachPluginServer` 把语言服务器移出登记表（不再接收请求、不会被重新启动），再把会话交给后台的 `Service.Uninstall`。
- **禁用顺序**：Core 先返回“记录禁用”，再返回“停止插件程序”，这样停止期间没有路径会把插件重新拉起来。
- **未安装的插件**：对没有安装版本的插件启用、禁用或卸载，Core 返回拒绝 `plugin.lifecycle.notInstalled`，`Manager` 报 `ErrUnknownPlugin`，不写任何选择，避免以后安装时被悄悄启用。
- **状态目录**：`pluginpkg.StateDirectory` 是 `.state` 的唯一定义（`pluginservice` 的 `pluginStateDirectory` 引用它）。`pluginpkg.RemoveState` 和卸载包一样，先把 `.state/<插件 ID>` 改名进 `.trash`，再递归删除，删除失败也不会把半份状态留在下次安装会读取的位置；它只处理目录，不跟随符号链接。`.state/host-secret` 和其他插件的目录不动。插件设置保存在应用偏好目录，不在 `.state` 里，所以卸载不会丢用户设置。

## 考虑过的备选方案

1. **保持“下载默认禁用”，在安装完成提示里引导用户去启用**：多一步操作，用户普遍以为装好就能用；与旧 macOS 客户端和 IntelliJ IDEA 的行为都不一致。放弃。
2. **每次确认安装都强制启用**：会覆盖用户“禁用后再更新”的明确选择。放弃，改为只在没有记录时启用。
3. **卸载时只删 `.state/<插件 ID>/<版本>`**：页面状态、工作区状态、日志在 `.state/<插件 ID>` 下按功能分目录，不在版本目录里，只删版本目录仍会留下大部分文件。放弃。
4. **启动时清理不再安装的插件的状态目录**：进程崩溃或并发时会删错，也让卸载结果依赖下次启动。放弃。

## 后果

- 用户从商店装好带语言服务器的插件，打开对应文件即可使用。
- 卸载会删除插件的全部运行时状态，包括较大的源码副本和索引；重装后需要重新生成，首次跳转进 JDK 会再解压一次。
- 卸载时要等进程停止（有界：语言服务器最长按 `pluginInstallTimeout`，后端按 `backendStopTimeout`），再删文件，卸载完成会稍晚出现在界面上。
- 构建 Provider、VCS Provider 和调试适配器进程仍没有在删包前停止，已建单 #1843。工作台三处写死 `".state"` 的路径拼接已建单 #1841。启用规则和步骤顺序已按 #1842 迁入 Core。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/pluginstate ./internal/pluginmanager ./internal/pluginpkg ./internal/pluginservice ./internal/workbench -count=1`：
  - Core 仓库 `cargo test -p lithe-core --lib installed_lifecycle`：逐条跑 `installed-lifecycle.json` 的用例，覆盖首次确认安装、禁用后更新保持禁用、卸载的步骤顺序、未安装插件的拒绝和非法请求。
  - `TestEnableInstalledKeepsAnExplicitChoice`：首次安装启用、禁用后升级保持禁用、未安装报 `ErrUnknownPlugin`、卸载后重装又启用。
  - `TestUninstallRemovesThePluginState`：删除本插件的 `.state/<插件 ID>`（含版本目录和 `pages/workspaces`），保留其他插件和 `host-secret`。
  - `TestUninstallStopsTheBackendBeforeRemovingThePlugin`、`TestDisableStopsTheBackend`：后端在删包前停止、禁用先记录后停止、其他插件后端不受影响。
  - `TestConfirmedInstallIsEnabledAndUninstallRemovesItsState`：工作台从磁盘安装并确认后插件已启用，卸载后插件包和状态目录都不存在。
- 2026-11-13 在 macOS 上用 `-tags vivahead` 构建的无头客户端（真实渲染，临时用户目录）从线上 Lithe Store 安装 Java Navigation 0.0.1：确认后显示“已启用”，F12 跳到项目内定义和 JDK `String.trim`，卸载后插件包、进程和 `.state/<插件 ID>` 都不存在，再按 F12 不跳转、不重新拉起进程，退出后无残留进程。Windows 共用同一份 Go 代码，尚未在 Windows 上验证。

## 适用范围

Viva 客户端（`desktop/`）的插件安装、启用、禁用和卸载：Core 的 `plugins.installed.lifecycle`、`desktop/internal/core/plugin_lifecycle.go`、`desktop/internal/pluginstate/`、`desktop/internal/pluginmanager/`、`desktop/internal/pluginpkg/install.go`、`desktop/internal/pluginservice/lifecycle.go`、`desktop/internal/workbench/plugins.go`。旧 Swift/Tauri 客户端的规则以各自原 Note 为准。
