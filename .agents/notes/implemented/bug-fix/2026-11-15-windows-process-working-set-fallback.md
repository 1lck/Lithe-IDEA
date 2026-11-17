# Agent 笔记：Windows 内存统计回退到普通工作集

状态：已实现

## 先说结论

Windows 能提供专用工作集时，内存详情使用进程独占且当前在内存中的字节数。服务器系统可能返回普通工作集，同时把专用计数留空。此时宿主展示普通工作集，压缩或换出值交给界面按缺失数据处理。

## 问题

Windows Server 2022 的桌面 CI 中，`GetProcessMemoryInfo` 返回成功后，运行中的宿主和测试进程都被统计成零字节，导致进程统计和工作台内存详情用例失败。调用方以返回值判断扩展计数已填充，漏掉了系统只提供基础计数的情况。[Windows CI 基线](https://github.com/1lck/Lithe-IDEA/actions/runs/43682939259)

## 决策

由 Windows 原生适配器检查系统实际返回的结构长度与工作集字段。扩展结构不完整，或普通工作集非零而专用工作集为零时，采用普通工作集并把 `CompressedBytes` 留空。扩展调用失败时仍用基础结构重试。有效的专用工作集继续参与原有统计，压缩或换出的估算继续以专用提交量减去专用工作集。[Win32 内存计数结构](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex2)

## 考虑过的备选方案

按系统产品名称或构建号选择结构。扩展计数的可用性与实际安装的累积更新有关，适配器可以直接使用调用返回的数据来判断。

## 后果

旧服务器可显示实际驻留内存。普通工作集包含共享页，回退读数可能高于任务管理器的专用工作集列。分组与汇总仍由现有 Core 接口处理。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/sysinfo -run 'TestWindowsProcessMemoryCounters|TestProcessesListsThisProcessAndItsChild'`：在 Windows 验证完整、缩短和缺字段的计数，检查实际运行进程的内存和处理器时间。
- `./scripts/desktop/desktop-go.sh test ./internal/workbench -run TestMemoryDetailsShowTheSummaryOfTheWholeInstance`：验证工作台交给 Core 的宿主行包含内存和处理器时间。

## 适用范围

- `desktop/internal/sysinfo/process_windows.go`
- `desktop/internal/sysinfo/process_windows_test.go`
- `desktop/internal/workbench/memory_monitor_test.go`
- `shared/platform-feature-matrix/features/memory-monitor.json`
