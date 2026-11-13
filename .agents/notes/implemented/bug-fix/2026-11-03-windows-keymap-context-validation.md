# Agent 笔记：快捷键条件由 Core 编译，Windows 按键时只查结果

状态：已实现

## 先说结论

Windows 不再解析快捷键的 `when` 条件。Rust Core 检查完整表达式，并提前计算各个
布尔上下文组合是否匹配；Windows 在按键时只根据焦点等原生状态查结果。
导入和保存必须先通过校验，已有配置里的非法条件保持不生效，不能拖死键盘事件。

## 问题

旧 tokenizer（把表达式切成词的代码）遇到 `@`、单个 `&` 等字符时既不推进位置也不
返回错误。旧解析器还忽略尾部输入和未闭合结构，甚至没有真正实现已经声明支持的
相等运算。仅补一个递增分支不能解决语法误判，也会继续把规则留在 Windows。

键盘事件又需要同步决定是否取消浏览器默认行为。如果每次按键都异步询问 Core，
收到结果时已经无法阻止原生复制、输入或菜单动作，容易产生重复操作。

## 决策

Core 接受有界的条件源码，检查字符、引号、括号、操作数和完整消费，并返回稳定的
语法错误码。错误位置以原始文本的 UTF-8 字节计数，不冒充编辑器的 UTF-16 位置。
运算规则和上下文组合的结果全部在 Core 计算，具体兼容面见共享 API 文档和 fixture。

因为现有 Windows 上下文值都是布尔值，Core 可以生成完整真值表，即每一种真假组合
对应的最终匹配结果。Windows 只把自己的布尔状态转换成数组下标，不持有语法树，
也不解释运算符。正确示例是先编译 `editorFocus && !vimMode`，按键时查询 Core
计算的那一格；不要在事件处理里重新分词，或者临时发送 IPC（跨进程调用）后才取消事件。

源码最多 4096 字节、128 个词、32 层括号或取反、12 个不同上下文键，结果最多 4096 格。
这是现有布尔上下文的有界编译方案，不是完整的 VS Code 条件语言。
Windows 每个窗口最多缓存 256 条条件，最多同时保留 16 个原生编译请求；没有后台轮询。
绑定和预设变化时刷新，旧任务在后续请求前检查取消，窗口键盘所有者销毁时释放缓存和订阅。

导入先在独立的有界暂存中验证全部条件，成功且缓存容量仍足够时才一起发布，
失败不占用生效缓存；新增、修改绑定在持久化前验证。
验证期间发生其他编辑或重置时拒绝提交旧快照，不能用旧结果复活已重置的绑定。
默认、扩展和旧持久化绑定在编译完成前保持不生效；失败只在配置准备路径记录诊断，
按键路径不解析、不发请求，也不会因为一条坏条件而卡死。

## 考虑过的备选方案

- 只在 TypeScript 的未知字符分支报错：可以解除单个死循环，但保留了平台私有语法。
- Core 返回语法树，再用 TypeScript 解释：仍然需要维护第二套相等、优先级和真假规则。
- 每次按键异步调用 Core：无法同步阻止浏览器默认行为，并给高频按键增加进程通信。
- 新增 WebAssembly 编译产物：可以同步执行 Rust，但引入新的构建和打包资源；当前有界
  布尔表已经能完整表达已有上下文，因此本次不增加运行时和资源链路。

## 后果

非法导入不会覆盖现有绑定，坏的历史条件也不会进入求值循环。正常的上下文变化无需
重新编译，条件表在代码和配置更新之后才刷新。代价是组合数量随键数量增长，因此
必须同时保留 Core 的键数上限和窗口缓存上限；未就绪或超预算的绑定不能被当成无条件绑定。
本次不改 macOS 的类型化快捷键，也不扩展数字、正则或字符串类型的原生上下文。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`
- `cargo test --manifest-path rust/lithe-core/Cargo.toml --lib context_`
- `node scripts/i18n/generate-i18n.mjs --check`
- `node scripts/agent-notes/verify-agent-notes.mjs`

共享 fixture 覆盖非法字符、不闭合引号/括号、缺少操作数、尾部垃圾、优先级、严格比较、
中文和 emoji，以及长度、层数和键数上限。显式设置 `LITHE_CORE_TEST_LIBRARY` 可通过
本次构建的动态库检查 Core JSON C ABI、导入拒绝和 Windows 同步查询使用相同结果。
事件集成测试检查坏历史条件之后的按键仍能返回和执行，真实 WebView2/整机验收另行记录。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/keymap/mod.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/keymap/mod.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/keymap/context-v1.json`
- ~~`windows/tauri/src/features/keymaps/utils/context.ts`~~（已随 #1794 移除）
- ~~`windows/tauri/src/features/keymaps/utils/keybinding-import-export.ts`~~（已随 #1794 移除）
- ~~`windows/tauri/src/features/keymaps/stores/keymaps.store.ts`~~（已随 #1794 移除）
- ~~`windows/tauri/src/features/keymaps/hooks/use-keymaps.ts`~~（已随 #1794 移除）
