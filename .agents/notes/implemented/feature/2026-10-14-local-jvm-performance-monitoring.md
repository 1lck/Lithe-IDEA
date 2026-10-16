# Agent 笔记：本地 JVM 性能监控的数据与生命周期

状态：已实现

## 先说结论

Performance 展示 Lithe 启动的目标 Java 进程的真实 CPU 和 JVM 堆数据。
堆计数复用目标 JDK 的 OpenJDK `jstat -gc -t`，CPU 复用 macOS 的进程计数；
不拿 Lithe 自身或目标进程的常驻内存冒充 JVM 堆。收起、切换、停止或销毁页面时取消采集。
暂不支持没有本地启动 PID 的远程附加目标，也不实现录制报告或 Show Results。

## 问题

本次对照的 Community revision 为 `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`。
核对其公开 platform/java/jvm/plugins 及 JetBrains profiler 公共仓库后，未找到参考图中
Performance 的 JVM 采集实现；公开 profiler API 不能证明存在可直接移植的 JVM 实现。
用户明确选择复用 OpenJDK 监控能力。UI 按参考布局接入现有 Lithe 主题和组件，不声称
复制了未公开的实现，也不引入商业分析器、额外 agent、私有协议或新的依赖。

`jstat` 已拥有 JVM 堆统计的解释权，Lithe 只按文档列名解析年轻代和老年代的使用量与
已提交容量，并排除元空间、压缩类空间等非堆数据。部分垃圾收集器不提供这些计数时
明确显示不支持，不能把缺失值当零。CPU 是目标进程的累计用户/内核时间增量，除以
单调时间间隔和逻辑处理器数，表示占全机逻辑 CPU 容量的比例。

## 决策

- `DebugPerformanceSampling` 是应用层接收采样的端口，只有进程 ID、Java 入口和数值数据。
  macOS 组合根注入 `MacDebugPerformanceSampler`；View 不创建原生进程。
- PID 来自现有 DAP 的终端启动回调，不扫描进程名猜测目标。工具使用该 Java 入口旁的
  `jstat`，不另行下载工具或修改目标启动参数。
- `MacDebugPerformanceSession` 使用已有 `MacStreamingProcess` 的进程组、输出与终止能力。
  初始及每次采样核对 PID 的启动时间，避免把退出后的 PID 复用误当作持续采样。
- `DebugPerformanceFeatureModel` 管理可见性、取消和过期结果。每个历史最多600点，最多
  保留16个目标；原生流只缓冲最新一条，避免主线程繁忙时无限堆积。
- DAP 会话不变而 PID 或 Java 入口改变时，取消旧采集并清空旧历史；相同目标重复登记
  不重启工具。否则重启后的 JVM uptime 会与旧运行的时间轴混在一起。
- 没有样本10秒后终止采集并报告错误；输出片段和诊断都设上限。正常结束保留已采集
  的历史，不伪造零值或延伸出不存在的采样。

正确做法是“已知启动目标 → 目标 JDK 的统计工具 → 有界原生流 → 当前可见会话”。
不要“按 java 名称找进程 → 用 RSS 画 Heap Memory → 隐藏面板后继续运行工具”。

## UI 与资源

图表复用系统 Swift Charts，折线、面积、悬停点对应同一真实采样。最近60秒的时间窗口
最新点在右侧，旧数据向左移动；600点历史不意味着同时压缩画在窗口内。共享字体、
主题色、背景图、分隔器和收起条保持与 Git Log 的对应组件一致。具体 UI 规则仍由
`2026-09-30-macos-shared-dropdown-style.md` 的 Debug 部分持有。

Java/JDK 资源保持只读。运行时没有新下载、解压或生成的应用资源目录，因此没有新增
可在 worktree 间共享的缓存。OpenJDK 自己管理系统临时性能数据；测试 Java 源文件只在
测试拥有的唯一临时目录生成并删除。应用 bundle 和安装目录不写入，不影响签名或
Sparkle 差分更新基线。未来若打包额外工具，必须先更新资源归属和 worktree 清单。

## 考虑过的备选方案

直接移植公开Community的Performance采集实现未找到可复用入口；商业或私有实现不在
许可范围内。自行嵌入Java agent/JMX服务会增加分发、安全与连接生命周期，因此本次
不采用；RSS不能表达堆使用量，也不采用。远程附加监控留待有明确目标身份端口后接入。

## 后果

复用JDK统计工具和原生进程计数，不新增依赖或第二套JVM堆语义。代价是目标必须提供
可用的本地JDK工具与计数器，采集粒度为秒级；缺失能力明确提示，不显示伪造图表。
若未来采用统一的公开跨平台采集器，应替换采样端口的原生实现，保留应用取消边界。

## 验证

- `DebugPerformanceSamplingTests`：分块解析、计量单位、非堆排除、异常/超长数据；
  可见性、会话切换、销毁、重启、错误和600点边界；使用有界事件门，不用睡眠同步。
- `DebugPerformanceChartTests`：明暗主题真实面积像素、初始右侧空白、固定时间窗口和
  真实采样吸附；不把缺失 CPU 值画成0%。
- `JVMPerformanceIntegrationTests`：显式设置 `LITHE_TEST_JAVA_EXECUTABLE` 指向测试 JDK
  才运行。启动临时 Java 源程序读取真实堆和 CPU，取消后检查工具 PID 实际退出，最后
  等待目标 Java 进程停止并清理文件。常规单元测试不依赖本机安装的 JDK。
- `scripts/verify-runtime-bundle-immutability.sh`、`scripts/verify-service-boundaries.sh`。

Windows 当前没有对应 UI/采集实现，矩阵明确标记缺失。完整用户项目的暂停、切换、
背景和 hover 验收与组件测试分别记录；不能用真实采集单测代替整个工作台验收。

## 适用范围

- `macos/Sources/Lithe/Core/Ports/DebugPerformanceSampling.swift`
- `macos/Sources/Lithe/Application/Features/DebugPerformanceFeatureModel.swift`
- `macos/Sources/Lithe/Platform/MacOS/Debug/MacDebugPerformanceSampler.swift`
- `macos/Sources/Lithe/Views/Debug/DebugPerformancePane.swift`
- `macos/Tests/LitheTests/DebugPerformanceSamplingTests.swift`
- `macos/Tests/LitheTests/JVMPerformanceIntegrationTests.swift`
