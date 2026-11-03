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
  和一个没有子项的 `root`。Windows 起初不传这个字段；后来 Windows 的文件清单调用方（`fffListFiles`、Lombok 导航）也改为传 `includeTree: false`，因为它们只用 `files`，Windows 文件树自己按目录读取，从不使用快照里的树（见 `2026-10-29-skip-python-environments-in-workspace-scans.md`）。
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

### 展开请求和包压缩的临时列表

包压缩为了判断 `com.example` 是否还能合并，已经读过末端目录的内容。此前这些内容被丢弃，
用户再展开这一行时又读取一次。现在 `RustWorkspaceOperations` 持有只在内存中的临时列表，
下一次加载消费该列表，不把它当成已展开的树，也不提前构造更多后代。
最多保留 128 个目录、合计 4096 个子项；单个列表超过上限时不缓存，容量不足时清空旧提示。
这是有意采用的简单上限，只有实际采样发现频繁淘汰影响性能时才改成按使用顺序淘汰。

缓存身份包含工作区和可见性规则。`WorkspaceFeatureModel` 在收到文件事件时立即失效，
不能等到防抖批次处理后才失效；重新扫描、修改过滤规则、切换或关闭工作区也会清理。
旧读取任务持有的代次不能重新写入缓存。缓存随工作区操作对象销毁释放，不写入磁盘、
app bundle 或插件包，不影响代码签名和 Sparkle 增量更新，也不属于可跨工作树复用的资源。

普通展开和定位文件共用模型持有的目录加载任务。同一批缺失目录保持批量读取，
每个目录只登记一个在途任务；取消一个等待者不能取消其他等待者需要的工作。
目录事件改变读取代次后，仍然有效的调用者按最新状态重试，切换工作区或关闭时取消后台任务。
发布结果前同时检查工作区代次、读取代次和当前行是否仍未加载。
侧栏同一次视图计算复用可见行和路径；保留 `LazyVStack` 的渲染方式。
树区域通过 `ProjectSidebarTree` 的值输入与相等检查隔离全局 `AppModel` 通知，
不要在这个区域重新声明 `@EnvironmentObject AppModel`，否则无关通知仍会绕过输入比较触发树计算。
相等检查必须覆盖树、行高、活动文件、Git 状态、目录标记、定位请求和完整树交互状态。
交互状态仍由侧栏持有，切到 Dependencies 再回来不能丢失展开和选择。

参考 IDEA Community `4b7301e1ae43acd14528f1d86b8b7ffaf3bba4d3`：
[`AsyncTreeModel`](https://github.com/JetBrains/intellij-community/blob/4b7301e1ae43acd14528f1d86b8b7ffaf3bba4d3/platform/ui.tree/src/com/intellij/ui/tree/AsyncTreeModel.java)
使用节点请求队列、后台计算和过期检查；
[`VirtualDirectoryImpl`](https://github.com/JetBrains/intellij-community/blob/4b7301e1ae43acd14528f1d86b8b7ffaf3bba4d3/platform/vfs-impl/src/com/intellij/openapi/vfs/newvfs/impl/VirtualDirectoryImpl.java)
复用已经加载的子项。Lithe 只复用这里适合已有架构的请求与缓存原则，不另建完整虚拟文件系统。

### 单子目录连续展开与空目录

普通目录展开后，如果只有一个可见的非隐藏子目录，侧栏继续展开这个子目录，保留各级目录行，
例如 `infra → docker → database-validation`，而不是把名字合并。遇到文件、多个子项或空目录就停止。
只处理刚展开或刚完成加载的父行；手动收起子目录后，无关模型通知不得重新打开它。
方向键、双击和展开按钮共用这条规则，Java 包压缩仍由原来的加载器负责。

不能先发布 `infra → docker`，再由视图回调发起 `docker → database-validation` 的读取，
这样即使总耗时不长，用户也会看到逐级展开。`ProjectTreeLoader` 在后台同一个请求内读完
唯一子目录链，最多继续 64 层，遇到分叉立即停止，不读取兄弟子树；包压缩的末端列表仍消费复用。
整批读取不可用（返回 nil）或取消时不发布半条链，模型现有的工作区和目录事件代次检查继续保护整批结果。
若仅省略某个探测路径（例如子目录不可读或刚被移除），停止该链的自动展开，保留已成功读取的父层
和未加载末端；包压缩也不能把省略的路径当成已知空目录。界面只自动展开已成功准备的子目录，
不能立即重试未加载末端并把它误标为空。普通、压缩包和同批其他目录共享这个错误边界。
界面记录正在展开的父路径，收到完整结果的首次行投影就使用完整展开集合；
不能等 `.onChange` 再补箭头状态，否则仍可能出现一帧中间状态。随后把同一集合保存为正常交互状态，
并清除等待标记，手动收起仍然有效。这里是对 Lithe 异步发布边界的修正，不代表 IDEA
对所有磁盘冷缓存目录都承诺整条链一次显示；上游同样支持后台节点加载。

依据 Community `e8d21e84ee23f99ae7237fbb4530ff2e7c3b47c5` 的 `DefaultTreeUI`、
`DefaultTreeLayoutCache` 与 `ProjectViewTree.AUTO_EXPAND_FILTER`。

空目录通过现有 `WorkspaceNode.children: []` 表示，未加载目录仍省略 children。
Core 在列出当前层时，对每个子目录探测第一个可见子项，发现一个就停止，不构建或排序后代列表；
过滤规则、符号链接和嵌套工作树边界复用正式列目录的判断。读取失败时保留可展开状态。
macOS 回退读取遵循同一规则。可见行去掉子树时必须保留空数组这个叶节点标记，
否则即使数据正确，渲染层也会错误显示箭头。空行不响应展开与右方向键；目录内容改变仍由监听更新。
Windows 当前未消费 `workspace.listDirectories`，该响应复用已有可选字段，不改变其加载路径。

目录名称只读取路径自身的 Git 状态，不能把后代删除或冲突传播成父目录的颜色。
IDEA 的 `AbstractPsiBasedNode.computeFileStatus` 调用 `FileStatusManager.getStatus`；
`getRecursiveStatus` 是独立的状态查询，不代表目录自身被删除。`GitTreeStatusProjection`
因此只保留精确路径索引，删除父目录最高优先级汇总；文件状态与直接报告的目录状态仍保留。

项目树去掉旧的额外 8pt 左留白，箭头在共享展开槽内按原生 16pt 左对齐，不退回 SF Symbol。
已只读核对本机 IDEA 2026.2.1 包内 chevron 明暗 SVG，与本次 Community 资源字节相同。
仅核对 SVG 字节不足以证明屏幕效果一致：同一 chevronRight 在 CoreSVG 直接 1x 渲染时，
上下端点覆盖不对称，collapseAll 的圆角尖端也会丢失抗锯齿像素。用本机 IDEA 2026.2.1
的开源 SVGLoader 对同一资源输出 1x/2x 图进行比较后，确认这是栅格化差异。
共享 `LitheIcons.ideaImage` 现在首次读取时按原尺寸的 4 倍生成透明位图，并按原逻辑尺寸缓存，
由现有 Image 插值缩小。SVG 路径、颜色、线宽和明暗变体都不修改；不是放大控件或叠加笔画。
`IDEAIconRasterizationTests` 加载真实四组箭头资源，检查深浅模式、1x/2x 的端点对称与非空输出。
代价是缓存位图按 4x 分配；若未来需要超过原尺寸 4 倍的图标，应按目标尺寸重新栅格化。
这些位图只在进程内生成，不新增磁盘缓存、不改写发布资源，也不依赖 IDEA 的运行时。

项目树缩进、展开槽和图文间距复用 `LitheTheme.Tree`，图标保留原生 16pt。
共享文件/目录图标使用上述 Community revision 的原版 ExpUI 明暗 SVG，具体路径记录在
`macos/Resources/IDEAIcons/NOTICE.txt`。删除本地改色的 `*_light.svg` 和手绘文件/目录替代图，
缺失类型只回退到已有 IDEA unknown 资源。Compose 四个标准文件名使用现有 Docker 图标，
普通 YAML 的映射不变；依据 Docker 官方 Compose 文件名约定。

### 显式全部展开 / 全部收起

Project 标题栏的全部展开走 `WorkspaceFeatureModel.loadAllDirectories`：逐批收集已知目录路径，
复用现有有界、共享的目录读取任务，到没有未加载行时才把完整展开集合交给侧栏。
它不会调用 workspace.snapshot 或重建平铺文件库存；只在用户主动点击全部展开时加载兄弟子树。
普通单目录展开仍遵循前述单链边界，不能因为增加这个按钮而恢复默认全树扫描。
整体沿用 64 轮的读取上限；无进展、读取失败、取消或工作区代次变化时停止，不应用旧展开集合。
侧栏的任务随卸载、切换内容或工作区变化取消；全部收起也取消请求，只保留根目录展开，
已读数据仍由现有树持有以支持再次展开，不重置文件库存或清空选择对应的文档。

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
- 正确示例：展开 `java` 时为压缩包名读到 `com/example` 的列表，接着展开该包时消费它；
  若期间收到该目录下的新增事件，则必须重新读取。不要让事件前的任务在事件后恢复旧缓存。

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
- 展开优化减少包压缩后的重复读取和并发请求，并以有界内存换取短期复用。
  超过缓存上限或发生文件事件时仍需读取磁盘；完整应用的交互耗时应通过实际项目采样验证。

## 验证

- `cd rust && cargo test -p lithe-core project`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'LitheCoreLogicTests'`
- `./scripts/architecture/verify-shared-contracts.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'ProjectTreeLoaderTests|LazyProjectTreeInventoryTests|projectTreeLoaderCompactsPackagesLikeTheFullTreeConversion|ProjectTreeSelectionTests'`

## 适用范围

- `rust/lithe-core/src/project/files.rs`
- `macos/Sources/Lithe/Models/Workspace/ProjectTreeLoader.swift`
- `macos/Sources/LitheCoreContracts/Workspace/FileNodePathLookup.swift`
- `macos/Sources/LitheWorkspaceModule/`
