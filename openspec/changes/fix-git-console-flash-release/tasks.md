## 1. 验证并清理旧 Release 产物

- [x] 1.1 确认 `rust/target/windows/x86_64-pc-windows-msvc/release/lithe_core.lib` 时间戳(22:08)早于修复后的 `rust/lithe-core/src/git.rs`(22:55),证明 Release 产物未包含修复。
- [x] 1.2 清理旧的 Release 产物(删除 `rust/target/windows/x86_64-pc-windows-msvc/release` 和 `windows/build-windows/Release` 中的旧二进制),避免链接到旧 lib 或旧 exe。

## 2. 构建并验证 Release

- [x] 2.1 用 `CARGO_TARGET_DIR=target/windows cargo build --manifest-path rust/Cargo.toml --target x86_64-pc-windows-msvc --release` 重新构建 Release Rust core。
- [x] 2.2 用 `cmake --build windows/build-windows --config Release --target lithe_windows_qt` 重链接 Release app。
- [x] 2.3 启动 `windows/build-windows/Release/lithe_windows_qt.exe`,观察 git 操作(状态刷新/提交/拉取)不再闪现标题为 git.exe 路径的控制台窗口。
- [x] 2.4 (可选)在 Release 配置下跑 CTest:因本次只构建了 `lithe_windows_qt` target,Release 测试目标未生成,导致部分测试 "Not Run";非代码回归。Debug 全量 CTest 已 28/28 通过,Release app 链接成功。

## 3. 交付

- [x] 3.1 告知用户从 `windows/build-windows/Release/lithe_windows_qt.exe` 启动,确认 Release 路径的 exe 是最新构建。
- [x] 3.2 检查 git diff,确认本次 change 没有新增源代码改动;git diff 中的 `git.rs` 改动来自已实施但尚未提交的 `fix-git-console-flash`,本次只新增 planning 文件。
