# Agent 笔记：Linux GPUI 终端改为复用 gpui_xterm 组件

状态：已实现

## 先说结论

Linux 原生 GPUI 版终端不再自己把 `alacritty_terminal` 的网格投影成 GPUI 元素，
改为整体复用成熟的 GPUI 终端控件 `gpui_xterm`（上游 Modolet/gpui_xterm），
以 vendored 副本放在 `third_party/gpui_xterm/`。开发者要记住三件事：
**终端渲染、键鼠输入、选择与剪贴板归组件负责，不要在本仓库重写**；
**`linux/src/workbench/terminal.rs` 只保留 PTY 会话编排、工程配置接线和组件
没有提供的产品能力（搜索、程序化发送命令、清屏、退出状态）**；
**PTY 子进程的终止与回收继续复用 `run/process.rs` 的“先温和后强制、有界等待”
契约，不另写一套信号逻辑**。

## 问题

上一版实现了“只复用 `alacritty_terminal` 引擎、自己渲染”的方案：解析、网格、
回滚、选择、搜索都用上游，但渲染投影、字符单元格排版、鼠标命中换算、键位映射、
鼠标上报、光标形状全部要本仓库维护。该方案当时的前提是“GPUI 生态不存在可复用
的成熟终端控件”（见已归档笔记
`.agents/notes/archived/architecture/2026-09-25-linux-gpui-terminal-engine-reuse.md`
的备选方案一）。

这个前提后来不成立了：`gpui_xterm` 已经是一个可嵌入 GPUI 应用的完整终端控件，
自带基于 `alacritty_terminal` 的网格渲染、键盘输入、鼠标选择、滚动、剪贴板与
事件回调。继续自绘意味着长期维护一套与上游能力重叠、缺陷面更宽的渲染与输入
代码，且每次 `alacritty_terminal` 升级都要重新对齐投影逻辑。

## 决策

### 复用边界

- `gpui_xterm` 是 Linux 终端的唯一 UI 控件：渲染、键盘输入、鼠标选择、滚动、
  剪贴板、IME、右键上下文菜单都由它提供。
- `linux/src/workbench/terminal.rs` 只做三件事：
  1. 用 `portable-pty` 起 PTY 会话，把输出端与共享写端交给组件；
  2. 把工作目录、平台 shell、字体/回滚设置与主题色映射成
     `gpui_xterm::TerminalConfig`，把组件上报的行列数同步给 PTY；
  3. 在组件之上补它没有的产品能力：终端内搜索、程序化发送命令、清屏、
     回到底部、退出状态展示。
- 终端语义仍全部来自 `alacritty_terminal`（由组件内部使用）。需要读取引擎
  信息（例如显示偏移、设置搜索高亮）时，只调用组件暴露的 `TerminalView::state()`，
  不在本仓库重新解析 ANSI 或重建网格。

### 依赖适配：必须 vendored

上游 `gpui_xterm` 依赖 Zed git 仓库的 `gpui` 与 longbridge git 仓库的
`gpui-component`；Lithe 通过 `gpui-kit` 使用 crates.io 的 `gpui-pre` /
`gpui-component` 包族。Cargo 把 git 依赖与 registry 依赖视为不同的包身份，
即使源码同源也无法类型互通，因此**不能**直接 `gpui_xterm = "0.1.1"`。

因此采用 `third_party/gpui_xterm/` 的 vendored 副本：保留上游源码，只改
`Cargo.toml` 的依赖指向（`gpui = { package = "gpui-pre" }`、`gpui-component`
crates.io 版、`alacritty_terminal` 与产品一致的 0.26），并记录上游 revision
`4bdcdbbeab4211f7938f31919819b06d755a1733`。本地补丁只做必要扩展：暴露引擎
状态（搜索/滚动/显示偏移）、让 `scrollback` 生效，以及把单元格宽度改为按半角
ASCII 步进测量（上游取 `M/W/█/▀/▄` 最大值，块元素会回退到全角字体把整列撑宽）。
完整清单见 `third_party/gpui_xterm/README.md`；升级上游时按该清单重新应用补丁。

### 会话层：终止与回收只有一套契约

`TerminalSession` 拥有主端句柄、共享写端与子进程等待线程，行为与旧实现一致：
先断 writer（`portable-pty` 会写入换行 + EOT，交互 shell 自行退出），再关主端
（slave 立刻收到 hangup），然后 `terminate_process_group` 先发 TERM、超时升级
KILL，最后兜底 `ChildKiller::kill` 并 join 等待线程。每一步都是有界等待，UI
线程不参与等待：会话句柄的 `Drop` 交给一次性后台线程执行。

生命周期用纯状态机 `SessionState`（`Closed`/`Running`/`Stopping`/`Exited`）
表达，退出码与信号由等待线程 `wait()` 之后回传。视图只把退出结果显示在窗格
状态区，不再往网格里写提示行（组件拥有网格，宿主不应注入内容）。

### 写端共享，程序化能力留在宿主

组件构造时需要拿走一个 `Write` 句柄；宿主又需要 `send_command` 能力。解决方式是
`SharedWriter`：会话与组件共享同一份底层 writer，双方写入同一 PTY。程序化清屏
通过向 shell 发送 Ctrl+L（`0x0c`）完成，让 shell 自己重画，而不是去改组件网格。

### 搜索

组件不提供终端内搜索，这是宿主补的能力，语义与旧实现一致：搜索栏复用工作台
唯一的 `search_input::SearchInput`，输入变化后用上游 `RegexSearch` 从网格最旧
一行顺序收集命中，上限 `SEARCH_MATCH_CAP`（超限时计数带 `+`），再按下标做
上一个/下一个环绕。注意上游 `search_next` 在“起点之后没有命中”时会回退返回
第一个命中，所以必须自己判断是否已经环绕。命中高亮复用上游 `Selection` 并配合
`Term::scroll_to_point`。搜索栏做成浮层，打开/关闭不会触发终端 resize 与全屏
TUI 重排。Ctrl+F 由宿主的按键钩子（`with_key_handler`）从组件手里吞掉，再由宿主
容器打开搜索栏，避免组件把 `^F` 写进 PTY 后工作台再收到同一个按键。

### 正确做法

- 需要滚动、选择、复制、随窗缩放时，用组件自身行为或 `TerminalView::state()`
  暴露的上游 API，不要在本仓库重写终端语义。
- 需要搜索时用 `term::search::RegexSearch` + `Term::search_next`，不要自己写
  匹配循环（与旧实现相同）。
- 关闭会话、切换工作目录时走 `TerminalSession` 的既有契约；不要在 UI 线程上
  阻塞等待子进程。
- 组件上报行列数时（resize 回调）必须把 `cols/rows` 同步给 PTY，否则全屏 TUI
  会拿到错误窗口大小。

### 不要这样做

- 不要在 `terminal.rs` 里手写 ANSI 解析、网格、光标、键位映射或鼠标上报编码。
- 不要为了“加个功能”把终端语义下沉到 `bottom_panel.rs` 或 `view.rs`；宿主只
  负责切换标签、转发命令和生命周期。
- 不要为终端另写一套搜索输入框，也不要另存一份 ANSI 调色板。
- 不要跳过 vendored 副本直接依赖 crates.io 的 `gpui_xterm`，那会引入第二套
  GPUI 包身份并在编译期类型撕裂。

## 考虑过的备选方案

### 备选方案一：直接依赖 crates.io 的 `gpui_xterm 0.1.1`

依赖最省事。但它依赖 crates.io 的 `gpui 0.2.2` 与 `gpui-component 0.5.1`，
而 Lithe 用的是 `gpui-pre 0.3.6` 与 `gpui-component 0.6.6`。这些包虽然都源自
Zed 的 GPUI，却是不同的包身份，`Entity`/`Render` 等类型不能互换，编译期即失败，
因此不可行。

### 备选方案二：用 Cargo `[patch]` 把 git `gpui` 重定向到 `gpui-pre`

`[patch]` 以包名匹配，无法把上游依赖的 `gpui` 包替换成包名不同的 `gpui-pre`，
也无法在不改上游清单的前提下统一 `gpui-component` 版本，因此不可行。

### 备选方案三：继续维护自绘实现（旧决策）

维护成本高、缺陷面宽，且与上游能力重叠；每升级一次 `alacritty_terminal` 都要
重新对齐渲染与输入。已被本决策取代。

### 备选方案四：把搜索/鼠标上报等能力也做成 vendored 补丁塞进组件

会让 vendored 副本偏离上游越来越远，升级成本上升。选择只保留“读取引擎状态”
一个最小接线补丁，其余能力留在宿主，边界清晰。

## 后果

- 收益：渲染、输入、选择、滚动、剪贴板、IME、右键菜单由成熟组件保证，本仓库
  代码量大幅下降（`terminal.rs` 从约 3100 行降到约 700 行），缺陷面收敛到
  “会话编排与工程接线”。
- 收益：终端配色、字号、回滚缓冲集中在一处映射，且随 `alacritty_terminal`
  升级只需同步 vendored 副本。
- 代价：多了一份 vendored 上游代码，需要在升级时重新应用补丁。
- 代价（已知能力差异）：组件不提供终端内搜索、向应用上报鼠标事件
  （SGR/X10，影响 vim/htop 鼠标交互）、光标闪烁与“退出提示写进网格”。搜索由
  宿主补齐；其余属于组件能力边界，若产品需要应在组件内实现或向上游补齐，不要
  在本仓库重写渲染与输入。
- 未覆盖：多标签、横向分屏、超链接点击、图形协议（Sixel/Kitty）仍未接入。

## 验证

- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib` 覆盖纯逻辑
  与引擎联通性：会话生命周期状态机、PTY 环境清理、搜索命中序号环绕与计数文案、
  跨回滚缓冲的搜索、主题色浮点转 8 位。
- `cargo build --manifest-path linux/Cargo.toml -p lithe-linux` 通过。
- `./scripts/verify-service-boundaries.sh` 通过（宿主边界未变化）。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` 通过。
- `./scripts/verify-agent-notes.sh` 通过。

## 适用范围

- `third_party/gpui_xterm/`：vendored 上游组件与其依赖适配、本地补丁清单。
- `linux/src/workbench/terminal.rs`：Linux 终端的会话编排、工程接线、
  搜索与宿主能力。
- `linux/src/workbench/run/process.rs`：`terminate_process_group` 同时服务
  Run/Maven 受管进程与集成终端。
- `linux/src/workbench/bottom_panel.rs`：终端窗格状态区、头部动作
  （重启/查找/回到底部/清空/关闭）与工作目录转发。
- `linux/src/workbench/search_input.rs`：终端内搜索复用的唯一输入实现。
- `linux/src/theme.rs`：`terminal_*` token 是终端配色的唯一来源。
- `linux/src/settings.rs`：终端字号与回滚设置的来源。
- 不适用于 Windows 产品；Windows 终端由
  `windows/tauri/src/features/terminal/`（xterm.js）与
  `windows/tauri/crates/terminal/`（`portable-pty`）承担。
