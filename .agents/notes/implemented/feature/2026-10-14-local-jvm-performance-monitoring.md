# Agent 笔记：本地 JVM 性能监控的数据与生命周期

状态：已实现

## 先说结论

Performance 展示 Lithe 启动的目标 Java 进程的真实 CPU 和 JVM 堆数据。
堆计数复用目标 JDK 的 OpenJDK `jstat -gc -t`，CPU 复用 macOS 的进程计数；
不拿 Lithe 自身或目标进程的常驻内存冒充 JVM 堆。收起、切换、停止或销毁页面时取消采集。
Test 的 Java 测试现在选择实际工作 JVM，以相同 jstat 端口采集 CPU 与堆内存；
显式 JFR 录制和 Show Results 复用 JDK 的命令工具。Performance 与 Details 合并为右侧
一个可收缩面板，以两个标签切换。非 Java 测试保留明确标注的进程树 CPU/RSS。
这两个内容页签按用户指定保留平面标签、矩形 hover 与底部3pt蓝色指示线，
使用 Community `DarculaTabbedPaneUI` 的下划线模式及明暗主题颜色。
Islands 的实际绘制覆盖会改成圆角选中块且不画下划线；用户已明确拒绝该形式，
因此这里保留指定外观和紧凑标题，不再套用 `LitheToolWindowTabStyle`。
暂不支持没有本地启动 PID 的远程附加目标。

Test Console 与 Debug、Run 使用相同的 `OutputTextView` / `LitheConsoleStyle`，
统一 INFO/WARN/ERROR 级别标签的颜色，不把正文整行重涂。Maven 测试计划通过 `-Dstyle.color=always`
保留管道模式下 Maven 自身的 ANSI 分段颜色与字重，渲染器仍按共享明暗色板显示。

## 问题

本次对照的 Community revision 为 `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`。
核对其公开 platform/java/jvm/plugins 及 JetBrains profiler 公共仓库后，未找到参考图中
Performance 的 JVM 采集实现；公开 profiler API 不能证明存在可直接移植的 JVM 实现。
用户明确选择复用 OpenJDK 监控能力。UI 按参考布局接入现有 Lithe 主题和组件，不声称
复制了未公开的实现，也不引入商业分析器、额外 agent、私有协议或新的依赖。

`jstat` 已拥有 JVM 堆统计的解释权，Lithe 只按文档列名解析年轻代和老年代的使用量与
已提交容量，并排除元空间、压缩类空间等非堆数据。部分垃圾收集器不提供这些计数时
明确显示不支持，不能把缺失值当零。CPU 是目标进程的累计用户/内核时间增量。Apple 的
[XNU fill_taskprocinfo](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)
写入 Mach 时间计数，原生入口使用 `mach_timebase_info` 转换为纳秒后，再除以
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

### 测试进程树

测试扩展和原生进程的 `running` 事件携带可选的真实启动 PID，`LanguageTestService`
在匹配 operationID 后发布到当前运行；停止、结束、重跑和关闭清除 PID，关闭同时清除
运行 ID。Test 使用独立的 `DebugPerformanceFeatureModel`，不会覆盖 Debug 会话历史。

Maven/Gradle 通常派生测试 JVM，只监测启动器会漏算测试负载。原生 adapter 先限定
在本次启动 PID 的后代内，再根据公开 JUnit、Surefire、Gradle Test Executor 入口确认
工作 JVM；通过 macOS 原生入口查询 Java 可执行路径与启动身份，不扫描整个系统的
java 名称。多个 worker 由用户选择，按启动身份隔离历史；没有独立 worker 的 Maven
in-process 模式和过短测试可显示无数据，不把构建 JVM 冒充测试。

内置 Gradle 测试计划对本次调用传 `--no-daemon`，已有常驻 daemon 不会被停止或复用。
Gradle 可按上游规则创建一次性 daemon，仍属于本次客户端的后代；因此现有 PID 与启动
身份验证继续有效，不扫描或附加其他任务的 worker。代价是每次 Gradle 测试额外启动 JVM，
普通构建保持原策略。自定义测试扩展若复用既有 daemon 且不提供当前操作的 worker 身份，
仍不受支持，应显示无可用目标，不能猜测同名进程。
依据：[Gradle Daemon](https://docs.gradle.org/current/userguide/gradle_daemon.html)。

`TestJVMPerformanceFeatureModel` 协调目标选择与显式录制，复用共享图表 Feature。
收起/切换到 Details 取消 live 采样；已经手动开始的录制保持到停止、worker退出或
120秒上限。停止请求失败时保留录制中状态和重试入口，禁止 Show Results 及开始新录制；
只有停止成功或 provider 确认目标退出后才结束。所有异步操作完成或失败后统一重新协调
发现轮询：隐藏且没有录制或忙碌操作时取消。重跑、关闭和销毁取消旧操作、停止本次
命名录制并删除其临时目录。

录制复用 JDK `jcmd JFR.start/stop` 与 `settings=profile`，最大64MiB、120秒，
`dumponexit=true` 保留正常退出时的结果。JDK `jfr summary/view hot-methods/view
allocation-by-site` 解释记录，UI 使用已有原生文本控件展示报告；没有自写 JFR 解析器
或商用 profiler 的火焰图。JDK 21 之前缺少 `jfr view` 时保留 summary 并显示工具错误。
工具命令各有10秒期限、取消与256KiB输出界限；仅操作PID加启动身份仍匹配的目标。

原生 CPU/RSS 进程树采样仍用于非 JVM 测试。其时间轴锚定根进程年龄，收起重开不从零
拼接；秒级采样会错过两个采样之间退出的进程，不是方法级性能归因。

## UI 与资源

图表复用系统 Swift Charts，折线、面积、悬停点对应同一真实采样。最近60秒的时间窗口
最新点在右侧，旧数据向左移动；600点历史不意味着同时压缩画在窗口内。共享字体、
主题色、背景图、分隔器和收起条保持与 Git Log 的对应组件一致。具体 UI 规则仍由
`2026-09-30-macos-shared-dropdown-style.md` 的 Debug 部分持有。

Java/JDK 资源保持只读。JFR仅在原生临时目录 `lithe-jfr-<uuid>` 生成单次录制，归属于当前运行，关闭/替换时
删除；资源清单以 `test-jfr-recordings` 明确排除跨工作树复制。没有新下载或可复用缓存。OpenJDK 自己管理系统临时性能数据；测试 Java 源文件只在
测试拥有的唯一临时目录生成并删除。应用 bundle 和安装目录不写入，不影响签名或
Sparkle 差分更新基线。未来若打包额外工具，必须先更新资源归属和 worktree 清单。

## 考虑过的备选方案

直接移植公开Community的Performance采集实现未找到可复用入口；商业或私有实现不在
许可范围内。自行嵌入Java agent/JMX服务会增加分发、安全与连接生命周期，因此 Debug
不采用；RSS不能表达堆使用量，Test 仅把它作为明确命名的驻留内存指标。远程附加监控留待有明确目标身份端口后接入。

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
- `TestJVMPerformanceFeatureTests` 与 `TestJFRIntegrationTests`：工作进程选择、隐藏时显式录制、worker退出、旧运行隔离；真实JDK启动、堆采样、JFR录制、热点/分配报告和临时资源清理。
- `ProcessTreePerformanceTests`：实际 shell 启动 CPU 工作子进程，验证真实启动 PID、
  根与子进程归属、CPU/RSS 样本和取消清理；超时关闭整组进程。
- `ExecutionModuleTests`：内置/扩展 PID 转发、重跑拒绝旧事件、停止及关闭清理。
- `scripts/verify-runtime-bundle-immutability.sh`、`scripts/verify-service-boundaries.sh`。

本轮本机显式启用 JDK 21 的88项相关回归通过，真实 JFR 集成检查4.276秒；补充4项
生命周期检查以及失败启动清理身份的单项回归通过，资源复用脚本14项检查通过。
实际 Maven 演示识别 Surefire 工作 JVM，显示 CPU 和堆，手动录制后切换 Details 不丢失
录制；正常退出自动结束，17秒 JFR 的热点报告识别演示方法占90.38%。关闭测试标签后
录制临时目录与采集进程均无残留。组件/真实采集证据不代替其他平台或自定义 runner 验收。

Windows 当前没有对应 UI/采集实现，矩阵明确标记缺失。完整用户项目的暂停、切换、
背景和 hover 验收与组件测试分别记录；不能用真实采集单测代替整个工作台验收。

## 适用范围

- `macos/Sources/Lithe/Core/Ports/DebugPerformanceSampling.swift`
- `macos/Sources/Lithe/Application/Features/DebugPerformanceFeatureModel.swift`
- `macos/Sources/Lithe/Platform/MacOS/Debug/MacDebugPerformanceSampler.swift`
- `macos/Sources/Lithe/Views/Debug/DebugPerformancePane.swift`
- `macos/Tests/LitheTests/DebugPerformanceSamplingTests.swift`
- `macos/Tests/LitheTests/JVMPerformanceIntegrationTests.swift`

审核回归增加非 Maven 成功/失败/取消、停止失败后重试、隐藏期间报告成功/失败与录制
启动失败。Gradle 真实集成测试显式设置 LITHE_TEST_GRADLE_EXECUTABLE、
LITHE_TEST_JAVA_EXECUTABLE、LITHE_TEST_JUNIT_JAR、LITHE_TEST_HAMCREST_JAR；
私有临时 Gradle user home 内先启动兼容常驻 daemon，再由产品测试计划启动实际 JUnit
测试，验证发现的 worker 属于本次客户端且既有 daemon 未被采样或停止，最后清理私有
daemon、测试进程和临时目录。该测试离线使用调用方提供的 JUnit/Hamcrest，不下载依赖，
单测试120秒、suite240秒；默认关闭，不依赖个人缓存路径。

本轮原生截图使用已有 Maven 演示项目。新建 Gradle 演示项目在完整应用导入后测试提供方
变为不可用，因此 Gradle 产品入口仍需另行验收；上面的真实集成只证明内置执行计划、
已有 daemon 共存时的 worker 归属和原生发现，不声称覆盖整个项目导入链路。

Gradle目标识别同时核对GradleWorkerMain与末尾的Gradle Test Executor正整数编号，
兼容DefaultWorkerProcessBuilder附加的单引号displayName。仅有通用入口、
Gradle Worker Daemon或异常名称不构成测试身份。真实集成开启fork编译，
用目标JDK的jps -lm确认通用编译worker与测试executor同时存活且前者未被选中；
自定义worker名称仍受既有身份识别限制，不回退到任意构建JVM。
