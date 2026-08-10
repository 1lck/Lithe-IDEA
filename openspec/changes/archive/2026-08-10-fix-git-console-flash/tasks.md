## 1. 实现 Windows 抑制 helper

- [x] 1.1 在 `rust/lithe-core/src/git.rs` 增加 `CREATE_NO_WINDOW` 常量(`0x0800_0000`,注释来源)与 `pub(crate) fn git_command()` helper:构造 `Command::new("git")`,在 `#[cfg(windows)]` 块内 `use std::os::windows::process::CommandExt` 并 `creation_flags(CREATE_NO_WINDOW)`;非 Windows 分支直接返回普通 `Command`。
- [x] 1.2 确认 helper 的 Windows 分支被 `#[cfg(windows)]` 完全隔离,非 Windows 平台编译行为与改动前一致。

## 2. 替换 git 子进程创建调用点

- [x] 2.1 `rust/lithe-core/src/git.rs` 主 git 执行路径(`:453` `Command::new("git")` + `.spawn()`)改用 `git_command()`。
- [x] 2.2 `rust/lithe-core/src/git.rs` `run_git`(`:2469` 链式 `.output()`)改用 `git_command()`。
- [x] 2.3 核实 `rust/lithe-core/src/lib.rs` 的全部 `Command::new("git")` 均位于 `#[cfg(test)] mod tests` 测试模块内,是 git fixture 构造而非生产子进程创建路径(测试在 cargo 环境运行,无 GUI 宿主窗口问题);生产 git 子进程创建(仅 git.rs 主路径与 `run_git`)已全部改用 `git_command()`。

## 3. 验证

- [x] 3.1 Grep 确认生产代码路径(git.rs)无绕过 helper 的残留 `Command::new("git")`(helper 定义处除外);lib.rs 残留均位于 `#[cfg(test)]` 测试模块,属测试 fixture,不构成绕过路径。
- [x] 3.2 在 Windows 重新构建 Rust core 并运行 `cargo test`:26 通过 / 8 失败,与改动前基线完全一致、无新增回归(8 个既有 git 领域失败为改动前基线,不属于本 change 阻塞)。
- [x] 3.3 重链接 `lithe_windows_qt` 并启动,观察 git 操作(状态刷新/提交/拉取)不再闪现标题为 git.exe 路径的控制台窗口。
- [x] 3.4 确认 Windows app 层(`win32_process_session`、`win32_terminal_transport`)未改动,CTest 回归 28/28 通过(需 `QT_QPA_PLATFORM=offscreen` + `QT_PLUGIN_PATH` 环境)。
