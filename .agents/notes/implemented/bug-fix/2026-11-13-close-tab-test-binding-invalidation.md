# Agent 笔记：关闭标签测试的快捷键变更必须请求刷新

状态：已实现

## 先说结论

无头测试直接修改快捷键时，也要像真实设置页一样通知界面刷新。否则输入仍使用上一帧的绑定，后台任务偶然产生的刷新会掩盖问题。关闭标签测试现在明确请求刷新，并在所有平台验证用户新增的绑定，避免 macOS 默认键位掩盖测试缺口。

## 问题

[#1885](https://github.com/1lck/Lithe-IDEA/issues/1885) 来自 Linux CI：添加 Control-W 后日志页签仍然打开。`6268d92923` 引入的测试只改内存设置，没有真实设置页 `SetKeymap` 的刷新通知；测试驱动的 `Pump` 只在已有唤醒标记时绘制，不保证每次调用都重画。

macOS 原测试直接使用初始注册的 Command-W，因此无法覆盖同一缺陷。在 macOS 显式新增 Control-W 的独立探针及正式回归都复现相同失败，排除了 Java 插件的影响。

## 决策

测试的绑定辅助函数在更新后调用现有刷新接口，下一次输入前由驱动处理刷新；不修改产品逻辑或框架行为。新增跨平台用户绑定回归，先消费已有帧，再修改绑定并立即触发，防止无关后台唤醒提供偶然的刷新。

正确做法是“更新测试设置、明确请求刷新、发送按键”。不要只更新字段后靠下一次后台活动、延长等待或重复运行获取绿灯。

## 考虑过的备选方案

- 每次 Pump 都强制绘制：改变成熟框架的按需绘制语义，掩盖测试与真实设置路径的差异。
- 加 sleep 或重试按键：依赖后台时序，还可能重复关闭其他标签。
- 只跑 macOS 默认键位：遗漏用户自定义绑定及其他平台。

## 后果

测试不再依赖偶然刷新；新增少量测试辅助代码和一项跨平台回归。产品运行时、默认快捷键、资源、性能与插件契约均不改变。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench -run '^TestCloseTabUserBindingClosesTheSelectedEditorTab$' -count=1`：未请求刷新时失败，日志页签仍为 1；修复后通过。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run '^TestCloseTab' -count=1` 与相同范围的 `-race`。
- `./scripts/agent-notes/verify-agent-notes.sh` 与测试稳定性静态检查。
- Linux、Windows 的目标平台结果以配套 PR 的 CI 为准，本地 macOS 回归不能代替它们。

## 适用范围

- `desktop/internal/workbench/close_tab_shortcut_test.go`
- `desktop/internal/workbench/settings.go` 的真实设置变更刷新顺序。
