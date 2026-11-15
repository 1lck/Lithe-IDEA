# Agent 笔记：读取登录 shell 环境

状态：已实现

## 先说结论

从 Finder / Dock 启动的 Lithe 只拿到 launchd 的最小 `PATH`，mise、SDKMAN、asdf、fnm、Homebrew 装的 Maven、JDK、Node 都看不见（#1514、#1455、#1162）。现在 Lithe 启动时读取一次用户登录 shell（打开终端时运行的那个 shell）的环境：`PATH` 合并进进程环境，并通过 `desktop/internal/loginenv` 提供给所有子进程；其他变量只放在内存里，只补进子进程缺失的键上，已有的值永远不被覆盖。

## 问题

- 只给 Node 脚本补 `PATH` 的做法（#1492）不够：mise 装的 Maven、`JAVA_HOME` 指向的 mise JDK 仍然找不到，而且每加一种工具都要再补一次。
- 宿主进程和它启动的 Core（语言服务器、Git、Agent）各自读取环境，结果不一致。

## 决策

- **启动时激活一次。** `desktop/cmd/lithe/main.go` 在 Core 启动线程、读取环境之前调用 `loginenv.Activate()`。
- **只缓存 `PATH`。** 登录 shell 的 `PATH` 写入用户缓存目录，而不是应用目录，不写入安装目录或发行资源。首次启动同步读取，超时有上限；之后启动直接应用缓存，后台再读一次供下次启动使用。
- **`PATH` 合并顺序。** 登录 shell 的条目在前，再接上继承下来、登录 shell 里没有的条目。从终端启动时，那个会话额外加的目录（例如已激活的 venv）不会丢。
- **其他变量只在内存里。** `JAVA_HOME`、`MAVEN_HOME`、代理等变量可能含密钥，不落盘。`loginenv.Environ()` / `Merged()` 只把它们补到子进程缺失的键上。
- **忽略 shell 自己的变量。** `PWD`、`SHLVL`、`TERM*` 这类由 shell 或终端设置的变量不取用。
- **关闭开关。** 设置 `LITHE_SKIP_SHELL_ENV` 可以关闭整个读取；读取 shell 时也会给子 shell 带上它，防止 shell 再启动 Lithe 时循环。
- **shell 不能拖住应用。** shell 在独立进程组里启动，超时或 shell 退出后整组结束，rc 文件留在后台的任务也会被清理。读取失败时保持继承的环境。
- **日志只记摘要。** 每次读取记录 shell 名、来源、耗时和变量个数，失败记 warning；日志里永远不写变量的值。

开发者要注意：新代码需要“用户的环境”时使用 `loginenv` 提供的环境，不要直接读 `os.Environ()` 而期望拿到登录 shell 的变量。

JDK 的自动选择和项目 JDK 传给语言服务器的规则属于 Java 逻辑，已随 #1495 迁到 [lithe-plugin-java](https://github.com/Lithe-IDEA/lithe-plugin-java) 插件仓库，宿主不再有对应实现。

## 考虑过的备选方案

- **继续逐个工具补 `PATH`**：改动小，但每种工具、每个入口都要再补，mise Maven 就是漏掉的例子。放弃。
- **每次启动同步读取登录 shell**：环境总是最新，但每次启动多等约 1 秒，rc 文件慢时更久。改为只在首次启动同步读取、之后用缓存加后台刷新。
- **把整个登录环境写进缓存**：热启动能立刻拿到 `JAVA_HOME`，但环境里常有 token，落盘不安全。只缓存 `PATH`。
- **启动后用 `setenv` 写入全部变量**：其他线程可能同时读环境，`setenv` 不是线程安全的。只在单线程阶段设置 `PATH`，其余走内存覆盖层。

## 后果

- 收益：从 Finder 启动后，运行、Core 启动的语言服务器和 Git 查找工具的范围与终端一致；子进程能看到 shell 里导出的 `JAVA_HOME`、`MAVEN_OPTS`、代理变量。
- 代价：首次启动最多多等超时上限；rc 文件在后台多运行一次；改了 shell 配置要到下次启动才生效。
- 热启动的前一两秒内，内存中的其他变量可能还没填好，此时探测到的 `JAVA_HOME` 来自进程本身。
- 本机代码衍生自 OpenIDEA 的 `shell_env.rs`（Apache-2.0），出处写在 `desktop/internal/loginenv/loginenv.go` 的文档注释里，仓库根目录 `NOTICE` 记录 OpenIDEA 版权声明。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/loginenv/...`：标记解析、超时、缓存、关闭开关、“已有值优先”和日志不含变量值的测试。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：缓存只写入用户缓存目录。

## 适用范围

- `desktop/internal/loginenv/loginenv.go`
- `desktop/internal/loginenv/loginenv_unix.go`
- `desktop/internal/loginenv/loginenv_windows.go`
- `desktop/cmd/lithe/main.go`
- `NOTICE`
