# Agent 笔记：Windows 增量更新的补丁副本归 Viva 安装器所有

状态：已实现

## 先说结论

Lithe 0.8.0 和 0.8.1 在 Windows 上点“下载并安装”增量更新，应用会直接退出、没有装上新版，也不会重新打开。原因是 Lithe 在退出前删掉了补丁重建出的新版本目录，而 Viva 的 Windows 安装辅助脚本要等 Lithe 退出后才读这个目录。
修复放在 Viva：Windows 和 macOS、Linux 一样，在退出前先把新版本复制到安装器自己的暂存目录。Lithe 删除自己那份的做法保持不变。
更新器自己的缺陷只能从修好的版本开始生效：执行安装的始终是用户手里的旧版本。所以发布脚本不再给 0.8.2 之前的 Windows 客户端生成补丁，让它们下载完整安装包。

## 问题

- 增量更新（delta update，只下载新旧版本之间的差异补丁）在本机临时目录里，用已安装文件加补丁重建出完整的新版本，再交给 Viva 的 `update.Install` 安装。
- `desktop/internal/workbench/updates.go` 的 `installUpdate` 在安装器回调里先删除这份重建结果，再退出。代码注释的前提是“安装器此时已把它复制到自己的暂存目录”，这在 macOS 和 Linux 上成立。
- Windows 的 `installPayload` 只把原路径交给一个 PowerShell 辅助脚本，脚本等 Lithe 退出后才读取。目录已经不在了，脚本在 `try` 之外的 `Get-Item` 处停止：什么都没装，也没有重新启动旧版本。
- 失败发生在 Lithe 退出之后，日志里只有 `updates.update` 这条操作记录。进程退出前来不及记下“改用完整包”的标记，下次更新还走补丁，所以每次都复现。
- 在 Windows 11 虚拟机里装 0.8.0、通过界面更新到 0.8.1 复现：补丁已下载、应用退出、安装目录三个文件哈希不变、没有进程被重新启动。

## 决策

- **补丁副本的所有权写进 Viva 契约。** `InstallOptions.Payload` 由调用方持有，`Install` 在调用 `quit` 之前复制完自己需要的内容。调用方在 `quit` 之后删除自己那份是允许的。Windows 修复见 vivaui/viva#334，fork 先合入为 Lithe-IDEA/Lithe-viva#31。
- **Windows 辅助脚本读不到补丁时也要重新启动旧版本。** 解析补丁路径挪进 `try`，失败时恢复并启动旧版本；脚本在每条退出路径上删掉自己的副本。
- **Lithe 不为这个缺陷加绕过代码。** 不改成“Windows 上不删补丁目录”，那样会让 Lithe 依赖某个平台安装器的私有时序。
- **旧客户端改走完整安装包。** `scripts/ci/desktop-release/publish-update-feed.sh` 的 `WINDOWS_PATCH_FROM` 记录第一个能安装 Windows 补丁的版本。feed 提供的上一版本早于它时，Windows 不生成补丁，NSIS 完整安装包仍照常列出。macOS 和 Linux 不受影响。

正确做法：更新器（安装、补丁、重启流程）的缺陷修好后，同时检查已发布的旧客户端会不会继续走到同一条坏路径，必要时在 feed 里对它们关掉这条路径。
不要这样做：只发一个修好的新版，就认为老用户能通过应用内更新拿到它。

## 考虑过的备选方案

- **Lithe 在 Windows 上不删补丁目录，交给辅助脚本删除**：能修好新版本，但 Lithe 要知道 Windows 安装器的读取时序，三个平台的契约也不一样；按仓库规则，Viva 缺陷不在应用层绕过。
- **只修 Viva、不改发布脚本**：0.8.0 和 0.8.1 的用户收到 0.8.2 的 Windows 补丁时，运行的还是旧代码，会再次退出而没装上，修复到不了他们手里。
- **对所有平台都停发补丁**：macOS 和 Linux 的旧客户端安装补丁没有问题，没必要让它们改下完整包。

## 后果

- 0.8.2 及以后的 Windows 客户端可以正常安装增量更新。0.8.0 和 0.8.1 的 Windows 用户更新时下载完整安装包（约 17 MB，补丁约 4.4 MB）。
- Windows 安装补丁时多一次目录复制，耗时和 macOS、Linux 已有的复制相同。
- `WINDOWS_PATCH_FROM` 只要还有人运行 0.8.0 或 0.8.1 就得保留；去掉它之前先确认 feed 提供的上一版本已经不早于 0.8.2。

## 验证

- Viva：`go test ./update/`；Windows 上运行 `update` 包测试，其中 `TestInstallPayloadHandsTheHelperACopyTheCallerMayDelete` 和 `TestPayloadHelperRelaunchesTheOldVersionWithoutAPayload` 在修复前失败、修复后通过。
- 发布脚本：`node --test scripts/ci/desktop-release/publish-update-feed.test.mjs`，其中 `a Windows client of 0.8.0 gets the full installer, not a patch` 和 0.8.1 的同名用例在修改前失败。
- Lithe：`./scripts/desktop/desktop-go.sh test ./internal/workbench -run 'Update|Updates|Delta|Payload'`。

## 适用范围

- `desktop/internal/workbench/updates.go`
- `desktop/go.mod`
- `scripts/ci/desktop-release/publish-update-feed.sh`
- `scripts/ci/desktop-release/publish-update-feed.test.mjs`
- [vivaui/viva#334](https://github.com/vivaui/viva/pull/334)
