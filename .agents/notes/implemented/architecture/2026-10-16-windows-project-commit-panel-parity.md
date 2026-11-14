# Agent 笔记：项目和提交面板同步边界

状态：已实现

## 先说结论

项目树区分行选择与编辑器活动文件，提交列表区分行选择与暂存包含。提交面板的 Amend、保存改动（Shelf，保存改动后暂时清理工作区的恢复记录）与草稿保留在原工作区会话。Shelf 必须先落盘，再清理文件；任何部分失败都保留完整记录供用户比较和恢复。

## 问题

原文件树只处理单项，目录单击把选择与展开绑定。提交列表已有 Diff 与暂存能力，但缺少 Amend 入口和集中的保存改动页签。项目历史聚合还暴露了旧存储只以相对路径区分文件的问题：两个项目的 `src/main.java` 会混入同一个时间线。

## 决策

- 树选择复用可见顺序工具，Shift 保持初始锚点，Ctrl 增减单项，项目树 Ctrl+A 只选择焦点项的显示同级；复选框仍只表达实际 Git 暂存状态。折叠目录不删除明确选中的后代，批量操作从已有文件库存取集合，不额外加载磁盘树。文件索引只在库存变化时建立，选择改变不重新遍历整棵树。
- 项目本地历史依赖 Core 的本地文件系统查询，因此菜单只对原生本地工作区显示，`openProjectLocalHistory` 也拒绝 `wsl://` 和 `remote://` provider 路径。后续开放这些 provider 时，必须先补齐 Core 或对应 provider 的历史契约，再移除入口门控。
- Shelf 用原始 Git 补丁分别保存暂存和工作区版本，包含未跟踪与二进制文件。保存完成后再读取一次快照并比较，确认期间没有变化才逆向清理；恢复先恢复暂存，再恢复工作区，最后才删除记录。两步之间的冲突不做自动合并或回滚，完整记录继续保留。重试时，某层补丁应用失败后复用 Core 的只读逆向检查，确认该层已恢复才继续；暂存层只检查索引，避免工作区已恢复第二层时误判。检查失败或仍有真实冲突时保留记录，全部恢复后删除失败也允许再次重试。
- Core 的预览令牌绑定补丁方向、目标、真实索引和工作区内容。Git 只读命令与 `apply --check --index` 也可能刷新索引时间信息，因此检查使用一次性索引副本；真实恢复在审核状态通过后刷新索引时间缓存，再由 Git 做最终内容匹配。共享协议保持 `reverse` 默认为 false。
- Git Stash 使用不可变对象身份 `oid`；列表位置变化后按身份重新定位，避免把旧 `stash@{0}` 当成同一记录。Diff 缓存和仍在等待的读取也按同一身份区分，旧读取的自动重试不得复用新占据该位置的记录结果。原 positional reference 继续兼容旧调用方。
- Shelf 与提交、暂存和 changelist 修改互斥。写工作区前检查未保存文档；切换工作区后停止后续写入，迟到的列表与 Diff 读取不能覆盖新面板。原生存储命令只保存恢复数据，不执行 Git 写操作。
- Shelf/Stash 列表与选择绑定到本次仓库会话及加载版本。切换仓库或刷新时立即隐藏旧列表，当前列表未成功加载前禁用创建、恢复和删除；加载失败可重新刷新。删除确认后再次核对会话和列表版本。离开 A 后再回到 A 也属于新会话，旧确认与恢复流程不得继续写入。

Shelf 的工作区层必须以真实索引为基线，包含未跟踪文件，统一由 Core 在临时索引中导出。例如已提交文件执行暂存删除后仍留在磁盘，工作区层必须记录“新增该文件”，清理时先移除磁盘副本，再逆向恢复暂存删除。不能拼接以 HEAD 为基线的未跟踪补丁，否则同内容副本会丢失，重建重命名源路径也会失败。普通补丁导出的 HEAD 基线保持原语义。

正确示例：同一文件的已暂存版本是 B，磁盘版本是 C。Shelf 保存 A→B 与 B→C，清理后回到 A；恢复后索引仍为 B，磁盘仍为 C。不要只保存 A→C 后执行整仓库 reset，否则暂存边界会丢失。

## 考虑过的备选方案

- 用 `git stash` 冒充 Shelf：两种保存记录的归属和删除规则不同，采用独立记录加现有 Core 补丁能力，不复制 Git 补丁解析和应用语义。
- 通过前端解析后的 Diff 重建补丁：会丢失二进制、CRLF、无末尾换行和重命名身份，否决。解析结果只供显示，写入始终使用原始补丁。
- 自动把旧全局历史复制到当前项目：旧元数据没有可靠工作区归属，无法区分同名文件。保留旧目录原字节，新的读写使用按工作区隔离的目录；不自动迁移或删除旧记录。

## 后果

项目与提交面板的选择、草稿和保存改动具有明确归属，部分失败仍保留恢复材料。代价是 Shelf 恢复无法自动消除并发编辑造成的冲突，用户需要比较保留的补丁与当前文件。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/workbench ./internal/core`：Shelf、提交面板与项目树选择的回归。
- 在 Core 仓库运行 `cargo test -p lithe-core git_patch_exchange -- --test-threads=1`：补丁导出、应用与逆向检查。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：Shelf 与历史存储不写发行目录。
- `./scripts/agent-notes/verify-agent-notes.sh`。


## 适用范围
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/git/patch_exchange.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/git/patch_exchange.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`
- `desktop/internal/workbench/shelf.go`
- `desktop/internal/core/git_shelf.go`