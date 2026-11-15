# Agent 笔记：本地 Git 变更列表与提交范围保护

状态：已实现

## 先说结论

本地变更列表（ChangeList）把同一工作区的文件改动分组，例如把只供本机使用的配置放进单独的列表。列表只是本地分组，不改变文件内容或 Git 暂存区：批量暂存只作用于当前列表，提交时若其它列表已有暂存文件，提交会被拦截，由用户明确处理。归属与提交范围由 Core 的 `git.changelists` 计算，桌面端只负责保存与展示。

## 问题

只把文件按标题分组，不能阻止“全部暂存”或整索引提交把本地配置带进去。只在界面最后一次刷新时检查也不够，外部 Git 可能在刷新后暂存文件、重命名文件或改变父仓库引用。把“移动到列表”实现成自动取消暂存，又会破坏用户的部分暂存结果。

## 决策

- **归属由 Core 计算。** 列表操作、文件归属、重命名跟随和提交范围都由 Core 的纯 reducer 计算。桌面端只保存持久化快照，并以状态代次丢弃过期投影。
- **文件归属包含仓库根和仓库相对路径。** 工作树与同名文件不会串组。
- **默认列表接收未分配的新路径。** 新建列表不会自动搬入已有文件；删除列表时文件回到默认列表，并需要确认。
- **当前列表限定批量暂存与提交范围。** 提交请求携带 Core 的 `pathScope`，Core 会重新读取真实暂存路径，拦截范围外的已暂存文件和自动父引用更新，并且不修改索引。
- **重命名跟随归属。** Git 报告的重命名沿用原路径的归属并记住新路径；手动移动重命名时两端都记录。不会通过扫描磁盘或相似内容推断重命名。
- **文件变干净后保留归属。** 配置之后再次修改时，仍留在原列表。
- **保存按仓库分文件、按读写冲突重试。** 元数据放在应用数据目录（`git-changelists-<仓库根哈希>.json`），不写入仓库或发行包。每次写入前重读并比较，与其它窗口冲突时最多重试三次，不覆盖更新的值。
- **元数据不可读时整套列表停用。** 格式、版本或仓库根不匹配，或读写失败时，禁止全部暂存、提交和 AI 生成说明，原文件保持不动，不静默恢复为空列表。
- **重试提交沿用上次计划的范围。** 重试不能借机放宽范围。

## 考虑过的备选方案

- **`assume-unchanged` 或 `skip-worktree`。** 未采用。它们改变工作树检查行为，不能表达本地任务分组，也不是防误提交的保证。
- **为每个列表维护独立索引或改写真实索引。** 未采用。会增加部分暂存、钩子、冲突和失败恢复的风险。
- **仅靠界面禁用按钮。** 未采用。快捷键与过期界面都可能绕过，Core 必须再次检查。

## 后果

- 列表按完整文件路径工作，不能把同一文件的不同修改块分到不同列表。
- 当前列表提交前，用户需要先取消其它列表的暂存勾选；Lithe 不会自动整理索引。
- 外部 Git 不参与 Lithe 的写入锁，外部并发仍可能在检查之后改变索引，因此提交前会再次核对。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench -run TestChangeLists -count=1`：覆盖只提交当前列表、其它列表已暂存时拦截、重名被拒后保留弹窗、删除归还默认列表、元数据损坏时停用且不覆盖。
- `scripts/desktop/desktop-go.sh test -race ./internal/core -run 'Test(ChangeListsUseSharedMembershipAndScope|WorkspaceCommitScopeProtectsStagedChanges)' -count=3 -timeout=90s`：用临时 Git 仓库验证范围、准备后暂存变化与 HEAD 和索引不变。
- 在真实仓库中验收：列表的新建、重命名、移动与提交范围，以及外部暂存其它列表文件后的拦截提示。

## 适用范围

- `desktop/internal/workbench/changelists.go`
- `desktop/internal/workbench/changelists_view.go`
- `desktop/internal/workbench/commit.go`
- `desktop/internal/core/changelists.go`
- `desktop/internal/core/changelists_test.go`
- `shared/platform-feature-matrix/features/git-local-changelists.json`
