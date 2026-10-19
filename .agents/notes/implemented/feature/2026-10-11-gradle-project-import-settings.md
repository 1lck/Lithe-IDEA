# Agent 笔记：Gradle 工程导入的显式声明与工作区指纹

状态：已实现

## 先说结论

Lithe 打包的 JDT LS 已内置 Buildship，因此 Gradle 工程本就能被导入、索引与补全。本次改动不改这条链路，只把原本依赖 Buildship 默认值的 Gradle 导入显式化：平台侧探测工作区根是否声明 Gradle、是否带 wrapper 描述文件，Rust Core 据此在 `settings.java` 下发 `java.import.gradle`，并把 Gradle 工程的结构文件纳入工作区指纹。下发的两个开关与上游默认值相同，对今天的导入结果是空操作，它固定的是 Lithe 依赖的行为前提，并让 Gradle 与 Maven 走同一套「平台探测 → Core 组装 → JDT LS」结构。

## 问题

Maven 工程有一套完整的显式设置链路：平台侧探测 `pom.xml` 与 settings.xml，Core 组装 `java.configuration.maven` 与 `java.project.sourcePaths` 并通过 `StartServerRequest` 下发。Gradle 工程没有对应链路，能否导入完全取决于 Buildship 的默认开关，行为漂移时无法从 Lithe 侧纠正，后续要在 Gradle 上增加导入设置时也缺少落点。Rust Core 看不到文件系统与环境变量，因此所有事实都必须由平台侧探测后传入，不能用 Core 自行假设。

## 决策

沿用 Maven 的既有形状，新增一条平行的 Gradle 链路，且只下发 Lithe 能确定的事实。

- 平台侧（Windows Rust，`windows/tauri/src-tauri/src/lsp.rs`）在解析 Java 启动信息时探测工作区根：存在 `build.gradle`、`build.gradle.kts`、`settings.gradle` 或 `settings.gradle.kts` 之一即判定为 Gradle 工程；再检测 `gradle/wrapper/gradle-wrapper.properties` 是否存在，得到 `wrapperPresent`。判据与 Buildship 一致：它只在该描述文件存在时使用工程自带的 wrapper，`gradlew`/`gradlew.bat` 脚本本身不参与判断。非 Gradle 工程返回 `None`，避免给纯 Maven 工程下发 `java.import` 设置。
- Rust Core 新增 `JdtGradleConfiguration { wrapper_present }`，并在 `JdtSettings` 中与 `maven` 并列增加 `gradle`。`java_settings()` 在存在 `gradle` 时写入 `java.import.gradle.enabled = true`；有 wrapper 描述文件时附加 `wrapper.enabled = true`。两项都等于 JDT LS 自身默认值，因此这是显式声明 Lithe 依赖的前提，而不是改变导入行为。`java_configuration_for_section()` 同步补齐 `java.import`、`java.import.gradle`、`java.import.gradle.enabled`、`java.import.gradle.wrapper`、`java.import.gradle.wrapper.enabled` 五个取值分支，使工作区配置查询与初始化选项保持一致。
- `merge_java_settings()` 对 `import` 键按叶子合并：只覆盖 Lithe 拥有的 `gradle.enabled` 与 `gradle.wrapper.enabled`，调用方已声明的 `offline.enabled`、`version` 等键保持不变。
- `StartServerRequest` 增加 `java_gradle` 字段，`RuntimeSession` 保存它，并在构造初始化选项与工作区配置时统一复用。wrapper 是工作区根在启动时的属性，会话生命周期内不变，所以只在启动时确定一次。
- 只下发 `enabled` 与 `wrapper.enabled` 这两项可以直接判定的布尔值。`java.home`、`version`、`offline.enabled` 等需要读取 Gradle 脚本或网络状态，Core 无法在启动时确定，一律不下发，交由 Buildship 自行解析。
- 例外是用户自己选的构建选项（2026-10-18）：声明 `languageImport.kind: "gradle"` 的构建插件把离线和 Gradle User Home 映射到自己的选项，`build.languageImport` 解析成 `javaGradle.offline` / `userHome`，Core 只在用户设置了它们时下发 `offline.enabled` 和 `user.home`。这些是用户的选择，不是猜测，见[构建系统插件契约](../architecture/2026-10-17-build-system-plugin-contract.md)第 12 节。
- Windows 的构建文件指纹（`windows/tauri/src-tauri/src/lsp/jdt_workspace.rs`）加入 `settings.gradle`、`settings.gradle.kts`（模块结构变化，对应 Maven 的直接模块扫描）与 `gradle/wrapper/gradle-wrapper.properties`（Gradle 版本所在）。`gradle.properties` 刻意不加入：mod 工程几乎每次版本提升都会改写它，一旦纳入指纹，每次改动都会换用新的 JDT 数据目录并冷导入一次。会话中途的构建文件变更由 Core 的 `classify_change` 负责。

TS 侧只做透传：`JavaLspLaunch` 增加可选的 `javaGradle`，`resolve-editor-lsp-launch.ts`、`lsp-core-adapter.ts`、`lsp-client.ts` 原样转发到核心的 `lsp.startServer`，不新增判断逻辑。

## 考虑过的备选方案

在 Rust Core 内直接读文件系统探测 wrapper。否决：Core 不接触文件系统与环境变量，破坏现有分层，也会让 macOS/Windows 的平台差异渗入 Core。

在 Core 中无条件下发 `java.import.gradle.enabled = true`。否决：会让纯 Maven 工作区多出无意义且可能误导的 Gradle 导入配置，违背「只下发确定事实」。

一次性下发完整的 `java.import.gradle`（含 `java.home`、`version`、`offline.enabled` 等）。否决：这些值需要读取 Gradle 脚本或网络状态，Core 在启动时无法可靠确定，下发错误值比不下发更糟；需要这些值时应当作为用户可配置项引入，而不是由 Lithe 猜测。

按 `gradlew`/`gradlew.bat` 脚本判断 wrapper。否决：Buildship 实际依据是 `gradle/wrapper/gradle-wrapper.properties`，按脚本判断会与上游行为不一致。

把 `gradle.properties` 与 `gradlew` 一并纳入指纹。否决：前者在 mod 工程里变动频繁，纳入后每次版本提升都会冷导入一次；后者并不携带 Gradle 版本信息。收益不足以抵消代价。

让 macOS 侧也补 wrapper 探测与指纹扩展。本次不做：改动范围限定为 Rust 内核与 Windows；macOS 依赖 Buildship 默认值即可导入 Gradle 工程，功能不缺，只是在显式声明与指纹覆盖上暂不对称。

## 后果

Gradle 与 Maven 在导入设置上结构对称，行为可预期、可扩展。Windows 下发的两个开关与 Buildship 默认值一致，导入结果不变；真正改变行为的是工作区指纹：`settings.gradle` 或 wrapper 描述文件变化会换用新的 JDT 数据目录并重新导入，而改写 `gradle.properties` 不会。macOS 在 2026-10-18 经构建插件 `languageImport` 接入显式设置：`BuildSystemService` 等待 Core 归一化后，把 `javaGradle` 经语言会话和 Rust Swift 桥传给启动请求，离线和 User Home 选项等下次会话启动生效。没有插件输入时保留 Buildship 默认行为。macOS 尚未扩展指纹（`MacJdtWorkspaceState.buildFileNames` 仍只覆盖 `pom.xml`、`build.gradle`、`build.gradle.kts`），同一工程在两个平台上的指纹含义并不相同；真实 macOS 导入验收也仍待完成。若工作区根未声明 Gradle 构建文件，Core 不会下发任何 `java.import` 设置，纯 Maven 工程不受影响。

## 验证

- `rust/lithe-core` 单测覆盖：初始化选项在导入前即携带 Gradle 设置、无 wrapper 描述文件时省略 wrapper 字段、无 Gradle 上下文时不下发 `java.import`、按 section 查询返回对应 Gradle 取值、叶子合并保留调用方已声明的 `offline` 与 `version`。
- `windows/tauri/src-tauri/src/lsp.rs` 单测覆盖：工作区指纹识别 Gradle 设置文件与 wrapper 描述文件且忽略 `gradle.properties`、根目录缺少构建文件时不判为 Gradle、仅有 `gradlew` 脚本时不认为存在 wrapper、Maven 工作区不产生 Gradle 上下文。
- `windows/tauri/src/features/editor/lsp/resolve-editor-lsp-launch.test.ts` 与 `windows/tauri/src/platform/lsp-core-adapter.test.ts` 覆盖 TS 透传：有 Gradle 上下文时原样转发，无上下文时为 `null`。
- `scripts/verify-rust-core.sh`、`scripts/verify-rust-core-comments.sh`、`scripts/verify-rust-core-layout.sh` 校验 Rust 核心的格式、注释与包布局。
- `scripts/verify-platform-feature-matrix.sh`、`scripts/verify-platform-feature-matrix-change.sh` 与 `scripts/verify-agent-notes.sh` 校验功能矩阵与 Note 记录。
- 真实运行验证：在 Windows 打开一个带 Gradle wrapper 的工程，确认 JDT LS 通过 Buildship 完成导入与依赖解析，源码可跳转、补全并能高亮 Gradle 依赖中的类型。此项待实机确认，故功能矩阵验证状态仍为待验证。

## 适用范围

- `rust/lithe-core/src/lsp/languages/jdt.rs`
- `rust/lithe-core/src/lsp/interface/engine.rs`
- `windows/tauri/src-tauri/src/lsp.rs`
- `windows/tauri/src-tauri/src/lsp/jdt_workspace.rs`
- `windows/tauri/src/features/editor/lsp/java-lsp-host-api.ts`
- `windows/tauri/src/features/editor/lsp/resolve-editor-lsp-launch.ts`
- `windows/tauri/src/features/editor/lsp/resolve-editor-lsp-launch.test.ts`
- `windows/tauri/src/features/editor/lsp/lsp-client.ts`
- `windows/tauri/src/platform/lsp-core-adapter.ts`
- `windows/tauri/src/platform/lsp-core-adapter.test.ts`
- `shared/platform-feature-matrix/features/java-gradle-project-import.json`
