# Agent 笔记：自动识别的运行配置只存在内存里

状态：已实现

## 先说结论

以前 Lithe 识别出项目能运行的入口后，会把结果写进用户工程的
`.lithe/run/generated.json`、`.lithe/toolchains/requirements.json`、`.lithe/project.json`
和 `.lithe/.gitignore`；没写这些文件之前，Run 和 Debug 都不可用，要先点“识别项目”。
现在识别结果（检测层，即 Lithe 自动找到的运行入口和工具链需求）只保存在 Rust Core
的进程内存里，并把上次的结果缓存到应用自己的缓存目录。打开项目时，宿主发现还没识别就直接识别，
工程里只剩用户自己保存的配置。已有用户 Run 文档的一次性格式转换独立处理，
不会恢复任何检测文件的工作区写入。

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

`inspect` 在本进程还没识别过这个工作区时返回 `requiresGeneration: true`。
保存过构建任务的工作区即使没有检测层也可以返回 `ready`，因此两端不能只检查 `missing`：
否则重启后只剩用户任务，Spring Boot 等自动入口不会恢复。宿主收到该标记或 `missing` 就直接识别，
不再停在“请生成”的空状态：

- Windows：`run.store.ts` 的 `loadProject` 调用 `generate(root, undefined, { automatic: true })`。
  运行面板、设置、Agent 查询或 Java 启动需要运行信息时才会触发加载，打开工程本身不会。
- macOS：`AppModel.loadProjectServices` 在工作区快照就绪后调用
  `generateFromJavaEntrypoints(..., automatic: true)`。

自动识别只报告问题（没有入口、识别失败），不弹“识别到 N 个入口”的提示；用户手动点“重新识别”
时仍然显示数量。JDT 就绪后的刷新沿用发起那次识别的 `automatic` 标记。

### 默认配置由 Core 选

`.lithe/project.json` 仍是用户可以编辑的团队文档，里面的 `defaultRunConfiguration` 依旧优先。
没有写默认值时，`resolve` 优先选择声明为 service 的检测入口，否则选择第一个不是
Current File 的检测入口；不维护框架提供者名单。以前两端各写了一份同样的规则，并在第一次生成时把结果写进
`project.json`。

### 插件运行目标与 Java 入口分别提供

macOS 只把当前启用插件的公开运行声明与最新模型中的匹配目标交给生成器。
例如插件声明 `serve` 适用于 `endpoint` 标签，宿主选中模型里的对应目标，Core
只保存完整选择器和上游名称；Core 不把某个目标 ID 翻译成框架、工具或调试器。
没有 Java 导入的插件也能生成运行配置，Java 源码归属继续由独立输入负责。

选择器决定稳定 ID，名称和执行类型变化只更新内容，不丢失参数、环境与目录覆盖。
模型指纹覆盖完整快照，顺序变化不算过期；目标撤回时移除自动配置，并保留用户层
以提示孤立覆盖。不要从旧缓存重新补回插件已经撤回的目标，也不要为了生成服务
在 Core 中维护框架名单。macOS 在模型通知和生成后重新比较快照；实际准备仍验证
当前插件、声明和模型，显示的新鲜度提示不能替代启动许可。

用户的运行时参数、入口和按次 Build 选项保存在独立的 `extensions.build-run`。
参数不先拼成字符串，空参数、空格与 Unicode 都保留。Core 只检查通用大小和字段，
准备时由当前声明校验选项，不能在 Core 里解释 Profile 或框架名称。省略该段保留
旧调用者的选择；显式空值表示清空，不把 `false` 和空数组当作“没有覆盖”。
原生存储与偏好复制保持该快照，重存同一选择器保留目录覆盖；Reset 发送空快照。
准备使用 Core 按当前声明规范化后的值，多选项排序不算无效；被丢弃或未知的选择
仍然拒绝。不要以原始数组顺序与规范顺序不同为由拒绝整个运行。
这些数据复用现有 Run 文档和 v10 请求，没有新增下载或缓存。两端编辑器以可逆文本回显 argv，
Core 保留显式空引号参数；共用 argument-text fixture 约束空格、引号、反斜杠与 Unicode。
Windows 的选项快照在映射、编辑和保存时独立复制，旧调用者省略时继续保留。

这段复用既有检测层和缓存，没有新增资源目录，不写入应用包。Windows 仍待接入
Provider 宿主；旧 Maven 配置格式及工具链迁移不因新增通用发现就视为完成。

### 保存的选择器保留已有配置 ID

配置 ID 是用户文档中的稳定身份，选择器是插件当前目标的身份；两者不能混为一谈。
完整的保存记录可以沿用旧 ID，Core 不再要求它必须以 `user:` 开头。没有完整记录的
孤立覆盖仍然提示孤立，所有实际启动仍重新验证启用插件、声明与目标，ID 不授予权限。
团队层和本机层先合并成有效选择器，再隐藏检测层中相同目标的重复项；用户明确保存的
多个配置仍然保留。这样迁移可以保留默认项、选择、层级覆盖和操作身份，而无需改写 ID。

例如，旧服务 `quarkus.maven:nested/app` 转成完整通用选择器后，仍使用原 ID，
自动生成的同目标条目不再重复出现。不要只换一个新 ID 再删除旧记录，那会把用户
默认项和本机覆盖变成孤立记录。Core 也不按这个历史前缀识别框架，它只比较选择器。

`resolve` 可接收内存中的团队/本机文档，宿主在发布两个文件前先验证完整合并结果。
这是通用的事务预检，不写文件、不授予操作权限；实际发布仍检查快照和当前工作区。
正常 Provider 启动只接受完整选择器，两端删除按旧 Maven 名称进入该路径的分支，Core 不再从
旧 Maven 扩展组装 Provider 启动输入。尚未替换的 Java/Windows 旧引擎不是这条新路径的后备实现。

### 旧 Maven Run 和偏好的有界转换

临时的 `MacLegacyMavenRunConfigurationMigration` 只从生成入口调用，不参与正常运行
准备。它将已有 Run v1/v2 中可确认的框架服务和模块目标转为通用选择器，保存原 ID、
参数数组、入口、环境、目录与按次选项；Java 源码入口继续留给阶段 E。
必须在当前模型里找到唯一的同工程/同目标，并核对旧提供者与当前目标名称一致。
重名、框架变化、未知字段或尚未接通通用工具定义的工具路径仍保留源数据并失败，不能靠猜测继续转换。
v1 文档在发布时整体转换字段形状，无关 Java 条目保留原身份；Java 的运行语义不在这里重建。
空目标列表保留为空，由 Maven 自己执行 defaultGoal 或报告无目标；不生成一个宿主默认目标。
旧模块里不受支持的运行时/入口选择也原样保存，由当前提供者明确拒绝，不静默丢弃。

宿主先构造两层文档，用 Core 预检，然后比较所有输入（包括未改写的一层）和偏好状态，
才使用带源版本检查的原子替换。写入、回读、取消或冲突失败时，只回滚自身仍未被改动
的输出；一个文件无法回滚，也继续尝试其他文件，不覆盖用户或另一进程的新数据。
生成任务的租约（可撤销的写入资格）在取消、工作区切换、模型变化或后续生成时失效。
这只约束用户文档与原生状态发布，不把检测缓存当作持久配置。

创建本机文档前，读取旧偏好命名空间并一并转移当时可确认的 Java 配置，避免旧导入器因 local.json 已存在而跳过它们。
显式本机字段高于旧偏好；现有偏好字节、键清单和迁移标记都加入发布前后的来源检查。
没有枚举能力的存储不能在缺少 local.json 时声称完成偏好迁移。通用文档发布后拥有当前值，旧偏好字节只作兼容窗口中的回滚记录，不再作正常运行的后备来源。

转换保留已有文件权限；偏好首次产生的本机文件权限为 0600。取消时条件删除自己的新文件，
只用 rmdir 清理本次创建的空目录，外部新文件不会被删除。不创建迁移缓存或收据，不写应用包和已安装
插件。没有旧记录的只读工程仍可识别。该适配器与唯一入口按 D-MIGRATION-REMOVAL
在稳定 N+2 前删除；通用 ID、预检和层合并规则继续服务正常保存配置。

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

对只有稀疏覆盖的文档，这可以少一次“未识别”的判断。但团队层里覆盖检测入口的条目会全部变成“孤立覆盖”，
用户会看到一批误导性的诊断。保留 `missing` 并让宿主自动识别更直接。

## 后果

- 收益：常规检测不再写用户工程；已有用户文档的临时格式转换单独做冲突保护。Run 和 Debug 不再需要先手动识别；两端删除了重复的写文件、
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
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'MacLegacyMavenRunConfigurationMigrationTests|ExecutionModuleTests|MacNativeBuildProviderIntegrationTests'`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`

## 适用范围

- `rust/lithe-core/src/execution/generated_layer.rs`
- `rust/lithe-core/src/execution/configuration.rs`
- `windows/tauri/src/features/run/`
- `macos/Sources/Lithe/Platform/MacOS/RunConfiguration/MacRunConfigurationStore.swift`
- `macos/Sources/LitheExecutionModule/Services/RunService.swift`
- `macos/Sources/Lithe/Platform/MacOS/Persistence/MacLegacyMavenRunConfigurationMigration.swift`
