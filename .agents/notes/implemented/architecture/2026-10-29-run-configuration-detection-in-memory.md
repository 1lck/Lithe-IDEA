# Agent 笔记：自动识别的运行配置只存在内存里

状态：已实现

## 先说结论

以前 Lithe 识别出项目能运行的入口后，会把结果写进用户工程的
`.lithe/run/generated.json`、`.lithe/toolchains/requirements.json`、`.lithe/project.json`
和 `.lithe/.gitignore`；没写这些文件之前，Run 和 Debug 都不可用，要先点“识别项目”。
现在识别结果（检测层，即 Lithe 自动找到的运行入口和工具链需求）只保存在 Rust Core
的进程内存里，并把上次的结果缓存到应用自己的缓存目录。打开项目时，宿主发现还没识别就直接识别，
工程里只剩用户自己保存的配置。

## 问题

- 打开项目就要往用户工程写文件：只读检出会失败，版本控制里多出用户没要的文件，
  文件监听还会把这些写入当成“工程变化”。
- 检测结果写成文件后就有了“文件坏了怎么办”“文件过期怎么办”两类状态，两端各自做了
  “重新生成损坏文件”的入口和提示。
- Run 和 Debug 依赖一次显式的“识别项目”，新用户第一次打开工程时看到的是空状态而不是运行列表。

## 决策

### 检测层归 Core 内存所有

`rust/lithe-core/src/execution/generated_layer.rs` 按规范化后的工作区路径保存最近一次
`runConfig.generate` 的结果（运行配置文档和工具链需求）。`inspect`、`resolve`、
创建用户配置时的 id 冲突检查、`toolchain_diagnostics` 都从这里读。宿主不再写任何检测文件：
Windows 删除了 `run_write_generated` 命令，macOS 删除了 `MacRunConfigurationStore.writeGenerated`。

两端的 Core 都和宿主跑在同一个进程里（Windows 由 Tauri 直接链接，macOS 经 C ABI 调用），
所以同一进程内的多个窗口共享同一份检测层。

### 跨会话只缓存 JDT 的上次入口

JDT（Java 语言服务）冷启动要几十秒。宿主在 `runConfig.generate` 里传 `cacheDirectory`
（Windows 用 `appCacheDir()`，macOS 用 `FileStorage.cacheDirectory()`），Core 把结果写到
`<cacheDirectory>/run-configurations/<sha256(工作区路径)>.json`。下次启动 JDT 还没回答时，
生成器从这里取上次的 Java 入口，运行列表不会变空。

- 生命周期：每次生成都覆盖；读不到、内容不对或写失败都只是少一份加速，不影响其他行为。
- 所有权：Core 写、Core 读；宿主只提供目录。目录在应用缓存里，不在 app bundle 或安装目录里，
  不影响代码签名和 Sparkle 增量更新。
- 旧版本写进工程的 `.lithe/run/generated.json` 只在缓存也没有时作为上次 Java 入口的来源读取一次，
  从不改写，也不再当作当前检测层。

### 打开项目时自动识别

`inspect` 在本进程还没识别过这个工作区时返回 `missing`。宿主收到 `missing` 就直接识别，
不再停在“请生成”的空状态：

- Windows：`run.store.ts` 的 `loadProject` 调用 `generate(root, undefined, { automatic: true })`。
  运行面板、设置、Agent 查询或 Java 启动需要运行信息时才会触发加载，打开工程本身不会。
- macOS：`AppModel.loadProjectServices` 在工作区快照就绪后调用
  `generateFromJavaEntrypoints(..., automatic: true)`。

自动识别只报告问题（没有入口、识别失败），不弹“识别到 N 个入口”的提示；用户手动点“重新识别”
时仍然显示数量。JDT 就绪后的刷新沿用发起那次识别的 `automatic` 标记。

### 默认配置由 Core 选

`.lithe/project.json` 仍是用户可以编辑的团队文档，里面的 `defaultRunConfiguration` 依旧优先。
没有写默认值时，`resolve` 按“框架服务（Spring Boot、Quarkus、Micronaut）优先，否则第一个不是
Current File 的检测入口”选出默认项。以前两端各写了一份同样的规则，并在第一次生成时把结果写进
`project.json`。

### 识别前也能选 JDK

`ProjectRuntimeService` 在 JDT 启动前就要按项目最低 Java 版本选 JDK。检测层还不存在时，
`read_requirements` 直接从工程自己的声明（`pom.xml`、`.java-version`、Maven Wrapper）推导需求，
而不是读一份可能过期的 `requirements.json`。

### 正确做法

- 新增检测结果字段：放进 `RunConfigurationDocument` 或 `ToolchainRequirementsDocument`，
  经 `generated_layer::store` 保存，读取方用 `generated_layer::get`。
- Rust 测试需要检测层夹具：用 `tests/support.rs` 的 `seed_generated`、`seed_requirements`；
  需要模拟新进程时用 `generated_layer::forget`。
- Swift 测试需要检测层：写真实的工程文件（例如带 `spring-boot-maven-plugin` 的 `pom.xml`），
  再调用 `MacRunConfigurationStore.generate`。

### 不要这样做

- 不要在宿主里重新把检测结果写回工作区，哪怕“只为了下次启动快一点”：跨会话加速已经由应用缓存承担。
- 不要把缓存当成必须存在的状态。缓存读失败时，正确行为是重新识别，而不是报错或显示空状态。
- 不要在宿主里重新实现默认配置的挑选规则。

## 考虑过的备选方案

### 继续写 `.lithe/run/generated.json`，只把写入挪到后台

改动最小，冷启动时也能直接读到上次结果。但写工程文件本身就是问题：只读检出、版本控制噪音、
文件监听误报都还在，“文件损坏”这类状态也还要维护。

### 把检测层写到应用缓存，inspect/resolve 直接读缓存

跨会话最快。代价是 `inspect`、`resolve` 和 JDK 选择都要知道缓存目录，缓存过期还要再做一套
新鲜度判断；而且缓存一旦成为“当前状态”，读失败就变成了错误路径。现在只让缓存服务生成器的
“上次 Java 入口”，其余读取都以本进程的识别结果为准。

### 没有检测层时 `resolve` 按空检测层处理

可以少一次“未识别”的判断。但团队层里覆盖检测入口的条目会全部变成“孤立覆盖”，
用户会看到一批误导性的诊断。保留 `missing` 并让宿主自动识别更直接。

## 后果

- 收益：打开项目不再写用户工程；Run 和 Debug 不再需要先手动识别；两端删除了重复的写文件、
  默认项挑选和“重新生成损坏文件”入口。
- 代价：每个新进程打开工程都要重新识别一次（只读扫描，不启动进程）。Java 入口在 JDT 回答前
  依赖缓存；缓存也没有时，Java 入口要等 JDT 就绪后才出现。
- 远程工作区的 `requirements.json` 读取（macOS `runtimeRequirements`）不受影响：远程从未由
  本地生成写入，这次也没有改变它。
- 需要重新评估：如果 Core 改为独立进程或多进程共享，检测层需要随 Core 会话迁移；
  如果识别本身变得很慢，再考虑让缓存直接作为启动时的检测层。

## 验证

- `cargo test -p lithe-core --lib run_configuration`
- `cargo test -p lithe-core --lib detectors`
- `cd windows/tauri && bun test src/features/run`
- `./scripts/macos/test/test-macos.sh --filter 'RunConfigurationIntegrationTests|MavenRuntimeTests|RunEntryPointTests'`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`

## 适用范围

- `rust/lithe-core/src/execution/generated_layer.rs`
- `rust/lithe-core/src/execution/configuration.rs`
- `windows/tauri/src/features/run/`
- `macos/Sources/Lithe/Platform/MacOS/RunConfiguration/MacRunConfigurationStore.swift`
- `macos/Sources/LitheExecutionModule/Services/RunService.swift`
