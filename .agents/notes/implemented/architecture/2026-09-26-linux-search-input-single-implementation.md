# Agent 笔记：Linux 工作台的搜索输入只有一套实现

状态：已实现

## 先说结论

Linux 工作台里凡是「输入关键词过滤 / 选择一个东西」的搜索框，都必须用
`linux/src/workbench/search_input.rs` 里的 `SearchInput` 组件。它内部包的是
gpui-kit 官方的 `Input` / `InputState`，由组件负责中文输入法组字、粘贴、
选区和光标；各弹窗只订阅业务事件。

开发者以后最需要记住的是两条：**不要再自己用 `div` + `on_key_down` +
`key_char` 拼一个输入框**；**不要在 `Render::render` 里每帧调用
`window.focus(&root_focus_handle)`**，那会把焦点从搜索框手里夺走，表现为
「点得进去却打不出字」。

## 问题

Linux 工作台的多个浮层（文件树过滤、快速打开、命令面板、跳转到行、
Search Everywhere、分支管理器）一开始都各自实现了一个「输入框」：一个普通
`div` 显示当前文本，配一个 `on_key_down` 监听器，遇到可打印字符就把
`key_char` 手动 `push` 到查询串，遇到退格就 `pop`。

这种自绘输入在 X11 上有三个真实的用户可见缺陷：

1. **打不出中文**。GPUI 的输入法（IME，如 ibus / XIM）组字需要把
   `InputHandler` 注册到有焦点的节点上。自绘 `div` 没有注册，输入法提交的
   组合字符串无处落地。用户看到的是「敲拼音没反应」。
2. **不能粘贴**。`Ctrl+V` 需要组件主动向剪贴板取文本并插入光标处，自绘
   `div` 只会把 `v` 当普通字符。
3. **规则漂移**。每个浮层都抄一遍「什么算可打印字符、退格怎么删、
   修饰键怎么忽略」，六份实现迟早不一致。

## 决策

把「搜索输入」收敛成 `SearchInput` 一个组件，所有搜索框接入它。

### 正确做法

- 新建浮层时，用 `SearchInput::new(placeholder, window, cx)` 拿一个搜索框，
  用 `search.subscribe(cx, |this, event, cx| ...)` 订阅
  `InputEvent::Change`（文本变化）和 `InputEvent::PressEnter { shift, .. }`
  （回车 / Shift+回车）；把返回的 `Subscription` 存进结构体字段，否则订阅
  立即失效。
- 渲染时直接 `.child(search.element())`。它已经带 `flex_1`、`min_w_0`，并
  用 `appearance(false)` 关掉组件自带的背景 / 边框 / 焦点环，外观由你外面的
  行容器决定，避免多出一层阴影或双边框。
- 回车统一走 `InputEvent::PressEnter`，**不要在 `on_key_down` 里再处理
  `"enter"`**。单行 `Input` 在回车时会派发该事件并继续向上冒泡，所以
  订阅方和祖先的 `on_key_down` 都能收到；重复处理会导致确认动作执行两次。
- 方向键（`up` / `down`）可以照常放在浮层根节点的 `on_key_down` 里做列表
  导航。单行 `Input` 不会为自己注册 `up` / `down` 的动作处理器（那一组只在
  多行模式下注册），所以按键会冒泡到根节点。
- 打开浮层时只聚焦一次。用 `pending_reset` / `pending_search_focus` 这类
  布尔标志，在 `render` 的第一帧把 `search.set_value("", ...)` 与
  `search.focus(...)` 一起做掉；此时才持有 `Window`，也是唯一需要 `Window`
  的时机。
- `Esc` 关闭浮层可以继续放在根节点 `on_key_down`：单行 `Input` 在
  `escape` 且没有内联补全 / IME 预编辑残留时会 `cx.propagate()`，事件能到
  根节点。

### 不要这样做

- 不要为了「看起来像输入框」而用 `div` 显示查询串加一个静态光标条。它没有
  输入法注册、没有剪贴板、没有选区，中文与粘贴直接失效。
- 不要在 `Render::render` 里每帧 `window.focus(...)` 抢焦点。渲染每帧都会
  执行，抢焦点会让搜索框刚拿到焦点就被夺走，症状是「能点、能看、打不出字」，
  极难定位。
- 不要各自复制 `InputState::new(...)` 再自己维护一份订阅逻辑。占位文案、去
  边框、`flex_1` 这些细节应当只有一处。
- 不要用 `#[cfg(target_os = ...)]` 给不同平台写两套输入路径。`SearchInput`
  只依赖 gpui-kit 官方 API，可编译到 macOS / Windows。

## 考虑过的备选方案

### 备选方案一：继续用自绘 `div`，只给它补 IME 钩子

最有吸引力的地方是改动最小，不用碰六个浮层的渲染。但「补 IME」本质上就是
要按 GPUI 的输入处理器协议实现一个迷你输入框，等于把 `Input` 已有的能力
（粘贴、选区、光标、撤销、鼠标点选）再实现一遍，长期维护成本更高，因此不
采用。

### 备选方案二：直接在每个浮层里内联 `Input` / `InputState`

能立刻修好中文和粘贴，六个浮层各写一遍 `InputState::new` + `cx.subscribe` +
`.appearance(false)`。问题在于「去边框 + flex_1 + 订阅生命周期 + 打开只聚焦
一次」这套约束会被复制六份，正是漂移的来源，因此不采用。

### 备选方案三：把搜索框做成一个 GPUI Entity（`SearchInputView`）

作为实体可以自己 `render`、自己持有订阅，看起来更「组件化」。代价是父浮层
要再套一层实体、焦点路径变深、事件回调要跨实体传递，而当前需求只是「一个
输入框 + 把事件转给父级」，用普通结构体加 `cx.subscribe` 已经够，因此不采用。

## 后果

- 收益：中文输入法、`Ctrl+V` 粘贴、选区、光标移动在所有搜索框里一次到位，
  且行为完全一致。
- 收益：占位文案、去边框外观、订阅接线只有一处实现，新浮层接入成本降为
  几行。
- 代价：`SearchInput` 的 `subscribe` 需要调用方自己保存 `Subscription`。
  忘记保存会静默失效（输入框能打字但父级收不到变化），这是 GPUI 订阅的
  通用约定，不是本组件特有。
- 代价：需要调用方遵守「打开只聚焦一次」。如果某个浮层坚持每帧 `focus` 根
  节点，症状会回来。
- 需要重新评估的触发条件：如果以后出现「需要多行搜索输入」或「需要把搜索
  框嵌进虚拟列表复用」的需求，`SearchInput` 的 `element()` 外观假设可能需要
  扩展。

## 验证

- `cargo build --manifest-path linux/Cargo.toml -p lithe-linux`：所有接入方
  编译通过且无警告。
- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib`：
  95 项测试通过（搜索相关的纯逻辑测试见 `workbench::tree_search`、
  `workbench::global_search`、`workbench::branch_manager_logic`）。
- `bash scripts/build-linux.sh`：canonical 二进制
  `target/debug/lithe-linux` 构建成功。
- 手工验证：分别打开文件树过滤、快速打开、命令面板、跳转到行、
  Search Everywhere、分支管理器，确认可以用输入法输入中文、可以用
  `Ctrl+V` 粘贴、回车执行、`Esc` 关闭、方向键在列表中选择。

## 适用范围

- `linux/src/workbench/search_input.rs`：搜索输入组件本体。
- `linux/src/workbench/sidebar.rs`：文件树过滤。
- `linux/src/workbench/quick_open.rs`：快速打开。
- `linux/src/workbench/command_palette.rs`：命令面板。
- `linux/src/workbench/go_to_line.rs`：跳转到行。
- `linux/src/workbench/search_everywhere.rs`：Search Everywhere。
- `linux/src/workbench/branch_manager.rs`：分支管理器搜索。
- 不适用于 Windows 与 macOS 产品；它们的搜索框真源分别是
  `windows/tauri/src/features/` 与 `macos/Sources/Lithe/Views/`。
