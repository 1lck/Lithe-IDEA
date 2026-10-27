# Agent 笔记：从 Finder 启动的 Lithe 运行 Node 脚本时补齐启动 PATH

状态：已实现

## 先说结论

从 Finder / Dock 启动的 Lithe 继承 launchd 的最小环境，`PATH` 只有
`/usr/bin:/bin:/usr/sbin:/sbin`。Lithe 自己能通过 Homebrew、fnm、nvm 找到
`pnpm`，但 `pnpm` 这类启动器用 `#!/usr/bin/env node` 找解释器，子进程按自己的
`PATH` 找不到 `node`，于是 `pnpm run <script>` 直接报
`env: node: No such file or directory`（#1455）。

现在运行入口会在启动前把两类目录补到子进程 `PATH` 后面：Lithe 发现到的 `node`
解释器目录，以及解析出的可执行文件目录；项目内的 `node` 和项目根目录永远不加。
终端、调试适配器和语言服务器不走这条路径，行为不变。

## 问题

用户从 Finder 启动 0.6.2 发行包，打开 pnpm 管理的项目，点 package.json 里的
`clean` 脚本。输出窗口先显示 `$ pnpm run clean`，紧接着就是
`env: node: No such file or directory`，进程没有真正运行。终端里执行同样的命令
正常，因为交互 shell 的启动脚本把 fnm / Homebrew 目录加进了 `PATH`。

代码侧的链路是：

- `MacRuntimeLocator.environment()` 直接返回 `ProcessInfo.processInfo.environment`，
  也就是 Lithe 自己被启动时拿到的环境。
- `ProjectRuntimeService.processEnvironment(overrides:)` 只在这份环境上叠加调用方
  传来的值，不补任何“我已经找到的工具”目录。
- `RunExecutableResolver` 把这份环境原样交给 `RunService`，`RunService` 再交给
  `Process.start`。

所以“Lithe 能找到 pnpm”靠的是 `MacRuntimeToolDiscovery` 对 PATH、Homebrew 和
Node 版本管理器目录的额外探测；这份探测结果从来没有进入子进程环境。

术语：

- launchd：macOS 的进程启动器。Finder 启动的 app 只继承它给出的最小环境，不会
  读取用户 shell 的启动脚本。
- shebang `#!/usr/bin/env node`：脚本第一行让内核用 `env` 去当前进程的 `PATH`
  里查找 `node`。用绝对路径启动脚本并不能替它准备好 `PATH`。

## 决策

- 组合点放在 `RunExecutableResolver.resolve`：`.toolchain` 和 `.command` 两条
  分支都会经过它。只补运行启动环境，不改 `ProjectRuntimeService.processEnvironment`
  本身，避免终端、调试适配器、语言服务器被顺带改掉。
- 目录顺序：原有 `PATH` 条目保持原位置和优先级，`node` 目录与被解析出的可执行
  文件目录补在后面，按原始拼写去重，避免错误合并大小写敏感卷上的不同目录。运行配置允许
  用户显式设置 `PATH` 来固定自己的工具链，追加而不是前置才能尊重这份配置；从
  Finder 启动时 `PATH` 里本来没有 `node`，追加同样能被 `env` 找到。
- 环境没有 `PATH` 时，`MacRuntimeLocator` 通过系统 `confstr(_CS_PATH)` 读取默认
  可执行搜索路径，经运行时服务传入纯环境组合器；Service 不硬编码系统目录。
  显式空 `PATH` 仍是用户覆盖，不被默认值替换；终端和语言服务器的基础环境不变。
- 安全边界：`RuntimeToolCandidate.source == .project` 的 `node` 不注入；可执行
  文件位于项目根内时（例如 `mvnw`、`gradlew`），它所在的目录也不注入。仓库内容
  不可信，把项目根放到 `PATH` 前部会让仓库里的同名文件劫持脚本后续调用的系统
  命令。这与语言服务器侧 `languageToolProcessEnvironment` 的既有规则一致。
- Windows 的运行入口 `prepend_runtime_paths` 早就在把“运行时目录 + 可执行文件
  目录”加进 `PATH`（Windows 是前置）。macOS 这次补上同类能力，但使用追加顺序，
  因为当前实现里没有和 Windows 运行时映射等价的可信来源，追加更不容易覆盖用户
  的显式配置。

正确做法：

```text
pnpm 在 /opt/homebrew/bin，node 在 fnm 的默认别名目录
子进程 PATH = <原有 PATH>:<fnm 的 node 目录>:<pnpm 目录>
```

不要这样做：

```text
子进程 PATH = <项目根>:<项目 .lithe/bin>:<原有 PATH>
```

后者会让仓库自带的 `node`、`git` 或任何同名文件覆盖系统工具。

## 考虑过的备选方案

- 只把“解析出的可执行文件所在目录”加入 `PATH`（issue 报告里的建议）：不够。
  Homebrew 安装的 `pnpm` 和 fnm 管理的 `node` 经常不在一处，`env node` 仍然
  找不到解释器。
- 在 `ProjectRuntimeService.processEnvironment` 里统一补：少一处分叉，但同一份
  环境也被调试适配器和语言工具使用，副作用范围比“运行”大得多，而且这些路径
  各自已经有 `LITHE_NODE_PATH` 之类的专门规则。
- 像终端一样先启动一次登录 shell 取得用户 `PATH`：依赖用户 rc 文件、每次多起
  一个进程、结果不确定，还会把 shell 初始化副作用带进运行。
- 把项目自带的 `node` 也注入（沿用发现顺序里的“项目工具优先”）：会让不可信
  仓库控制用户点击运行的每个脚本的解释器，收益小于风险。

## 后果

- 收益：从 Finder 启动也能运行 `pnpm` / `npm` / `yarn` / `tsx` 等脚本；脚本内部
  再调用 `node` / `npm` 也能解析到同一套工具；与 Windows 的启动环境方向一致。
- 代价：每次运行解析多一次 `node` 候选发现（PATH 和各版本管理器目录的只读
  探测），单次毫秒级；子进程 `PATH` 的内容和顺序与 0.6.2 不同。macOS 与 Windows
  的排序不同：Windows 前置，macOS 追加；macOS 还会排除项目内的 wrapper 目录，
  Windows 不排除。
- 例外：系统里完全没有 `node` 时不注入任何目录，失败表现与修复前相同；项目里
  只有自带 `node` 时也不注入，仍然按系统环境处理。只能覆盖 Lithe 发现器已知的
  安装位置（PATH、Homebrew、volta、fnm 默认别名、nvm 版本目录）；fnm 为单个
  shell 创建的临时 multishell 目录不在发现范围内，用户没有默认别名时仍会缺
  `node`。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter RunLaunchEnvironmentTests`
  覆盖这些场景：GUI 最小 PATH 下补齐 node 与启动器目录、项目内 node 被排除、
  项目 wrapper 不把仓库根放进 PATH、已有目录去重且保持顺序、显式 PATH 保持优先级、
  缺失 PATH 时使用注入的系统默认值、显式空 PATH 不使用默认值、resolver 对
  `.command` 与 `.toolchain("project-node")` 的接线，以及基础进程环境不被改写。
- `./scripts/verify-service-boundaries.sh`
- 失败形态的手工复现：`env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/env node --version`
  返回 `env: node: No such file or directory`；把 node 目录加进 `PATH` 后恢复。
  发行包上的 GUI 端到端运行未在本机复验。

## 适用范围

- `macos/Sources/Lithe/Services/Java/RunLaunchEnvironment.swift`
- `macos/Sources/Lithe/Services/Java/RunExecutableResolver.swift`
- `macos/Tests/LitheTests/RunLaunchEnvironmentTests.swift`
- 对照实现：`windows/tauri/src-tauri/src/run.rs` 中的 `prepend_runtime_paths`
