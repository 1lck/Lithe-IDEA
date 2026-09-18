# Agent 笔记：Java 项目的构建与启动边界

状态：已实现

## 先说结论

Java 项目里的 Main 类，以及能确定 Java 入口源码的 Spring Boot 服务，不再通过
reactor-wide Maven goal 运行。Lithe 先让
JDT LS / Java Debug Server 找到精确源码目标、构建它所属的项目，并解析运行时
classpath/module-path；随后 Run 模块只启动一次项目 JDK。Maven 仍负责
描述项目，但不再充当 Java Main 的启动器。

## 问题

把 Maven reactor 的“构建依赖”参数 `-am` 与 `exec:java` 放在同一条命令中，
会让 Exec goal 依次落到父工程和依赖模块。那些模块通常没有目标 Main 类，于是
在真正的应用模块启动前就报 `ClassNotFoundException`。单模块或结构碰巧简单的
项目可能成功，因此问题表现不一致。

## 决策

项目 Java Main 和已识别入口源码的 Spring Boot 服务，准备流程固定为：

1. `vscode.java.resolveMainClass` 按生成配置记录的精确源码路径选择目标；
2. `vscode.java.buildWorkspace` 构建拥有该目标的 Java 项目；
3. `vscode.java.resolveClasspath` 返回 runtime classpath 和 module-path；
4. Rust Core 接收结构化 `javaLaunch`，生成 `project-jdk` 直启计划；
5. macOS/Windows 宿主按各自路径分隔符拼接参数并启动一个 JVM。

Run 和 Debug 共用同一套 Java 项目准备逻辑。配置中的 Maven 信息仍用于 JDT LS
导入、Profile、settings.xml 和项目模型；Maven 工具窗口、框架 goal、测试与显式
Maven 任务仍走 Maven 启动计划。

Spring Boot 检测仍由 Maven 插件决定“它是不是服务”，不会把普通依赖模块误报成
服务。扫描到唯一的 `@SpringBootApplication` 源码后，配置同时记录入口类和源码；
此时 Run 走上述 JDT 直启流程。没有 Java 入口源码的特殊项目（例如入口不在可见
Java 源码中）仍可保留 Spring Boot Maven goal 兼容路径。
生成器 revision 随这项行为提升，旧工作区会自动重新生成配置，不要求用户删除
`.lithe/run/generated.json`。

`javaLaunch` 包含 JDT 确认的 `mainClass`、`classPaths`、`modulePaths`。缺少这些
项目元数据时直接提示等待或修复 Java 语言服务，不回退到 `exec:java`，避免把
原问题换成一次不确定的错误运行。JDT 对模块化项目返回的
`module/name.Type` 会转换为 JVM 需要的 `-m module/name.Type`。

## 考虑过的备选方案

- 先执行 `mvn compile`，再手工猜 `target/classes` 与依赖：被否。自定义输出目录、
  generated sources、测试源码、模块路径和非 Maven Java 项目都会重新造一套模型。
- 在 Maven Exec 上继续调整 `-pl/-am`：被否。Exec goal 与 reactor 生命周期绑定，
  无法稳定表达“构建依赖，但只在目标模块执行一次 Main”。
- 引入完整 Maven Embedder：暂不采用。体积和维护成本较高，而产品已打包 JDT LS
  与 Java Debug Server，后者已经提供成熟的构建和 classpath 解析能力。

## 后果

- 多模块 Maven 的 Java Main 和已解析入口的 Spring Boot 服务只会启动一次，不再
  在父模块或依赖模块找主类。
- Maven 生成源码、测试源码 Main 和 JPMS module-path 使用同一项目模型。
- 点击运行可能需要等待 Java 语言服务 ready；构建失败会阻止启动并保留真实诊断。
- 独立 Java 文件仍遵循“`javac` 编译再运行”的既有方案，不依赖语言服务。

## 验证

- Rust：Java Main 与已解析入口的 Spring Boot 服务启动计划必须是 `project-jdk`，
  参数不含 `-am`、Exec 插件或 Maven goal，并保留 JDT 返回的
  classpath/module-path。
- macOS：语言服务命令顺序为 resolve main → build workspace → resolve classpath。
- Windows：Run Store 把准备结果传入 Core，并分别用 `;` 拼 classpath/module-path。
- 共享契约：`shared/contracts/rust-core-api.md` 与
  `shared/contracts/application-boundary.md`。

## 适用范围

- Rust Core：`rust/lithe-core/src/execution/configuration.rs`
- macOS：`LanguageToolingSessionManager`、`AppModel+RunConfiguration`、`RunService`
- Windows：`java-run-launch.ts`、`lsp-core-adapter.ts`、`run.store.ts`
- 相关笔记：
  `.agents/notes/implemented/feature/2026-09-17-standalone-java-compile-then-run.md`
