# Agent 笔记：Java 调试与运行使用同一个 JDK

状态：已实现

## 先说结论

macOS 上 Java 调试启动的 JVM 现在就是“运行”会用的那个 JDK。调试不保存自己的 JDK 配置：它只说明“我要调试的是哪类目标”，再向运行所用的同一条选择链取 `java` 路径，写进调试启动参数 `javaExec`。所以改运行配置的 JDK、项目 JDK 或 `JAVA_HOME`，调试自动跟着变。

## 问题

用户调试 Java 程序时，被调试的 JVM 是 Java Support 插件包里的运行时，而不是项目配置的 JDK；运行同一个配置用的却是配置的 JDK。

原因是调试启动参数只带了主类、工作目录、classpath、程序参数、环境变量和 VM 参数，没有带 Java 可执行文件。Java Debug Server 在缺少 `javaExec` 时自己选 JVM，选中的是 JDT LS 进程所在的 JDK，也就是语言服务器的运行时。Java 语言服务器迁移成声明式插件之前，这个运行时在应用包里；迁移之后在插件包里，卸载或重装插件会直接换掉用户程序的调试 JVM，问题因此变得可见。

## 决策

### 正确做法

1. **调试不拥有 JDK 配置。** `DebugJavaRuntime` 只描述目标属于哪条选择链：
   - `.java(homeOverride:)`：Java 主类和当前文件配置，取运行配置的 JDK；没有运行配置时走项目 JDK 链。
   - `.maven(homeOverride:)`：Maven 类配置（Maven 模块、Spring Boot 等）和调试测试，取 Maven 的 JDK。运行配置里 Maven JDK 为空时退回该配置的 JDK，与 `MavenRunToolchainProvider` 一致。
2. **取值只有一个入口。** `ProjectRuntimeService.javaExecutableURL(forDebugging:)` 直接转到运行使用的 `javaExecutableURL(overridePath:)` 和 `mavenJavaHomeURL(overridePath:)`，不复制选择规则。
3. **JDK 不可用时调试失败，与运行一致。** 选择链返回空（配置的路径无效，或一个 JDK 都找不到）时抛出 `javaRuntimeUnavailable`，文案与运行相同。不能悄悄退回语言服务器的运行时，否则用户以为配置生效了。
4. **解析器保持无平台依赖。** `DebugLaunchConfigurationResolver` 通过注入的闭包取路径；没有注入时不写 `javaExec`，行为与修改前相同，单元测试和没有运行时服务的组合不受影响。

### 反例

- 给调试单独加一个 JDK 设置项：两处配置迟早不一致。
- 在调试路径里再写一遍“覆盖值 → 项目 JDK → `JAVA_HOME` → 探测”：规则会和运行漂移。
- JDK 无效时省略 `javaExec`：调试会落到语言服务器的运行时，掩盖配置错误。

## 考虑过的备选方案

- **向 JDT 请求 `vscode.java.resolveJavaExecutable`。** 它返回的是 JDT 为项目绑定的 JRE，由 `java.configuration.runtimes` 和执行环境名决定，不读取运行配置的 JDK，仍然和运行不是同一个来源。
- **让语言服务器直接运行在项目 JDK 上。** JDT LS 对自身运行时有最低版本要求，项目可以面向更低的 Java 版本；两者不能绑在一起。

## 后果

运行和调试对同一目标永远得到同一个 JVM。代价是：以前配置了无效 JDK 路径时调试还能靠语言服务器的运行时启动，现在会和运行一样直接报错。语言服务器自己仍运行在插件自带的运行时上，不受影响。Windows 调试启动参数目前同样不带 `javaExec`，尚未对齐。

## 验证

- `macos/Tests/LitheTests/RunConfigurationIntegrationTests.swift`：
  - `javaDebugRunsOnTheJDKRunSelectsForTheSameConfiguration`：无配置、Java 主类、Maven 模块（有无 Maven JDK）四种情况请求的运行时与写入的 `javaExec`。
  - `javaDebugFailsLikeRunWhenItsJDKIsUnusable`：JDK 不可用时抛出 `javaRuntimeUnavailable`。
  - `debugJavaRuntimeFollowsTheRunSelectionChain`：调试入口与运行入口返回同一路径。
  - `javaTestDebugLaunchUsesTheSharedRustConfiguration`：调试测试使用 Maven 的 JDK，未注入时不写 `javaExec`。
- 实际应用（2026-10-14，macOS）：以 `JAVA_HOME` 指向 `/Library/Java/JavaVirtualMachines/jdk-21.jdk` 启动，调试 Spring Boot 配置停在断点时，被调试进程与随后“运行”同一配置的进程都是该 JDK 的 `bin/java`，语言服务器进程仍是插件运行时；改为另一个 JDK 21 重启后调试 Java 主类，JVM 随之变为新的 JDK。未在界面里修改项目 JDK 设置后实测，也未实测无效路径的报错展示。
- `./scripts/test-macos.sh --filter '(RunConfigurationIntegrationTests|JavaTestDebugLaunchServiceTests|MavenRuntimeTests|RunWorkflowCoordinatorTests)'`。

## 适用范围

- `macos/Sources/Lithe/Services/Debug/DebugLaunchConfigurationResolver.swift`
- `macos/Sources/Lithe/Services/Java/ProjectRuntimeService.swift`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Tests/LitheTests/RunConfigurationIntegrationTests.swift`
- `shared/platform-feature-matrix/features/debug-java-runtime.json`
