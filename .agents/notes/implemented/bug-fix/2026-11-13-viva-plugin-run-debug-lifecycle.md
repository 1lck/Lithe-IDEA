# Agent 笔记：Viva 插件动作注册、首次调试与运行进程回收

状态：已实现

## 先说结论

插件声明本身符合契约，也可能因为宿主接线不完整而无法显示 Run 或首次调试失败。Viva 现在把动作声明与工作区路由分开交给 Core 校验，注册变化后异步刷新文档，首次调试按需加载适配器。Run 启动的进程还会随附加调试会话在后台有界回收；Java 规则仍由独立插件和上游工具负责。

## 问题

这些路径来自 `0faecba491` 的 Viva 迁移：注册请求中的 context 被一并交给严格声明解码器，真实 Core 因额外字段拒绝；轻量假宿主没有解码器，原测试未覆盖。注册完成后也没有刷新已打开文档，动作可能要等用户再编辑才出现。

Run 发起调试时直接要求适配器目录已加载，但目录之前只会在 Debug 面板打开时加载。调试工具栏停止又只断开调试适配器协议（DAP）连接，没有回收 Run 自己启动的进程，真实 Java 调试中会留下仍暂停的 JVM（Java 虚拟机）。

## 决策

声明校验仍由 Core 严格执行；Go 只移除已经检查过的路由 context，不放宽未知字段规则。注册和撤回通知窗口排队刷新，锁内不调用插件，避免注册应答和动作查询相互等待。语言服务器就绪后也重新收集动作。

模型刷新未必修改文本，不能只凭文档文本版本接受动作查询的异步结果。窗口为每份文档持有动作呈现代际，清空或重新查询时推进它；晚到的旧结果不能覆盖新动作，也不能替换当前失败提示。Java 插件另行监听渐进导入的项目/classpath 事件并校验服务器代际，不将第一次 ServiceReady 等同于所有模块导入完毕。

Run 的首次调试复用既有适配器加载入口，完成后检查原调用是否取消。Run 原生进程所有者给附加会话一个有界停止回调，调试连接关闭后在后台调用；手动附加到外部进程没有回调，不接管外部进程所有权。

## 考虑过的备选方案

- 放宽 Core 声明解码：掩盖宿主把路由信息当成声明的错误，也允许其他无效字段通过。
- 要求用户编辑文件或先打开 Debug 面板：把接线时序变成操作前提，不能修复首次使用。
- 在 Java 插件里按 PID 杀进程：插件不拥有宿主进程树，会重复实现原生清理并误伤外部附加目标。

## 后果

首次打开 Java 文档即可出现动作，首次 Debug 不依赖面板预热，停止会清理所拥有的运行。代价是窗口多一个内部刷新通知和调试会话多一个进程清理回调；不增加公共插件 API。

旧源码兼容性另行判断：当前随包 ECJ 编译器拒绝 Java 5/7 源码级别，安全拒绝测试不能当成这些工程完整可运行。正常关闭的既有销毁重试噪声独立记录为 [#1860](https://github.com/1lck/Lithe-IDEA/issues/1860)，本修复不改变该策略。

## 验证

- 真实 Core 解码回归：动作/Provider 注册在修复前报 `plugin.host.invalidParams`，修复后接受并刷新；拒绝重复注册不触发刷新。
- 同文本版本下倒序送达两次收集结果：修复前旧空结果覆盖新动作，修复后保留新动作；测试直接控制送达顺序，无时间竞争。
- 未打开 Debug 面板的 attach/launch 回归：修复前返回适配器仍在加载，修复后按需加载并进入既有调试流程。
- `TestJavaPluginMavenWorkflow` 与旧布局矩阵：真实 ZIP、Maven、JDT 和调试器，验证断点变量、继续退出、再次调试后停止，以及安装目录哈希不变；停止回收回归在修复前超时，修复后退出。
- `scripts/desktop/desktop-go.sh test ./...` 与受影响包的 `-race`；本机证据来自 macOS arm64 无头工作台，原生窗口与其他平台未据此标记已验收。

## 适用范围

- `desktop/internal/pluginservice/hostactions.go`、`hostproviders.go`、`runs.go`
- `desktop/internal/workbench/debug_start.go`、`debug.go`、`pluginworkbench.go`、`pluginbackends.go`
- `desktop/internal/workbench/java_plugin_e2e_test.go`、`java_legacy_e2e_test.go`
- 通用职责边界见 [插件后端会话与宿主服务](../architecture/2026-11-10-viva-plugin-host-services-and-backend-sessions.md)。
