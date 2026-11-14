# Agent 笔记：跳转到行时保留列号与整行选择

状态：已实现

## 先说结论

“跳转到行”接受行号或“行号:列号”。输入格式及是否选中整行由 Core 统一决定，宿主只负责按当前文档定位和选择。曾经的宿主实现只读取开头的整数，因此 `120:35` 被当成 120 行，`12abc` 被当成 12 行，导致用户跳到错误位置。

## 问题

宿主如果自行解释输入，不同入口会对同一输入给出不同结果：有的只读开头的整数，有的识别可选列号并拒绝尾随字符。整行选择的意图也会在这个过程中丢失。

## 决策

- **解析由 Core 完成。** `editor.parseNavigationInput`（`desktop/internal/core/navigation.go` 的 `ParseNavigationInput`）返回零基行、UTF-16 列和整行选择标记。只输入行号时选中该行内容，不包含换行符；输入列号时把光标放到指定列。
- **边界由宿主收敛。** 平台按照当前文档边界收敛位置，不在输入解析里复制文档内容。
- **无效输入不跳转。** 解析失败时保持当前位置。
- **传输前限制长度。** 超长输入在发送前截断拒绝，避免粘贴巨大文本时反复跨进程传输。

不要在界面层用正则、整数解析或私有解析器猜测结果。

## 考虑过的备选方案

- **只修宿主的整数解析**：两处规则仍会分歧，之后可能再次出现不一致。
- **每次按键都同步调用 Core**：会把跨进程请求放进输入路径；需要时由输入完成后的一次解析完成。

## 后果

输入解释只有一份，编辑器继续拥有实时文档边界与选择。

## 验证

- Core 仓库的 [`navigation-input-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/editor/navigation-input-v1.json) 覆盖行列、空格、零、负数、尾随字符和溢出。
- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/workbench/...`：宿主侧的跳转与行选择。
- 在真实编辑器中输入 `120`、`120:35`、`12abc` 并快速修改输入，确认选择、光标和无效输入行为。

## 适用范围

- `desktop/internal/core/navigation.go`
- Core 仓库的编辑器导航输入实现（rust/lithe-core/src/editor/navigation_input.rs），以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
