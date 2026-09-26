# Agent 笔记：Maven 依赖树从插件输出文件读取

状态：已实现

## 先说结论

Maven 工具窗口的依赖树以前是从 Maven 进程的整段控制台输出里解析出来的。
依赖树和普通日志共用 500,000 字符的上限，大型项目（例如 6,000 个依赖节点，
约 700 KB 文本）会报 `Maven dependency output exceeded the supported limit.`，
依赖根本打不开（#890）。

现在依赖树由 `maven-dependency-plugin` 通过 `-DoutputFile` 写进一个平台临时
文件，Rust Core 从文件读取并解析。控制台输出只当日志，不再参与数据解析。
开发者以后要记住：**依赖数据走文件，日志走控制台，两条通道不能再合并**；
临时文件由平台创建和删除，Core 只负责校验和解析。

## 问题

- 依赖数据和日志混在同一个通道里。Maven 下载、警告、插件日志都占用依赖树
  的预算，合法的大型树会因为日志多而失败。
- macOS 与 Windows 各自在平台层累积整段输出、各自计数（Swift 按字符簇、
  TypeScript 按 UTF-16、Core 按 Unicode 标量），同一份输出在三处的“长度”
  不一样。
- 解析器会跳过任何看不懂的行。项目 POM 如果覆盖了插件的输出格式，结果会被
  当成一棵“更短的树”显示成功，而不是报错。
- verbose 模式里的“依赖管理前版本/scope（`version managed from`、
  `scope managed from`）”和“scope 调解（`scope updated from`、
  `scope not updated to`）”被直接丢弃，界面无法说明某个版本为什么是现在这样。

## 决策

### 数据来源

- `maven.dependencyPlan` 必须收到平台提供的绝对路径 `outputFile`。Core 生成
  固定调用：`maven-dependency-plugin:3.8.1:tree -Dverbose=true
  -DoutputType=text -Dtokens=standard -DoutputFile=<path>
  -DoutputEncoding=UTF-8 -DappendOutput=false`。影响格式的属性全部显式
  传入，用户或项目默认值不能改变 Core 要解析的格式。
- 一次调用只运行一个工程：模块查询用 `-pl <module>`，reactor 根用 `-N`。
  否则 reactor 里每个工程都会覆盖同一个文件，根查询会显示 Maven 最后访问的
  那个模块。
- 依赖语义仍归 Maven：冲突调解、依赖管理、scope 调解都由 Maven 的解析库
  （Maven Resolver 的 verbose 冲突模式）决定。Core 只把每个节点的标注翻译
  成显式字段：`resolution`、`selectedVersion`、`premanagedVersion`、
  `premanagedScope`、`originalScope`、`ignoredScope`。字段语义与 IntelliJ
  IDEA 的 `MavenArtifactNode` 对齐。

### Core 的读取规则（`rust/lithe-core/src/project/maven_dependency_tree.rs`）

- 插件版本固定，所以文本格式固定。第一行必须是模块自身的坐标，之后每一行
  都必须是合法节点，且只能带该版本会写出的标注。不认识的行、标注或编码
  返回 `parse_failed`，不返回残缺的树。
- 上限来自树本身：最多 10,000 个节点、64 层，单行 4 KiB，文件总字节数由
  “(节点上限 + 根行) × 单行上限”推出。这些上限和日志量无关。
- Maven 正常退出但文件不存在时返回 `process_failed`，通常说明项目 POM 为
  依赖插件配置了别的输出位置。

### 临时文件归平台所有

- **Windows**：Tauri 宿主提供 `maven_create_dependency_output` /
  `maven_remove_dependency_output`，文件放在应用缓存目录的
  `maven-dependency-trees/` 下，以会话 ID 命名；应用是单实例，启动时清空
  整个目录。前端 `maven.store.ts` 的所有结束路径（读完、取消、超时、失败、
  配置失效、被新请求取代）都经过 `releaseDependencySession`。
- **macOS**：端口 `MavenDependencyOutputStoring`（`LitheCoreContracts`）由
  `MacMavenDependencyOutputStore` 实现。允许多个 Lithe 同时运行，所以每个
  进程使用以 PID 命名的子目录，创建时只删除进程已退出的目录。`MavenService`
  的结束路径统一经过 `releaseDependencyOutputFile`。
- 两端都在 Core 读完之后才删除文件；一次读取开始后，新的请求或取消不会删掉
  正在被读取的文件。

### 正确做法

- 新增依赖相关字段时，从插件写出的标注或上游结构化模型里取值，在 Core 中
  变成显式字段，再由两端界面展示。
- 平台只负责路径、生命周期和清理；解析、上限和错误分类都在 Core。

### 不要这样做

- 不要重新订阅依赖进程的控制台输出来拼接依赖树，也不要为“大项目又超限了”
  调大某个字符上限。那会把日志量重新变成数据上限。
- 不要把树文件写进用户项目目录（例如模块的 `target/`），那会触发文件监听、
  被 `mvn clean` 删除，还可能被提交。
- 不要在 Core 里用 `std::env::temp_dir()` 自行决定临时目录；目录和清理策略
  属于平台。

## 考虑过的备选方案

### 通过 JDT LS / m2e 获取结构化依赖树

最有吸引力的地方是数据完全结构化：Eclipse m2e 的
`MavenModelManager.readDependencyTree` 在 `org.eclipse.m2e.core` 里，JDT LS
自带它，Lithe 也已经把 profiles 和 settings 传给 m2e。没有采用的原因：它使用
m2e 内嵌的 Maven，而不是用户配置的 Maven 或 mvnd，违反“依赖树与项目 Maven
一致”的要求；仓库没有 Java 扩展 bundle 的构建和发布链路，需要新增并长期维护；
而且必须等 JDT LS 启动并完成项目导入才能工作。若以后 Lithe 需要自己的 JDT LS
扩展 bundle，可重新评估，Core 的返回契约无需改变。

### 使用插件的 JSON 输出（`-DoutputType=json`）

看起来能省掉文本解析。没有采用：3.8.1 与 3.9.0 的 `JsonDependencyNodeVisitor`
只输出坐标、scope 和 optional，冲突、重复和依赖管理信息全部丢失，字符串也
没有转义。

### 像 IntelliJ IDEA 一样运行独立的 Maven Server 进程

这是最完整的方案：独立 JVM 中嵌入用户选择的 Maven，直接调用解析库并返回
结构化节点。没有采用：需要处理多个 Maven 版本的类加载与进程协议，成本远高于
本问题需要的范围。

### 只把控制台上限调大（例如 8 MiB）

改动最小，但依赖树仍然和日志共用预算，下一个更大的项目会再次失败，#890 明确
不接受这种修复。

## 后果

- 收益：合法的大型依赖树不再因为日志量失败；两端共用一个字节上限；格式漂移
  会明确报错；界面能显示依赖管理和 scope 调解信息；mvnd 等控制台格式不同的
  执行器也不影响数据。
- 代价：两端各多了一份临时文件的生命周期代码；Maven 在被停止后才写出的文件
  要等下一次启动清理（Windows）或进程目录清理（macOS）。
- 重新评估的触发条件：升级插件版本（格式可能变化，需同步更新解析器和
  fixture）；或决定引入 JDT LS 扩展 bundle / Maven Server。

## 验证

- Rust Core：`cargo test --manifest-path rust/lithe-core/Cargo.toml maven_depend`
  覆盖计划参数（含 `-N` 与 `outputFile` 校验）、共享 fixture
  `shared/fixtures/maven/dependency-tree-v2.json`（LF 与 CRLF）、6,000 与
  10,000 节点的大树、字节/节点/行长/深度上限、格式漂移与缺失文件。完整校验运行
  `./scripts/verify-rust-core.sh`。
- Rust Core 注释规范：`./scripts/verify-rust-core-comments.sh`。
- 共享契约：`./scripts/verify-shared-contracts.sh`。
- Windows 前端：在 `windows/tauri` 运行
  `bun test --preload ./src/test-utils/vite-assets.ts src/features/maven`，覆盖
  每条结束路径都删除临时文件、读完才删除、删除失败只记日志。
- macOS：`./scripts/test-macos.sh`，其中 `ExecutionModuleTests` 覆盖服务生命周期，
  `MavenRuntimeTests` 通过真实 Core 读取 fixture 文件并验证 PID 目录清理。

## 适用范围

- `rust/lithe-core/src/project/maven_dependency_tree.rs`
- `rust/lithe-core/src/project/maven.rs`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/maven/dependency-tree-v2.json`
- `windows/tauri/src-tauri/src/maven.rs`
- `windows/tauri/src/features/maven/`
- `macos/Sources/LitheExecutionModule/Services/MavenService.swift`
- `macos/Sources/Lithe/Platform/MacOS/Persistence/MacMavenDependencyOutputStore.swift`
