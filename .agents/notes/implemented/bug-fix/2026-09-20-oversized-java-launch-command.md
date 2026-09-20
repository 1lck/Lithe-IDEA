# Agent 笔记：超长 Java 启动命令与失败可见性

状态：已实现

## 先说结论

Java 项目现在由项目 JDK 直接启动，JDT 解析出的运行时 classpath 会原样出现在命令行上。
若依 Plus 这类几十模块的工程有几百个绝对 jar 路径，命令行长度超过 Windows 的
32767 字符上限，进程根本创建不出来。现在超限时由 Core 把路径列表搬进 JDK 参数文件
（argfile，`java @文件` 读取的选项文件），宿主负责写和删；同时启动失败的真实原因
必须能显示出来，不能再被兜底文案吞掉。

## 问题

用户在 Windows 上运行若依 Plus，构建成功，运行面板打印出一条几万字符的
`java -cp <几百个 jar> org.dromara.DromaraApplication`，然后只显示一句
「Unable to start the run configuration.」。

这里其实是两个缺陷叠在一起：

1. **命令行超限**。`java.exe` 不是批处理文件，宿主直接走 `CreateProcessW`，
   它的命令行上限是 32767 个 UTF-16 字符，超过就失败（系统错误 206）。以前
   通过 Maven 启动时，这份 classpath 在 Maven 进程内部组装，不经过操作系统，
   所以同样的项目不会触发。改成直接启动 JDK 之后，长度问题才暴露出来。
2. **失败原因被吞掉**。Tauri 命令返回 `Result<(), String>`，失败时前端拿到的是
   **字符串**；而运行面板只在 `error instanceof Error` 时才取 `message`，否则
   显示兜底文案。这条路径也没有写日志，所以 6MB 的日志里关于这次失败一条记录
   都没有。无论根因是什么，用户看到的都是同一句没有信息量的话。

## 决策

### 正确做法

1. **Core 判断，宿主落盘。** 启动前调用
   `lithe_core::execution::plan_launch_command`：它估算命令行长度，超限时把
   `-cp`、`-classpath`、`--class-path`、`-p`、`--module-path` 这些「路径列表」
   选项搬进 argfile，返回文件内容和缩短后的参数。宿主只负责选临时路径、写文件、
   进程退出后删除。
2. **只搬路径列表。** JVM 选项、主类和程序参数留在命令行上；argfile 引用出现在
   原来第一个被搬走的选项位置，所以 JVM 选项仍在主类之前，程序参数仍在其后。
3. **转义由 Core 负责。** argfile 的引号字符串里反斜杠是转义符，Windows 路径的
   每个分隔符都要写成两个；带空格的路径靠引号保持为一个参数。
4. **按 JDK 版本决定能不能写。** JVM 启动器在任何字符集设置生效之前就展开
   `@file`：JDK 18 及以上按 UTF-8 读取，更早的版本用平台编码，JDK 8 根本不支持。
   宿主从 JDK 的 `release` 文件读出版本号（不用启动进程），交给 Core 判断：
   JDK 8 不写；内容是纯 ASCII 时任何 9 以上版本都能写；含非 ASCII 字符（例如
   `C:\Users\易林辉\.m2\...`）时只有 JDK 18+ 才写。否则保持原样，让宿主报出
   系统的真实错误——总比把 classpath 读成乱码、最后报一个找不到类要好。
5. **失败必须可见。** 宿主的失败消息带上系统错误、可执行文件和命令长度；
   前端把非 `Error` 的拒绝值也转成可读文本，并通过 `frontendTrace` 写日志。

### 不要这样做

- 不要在 Windows 宿主里自己判断长度、自己拼 argfile。判断和转义是确定性逻辑，
  放 Core 才能被两个平台复用，也才能脱离 Tauri 单独测试。
- 不要无条件写 argfile。只有「不这样做就必定失败」时才写，避免给本来正常的
  启动引入额外的文件依赖。
- 不要在前端只用 `error instanceof Error` 取消息。Tauri 命令失败时给的是字符串，
  这样写等于丢掉全部诊断信息。

## 考虑过的备选方案

- **改用 `CLASSPATH` 环境变量**：被否。Windows 对单个环境变量和整个环境块同样有
  32767 的限制，只是把同一个上限换了个地方。
- **生成 pathing jar**（用 manifest 的 `Class-Path` 间接引用）：暂不采用。它能兼容
  JDK 8，但要处理相对 URL 编码和路径空格，复杂度明显高于 argfile。等真的出现
  JDK 8 大工程需求再做。
- **退回 Maven 启动**：被否。那会把
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
  里已经解决的 `ClassNotFoundException` 重新带回来。
- **只延长/忽略长度，靠用户手动缩短依赖**：被否。用户无法控制传递依赖的数量。

## 后果

- 大型多模块 Maven 项目在 Windows 上可以启动，命令行只剩下一个 `@文件` 引用。
- 启动失败时用户和日志都能看到系统给出的真实原因，排查不再依赖猜测。
- 多了一个临时文件的生命周期要管：进程退出后删除，启动失败时立即删除。
  进程存活期间被外部清理临时目录会影响下一次启动，不影响已启动的 JVM。
- `@argfile` 需要 JDK 9 以上。JDK 8 上的超长 classpath 仍然无解，但那种情况
  今天本来就会失败，所以不构成回退。
- argfile 以 UTF-8 写入，并按上面的版本规则限制适用范围。JDK 9-17 且路径含
  非 ASCII 字符的组合仍然无法缩短，会以可见的系统错误失败；要覆盖这种情况需要
  pathing jar（清单里的路径是百分号编码的 ASCII），属于后续工作。
- Java **测试**的调试仍由 Java Debug Server 自己拉起 JVM，它的
  `shortenCommandLine` 默认是 `none`，因此大工程调试测试时仍可能超限。修它需要
  在启动请求里传 `argfile` 或 `jarmanifest`，本次未做。

## 验证

- Rust Core：`cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib launch_command`
  覆盖长度判断、argfile 生成与顺序、反斜杠和空格转义、无可搬运选项时不改写、
  以及可配置上限。
- Windows 宿主：`cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml run::tests`
  覆盖写入并删除 argfile、普通启动不写文件、失败消息包含系统原因。该 crate 需要
  Windows 或具备 GTK 依赖的环境才能编译。
- Windows 前端：`bun test src/features/run` 覆盖字符串拒绝值的显示与兜底文案。

## 适用范围

- Rust Core：`rust/lithe-core/src/execution/launch_command.rs`
- Windows：`windows/tauri/src-tauri/src/run.rs`、
  `windows/tauri/src/features/run/stores/run.store.ts`
- 共享契约：`shared/contracts/rust-core-api.md`
- 相关笔记：
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
