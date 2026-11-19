# Agent 笔记：Windows 工具链发现使用文件句柄读取最终路径

状态：已实现

## 先说结论

Windows 工具链发现通过文件句柄读取最终路径。目录联接点（junction，Windows 上把一个目录指向另一位置的重定向）也会被解析，Core 因此能在版本探测前检查实际目录是否仍在工作区内。

## 问题

PR #2175 和桌面主线的 Windows CI 都发现，指向工作区外的环境目录被当作工作区内的环境接受。Go 的 `filepath.EvalSymlinks` 无法完整解析经过联接点的路径。宿主遇到解析失败时，仍可能把原路径作为最终路径交给 Core。[Go #82447](https://github.com/golang/go/issues/82447)

## 决策

- Windows 使用 `GetFinalPathNameByHandleW` 读取系统解析出的路径，再以 Core 已支持的盘符或 UNC 共享路径形式上报。句柄仅用于读取元数据，候选读取结束即关闭。[Windows API 文档](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew)
- 文件或目录候选必须同时有最终路径与匹配的文件类型证据。解析失败时，该路径不能作为文件或目录候选上报。是否允许探测和选择仍由 Core 判定。

## 考虑过的备选方案

- 逐段解析联接点需要维护 Windows 重定向类型、循环和长路径规则。通过已打开的句柄读取最终路径可以复用系统已完成的解析。

## 后果

Core 能区分项目内环境目录和指向外部的目录联接点。无法取得最终路径的候选会被排除。读取发生在工具链发现期间，无需修改工具配置或安装文件。

## 验证

`scripts/desktop/desktop-go.sh test ./internal/toolchain -run '^TestTrustedWorkspaceResolvesSubdirectoryEnvironmentAndRejectsEscapingDirectories$'`。用例同时检查合法的子目录环境可选，以及外部目录联接点返回 `unsafePath` 且没有启动任何探测。macOS 使用目录符号链接执行对应断言。

## 适用范围

- `desktop/internal/toolchain/native_path_windows.go`
- `desktop/internal/toolchain/scan.go`
- `desktop/internal/toolchain/project_trust_test.go`
