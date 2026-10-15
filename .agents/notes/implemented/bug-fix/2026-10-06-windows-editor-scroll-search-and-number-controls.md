# Agent 笔记：Windows 编辑区滚动、当前文件搜索与数值控件

状态：已实现

## 先说结论

输入文件名时必须能找到当前正在编辑的文件；空搜索仍用于快速切换到其他文件。
Windows 普通编辑器与笔记本代码区采用和现有 Diff 一样的滚轮速度，用户的平滑滚动设置继续生效。
设置中的数字输入区与步进按钮分开，数字居中，按钮使用与控件高度一致的点击范围。

## 问题

快速打开的活动文件过滤原本用于空查询的文件切换，但有查询词时也继续排除活动文件。
例如正在编辑 `independent-commit-diff.ts` 时搜索 `independent-commit-diff`，底层文件列表包含它，结果却不显示。
本地搜索适配器实际返回完整文件列表；把它当后台索引轮询，再为每个查询扫描整个目录，会重复读取文件系统。
普通编辑器未配置滚轮灵敏度，与 Diff 的两倍速度不同。数值控件的固定紧凑宽度不足以同时容纳输入区与按钮。
实际 Windows 设置窗口由 `settings-dialog.tsx` 路由到 `settings-panels.tsx` 的 EditorPanel；
后者原本直接使用右对齐的原生数字输入框，修改旧设置页的共享控件不会影响这个入口。

## 决策

- 有查询词时把活动文件视为已打开文件参与匹配；不修改共享的空搜索快照语义。
  不在查询结果中再次排除活动路径，否则已知文件依然不可检索。
- 每次打开搜索框只获取一次完整列表，再复用现有模糊匹配与分类排序；重开重新加载，保证新建、删除文件可见。
  切换工作区、关闭搜索或卸载时拒绝迟到结果，不创建轮询计时器。
- Windows 滚轮速度常量由编辑器配置所有者提供，普通编辑器、笔记本和 Diff 共用。
  创建与更新 Monaco（编辑器组件）配置都应用它，由 Monaco 继续处理滚轮、边界和滚动设置；不增加另一套鼠标事件拦截。
- 数值控件仍复用 Base UI（数值输入交互库）的编辑、步进、上下限和键盘能力。
  数字居中并隐藏浏览器额外的原生小箭头；右侧独立按钮使用现有按钮系统，上方增大、下方减小，标准尺寸各为 32×32px。
  紧凑设置宽度为 160px，输入与按钮区间隔 8px，按钮之间间隔 4px；使用共享控件的设置行共用此布局。
  实际 EditorPanel 字号也必须接入这个控件，保留该页原有 10–22 范围与设置持久化。

IDEA 参考版本为 `fb72b4df43aba102479eb0502d20b03586b9c5b8`：
`platform/platform-impl/src/com/intellij/openapi/editor/impl/EditorScrollableIncrementProvider.kt`
以行高提供纵向单位，`platform/platform-api/src/com/intellij/ui/components/JBScrollBar.java`
结合滚轮数量与单位计算位移；`platform/lang-impl/src/com/intellij/ide/actions/GotoFileItemProvider.java`
使用文件名索引与匹配器，未将当前文件从文件名搜索中删除。
`platform/platform-impl/src/com/intellij/ide/ui/laf/darcula/ui/DarculaSpinnerUI.java`
为文本编辑区与按钮保留独立布局。Lithe 的两倍滚轮速度及完整按钮尺寸是产品选择，
不是 IDEA 固定倍数或原生步进器几何尺寸的复制。

## 考虑过的备选方案

保留逐查询扫描并仅改活动文件过滤，可以修复漏文件，但仍重复遍历目录且绕过已有模糊匹配。
把两个原生小箭头压进 32px 总高度会继续缩小命中范围；因此保留各自完整的点击区域。步进按钮最初竖排（上增下减），
横排后不再增加控件高度，故改为输入框右侧左增右减。
直接接管编辑器 wheel（滚轮）事件会重复实现 Monaco 的单位换算、修饰键和边界处理，故继续使用其公开配置。

## 后果

查询能找到活动文件，去掉连字符的文件名也能使用已有模糊匹配；目录读取次数减少。
输入区与步进按钮不再拥挤，标准按钮可完整点击。共用数字控件的其他设置行也采用新宽度。
一次打开期间使用同一份完整文件快照；外部新增或删除文件在重开后刷新。
快照不预先过滤，空查询切换列表才隐藏 `.gitignore`、`Cargo.lock` 等噪声文件，带词搜索仍可精确找到它们。两倍速度不等同于 IDEA 整体帧性能。

## 验证

- 搜索回归覆盖当前文件、空搜索、模糊匹配、重开刷新、工作区切换与迟到结果，以及非活动 `.gitignore` / `Cargo.lock` 的精确搜索。
  这些回归测试已登记到 Windows Frontend CI 的 quick-open / number-input 计时 lane。
- 数值交互覆盖受控值、步进、上下限、禁用和只读；通过实际 SettingsDialog 的 Editor 路由验证控件与设置持久化。
  浏览器探针还必须渲染真实 EditorPanel，检查连续增减、直接输入及 10–22 边界；独立控件检查不能替代页面入口验证。
  Diff 回归检查共用常量后滚轮行为保持。
- 浏览器组件探针检查真实输入居中、间距、按钮尺寸、手动输入及相同滚轮事件的位移。
  组件探针不等于完整 WebView2 应用与 IDEA 的帧性能对照。
- 运行 `.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`、
  `scripts/build-windows.ps1 -Configuration Release`、`scripts/verify-windows-boundaries.sh`、
  `scripts/verify-runtime-bundle-immutability.sh`、`scripts/verify-platform-feature-matrix.sh` 和 `scripts/verify-agent-notes.sh`。

## 适用范围

- `windows/tauri/src/features/quick-open/hooks`
- `windows/tauri/src/features/editor/config/constants.ts`
- `windows/tauri/src/features/editor/components/monaco-editor.tsx`
- `windows/tauri/src/features/editor/notebook/notebook-code-cell-editor.tsx`
- `windows/tauri/src/features/git/components/diff/independent-commit-diff-surface.ts`
- `windows/tauri/src/features/settings/components/settings-section.tsx`
- `windows/tauri/src/features/settings/components/settings-panels.tsx`
- `windows/tauri/src/features/settings/components/editor-settings-routing.test.tsx`
- `windows/tauri/src/ui/number-input.tsx`
