# Agent 笔记：跳转到行时保留列号与整行选择

状态：已实现

## 先说结论

“跳转到行”接受行号或“行号:列号”。输入格式及是否选中整行由 Core 统一决定，
两端只负责按当前文档定位和选择。原来的 Windows 实现把 `120:35` 当作 120 行，
也会把 `12abc` 当作 12 行，导致用户跳到错误位置。

## 问题

两端原先分别解释输入，Windows 只读取开头的整数，而 macOS 识别可选列号并拒绝
尾随字符。相同输入因此可能跳到不同位置，Windows 还丢失了整行选择的意图。

## 决策

Core 返回零基行、UTF-16 列和整行选择标记。只输入行号时选中该行内容，
不包含换行符；输入列号时把光标放到指定列。平台按照当前文档边界收敛位置，
不要在输入解析里复制文档内容。无效输入不跳转；传输前限制超长输入，避免
粘贴巨大文本时反复跨边界传输。

macOS 的对话框把短文本校验放到后台，合并短时间内的输入，输入变化后取消上一个校验并丢弃迟到结果；
只有当前文本验证成功才允许确认。用户在校验期间按 Return 时，等待当前结果再确认，
继续修改文本会撤销待确认操作。Windows 在确认后请求同一 Core 解析，校验期间切换
工作区或文档时丢弃结果；编辑器尚未挂载时的有限重试由视图持有，并在新目标或卸载时取消。
不能在 React 或 Swift 再用 `parseInt`、正则或私有解析器猜测结果。

## 考虑过的备选方案

- 只修正 Windows 的整数解析：两端仍有独立规则，之后可能再次出现不一致。
- 每次按键在主线程同步调用 Core：会把跨边界请求放进输入路径，故采用可取消的后台校验。

## 后果

两端共享输入解释，原生编辑器继续拥有实时文档边界与选择。校验在后台完成前，
macOS 确认按钮暂不可用；已过期的校验结果不会覆盖新输入。

## 验证

- `shared/fixtures/editor/navigation-input-v1.json` 覆盖行列、空格、零、负数、
  尾随字符和溢出；Core 与 Windows 命令回归消费同一 fixture。
- `GoToLineInputTests` 和 `GoToLineDialogValidationTests` 覆盖原生桥接、迟到结果和
  原生模态循环；Windows 的导航命令和行选择测试覆盖列号、CRLF 与 UTF-16 列。
- 在两端真实编辑器中分别输入 `120`、`120:35`、`12abc` 并快速修改输入，确认
  选择、光标和无效输入行为；真实平台工作流验收仍待完成。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/editor/navigation_input.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/editor/navigation_input.rs)
- ~~`macos/Sources/Lithe/Models/Editor/GoToLineInput.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Views/Editor/GoToLineDialog.swift`~~（已随 #1794 移除）
- ~~`windows/tauri/src/features/keymaps/commands/navigation-command-actions.ts`~~（已随 #1794 移除）
- ~~`windows/tauri/src/features/editor/components/code-editor.tsx`~~（已随 #1794 移除）
