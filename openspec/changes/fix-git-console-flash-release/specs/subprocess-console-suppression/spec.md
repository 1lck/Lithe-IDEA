## MODIFIED Requirements

### Requirement: git 子进程在 Windows GUI 宿主下不创建控制台窗口

lithe-core SHALL 在 Windows 平台上以抑制控制台窗口的方式创建 git 子进程,使 git 写入 stdout/stderr 时不触发 Windows 隐式 `AllocConsole`,不弹出独立控制台窗口。**该要求同时适用于 Debug 与 Release 构建产物**。

#### Scenario: git 状态查询在 Release 构建下不闪现窗口

- **WHEN** 使用 Release 构建的 `lithe_windows_qt.exe` 执行 git 状态/查询操作
- **THEN** git 子进程以 `CREATE_NO_WINDOW` 创建,屏幕不闪现标题为 git.exe 路径的控制台窗口

#### Scenario: git 子进程写入输出

- **WHEN** git 子进程向 stdout/stderr 写入内容
- **THEN** 不产生新控制台窗口,输出仍通过管道正常捕获

#### Scenario: 非 Windows 平台行为不变

- **WHEN** 在非 Windows 平台(如 macOS)执行 git 操作
- **THEN** 子进程创建行为与改动前一致,抑制逻辑为无操作

### Requirement: 所有 git 子进程创建统一走抑制路径

lithe-core SHALL 通过同一个构造入口创建所有 git 子进程(执行命令、`run_git`、clone 等),确保 Windows 抑制标志在所有调用点一致生效,**无论构建配置是 Debug 还是 Release**。

#### Scenario: 统一构造入口

- **WHEN** lithe-core 的任何模块创建 git 子进程
- **THEN** 一律经由带 Windows 抑制标志的构造 helper,不存在绕过抑制的直接 `Command::new("git")`
