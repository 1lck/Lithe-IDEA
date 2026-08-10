## Why

`fix-git-console-flash` 已在 Debug 构建中修复并验证(git 子进程 `CREATE_NO_WINDOW`),但用户运行 Release 构建的 `lithe_windows_qt.exe` 时仍会闪现标题为 git.exe 路径的控制台窗口。Release 构建需要重新编译 Rust core 并重链接 app,否则它仍链接修复前的旧 `lithe_core.lib`。

## What Changes

- 重新构建 Release 配置下的 Rust core(`lithe-core`),使 Release 的 `lithe_core.lib` 包含 `git_command()` 的 `CREATE_NO_WINDOW` 修复。
- 重链接 Release 配置的 `lithe_windows_qt.exe`。
- 启动 Release exe 并验证 git 操作不再闪现控制台窗口。
- 可选:在 Release 配置下跑 CTest 回归,确保重新链接无回归。
- 无源代码改动,无 spec 需求变化;这是一个构建/验证收口任务。

## Capabilities

### New Capabilities

### Modified Capabilities

- `subprocess-console-suppression`:该能力(Windows GUI 宿主下 git 子进程不闪现控制台窗口)必须在 **Release 构建** 下同样生效;之前只在 Debug 构建中验证,Release 产物未重新编译导致实际未生效。

## Impact

- `rust/target/windows/x86_64-pc-windows-msvc/release/lithe_core.lib`
- `windows/build-windows/Release/lithe_windows_qt.exe`
- 仅构建产物;不修改 `rust/lithe-core` 源码、`windows/adapters` 或 Qt 代码
- 用户从 Release 路径启动的 exe 将获得与 Debug 一致的修复效果
