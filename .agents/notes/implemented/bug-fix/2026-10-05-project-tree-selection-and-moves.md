# Agent 笔记：项目树独立选择与批量移动

状态：已实现

## 先说结论

目录是一个独立选项，选择目录不会让它的后代一起高亮。目录名称负责选择，箭头或目录名称双击负责展开；上下方向键移动选择，左右方向键展开、折叠或进入显示子项、返回显示父项。拖动一个已选项时携带完整选择集合，移动目录时按整个目录处理，后代不再单独移动。可见行、选择修正和多选规则由 Rust Core 计算，界面层不再增加这类共享规则。

## 问题

目录后代继承高亮，看起来像全选，点击大目录还可能卡顿。原选择集合只包含目录，但显示层沿父路径判断选中。拖动只提供单个文件 URL，目录没有拖动入口，项目树也没有移动接收端。普通点击同时触发展开，递归的非懒加载视图会实例化全部已展开行，选择成本与展开成本必须分开。

## 决策

### 选择语义

- 选择和展开是两种动作：单击只选择，双击或点击箭头才展开或折叠。
- 行高亮和右键目标只使用明确的选择集合。修饰键点击增减单项，Shift 只在需要范围时读取可见行顺序。
- 上下方向键只选择可见行，不打开文件；选择变化后滚动到焦点项。
- 目录变化时的选择修正、可见行计算和多选（普通、修饰键、Shift 与批量目标）由 Core 的 `workspace.projectTree.rows` 和 `workspace.rowSelection.reduce` 完成（[#1800](https://github.com/1lck/Lithe-IDEA/issues/1800)）。

正确示例：同时选择 `src`、`src/A.java`、`README.md`，拖到 `archive`，实际只移动 `src` 与 `README.md`，后代随目录移动。不要将 `src/A.java` 再移动一次，也不要为了目录高亮去遍历或加载未展开的后代。

### 懒加载与视口

只为视口及少量相邻行创建控件。目录变化时重新测量可见树中最长名称，保证最长行尚未滚入视口时也能横向滚动。这一策略仍需遍历已加载且展开的行，不等于完整的增量虚拟树。

### 监听与重列

项目级递归原生监听与项目搜索共用，后台先由 Core 过滤隐藏路径，再只重列已加载的相关目录。事件队列有界；丢失事件或积压超限时重列已展开目录。同一目录的列出请求同一时刻最多一个在途，过期结果不发布。

重列复用仍存在的节点和已加载子树；选中的子节点消失时回退到最近仍存在的父目录；文件插在视口上方时按原可见行及像素偏移锚定。根目录不可用时释放失效监听并提供重试，关闭项目时释放共享监听。

Linux 的递归监听需要逐目录注册，暂时沿用按需目录监听，最多 128 个，超限时记录并提示，优先保留展开目录。

### 本地单项重命名和拖移

窗口可以提前提示重名，但不能用之前查到的空名额覆盖后来出现的条目。保存相关文档后，项目树在后台调用 Core 的 `workspace.renameEntry`，不再自行调用 `os.Rename`。Core 拒绝重名时提示「已有同名条目」，原标签页不动；只有成功后才迁移标签、目录标记和本地历史，再刷新项目树和 Git。只改大小写的合法重命名也由 Core 判定。

移动过程中关项目或退出时，让窗口继续响应，把关闭推迟到移动结果已处理、目录标记和本地历史的写入都已结束。不能只等磁盘上的改名：例如 `src` 已变成 `lib`，但标记还没落盘，此时取消项目任务会让重新打开的项目仍把 `src` 当成源码目录。树和 Git 的读取可以随项目取消，不需要为了退出等待所有后台任务。

若改名前正在核对磁盘内容的标签被淘汰，文档移除后要把未完成的检查按失败交还给每个等待者，且只通知一次。这样改名会在写盘前中止，关闭项目也不会等一个永远不会再收到的回执。

这个约束只覆盖本地重命名和拖移，不代表剪切粘贴或远程移动也走同一入口。对不支持排他改名的卷，Core 契约允许降级为先检查再移动，因此不能把此修复当作所有文件系统都支持原子改名的保证。

### 批量移动（设计要求，Viva 尚未实现）

拖动已选集合时，界面携带完整选择。工作区模块复用文件操作端口，后台预检整个集合，排除父子重复、根目录、同名目标、越界符号链接和移入自身或后代。当前目录中的项目保持原位。

未保存文档在历史记录前后检查，成功项立即更新打开文档，再迁移历史和目录标记。批量操作期间持有批量标志，工作区切换后停止后续项。中途失败不自动回滚已成功项，因为回滚可能覆盖期间发生的外部编辑；界面提示完成数量与剩余项。

## 考虑过的备选方案

- 仅修复高亮：无法补齐批量移动，不能满足完整操作链。
- 点击目录仍展开：把选择和大目录布局绑在同一次动作上，不采用。
- 完整替换为原生树控件：会扩大菜单、图标、定位和滚动的改动范围，本次保留现有行呈现。

## 后果

独立选择减少误解，目录移动不需要枚举磁盘后代，懒加载避免为屏幕外每行启动图标任务。代价是需要维护原生输入适配器，真实拖动和大目录性能仍需实机验收。

当前 Viva 只接入了目录单击选择、双击名称或点击箭头切换展开、方向键导航和选中项滚动到视口。多选、批量移动、右键菜单和实机交互验收仍待完成，不能用下文测试证明已迁移。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench -run '^TestProjectCloseWaitsForTreeMove$' -count=1`：分别暂停改名回执、历史迁移和目录标记写入，确认关闭不会提前完成；关闭后从存储检查标记、历史路径和快照内容。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run '^Test(EvictingTabDuringRenameCheckAllowsProjectClose|ProjectCloseVerifiesMovedTabAfterRenameReceipt)$'`：检查源标签被淘汰时改名中止且项目仍能关闭，以及保留打开的标签时会话记录的是新路径。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run '^TestProjectTree(HonorsCoreRenameRefusal|CaseOnlyRenameKeepsOpenTab|RenameOntoExistingFile|DragOntoExistingFile|DragIntoAvailableName)$' -count=1`：检查 Core 拒绝时文件和标签不动、已有重名提示、无冲突拖移和仅改大小写。
- `scripts/desktop/desktop-go.sh test -race ./internal/workbench -run TestProjectTree -count=3`：覆盖真实文件系统的新增、删除、空目录变化、视口锚定、过期结果、监听关闭和根目录重试。其中 `TestProjectTreeBatchSelectionFollowsCore` 覆盖批量选择与 Core 的一致性。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run '^$' -bench '^BenchmarkProjectTreeResize1000$' -benchmem -benchtime=1s -count=3`：固定 1,000 行并反复改变窗口宽度，只统计无头布局。
- 多选、拖动和真实 macOS / Windows 窗口行为仍需实现并验收。
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `desktop/internal/workbench/filetree.go`
- `desktop/internal/workbench/filetree_test.go`
- `desktop/internal/core/project_tree.go`
