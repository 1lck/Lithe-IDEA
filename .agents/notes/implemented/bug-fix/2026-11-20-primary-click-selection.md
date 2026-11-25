# Agent 笔记：主修饰键追加选择保留原行并显示全部选中项

状态：已实现

## 先说结论

在项目文件树和 Git 分支列表中，先普通点击 A，再按 macOS Command 或 Windows Control 点击 B，A 和 B 都保留选中；再次修饰键点击某行只取消该行。Core 统一维护选择规则，界面显示所有已选行，指针移入的焦点不能提前覆盖原选择。

## 问题

Core 的第一次 toggle（增减一行选择）只把点击目标加入标记，丢掉普通点击已经选中的行。文件树的行描述只把当前行设为选中，没有呈现批量标记。指针按下带来的焦点又会在处理带修饰键的点击前更新当前行，导致即使 Core 修正，原行仍可能丢失。

相关代码源于 Viva 迁移提交 `0faecba491`（宿主 #1799）及 Core 选择规则提交 `62b8a08`（Core #31）；这与旧客户端的 #1050 不同，当前问题可在共享 Viva 无头鼠标流程中复现。

## 决策

- 没有批量标记和范围锚点时，Core 先把可见的、非根的当前行纳入，再切换点击行。已有批量继续只切换一行；隐藏旧行不因首次点击被意外加入。
- 文件树与 Git 分支列表有批量状态时只用批量标记呈现选中底色；取消选中的当前行不继续显示为已选。
- 文件树记录已观察的焦点，指针焦点先交给点击处理，键盘焦点仍更新当前行。窗口失焦和恢复不清除批量。焦点清空时只记录焦点变化，行匹配要求焦点 ID 非空。目录列表刚加入的行在首次绘制前也使用空 ID，两者相等会把原选中项误移到新行。
- 引用和问题树复用 `treelist.FocusedRow` 匹配 Viva 行身份，只在非空焦点命中已声明行时更新选择。焦点清空仍写入已观察状态，因此重新聚焦同一行能够响应；工具栏定位保留原来的滚动和预览行为。这个适配只解释 Viva 的焦点 ID，不改变 Core 的结果排序或业务选择规则。
- macOS Command 和 Windows Control 由 Viva 已有的主修饰键定义提供，不新增系统按键适配。

## 考虑过的备选方案

- 只补选中底色：原始选择仍丢失，批量操作目标继续不符合预期。
- 在每个界面各自补回旧选中项：会让文件树、Git 列表与其他 Core 消费者产生不同规则。
- 把任何焦点都直接当作选中：指针按下会先替换旧行，无法正确追加选择。

## 后果

追加多选符合平台习惯，取消选择可见，Core fixture 约束所有消费者。代价是 Core 与宿主需要同步升级，并保留一个局部焦点身份以区分指针和键盘变化。

## 验证

- Core 共享 row-selection fixture 修改后先红后绿，覆盖首次追加保留、点击当前行取消、隐藏标记、范围选择和根保护。
- `desktop/internal/workbench/filetree_test.go` 的真实驱动点击先复现旧选择丢失，修复后覆盖追加、取消、全部选中底色、普通点击清除及键盘焦点回归。
- `TestProjectTreeKeepsSelectionWhenFocusClearsBeforeNewRowsPaint` 控制焦点清空与目录行首次绘制的顺序，修复前选中新增行，修复后保留原选中行。`TestProjectTreeLocateGivesUpOnAFileThatIsGone` 覆盖删除活跃文件后定位的完整流程，`TestVisualProjectTreeMissingFile` 采集明暗主题的结果。
- `desktop/internal/workbench/result_tree_focus_test.go` 用真实 Viva Tree 定序控制引用和问题结果刷新、清空焦点、重新聚焦及方向键。新行在第一次绘制前没有行 ID，旧实现会误选它；修复后保留原行，失焦时定位不抢键盘，回到原焦点后继续更新选择。`references_visual_test.go` 与 `problems_visual_test.go` 在未声明行时清空焦点，再采集保留选择及预览的中英文明暗主题截图。
- `desktop/internal/workbench/branch_delete_test.go` 混合批量从普通点击开始，再用平台主修饰键追加，验证实际删除集合。
- 通过 `scripts/desktop/desktop-go.sh` 执行定向无头测试，`desktop/internal/workbench/branch_delete_visual_test.go` 生成中英文明暗主题的文件树多选截图。Windows 原生交互验证仍待目标平台执行。

## 适用范围

- `desktop/internal/workbench/filetree.go`
- `desktop/internal/workbench/filetree_view.go`
- `desktop/internal/workbench/gitlog_view.go`
- `desktop/internal/treelist/treelist.go`
- `desktop/internal/workbench/references_view.go` 与 `desktop/internal/workbench/problems_view.go`
- 外部 Lithe-core-rust 的 `rust/crates/row-selection/src/lib.rs` 与共享 fixture。
