# Agent 笔记：Gradle 工程导入与 wrapper 固定

状态：已实现

## 先说结论

Lithe 打包的 JDT LS 已内置 Buildship，因此 Gradle 工程本就能被导入、索引与补全。本次改动不改这条链路，只把原本依赖 Buildship 默认值的 Gradle 导入显式化：由平台侧探测工作区根是否声明 Gradle 并是否带 wrapper，Rust Core 据此在 `settings.java` 下发 `java.import.gradle`。这样 Gradle 与 Maven 走同一套「平台探测 → Core 组装 → JDT LS」结构，行为不再依赖隐式默认值。

## 问题

Maven 工程有一套完整的显式设置链路：平台侧探测 `pom.xml` 与 settings.xml，Core 组装 `java.import.maven` 并通过 `StartServerRequest` 下发。Gradle 工程没有对应链路，能否导入完全取决于 Buildship 的默认开关。这带来两个问题：一是行为不可控，默认值变化或配置漂移时无法从 Lithe 侧纠正；二是与 Maven 不对称，后续要在 Gradle 上增加更多导入设置时缺少落点。Rust Core 看不到文件系统与环境变量，因此所有事实都必须由平台侧探测后传入，不能用 Core 自行假设。

## 决策

沿用 Maven 的既有形状，新增一条平行的 Gradle 链路，且只下发 Lithe 能确定的事实。

- 平台侧（Windows Rust，`windows/tauri/src-tauri/src/lsp.rs`）在解析 Java 启动信息时探测工作区根：存在 `build.gradle`、`build.gradle.kts`、`settings.gradle` 或 `settings.gradle.kts` 之一即判定为 Gradle 工程；再检测是否存在 `gradlew` 或 `gradlew.bat`，得到 `wrapperPresent`。非 Gradle 工程返回 `None`，避免给纯 Maven 工程下发 `java.import` 设置。
- Rust Core 新增 `JdtGradleConfiguration { wrapper_present }`，并在 `JdtSettings` 中与 `maven` 并列增加 `gradle`。`java_settings()` 在存在 `gradle` 时写入 `java.import.gradle.enabled = true`；有 wrapper 时附加 `wrapper.enabled = true`。`java_configuration_for_section()` 同步补齐 `java.import`、`java.import.gradle`、`java.import.gradle.enabled`、`java.import.gradle.wrapper`、`java.import.gradle.wrapper.enabled` 五个取值分支，使工作区配置查询与初始化选项保持一致。
- `StartServerRequest` 增加 `java_gradle` 字段，`RuntimeSession` 保存它，并在构造初始化选项与工作区配置时统一复用。wrapper 是工作区根在启动时的属性，会话生命周期内不变，所以只在启动时确定一次。
- 只下发 `enabled` 与 `wrapper.enabled` 这两项可以直接判定的布尔值。`java.home`、`version`、`offline.enabled` 等需要读取 Gradle 脚本或网络状态，Core 无法在启动时确定，一律不下发，交由 Buildship 自行解析。
- Windows 的构建文件指纹（`windows/tauri/src-tauri/src/lsp/jdt_workspace.rs`）补齐 `settings.gradle`、`settings.gradle.kts`、`gradle.properties`、`gradlew`、`gradlew.bat`，使这些文件的变更能触发 JDT 工作区重建。

TS 侧只做透传：`JavaLspLaunch` 增加可选的 `javaGradle`，`resolve-editor-lsp-launch.ts`、`lsp-core-adapter.ts`、`lsp-client.ts` 原样转发到核心的 `lsp.startServer`，不新增判断逻辑。

## 考虑过的备选方案

在 Rust Core 内直接读文件系统探测 wrapper。否决：Core 不接触文件系统与环境变量，破坏现有分层，也会让 macOS/Windows 的平台差异渗入 Core。

在 Core 中无条件下发 `java.import.gradle.enabled = true`。否决：会让纯 Maven 工作区多出无意义且可能误导的 Gradle 导入配置，违背「只下发确定事实」。

一次性下发完整的 `java.import.gradle`（含 `java.home`、`version`、`offline.enabled` 等）。否决：这些值需要读取 Gradle 脚本或网络状态，Core 在启动时无法可靠确定，下发错误值比不下发更糟。

让 macOS 侧也补 wrapper 探测。本次不做：改动范围限定为 Rust 内核与 Windows；macOS 依赖 Buildship 默认值即可导入 Gradle 工程，功能不缺，只是在显式固定 wrapper 上与 Windows 暂不对称。

## 后果

Gradle 与 Maven 在导入设置上结构对称，行为可预期、可扩展。Windows 会显式固定到工作区声明的 wrapper，避免用到机器上恰好安装的其它 Gradle 版本。macOS 未接入显式设置，行为仍由 Buildship 默认值决定，与 Windows 存在一处已知不对称。若工作区根未声明 Gradle 构建文件，Core 不会下发任何 `java.import` 设置，纯 Maven 工程不受影响。

## 验证

- `rust/lithe-core` 单测覆盖：初始化选项在导入前即携带 Gradle 设置、无 wrapper 时省略 wrapper 字段、无 Gradle 上下文时不下发 `java.import`、按 section 查询返回对应 Gradle 取值、无 wrapper 时省略 wrapper。
- `windows/tauri/src-tauri/src/lsp.rs` 单测覆盖：工作区指纹识别 Gradle 设置文件、根目录缺少构建文件时不判为 Gradle、识别 Windows 的 wrapper 脚本、Maven 工作区不产生 Gradle 上下文。
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
