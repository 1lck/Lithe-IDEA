## Context

`fix-git-console-flash` 修改了 `rust/lithe-core/src/git.rs`,给所有 git 子进程统一设置 Windows `CREATE_NO_WINDOW`,并在 Debug 构建中验证通过。但 `lithe_windows_qt` 的 Release 构建使用独立的 `rust/target/windows/x86_64-pc-windows-msvc/release/lithe_core.lib`;该 lib 是修复前编译的,因此 Release exe 仍会触发 git 子进程的隐式 `AllocConsole`,闪现 git 控制台窗口。

Windows CI(`.github/workflows/ci-windows.yml`)默认跑 Release 配置,但用户本地之前的构建仅更新了 Debug 产物。

## Goals / Non-Goals

**Goals:**

- 让 Release 构建的 `lithe_core.lib` 包含 `CREATE_NO_WINDOW` 修复。
- 重链接 Release `lithe_windows_qt.exe`。
- 启动 Release exe 并确认 git 操作不再闪现窗口。

**Non-Goals:**

- 不改动源代码(已在 `fix-git-console-flash` 中完成)。
- 不引入新的 spec 需求或测试用例。
- 不处理 Debug 构建(已验证通过)。

## Decisions

### 1. 使用与 CI 一致的 Release 构建命令

CI 通过 `build-windows.ps1 -Configuration Release` 构建。为了本地快速验证,使用等价的命令序列:

```bash
CARGO_TARGET_DIR=target/windows cargo build --manifest-path rust/Cargo.toml --target x86_64-pc-windows-msvc --release
cmake --build windows/build-windows --config Release --target lithe_windows_qt
```

这与 `build-windows.ps1` 使用相同的 `CARGO_TARGET_DIR` 和 target,避免产物路径不一致。

### 2. 不修改 `build-windows.ps1` 或 CI

脚本本身已支持 Release 配置,问题仅是本地没有重建 Release。因此不需要脚本改动。

### 3. 验证策略

- 先确认 `rust/target/windows/x86_64-pc-windows-msvc/release/lithe_core.lib` 时间戳早于 Debug lib 或源码修改时间,确认它是旧产物。
- 启动 Release exe,观察 git 操作(状态刷新)是否仍闪现 git.exe 窗口。

## Risks / Trade-offs

- **Release 编译耗时较长** → 使用 `--release` 单次构建;不跑完整 `cargo test --release`(Debug 测试已通过,Release 只跑构建和链接)。
- **Release CTest 可能因缺少 offscreen 环境失败** → 视觉验证即可;如需跑 CTest,设置 `QT_QPA_PLATFORM=offscreen` 和 `QT_PLUGIN_PATH`。
- **用户后续仍运行旧 Release exe** → 明确告诉用户从 `windows/build-windows/Release/lithe_windows_qt.exe` 启动。

## Migration Plan

1. 构建 Release Rust core。
2. 重链接 Release app。
3. 启动 Release exe 验证窗口不再闪现。
4. 如需清理旧 Release 产物,删除 `rust/target/windows/x86_64-pc-windows-msvc/release` 和 `windows/build-windows/Release` 中的旧二进制,再重新构建。

## Open Questions

无。
