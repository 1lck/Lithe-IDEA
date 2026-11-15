# Agent 笔记：运行配置的分类、命名与入口识别

状态：已实现

## 先说结论

同一个仓库里，“能跑的东西”不都是这个项目的服务。例如一个 Java 项目里可能有多个 docker-compose 文件，其中的数据库容器和项目自己的服务若混在同一个服务列表里，用户很难找到真正要启动的目标，同名的 `compose up` 也无法区分。

现在由 Rust Core 统一决定三件事：每个配置属于“项目”还是“基础设施”（category）、同名配置怎么加限定词，以及探测器产生的入口是否可信。宿主只按 category 分组展示，不自行判断哪些配置算基础设施。

## 问题

用户打开一个带多个 compose 文件的项目后，运行面板的服务列表里出现大量数据库和中间件容器，真正要启动的项目服务被淹没其中。默认勾选的还是列表第一条，也就可能是某个数据库容器。

此外，扫描器曾用正则在原始文本上匹配 `main` 方法签名，于是测试代码字符串里的示例代码被当成真实入口，生成了根本无法启动的配置。

## 决策

### 1. 配置分“项目”和“基础设施”两类

`RunCategory`（Core 仓库的 `rust/crates/execution/src/types.rs`）取值 `project` 或 `infrastructure`，默认 `project`，序列化时省略默认值，所以已有的生成文件内容不变。docker-compose 探测出来的服务和整栈条目标记为 `infrastructure`。

判断放在探测器里，不要放在宿主：宿主只读 category 分组。

正确做法：新增探测器时，如果找到的是项目依赖的外部服务（数据库、消息队列、模拟器），在探测结果上标记为基础设施。宿主把基础设施放进单独分组，并且不把它算进“运行全部服务”或默认勾选。

不要这样做：不要因为 compose 条目碍事就不再探测它们，纯 docker 项目仍然需要它们；也不要在各平台各写一份“哪些算基础设施”的判断。

### 2. 同名配置由 Core 加限定词

配置 id 里带目录，所以本来就不重复；但界面只显示名字，多个 compose 文件各出一条 `compose up` 时用户无法区分。Core 在生成阶段按组消歧：依次尝试 Maven 模块、工作目录、来源清单，取第一个能把该组内每条都区分开的候选，得到类似 `compose up (script/docker)` 这样的名字。只出现一次的名字不加后缀，id 也不受影响。

### 3. Java 入口由 Java 插件判定

Java 的可运行类和测试由 Java 插件的语义分析（JDT / Java Test）判定，Core 与宿主不维护方法签名或测试注解规则。Java 相关的探测与入口规则已随 Java 逻辑迁到 [lithe-plugin-java](https://github.com/Lithe-IDEA/lithe-plugin-java) 插件仓库（#1495）。

`src/test` 下真实存在的 main 方法**仍然是合法入口**，应使用测试 classpath 启动。不要为了让列表变短而整体排除测试源码；真正的缺陷是字符串或注释里的示例代码被误判，不是测试源码本身。

### 4. 生成器版本提升

Core 的生成器版本（`GENERATOR_REVISION`）提升后，已有工作区会重新生成配置，用户不需要手动删除生成文件。

## 考虑过的备选方案

- **不探测 docker-compose**：纯 docker 项目会失去唯一的运行入口，问题其实出在展示方式，不是探测本身。
- **只探测仓库根或部署目录里的 compose 文件**：规则靠猜目录名，`sql/tools` 这种位置也可能是用户真正要启动的东西。
- **排除 `src/test` 下的全部 main 方法**：共享夹具和既有实现都明确支持测试源码里的 main 用测试 classpath 启动，用户也确实有这种工具类。
- **在宿主侧按 provider 前缀（如 `compose.`）分组**：每个平台会各写一份相同判断，新增探测器时容易漏改。

## 后果

默认勾选的服务因此变成真正的项目服务；基础设施条目进入可折叠的分组。字符串和注释里的示例代码不再产生幻影配置。

新增探测器如果忘记标记基础设施，条目会落回“项目”分组；这是可见的错误，不会让配置消失。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core/...`：`run_config_test.go` 与 `run_discovery_test.go` 覆盖配置分类与探测结果的宿主侧读取。
- Core 仓库的 `cargo test -p lithe-core`，覆盖 compose 探测归类、同名目录限定，以及字符串和注释中的入口不被误识别。
- 共享契约 `run-configuration-v2.schema.json` 位于 Core 仓库，以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。

## 适用范围

- `desktop/internal/core/run_config.go`
- `desktop/internal/core/run_discovery.go`
- Core 仓库的运行配置类型与探测器（rust/crates/execution/src/types.rs、rust/crates/execution/src/detectors/），以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
