# Agent 笔记：Run/Maven 输出改用 PTY + 终端组件控制台

状态：已实现

## 先说结论

Run 与 Maven 面板的输出不再逐行拼纯文本，而是**让受管进程跑在 PTY 上**，把 PTY 的
原始字节交给 `gpui_xterm` 终端组件渲染。开发者要记住三件事：**受管步骤必须经
`portable-pty` 启动、输出必须是原始字节**（否则 Maven/JDK 不会输出颜色）；
**宿主自己的提示（命令回显、错误、状态）统一走
`OutputConsole::write_heading/write_muted/write_error`，不要直接拼 ANSI；**
**不要退回“读管道按行存 `Vec<String>` 再画 div”的老做法**。

## 问题

Run/Maven 面板此前用 `std::process` + 管道启动受管进程，`BufReader::lines()` 逐行
读取，存进 `run_output: Vec<String>` / `maven_output: Vec<String>`，再用纯文本
`div` 渲染（`render_output_line`，无任何 ANSI 解析）。带来三个问题：

1. **子进程不是 TTY**，Maven/JDK/Spring 等会主动关闭彩色输出，进度条 `\r` 也被
   当成普通字符；面板永远是单色纯文本。
2. 逐行渲染没有终端排版：宽字符/换行对齐、`\r` 覆盖、光标控制全部丢失。
3. 面板自行截断输出（`MAX_RUN_OUTPUT`/最后 800 行），与终端组件已有的回滚缓冲
   重复且行为不同。

## 决策

### 受管进程跑在 PTY 上

`workbench/run/process.rs` 的每个步骤改用 `portable-pty` 启动：
`native_pty_system().openpty(size)` → `slave.spawn_command(cmd)`。因此：

- 子进程看到真正的 TTY，彩色输出、`\r` 进度条、宽度感知都恢复；
- stdout/stderr 由 PTY 合并为一路，`ProcessEvent::Output` 直接携带**原始字节**
  （不再有 `OutputStream`/`text` 字段）；
- `portable-pty` 让子进程 `setsid`，子进程 pid 即进程组 id，停止仍复用既有的
  “先温和后强制、有界等待”契约（`send_signal(-pgid)` + `wait_for_child`）；
- 退出码取 `ExitStatus::exit_code()`；被信号终止时给出显式错误。

PTY 行列数由宿主的输出控制台实测尺寸决定（见下），保证子进程按真实宽度排版。

### 只读输出控制台

新增 `workbench/console.rs` 的 `OutputConsole`：

- 一个**只读** `gpui_xterm::TerminalView`：写端是 `io::sink()`，读端是
  `ChannelReader`（把 `mpsc` 字节块适配成 `Read`）；
- 宿主在 UI 线程通过 `write_bytes`（受管进程 PTY 原始字节）与
  `write_text/write_heading/write_muted/write_error`（自己的提示，带 ANSI 配色）
  喂数据；`clear` 发 `ESC[2J ESC[H`；
- 通过 resize 回调记录终端实测行列数，作为受管进程 PTY 的初始尺寸
  （每次运行启动时快照一次）；
- 配色复用 `terminal::terminal_color_palette()`，字体复用 `fonts::mono_family(cx)`，
  与集成终端同一套，不新增第二份 ANSI 调色板。

Run 与 Maven 面板各持有一个 `OutputConsole`，`run_output`/`maven_output` 字段由
`Vec<String>` 换成 `OutputConsole`（仍保留 `is_empty()`/`clear()` 语义供门控使用），
渲染直接挂载终端视图；滚动交给终端组件自己处理。

### “跟随末尾”

不再用 `ScrollHandle` + 行数比较。开着跟随时，每次输出事件后调用
`OutputConsole::scroll_to_bottom`；打开跟随时立即滚到底。用户手滚上去后输出不会
强行拉回（与终端行为一致）。

### 正确做法

- 受管步骤启动一律走 `ProcessManager::start(..., terminal_size)`，不要回到
  `std::process::Command` + 管道。
- 输出一律把原始字节交给 `OutputConsole`，不要在 `bottom_panel.rs` 里解析 ANSI 或
  按行拆分。
- 宿主提示用 `write_heading`（命令行/表头）、`write_muted`（状态）、`write_error`
  （错误）三类，配色集中在这三个方法里。
- 新增需要“终端观感”的只读输出，复用 `OutputConsole`，不要再写一套文本渲染。

### 不要这样做

- 不要给受管进程用管道后“手动补 `-Dstyle.color=always`”之类的开关来凑颜色；
  让子进程看到 TTY 才是根因修复。
- 不要在 `bottom_panel.rs` 里再引入 `Vec<String>` 行缓冲或行数上限。
- 不要把 `OutputConsole` 做成可交互控制台（向子进程写键盘输入）；Run 控制台
  只需要渲染与选择/复制。

## 考虑过的备选方案

### 备选方案一：保留管道，把原始字节喂给虚拟终端

改动最小（只把 `spawn_reader` 改成读字节 + 给组件加 `feed_bytes`），但子进程不是
TTY，Maven/JDK 依旧不输出颜色，`\r` 进度条虽能覆盖但整体观感提升有限。用户明确
选择了“真终端”，故不采用。

### 备选方案二：只美化现有文本渲染

不动进程层，仅做关键词着色/行距/对齐。治标不治本，且与终端组件能力重复。不采用。

### 备选方案三：每个步骤新建一个终端视图

会丢失跨步骤的连续输出与回滚历史，且重复创建视图成本高。选择“一个控制台 +
channel 持续喂数据”。

## 后果

- 收益：Run/Maven 输出获得彩色、`\r` 进度、宽字符与换行对齐，与 IDEA 控制台观感
  一致；宿主提示有统一的强调/灰/红配色。
- 收益：输出滚动/回滚复用终端组件，`MAX_RUN_OUTPUT` 与 800 行截断等重复逻辑删除。
- 代价：stdout/stderr 合并，失去原先 `[stderr]` 前缀区分（PTY 的固有代价）。
- 代价：控制台是真实终端视图，会显示光标、可获焦点（键盘输入写到 `sink` 无副作用）；
  只读化属于组件能力，暂未实现。
- 注意：PTY 尺寸在每次运行启动时快照，运行中途改变面板宽度不会 resize 正在跑的
  PTY（下次运行生效）。

## 验证

- `bash scripts/build-linux.sh` 通过，产物 `target/debug/lithe-linux`。
- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib` 通过；其中
  `workbench::run::process::tests` 覆盖 PTY 下的步骤失败短路与整进程组停止。
- 运行 Maven/Spring 配置，输出为彩色，`\r` 进度条正常覆盖。
- `./scripts/verify-agent-notes.sh` 通过。

## 适用范围

- `linux/src/workbench/run/process.rs`：受管步骤的 PTY 启动、原始字节输出、停止与
  回收契约。
- `linux/src/workbench/console.rs`：只读输出控制台（终端视图 + 字节通道 + 配色提示）。
- `linux/src/workbench/bottom_panel.rs`：Run/Maven 面板挂载控制台、状态与门控。
- `linux/src/workbench/terminal.rs`：`terminal_color_palette` 被控制台复用的唯一调色板。
- `linux/src/fonts.rs`：控制台等宽字体来源。
- `third_party/gpui_xterm/`：提供终端视图与 `state()` 补丁。
- 不适用于 macOS/Windows 产品；两端的 Run 控制台由各自前端承担。
