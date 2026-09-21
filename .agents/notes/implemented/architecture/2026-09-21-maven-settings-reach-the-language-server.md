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
分层是惰性的：已经显式配置的工程不会触发 `mvn -version` 探测。

这样在任意一处填 `D:\apache-maven-3.9.16`，语言服务和命令行都会用它。

**4. 本地仓库通过生成的设置文档传递。** JDT LS 没有“本地仓库”这个首选项，
该值只能写在 `settings.xml` 里。所以当用户填了本地仓库时，Core 以生效的设置
文件为底稿做一次**保留式 XML 改写**——只替换 `<localRepository>` 节点，
`<mirrors>`、`<servers>`、`<proxies>`、注释和缩进原样带过——写进语言服务已有
的缓存目录，再作为 `userSettings` 传下去。安装级设置仍在 `globalSettings` 上，
Maven 会把两者合并。

绝不凭空合成一份只含 `<localRepository>` 的文档：那会丢掉镜像配置，把下载从
阿里云打回 Maven Central。这是本次事故里代价最大的一条。

## 考虑过的备选方案

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
- Windows：`bun test src/features/maven` 覆盖四层优先级、各层失败时的降级、
  面板留空时把解析结果带进启动上下文、清空路径时丢弃上一次的解析结果。
  边界校验运行 `./scripts/verify-windows-boundaries.sh`。
- 共享契约：`./scripts/verify-shared-contracts.sh`。
- 测试稳定性：`./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`。

## 适用范围

- Rust Core Maven 域：`rust/lithe-core/src/project/maven.rs`
- Rust Core JDT 适配：`rust/lithe-core/src/lsp/languages/jdt.rs`
- Rust Core 语言服务引擎：`rust/lithe-core/src/lsp/interface/engine.rs`
- Windows：`windows/tauri/src/features/maven/services/resolve-maven-toolchain.ts`、
  `windows/tauri/src/features/maven/stores/maven.store.ts`
- macOS：`macos/Sources/LitheExecutionModule/Services/MavenService.swift`
- 相关笔记：
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
