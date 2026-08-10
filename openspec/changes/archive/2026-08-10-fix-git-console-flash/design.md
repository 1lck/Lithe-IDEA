## Context

`lithe_windows_qt` 是 WIN32 GUI 子系统应用(`windows/CMakeLists.txt:375` `add_executable(lithe_windows_qt WIN32 ...)`),启动时无控制台。lithe-core 通过 `std::process::Command::new("git")` 启动 git.exe——git 是控制台子系统(CUI)程序,写入 stdout/stderr 时,Windows 对由无控制台父进程启动的控制台子进程执行隐式 `AllocConsole`,弹出标题为可执行文件完整路径的控制台窗口。git 操作由 lithe-core 的固定 worker 周期调度(git status watcher 等),因此窗口"时不时"闪现,标题形如 `D:\Claude Code\git\Git\cmd\git.exe`。

现状:
- `rust/lithe-core/src/git.rs`:主 git 执行路径(`:453` `let mut process = Command::new("git")` + `.spawn()`)与 `run_git`(`:2469` 链式 `.output()`)。
- `rust/lithe-core/src/lib.rs`:多段 git clone/操作(`:531`、`:590`、`:897`、`:986`、`:1109`、`:1390`、`:1706`、`:1772`、`:1887`、`:1979`)直接 `Command::new("git")`。
- Windows app 层进程创建已正确: `win32_process_session.cpp:381` 用 `CREATE_NO_WINDOW`,`win32_terminal_transport.cpp:455` 挂伪控制台属性。本 change 不涉及它们。

## Goals / Non-Goals

**Goals:**

- Windows 下 lithe-core 启动的 git 子进程不再闪现控制台窗口。
- 非 Windows 平台(macOS)编译与运行时行为完全不变。
- 用一个集中构造入口覆盖所有 git 子进程创建,避免逐点复制。
- 不改变 git 的执行逻辑、参数、stdin/stdout/stderr 管道捕获方式。

**Non-Goals:**

- 不修改 Windows app 层(`win32_process_session`、`win32_terminal_transport`)——它们已正确处理。
- 不处理 ConPTY 终端会话(已挂伪控制台,无此问题)。
- 不引入新的进程创建抽象或重写 Rust 进程管理。

## Decisions

### 1. 集中构造 helper,而非逐点 `#[cfg(windows)]`

在 `git.rs` 增加 crate 可见的 `git_command()` helper,统一构造 git 子进程:

```rust
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub(crate) fn git_command() -> std::process::Command {
    let mut command = std::process::Command::new("git");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}
```

所有 `Command::new("git")` 调用点(共 13 处)改为 `git_command()`。

**备选方案与理由:**
- 备选 A:在每个调用点用 `#[cfg(windows)]` 加三行。缺点:13 处重复、容易漏掉新调用点,违背"统一抑制路径"的需求。
- 备选 B:用 `cfg!(windows)` 运行时分支在每处执行。缺点:同上,且让非 Windows 分支也携带 Windows 常量。
- 选定:集中 helper,一处定义、全量复用,未来新增 git 子进程天然走抑制路径。

### 2. 常量值来源

`CREATE_NO_WINDOW = 0x08000000` 是 Windows SDK 公开常量(winbase.h),Rust 标准库不导出,用 `const` 定义并注释来源,避免魔法数字。`creation_flags()` 由 `std::os::windows::process::CommandExt` 提供,仅在 `#[cfg(windows)]` 块内导入。

### 3. helper 的位置与可见性

git 专属逻辑放 `git.rs`,标记 `pub(crate)` 使 `lib.rs` 的调用点也能复用。lib.rs 中所有 git 进程创建直接改用 `git_command()`;若未来 lithe-core 需要启动非 git 的 CUI 子进程,再按同样模式抽取通用 helper(本次不做,避免过度设计)。

## Risks / Trade-offs

- **CREATE_NO_WINDOW 影响 git 交互?** → git 的交互提示(如 credential 询问)通过管道 stdin 进行,`CREATE_NO_WINDOW` 只抑制窗口创建,不改变管道 I/O;行为与改动前一致。
- **非 git 的 CUI 子进程未来也可能闪现** → 本次范围仅 git(所有现有 `Command::new` 均为 git)。设计中的 `git_command()` 已体现抑制模式,未来可平移为通用 helper。
- **Windows 特有代码误入共享路径** → helper 内 Windows 分支用 `#[cfg(windows)]` 包住,`CommandExt` 的 import 也在块内;macOS 编译时该分支被剥离,行为不变。
- **回归风险(改动前 git 正常)** → 改动仅新增创建标志,不触碰命令构造、参数、目录与管道;用 Windows CI 的 `cargo test`(git 相关用例)与手动启动验证覆盖。

## Migration Plan

1. 在 `git.rs` 增加 helper,替换 `git.rs` 两处调用点;在 `lib.rs` 替换其余 `Command::new("git")`。
2. 在 Windows 上重新构建 Rust core(`cargo build`),重链接 `lithe_windows_qt`。
3. 验证:启动 app 观察 git 操作不再闪现窗口;`cargo test`(Windows 与跨平台)通过;CTest 回归通过。
4. 回滚:仅 Rust 源码改动,`git revert` 后重建即可;无数据迁移、无 ABI 变化。

## Open Questions

无(根因已由用户观察到的窗口标题确认,修复路径明确)。
