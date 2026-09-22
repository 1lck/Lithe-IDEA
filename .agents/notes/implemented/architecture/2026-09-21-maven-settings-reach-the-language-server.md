# Agent 笔记：Maven 设置必须到达语言服务

状态：已实现

## 先说结论

Lithe 以前只把 `settings.xml` 这一个字段转给 JDT LS（Eclipse 的 Java 语言
服务），而且只有用户手动填写时才转。结果是：Maven 命令行用工程配置的安装读
到 F 盘仓库和阿里云镜像，JDT LS 却回落到出厂默认，在 `C:\Users\<user>\.m2`
另外下载一整套依赖。同一个工程被解析到两个本地仓库，磁盘翻倍，下载绕过镜像，
依赖没下全时启动报 `Unresolved compilation problems`。

现在的规则只有一条：**Lithe 会运行哪个 Maven，JDT LS 就必须看到那个 Maven
会读的设置。** 开发者以后新增任何影响依赖解析的 Maven 配置项，都要同时回答
“它怎么到达语言服务”，否则命令行和语言服务会再次分叉。

## 问题

三个独立缺陷叠在一起，表现为同一个现象。

**一、字段在 Core 里被丢掉。** `jdt_configuration()` 构造的
`MavenJdtConfiguration` 只有 `profiles / settings_path / project_paths /
source_paths` 四个字段。上游 `MavenLaunchContextRequest` 里带着的
`local_repository_path` 和 `maven_executable_path` 在这里直接消失，下游
`java_settings()` 因此只能发 `java.configuration.maven.userSettings` 一条。
全仓库搜不到 `globalSettings`。

Maven 自己的设置解析顺序是“用户级 `~/.m2/settings.xml` 叠加安装级
`<maven home>/conf/settings.xml`”。安装级那份从来没转给 JDT LS，而典型的国内
开发机恰恰把仓库位置和镜像写在安装级里、根本没有用户级文件。m2e（JDT LS 内置
的 Maven 集成）于是零配置启动，回落到 `${user.home}/.m2/repository` 和
`repo.maven.apache.org`。

**二、送达时机太晚。** `adapt_initialization_options()` 只注入
`extendedClientCapabilities` 和 `bundles`，不注入 `settings`。Maven 配置只能
走 `initialized` 之后的 `didChangeConfiguration` 和被动的
`workspace/configuration` 应答。JDT LS 在处理 `initialize` 时就配置 m2e 并紧接
着启动项目导入，所以哪怕路径填对了，也要等首次导入按默认值解析完才送达。

**三、设置面板的“自动检测”是空头支票。** Maven 设置面板四个输入框统一用
`自动检测` 作占位符，但代码里没有任何一处检测 `settings.xml` 或本地仓库。
用户正因为看到“自动检测”才放心留空。

此外，「运行配置」和「Maven 设置」各有一个「Maven 主目录」输入框，语义不同但
用户不会这样理解。数据流只有“运行配置读 Maven 面板”的单向兜底
（`resolve-run-project.ts`），反方向没有，所以在运行配置里填的 Maven 主目录
对语言服务零影响。

## 决策

**1. 安装级设置转成 `globalSettings`。** Core 从配置的 Maven 主目录或
`<home>/bin/mvn*` 启动器推出 `conf/settings.xml`，作为
`java.configuration.maven.globalSettings` 交给 JDT LS。

推导失败时返回空，这是刻意的：项目 Wrapper（`mvnw`）不在任何安装目录里，
没有安装级设置；此时 JDT LS 停留在自身默认，而这正是直接敲 `mvnw` 会得到的
结果。两边仍然一致。

**2. 设置随 `initialize` 一起送达。** `adapt_initialization_options()` 把
`settings.java` 注入 `initializationOptions`，赶在 m2e 配置和首次导入之前。
注入采用覆盖式合并：扩展目录自带的键保留，Lithe 拥有的键权威。

**3. Maven 选择统一成一条优先级链。**

```text
Maven 设置面板的显式配置
  → 运行配置的机器工具链
  → 项目 Wrapper / 宿主发现到的安装
```

两个平台都把**解析后**的安装写进 Maven 启动上下文，而不是把空值传下去。

这样在任意一处填 `D:\apache-maven-3.9.16`，语言服务和命令行都会用它。

**这条链上不允许启动进程。** 它跑在 Maven 工程加载里，而 Java 编辑器打开文件
时会先 `await` 这个加载再启动语言服务（`resolve-editor-lsp-launch.ts`）。
现成的 `run_discover_toolchains` 会对每个候选跑 `mvn -version` / `java -version`，
首次运行 Wrapper 甚至会去下载一份 Maven 发行版 —— 把它放在这里等于让每次
首开 Java 文件都赌一次网络。所以 Windows 侧新增了 `maven_resolve_installation`：
候选顺序与 `resolve_maven_executable` 一致（覆盖 → 可用的 Wrapper → 机器安装），
但只做 `is_file()` 判断，不起进程。

开发者以后往这条链上加层时，先问“它会不会起进程或等网络”。会的话，放到后台
解析并在结果回来后刷新，不要放进加载路径。

**4. 本地仓库通过生成的设置文档传递。** JDT LS 没有“本地仓库”这个首选项，
该值只能写在 `settings.xml` 里。所以当用户填了本地仓库时，Core 以生效的设置
文件为底稿做一次**保留式 XML 改写**——只替换 `<localRepository>` 节点，
`<mirrors>`、`<servers>`、`<proxies>`、注释和缩进原样带过——写进语言服务已有
的缓存目录，再作为 `userSettings` 传下去。安装级设置仍在 `globalSettings` 上，
Maven 会把两者合并。

绝不凭空合成一份只含 `<localRepository>` 的文档：那会丢掉镜像配置，把下载从
阿里云打回 Maven Central。这是本次事故里代价最大的一条。

底稿读不到时（路径过期、文件被删、盘没挂载）**降级而不是失败**：跳过改写，
把原路径原样交给 JDT LS，并往会话日志写一条 warn 说明仓库覆盖未生效。
理由是失败半径不对称 —— 丢掉的是一个可选设置项，而让 `start_server` 失败会
让整个工作区没有补全、跳转和诊断。不要为了“配置错误就该响亮失败”把语言服务
一起拖下水。

## 考虑过的备选方案

- **配置读不到时让会话启动失败。** 被否。第一版这样做过，复审时发现失败半径
  （整个 Java 语言服务）和成因（一个可选设置项）严重不匹配，而且只有配了本地
  仓库的用户才会踩到，行为不一致。改为降级加 warn 日志。
- **给 JDT LS 传 `-Dmaven.repo.local` JVM 参数。** 被否。m2e 的仓库位置来自
  settings 解析结果，这个系统属性是否被尊重取决于 m2e 版本，我们无法在没有
  Windows 环境的情况下证明它成立。不上无法验证的机制。
- **合成只含 `<localRepository>` 的最小 settings.xml 当 userSettings。** 被否。
  用户配置了 settings.xml 时，这份合成文档会取代它，镜像随之丢失。只有在用户
  没有任何 settings.xml 时才退化成这种最小文档，此时本来就没有镜像可丢。
- **把用户的 settings.xml 放进 `globalSettings` 槽位、合成文档放 userSettings。**
  被否。这样能免去 XML 改写，但会挤掉安装级设置；三份文件两个槽位，语义失真。
- **把两个「Maven 主目录」输入框合并成一个。** 被否。运行工具链和项目导入的
  作用域确实不同，合并会让“只想给某个运行配置换 JDK”的场景没法表达。改为共用
  一条解析链，保留两个入口。
- **Core 直接读 `.lithe/run/local.json` 拿运行工具链。** 被否。运行配置的本地
  层由宿主读取后传入 Core（`local_layer_document`），Core 自己读盘会破坏既有的
  持久化归属。解析链因此留在平台侧。

## 后果

### 项目环境设置入口（2026-09-22）

两个平台都从「设置 → 项目 · JDK 与 Maven」管理项目默认环境。Windows 的 Maven
工具窗口齿轮也跳到这里。各服务的启动参数、环境变量、工作目录与工具链覆盖
统一在「设置 → 运行配置」编辑，复用原有保存链路，不改变本机／项目作用域。
运行窗口移除逐服务齿轮和编辑弹窗，保留选择、启动、停止及只读详情；编辑器
行号旁的编辑命令直接打开设置并选中对应配置。Node 配置也使用同一设置入口。

不要在设置中复制一套运行参数解析或另存一份配置。正确做法是设置页复用运行
功能模型及原有编辑表单；错误做法是在运行面板和设置各保留一个独立草稿入口。
代价是编辑前需要进入设置，但所有配置的位置一致，运行界面也不再堆积齿轮。

项目设置保存必须调用 `runConfig.updateOptions` 的本机工具链分支，不得选择一个
服务、把它当前解析后的参数重新保存一遍。正确做法是只更新本机 `toolchain`，
保留原有 `configurations`；错误做法是把继承结果写成服务覆盖，导致项目默认值
下次变化时服务不再跟随。macOS 的运行配置端口为此增加独立保存操作。

Windows 设置使用 `runConfig.inspect` 的 `checkFingerprint: false` 读取默认值，
不要求先生成运行配置，也不为打开设置遍历全部源文件。自动检测的安装仅供候选
展示，不能把检测结果当作用户已经保存的选择。Maven JDK 留空时，Windows 的
Maven 启动适配器读取项目默认 JDK；该解析不把继承结果写回配置。

Maven 目标执行不依赖运行配置文档有效：Windows 读取项目 JDK 默认值失败时，
记录不含原始错误或机器路径的警告，回退到宿主 JDK 选择，不能让损坏的
generated.json 阻止独立 Maven 任务。macOS 首次保存项目默认值必须先补齐
本机运行配置的 Git 忽略规则，保留用户已有内容；设置中的重新识别也必须遵守
不支持版本的升级保护，并在运行服务入口再次拦截，不能只依赖按钮禁用。

现有 Maven 的本机配置仍由 Maven 存储管理，设置页同步其显式选择，保留 profiles、
settings.xml 和仓库路径。Windows 的 Run 本机文档与 Maven 本机文档是两次独立
写入；若后一步失败，界面明确提示默认值已保存，不伪装成整次回滚。原生 UI 和
进程行为仍需分别在 macOS、Windows 验证。

收益：

- 命令行与语言服务解析同一个本地仓库，不再重复下载整套依赖。
- 镜像配置对语言服务生效，国内网络下的首次导入不再绕道 Maven Central。
- 「自动检测」名副其实：留空时按优先级链解析，而不是静默回落到出厂默认。

代价和例外：

- Wrapper 工程仍然得不到安装级设置。这是正确行为，但用户如果期望
  「配了 Maven 主目录就该全局生效」，需要显式填写而不是依赖 Wrapper。
- 本地仓库走生成文档这条路，意味着缓存目录里多出一份 `maven/settings.xml`。
  它是派生产物，用户配置文件本身不被修改。
- 生成文档的路径是固定的，所以仓库路径变化不体现在 JDT Profile 指纹上。
  当前没有问题，因为改动 Maven 设置会触发 Java 会话重载并重新生成；如果将来
  去掉这个重载，指纹需要一并纳入仓库路径。
- Maven 上下文仍然不进日志。这次定位只能靠翻启动命令行里的 `-cp`，下次遇到
  类似问题依然会很慢。补日志是独立的后续工作。

## 验证

- Rust Core：`cargo test --manifest-path rust/lithe-core/Cargo.toml`
  覆盖主目录与启动器两种写法都能推出 `conf/settings.xml`、Wrapper 与无 `conf`
  的安装正确返回空、`initializationOptions` 注入且不吃掉扩展目录的键、
  Profile 指纹随安装变化，以及生成文档保留镜像/注释、插入缺失节点、展开空元素、
  转义路径中的 `&`、不误伤 profile 内的同名元素。完整校验运行
  `./scripts/verify-rust-core.sh`。
- Rust Core 注释规范：`./scripts/verify-rust-core-comments.sh`。
- Windows 前端：`bun test src/features/maven` 覆盖优先级链、各层失败时的降级、
  面板留空时把解析结果带进启动上下文、清空路径时丢弃上一次的解析结果。
  边界校验运行 `./scripts/verify-windows-boundaries.sh`。
- Windows 宿主：`cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml
  maven_resolution_without_probing` 覆盖 Wrapper 优先、主目录与启动器两种覆盖
  写法、残缺 Wrapper 不被选中。
- 共享契约：`./scripts/verify-shared-contracts.sh`。
- 测试稳定性：`./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`。

## 适用范围

- Rust Core Maven 域：`rust/lithe-core/src/project/maven.rs`
- Rust Core JDT 适配：`rust/lithe-core/src/lsp/languages/jdt.rs`
- Rust Core 语言服务引擎：`rust/lithe-core/src/lsp/interface/engine.rs`
- Windows 前端：`windows/tauri/src/features/maven/services/resolve-maven-toolchain.ts`、
  `windows/tauri/src/features/maven/stores/maven.store.ts`
- Windows 宿主：`windows/tauri/src-tauri/src/run.rs`（`maven_resolve_installation`）
- macOS：`macos/Sources/LitheExecutionModule/Services/MavenService.swift`
- 相关笔记：
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
