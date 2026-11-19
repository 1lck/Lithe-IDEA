# Agent 笔记：运行配置的生成层只来自插件声明，只存在内存里

状态：已实现

> 2026-11-19 更新：打开项目时就识别构建系统并加载每个实例的模型，标题栏不再停在“当前文件”、等用户先点运行或打开下拉。见下文“模型加载后自动生成”。
>
> 2026-11-18 更新：用户层改存 `.lithe/run/configurations.yaml`、`local.yaml` 和按插件拆分的 `.lithe/run/plugin/<插件 ID>.toml`、`<插件 ID>.local.toml`；Core 不再写这些文件，编辑命令返回文件改动，由宿主按哈希检查后应用。内置的脚本与程序运行不经过生成层。决策见[脚本与程序运行由 Core 内置，运行配置存 YAML 和 TOML](2026-11-18-builtin-process-runs-and-run-file-formats.md)。
>
> 2026-11-16 更新：Core 删除了内置的运行发现探测器、项目内容指纹和工具链需求（[Lithe-core-rust #77](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/77)，#1856 第 4 项）。生成层现在只由构建插件声明的 `buildSystems[].run` 组成。原来的“跨会话缓存语言服务入口”和“识别前也能选 JDK”两节随之删除；分类与重名规则从已归档的 `.agents/notes/archived/feature/2026-09-20-run-configuration-discovery-quality.md` 并入本文，指纹相关的旧做法见已归档的 `.agents/notes/archived/bug-fix/2026-09-22-run-panel-fingerprint-loading.md`。

## 先说结论

Run 列表里自动出现的条目（生成层）只来自已启用构建插件声明的运行入口（`buildSystems[].run`）。宿主在构建模型加载后，把匹配的目标作为 `providerRuns` 交给 Core 的 `runConfig.generate`；Core 把结果保存在进程内存里，不写工作区，也不写缓存。Core 自己不识别任何生态的入口，也不扫描工作区计算指纹；模型何时过期由插件的 `sync.watch` 决定。工程里只有用户自己保存的配置。

## 问题

- 打开项目就往用户工程写文件：只读检出会失败，版本控制里多出用户没要的文件，文件监听还会把这些写入当成“工程变化”。写成文件后又多出“文件坏了”“文件过期”两类状态和对应的修复入口。
- Core 曾内置 Cargo、Go、npm/pnpm/yarn/bun、Python、Make、just、Procfile、Compose 探测器，生态知识写死在 Core：新增或修正一个生态都要改 Core 并发版；插件已经声明的运行入口和探测结果还会各出一条。
- 为了判断探测结果是否过期，Core 要遍历整个工作区计算内容指纹。大项目或文件访问被杀毒软件拖慢时会超时，还要为“扫描不完整”维护专门的诊断和界面提示。
- Run 和 Debug 曾依赖一次显式的“识别项目”，新用户第一次打开工程时看到的是空状态而不是运行列表。

## 决策

### 生成层只来自插件声明的运行入口

`runConfig.generate` 只把 `providerRuns` 生成为 `build.provider` 条目；省略 `providerRuns` 等于传 `[]`，生成层为空。宿主只把插件公开的运行声明与当前模型中匹配的目标（例如“`serve` 适用于 `endpoint` 标签”）交给生成器。Core 只保存完整选择器和上游名称，不把某个目标 ID 翻译成框架、工具或调试器。

没有声明 `run` 的生态在 Run 列表里没有自动条目，用户仍可以保存自己的配置。要让一个生态出现自动条目，就在它的插件里声明 `run`，不在 Core 或宿主里加识别规则。

### 生成层归 Core 内存所有

Core 按规范化后的工作区路径保存最近一次 `runConfig.generate` 的结果。`inspect`、`resolve` 和创建用户配置时的 ID 冲突检查都从这里读。宿主不写任何生成文件；旧版本写进工程的 `.lithe/run/generated.json` 不再读取。

桌面端与 Core 在同一进程里（经 C ABI 调用），同一进程内的多个窗口共享同一份生成层。

### 过期只比较快照

`generator.providerRunFingerprint` 覆盖完整排序后的快照，顺序变化不算过期。`inspect` 收到 `providerRuns` 且与生成层的快照不同时，报告 `staleProviderModel`。哪些文件变化会让模型过期，由插件在 `sync.watch` 里声明，Core 不扫描工作区。

选择器决定稳定 ID，名称和执行类型变化只更新内容，不丢失参数、环境与目录覆盖。目标撤回时移除自动配置，并保留用户层以提示孤立覆盖；已撤回的目标不能从更早的生成结果补回。

### 模型加载后自动生成

`inspect` 在本进程还没生成过这个工作区时返回 `requiresGeneration: true`。保存过构建任务的工作区即使没有生成层也可以返回 `ready`，因此宿主不能只检查 `missing`：否则重启后只剩用户任务，自动入口不会恢复。桌面端在构建模型加载后生成（`desktop/internal/workbench/runconfig.go` 的 `refreshRunConfigurations`），不停在“请生成”的空状态。

模型在打开项目时就开始加载：`openProjectHere`（`desktop/internal/workbench/app.go`）调用 `loadTitleRunConfigs`，先识别构建系统，再加载每个识别到的实例的模型，因为标题栏要列出所有实例声明的运行，不只是构建窗口选中的那一个。以前只有按下标题栏的运行、打开运行配置下拉或打开构建窗口时才识别，用户打开 Spring Boot 工程后看到的是“当前文件”和空列表，以为启动类没被识别出来。

自动加载不放宽执行仓库代码的限制：加载模型时构建工具经工具链各层解析，工作区还没被信任时，`mvnw`、`gradlew` 这类工作区里的程序不会被选中，和用户手动触发时是同一道门槛。加载模型也不写用户工程。

### 默认配置由 Core 选

`.lithe/project.json` 仍是用户可以编辑的团队文档，里面的默认运行配置优先。没有写默认值时，`resolve` 依次选择第一个声明为 service 的生成条目、第一个不是 Current File 的生成条目。宿主不实现这套挑选规则。

### 分类与重名由 Core 决定

每个配置的 `category` 是 `project` 或 `infrastructure`，默认 `project` 且序列化时省略。`infrastructure` 表示项目依赖的外部服务（数据库、消息队列）。生成的条目都是 `project`；用户保存的配置可以声明 `infrastructure`。宿主只按 `category` 分组展示，把基础设施放进单独分组，不算进“运行全部服务”或默认选择，也不按 provider 前缀或工具名自己判断。

界面只显示名字，多个模块各声明一个 `serve` 时用户无法区分。Core 在生成时处理重名：同名条目的工作目录互不相同、且都不是工作区根目录时，每个名字加上目录，例如 `serve (services/api)`；否则名字不变。只出现一次的名字不加后缀，ID 也不受影响。

### 用户选项

用户的运行时参数、入口和按次构建选项保存在独立的 `extensions.build-run` 段。参数不先拼成字符串，空参数、空格与 Unicode 都保留。Core 只检查通用大小和字段，准备时由当前声明校验选项，不能在 Core 里解释 Profile 或框架名称。显式空值表示清空，不把 `false` 和空数组当作“没有覆盖”。

### 保存的选择器保留已有配置 ID

配置 ID 是用户文档中的稳定身份，选择器是插件当前目标的身份，两者不能混为一谈。完整的保存记录可以沿用旧 ID，Core 不要求它必须以 `user:` 开头。没有完整记录的孤立覆盖仍然提示孤立；实际启动仍重新验证启用插件、声明与目标，ID 不授予权限。

团队层和本机层先合并成有效选择器，再隐藏生成层中相同目标的重复项；用户明确保存的多个配置仍然保留。这样迁移可以保留默认项、选择、层级覆盖和操作身份，而无需改写 ID。不要只换一个新 ID 再删除旧记录，那会把用户默认项和本机覆盖变成孤立记录。Core 也不按历史前缀识别框架，它只比较选择器。

`resolve` 可接收内存中的团队或本机文档，宿主在发布两个文件前先验证完整合并结果。这是通用的事务预检，不写文件、不授予操作权限；实际发布仍检查快照和当前工作区。

### 发布用户文档的保护

Core 的编辑命令只返回文件改动（路径、改动前的哈希和新内容），宿主在 `applyRunConfigChanges` 里确认每个文件仍是 Core 读到的字节后才一次性应用；任何一个不符就整体放弃并报冲突。写入或回读失败时，只回滚自身仍未被改动的输出，不覆盖用户或另一进程的新数据。生成任务的租约（可撤销的写入资格）在取消、工作区切换、模型变化或后续生成时失效。

生成层不是持久配置，不参与这套发布。

### 正确做法

- 让某个生态出现在 Run 列表：在它的插件里声明 `buildSystems[].run` 和 `sync.watch`，Core 和宿主都不改。
- 新增生成结果字段：放进运行配置文档，经生成层保存，读取方从生成层读取。
- 测试需要生成层夹具：Core 测试用 `generated_layer::seed`；宿主测试用合成的 provider run（`dev.example.*` 插件 ID），不依赖具体插件。

### 不要这样做

- 不要在 Core 或宿主里按文件名（`package.json`、`Cargo.toml`、`compose.yaml` 等）识别入口，也不要按工具名或 provider 前缀分组、选默认项。
- 不要把生成层写回工作区或缓存，哪怕“只为了下次启动快一点”。
- 不要在宿主里重新实现默认配置、分类或重名规则。

## 考虑过的备选方案

### 继续写 `.lithe/run/generated.json`，只把写入挪到后台

改动最小，冷启动时也能直接读到上次结果。但写工程文件本身就是问题：只读检出、版本控制噪音、文件监听误报都还在，“文件损坏”这类状态也还要维护。

### 把上次的生成结果缓存到应用缓存目录

以前为语言服务冷启动缓存过上次的入口（`<cacheDirectory>/run-configurations/`）。现在入口来自构建模型，模型加载后才生成；缓存旧入口会让已撤回的目标在模型加载前短暂复活，还要另做一套新鲜度判断。删除后的代价是模型加载前 Run 列表只有用户配置。

### 保留内置探测器，作为没有插件的生态的兜底

能让 npm、Python、Make 等项目继续自动出现入口。没有采用：生态知识仍写死在 Core，和插件声明的入口重复，还需要全量指纹扫描。用户决定入口一律由插件声明，接受没有插件的生态暂时没有自动条目。

### 把探测器改写成 Core 内置的声明

这是[构建系统 Provider 提案](../../proposed/architecture/2026-10-17-build-system-provider-api.md)原来的迁移计划。没有采用：Core 仍然维护生态知识，只是换了格式；插件已经能声明同样的内容。

### 没有生成层时 `resolve` 按空生成层处理，并照常报孤立覆盖

对只有稀疏覆盖的文档，这可以少一次“未生成”的判断。但团队层里覆盖自动条目的配置会全部变成“孤立覆盖”，用户会看到一批误导性的诊断。

2026-11-18 起采用了折中做法：没有生成层时，`resolve` 返回已保存的配置（一个都没有时返回空列表），让内置的脚本与程序运行不必等构建模型；这时不报孤立覆盖。生成仍由 `inspect` 的 `requiresGeneration` 触发。

## 后果

- 收益：Core 不含任何生态的入口规则，也不再遍历工作区计算指纹；常规生成不写用户工程；默认项、分类和重名只在 Core 实现一次。
- 代价：没有插件声明 `run` 的生态在 Run 列表里没有自动条目。2026-11-16 时，Cargo 插件 0.1.3 还没有声明 `run`，Docker 插件没有 `buildSystems`，npm/pnpm/yarn/bun、Python、Make、just、Procfile 没有插件。provider run 只能生成 `project` 类别，Compose 这类基础设施要等契约支持声明类别。模型加载前 Run 列表只有用户配置，每个新进程都在模型加载后重新生成。
- 需要重新评估：如果 Core 改为独立进程或多进程共享，生成层需要随 Core 会话迁移；如果插件需要声明基础设施，扩展 `run` 声明而不是在 Core 里识别。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/workbench/...`：`run_discovery_test.go` 证明生成不写工作区；`run_config_test.go` 和 `runconfig_edit_test.go` 覆盖生成、解析、默认项和选项往返。
- Core 仓库的 `cargo test -p lithe-execution`：覆盖 provider run 生成、重名限定、过期快照和默认项。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：确认生成不写入发行目录。

## 适用范围

- `desktop/internal/core/run_discovery.go`
- `desktop/internal/core/run_config.go`
- `desktop/internal/workbench/runconfig.go`
- Core 仓库的生成层与生成器：[generated_layer.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/execution/src/generated_layer.rs)、[generation.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/execution/src/configuration/generation.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`
