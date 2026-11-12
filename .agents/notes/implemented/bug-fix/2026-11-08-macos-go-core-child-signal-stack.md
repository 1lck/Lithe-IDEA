# Agent 笔记：macOS 上 Go 与 Core 共用子进程信号

状态：已实现

## 先说结论

macOS 的 Go 桌面进程把 Rust Core 静态链接进同一进程。Core Agent 的 Tokio 进程运行时注册 `SIGCHLD`（子进程退出通知）时，处理器必须带 `SA_ONSTACK`，否则它链式调用已有的 Go 信号处理器时，Go 可能直接终止整个进程。桌面链接边界在注册动作发生之前补上该标志；其他信号、忽略和默认处理方式不改变。

## 问题

运行桌面 Core 的全量测试时，启动 Agent 后另一个 Git 子进程退出，进程报告 `non-Go code set up signal handler without SA_ONSTACK flag` 并终止。进程内探针观察到启动 Agent 前 `SIGCHLD` 标志为 `0x43`，启动后为 `0x42`；缺失的是 `SA_ONSTACK`（`0x1`）。固定 Core 中的 Tokio 使用 `signal-hook-registry` 1.4.8，其注册函数使用 `SA_RESTART | SA_SIGINFO` 而没有 `SA_ONSTACK`。该问题与后续 Git 测试本身无关：任意子进程结束都可能发送同一种信号。

## 决策

- `desktop/internal/core/signal_guard_darwin.c` 在 macOS 可执行文件的链接边界包装 `sigaction`。对带实际处理函数的 `SIGCHLD` 注册，只在传给系统之前增加 `SA_ONSTACK`；保留原处理函数、信号掩码及其余标志。查询、默认/忽略处理和其他信号原样交给系统。这样并发子进程不会落在注册后再修改标志的空档里。
- 通过 `RTLD_NEXT` 查找系统实现并用 `pthread_once` 初始化，解析失败时返回系统调用错误。Go 入口引用链接锚点，确保构建正式程序时该对象不被丢弃。该包装只覆盖链接进可执行文件的调用，不保证拦截其他动态库自己的注册；如以后引入会自行注册 `SIGCHLD` 的动态库，必须单独验证。
- 正确做法：测试在真实 Core Agent 启停后查询进程中的信号标志，再启动 Go 和 Core 两侧的 Git 子进程。隔离子进程另验证 `SIGUSR1` 的处理器、掩码与标志不变。不要通过禁用 Go 的信号、重试崩溃或在注册返回之后补设置标志掩盖问题。
- Windows 不使用 POSIX `sigaction`，该文件不参与 Windows 构建。Linux 也有 Go/Rust 同进程边界，但本次没有实现或验证 Linux 的对应保护，不能把 macOS 结果当作 Linux 已通过。

## 考虑过的备选方案

- 等 Agent 启动后再查询并补设 `SA_ONSTACK`：两次系统调用之间仍可能收到子进程退出信号，不能修复竞态。
- 在桌面分支复制或改写 Tokio：会制造另一份外部运行时源码，并要求每次 Core 修订同步；目前保留上游实现，在宿主的原生链接边界保证 Go 所需的注册约束。
- 把 Core 改成独立进程：能隔离信号，但也会改变当前 C ABI、取消和资源生命周期，不适合作为这个缺陷的局部修复。

## 后果

这为链接进当前 macOS 程序的 Core 信号注册增加一条很小的系统调用前检查，避免子进程退出导致的进程级崩溃。它是进程级原生适配，未来升级链接器、Core 或引入新的信号使用方时必须继续运行回归；它不证明其他动态库或 Linux 已经安全。

## 验证

- `./scripts/desktop/desktop-go.sh test -race ./internal/core -run 'TestCoreAgentKeepsGoChildSignalStack|TestSignalGuardLeavesOtherSignalActionsUnchanged' -count=3`
- `./scripts/desktop/desktop-go.sh test ./...`
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`

## 适用范围

- `desktop/internal/core/`
- `scripts/desktop/`
- [Go 信号与非 Go 代码的要求](https://pkg.go.dev/os/signal#hdr-Go_programs_that_use_cgo_or_SWIG)
