# Agent 笔记：超长启动命令由插件缩短，宿主只按字节写临时文件

状态：已实现

## 先说结论

依赖很多的 Java 项目，命令行会超过 Windows 的 32767 个 UTF-16 字符上限，进程根本创建不出来。以前由 Core 的 `execution.planLaunchCommand` 判断长度、把类路径搬进 JDK 参数文件（argfile，`java @文件` 读取的选项文件），再由桌面端按系统代码页写文件。

Core 不能认识 Java，所以这条路径整个删掉了：Core 删除 `execution.planLaunchCommand`（Lithe-IDEA/Lithe-core-rust#23），桌面端删除 `launch_plan.go`、`runargs.go`、`argfile_encoding_*.go`。现在宿主按原样启动插件给出的命令行。命令行需要缩短时，由插件自己生成参数文件或 classpath JAR，通过 `run/start` 的 `temporaryFiles` 交给宿主写入。

对日常开发的直接影响：宿主和 Core 里不要再出现“这是不是 JDK”“这个选项是不是类路径”之类的判断；任何语言的命令行缩短都在插件里做。

## 问题

旧做法把三件只属于 Java 的事放进了通用层：

1. **识别启动器。** Core 要知道 `java` 能读参数文件、JDK 9 以上才支持、JDK 8 要改用 classpath JAR。宿主要去读 JDK 的 `release` 文件确定版本。
2. **识别选项。** Core 要知道 `-cp`、`--module-path` 是路径列表，遇到主类、`-jar`、`-m` 要停止搬运。
3. **选择编码。** Windows 上 JDK 启动器按系统 ANSI 代码页读取参数文件，宿主为此写了一份只服务 Java 的编码器。

这违反“Core 对语言零依赖、零特判，语言知识全部由插件注入”的规则。Go、Node、.NET 也有各自的长命令行问题，按旧做法每种语言都要在 Core 里加一套。

## 决策

### 正确做法

1. **宿主按原样启动。** `desktop/internal/pluginservice/runs.go` 不再改写参数。插件给什么命令行，就启动什么命令行。
2. **插件决定是否缩短、怎么缩短、用什么编码。** 插件知道自己的工具：Java 插件知道 JDK 版本、哪些选项能搬、启动器读文件时用什么编码。生成的文件放进 `run/start` 的 `temporaryFiles`，参数里写 `${temporaryFile:<name>}` 引用它。
3. **文件内容有两种形式。** `{name, contents}` 是 UTF-8 文本；`{name, base64}` 是插件自己编码好的字节，宿主解码后原样写入，不转码。需要系统代码页的 Windows 参数文件、二进制的 classpath JAR 都用 `base64`。两种字段同时给出或都不给，Core 拒绝。
4. **校验在 Core，写入在宿主。** Core 的 `run.decodeStart` 检查个数（最多 4 个）、名字、大小（每个最多 4 MiB）和 base64 是否合法，并给出每个文件在临时目录里的路径。宿主只负责创建这次运行的临时目录、写入文件、运行结束后删除。

例子：

```text
正确：Java 插件算出命令行超长 → 生成按代码页编码的参数文件 →
     run/start { arguments: ["@${temporaryFile:args}", "Main"],
                 temporaryFiles: [{ name: "args", base64: "..." }] }
     → 宿主写文件、启动 java

不要这样做：宿主看到可执行文件名是 java，就去读 release 文件、自己拼参数文件。
```

### 插件实现时仍然成立的事实

这些来自旧实现的排查结论，Java 插件实现缩短时必须遵守（插件侧工作见 Lithe-IDEA/lithe-plugin-java#7）：

- 只搬路径列表选项。JVM 选项、主类和程序参数留在命令行上；遇到主类、`-jar`、`-m` 或 `--module` 之后的参数属于应用程序，必须原样保留。
- JEP 400 不改变 Windows 启动器读取参数文件的编码。不能因为 JDK 18 以上就写 UTF-8，要按系统 ANSI 代码页编码；代码页放不下的字符要报错，不能替换成问号。双字节字符的尾字节是 `0x5c` 时要再写一个 `0x5c`。
- JDK 8 不认识参数文件，改用只含 `META-INF/MANIFEST.MF` 的 classpath JAR；manifest 里的路径写成绝对 `file:` URL，目录以 `/` 结尾。
- 只有不缩短就必定失败时才缩短，普通长度的命令行保持原样。

## 考虑过的备选方案

- **保留 Core 的规划，只把名字改得中立。** 不采用：规划逻辑本身就要识别 JDK 和 Java 选项，换个名字仍然是 Java 特判。
- **宿主提供一个“按系统代码页编码文本”的通用服务，插件只给 UTF-8 文本。** 不采用：“哪个程序用哪种编码读文件”是工具知识。Java 启动器用 ANSI 代码页，别的工具可能用 UTF-8 或 UTF-16；由宿主猜就又回到按程序名特判。插件直接给字节，宿主不需要知道编码。
- **插件自己选目录写文件。** 不采用：文件只属于一次运行，生命周期应跟着运行走。由宿主在运行结束、启动失败或 Core 拒绝时统一删除，插件后端崩溃或被停用也不会留下文件；插件也不需要知道临时目录在哪里。
- **改用 `CLASSPATH` 环境变量。** 不采用：Windows 对单个环境变量和整个环境块同样有 32767 的限制。

## 后果

- Core 和宿主不再包含任何 Java 启动知识，新增语言不需要改 Core。
- `temporaryFiles` 成为所有插件都能用的通用能力：任何需要写临时文件的启动都可以用，内容可以是任意字节。
- 代价：在 Java 插件接上缩短逻辑之前，Windows 上依赖很多的 Java 项目会因命令行超长无法启动。macOS 的 `ARG_MAX` 远大于 Windows 上限，实际不受影响。
- 代价：每个需要缩短命令行的插件都要自己实现，不能复用 Core 的规划器。Java 插件已经有从 Core 移植的规划代码（`crates/java-domain/src/execution/`），只缺接线和 Windows 编码。
- 运行临时目录 `<system-temp>/lithe-run-<random>/` 在 `scripts/resources/worktree-resources.json` 的 `run-temporary-files` 中登记为不可复用资源，任何阶段都不得跨工作树复制，也不写发行目录。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/pluginservice/ -run TestRunStartWritesTemporaryFilesAsGiven`：进程读到的文件与插件给出的内容逐字节一致，包括非 UTF-8 字节和空文件。
- `./scripts/desktop/desktop-go.sh test ./internal/core/ -run TestDecodeRunStartFollowsTheContractFixture`：回放 Core 的 `run-start.json`，覆盖 `contents` 和 `base64` 同时给出、都不给、base64 不合法的拒绝。
- `node scripts/resources/test-reuse-worktree-resources.mjs`：`run-temporary-files` 不能跨工作树复用。

## 适用范围

- 宿主：`desktop/internal/pluginservice/runs.go`、`desktop/internal/core/run_start.go`
- 资源登记：`scripts/resources/worktree-resources.json`
- 取代的笔记：`.agents/notes/archived/bug-fix/2026-09-20-oversized-java-launch-command.md`
