# Agent 笔记：中文组词期间隐藏输入框占位文字

状态：已实现

## 先说结论

输入法组词时，用户已经在输入框里看到文字，但应用绑定的文本可能仍为空。
共享单行输入框必须同时检查原生编辑器的可见文字，不能等按空格确认后才隐藏
占位文字。Commit 多行输入框同样在组词变化时重绘完整占位区域。

## 问题

`LitheSearchTextField` 通过 SwiftUI 覆盖层保持共享占位字号和颜色，仅检查
`text.isEmpty` 会把占位文字叠在未确认的拼音或中文上。该组件用于 Git Log、
Search 和 Database，逐个业务页面修补会留下相同问题的其他入口。

Commit 使用原生 `NSTextView`，输入法可能只标记组词字形的区域需要重画。
原来较长占位文字的尾部会残留，必须让整个占位区域重新绘制。

## 决策

共享单行组件保留 SwiftUI `TextField` 的编辑、焦点、提交和代理。原生背景
观察视图读取当前窗口的字段编辑器（AppKit 为单行输入框提供的 `NSTextView`），
只接收同一编辑器文本存储的变化，并以编辑器边界匹配当前输入框。已有文字
和未确认组词都隐藏占位文字；取消或删空后恢复。观察视图不写入业务绑定，
不把组词内容提前当作搜索或提交结果。

文本存储也可能在工作线程发布无关通知，观察入口先过滤线程，避免在后台读取
窗口。可见内容是否为空改变后，只通过弱引用在下一次主队列交付本地状态，
避免在原生视图更新过程中修改 SwiftUI 状态。视图移出窗口、卸载及释放时
移除通知观察；输入框之间及窗口之间不能互相改变占位状态。

Commit 编辑器在 `setMarkedText` 和 `unmarkText` 后标记完整视图需要绘制，
绘制占位文字还要求没有组词。后端、输入绑定的更新语义和模块动作保持原样。

共享字段使用已有 Find Bar 的 `onContinuousHover` 原生光标处理：可编辑字段悬停时立即显示 I-beam（文本编辑光标），离开或禁用时恢复箭头，不等字段成为第一响应者。占位覆盖层仍不接收点击，输入法观察视图仍不截获鼠标。

正确示例：原生编辑器显示 `ni`，绑定仍为空，此时已经隐藏占位文字。
错误示例：只在绑定变成 `你` 后隐藏占位文字，导致候选组词期间两层文字重叠。

## 考虑过的备选方案

- 每个模块单独修补：会遗漏其他共享字段，所以在共享组件处理。
- 替换整个原生单行编辑器：需要重新接入现有焦点和提交路径；本次只需要
  观察可见文本，不替换 SwiftUI 已有的编辑器。
- 只在焦点进入时隐藏占位：空输入框聚焦仍应显示占位，所以不能采用。

## 后果

组词、确认、取消及删除使用同一占位规则。单行组件增加窗口内原生文本通知
观察，但空值状态未变化时不发布更新。原有样式、边框和字号不变。

## 验证

运行以下原生编辑器回归，覆盖明暗主题、空绑定下的组词、取消及确认、两个
字段互不影响，以及 Commit 旧占位尾部的完整失效区域。功能截图与空白背景
比较，避免窗口使用的显示器颜色配置改变占位存在性的判断；原有字号与颜色
检查单独保留。原生组词事件不等同于真实输入法候选窗口的人工验收。

```bash
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'LitheSearchFieldStyleTests|CommitMessageEditorTests'
./scripts/verify-runtime-bundle-immutability.sh
./scripts/verify-agent-notes.sh
```

## 适用范围

- `macos/Sources/Lithe/Theme/LitheTheme.swift`
- `macos/Sources/Lithe/Views/Git/CommitMessageEditor.swift`
- `macos/Tests/LitheTests/LitheSearchFieldStyleTests.swift`
- `macos/Tests/LitheTests/CommitMessageEditorTests.swift`
