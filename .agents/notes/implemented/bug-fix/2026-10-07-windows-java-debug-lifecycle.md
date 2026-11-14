# Agent 笔记：Windows Java调试状态与资源生命周期

状态：已实现

> 2026-11-08 Viva 迁移：本文记录旧 Windows/Tauri 调试宿主的已实现行为及验证，
> 不代表 Viva 已完成 Java 调试接线。以下断点时序、停止状态和会话清理约束仍是迁移时
> 的参考；当前实现及验收状态应查功能矩阵和 Viva 代码，不得沿用旧平台测试结果。

## 先说结论

使用宿主既有request信封；在launch前同步断点。Core规范化事件进入同一暂停/继续状态处理，线程列表不能覆盖实际停止线程。调试器动作共享停止与线程请求所有者，并发释放等待同一Promise；Maven调试准备检查取消和工作区归属，编辑器装饰只观察既有调试状态。

## 问题

DAP请求参数与宿主信封不匹配、断点入队晚于启动、继续和单步异步回执覆盖新暂停状态，以及重复Stop提前返回，都能造成界面和实际会话矛盾。

## 决策

使用宿主既有request信封；在launch前同步断点。Core规范化事件进入同一暂停/继续状态处理，线程列表不能覆盖实际停止线程。调试器动作共享停止与线程请求所有者，并发释放等待同一Promise；Maven调试准备检查取消和工作区归属，编辑器装饰只观察既有调试状态。

## 考虑过的备选方案

不在前端重写DAP初始化或configurationDone；不按当前焦点终端停止进程；不在每个按钮里复制清理流程；不通过固定延迟等待下一次暂停。

## 后果

前端与适配器状态更一致；增加清理并发与过期响应测试。启动的进程/监听/装饰按会话释放，不改写安装目录。快捷键重新映射和选中配置工具栏是后续独立改动，不宣称完整IDEA调试能力。

## 验证

- [旧 Windows 客户端的测试清单（历史版本）](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/.agents/notes/implemented/bug-fix/2026-10-07-windows-java-debug-lifecycle.md) 覆盖 DAP 服务、事件、会话清理、动作、编辑器装饰、Maven 调试准备及进程事件。Viva 尚未接入对应调试宿主，不能运行这些旧测试来证明新客户端通过；迁移时需以相同生命周期场景补充两端测试。

## 适用范围

- ~~`shared/platform-feature-matrix/features/debug-java-runtime.json`~~（已随插件归属规则移出宿主，见 [插件的测试、功能矩阵和翻译只在插件仓库](../architecture/2026-11-14-plugin-owned-tests-matrix-i18n.md)）
- `shared/platform-feature-matrix/features/debug-state.json`
- `shared/platform-feature-matrix/features/debug-breakpoints.json`
- [旧 Windows 客户端的实现和原适用范围（历史版本）](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/.agents/notes/implemented/bug-fix/2026-10-07-windows-java-debug-lifecycle.md)
