# Agent 笔记：Linux GPUI 终端的引擎复用边界

状态：已实现

归档日期：2026-09-26

被 `.agents/notes/implemented/architecture/2026-09-26-linux-gpui-terminal-component-reuse.md` 取代。

## 先说结论

Linux 原生 GPUI 版终端不自己实现终端语义，只复用成熟上游 `alacritty_terminal`
作为“终端引擎”（负责解析 ANSI 转义序列、维护字符网格、回滚、选择、搜索），
再由本仓库把它投影成 GPUI 元素。原因是 GPUI 生态不存在可复用的成熟终端
控件，唯一成熟且可合法分发的上游是引擎层。开发者要记住两件事：**终端行为
（滚动、选择、搜索、随窗缩放、reflow）只能调用 `alacritty_terminal` 的既有
API，禁止在 `terminal.rs` 里手写第二套终端语义**；**PTY 子进程的终止与回收
复用 `run/process.rs` 的“先温和后强制、有界等待”契约，不另写一套信号逻辑。**

## 问题

Linux 版工作台使用 GPUI Kit 构建，底部面板需要一个嵌入式终端。
Windows 版同类能力由前端 xterm.js 承担，xterm.js 是完整的成熟终端控件
（自带网格渲染、滚动、选择、复制、搜索）。GPUI 没有 DOM，无法复用 xterm.js。

第一版实现虽然在依赖里引了 `alacritty_terminal`，但只把它当解析器使用：
渲染固定 120×30、不随窗缩放，且完全没接上游已经提供的回滚滚动、
文本选择、复制、搜索 API。结果是终端“能跑但不好用”，并被迫在文件头
声明“多标签、搜索、复制粘贴、随窗缩放暂不支持”。

接上滚动与选择之后仍然不能当 IDE 终端用：关闭会话只是丢句柄（拿不到退出码，
子孙进程可能残留）、PTY 环境照抄宿主终端变量、搜索从光标位置起算导致计数与
上一个/下一个都不可信、自带一份硬编码 ANSI 调色板与主题脱节、
`terminal.new`/`terminal.close` 只是重建网格和折叠面板。

## 决策

### 复用边界

- `alacritty_terminal` 0.26 是 Linux 终端的唯一引擎。解析、网格状态、
  回滚缓冲、选择模型、正则搜索、resize/reflow 全部由它提供。
- `linux/src/workbench/terminal.rs` 只做三件事：
  1. 用 `portable-pty` 起 PTY 会话并转发字节；
  2. 调用上游 API（`Term::resize`、`Term::scroll_display`、
     `Selection`、`RegexSearch`、`Term::renderable_content`）；
  3. 把网格投影成 GPUI 元素并处理鼠标/键盘事件。
- 渲染层实现成“固定字符单元格”排版：单元格宽度由上游
  `WindowTextSystem::em_layout_width` 按当前字号实测，行高按字号倍率换算。
  鼠标坐标换算、PTY 行列数、网格 `cols/rows` 三者必须使用同一套
  `CellMetrics`，否则选择与点击会出现半格偏移。

### 会话层：终止与回收只有一套契约

`TerminalSession` 拥有主端句柄、writer、子进程和 reader 线程。关闭顺序与
`run/process.rs` 的受管进程一致：先断 writer（`portable-pty` 会写入换行 +
EOT，交互 shell 自行退出），再关主端（slave 立刻收到 hangup），然后
`terminate_process_group` 先发 TERM、超时升级 KILL，最后兜底
`ChildKiller::kill` 并 join reader 线程。每一步都是有界等待，UI 线程不参与
等待：会话句柄的 `Drop` 交给一次性后台线程执行。

生命周期用纯状态机 `SessionState`（`Closed`/`Running`/`Stopping`/`Exited`）
表达，退出码与信号由 reader 线程 `wait()` 之后回传，视图把结果写进网格并
显示在窗格状态区。不要为了“关得更快”只 drop 主端句柄，也不要在 UI 线程上
阻塞等待子进程。

### 尺寸：prepaint 驱动，不靠固定初值

网格容器用 `on_children_prepainted` 拿到当帧实测边界后立刻 `Term::resize`
并同步 PTY 行列数，面板折叠/展开与窗口缩放都在当帧生效，不存在“先按上一帧
尺寸渲染、下一帧才纠正”。首帧还没有实测值时用引导尺寸开会话，同一帧的
prepaint 就会纠正。自动创建会话只尝试一次：失败或用户显式关闭之后不会每帧
重开，否则会变成满 CPU 的重连循环。

### PTY 环境

会话环境 = 宿主环境减去宿主终端遗留变量（`COLUMNS`/`LINES`/`WT_SESSION`/
`ITERM_SESSION_ID` 等），再加上 `TERM=xterm-256color` 与
`COLORTERM=truecolor`。`TMUX`/`STY` 故意保留，嵌套会话需要它们。

### 搜索

搜索栏复用工作台唯一的 `search_input::SearchInput`（不重写输入框），输入变化
后用上游 `RegexSearch` 从网格最旧一行顺序收集命中，上限 `SEARCH_MATCH_CAP`
（超限时计数带 `+`），再按下标做上一个/下一个环绕。注意上游 `search_next`
在“起点之后没有命中”时会回退返回第一个命中，所以必须自己判断是否已经环绕。
命中高亮复用上游 `Selection` 并配合 `Term::scroll_to_point`。搜索栏做成浮层，
打开/关闭不会触发终端 resize 与全屏 TUI 重排。

### 渲染

前景/底色取 `theme.rs` 的 `terminal_*` token：8 个基础色直接用主题，亮色/
暗色变体与 `Dim*`/`Cursor` 由基础色派生，256 色的立方体与灰阶仍按 xterm 公式
计算。**不要再写第二份硬编码 ANSI 调色板**；命名色也不要再用 `named as u8`
取下标，那会把 `DimRed`(259) 折回 `Yellow`。单元格按上游 `Flags` 处理
`INVERSE`/`HIDDEN`/`DIM`/粗斜体/下划线/删除线，宽字符的占位格只占宽度不绘制
字符；光标形状按上游 `CursorShape` 画成反色块、下划线、竖线或空心块。

### 正确做法

- 需要滚动时调用 `term.scroll_display(Scroll::Delta / Bottom)`，不要
  自己维护偏移量。
- 需要复制时调用 `term.selection_to_string()`，不要自己遍历网格拼字符串。
- 需要搜索时用 `term::search::RegexSearch` + `Term::search_next`，不要
  自己写匹配循环。
- 容器尺寸变化时用 `Term::resize(TermDims)` 并把 `cols/rows` 同步给 PTY；
  reflow 由上游完成。
- 鼠标命中用 `viewport_to_grid_point(局部坐标, CellMetrics, TermDims, display_offset)`
  换算，回滚偏移必须叠加，保证上滚后仍命中用户看到的同一行。
- 应用要求鼠标事件时（`TermMode::MOUSE_REPORT_CLICK`/`MOUSE_MOTION`），把事件
  编码成 SGR 1006（回退 X10）发给应用，不要抢走做本地选择；是否上报由上游
  模式决定，拖动上报只在按住鼠标时发。

### 不要这样做

- 不要在 `terminal.rs` 里手写 ANSI 解析、换行、光标移动或滚动缓冲。
- 不要固定网格行列数；固定尺寸会让全屏 TUI（如 vim、top）拿不到正确
  窗口大小，也无法随窗缩放。
- 不要用渲染文本的视觉长度代替单元格数换算鼠标列号；宽字符和样式分段
  会让两者不一致。
- 不要为了“加个功能”把终端语义下沉到 `bottom_panel.rs` 或 `view.rs`；
  宿主只负责切换标签、转发命令和生命周期。
- 不要为终端另写一套搜索输入框，也不要另存一份 ANSI 调色板。

## 考虑过的备选方案

### 备选方案一：引入 GPUI 生态的终端控件

如果存在成熟的 GPUI 终端控件，可以像 xterm.js 一样整体复用，工作量最小。
但实际盘点后不存在：本地 Cargo registry 与可访问上游都没有
`gpui-term`、`gpui_term`、`terminal-gpui` 这类 crate；Alacritty 自身的
渲染在 `alacritty` 二进制 crate 中，基于 OpenGL/winit，与 GPUI 的
`Element`/`Render` 体系不兼容，无法直接嵌入。

### 备选方案二：复用 `viml` / `wezterm-term` / `termwiz` 引擎

这些是其他终端模拟器的引擎，成熟度也够。但它们与 `alacritty_terminal`
能力重叠，且现有实现已经在用 `alacritty_terminal`。为同一目标引入第二个
引擎会增加依赖体积和双份语义，收益为零，因此不采用。

### 备选方案三：继续维护现有固定尺寸实现

改动最小，但无法满足“和 Windows/Tauri 终端一致”的产品目标：固定
120×30、无回滚、无选择、无搜索、无缩放，属于明确的能力缺口，不是可接受
的长期状态。

### 备选方案四：终端自建进程组终止逻辑

PTY 子进程自带会话与进程组，可以直接在 `terminal.rs` 里发信号。但
`run/process.rs` 已经把“先温和后强制、有界等待”做成
`terminate_process_group`，另写一份会出现两套等待时长与两套降级策略，
因此选择复用。

## 后果

- 收益：滚动、选择、复制粘贴、搜索、随窗缩放、reflow 全部由上游保证，
  本仓库代码量显著下降，缺陷面收敛到“投影与事件接线”。
- 收益：单元格度量、命中换算、PTY 尺寸三处共用同一来源，跨窗口大小与
  字体缩放行为一致。
- 收益：关闭会话拿得到退出码与信号，窗口折叠/展开与项目切换都不会留下
  孤儿 shell；终端配色跟随主题。
- 代价：渲染仍需自绘（上游无 GPUI 渲染器），固定单元格排版要求等宽
  字体，非等宽字体下对齐会退化。
- 代价：搜索高亮复用上游 `Selection`，因此搜索高亮与用户拖选的选区共用
  一份状态，关闭搜索会清掉选区。
- 未覆盖：多标签、横向分屏、超链接点击、图形协议（Sixel/Kitty）仍未接入。
  会话层 `TerminalSession` 不依赖 GPUI，后续加标签只需在 `TerminalView`
  上并列多个会话；超链接与图形协议属于引擎/渲染能力缺失，需要单独决策。

## 验证

- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib`
  覆盖纯逻辑与引擎联通性：`viewport_to_grid_point` 的边界/内边距/回滚偏移
  换算、容器尺寸到网格行列数（含最小值与上限钳制）、会话生命周期状态机、
  按键映射（控制字符、复制粘贴搜索、翻页滚动、方向键模式、Alt 序列、
  放行组合）、鼠标上报编码（SGR/X10、拖动与抬起、偏移叠加）、搜索命中
  序号环绕与计数文案、跨回滚缓冲的搜索、PTY 环境清理、主题调色板与
  命名色/加粗/反色解算，以及引擎侧的解析、回滚 `display_offset`、选择导出、
  `resize` 与宽字符占位格。
- `cargo build --manifest-path linux/Cargo.toml -p lithe-linux` 通过。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` 通过。

## 适用范围

- `linux/src/workbench/terminal.rs`：Linux 终端的会话生命周期、引擎调用、
  渲染投影与事件接线。
- `linux/src/workbench/run/process.rs`：`terminate_process_group` 同时服务
  Run/Maven 受管进程与集成终端。
- `linux/src/workbench/bottom_panel.rs`：终端窗格状态区、头部动作
  （重启/查找/回到底部/清空/关闭）与工作目录转发。
- `linux/src/theme.rs`：`terminal_*` token 是终端配色的唯一来源。
- `linux/src/i18n.rs`：终端会话、搜索与退出提示文案键。
- 不适用于 Windows 产品；Windows 终端由
  `windows/tauri/src/features/terminal/`（xterm.js）与
  `windows/tauri/crates/terminal/`（`portable-pty`）承担。
