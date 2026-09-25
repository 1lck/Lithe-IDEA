# Agent 笔记：Linux GPUI 终端的引擎复用边界

状态：已实现

## 先说结论

Linux 原生 GPUI 版终端不自己实现终端语义，只复用成熟上游 `alacritty_terminal`
作为“终端引擎”（负责解析 ANSI 转义序列、维护字符网格、回滚、选择、搜索），
再由本仓库把它投影成 GPUI 元素。原因是 GPUI 生态不存在可复用的成熟终端
控件，唯一成熟且可合法分发的上游是引擎层。开发者要记住：**终端行为（滚动、
选择、搜索、随窗缩放、reflow）只能调用 `alacritty_terminal` 的既有 API，
禁止在 `terminal.rs` 里手写第二套终端语义。**

## 问题

Linux 版工作台使用 GPUI Kit 构建，底部面板需要一个嵌入式终端。
Windows 版同类能力由前端 xterm.js 承担，xterm.js 是完整的成熟终端控件
（自带网格渲染、滚动、选择、搜索）。GPUI 没有 DOM，无法复用 xterm.js。

早期实现虽然在依赖里引了 `alacritty_terminal`，但只把它当解析器使用：
渲染固定 120×30、不随窗缩放，且完全没接上游已经提供的回滚滚动、
文本选择、复制、搜索 API。结果是终端“能跑但不好用”，并被迫在文件头
声明“多标签、搜索、复制粘贴、随窗缩放暂不支持”。

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

### 不要这样做

- 不要在 `terminal.rs` 里手写 ANSI 解析、换行、光标移动或滚动缓冲。
- 不要固定网格行列数；固定尺寸会让全屏 TUI（如 vim、top）拿不到正确
  窗口大小，也无法随窗缩放。
- 不要用渲染文本的视觉长度代替单元格数换算鼠标列号；宽字符和样式分段
  会让两者不一致。
- 不要为了“加个功能”把终端语义下沉到 `bottom_panel.rs` 或 `view.rs`；
  宿主只负责切换标签、转发命令和生命周期。

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

## 后果

- 收益：滚动、选择、复制粘贴、搜索、随窗缩放、reflow 全部由上游保证，
  本仓库代码量显著下降，缺陷面收敛到“投影与事件接线”。
- 收益：单元格度量、命中换算、PTY 尺寸三处共用同一来源，跨窗口大小与
  字体缩放行为一致。
- 代价：渲染仍需自绘（上游无 GPUI 渲染器），固定单元格排版要求等宽
  字体，非等宽字体下对齐会退化。
- 代价：多标签、横向分屏、超链接点击、图形协议（Sixel/Kitty）仍未接入，
  需后续按需扩展；这些属于产品编排，不属于引擎边界。

## 验证

- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib`
  覆盖：`viewport_to_grid_point` 的边界/内边距/回滚偏移换算、256 色与
  加粗高亮解算，以及引擎联通性（解析输出入网格、回滚 `display_offset`、
  选择导出字符串、`resize` 改变列数）。
- `cargo build --manifest-path linux/Cargo.toml -p lithe-linux` 通过。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` 通过。

## 适用范围

- `linux/src/workbench/terminal.rs`：Linux 终端的引擎调用、渲染投影与事件接线。
- `linux/src/i18n.rs`：终端搜索栏等新增文案键。
- 不适用于 Windows 产品；Windows 终端由
  `windows/tauri/src/features/terminal/`（xterm.js）与
  `windows/tauri/crates/terminal/`（`portable-pty`）承担。
