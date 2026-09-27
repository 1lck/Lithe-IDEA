# Agent 笔记：Windows Git 路径往返必须保持文件身份

状态：已实现

## 先说结论

Windows 的原生网络路径（UNC）和扩展长度路径（verbatim，带 `\\?\` 前缀）必须先规范化，再判断是否为绝对路径。Git 暂不支持路径分量末尾为 ASCII 点或空格，保留的 DOS 设备文件名、扩展路径内的 `.`/`..` 分量，以及盘符/UNC 之外的设备命名空间；遇到这些输入必须明确报错，不能通过去前缀或清理空白访问另一个文件。

## 问题

Issue #627 中，前端先判断绝对路径再替换反斜杠，把原生 UNC 文件拼进了当前仓库。Core 同时无条件去掉规范路径的扩展前缀，但该前缀会改变 Windows 的路径解析规则，去掉后不一定还是原来的目录。

## 决策

- 前端文件解析先经过 `normalizeGitOperationPath`，再决定是否拼接仓库根；共享文件路径工具继续服务其他模块，Git 的拒绝策略单独放在 Git 边界。
- 供 UI 比较和渲染使用的 `normalizeRepositoryPath` 对不支持的路径保留原值，不抛错也不改写身份。执行入口使用带校验的函数，让仓库发现等异步流程把错误写入已有界面状态。
- Core 在文件系统查找之前、规范化之后及读取 Git 返回路径时校验不支持的名字，返回 `invalid_request`。已删除工作树仍可使用原路径展示，但不能让这个回退吞掉不支持路径的错误。
- 去掉 Git 输出的行结束符时不使用会吞掉文件名空格的 `trim()`。正常盘符/UNC、中文、内嵌空格和长路径继续通过原生 Git 处理；不凭长度推断它们不可用。
- `remote://`、`wsl://` 保留协议和远端 POSIX 文件名语义，不对远端目录套用 Windows 尾部点/空格限制。

正确例子：`\\?\C:\work\repo\src\main.ts` 解析为仓库 `C:/work/repo` 与相对文件 `src/main.ts`。
不要把 `\\?\C:\work\repo.` 改写成 `C:/work/repo`，也不要在校验失败后改用活动仓库继续操作。

## 考虑过的备选方案

全链路保留扩展前缀可以支持更多特殊名字，但当前前端、Git 工作目录和原生监听器都消费普通路径，局部保留不能保证往返身份一致。静默删除尾部点、空格或前缀会访问错误对象，因此采用显式拒绝，待所有消费者能够保留语义时再扩大支持范围。

## 后果

普通 UNC 文件不会再被错误拼接，危险的路径转换会变为可见错误。代价是含尾部点/空格的 Windows 仓库当前不能使用 Git 功能；这项限制必须由两端校验和共享样例一起维护，不能只放开其中一端。

## 验证

- `shared/fixtures/git/windows-paths.json` 由前端与 Rust 测试共同读取。
- `git_path_roundtrip` 原生集成测试使用真实 Git 仓库，把发现结果交给实际前端 TypeScript 规范化函数后回传 Core，核对提交、分支、stash 和链接工作树的监听目录。它需要 Git 和 Node.js 22.6+，子进程通过现有 Git Host 设置本地期限并清理进程树。
- Windows 专属测试真实创建末尾点/空格目录及普通同名目录，确认请求明确拒绝，不误用普通目录。
- 原生 watcher 测试用有界事件接收验证外部提交/切换所写的共享引用与独立 HEAD 元数据会通知对应工作树；没有用 sleep 等待防抖。
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope SharedRust`
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope WindowsRust`
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`

## 适用范围

- `rust/lithe-core/src/git/mod.rs`
- `windows/tauri/src/features/git/api/git-repository-path.ts`
- `windows/tauri/src/features/git/api/git-repo-api.ts`
- `rust/lithe-core/tests/git_path_roundtrip.rs`
- `windows/tauri/crates/project/src/git_watcher.rs`
- `shared/contracts/rust-core-api.md`
