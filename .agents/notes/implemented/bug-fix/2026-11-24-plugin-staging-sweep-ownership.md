# Agent 笔记：插件暂存目录的跨进程清理

状态：已实现

## 先说结论

桌面安装、后台准备更新和卸载使用同一个用户插件根目录。启动时只有取得独占锁的进程才清理临时目录，使用临时目录的进程共同持有共享锁。这样在另一个窗口启动时，正在验包或等候用户批准的安装仍能继续。

## 问题

每个桌面进程会在加载插件服务时清理 `.staging` 和 `.trash`，原先假定此时没有安装或卸载。打开新窗口可能启动另一个进程。后台更新在发布待激活目录之前已经解包，用于串行发布的锁也无法覆盖此前的准备过程。

## 决策

- 使用写在用户插件根目录的 `.staging-sweep.lock`。安装和卸载从准备临时文件前到发布或清理完成为止持有共享锁。启动先探测是否有遗留目录，然后只尝试一次独占锁。获取锁后重新读取目录，目录正在使用时留给以后启动清理。异常退出时系统会释放锁，锁文件继续供其他进程使用。
- 包发布和审批记录继续使用原有的独占锁。用户等待审批时其他进程仍能准备各自的包，也能打开窗口。
- 例如：进程 A 解包并进入审批，进程 B 启动并读取插件列表。B 发现暂存目录正由 A 使用，略过启动清理，A 可以继续发布。取得独占锁后才读取临时目录，可避免用加锁前的列表误删刚创建的包。

## 考虑过的备选方案

- 扩大包发布独占锁以覆盖下载、解包和审批。审批时间由用户决定，持有该锁会让其他安装或卸载等到超时。
- 按文件修改时间删除旧目录。后台检查、用户审批和休眠都可能持续超过选定期限，目录年龄无法证明已经没有进程使用它。

## 后果

同时准备的包不互相等待，启动清理也不等待用户操作。其他桌面进程正在安装或卸载时，已中断任务的文件会留到下一次可清理的启动。锁文件随用户的插件数据根存在，位于发行包之外，因此不改变代码签名或应用增量更新基线。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/workbench -run TestPluginAutoUpdateStagesAnApprovedNewVersionUntilRestart` 在合成插件归档解包和发布之间运行第二个桌面插件服务，验证更新成功暂存，并在随后激活。
- `./scripts/desktop/desktop-go.sh test ./internal/pluginpkg ./internal/plugininstall ./internal/pluginservice` 验证遗留文件清理和安装包只读边界。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh` 检查 macOS 和 Windows 的发行目录只读门禁。

## 适用范围

- `desktop/internal/pluginpkg/install.go`
- `desktop/internal/workbench/plugins.go`
- `desktop/internal/workbench/plugin_auto_update.go`
- `desktop/internal/pluginservice/lifecycle.go`
