# Agent 笔记：独立 Java 文件编译再运行（兼容 JDK 8）

状态：已实现

## 先说结论

没有构建系统的独立 Java 文件（`java.current-file`，以及没有 Maven 归属的
`java.main`）在一键运行时，Rust 核心不再直接生成 `java File.java`，而是先用
`javac` 把源码编译到 `.lithe/run/classes/<配置 id>/`，再用 `java` 按合格类名
运行。这样在 **JDK 8** 上也能一键运行——`java File.java`（JEP 330 单文件源码
启动器，下称“单文件启动器”）只有 JDK 11+ 才有，JDK 8 会把 `File.java` 当成
类名，报“找不到或无法加载主类 File.java”。日常开发只要记住：独立 Java 运行
计划现在会带一个编译前置步骤和一个结构化 classpath，宿主负责按序执行、按
平台分隔符拼接 classpath。

## 问题

一个只有裸 `src/main/java/Test.java`、没有 `pom.xml`/`build.gradle` 的项目，
用 JDK 8 一键运行会失败。根因是：Lithe 对独立 Java 文件生成的启动命令是
`java <文件>.java`，依赖 JDK 11+ 才有的单文件启动器。JDK 8 没有这个能力，
把 `Test.java` 当作类名解析，必然失败。本机验证：JDK 8 报错，JDK 11/17
正常打印结果；而 `javac X.java && java X` 在 JDK 8/11/17 上都成功。

因为 Lithe 支持的 JDK 版本跨度从 8 起，任何独立 Java 文件在 JDK 8 项目里
都跑不起来，不只 `Test.java`。

## 决策

统一“编译再运行”，不区分 JDK 版本：独立 Java 一律先 `javac` 再 `java`。
决策逻辑放在可单测的 Rust 核心（`create_launch_plan`），宿主只新增“按序执行
前置步骤、失败即止”的最小编排。

启动计划信封新增两个可选字段（向后兼容，为空时不序列化）：

- `preLaunchSteps`：有序的前置步骤数组，每个步骤是
  `{ executable, arguments, classpath? }`。宿主按顺序执行，任一步骤非零退出
  就中止本次运行并回传该步骤的诊断。步骤的 `executable` 复用主进程的
  `{ toolchain }` 形状，外加可选的 `tool` 选择器：`"javac"` 表示从工具链
  `bin` 目录解析出兄弟编译器；缺省表示默认启动器 `java`。
- `classpath`：结构化的 classpath 条目数组（工作区相对或宿主绝对路径）。
  **拼接归宿主**：宿主用平台分隔符（POSIX `:`、Windows `;`）拼接后，把
  `["-cp", 拼接结果]` 前插到对应的参数列表。核心绝不拼接 classpath，因为
  分隔符是平台相关的。

对独立 Java，核心生成一个 `javac -d .lithe/run/classes/<配置 id> <源码>`
前置步骤，把该输出目录放进运行 `classpath`，主进程 `arguments` 用合格
类名而不是源码文件。`<配置 id>` 会清洗（非 `[A-Za-z0-9._-]` 的字符替换为
`-`）以保证 Windows 文件名安全。

主类来源：`java.main` 优先取 `extensions.maven.mainClass`，缺失时回退到读取
源码用 `languages::java::standalone_launch_class` 推导；`java.current-file`
始终读取当前文件，用同一函数从 `package` 和声明的类名推导合格类名，默认包
回退为简单类名。若宿主传入项目 `classPath`（Maven 模块的 `target/classes`），
运行 classpath 为 `[输出目录, 项目 classPath]`（新编译的类在前，重建后优先
命中），编译步骤 classpath 为 `[项目 classPath]`（让源码引用能解析）。

宿主在用户**显式点运行**时才建立 `.lithe/run/classes/` 并写入 `.class`，
并在 `.lithe/.gitignore` 追加 `run/classes/`。打开项目本身仍不主动写
`.lithe/`（沿用“运行配置生成保持显式、打开项目不写 `.lithe/`”的既有约束）。

## 考虑过的备选方案

- **保留 `java File.java`，仅在 JDK < 11 时提示升级**：被否。等于告诉 JDK 8
  用户“这个项目跑不了”，没有解决一键运行诉求；且需要把 JDK 版本从宿主运行
  时发现层穿进 Rust 核心，破坏核心“平台中立、确定性”的边界。
- **只对 JDK 8 编译、JDK 11+ 仍走单文件启动器**：被否。需要核心感知版本号，
  两条分支都要维护和测试；统一编译再跑在所有版本上行为一致、可确定性单测，
  代价只是多一次 `javac`。
- **在 Rust 核心里用 OS 分隔符拼好 classpath 字符串**：被否。`:` 与 `;` 是
  平台相关的，拼接属于宿主职责；核心只输出结构化列表。
- **把 `.class` 写到系统临时目录**：被否。工作区内 `.lithe/run/classes/`
  可作为增量编译缓存保留、可 gitignore、路径可预测，便于诊断。

## 后果

- 收益：独立 Java 文件在 JDK 8/11/17 上都能一键运行；编译失败时直接暴露
  `javac` 的真实诊断，取代原先误导性的“找不到主类 File.java”。
- 代价：每次运行多一次 `javac` 编译；宿主新增“按序执行前置步骤”的编排
  路径（macOS `RunService`、Windows `run.rs`）。运行结束不清理
  `.lithe/run/classes/`（作为增量缓存保留，已 gitignore）。
- 边界：`java.current-file` 若文件无 `main`，在运行阶段报“无主类”——比旧的
  “找不到主类 X.java”清晰。

## 验证

- `./scripts/verify-rust-core-comments.sh`、`./scripts/verify-rust-core.sh`
- `./scripts/verify-shared-contracts.sh`、`./scripts/verify-service-boundaries.sh`
- `./scripts/verify-agent-notes.sh`
- `./scripts/test-macos.sh`；Windows 在 Parallels VM 上
  `./scripts/build-windows.ps1 -Configuration Release` 与
  `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml`
- Rust 用例：`rust/lithe-core/src/tests/run_configuration.rs` 的
  `plain_java_main_uses_the_jdk_without_maven`、
  `nested_maven_generation_keeps_standalone_java_on_the_jdk`、
  `current_file_compiles_then_launches_by_derived_class_name`、
  `current_file_run_classpath_prepends_output_ahead_of_project_classes`、
  `standalone_java_main_compile_then_run_matches_shared_fixture`
- 共享 fixture：`shared/fixtures/execution/standalone-java-compile-run-v1.json`
- 手动：用 JDK 8 打开裸独立文件项目，点运行 → 编译后打印结果（不再报找不到
  主类）；再用 JDK 17 复测。

## 适用范围

- Rust 核心：`rust/lithe-core/src/execution/configuration.rs`（`create_launch_plan`）、
  `rust/lithe-core/src/languages/java.rs`（`standalone_launch_class`）
- 契约：`shared/contracts/rust-core-api.md`（createLaunchPlan 段）
- macOS 宿主：`RunService`、`RustCoreBridge`、`ProjectRuntimeService`、
  `RunExecutableResolver`、`RunToolchainProviders`、`MacRunConfigurationStore`
- Windows 宿主：`windows/tauri/src-tauri/src/run.rs`、
  `windows/tauri/src/features/run/`
- 相关笔记：语言工具链与 Run/Debug JDK 的归属区分见
  `.agents/notes/implemented/architecture/2026-09-13-language-tooling-and-lsp-runtime-ownership.md`
