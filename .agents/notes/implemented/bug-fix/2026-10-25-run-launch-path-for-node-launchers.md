# Agent 笔记：从 Finder 启动的 Lithe 运行 Node 脚本时补齐启动 PATH

状态：已实现

## 先说结论

从 Finder / Dock 启动的应用继承 launchd 的最小环境，`PATH` 只有 `/usr/bin:/bin:/usr/sbin:/sbin`。`pnpm` 这类启动器用 `#!/usr/bin/env node` 找解释器，子进程按自己的 `PATH` 找不到 `node`，于是 `pnpm run <script>` 直接报 `env: node: No such file or directory`（#1455）。现在 Viva 启动时读取登录 shell 的环境（`desktop/internal/loginenv`），运行进程的 `PATH` 由工具链目录加上继承的 `PATH` 组成；仓库内的目录永远不得进入 `PATH` 前部。

## 问题

用户从 Finder 启动发行包，打开 pnpm 管理的项目，点 package.json 里的 `clean` 脚本。输出窗口先显示 `$ pnpm run clean`，紧接着就是 `env: node: No such file or directory`，进程没有真正运行。终端里执行同样的命令正常，因为交互 shell 的启动脚本把 fnm / Homebrew 目录加进了 `PATH`。

问题的根源是：宿主自己能通过 Homebrew、fnm、nvm 找到 `pnpm`，这份探测结果如果没有进入子进程环境，子进程就只能拿到最小的继承环境。

术语：

- launchd：macOS 的进程启动器。Finder 启动的 app 只继承它给出的最小环境，不会读取用户 shell 的启动脚本。
- shebang `#!/usr/bin/env node`：脚本第一行让内核用 `env` 去当前进程的 `PATH` 里查找 `node`。用绝对路径启动脚本并不能替它准备好 `PATH`。

## 决策

- **启动时读取登录 shell 环境。** `desktop/internal/loginenv` 在应用启动时读取登录 shell 的环境，与继承的环境合并（`Merged`）。读取失败或设置了 `LITHE_SKIP_SHELL_ENV` 时，退回继承的环境。
- **运行进程的 `PATH` 由工具链目录和继承值组成。** `desktop/internal/workbench/toolchains.go` 的 `launchSearchPath` 把工具链给出的目录放在前面，然后是继承的 `PATH`；空条目和重复项的规则由 Core 的 `execution.resolveSearchPath`（`desktop/internal/core/run_discovery.go` 的 `ResolveSearchPath`）决定。Core 无法回答时退回简单拼接，保证运行仍能启动。
- **仓库内的目录不进入 `PATH`。** 项目内的 `node`（例如项目自带的解释器）和项目根目录（例如 `mvnw`、`gradlew` 所在目录）都不得注入到 `PATH` 前部。仓库内容不可信，把项目根放到 `PATH` 前部会让仓库里的同名文件劫持脚本后续调用的系统命令。
- **只补运行启动环境，不改基础进程环境。** 终端、调试适配器和语言服务器有各自的环境规则，不能顺带被改掉。

正确做法：

```text
pnpm 在 /opt/homebrew/bin，node 在 fnm 的默认别名目录
子进程 PATH = <工具链目录>:<继承的 PATH（含登录 shell 的 PATH）>
```

不要这样做：

```text
子进程 PATH = <项目根>:<项目 .lithe/bin>:<原有 PATH>
```

后者会让仓库自带的 `node`、`git` 或任何同名文件覆盖系统工具。

## 考虑过的备选方案

- **只把“解析出的可执行文件所在目录”加入 `PATH`**：不够。Homebrew 安装的 `pnpm` 和 fnm 管理的 `node` 经常不在一处，`env node` 仍然找不到解释器。
- **每次运行都先启动一次登录 shell 取得用户 `PATH`**：依赖用户 rc 文件、每次多起一个进程、结果不确定，还会把 shell 初始化副作用带进运行。应用启动时读取一次即可。
- **把项目自带的 `node` 也注入（项目工具优先）**：会让不可信仓库控制用户点击运行的每个脚本的解释器，收益小于风险。

## 后果

- 收益：从 Finder 启动也能运行 `pnpm` / `npm` / `yarn` / `tsx` 等脚本；脚本内部再调用 `node` / `npm` 也能解析到同一套工具。
- 代价：启动时多一次登录 shell 环境读取；读取失败时只能覆盖 Lithe 已知的安装位置，fnm 为单个 shell 创建的临时目录不在范围内，用户没有默认别名时仍会缺 `node`。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core -run TestResolveSearchPathFollowsTheContractFixture`：`ResolveSearchPath` 与 Core 的契约 fixture 一致（`desktop/internal/core/run_discovery_test.go`）。
- `scripts/desktop/desktop-go.sh test ./internal/loginenv/...`：登录 shell 环境的读取与合并。
- 失败形态的手工复现：`env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/env node --version` 返回 `env: node: No such file or directory`；把 node 目录加进 `PATH` 后恢复。发行包上的 GUI 端到端运行需要在 macOS 上手工复验。

## 适用范围

- `desktop/internal/loginenv/loginenv.go`
- `desktop/internal/workbench/toolchains.go`
- `desktop/internal/core/run_discovery.go`
- `desktop/internal/core/run_discovery_test.go`
