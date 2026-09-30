# Agent 笔记：Linux 项目侧边栏的搜索按钮对齐 Windows 的文件树搜索

状态：已实现

## 先说结论

Linux 工作台左侧「项目（Explorer）」面板标题栏上有一个放大镜按钮。它以前
只是把**已经展开的文件树**按文件名做一次子串过滤：看不到没展开目录里的文件，
不匹配路径，不能回车在命中之间跳转，也不会自动展开命中所在的目录。现在它和
Windows 的同一个按钮行为一致：在整个工作区快照上搜索，命中项连同其所在目录
一起显示并自动展开，回车 / Shift+回车 可以在命中之间前后跳转。

开发者要记住：**这个按钮的行为只能以 Windows 的
`windows/tauri/src/features/file-explorer/` 为准，不要在 Linux 里另立一套
匹配范围或导航规则。**

## 问题

Windows 的 `file-explorer-tree.tsx` 中，标题栏的搜索按钮打开一个
`SidebarSearchPopover`，输入的不是「过滤当前已显示的行」，而是一次真正的
工作区文件搜索：

- 命中收集 `collectFileTreeSearchHits` 在整个文件树上遍历，匹配串是
  `"${name} ${path}".toLowerCase()`，因此路径片段也能命中，且未展开目录里
  的文件同样会被搜到。
- 命中后 `filterFileTreeForFffHits` 只保留命中项及其祖先目录，并把含命中
  子节点的目录放进 `expandedPaths` 强制展开。
- 回车调用 `navigateTreeSearchMatch`：回车跳下一个命中，Shift+回车跳上一个，
  并滚动 / 聚焦到该行。

Linux 侧 `linux/src/workbench/sidebar.rs` 原来只有：

- 对 `visible_items`（`collect_visible` 的产物，只包含已展开节点）做
  `item.name.to_lowercase().contains(query)` 过滤；
- 保留命中项的祖先目录路径，但不展开；
- 回车分支为空 `"enter" => {}`。

于是同一个关键词，Windows 能搜到 `src/main.rs` 这类未展开的深层文件，Linux
搜不到；Windows 能回车逐个跳转，Linux 只能看。

## 决策

### 匹配范围与串：完全复刻 Windows

新增纯逻辑模块 `linux/src/workbench/tree_search.rs`：

- `collect_hits(root, query, limit)` 对应 `collectFileTreeSearchHits`：深度优先
  遍历整个递归树，对 `"name path"` 做大小写不敏感子串匹配，按命中顺序返回
  路径，命中上限 `TREE_SEARCH_RESULT_LIMIT = 500`。
- `filter_for_hits(root, hit_paths)` 对应 `filterFileTreeForFffHits`：返回只含
  命中项及祖先目录的子树、命中路径集合与需要展开的目录集合。命中目录自身
  若没有命中子节点，保留其原始子节点且不强制展开——与 Windows 的
  `children: matchingChildren.length > 0 ? matchingChildren : item.children`
  逐一对应。

该模块不依赖 gpui、不做 IO，便于用确定性单测锁定行为。

### 渲染时用「展开覆盖」，不改写用户的展开状态

Windows 把 `expandedPaths` 当作渲染期的覆盖集合，而不是改持久状态。Linux
在 `render_explorer` 里同样只在计算可见行时对克隆出来的树应用覆盖
（`apply_expanded_override`），并保留工作区根节点的展开态。搜索清空后，
文件树恢复用户原本的展开状态，不会因为搜索过就"到处都展开了"。

### 导航游标放在视图状态里

`SidebarView` 新增 `tree_search_hits` 与 `tree_search_match_index`：输入变化时
`recompute_tree_search` 重算命中并把首个命中设为当前选中；回车时
`navigate_tree_search` 按环形下标前进或后退。这样键盘导航不需要重新搜索。

## 考虑过的备选方案

### 备选方案一：只把过滤范围从 `visible_items` 改成整棵树

改动最小，能解决「搜不到未展开文件」。但它仍然不匹配路径、不自动展开、
不能跳转，Linux 与 Windows 仍是两套能力。用户要求「具备同样的搜索能力」，
因此不采用。

### 备选方案二：接入 Windows 使用的 fff（模糊文件查找）后端

Windows 桌面端用 `useFffSearch` 调用原生 fff 后端做模糊匹配，WSL 根路径才
退回 `collectFileTreeSearchHits` 子串匹配。Linux 没有 fff 后端，且当前
Lithe Linux 的快速打开也使用子串匹配；为了不引入第二套匹配语义和额外
依赖，Linux 选择与 Windows 的 WSL 回退路径一致：对完整树做 `"name path"`
子串匹配。ceiling 是：Linux 不做模糊排序，命中顺序是树的深度优先顺序。

### 备选方案三：把搜索做成独立的 Search 标签页

Linux 侧边栏已有一个「搜索」标签页（对应全局内容搜索）。但标题栏的放大镜
按钮在 Windows 里是「在文件树中定位文件」，与内容搜索是两回事。合并两者
会让按钮语义漂移，因此不采用。

## 后果

- 收益：同一个关键词，Linux 与 Windows 能搜到的文件集合一致（Linux 不做
  模糊排序，这是唯一已知差异）；深层未展开文件也能被搜到。
- 收益：命中项所在目录自动展开，回车 / Shift+回车 可直接在命中间跳转。
- 代价：搜索会遍历整棵文件树，而不是只遍历已展开节点。文件多时有额外开销，
  `TREE_SEARCH_RESULT_LIMIT` 用来限制命中数量；后续如需可按下发的
  `TREE_SEARCH_DEBOUNCE_DELAY_MS` 接入防抖。
- 代价：命中高亮只做整行选中，不像 Windows 那样对匹配字符做局部高亮。

## 验证

- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib` 中
  `workbench::tree_search` 的 8 项纯逻辑测试覆盖：深度优先全树遍历、空格查询
  返回空、路径片段命中、大小写不敏感、命中上限、命中项与祖先保留、命中目录
  不因自身命中而强制展开、无命中返回空结果。
- `cargo build --manifest-path linux/Cargo.toml -p lithe-linux` 通过。
- 手工验证：在 Explorer 点放大镜输入关键词，确认深层未展开文件出现且目录
  自动展开；回车 / Shift+回车 在当前选中项前后跳转；Esc 或清除按钮后文件树
  恢复原展开状态。

## 适用范围

- `linux/src/workbench/tree_search.rs`：文件树搜索纯逻辑与常量。
- `linux/src/workbench/sidebar.rs`：搜索按钮、输入、命中重算、导航与渲染期
  展开覆盖。
- 不适用于 Windows 产品；Windows 侧真源是
  `windows/tauri/src/features/file-explorer/components/file-explorer-tree.tsx`
  与 `windows/tauri/src/features/file-explorer/lib/visible-file-tree-rows.ts`。
- macOS 的项目侧边栏当前没有这个搜索按钮，因此本决策不涉及 macOS。
