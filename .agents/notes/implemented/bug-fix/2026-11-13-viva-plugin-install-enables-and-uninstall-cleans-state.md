# Agent 笔记：Viva 确认安装即启用插件，卸载先停进程再清理状态目录

状态：已实现

## 先说结论

Viva 客户端从插件市场装好插件后，插件默认是禁用的，用户要再去打开开关，语言服务器才会启动；卸载后，插件写进 `<插件根>/.state/<插件 ID>` 的文件（例如解压出来的 JDK 源码）还留在磁盘上。现在的做法是：用户在审查框确认安装，就等于选择使用这个插件，插件直接启用，但用户以前明确禁用过的选择保持不变。卸载时先等待语言服务器、后端、构建与版本控制提供者、调试适配器退出，再删除插件包、批准记录、启用选择和整个 `.state/<插件 ID>`；停止失败时保留文件。禁用插件时，同样停掉它的后端。

## 问题

旧 macOS 客户端早就规定“确认的首次安装会把插件记为启用，更新和重装不改已有选择”（见[Go 与 PHP 社区插件](../architecture/2026-10-20-go-php-community-plugins.md)）。Viva 重写插件管理时没有带上这条规则：`pluginstate` 规定“没有记录就是禁用”，确认安装后也不写记录。实测从 Lithe Store 安装 Java Navigation 后，打开 Java 文件状态栏一直是“LSP 未启动”，F12 没有反应。

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


### 安装审查跟随设置窗口

设置窗口的市场列表、详情和已安装页的更新入口先询问是否下载。确认后只授权传输。旧审查弹窗绘制在主窗口，会被设置窗口挡住。下载、进度、准备后的权限审查和安装结果现在都在发起操作的设置窗口显示。

工作台仍先校验归档 SHA-256，再用 Core 校验清单、身份、版本、能力和程序声明。对首次安装或历史批准不覆盖的包，设置窗口展示本次校验得到的完整权限和程序，用户点击「安装」后才提交并记录批准。市场包只有现有信任判定确认历史批准覆盖当前包时才直接进入安装。本地包始终展示完整声明并等待确认。

权限和程序声明较多时，详情区最多占 300 个逻辑像素，使用 Viva 的虚拟列表滚动查看。标题和确认按钮留在详情区外，程序声明保留完整的 JSON 内容。进入提交前取消、按 Escape 或关闭设置窗口会中止当前操作。后台任务丢弃迟到的准备结果并清理暂存目录。

下载时显示已接收和总 MiB，以及确定的字节进度。服务器没有提供大小时只显示已接收量；下载完成后切换为解压校验，避免把网络等待都称为校验。通知在传输线程合并，最多每 100 毫秒发送一次，开始和结束时另发一次；没有空闲轮询。

设置会话保留最近一个已完整校验的归档文件，最多沿用下载上限 512 MiB，不把归档内容留在内存。取消准备后再次安装相同来源和摘要时借用该临时文件；更换包、关闭设置和退出应用都释放保留的所有权。正在准备的任务单独持有文件所有权，直到读完才删除，避免关闭窗口时删除正在读取的文件。每次准备仍从同一文件句柄校验 SHA-256 再解压；排除用户取消和超时后的准备错误会淘汰保留文件，下次重试重新下载。

这个保留文件由 Go 原生文件适配器管理，只用于避免重复传输 Core 已选定的字节。可用性、插件身份、版本、审批和程序校验仍由现有 Core 流程决定；这不是可跨工作树、跨来源分享的构建缓存。写入只在系统临时目录，不影响发行包签名和 Sparkle 增量基线。资源复用清单明确拒绝复制这些文件。


已安装页在市场提供可安装的新版时才显示「更新到…」。此前的「重新安装」会把同版本交给普通安装器，安装器拒绝覆盖已有版本目录。


## 考虑过的备选方案

1. **保持“下载默认禁用”，在安装完成提示里引导用户去启用**：多一步操作，用户普遍以为装好就能用；与旧 macOS 客户端和 IntelliJ IDEA 的行为都不一致。放弃。
2. **每次确认安装都强制启用**：会覆盖用户“禁用后再更新”的明确选择。放弃，改为只在没有记录时启用。
3. **卸载时只删 `.state/<插件 ID>/<版本>`**：页面状态、工作区状态、日志在 `.state/<插件 ID>` 下按功能分目录，不在版本目录里，只删版本目录仍会留下大部分文件。放弃。
4. **启动时清理不再安装的插件的状态目录**：进程崩溃或并发时会删错，也让卸载结果依赖下次启动。放弃。

5. **准备完成后把主窗口拉到前面**。这会把用户从插件列表切走，仍需在两个窗口之间来回操作。采用设置窗口内的弹窗。

## 后果

- 用户从商店装好带语言服务器的插件，打开对应文件即可使用。
- 卸载会删除插件的全部运行时状态，包括较大的源码副本和索引；重装后需要重新生成，首次跳转进 JDK 会再解压一次。
- 卸载时要等进程停止（有界：语言服务器最长按 `pluginInstallTimeout`，后端按 `backendStopTimeout`），再删文件，卸载完成会稍晚出现在界面上。
- #1843 补齐构建提供者、版本控制提供者和调试适配器：卸载先阻断本插件的新启动，再等待所有项目标签（含隐藏标签）的原生会话结束，最后执行 Core 计划中的删包、清批准和删状态。停止失败或等待超时时保留文件；不能把“已经发送停止”当成“进程已经退出”。工作台三处写死 `".state"` 的路径拼接仍由 #1841 跟踪。启用规则和步骤顺序已按 #1842 迁入 Core。

### 卸载期间的原生启动与清理（#1843）

构建和版本控制提供者是独立进程，不属于插件后端或语言服务器；调试适配器还可能通过语言服务器共用连接。因此不能只调用后端停止，也不能在删包后的界面回调里清理这些进程。

桌面端按进程所有权等待原生清理，Core 继续决定卸载步骤。提供者从创建状态目录前开始登记启动，卸载取消启动并等待它完成；迟到的启动必须用独立的清理期限停止自己，不能用已经取消的启动上下文清理进程。版本控制列表刷新时保留启动阻断，避免替换运行对象后重新创建已删除的状态；用户重新启用或确认安装时，即使列表刷新已经移除了旧会话对象，也要恢复这个保留的启动入口。调试会话沿用原有的父子会话、Core 销毁和 Run 进程清理顺序，并额外发布清理完成事件供卸载等待。

正确做法是“阻断启动 → 等待原生退出 → 删文件”；不要在后台启动停止任务后立即返回成功，也不要忽略清理失败后继续删除。已登记的提供者停止失败时保留其原生句柄供重试；启动阶段发生无法确认的清理失败则继续阻断删除，退出应用完成进程清理后再重试。原生登记与等待只在存在插件任务时分配资源，不增加轮询、定时器或常驻线程。

多个用户生命周期操作重叠仍需要单独的共享事务，例如卸载等待时又从另一个标签启用或确认安装。现有独立后台入口的串行化与迟到回调归属债务由 [#1918](https://github.com/1lck/Lithe-IDEA/issues/1918) 跟踪；本修复验证单次卸载与正在启动、运行的原生会话之间的顺序，不声明多个包修改操作已具备原子性。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/pluginstate ./internal/pluginmanager ./internal/pluginpkg ./internal/pluginservice ./internal/workbench -count=1`：
  - Core 仓库 `cargo test -p lithe-core --lib installed_lifecycle`：逐条跑 `installed-lifecycle.json` 的用例，覆盖首次确认安装、禁用后更新保持禁用、卸载的步骤顺序、未安装插件的拒绝和非法请求。
  - `TestEnableInstalledKeepsAnExplicitChoice`：首次安装启用、禁用后升级保持禁用、未安装报 `ErrUnknownPlugin`、卸载后重装又启用。
  - `TestUninstallRemovesThePluginState`：删除本插件的 `.state/<插件 ID>`（含版本目录和 `pages/workspaces`），保留其他插件和 `host-secret`。
  - `TestUninstallStopsTheBackendBeforeRemovingThePlugin`、`TestDisableStopsTheBackend`：后端在删包前停止、禁用先记录后停止、其他插件后端不受影响。
  - `TestConfirmedInstallIsEnabledAndUninstallRemovesItsState`：工作台从磁盘安装并确认后插件已启用，卸载后插件包和状态目录都不存在。
- #1843 的自动回归使用虚构清单及复制的测试程序，不依赖任何具体插件：`TestUninstallWaitsForTheDebugAdapter`、`TestUninstallStopsProviderSessionsBeforeDeletingFiles` 检查进程先退出/销毁再删包；`TestUninstallWaitsForAProviderStillStartingInHiddenTab` 用受控事件检查取消、等待迟到启动、隐藏标签和卸载后的启动阻断；`TestUninstallPreservesFilesWhenProgramsCannotStop` 检查停止失败时包、批准和状态保留。macOS 已验证，Windows 文件锁场景仍需原生验证。
- 2026-11-13 在 macOS 上用 `-tags vivahead` 构建的无头客户端（真实渲染，临时用户目录）从线上 Lithe Store 安装 Java Navigation 0.0.1：确认后显示“已启用”，F12 跳到项目内定义和 JDK `String.trim`，卸载后插件包、进程和 `.state/<插件 ID>` 都不存在，再按 F12 不跳转、不重新拉起进程，退出后无残留进程。Windows 共用同一份 Go 代码，尚未在 Windows 上验证。

- `TestMarketplaceInstallEntryPointsShowProgressAndReview` 覆盖市场列表与详情入口、更新、进度、下载失败和迟到结果。
- `TestMarketplaceRequiresApprovalOfVerifiedDeclarations` 在修复前因未展示完整声明就批准安装而失败。修复后覆盖权限与完整程序展示、明确安装确认、取消、Escape 和关闭窗口。
- `TestMarketplaceReusesVerifiedApproval` 验证匹配的历史批准可以省去重复安装确认。`TestMarketplaceCancelBeforeVerificationDoesNotInstall` 覆盖下载取消，包括历史批准可复用但窗口已关闭的情况。`TestLocalPackageStillWaitsForInstallConfirmation` 验证本地包仍需主动确认。
- `TestPluginInstallReviewScrollsLongDetails` 验证长权限列表滚动到最后一条程序声明时，底部按钮保持可见且位置固定。
- `TestArchiveSessionReusesTheLastVerifiedTransfer` 覆盖重试不重新请求、摘要变化、替换/关闭时活跃借用不被删除，以及最终临时目录清空。
- `TestMarketplaceRetryReusesBytesAndStillRejectsTampering` 通过真实安装准备链验证重复审查只下载一次、拒绝审查后没有安装包或批准记录、被篡改的归档不进入审查，以及设置关闭后的清理。
- `TestPluginInstallShowsTransferBytesAndLocalVerification` 覆盖已知大小、未知大小与解压校验阶段的界面回显。
- `TestMarketplaceAsksBeforeDownloading` 在旧实现中因提前启动下载而失败；修复后覆盖确认、取消、Escape 和关闭窗口。市场列表、详情与已安装更新测试同时验证确认后才调用安装准备入口。
- 下载会话测试也覆盖旧包的准备错误迟到时，不会清掉较新的保留文件。macOS 与 Windows 的真实安装流程验收仍待完成。

## 适用范围

Viva 客户端（`desktop/`）的插件安装、启用、禁用和卸载：Core 的 `plugins.installed.lifecycle`、`desktop/internal/core/plugin_lifecycle.go`、`desktop/internal/pluginstate/`、`desktop/internal/pluginmanager/`、`desktop/internal/pluginpkg/install.go`、`desktop/internal/pluginservice/lifecycle.go`、`desktop/internal/workbench/plugins.go`。设置弹窗入口在 `desktop/internal/settingswindow/plugin_install.go`。


## 安装反馈补充

在 #1931 的设置窗口安装所有权和临时归档复用基础上，连接下载源、传输、校验、确认、安装与完成有分别的说明。失败保留在当前窗口并提供重试：市场和磁盘入口都重建反馈对象，旧任务只能更新自己的对象；仍由原有准备链重新校验和请求批准，不绕过 Core 审查。原始 I/O 错误进入既有统一日志，界面只显示本地化恢复建议，不泄露 URL、凭据或路径。成功需用户关闭完成提示，但不声称覆盖了用户原有的启用选择。

权限显示可读说明并保留原始 ID；技术声明默认折叠，展开仍可查看完整内容。内容列表限制高度，底部按钮不随声明滚动。下载复用、只读发行目录和关闭窗口后的清理沿用 #1931，不另建第二套安装状态。新增回归 `TestMarketplaceFailureOffersRetryInCurrentWindow` 在改动前因缺少重试入口失败；`TestInstallFailureGuidanceHidesNativeSecrets` 覆盖错误脱敏。原生终态、异常网络和 Windows 的完整验收仍未执行，不据此声称发版就绪。
