# Agent 笔记：Linux 全局搜索对齐 Tauri 的参数与分页契约

状态：已实现

## 先说结论

Linux 侧的“在文件中搜索”曾把 `maxResults` 写死为 100，并且只发送 4 个简单
参数，导致同一个关键词在 Linux 上明显比 Windows 少很多结果。现在 Linux 与
Windows 使用**同一套参数契约和同一套结果语义**：核心命令 `workspace.search`
由两端各自按相同字段发送，搜索选项（大小写 / 全字 / 正则）、文件数分页上限
（每页 140）、路径 include/exclude 过滤、上下文行（2 行）、结果摘录与替换
全部按 Windows 的行为实现。开发者要记住：**搜索行为只能以
`windows/tauri/src/features/global-search/` 为准，不要在 Linux 里另立一套
默认值或匹配规则。**

## 问题

Linux 工作台的侧边栏搜索早期只有“一个输入框 + 一次请求”：

- 调用 core `workspace.search` 时只传 `root`、`query`、`caseSensitive=false`、
  `maxResults=100`。而 Windows 传的是完整字段，默认 `maxResults=140`，
  且 core 自身默认值是 200，上限 10000。
- 没有大小写 / 全字 / 正则开关，没有 include/exclude 路径过滤。
- 没有分页（`file_offset`），没有上下文行，没有结果摘录与替换。

结果就是用户观察到的问题：同一关键词在 Linux 上搜出来的东西“特别少”。
根因不是匹配逻辑不同（两端都由 core 的同一个 `search_with_index` 执行），
而是**请求参数和结果上限被写死得比 Windows 小**。

## 决策

### 契约只在两端共享，语义以 Windows 为准

- 两端都调用 core 的 `workspace.search`，字段名与含义一致：
  `caseSensitive`、`wholeWords`、`regularExpression`、`maxResults`、
  `fileMask`、`paths`。
- Linux 的默认值与上限改为与 Windows 相同：每页 `CONTENT_SEARCH_PAGE_SIZE`
  = 140，上下文 `CONTEXT_LINES` = 2，展开上下文 `EXPANDED_CONTEXT_LINES` = 7，
  防抖 `SEARCH_DEBOUNCE_DELAY_MS` = 200，首次渲染 40 条、每次追加 40 条。
  这些常量集中在 `linux/src/workbench/global_search.rs`，逐条对应
  `windows/tauri/src/features/global-search/constants/limits.ts`。
- 分组与分页语义按 `windows/tauri/src/features/file-search/lib/file-search-api.ts`
  的 `searchFilesContent` 实现：只保留 `kind == "content"`，按文件分组，
  文件数超过 `maxResults` 时截断并置 `has_more`。

### 纯逻辑与渲染分离

- `linux/src/workbench/global_search.rs` 只放纯逻辑：常量、匹配选项、
  正则构建、单文件切分、结果分组、分页合并、路径 glob 过滤、摘录构建。
  它不依赖 gpui，也不做 IO，因此可以用确定性单测锁定行为。
- `linux/src/workbench/global_search_panel.rs` 只负责状态与渲染：防抖、
  首页/加载更多、三个开关、include/exclude、摘录行渲染、替换。

### 路径过滤用 glob，不用 core 的 fileMask

Windows 的 include/exclude 是在前端把 glob 编译成正则后过滤**相对路径**，
而不是把通配符交给 core 的 `fileMask`。为保持行为一致，Linux 复刻同一套
`globToRegExp` 语义（`*` 不跨目录、`**` 跨目录、`?` 单字符、逗号或换行分隔），
在 `matches_path_filters` 中实现。

### 替换走 core 的预览命令

Windows 的替换在客户端读写整文件。Linux 复用 core 已有的
`workspace.replacePreview` 得到每个文件的新内容，再用 `file.write` 写回，
避免在 Linux 里手写第二套替换正则逻辑。

## 考虑过的备选方案

### 备选方案一：只把 `maxResults` 从 100 提到 500

这是最小改动，能立刻缓解“结果少”。但它只改了数量上限，仍然没有开关、
过滤、分页、上下文和替换，Linux 与 Windows 仍是两套能力。用户明确要求
“完全对齐、保持功能一致性”，因此不采用。

### 备选方案二：把 Windows 的 React/TS 代码整体移植到 Linux

不可行。Windows 的 `features/global-search/` 是约 3900 行 React/TS，依赖
zustand store、React hooks 和 Monaco 摘录渲染；Linux 是 GPUI/Rust，没有
DOM、没有 React、没有 Monaco。可行做法是复用**核心命令契约与可见行为**，
而不是复用前端框架代码。

### 备选方案三：在 Linux 里另写一套更简单的搜索 UI

改动看起来更小，但会制造第二套默认值和匹配规则，正是本次问题的成因。
一旦两端上限、过滤或上下文行数不同，“同一关键词结果不同”会再次出现。

## 后果

- 收益：同一个关键词在 Linux 与 Windows 上返回相同的匹配集合，差异只剩
  渲染方式；用户对“结果变少”的困惑被消除。
- 收益：搜索选项、过滤、分页、上下文、替换都集中在纯逻辑模块里，行为可由
  单测锁定，后续调整只改常量与纯函数。
- 代价：Linux 新增加载更多、上下文展开、三个开关和替换输入，界面比原来复杂。
- 代价：Linux 的摘录需要按需读取源文件才能展开上下文；当前只预取前 20 个
  文件并限制缓存 64 条，未读取到的文件只显示 core 附带的上下文字符串。

## 验证

- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib` 覆盖
  `workbench::global_search` 的 20 项纯逻辑测试：字面量/大小写/全字/正则的
  匹配语义、非法正则返回 `None`、单文件多区间与上下文、二进制跳过、
  分页合并去重、`kind` 过滤与文件数上限、glob（`*` / `**` / `?`）、
  exclude 优先、摘录上下文合并与 `...`、匹配条数上限、展开上下文、
  相对路径与路径拼接。
- `cargo build --manifest-path linux/Cargo.toml -p lithe-linux` 通过。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` 通过。
- 从仓库根与带 CLI 参数两种方式启动 `./target/debug/lithe-linux` 均无 panic。

## 适用范围

- `linux/src/workbench/global_search.rs`：搜索纯逻辑与常量。
- `linux/src/workbench/global_search_panel.rs`：搜索面板状态与渲染。
- `linux/src/core/client.rs`：`search` 的完整参数与 `replace_preview`。
- `linux/src/i18n.rs`：`search.*` 文案键。
- `linux/src/workbench/view.rs`：`edit.find` / `edit.find_replace` 打开面板、
  面板事件的接线。
- 不适用于 Windows 产品；Windows 侧真源是
  `windows/tauri/src/features/global-search/` 与
  `windows/tauri/src/features/file-search/lib/file-search-api.ts`。
