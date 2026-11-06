# Agent 笔记：同步规则桥（lithe-core-rules 与 wasm）

状态：已实现

## 先说结论

少数必须“同步”执行的小规则（例如双击 Shift 手势，每个按键事件都要立刻出结果）放进新的纯 Rust crate
`rust/lithe-core-rules`。`lithe-core` 依赖它，macOS 通过原来的 FFI（Swift 调用 Rust 的 C 接口）调用；
同一份源码再编译成 wasm（WebAssembly，浏览器可运行的二进制），Windows 前端在启动时异步加载一次，之后同步调用。
规则只有一份源码，不再在 Swift 和 TypeScript 各写一遍再靠 fixture 对照。

## 问题

Issue #1662 要求把两端重复的确定性逻辑下沉到 Core。Windows 前端调用 Core 只有异步的 Tauri `invoke`，
而几条规则卡在同步热路径上，下沉不了：LSP-16 在 zustand 的 `set()` 里同步规范化 pane 树；WS-04 在文件树渲染时
同步判断隐藏；WS-17 在每个按键事件上同步运行。macOS 通过 FFI 同步调用 Core，没有这个问题。
结果是这类规则只能两端各留一份实现，只靠共享 fixture 防止走样，而这本身就是 #1662 想消除的重复。

## 决策

- **新 crate `lithe-core-rules`**：只依赖 serde 和 serde_json，不碰文件系统、进程、线程、时钟（时间由调用方传入），
  能编译到 `wasm32-unknown-unknown`。规则以“状态 + 事件 + 时间戳 → 新状态 + 结果”的纯函数表达，状态由宿主持有。
- **命令仍是 Core 命令**：`lithe-core` 的 JSON 分发把这些命令转给 crate，命令名、请求/响应 envelope（信封）和
  错误码与其他 Core 命令一致，例如 `keymap.modifierGestureStep`。macOS 和 Windows 的 Rust 后端走原通道。
- **wasm ABI 不用 wasm-bindgen**：只导出 `lithe_rules_alloc`、`lithe_rules_dealloc`、`lithe_rules_execute`、
  `lithe_rules_result_len` 四个 `extern "C"` 函数，输入输出都是 JSON 字节，复用 Core 的 envelope。
- **启动时异步加载**：Chromium（WebView2）不允许主线程同步编译大于 4 KB 的 wasm，所以
  `windows/tauri/src/core/core-rules.ts` 的 `initializeCoreRules()` 在 `main.tsx` 里先异步 instantiate，
  成功后才渲染 React；之后 `executeCoreRuleSync(command, payload)` 全部同步。加载失败显示本地化错误
  （`coreRules.initFailed`），**不回退到 TypeScript 算法**。
- **WS-17 作为首个端到端迁移**：Swift `DoubleShiftGestureRecognizer` 和 TS `double-shift-recognizer.ts` 只剩薄适配层
  （转换原生事件、保存 Core 返回的状态、把 `triggered` 变成动作）。macOS 每次事件一次同步 FFI，body 约 100 字节，
  `keymap.*` 不进请求追踪；按键速度下可以接受。
- **LSP-16 编辑器分组成员状态**：`editor.workbenchState.reduce` 在 `lithe-core-rules` 里定义取两端并集的规范“组成员状态”
  （每组：有序去重的成员、选中项、MRU、固定、预览），动作为 normalize、open、close、activate、move、reorder、固定、预览和 mergeGroup，
  返回新状态和 `removedGroupIds`。macOS 把 `items`、`placements`、`groupSelections` 转成规范状态（MRU、固定、预览传空值），
  Windows 把每个 `PaneGroup` 转成规范组，两端旧规则已删除；布局树、拆分方向和比例仍在各自平台，只按 `removedGroupIds` 修剪。
  两端在“选中项离开分组”时的既有行为不同（macOS 回落到第一个标签，Windows 选中相邻标签），用请求里的 `selectionFallback`
  （`first` / `adjacent`）保留，不改用户可见行为。fixture 为 `shared/fixtures/editor/workbench-state-v1.json`。
- **WS-04 隐藏路径规则**（已迁移规则）：内置默认列表、glob 匹配和“目录名/文件”的区别只在
  `rust/lithe-core-rules/src/visibility.rs`。Core 的 `files.rs` 直接复用这份代码，不再有第二份；macOS 经
  `workspace.classifyVisibility`（按一批路径一次调用）和 `workspace.visibilityDefaults` 同步 FFI 调用，Windows 同样经 wasm。
  `LitheCoreContracts` 不链接 Rust bridge，所以只定义 `FileVisibilityEngine` 协议，由 App 里的
  `RustFileVisibilityEngine` 实现，按 ObjC 类名在首次使用时发现，使 App 和链接了 App 的测试宿主无需关心安装顺序。
  用户只保存自己的条目，内置规则由 Core 补上；`!` 条目关闭内置规则。结果里的 `watchedDespiteHiding` 表示
  `.lithe` 配置目录“树里隐藏、事件仍要监听”。Windows 文件树按目录批量分类，结果按“目录 + 规则版本”缓存。
  `workspace.classifyVisibility` 和 `workspace.visibilityDefaults` 不进请求追踪。
  共享 fixture：`shared/fixtures/workspace/visibility-v1.json`。

## 边界

只放**纯计算、体量小、处在同步热路径上**的规则。凡是涉及 I/O、进程、文件、网络、长耗时或大数据的逻辑，
仍放 `lithe-core` 并走异步 IPC。判断方法：如果 Windows 调用方可以 `await`，就不要放进这个 crate。
不要把它当成第二个 Core 来堆功能；wasm 体积会拖慢每次启动。

## 考虑过的备选方案

- **Windows pane store 全部改为异步**：`set()` 里不能 `await`，要重写所有读写 store 的组件并处理中间状态竞态，
  风险和范围远大于这几条规则，被否决。
- **TS 与 Swift 各留一份算法，靠共享 fixture 对照**：这是迁移前的做法。fixture 只能发现已写入的用例，
  新分支仍会漂移，且违反“可共享逻辑进 Core”的规则，被否决。
- **引入 wasm-bindgen**：需要额外工具链（wasm-bindgen-cli）、生成胶水 JS，版本需与依赖严格匹配；
  我们只需要 JSON 进 JSON 出，手写四个 C 函数更小、更可审计，被否决。

## 构建与 CI

- `scripts/windows/prepare/prepare-core-rules-wasm.mjs` 把 `lithe_core_rules.wasm` 编译（release，`opt-level="s"`、LTO、strip）
  并放到 `windows/tauri/public/core-rules/`。该目录被 `.gitignore` 忽略，**不提交**。
- 接入 Windows `dev`、`build`（`desktop:build` 的 beforeBuildCommand 经 `bun run build` 间接包含）、`ci-windows.yml`
  前端 job（安装 `wasm32-unknown-unknown` target 并构建）、`release-windows.yml`、`release-preview-windows.yml`。
  bun 测试辅助 `src/test-utils/core-rules.ts` 在产物缺失或旧于源码时调用同一个脚本重建。
- 工作树资源复用：产物没有可靠的 identity stamp，登记为不可复用的 `core-rules-wasm`，各工作树自行重建（几秒）。
- 运行时只读：wasm 是打包进前端资源的只读输入，运行时不写入，不影响代码签名和 Sparkle delta。
- 注释检查 `verify-rust-core-comments.sh`、rustfmt、日志检查和 Rust 单测已把新 crate 纳入覆盖范围。

## 后果

- 新增规则要在 `lithe-core-rules` 的 `COMMANDS` 和 `lithe-core` 的 `CoreCommand` 同时注册；
  `every_rules_crate_command_is_routed_by_core` 测试会拦截遗漏。
- Windows 本地开发需要 `rustup target add wasm32-unknown-unknown`；缺失时脚本给出明确提示。
- 当前 wasm 体积约 141 KB（release，未压缩）。

## 验证

- `cargo test -p lithe-core-rules` 与 `cargo test -p lithe-core --lib protocol`：同一份 fixture 经 JSON envelope 逐步驱动。
- `cargo build -p lithe-core-rules --target wasm32-unknown-unknown --release` 成功，且产物经 bun 测试真实加载。
- `bun` 测试 `double-shift-recognizer.test.ts` 与 `core-rules.test.ts` 通过 wasm 跑同一份
  `shared/fixtures/keymap/modifier-gesture-v1.json`；macOS `KeymapTerminalCoreFixtureTests` 通过真实 FFI 跑它。
- `bun run build` 产物中包含 `core-rules/lithe_core_rules.wasm`。真实 Windows WebView2 加载需在 Windows 机器上确认。

## 适用范围

适用于所有需要在 Windows 前端同步执行的纯规则。第二阶段计划迁入 LSP-16（pane 树规范化）和 WS-04（隐藏判断）。
