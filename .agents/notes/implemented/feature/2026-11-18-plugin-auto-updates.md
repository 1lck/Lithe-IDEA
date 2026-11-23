# Agent 笔记：插件自动更新必须守住用户已审批的来源和权限

状态：已实现

## 先说结论

插件自动更新默认关闭，用户可以从插件设置页齿轮菜单主动开启。开启后只自动安装**已经通过同一个插件市场来源授权、且新版本没有增加权限或改变程序声明**的更新；安装后保持当前运行中的插件不受干扰，重启 Lithe 后使用新版本。无法证明原安装来源或需要新授权时，继续使用原来的手动更新和审批窗口。

## 问题

当前插件市场能显示更新，并且下载包有 SHA-256 校验、插件安装有权限和程序审查，但这些步骤需要用户点击。把“有更高版本”直接等同于“可以无人值守安装”会允许另一订阅源冒充同 ID 的插件，或者绕过用户对新增程序和权限的确认。

## 决策

- 插件自动更新与应用自身的更新检查分开控制。默认不后台联网；开启 30 秒后首次检查，此后每 24 小时最多启动一轮。窗口在后台时推迟，重新激活后检查；关闭开关或退出窗口会取消下载和准备任务。
- 在市场层拿到 Core 规范化的 IndexURL；用户完成市场安装时，这个来源和原有权限/程序声明一起保存到批准记录中。早于此功能的记录没有来源地址，只能手动更新一次建立来源后才可自动更新；本地磁盘安装始终不自动更新。
- Core 已验证市场版本顺序和本机平台可用性，宿主不猜测语义版本排序。市场下载继续校验固定的 SHA-256，完整解包后由现有插件审查返回权限和程序声明。只有审批记录与新版权限/程序声明集合完全一致，才能自动提交；有变化直接放弃本次自动安装，用户手动确认后再更新。
- 安装前在运行时准备协调器内再次检查已安装版本、启用状态和旧版批准记录，不能覆盖下载过程中用户手动做的禁用、卸载或升级。仍复用现有托管运行时复用和插件包分版本存储，不强制停止正在运行的后台或语言服务器；提示重启后生效。

正确做法：原插件 1.0.0 已在某个 IndexURL 下授权，2.0.0 保持同样的权限和程序声明；开启自动更新后安装新版，并在原会话继续工作的同时提示重启。

不要这样做：只看插件 ID 相同就从另一个源替换，或把新增的终端权限和可执行程序视作旧审批覆盖；也不能以卸载旧插件的方式完成自动升级。

### 手动与后台共享增量下载

市场可在同一索引提交发布独立的补丁索引。旧客户端仍能读取主索引，新客户端先确定完整包，再看是否有与原审批中的旧包摘要匹配的补丁。用 Zstandard（zstd）将旧的原始 ZIP 作为参考，在平台临时目录重建目标 ZIP，并验证旧包、补丁和目标包的 SHA-256。缺少可用基线或重建失败时走完整包，取消会结束下载并清理临时数据。下载完成的 ZIP 可在用户缓存保留，以便后续生成精确基线。

桌面进程共享 ZIP 缓存。写入方从检查容量、淘汰旧归档到发布新归档持有同一把原生锁，避免两个进程按同一份旧容量各自写入。获取锁最多等待一秒。锁不可用时记录失败，已下载的包仍可用于本次安装。

同一进程内使用同一个插件数据根的工作台共享更新轮次。手动安装和后台暂存在提交阶段争用同一个插件安装入口。后台将包与审批一起准备完成后再提交到待激活目录。下次启动 Lithe 进程时在后台验包，读取启动项目和插件语言清单前复核原版本和审批，只有仍然符合的包才进入已安装目录。例如后台暂存 2.0.0 后再禁用 1.0.0，重启时丢弃待更新包。运行中的会话读取的仍是旧目录。

不同进程共享插件数据根。激活、手动安装、后台暂存、禁用和卸载使用同一个原生文件锁。卸载先取消并等待进程内的安装任务，再加锁让 Core 读取安装快照。这样即使另一个窗口刚刚激活新版，卸载计划也会包含它。锁文件保留在可写的插件数据根，进程退出时由操作系统释放锁。

## 考虑过的备选方案

- 默认无条件自动更新：用户没有同意后台下载或插件执行代码更换，拒绝。
- 只比较版本号，不检查来源、权限和程序：会让第三方源或新版程序跨越信任边界，拒绝。
- 在主索引加入可选补丁字段会让当前旧 Core 拒绝未知字段。重新压缩已安装目录也无法保证得到与旧 ZIP 一致的字节。独立索引与有界原包缓存让两条下载路径共享既有校验。
- 立即重启已运行语言服务器和插件后端：影响正在编辑/调试的工作区，也可能丢失临时状态；选择不在后台更新时强制重启。

## 后果

- 收益：用户明确开启后，符合旧审批范围的更新无需反复点击，也不会重复下载安装相同已装版本；托管运行时按现有复用策略避免重复下载。
- 代价：符合补丁格式的原始 ZIP 占用有限的用户缓存。无精确缓存基线时走全包，大包是否发布补丁由实际体积决定。
- 旧版市场插件需要一次手动更新以记录来源；权限/程序变化必须手动审核，后台没有弹窗。后台安装后需重启才能确保旧插件会话切换到新版本。
- 仍需原生跨平台验收：macOS 与 Windows 的窗口无头/真实插件更新、关窗取消与慢网络处理。未完成时功能矩阵保留 pending。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/plugintrust ./internal/marketplace ./internal/workbench -run 'TestMayAutoUpdate|TestNewerOffered|TestAutoUpdateCandidates' -count=1`
- `./scripts/desktop/desktop-go.sh test ./internal/marketplace -run TestMarketplaceDelta` 覆盖补丁命中、损坏、取消和已安装包只读。
- `./scripts/desktop/desktop-go.sh test ./internal/marketplace -run 'TestArchiveCacheKeepsBudgetAcrossProcesses|TestMarketplaceDeltaTransport'` 覆盖两个进程同时写入时的归档条数和字节上限，以及缓存锁不可用时继续交付已校验的 ZIP。
- `TestUninstallWaitsForPackagePublicationInAnotherProcess` 用两个进程验证卸载等待发布，并在重试后删除新旧两个版本。测试同时核验发行包内容未改变。
- `node scripts/i18n/generate-i18n.mjs --check`、`./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`、`./scripts/agent-notes/verify-agent-notes.sh`。
- 在合成插件市场的自动更新场景，观察安装文件、批准记录、运行中的旧进程和重启后新版本；拒绝案例不得提交任何安装。

## 适用范围

- `desktop/internal/workbench/plugin_auto_update.go`
- `desktop/internal/workbench/app.go`
- `desktop/internal/settingswindow/marketplace_view.go`
- `desktop/internal/plugintrust/auto_update.go`
- `desktop/internal/plugininstall/plugininstall.go`
- `desktop/internal/marketplace/service.go`
- `desktop/internal/marketplace/delta.go`
- `desktop/internal/marketplace/archive_cache.go`
- `desktop/internal/plugininstall/pending.go`
