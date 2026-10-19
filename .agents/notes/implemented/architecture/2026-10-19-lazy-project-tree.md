# Agent 笔记：macOS 项目树按需列目录

状态：已实现

## 先说结论

#1245 中，工作区文件很多时，macOS 侧栏会占用大量内存并卡顿。原因是每次扫描都把整个工作区构建成一棵完整的树。
现在，扫描（`workspace.snapshot`）只返回平铺的文件清单，不再返回树。项目树的目录行一开始是“未加载”状态，
只有用户展开时才通过 `workspace.listDirectories` 列出下一层，和 IDEA 的做法一致。
开发者以后要记住两点：`FileNode.children == nil` 的目录表示“还没列过”，不是“空目录”；
项目树相关的查找和编辑要处理“路径在未加载行下面”这种情况。

## 问题

- 原来每次快照都把工作区的完整树序列化后交给 Swift，节点数与文件数相同。
  主仓库在排除嵌套工作树后仍有约 6.5k 个文件，快照 JSON 约 1.37 MB。
  如果存在嵌套工作树或 `.artifacts`，会膨胀到十几万个文件、42 MB。
- 但是用户通常只展开很少几层目录，绝大多数节点从来不会被显示。
- Compact Middle Packages（把源码根下只含一个子目录的包合并显示成 `a.b.c` 一行）
  需要预先知道下一层的内容，所以不能简单地“只列当前层”。

## 决策

- 由 Rust Core 负责列目录。`workspace.snapshot` 接受 `includeTree: false`，这时只返回 `files`
  和一个没有子项的 `root`。Windows 不传这个字段，行为不变。
- `workspace.listDirectories` 一次可以列出多个相对路径的下一层。它与快照使用同一套过滤规则：
  隐藏目录、隐藏文件、符号链接、嵌套工作树。
  不存在、被隐藏或越过根目录的路径直接不返回，调用方不需要区分具体是哪种原因。
- `ProjectTreeLoader`（`macos/Sources/Lithe/Models/Workspace/`）把列表结果转换成树行。
  如果某行在源码根之下，它会继续按批次往下列，直到单子目录链结束，最多 64 层。
  这样生成的压缩包行与原来全树转换的结果完全一致。
- `WorkspaceFeatureModel` 持有已加载的目录集合：
  - 重新扫描时，会按批次重新列出这些目录，所以展开状态不会因为文件变化而丢失。
  - 用户展开目录时，侧栏调用 `loadExpandedDirectories`。
  - 定位文件（reveal）时，先加载祖先目录，再滚动。
- 增量更新通过 `FileNode.TreeEdit` 表达：
  - 改动落在未加载行下面时，返回 `.unchanged`，下次展开时自然会列到。
  - 改动可能影响压缩包布局时，返回 `.reload`，重新列出已加载的目录。
  - 其它情况返回 `.updated`，原地改树。

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
- 不要为了“预加载更流畅”而在扫描时把整棵树一起带回来。这会恢复 #1245 的内存占用。
  需要预取时，只多列可见的下一层。

## 考虑过的备选方案

### 继续发送全树，只在 Swift 侧做压缩或去重

这个方案改动最小。但是 JSON 解码和节点分配的成本仍然与文件数成正比，侧栏任何一次重新扫描都会全部付一遍，
所以没有采用。

### 在 Swift 侧用 FileManager 直接列目录

这样可以省去一次跨语言调用。但是这会让隐藏规则和嵌套工作树检测在 Rust 与 Swift 中各维护一份，
Windows 以后也没法复用。因此生产路径走 Rust，Swift 版本只作为 Rust 不可用时的回退，
并且与 Rust 使用相同的过滤顺序。

## 后果

- 收益：在主仓库上测量，快照 JSON 从 1,375,935 字节降到 435,740 字节，快照耗时从 123 ms 降到 74 ms，
  列出根目录约 0.3 ms。
- 代价：展开一个新目录需要一次异步调用。源码根下的深层单子目录链需要多轮列目录。
- 仍未解决的部分：`projectFiles`（平铺的 `[URL]`）仍然完整驻留内存，有约 20 处消费者。
  所以 Swift 侧的内存收益主要来自树节点。如果大仓库的内存仍然明显偏高，应该优先把它换成更轻量的索引。

## 验证

- `cd rust && cargo test -p lithe-core project`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'LitheCoreLogicTests'`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-agent-notes.sh`

## 适用范围

- `rust/lithe-core/src/project/files.rs`
- `macos/Sources/Lithe/Models/Workspace/ProjectTreeLoader.swift`
- `macos/Sources/LitheCoreContracts/Workspace/FileNodePathLookup.swift`
- `macos/Sources/LitheWorkspaceModule/`
