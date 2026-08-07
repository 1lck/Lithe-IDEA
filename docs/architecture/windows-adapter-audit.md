# Windows 现有适配层审计

对 `windows/` 现有 1,521 行 C++ 的逐文件审计结论。本文档是
[windows-development-plan.md](windows-development-plan.md) 阶段 0 的输入。

**总体判断**：不是骨架，多数适配器有真实 Win32 调用，但属于一次性初稿，
存在若干在负载下必然暴露的正确性缺陷，且有一个文件从未在 Windows 上编译过。
进程 / 终端 / 运行时 / 键值四个适配器目前**没有任何 UI 代码在用**
（`workbench_window.cpp` 只引用 `CoreClient` 与 `DirectoryChangeSource`）。

## 必须重写而非修补

### win32_terminal_transport.cpp —— 从未编译过

ConPTY 握手本身写得正确（`CreatePseudoConsole` / `ResizePseudoConsole` /
`InitializeProcThreadAttributeList` + `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` /
`STARTUPINFOEXW`），但第 9 行 `#include <winconpty.h>` —— **这个头文件在
Windows SDK 里不存在**。ConPTY 在 `<consoleapi.h>`，经 `<windows.h>` 引入，
要求 `_WIN32_WINNT >= 0x0A000006` 与 SDK 10.0.17763+。

另有多处泄漏路径（第 98、101、112 行的 `return` 泄漏管道句柄和 `HeapAlloc`
的属性列表），且不调用退出回调 —— UI 会永久等待一个永不启动的终端。

### win32_process_session.cpp —— 三类数据竞争 + 无进程树终止

真实实现：三个 `CreatePipe`、`SetHandleInformation`、`STARTUPINFOW` +
`STARTF_USESTDHANDLES`、`CreateProcessW(CREATE_NO_WINDOW)`。
参数引用的反斜杠加倍处理（第 23-37 行）是正确的。

但有四个必须修的问题：

1. **没有 JobObject。** 全树零命中 `CreateJobObject` / `AssignProcessToJobObject`。
   `TerminateProcess` 只杀直接子进程 —— 杀掉 `mvn.cmd` 会留下 `java.exe` 孤儿。
   对一个要跑 Maven 的 IDE 来说这是最严重的缺失。
2. **`state->input` / `state->process` 跨线程无锁读写。**
   第 111 行工作线程写 `impl_->input` 不持锁，而 `send()` 在第 192 行持锁读；
   第 138 行写 `state->process`，第 205 行 `stop()` 读。都是 UB 且都可达。
   第 180 行工作线程 `CloseHandle(state->input)` 同样不持锁 —— `send()` 可能写已关闭句柄。
3. **无法只关 stdin 而不杀进程。** `ProcessSession` 没有 `closeInput()`。
   任何等 EOF 的子进程会永久挂起。`git.rs` 的 `GitCommandRequest.input`
   走 stdin 传提交信息，这条路径受影响。
4. **`environment` 字段声明了但从未读取。** `CreateProcessW` 的 `lpEnvironment`
   传 `nullptr`，所有 `JAVA_HOME` / `MAVEN_OPTS` 覆盖被静默丢弃。

另外超时循环会为一次终止发两个 `Stopping` 事件而永不发 `Finished`，
`Win32ProcessRunner` 会因此永久等待；退出码 124 随后又被 `GetExitCodeProcess` 覆盖。
子进程输出未做 UTF-8 解码，多字节序列跨 4096 字节读取边界会损坏。

### win32_directory_watcher.cpp —— 同步 IO + 无防抖

`ReadDirectoryChangesW` 递归监听是真的，但：

- **同步而非重叠 IO**（最后两个参数是 `nullptr, nullptr`）。创建了 `stopEvent`
  但**没有任何地方等待它**，纯粹是死代码。
- **`CancelSynchronousIo(native_handle())` 在 `join()` 之前调用是 use-after-free 竞态**；
  线程已退出时 `native_handle()` 是失效句柄。
- **无防抖、无合并。** 每批变更直接触发回调，Qt 侧每批都重跑一次完整
  `workspace.snapshot`。Maven 构建touch `target/` 会产生数千次回调 —— 这是
  实践中最糟的缺陷。
- 路径是相对监听根的 UTF-16 片段、`\` 分隔符，直接转 UTF-8 未归一化，
  消费方拿到 `src\main\Foo.java`。
- `record->Action` 完全被忽略（增/删/改/重命名不区分）。
- 无 `ERROR_NOTIFY_ENUM_DIR` 处理，缓冲区溢出时静默丢变更且不重新同步。
- 无长路径前缀；根路径超 `MAX_PATH` 时 `start()` 静默返回
  —— `DirectoryChangeSource` 根本没有错误回调通道。

### win32_runtime_locator.cpp —— 最接近 stub

只扫 `%JAVA_HOME%` / `%MAVEN_HOME%` 环境变量加 `SearchPathW` 查 PATH。
**零注册表调用**（全树无 `RegOpenKeyEx`）。不看
`HKLM\SOFTWARE\JavaSoft\JDK`、Adoptium/Temurin 键、WOW6432Node，
不扫 `C:\Program Files\Java`、`\Eclipse Adoptium`、`\Microsoft\jdk`。

**`version` 永远是空的** —— 没有任何地方跑 `java -version`，IDE 无法区分 JDK 8 和 21。
返回类型是 `vector` 但最多只返回一个候选，JDK 选择器没法用。
第 21 行 `std::wstring(name.begin(), name.end())` 是逐字节加宽而非 UTF-8 转换。

## 可保留但需加固

### win32_file_system.cpp —— 七个里最扎实的

原子写正确：同目录临时文件 + `FlushFileBuffers` + `MoveFileExW(REPLACE_EXISTING |
WRITE_THROUGH)`，每条失败路径都清理临时文件。路径转换用
`MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS)`，严格，好。

需要修：

- **`readUtf8` 名不副实** —— 内容按裸字节处理，无 BOM 剥离、无 UTF-16 探测。
  UTF-16LE 的 Java 文件读出来是乱码。
- 64 MiB 读取上限与 Rust `workspace.rs` 的 `MAX_FILE_SIZE = 2 MiB` 不一致，两层限制矛盾。
- `remove()` 只用 `DeleteFileW`，对目录和只读文件失败（未清 `FILE_ATTRIBUTE_READONLY`）。
- `move()` 传了 `MOVEFILE_COPY_ALLOWED` 但没传 `MOVEFILE_REPLACE_EXISTING`，
  跨卷移动到已存在文件会失败。
- `winError()` 返回 `"Win32 error 5"` 这种裸数字，没有 `FormatMessageW`，UI 无法展示。
- `wide()` 对空输入和转换失败都返回 `{}`，非法 UTF-8 路径会静默变成 `CreateFileW("")`。
- 无长路径支持（无 `\\?\` 前缀，无 `longPathAware` 清单）。

### win32_key_value_store.cpp —— 是文件不是注册表

零 Win32 调用，纯 `std::filesystem`。存 `%APPDATA%\Lithe\state\<key>.value`，
一键一文件。用文件而非注册表是合理选择，但类名有误导性。

需要修：

- **sanitize 冲突**：`a/b`、`a\b`、`a:b` 都映射到 `a_b.value`。
- **Windows 上写入非原子**：先 `remove` 再 `rename`，中间崩溃会丢值。
  讽刺的是同目录的 `win32_file_system` 做对了。
- 用 `std::getenv("APPDATA")` 而非 `SHGetKnownFolderPath`，
  非 ANSI 用户名下会出问题。
- **无锁**，两线程并发 `write()` 会在同一 `.tmp` 路径上交错。
- **类型不足**：`AppSettings.swift` 需要 Double / Int / Bool / stringArray / data，
  而 C++ 端口只有 `std::string`。必须加类型化访问器或 JSON 信封。

### win32_process_runner.cpp

36 行，委托给 session 并等条件变量。逻辑经推演是正确的，
但 `condition.wait` 无超时 —— 若工作线程被杀或读取线程阻塞会永久挂起。
应改为 `wait_for` 并有明确的超时错误。

## 上游发现：Swift 侧的取消是空转

审计 macOS 侧时发现两个与设计直接相关的事实，Windows 侧不应照抄：

1. **`operationId` 不可观测。** `RustCoreBridge.executeResult` 内部用
   `UUID().uuidString` 生成 id 并且从不返回给调用方，所以**没有任何调用方能取消请求**。
   `cancel(operationID:)` 有定义，零调用点。Swift 侧的"取消"全靠丢弃结果实现。
2. **`timeoutMilliseconds` 永远是 `nil`。** 核心的协作式截止时间机制完全未启用。

Windows 侧必须在调用点生成 id 并回传，让取消真正可用。

## 上游发现：Rust 取消作用域是线程局部的

`rust/lithe-core/src/cancellation.rs` 的注册表是
`static OnceLock<Mutex<HashMap<..>>>`，但**每操作状态是 `thread_local!`**。

这对 C++ 侧的线程模型是硬约束：**不能把核心调用放在会迁移作用域的线程池上**。
取消要生效，执行线程必须稳定，且发起取消的线程必须不同于执行线程。
这一条直接决定了下一节的线程设计。

## 结论对计划的影响

阶段 0 的"补齐端口骨架"要改成"重写三个 + 加固两个"：

| 适配器 | 处置 |
| --- | --- |
| `win32_terminal_transport` | 重写（头文件错误 + 泄漏 + 竞态） |
| `win32_process_session` | 重写（JobObject + 竞态 + closeInput + environment） |
| `win32_directory_watcher` | 重写（重叠 IO + 防抖 + 动作区分 + 错误通道） |
| `win32_runtime_locator` | 重写（注册表 + 版本探测 + 多候选） |
| `win32_file_system` | 加固（编码 + 目录删除 + 跨卷移动 + 错误文本 + 长路径） |
| `win32_key_value_store` | 加固（原子写 + 类型化 + 锁 + KnownFolder） |
| `win32_process_runner` | 加固（`wait_for` 超时） |
