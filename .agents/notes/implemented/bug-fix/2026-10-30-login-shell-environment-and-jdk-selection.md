# Agent 笔记：读取登录 shell 环境，并按项目 Java 版本精确挑选 JDK

状态：已实现

## 先说结论

很多“项目跑不起来”的 Issue 来自两个共同原因。第一，从 Finder / Dock 启动的
Lithe 只拿到 launchd 的最小 `PATH`，mise、SDKMAN、asdf、fnm、Homebrew 装的
Maven、JDK、Node 都看不见（#1514、#1455、#1162）。第二，自动选 JDK 时只要求
“不低于项目版本”，`JAVA_HOME` 来源优先级最高，于是 Java 8 项目会被 `JAVA_HOME`
指向的 JDK 21 抢走（#1118、#826 一类）。

现在 macOS 启动时读取一次用户登录 shell（login shell，打开终端时运行的那个 shell）
的环境；JDK 自动选择改为“版本完全相同优先，其次选比它新的里面最旧的”，来源优先级
只在同一主版本内比较。两端还会扫描 mise、asdf、`~/.jdks`、Scoop 和 SDKMAN 的
Maven 安装目录。做法参考 OpenIDEA（Apache-2.0），出处写在仓库根目录 `NOTICE`。

## 问题

- #1492 只给 Node 脚本补了 `PATH`。mise 装的 Maven、`JAVA_HOME` 指向的 mise JDK
  仍然找不到；以后每加一种工具都要再补一次。
- `lithe-agent-host` 自己也读了一次登录 shell 的 `PATH`，只给 Agent 用，运行、Maven、
  JDT 看不到。
- `select_java_candidates` 先按来源优先级、再按版本从新到旧排序，只用最低版本过滤。
  `JAVA_HOME`（优先级 0）只要不低于要求就被选中，即使机器上装了项目声明的那个版本。
- 版本管理器的 shim（垫片脚本，指向管理器自身的可执行文件）不是 Maven home。
  把它当 home 解析，会得到错误的安装目录。

## 决策

### macOS：启动时读登录 shell 环境

入口是 `macos/Sources/Lithe/Platform/MacOS/Runtime/MacLoginShellEnvironment.swift`，
在 `MacApplicationEntryPoint.main()` 里、任何线程和子进程启动之前调用。

1. 运行 `$SHELL -ilc "printf MARK; /usr/bin/env -0; printf MARK"`，用标记截取输出，
   忽略 rc 文件打印的欢迎语，丢掉 `PWD`、`SHLVL`、`TERM*` 这类 shell 自己的变量。
2. 只把 `PATH` 写进 Caches 目录下的 `login-path`（经 `MacFileStorage.cacheDirectory()`，
   不碰 app bundle）。首次启动同步读取，最多等 3 秒；之后启动直接用缓存，
   后台再读一次刷新，供下次启动使用。
3. 进程 `PATH` = 登录 shell 的条目在前，再接上继承下来、登录 shell 里没有的条目。
   从终端启动时，那个会话额外加的目录（例如已激活的 venv）不会丢。
4. 其他变量（`JAVA_HOME`、`MAVEN_HOME`、代理等）可能含密钥，只放在内存里，
   通过 `MacLoginShellEnvironment.shared.merged(_:)` 补到缺失的键上，
   已有的值永远不被覆盖。`MacRuntimeLocator.environment()`、`MacManagedProcess`
   的默认环境和 JDT 的 JDK 发现都经过这里。
5. 设置 `LITHE_SKIP_SHELL_ENV=1` 可以关闭整个读取；读取 shell 时也会给子 shell 带上它，
   防止 shell 再启动 Lithe 时循环。

开发者要注意：新代码需要“用户的环境”时调用 `runtimeLocator.environment()`，
不要直接读 `ProcessInfo.processInfo.environment`，否则拿不到登录 shell 的变量。

### Core：JDK 自动选择按主版本距离排序

`rust/lithe-core/src/execution/java_selection.rs` 的 `select_java_candidates`：

- 仍然先用最低版本过滤，不兼容的不选。
- 兼容的候选按“主版本减去项目版本”的差值排序，差值最小（相同版本）优先；
  差值相同时才比较来源优先级，最后按补丁版本和 ID 稳定排序。
- 没有项目版本时行为不变，仍然用平台给的 fallback。

例子：项目声明 Java 8，`JAVA_HOME` 是 21，另装了 Zulu 8，选 Zulu 8；
项目声明 11，只有 21（`JAVA_HOME`）和 17，选 17。不要这样做：在平台侧再写一套
排序去“修正” Core 的结果，两端会再次分叉。

### 两端：扫描版本管理器的安装目录

- macOS `MacRuntimeDiscovery`：JDK 增加 `~/.jdks`、mise
  （`MISE_DATA_DIR` 或 `XDG_DATA_HOME/mise`，默认 `~/.local/share/mise`，含 macOS 的
  `Contents/Home` 布局）和 asdf（`ASDF_DATA_DIR` 或 `~/.asdf`）；Maven 增加 SDKMAN、
  mise、asdf 的 `installs/maven/*/bin/mvn`，并跳过 `PATH` 里名为 `shims` 的目录。
- Windows `run.rs`：JDK 增加 mise（`MISE_DATA_DIR` 或 `%LOCALAPPDATA%\mise`）、asdf、
  Scoop（`apps/*/current`）、`Semeru`、`OpenJDK` 目录；Maven 增加 mise、asdf、SDKMAN、
  Scoop，排在显式配置、wrapper 和 `PATH` 之后，不会抢走它们。

## 考虑过的备选方案

- **继续逐个工具补 `PATH`（#1492 的做法）**：改动小，但每种工具、每个入口都要再补，
  mise Maven 就是漏掉的例子。放弃。
- **每次启动同步读取登录 shell**：环境总是最新，但每次启动多等约 1 秒，rc 文件慢时更久。
  改为只在首次启动同步读取、之后用缓存加后台刷新。
- **把整个登录环境写进缓存**：热启动能立刻拿到 `JAVA_HOME`，但环境里常有 token，
  落盘不安全。只缓存 `PATH`。
- **启动后用 `setenv` 写入全部变量**：其他线程可能同时读环境，`setenv` 不是线程安全的。
  只在单线程阶段设置 `PATH`，其余走内存覆盖层。
- **由 JDT 报告的 `vm.location` 决定运行 JDK**：OpenIDEA 用它作为第二优先级。
  需要两端各加一次 LSP 往返和新的契约字段，这次没有做；先用 Core 的精确匹配解决
  选错 JDK 的主要场景。

## 后果

- 收益：从 Finder 启动后，Maven、JDK、Node、Gradle 的查找与终端一致；子进程能看到
  shell 里导出的 `JAVA_HOME`、`MAVEN_OPTS`、代理变量；JDK 8/11/17 项目在装了对应版本时
  不再被更新的 `JAVA_HOME` 抢走。
- 代价：首次启动最多多等 3 秒；rc 文件在后台多运行一次；改了 shell 配置要到下次启动
  才生效。项目声明 17、机器同时有 17 和 21 时，现在会选 17 而不是 21，这是有意的行为变化。
- 只缓存 `PATH`，热启动的前一两秒内，内存覆盖层可能还没填好，此时探测到的
  `JAVA_HOME` 来自进程本身。
- 衍生代码按 Apache-2.0 保留出处：Swift 文件头和 Rust 文档注释注明来源，仓库根目录
  `NOTICE` 记录 OpenIDEA 版权声明。

## 验证

- `./scripts/rust-core/verify-rust-core.sh`：`automatic_java_selection_uses_shared_fixture_and_current_requirements`
  读取 `shared/fixtures/run-configuration/automatic-java-selection.json`，覆盖精确版本优先、
  最旧的更新版本、同版本内按来源优先级。
- `./scripts/macos/test/test-macos.sh`：`MacLoginShellEnvironmentTests` 用假 shell 覆盖
  标记解析、超时、冷/热启动缓存、关闭开关和“已有值优先”；`MacRuntimeDiscoveryTests`
  覆盖 mise/asdf/`~/.jdks` 的 JDK 和跳过 shim 的 Maven 发现。
- `./scripts/architecture/verify-shared-contracts.sh`。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/Runtime/MacLoginShellEnvironment.swift`
- `macos/Sources/Lithe/Platform/MacOS/Runtime/MacRuntimeDiscovery.swift`
- `macos/Sources/Lithe/Platform/MacOS/MacApplicationEntryPoint.swift`
- `rust/lithe-core/src/execution/java_selection.rs`
- `windows/tauri/src-tauri/src/run.rs`
- `NOTICE`
