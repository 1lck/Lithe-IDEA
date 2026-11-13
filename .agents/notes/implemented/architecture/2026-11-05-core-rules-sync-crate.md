# Agent 笔记：同步规则 crate（lithe-core-rules）

状态：已实现

## 先说结论

Core 仓库里有一个单独的纯 Rust crate（Rust 的编译单元）`rust/crates/core-rules`。它只放小而确定、不做 I/O 的规则，例如双击 Shift 手势：每次按键都要立刻出结果。
`lithe-core` 依赖它，并把这些规则当作普通 Core 命令分发。桌面端和调用其他 Core 命令一样，通过 C ABI（C 语言调用接口）同步调用这些规则。
这个 crate 原来还会编译成 wasm（WebAssembly，浏览器里能运行的二进制格式），供 Windows 前端同步调用。Windows 前端已经删除，所以从 2026-11-13 起，这个 crate 不再产出 wasm，也不再提供自己的 JSON 请求入口。

## 问题

2026-11-05，Issue #1662 要求把两个客户端里重复的确定性逻辑移进 Core。当时 Windows 前端（Tauri + React）调用 Core 只能用异步的 Tauri `invoke`。但有几条规则必须同步执行：
- LSP-16 在 zustand 的 `set()` 里同步规范化编辑器分组；
- WS-04 在渲染文件树时同步判断哪些路径要隐藏；
- WS-17 在每个按键事件上同步运行。

macOS 通过 FFI 同步调用 Core，没有这个限制。结果是这几条规则只能在两端各写一份，再靠共享 fixture 对照，这正是 #1662 想去掉的重复。

2026-11-08，#1799 删除了两个旧客户端，唯一的宿主变成 Viva 桌面端（Go 编写）。桌面端通过 cgo 链接 `liblithe_core.a`，任何 Core 命令都能同步调用，wasm 构建从此没有使用方。但 Core 里仍然留着只为 wasm 存在的代码：
- `wasm.rs` 里的四个 `extern "C"` 导出；
- `crate-type` 里的 `cdylib`；
- crate 自己的 JSON 信封（请求/响应外层格式）入口 `execute_json` 和 `is_rule_command`；
- `RuleError` 的 JSON 序列化。

这些代码只有测试在调用。

## 决策

- **保留单独的 crate**：它只依赖 serde、serde_json 和 unicode-normalization（动作搜索做 NFC 规范化），不访问文件系统、进程、线程和时钟，时间由调用方传入。规则都写成“状态 + 事件 + 时间戳 → 新状态 + 结果”的纯函数，状态由宿主保存。
  - 保留它的理由不再是 wasm，而是依赖边界由编译器保证：规则代码引用不到 `lithe-core` 的 I/O 和全局状态。
  - 拆分 Core crate 时，它也正好属于最底层的基础层。
- **命令仍是 Core 命令**：
  - `lithe-core` 的 JSON 分发把 `lithe_core_rules::COMMANDS` 里列出的命令交给 `lithe_core_rules::execute(command, payload)`。
  - 命令名、信封和错误码与其他 Core 命令一致。`RuleError` 由 `lithe-core` 一对一转换成 `CoreError`。
  - 这个 crate 自己不解析信封。
- **当前包含的规则**：
  - `keymap.modifierGestureStep`：双击 Shift 手势（WS-17）。桌面端只负责转换原生事件、保存 Core 返回的状态，并把 `triggered` 变成动作。
  - `editor.workbenchState.reduce`：编辑器分组成员状态（LSP-16）。状态包括有序去重的成员、选中项、MRU、固定和预览。
    - 两个旧客户端在“选中项离开分组”时的行为不同。请求里的 `selectionFallback`（`first` 或 `adjacent`）保留了这两种行为。
    - 布局树、拆分方向和比例不进 Core，宿主只按返回的 `removedGroupIds` 修剪自己的布局。
  - `workspace.classifyVisibility` 和 `workspace.visibilityDefaults`：隐藏路径规则（WS-04）。内置默认列表和 glob 匹配只写在 `visibility.rs` 里，`lithe-core` 的 `project/files.rs` 直接复用这份代码。
  - `workbench.chromeLayout.reduce`：工作台外框上可拖动按钮的位置，覆盖两侧工具条、标题栏末端和状态栏末端。
  - `keymap.parseContext`、`keymap.evaluateContext`、`keymap.analyzeConflicts`、`keymap.schemes.reduce`：快捷键上下文表达式的解析与求值、冲突分析、快捷键方案的合并。2026-11-13 随 Core #27 从 `lithe-core` 的 `keymap/` 移入，命令名和 JSON 不变。
  - `search.actions`：动作搜索的匹配与排序。2026-11-13 随 Core #27 从 `lithe-core` 的 `action_search/` 移入，命令名和 JSON 不变。
- **2026-11-13 删除 wasm 构建**：
  - Core 里删除 `wasm.rs`、`cdylib`、`execute_json`、`is_rule_command` 和 `RuleError` 的序列化，fixture 测试改为直接调用 `execute`。
  - `lithe-core` 自己的 `cdylib` 同时删除，它也没有使用方。
  - 本仓库删除 `core-rules-wasm` 资源登记、对应测试和 `docs/ci-builds.md` 里的说明段落。

## 边界

这个 crate 只放纯计算、体量小的规则。涉及 I/O、进程、文件、网络、耗时长或数据量大的逻辑，放在 `lithe-core` 或对应的基础层 crate。

判断方法：如果规则要读文件、调用外部程序，或者要用 `lithe-core` 的其他模块，就不要放进这个 crate。

- 正确：双击 Shift 状态机，时间戳由宿主传入。
- 不要这样做：在 crate 里读取 `.lithe/` 配置来决定隐藏规则。应该由 `lithe-core` 读取配置，再把读到的列表作为参数传给规则。

## 考虑过的备选方案

- **（2026-11-05）把 Windows 的 pane store 全部改成异步**：`set()` 里不能 `await`，要重写所有读写这个 store 的组件，还要处理中间状态的竞态。风险和改动范围都远大于这几条规则，被否决。
- **（2026-11-05）TypeScript 和 Swift 各留一份算法，靠共享 fixture 对照**：这是迁移前的做法。fixture 只能发现已经写进去的用例，新分支仍然会漂移，被否决。
- **（2026-11-05）引入 wasm-bindgen**：需要额外的工具链和生成的胶水 JS，版本还要和依赖严格匹配。我们只需要 JSON 进、JSON 出，手写四个 C 函数更小，也更容易审查，被否决。这个 ABI 已随 wasm 构建一起删除。
- **（2026-11-13）删除 wasm 后，把规则并回 `lithe-core`**：crate 只剩一个使用方，并回去可以少一个 workspace 成员。没有采用，因为依赖边界会退回到只靠约定，而 Core 拆 crate 的方向是增加由编译器保证的边界。
- **（2026-11-13）保留 wasm 构建，留给将来的网页前端**：没有使用方的产物仍要维护编译目标、注释和资源登记，被否决。将来真的需要时，可以从 git 历史恢复 `wasm.rs`。

## 后果

- 新增规则时，要同时在 `lithe-core-rules` 的 `COMMANDS` 和 `lithe-core` 的 `CoreCommand` 里注册。`every_rules_crate_command_is_routed_by_core` 测试会拦住遗漏。
- 测试分两层：
  - 规则 crate 的测试只检查 `execute` 的结果和错误码。
  - 信封解析由 `lithe-core` 的协议测试覆盖，例如无法解析的 JSON 要返回 `invalid_request`，且 `id` 为空。
- 本地开发和 CI 不再需要 `wasm32-unknown-unknown` 编译目标。
- 代价：删除 wasm 后，这个 crate 与 `lithe-core` 其他模块的区别只剩依赖边界。以后如果某条规则需要 I/O，必须拆成两段：`lithe-core` 读取数据，规则 crate 只做纯计算。

## 验证

- Core 仓库：`cargo test -p lithe-core-rules` 直接调用 `execute`，`cargo test -p lithe-core --lib protocol` 经过 JSON 信封，两者跑同一份 fixture。
- Core 仓库：`git grep -n -i wasm -- rust/crates/core-rules` 没有结果。
- Core 仓库：`cargo tree --manifest-path rust/Cargo.toml -p lithe-core-rules --edges normal --depth 1` 只列出 serde、serde_json 和 unicode-normalization。
- 桌面端：`scripts/desktop/desktop-go.sh test ./internal/core/...` 通过真实的 Core 调用 `workbench.chromeLayout.reduce` 等规则命令。
- 本仓库：`node scripts/resources/test-reuse-worktree-resources.mjs` 通过，资源登记里没有 `core-rules-wasm`。

## 适用范围

规则 crate 本身在 Core 仓库的 `rust/crates/core-rules/`。本仓库里调用这些规则的入口：

- `desktop/internal/core/keymap_gesture.go`
- `desktop/internal/core/workbench.go`
- `desktop/internal/core/chrome.go`
- `desktop/internal/core/editor_essentials.go`（`keymap.schemes.reduce`）
