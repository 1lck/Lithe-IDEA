# Agent 笔记：项目树按需读取时批量查询 Git 跟踪目录

状态：已实现

## 先说结论

项目目录存在且可读时，打开它仍可能显示“读取失败：项目目录不可用”：同层有很多被 Git 忽略的目录，逐个启动 Git 会耗尽项目树读取的时间预算。
目录是否包含已跟踪文件仍由本机 Git 判断，但 Rust Core（各平台共用的内核）把同层查询按有界批次合并。
项目树继续按需读取，不为这项优化扫描尚未展开的整棵目录树；桌面端只接入修订后的 Core，并保留原有超时、取消和过期结果隔离。

## 问题

`workspace.listDirectories` 不只读取目录名，还要取得目录的索引排除标记。
Core 的 `IndexingContext::prepare_parent` 已经把同层目录合并给 `git check-ignore`，但没有完整预取答案时，仍为每个被忽略的普通目录单独执行 `git ls-files`，确认其中是否存在已跟踪文件。
因此，同层有 N 个这样的目录时，会额外启动 N 个 Git 进程；目录本身可读并不能避免这段等待。

桌面端的这条请求使用两秒 `kernelCallTimeout`。查询超过预算后，项目树显示的是读取失败状态，不能仅凭提示判定目录已被删除或没有权限。
全树扫描的按层预取已经由 [Core #60](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/60) 处理，但首次按需列目录以及预取后新建的目录仍可进入逐个查询的路径。

## 决策

- 在 Core 的 `prepare_parent` 收集需要检查的同层忽略目录，复用已有 `lithe_git::tracked_directories`。该接口按路径参数总字节数分批，每批上限为 16 KiB，并按字面路径及 NUL 分隔输出判断已跟踪内容。
- 查询成功时，只有没有已跟踪内容的普通目录才作 Git 自动排除。包含 `.git` 的嵌套仓库保留自己的规则；手动排除、包含例外、隐藏规则和目录自然排序不因这项优化改变。
- 批量接口返回 `None` 表示无法可靠回答，例如 Git 失败或输出路径无法归属到请求目录。此时保留原有逐目录查询和失败处理，不能把未知答案当成“没有已跟踪文件”。取消检查及最终结果写入的代际检查继续生效。
- 这次只改变当前父目录的询问方式，不增加全树预扫、常驻缓存、轮询或后台进程。Git 跟踪与忽略规则继续在 Core 中处理，Go 呈现层不复制这些规则，也不改变共享接口。
- 桌面端仍使用原两秒预算。为原生 I/O 设置独立预算由 [主仓库 #2045](https://github.com/1lck/Lithe-IDEA/pull/2045) 单独处理；批量查询与合理的 I/O 超时互相补充。

### 正确做法与反例

例如，同层有 500 个 `generated*` 目录，先把需要检查的目录交给批量接口，再使用同一份结果设置各目录的排除标记。被强制加入 Git 索引的后代文件必须受到保护，被索引排除的目录仍可在项目树中浏览。
不要在 Go 中把所有 `generated*` 目录直接隐藏，也不要为了预热答案先遍历整个深层项目；前者改变浏览与索引的语义，后者恢复了按需目录读取原本要避免的工作量。

## 考虑过的备选方案

- 只延长桌面请求超时：能给慢磁盘更多完成机会，但同层目录增加时仍会逐个启动 Git，未消除这次定位到的重复工作。
- 打开项目时先执行全树预取：会访问尚未展开的深层目录，把打开根节点的成本重新绑定到整个工作区大小。
- 自行解析 Git 忽略规则，或者直接排除所有匹配的目录：无法完整保留嵌套仓库、已跟踪后代和原有失败语义。
- 批量查询失败后直接使用空集合：会把未知的跟踪状态当作没有已跟踪内容，造成错误排除，因此保留逐目录回退。

## 后果

正常路径不再为每个被忽略目录启动一次 `git ls-files`，进程数由路径参数的分批数量决定。批量结果只服务当前目录读取，不新增常驻状态；临时参数和结果集合仍随同层目录数增长。
批量查询无法可靠回答时，会先付出一次批量尝试，再回退到原有逐目录成本；这种情况下不承诺性能改善，但保留原有判定能力和失败信号。
慢文件系统或很大的 Git 索引仍可能耗尽读取预算。本决策消除已确认的逐目录进程开销，不构成任意规模项目都能在两秒内打开的保证。

## 验证

- 在 Core 仓库运行 `cargo test --locked --manifest-path rust/Cargo.toml -p lithe-project -- indexing::tests`，检查按需目录查询的进程数量、已跟踪后代、嵌套仓库、批量失败回退以及取消行为。进程数量断言用于防止退回逐目录启动，不能只用机器相关的耗时阈值代替。
- 桌面端的 `desktop/internal/workbench/filetree_large_directory_visual_test.go` 使用真实临时 Git 仓库、500 个同层忽略目录和真实 Core，通过 `TestVisualProjectTreeLargeDirectory` 检查根目录加载、展开普通源码目录和打开文件内容。浅色中文、深色英文分别生成项目树和文件打开后的截图；旧 Core 失败时也先保存项目树截图。
- 从仓库根运行 `LITHE_VISUAL_OUTPUT_DIR="$PWD/.artifacts/project-tree-large-directory" scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench -run '^TestVisualProjectTreeLargeDirectory$' -count=1 -timeout=120s`。分别链接改动前后 Core，使用相同目录数量和机器环境，核对成功状态、文件内容与截图；测试只在显式选择可视化标签时运行。
- Linux 无头结果只能证明所执行环境下的 Core、桌面接线和绘制。macOS、Windows 的原生窗口、文件系统和进程启动成本需在各自平台验证，功能矩阵不据此提前标记为已验收。具体通过记录、耗时和截图随对应 PR 提供，不把探索数据作为正式性能结论。
- `./scripts/agent-notes/verify-agent-notes.sh` 和 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh` 校验记录结构和证据路径。

## 适用范围

- Core 仓库的 `rust/crates/project/src/indexing.rs` 与 `rust/crates/git/src/status.rs`，以 `scripts/desktop/build-desktop-core.sh` 固定的修订为准。
- `desktop/internal/core/workspace.go`
- `desktop/internal/workbench/filetree.go`
- `desktop/internal/workbench/filetree_large_directory_visual_test.go`
- `shared/platform-feature-matrix/features/file-explorer.json`
- 原有边界见 [项目树按需列目录](../architecture/2026-10-19-lazy-project-tree.md) 和 [目录索引排除与项目树可见性分离](../architecture/2026-10-28-workspace-indexing-exclusions.md)。
