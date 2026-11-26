# Agent 笔记：结构化日志收集与文件替换后保留证据

状态：已实现

## 先说结论

结构化日志不能按文件名倒序分配读取预算，也不能假设打开的日志文件一直存在。读取顺序和旧分类由 Core 计算；日志写入器在追加前确认缓存句柄仍指向活动路径。插件语法失败始终记录插件身份，不能因为语言 ID 不符合目录段格式就漏掉错误。

## 问题

同一会话有多个通道、每个通道有活动文件和轮转段时，名字靠后的旧段会先耗尽 10 MiB 收集预算，最新错误可能完全不进入预览和导出。缓存的文件句柄在文件删除或原子替换后仍可写，但写入目标已经失去路径，读回时找不到新事件。

迁移还改变了分类与身份约束：更新事件不再出现在已有的 Application 筛选中；浏览器返回 `c++` 等合法语言 ID 时，因为路由段不允许加号，整个失败事件被跳过。

## 决策

- **保留部分导出的可读记录。** 如果某个会话子目录没有读取权限，扫描继续处理同级目录。导出包在 `collection-status.txt` 中写入 `truncated=true`，这样排查者知道部分记录可能缺失。若日志根目录本身无法打开，直接返回读取错误。
- **Core 决定读取顺序。** Core 接收文件元数据，先按会话和既有分类筛选，再按最新会话、活动段、轮转序号及修改时间分配有界读取。宿主只执行返回的路径、偏移和长度（`desktop/internal/logstore/collect.go` 的 `Collect`）。正确做法是先读活动文件，再读旧轮转；不要按文件名的字符串顺序花完预算。
- **通道分类由 Core 持有。** 通道到旧六类设置选项的映射由 Core 持有，收集和详细诊断共用。更新、远程及 Agent 事件仍属于 Application；终端属于 Run。
- **追加前检查文件身份。** 每次追加前检查缓存句柄与磁盘上的路径是否仍是同一个文件（`desktop/internal/logstore/store.go` 使用 `os.SameFile` 和文件大小）。路径被删除、替换或截断后关闭旧句柄并重开，必要时重建文件头；目录不可写时沿用默认目录回退。只检查路径存在无法发现原子替换。
- **插件身份单独路由。** 插件语法失败使用插件身份路由，语言作为可选、有界的 version 字段。`c++` 保留原值，超长语言 ID 省略该字段，但保留失败事件。

## 考虑过的备选方案

- **继续按文件名倒序收集**：新名字不再包含写入时间，无法代表证据新旧。
- **只优先某个通道**：会使其他通道的活动日志被旧段挤掉，因此采用所有活动段优先。
- **每条事件重新打开文件**：可恢复路径，但丢失句柄缓存的收益。保留缓存并检查文件身份。
- **把语言 ID 清洗成目录段**：改变真实身份，且掩盖插件诊断；仅路由身份需要段校验。

## 后果

日志预览与导出在预算压力、外部清理或原子替换后仍能定位近期错误。每次追加增加一次文件身份检查，Core 增加一个纯计算的收集入口；没有新的后台定时器或跨工作树可变缓存。日志只写平台可写目录，不写应用包，不改变代码签名或 Sparkle 增量基线。

## 验证

- `TestCollectMarksUnreadableSubtreeAsIncomplete` 在可读日志旁建立一个不可读的子目录，检查导出包含可读事件并标记不完整。
- `scripts/desktop/desktop-go.sh test ./internal/logstore/...`：`collect_test.go`、`store_test.go` 和 `writer_test.go` 覆盖收集预算、删除与替换后的重开以及导出。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`

三项文件回归在修复前分别遗漏最新通道、丢失删除或替换后的事件，以及漏掉更新分类；Core 的 C++ 语法失败用例在修复前返回的字段非法。

## 适用范围

- `desktop/internal/logstore/collect.go`
- `desktop/internal/logstore/store.go`
- Core 仓库的 [`rust/crates/diagnostics/src/collection.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/diagnostics/src/collection.rs) 与 [`channel.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/diagnostics/src/channel.rs)，以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
- [结构化日志夹具](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/diagnostics/logging-v2.json)
