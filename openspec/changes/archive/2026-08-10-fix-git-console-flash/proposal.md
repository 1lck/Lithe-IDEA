## Why

Windows Qt 版(`lithe_windows_qt`)打开后,git 操作期间屏幕会不定期闪现一个标题为 git.exe 完整路径(如 `D:\Claude Code\git\Git\cmd\git.exe`)的控制台窗口。根因:`lithe_windows_qt` 是 WIN32 GUI 子系统应用(无控制台),而 lithe-core 用 `std::process::Command` 启动 git.exe(控制台子系统程序),git 写入 stdout/stderr 时触发 Windows 隐式 `AllocConsole`,弹出独立控制台窗口;git 操作由 worker 周期性调度,因此窗口"时不时"闪现。

## What Changes

- 在 lithe-core 增加 Windows 特化的 git 子进程构造 helper,统一设置 `CREATE_NO_WINDOW`(`0x08000000`),从 GUI 宿主创建 git 进程时不产生控制台窗口。
- `git.rs` 的 `run_git` 与主 git 执行路径(`git.rs:453`)、`lib.rs` 的全部 `Command::new("git")` 调用点改用该 helper。
- 非 Windows 平台该 helper 编译为直接返回普通 `Command`,行为完全不变;macOS 共享核心不受影响。
- 不修改 Windows app 层(`win32_process_session` 已用 `CREATE_NO_WINDOW`,ConPTY 会话已挂伪控制台)。

## Capabilities

### New Capabilities

- `subprocess-console-suppression`:在 Windows 的 GUI(无控制台)宿主下,lithe-core 启动 git 子进程时抑制隐式控制台窗口,保证子进程写入 stdout/stderr 不弹出控制台窗口。

### Modified Capabilities

## Impact

- `rust/lithe-core/src/git.rs`:`run_git`(`:2469`)与主执行路径(`:453`)的 `Command::new("git")`。
- `rust/lithe-core/src/lib.rs`:多处 git clone/操作(`:531`、`:590`、`:897`、`:986`、`:1109`、`:1390`、`:1706`、`:1772`、`:1887`、`:1979`)的 `Command::new("git")`。
- 仅 Windows 编译分支行为变化;需要重新构建 Rust core 并在 Windows 上运行 `cargo test` 与 CTest 验证。
- 依赖方向不变:共享行为留在 `rust/lithe-core`,Windows app 层不动。
