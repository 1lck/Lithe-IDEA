# Agent 笔记：Java 入口点和测试由 JDT 判定

状态：已实现

## 先说结论

“哪个 Java 类能运行”“哪个方法是测试”由 JDT（Eclipse 的 Java 语言服务，
Lithe 已经内置）回答，Lithe 不再用自己写的语法扫描判断。Issue #769 暴露了
这个问题：Java 25 允许 `static void main()` 这类新写法，Lithe 自己的规则还停在旧
Java，所以运行列表里没有它们。修法不是把规则改宽，而是删掉这套规则：以后
Java 再出新写法，只需升级 JDT。

开发者要记住一句话：**答案会随 Java 版本、编译设置或类型系统变化的问题，
交给 JDT；Lithe 只负责整理结果、排序、命名和产品分类。**

## 问题

运行列表由 Rust Core 用 tree-sitter（一种只看语法、不懂类型的解析器）扫描源码
生成。`rust/lithe-core/src/languages/java_syntax.rs` 的 `is_main_method` 要求
`static`、恰好一个参数，因此 Java 25 的无参 main、实例 main 全部漏掉。同一个
旧假设还复制在另外几处：`java.rs` 的 `main_declaration_index`、
`execution/configuration.rs` 的 `main_class_exists`，以及 macOS
`DebugLaunchSourceResolver.swift` 的正则。只改一处，另外几处照样会否决结果。

测试发现也是同一个问题：Windows 用 `java.testMethods` 在本地扫描注解，看不见
自定义组合注解（例如自己定义的 `@FastTest`）；macOS 先按 `*Test.java` 文件名
筛选，再去问 JDT，文件名不符合的测试在问之前就被丢掉了。

阶段 0 在 Linux 上实测（真 JDK 25 + 真 JDT）得出的事实：

| 写法 | JVM 能运行 | 当前 JDT 1.38.0 | JDT 1.61.0 | 当前 Lithe 扫描 |
| --- | --- | --- | --- | --- |
| `public static void main(String[])` | 是 | 是 | 是 | 是 |
| `static void main()`（#769） | 是 | 否 | 是 | 否 |
| 实例 `void main(String[])` / `void main()` | 是 | 否 | 是 | 否 |
| 紧凑源文件（整个文件没有 `class`） | 是 | 否 | 是 | 否 |
| 从父类继承的 main | 是 | 否 | 否 | 否 |
| `private` main、返回 `int` 的 main、字符串里的示例 | 否 | 否 | 否 | 否 |

结论：**只改成“问 JDT”而不升级修不好 #769**，当前锁定的 JDT 1.38.0（2024-08）
本身不认识这些写法。

## 决策

### 版本组合

JDT 及插件作为一个整体锁定，并由真实 JDT 测试证明可用：

- JDT LS 1.61.0
- Java Debug 插件 0.53.2（来自 `vscode-java-debug` 0.59.0）
- Java Test 插件 0.43.1（来自 `vscode-java-test` 0.46.0）
- 运行 JDT 的 JDK 仍是内置 Temurin 21（JDT LS 从 1.44 起最低要求 21）
- Lombok 1.18.46 保持不变（实测兼容）

Java Test 需要的 jar 列表以 VSIX 中 `package.json` 的
`contributes.javaExtensions` 为准，不再在脚本里写死数量。Windows 和 macOS 打包
同一组 jar。

### 数据流

```text
平台工作流（Windows run.store / macOS RunService）
  → lsp.request(operation = "javaEntrypoints")
  → Rust JDT 适配层调用 vscode.java.resolveMainClass
  → Rust 整理成统一结果（相对路径、排序、去重、诊断）
  → runConfig.generate(整理后的入口 + 项目模型)
  → .lithe/run/generated.json
```

启动时同样使用 `javaEntrypoints` 的结果按源码路径挑选目标。平台代码不再各自
解析 Java Debug 插件的原始 JSON。

测试发现使用同一条边界：

```text
平台测试工作流
  → lsp.request(operation = "javaTestItems", uri = 当前 Java 文件)
  → Rust 调用 vscode.java.test.findTestTypesAndMethods
  → Rust 校验并整理成版本化的类/方法树和 UTF-16 范围
  → 平台只投影列表、Maven 选择器和 Debug 请求
```

macOS 会把工作区内每个 Java 源文件交给该操作，不按 `src/test` 或文件名预筛；
Windows 会先同步当前编辑文档再请求该操作。两端都不再解析 Java Test 插件的
原始发现 JSON，也不再调用本地 `java.testMethods`。

### 正确做法

- 需要知道“能不能运行 / 是不是测试”时，调用 `javaEntrypoints` 或 JDT 测试发现，
  不要读源码自己判断。
- Spring Boot 分类、配置 ID、排序、模块归属在拿到 JDT 结果之后由 Core 补充；
  它们只能给已确认的入口加标签，不能新增或删除入口。
- 列表状态分 `idle / loading / ready / stale / failed`。JDT 未就绪时显示上次
  成功的结果并标记为刷新中；刷新失败不能用空列表覆盖旧结果；用户点运行时必须
  重新向当前 JDT 确认。
- 判断“运行列表是否过期”也以 JDT 为准：打开项目且 JDT 就绪后，平台把
  `javaEntrypoints` 的结果传给 `runConfig.inspect`，由 Core 和已生成的 Java 入口
  比对。输入指纹不再对全部 Java 源码做内容哈希（见
  `.agents/notes/implemented/bug-fix/2026-09-22-run-panel-fingerprint-loading.md`）。

### 不要这样做

- 不要在 Core 或平台代码里写“main 方法长什么样”“测试注解叫什么”的规则，
  哪怕只是兜底。兜底会变回第二套标准，下一次 Java 升级又会出同样的 bug。
- 不要在 JDT 不可用时偷偷退回本地扫描；应显示“Java 服务未就绪/不可用”。
- 不要为了 Java 21–24 的 preview 项目写本地识别：JDT 1.61.0 的编译器只允许在
  它支持的最新版本（26）上开启 preview，这是上游限制，编辑器会直接显示 JDT
  的报错。

## 考虑过的备选方案

### 放宽 `is_main_method` 的规则

改动最小，几行就能让 #769 的写法出现。但它只是把规则更新到 Java 25，下一次
语言变化还会重演；而且继承的 main、组合注解这类需要类型信息的情况，语法扫描
永远看不到。负责人明确要求不打补丁、一次根治。

### 先发临时修复，再做迁移

外部评审（Codex）建议 P0 先发一个标明待删的最小修复。负责人否决：宁可让用户
多等，也不引入第二套标准。

### 本地扫描作为 JDT 未就绪时的兜底

能避免冷启动时列表为空。但它会造成“先显示 3 个、JDT 就绪后变 5 个”的跳动，并
重新引入双真源。改用“显示上次成功结果 + 刷新中”解决冷启动问题。

### 一次迁移所有“语义类”功能（跳转定义、引用计数等）

原则上一致，但会让 #769 没有边界。判断标准是：是否影响“JDT 找到的入口能否出现
在列表、能否被选中、能否启动”。入口发现、启动解析、测试发现在范围内；跳转定义
的正则、引用计数、参数提示另开 issue。

## 验证

- Rust 单元与契约测试覆盖入口点和测试项的版本化规范化、错误结果、Windows 路径、
  Maven 多模块同名类，以及旧生成结果在 JDT 未就绪时的保留。
- 真实 JDT 测试使用 JDK 25 项目验证 `static void main()`、实例 main、紧凑源文件，
  排除 `private`/错误返回类型/字符串示例，并实际编译运行 #769 的入口。
- 同一真实测试让 Java Test/JDT 发现自定义组合注解和继承来的测试，再用 Maven
  精确运行这两个非传统命名测试并检查执行标记。
- `scripts/verify-java-semantic-ownership.mjs` 阻止已删除的本地入口/测试扫描标识符
  回到 Rust、macOS 或 Windows 产品源码。
- Windows 和 macOS 打包同一份上游 `contributes.javaExtensions` bundle 列表；
  Windows CI 的独立真实 JDT 任务只在 Java/JDT 相关路径变化时运行。

## 后果

收益是 Java 语言版本升级、组合注解和继承等语义变化只需要跟随 JDT，不会再要求
三个实现各自追上规则。代价是运行列表和测试列表必须等待 Java 服务准备完成，
真实 JDT 集成验证也比纯解析器单元测试更慢。

- `vscode.java.resolveMainClass` 是插件内部命令，不是公开标准。升级插件可能
  悄悄改变返回格式，所以版本必须锁定，并用契约测试和真实 JDT 测试盯住。
- 插件在内部出错时可能返回空列表，产品层无法和“确实没有入口”区分。只能靠
  状态机不让失败覆盖旧结果、真实 JDT 测试和日志关联降低风险。
- 从父类继承的 main 目前 JDT 也识别不到（JVM 能运行）。这是上游缺口，不在本地
  补规则，记录为已知限制。
- JDT 升级影响补全、跳转、Maven 导入等全部 Java 功能，需要单独回归。

## 适用范围

- `rust/lithe-core/src/languages/`
- `rust/lithe-core/src/lsp/languages/`
- `rust/lithe-core/src/execution/configuration.rs`
- `third_party/jdtls/manifest.json`
- `scripts/prepare-jdtls.sh`
- `scripts/prepare-jdtls.ps1`
- `windows/tauri/src/features/run/`
- `windows/tauri/src/platform/lsp-core-adapter.ts`
- `macos/Sources/LitheExecutionModule/Services/`
- `.github/workflows/ci-windows.yml`
- 相关笔记：
  `.agents/notes/implemented/feature/2026-09-20-run-configuration-discovery-quality.md`、
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
