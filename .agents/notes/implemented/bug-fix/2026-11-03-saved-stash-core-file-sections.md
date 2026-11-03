# Agent 笔记：Stash 查看使用 Core 的逐文件差异

状态：已实现

## 先说结论

macOS 查看 Stash 时，Git 执行、文件身份和差异解析都由 Rust Core 完成；宿主只呈现 Core 返回的文件与行。每个文件保留原始补丁，二进制与未跟踪文件也能查看；原来的 Shelf 双层补丁流程尚未迁移。

## 问题

旧实现手工执行 `stash show`，在 Swift 里拆分文件，再逐文件启动 Git 识别路径并再次解析差异。文件多时 Git 进程数量随文件增长；文件名转义、前缀设置和平台解析器还可能造成不同结果。旧差异解析器对每一行重复统计整份补丁的行数，大补丁的扫描成本呈平方增长。

## 决策

- `git.diff` 接受已有的不可变 stash 提交身份，按需返回逐文件结构；此模式目前只支持整个仓库，拒绝局部路径参数，避免误返回未选文件。路径与重命名前路径交给 Git 的双向 NUL 分隔统计解析，Core 校验数量与补丁边界一致；每段原始 UTF-8 补丁和 Core 行结果一起返回，避免再传一份完整补丁。
- 强制 Git 使用标准前缀、关闭颜色和文本转换。不能依赖用户的 `diff.noprefix` 设置，也不要给 `stash show` 组合手写前缀参数：某些 Git 版本会因此输出不能由 `git apply` 识别的无前缀补丁。
- 补丁超过共享 32 MiB 上限、不是有效 UTF-8 或无法一致配对时拒绝返回；不能以替换字符伪造可恢复的原始补丁。解析逐行线性扫描，普通平铺 `git.diff` 响应保持兼容。
- 正确做法是先固定选中 stash 的提交，再请求逐文件数据并直接使用返回的渲染行；不要在宿主按文件名切补丁、重新解释 Git 路径或把一份补丁按文件重复发送给 Git。

## 考虑过的备选方案

- 只把 `stash show` 换成 Core、保留 Swift 分段和逐文件检查：仍重复解析和启动 Git，没有解决跨平台规则分散。
- 手工解析 `diff --git` 里的转义文件名：Git 原生 NUL 分隔统计已经提供更可靠的路径语义，不再维护另一套转义规则。
- 把原始补丁和全部逐文件内容一起返回：大补丁需要重复跨语言传输；逐文件模式将平铺结果留空。

## 后果

一份 Stash 需要 Git 的差异查询与两次批量补丁统计，不再按文件调用 Git；每个文件仍有独立补丁和展示行。返回数据不是跨外部 Git 操作的事务，但固定提交身份避免列表位置变化后查看到其他 Stash。Shelf 和 Windows 平台的重复解析仍由 GIT-20 跟踪；不在本次改动中声称完成。

## 验证

- `rust/lithe-core/src/tests/git_patch_exchange.rs`：真实临时仓库覆盖重命名、中文名称、未跟踪文件、二进制、Git 前缀配置以及错误的请求模式。
- `macos/Tests/LitheTests/GitStatusObservationTests.swift`：真实 Swift 桥接、Core 和 Git 验证已跟踪、未跟踪与二进制 Stash 文件及展示行。
- `./scripts/rust-core/verify-rust-core.sh`、`./scripts/architecture/verify-shared-contracts.sh`、`./scripts/agent-notes/verify-agent-notes.sh` 和 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。
- 大补丁解析循环使用合成 2 万行输入作前后测量；这不是完整工作台加载延迟。原生界面和平台矩阵验收保持待验证。

## 适用范围

- `rust/lithe-core/src/git/mod.rs`
- `rust/lithe-core/src/git/patch_exchange.rs`
- `macos/Sources/LitheGitModule/Services/GitService.swift`
- `macos/Sources/Lithe/Core/Rust/RustGitOperations.swift`
- `shared/contracts/rust-core-api.md`
