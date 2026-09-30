# Agent 笔记：运行中的 Java 服务更新

状态：已实现

## 先说结论

macOS 和 Windows 的服务面板支持保存并编译正在运行的 Spring Boot 服务，交给
DevTools（Spring Boot 的开发期自动重启工具）处理更新。Java 调试面板支持通过
HotSwap（JVM 在原进程中替换已加载类）应用代码更改。所有操作绑定启动时的目标和
执行身份；构建完成不能冒充服务已就绪，也不能把旧操作应用到新启动的进程。

## 问题

仅在工具栏添加“热更新”会掩盖三种不同结果：编译了源码、替换了 JVM 类、或者
应用上下文已重启。多模块工程还可能更改运行路径，导致编译成功但原服务没有变化。

## 决策

复用打包的 JDT LS 和 Java Debug Server 0.53.2，不另写编译器、类文件扫描器或
JVM agent。Run 保留启动目标和源码路径；更新前重新向 JDT 查询运行路径并与原值
比较，路径变化时要求重启。保存和构建分别经过已有文档工作流和 Core 构建协调器。

调试器的自定义 `redefineClasses` 请求有实际结果才算完成。上游可能在 DAP
（调试适配器协议）的成功响应内返回 `errorMessage`，Core 必须将它变为操作失败，
不能终止整个调试会话。空类列表显示“没有可应用的修改”。更新不主动恢复暂停线程。
双端 Java Debug 启动禁用 DevTools 自动重启，避免类加载器被重新创建、丢失调试现场。
普通 Run 保持项目原来的 DevTools 行为；显式配置触发文件的项目仍由用户更新该文件。

正确示例：保存服务 A 的工作区，检查 A 启动时的路径，构建成功后更新 A 的原始
调试会话。不要根据用户后来选中的服务 B、当前编辑文件或最新配置重新推测 A。
停止、重启、切换工作区后不得发布旧结果；同一次执行中的重复点击不产生并行更新。

## 考虑过的备选方案

- 自己扫描 class 文件并实现 JVM agent：现有 Java Debug Server 已有完整能力，
  重复维护类加载、构建和调试状态没有收益。
- 所有服务都显示“无重启热更新”：普通 Run 没有调试通道，DevTools 会重建上下文，
  无法保证保留内存状态。
- 失败时自动重启：会丢失调试现场，因此先报告失败，由用户点击“重启服务”后执行正常启动工作流。
- 根据编译成功或某一行日志宣称服务就绪：不同项目的就绪条件不同，不应猜测。

## 后果

更新操作复用现有编译和调试基础设施，双端无需安装额外 agent。标准 JVM 仍不支持
任意结构修改；新增字段、改变方法签名等可能需要重启。JDT 的自动构建以及 DevTools
的监听规则仍由上游和项目配置决定，按钮不是事务隔离屏障，也不保证构建失败前完全
没有输出文件变化。第一版仅覆盖已有 JDT 启动元数据的本地服务，不支持远程 attach。

所有状态保存在内存中，随执行或工作区结束失效；编译产物位于工作区，JDT 状态沿用
平台存储 adapter。没有新增下载、缓存资源和发行目录写入，不影响签名或 Sparkle delta。

## 验证

- `./scripts/verify-runtime-bundle-immutability.sh` 检查双端安装目录只读边界。
- `./scripts/verify-shared-contracts.sh` 校验共享契约。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` 检查测试有界性。
- `./scripts/test-macos.sh` 执行 macOS 工作流测试。
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`
  执行 Windows 前端测试并记录单测试耗时。
- 原生验收：启动本地 HTTP 服务，修改方法体并更新，检查响应变化；Debug 检查 PID
  不变和暂停状态；Run 检查 DevTools 日志。追加结构修改、编译错误、依赖路径变化、
  双击、停止和快速重启场景，并对比运行前后发行目录清单或哈希。

## 适用范围

- `rust/lithe-core/src/debug/`
- `macos/Sources/LitheDebugModule/`
- `macos/Sources/LitheExecutionModule/`
- `macos/Sources/LitheLanguageIntelligenceModule/`
- `windows/tauri/src/features/run/`
- `windows/tauri/src/features/debugger/`
