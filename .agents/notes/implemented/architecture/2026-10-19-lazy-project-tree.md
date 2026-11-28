# Agent 笔记：项目树按需列目录

状态：已实现

## 先说结论

#1245 中，工作区文件很多时，侧栏会占用大量内存并卡顿。原因是每次扫描都把整个工作区构建成一棵完整的树。
现在，扫描（`workspace.snapshot`）只返回平铺的文件清单，不再返回树。项目树的目录行一开始是“未加载”状态，
只有用户展开时才通过 `workspace.listDirectories` 列出下一层，和 IDEA 的做法一致。
开发者以后要记住两点：未加载的目录（还没列过）不是空目录；
项目树相关的查找和编辑要处理“路径在未加载行下面”这种情况。

### Viva 迁移中的项目树

Viva 客户端在已加载根目录后将根节点作为第 0 层行显示，包括空项目；根节点可选择、
折叠并用键盘重新展开。子节点从第 1 层开始，目录变化触发异步重列时按含根节点的可见行
恢复滚动锚点。界面的 24pt 行高、19pt 层级缩进、17pt 展开槽、16pt 图标、12pt 水平留白、
13pt 文字及圆角选中背景参照迁移前原生实现；展开箭头直接使用原版 IDEA SVG。
这只覆盖了上述树行和基础交互，不能据此认为包压缩、多选、批量移动、完整菜单或逐像素视觉对照已完成。
原生窗口失焦时 Viva 的焦点接口目前只提供控件焦点，选中态的窗口失焦表现仍需实机确认。

### 哪些行显示、选中谁，由 Core 决定（#1800）

项目树“显示哪些行”和“选中、标记哪些行”是所有客户端都要一致的规则，所以放在 Rust Core，
界面只负责列目录的结果、哪些目录打开、焦点、滚动和绘制：

- `workspace.projectTree.rows`（Core crate `lithe-project-tree`）：树的形状变化后
  （目录打开或关闭、列表返回、节点消失），界面把已加载节点按先序连同层级和是否打开发给 Core，
  Core 返回要显示的行、修正后的选择，以及变化前视口顶端那一行现在的位置。
  选中的节点消失时，选择交给仍加载的最近上级目录；被关闭的目录挡住时，交给它上方最近的可见行。
  被关闭目录里的标记保留，消失节点的标记和锚点丢弃。
- `workspace.rowSelection.reduce`（Core crate `lithe-row-selection`）：一次点击怎样改选择。
  普通点击选中一行并清掉标记；Cmd/Ctrl 点击切换一行的标记并把它设为锚点（Shift 扩选的起点）；
  Shift 点击标记锚点（没有锚点时从选中行）到点击行之间的所有行。根节点永远不会被标记。
  批量操作的目标是标记行去掉已被标记目录包含的那些。Commit 窗口的改动行使用同一个归约。

开发者要记住：

- 只在树的形状变化后调用一次 `workspace.projectTree.rows`（Go 侧设置 `rowsDirty`，
  下一次绘制或列表返回时刷新），不要每帧发送整棵树。缩放窗口、滚动和重绘不调用 Core。
- 不要在 Go 里自己算可见行、扩选范围或“选择移到哪里”。需要新的选择语义时改 Core 的
  fixture（`rust/fixtures/workspace/row-selection-v1.json`、`project-tree-rows-v1.json`）和 crate。
- 方向键在行之间移动焦点由 Viva 的 `ui.Tree` 组件负责，选中行跟随焦点；这是通用控件行为，
  不是项目树专有规则。
- Collapse All 把选中行藏起来时，界面把键盘焦点交给新选中的行；外部文件变化
  （例如选中的文件被删除）移动选择时只改选中行，不抢键盘焦点。

## 问题

- 原来每次快照都把工作区的完整树序列化后交给界面，节点数与文件数相同。
  主仓库在排除嵌套工作树后仍有约 6.5k 个文件，快照 JSON 约 1.37 MB。
  如果存在嵌套工作树或 `.artifacts`，会膨胀到十几万个文件、42 MB。
- 但是用户通常只展开很少几层目录，绝大多数节点从来不会被显示。
- Compact Middle Packages（把源码根下只含一个子目录的包合并显示成 `a.b.c` 一行）
  需要预先知道下一层的内容，所以不能简单地“只列当前层”。

## 决策

- 由 Rust Core 负责列目录。`workspace.snapshot` 接受 `includeTree: false`，这时只返回 `files`
  和一个没有子项的 `root`。
- `workspace.listDirectories` 一次可以列出多个相对路径的下一层。它与快照使用同一套过滤规则：
  隐藏目录、隐藏文件、符号链接、嵌套工作树。
  不存在、被隐藏或越过根目录的路径直接不返回，调用方不需要区分具体是哪种原因。

### 正确做法

- 判断一个文件是否属于项目时，始终查询平铺清单 `projectFiles`。目录展开和文件监听事件可能观察到不同版本的磁盘：
  例如先展开后收到新增事件时，树里已经有文件，但库存仍需要补入；删除事件同理。
- 增量事件先同步发布文件清单，再异步重列可能变化的压缩包目录。重列只更新树，保留当前库存和快照标识；
  等待期间若其它事件或目录展开推进了状态，就按最新树重试。不能把等待前捕获的文件数组写回，
  也不能因为后续事件取消了防抖任务就丢掉已经提交的目录布局变化。
- 新增需要遍历树的功能时，明确说明它只看已加载的行（`fileURLs`、`loadedDirectoryRows`），
  还是需要全部文件（这种情况应该使用 `projectFiles`）。

### 不要这样做

- 不要把 `children == nil` 的目录当成空目录。这样会让未展开的目录显示成没有内容，
  文件变化也会被当作新增目录，从而反复触发全量扫描。
- 同名替换空目录时，事件可能只带目录名。除刷新父目录外，还要让这个目录恢复可点击；已有读取则作废旧结果。
  监听重连时也要检查折叠分支内的缓存，但不能为确认空态去扫描这些分支。例如 `outer/inner` 在断线期间新增了文件，
  用户再次打开 `outer` 后必须能点击 `inner`。远端监听完整时，同级文件变更不应让正常的空目录反复出现箭头。
- 不要为了“预加载更流畅”而在扫描时把整棵树一起带回来。这会恢复 #1245 的内存占用。
  需要预取时，只多列可见的下一层。
- 正确示例：展开 `java` 时为压缩包名读到 `com/example` 的列表，接着展开该包时消费它；
  若期间收到该目录下的新增事件，则必须重新读取。不要让事件前的任务在事件后恢复旧缓存。

## 考虑过的备选方案

## 后果

- 收益：在主仓库上测量，快照 JSON 从 1,375,935 字节降到 435,740 字节，快照耗时从 123 ms 降到 74 ms，
  列出根目录约 0.3 ms。
- 代价：展开一个新目录需要一次异步调用。源码根下的深层单子目录链需要多轮列目录。
- 展开优化减少包压缩后的重复读取和并发请求，并以有界内存换取短期复用。
  超过缓存上限或发生文件事件时仍需读取磁盘；完整应用的交互耗时应通过实际项目采样验证。

## 验证

- `./scripts/desktop/desktop-go.sh test -race ./internal/workbench -run TestProjectTree`：项目树回归。
- `./scripts/desktop/desktop-go.sh test ./internal/workbench -run 'TestProjectTreeBatchSelectionFollowsCore|TestChangeListRowSelectionFollowsCore'`：选择归约与改动行多选。
- 在 Core 仓库运行 `cargo test -p lithe-core -- project_tree row_selection`：规则与 fixture。
- `./scripts/desktop/desktop-go.sh test ./internal/workbench -run '^$' -bench BenchmarkProjectTreeResize1000 -benchmem`：1000 行项目树缩放耗时（#1800 前后同机约 397µs/op 与 394µs/op）。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`。
- `./scripts/agent-notes/verify-agent-notes.sh`。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/files.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/files.rs)
- Lithe-core-rust：`rust/crates/project-tree/`、`rust/crates/row-selection/`
- `desktop/internal/core/project_tree.go`
- `desktop/internal/workbench/filetree.go`
- `desktop/internal/workbench/filetree_rows.go`
- `desktop/internal/workbench/changelists_select.go`
- `desktop/internal/workbench/filetree_watch.go`
- `desktop/internal/workbench/filetree_test.go`
