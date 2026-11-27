# Agent 笔记：工作台设置在后台串行落盘

状态：已实现

## 先说结论

设置回调复制当前设置并继续处理界面事件，工作台为每个设置目录安排一个按需启动的写入者。写入者拿到文件锁后处理最新的待写快照。正常关闭窗口异步等待写入排空，等待最多五秒。

## 问题

[#2021](https://github.com/1lck/Lithe-IDEA/issues/2021) 的基线只在文件锁已被占用时转后台。锁空闲时，窗口线程仍执行创建目录、重读、合并及原子替换。暂停写入器可以稳定重现设置回调不能返回。

## 决策

- 闲时没有写入任务，忙时每个设置目录最多保留一份正在落盘和一份待写快照。锁竞争期间仍可替换待写快照，写入期间可以接收下一份快照。
- 写入者拿到原文件锁后重新读取，为原子替换保留磁盘上的未知字段，依照 [#1943](https://github.com/1lck/Lithe-IDEA/issues/1943) 移走无法读取的原文件。失败进入原有设置保存日志和界面通知，通知通过窗口队列送达。
- 关闭窗口前把最新窗口尺寸一并入队。退出时文件系统若超过期限仍未返回，沿用工作台的有界关闭流程并记录超时。导入旧设置的回读和跨渠道更新的副本等待对应批次完成。新窗口启动另一个进程读取设置，也会等待本次保存，等待到期后仍可继续打开项目。

## 考虑过的备选方案

- 每次点击都创建一个独立写入任务。文件锁可以互斥，但等待顺序不等同于用户修改顺序，且连续修改会积累任务。

## 后果

新开的项目标签页在同一窗口有待写设置时先取内存快照。应用级设置在已有窗口之间的所有权与投递仍由 [#1851](https://github.com/1lck/Lithe-IDEA/issues/1851) 跟踪。

## 验证

在 Viva 无头工作台运行 `TestSettingsSaveReturnsWhileDiskWriteIsBlocked`、`TestSettingsSaveCoalescesPendingWritesAndFlushesOnClose` 和 `TestSettingsCloseProceedsWhenFlushDeadlineExpires`。锁竞争、窗口尺寸、未知字段和损坏文件另存由同一工作台包的回归测试验证。

## 适用范围

- `desktop/internal/workbench/settings_save.go`
- `desktop/internal/workbench/window_sessions.go`
- `desktop/internal/store/store.go`
