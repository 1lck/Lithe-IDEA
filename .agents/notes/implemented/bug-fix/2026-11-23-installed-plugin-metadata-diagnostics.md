# Agent 笔记：已安装插件元数据降级时保留基本信息和诊断

状态：已实现

## 先说结论

已安装页面和跨插件函数转发都读取磁盘上的插件清单。读取或解析失败时，已安装页面保留插件的 ID、版本和路径，函数转发仍把其余声明交给 Core。两个入口用相同的单份清单大小上限，并通过统一日志记录各自的刷新结果。

## 问题

[#2364](https://github.com/1lck/Lithe-IDEA/issues/2364) 发现已安装页面整份读取清单，且忽略审批、读取与解码错误。工作区上下文变化时，观察者也忽略了函数转发的刷新错误，开发者无法从日志判断是哪一步失败。

## 决策

- 清单读取复用 `ReadInstalledManifest`，按已选版本的安装路径取文件。已安装页面也展示停用版本，所以沿用包含停用项的版本选择。审批失败时仍可展示可读的清单，清单失败时也仍可展示可读的审批。
- 函数转发把可读的声明交给 Core，并把损坏声明和 Core 刷新失败一并交还给观察者。观察者从通知锁退出后才记录失败。积压的观察者若读到同一个上下文修订号，只处理一次。下一次上下文变化会重新刷新。
- 只有取消导致的结束不产生告警。到达截止时间，或同时遇到实际故障时，仍经后台操作失败日志报告。

## 考虑过的备选方案

给每个坏清单立即发一条日志会让一次列表刷新产生多项告警，并重复报告同一个审批存储故障。工作台在收到部分结果后合并记录一次，保留包身份和失败阶段。

## 后果

单次刷新读取的每份清单都有上限，安装目录继续只读。诊断回调可以在通知锁释放后执行。单一上下文修订号内的瞬时失败会记入日志，后续上下文变化触发重试。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/pluginpkg ./internal/pluginservice -run 'TestReadFileEnforcesTheLimit|TestSyncFunctionRelayReportsBrokenManifest|TestWorkspaceContext'` 覆盖合成清单的读取边界、部分转发、诊断锁边界和报告频率。
- `./scripts/desktop/desktop-go.sh test -tags vivahead ./internal/workbench -run TestRefreshPluginStateKeepsInstalledFactsAndReportsMetadataFailures` 覆盖已安装行保留和一次合并诊断。

## 适用范围

桌面工作台的已安装插件资料、内存详情与语言服务停用提示，以及 `desktop/internal/pluginservice/` 的上下文刷新。
