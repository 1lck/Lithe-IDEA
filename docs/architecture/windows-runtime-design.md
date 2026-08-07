# Windows 端运行时设计

线程模型、取消、路径、编码、错误映射的设计决策。这些是返工代价最高的部分，
必须在写第一行功能代码之前定下来。

配套文档：[开发计划](windows-development-plan.md)、
[适配层审计](windows-adapter-audit.md)、[DTO 契约](windows-dto-reference.md)。

## 一、线程模型

### 硬约束：Rust 取消作用域是线程局部的

`rust/lithe-core/src/cancellation.rs` 的注册表是 `static OnceLock<Mutex<HashMap<..>>>`，
但**每操作状态是 `thread_local!`**。这推出两条不可违反的规则：

1. **核心调用不能跑在会迁移任务的线程池上。** 如果一个操作在 A 线程注册、
   在 B 线程继续，取消就失效。必须用固定的工作线程，而不是
   `QThreadPool` / `std::async` 那种任务可能被任意工作线程取走的模型。
2. **发起取消的线程必须不同于执行线程。** 取消是从 UI 线程调 `lithe_core_cancel`，
   由执行线程在命令边界自行观察。

### 选定的模型：GUI 线程 + 固定核心工作线程池

```
GUI 线程（Qt 主线程）
  ├─ 所有 UI 与特性模型状态，唯一可变状态所在地
  ├─ 发起命令：生成 operationId，投递到核心线程
  └─ 取消：直接调 lithe_core_cancel(operationId)

CoreWorker 线程（N=4，固定，不迁移）
  ├─ 每个线程有自己的 QObject + 事件循环
  ├─ 一个命令在一个线程上从头执行到尾（满足 thread_local 约束）
  └─ 结果经 queued signal 回 GUI 线程

进程读取线程（每流一个）
  ├─ stdout / stderr / ConPTY 各自独立
  ├─ 增量 UTF-8 解码 + 行/帧切分在这一层做
  └─ 经 queued signal 回 GUI 线程
```

线程亲和性的实现方式：命令按 `operationId` 哈希到固定槽位，或者为长任务
（工作区扫描、Git 历史）分配专用线程。绝不用 `QtConcurrent::run`。

macOS 侧不是这个模型 —— 它是 `@MainActor` 加短命的 `Task.detached`，
FFI 调用在协作线程池上并发发生，没有任何锁。Rust 是线程安全的所以能工作，
但取消从来没真正生效过（见下）。Windows 侧不照抄这一点。

### macOS 侧的取消是空转，不要照抄

两个实测事实：

- `RustCoreBridge.executeResult` 内部用 `UUID().uuidString` 生成 id
  且**从不返回给调用方**，所以没有任何调用方能取消请求。
  `cancel(operationID:)` 有定义，零调用点。
- `timeoutMilliseconds` 永远是 `nil`，核心的协作式截止时间完全未启用。

Swift 侧的"取消"全靠丢弃结果实现。Windows 侧必须做对：

```cpp
// 调用点生成并持有 id，这样取消才可能
struct CoreCall {
    std::string operationId;   // 调用方生成，UUID
    std::optional<uint64_t> timeoutMs;
};
```

约定的超时值（macOS 无先例，这里新定）：交互式命令 5s，
工作区扫描与搜索 30s，Git 历史 30s，无超时的只有 `core.ping`。

### 陈旧结果的丢弃

macOS 有三套互不相干的机制，Windows 侧统一成一个。

`CoreCall` 之上加一层 `Generation`：

```cpp
template <typename T>
class Generational {
    uint64_t current_ = 0;
    uint64_t begin() { return ++current_; }        // 发起时取号
    bool isCurrent(uint64_t g) const { return g == current_; }
};
```

发起时取号，结果回到 GUI 线程后先比对，不匹配直接丢弃 **并且清理 loading 标志**。

macOS 有一个必须避开的缺陷：`WorkspaceFeatureModel.swift:155` 的 stale 分支
在清 `isLoadingWorkspace` / `isRefreshingWorkspace` **之前**就返回了，
工作区切换正好落在扫描中途会让转圈图标一直挂着。Windows 侧的 stale 分支
必须走统一的清理路径。

### 防抖间隔表

照搬 macOS 实测值，`*` 标记的是 Windows 侧新增或改动：

| 毫秒 | 位置 | 用途 |
| --- | --- | --- |
| 250 | 文件内查找 | 输入防抖 |
| 180 | Search Everywhere | 输入防抖 |
| 350 | 目录监听批次 | 事件合并 |
| 250 | 监听器自身延迟 | OS 级合并（与上一条叠加，最坏约 600ms） |
| 150 | 会话持久化 | 写盘防抖 |
| 450 | code vision + inlay hints | 击键后延迟 |
| 1500 | 自动保存 | 默认关闭 |
| 900/1800/2700 | inlay hints 重试 | 三次退避后走 fallback |
| 2000 | 提示消息 | 自动消失 |
| 530 | 终端光标 | 闪烁 |
| 5000 | JDWP attach 兜底 | 见调试阶段 |
| 900 | jdb 稳定延迟 | 见调试阶段 |
| 86400s | 更新检查 | 节流 |
| 50 | 下载进度 | 发布节流 |
| **300** * | **LSP didChange** | **macOS 缺失，必须新增** |
| **200** * | **Git 刷新** | **macOS 缺失，必须新增** |

后两条是 macOS 的实际缺陷。`JavaLanguageService.swift:358` 在每次按键都
同步发全文 `didChange`，`AppModel.swift:816` 还是在 450ms 睡眠**之前**调的，
所以 JDT LS 每个字符都收一次完整缓冲区。`GitFeatureModel.swift:104` 的
`refreshGit` 只有一个重入标志，冲突时直接丢弃调用而不是合并。
Windows 侧两处都加真正的防抖。

## 二、路径与编码

### 单一归一化入口

macOS 把绝对→相对的转换**复制了五遍**（`AppModel.swift:804`、
`DocumentFeatureModel.swift:399`、`JavaFeatureModel.swift:348`、
`ProjectHistoryFeatureModel.swift:360`、`JavaCodeVisionService.swift:40`、
`LocalHistoryService.swift:128`、`GitService.swift:233`、
`RustJavaMavenOperations.swift:108`），而 `FileVisibilityRules.swift:81`
还是一份语义不同的版本（失败时回退到文件名而非 nil）。

Windows 侧只允许一个入口：

```cpp
class WorkspacePaths {
public:
    explicit WorkspacePaths(std::filesystem::path root);
    // 绝对 → 工作区相对，`/` 分隔；不在工作区内返回 nullopt
    std::optional<std::string> toRelative(const std::filesystem::path&) const;
    // 工作区相对 → 绝对，输入必须是 `/` 分隔
    std::filesystem::path toAbsolute(std::string_view relative) const;
    bool contains(const std::filesystem::path&) const;
private:
    std::filesystem::path root_;  // QDir::cleanPath 语义，不解析符号链接
};
```

归一化用词法清理（对应 Swift 的 `standardizedFileURL`），**不做符号链接解析**。
macOS 侧 `resolvingSymlinksInPath()` 只在三处非工作区身份的地方出现，
保持一致；要改是独立议题。

### 类型上区分文件路径与 Git 引用

macOS 侧两者都是 `String`，导致 16 处硬编码 `/` 分隔符里，
有些是文件路径（Windows 要变 `\`），有些是 Git refname（`origin/main`，
**必须保持 `/`**）。混在一起迟早出错。

```cpp
class RelativePath { std::string value_; };   // 始终 `/`，用于核心通信
class GitRef       { std::string value_; };   // 始终 `/`，与分隔符无关
// 本地文件系统路径用 std::filesystem::path，允许 `\`
```

### 已知的 Windows 破坏点

`RustCoreBridge.swift:527` 与 `RustJavaMavenOperations.swift:52` 用
`repositoryRoot.hasPrefix("/")` 判断绝对路径：

```swift
let root = repositoryRoot.hasPrefix("/")
    ? URL(fileURLWithPath: repositoryRoot)
    : workspaceURL.appendingPathComponent(repositoryRoot)
```

`C:\...` 永远不匹配 `/`，会被当成相对路径拼到根上。
`OutputTextView.swift:161` 同样问题。Windows 侧的绝对路径判断必须用
`std::filesystem::path::is_absolute()`，不能看首字符。

核心侧是安全的 —— `error.rs:54` 的 `invalid_relative_path` 会先
`replace('\\', "/")` 再校验，`git.rs:1107`、`java.rs:822`、`history.rs:260`
同样做了防御性归一化。问题全在应用层。

### 行号与列号：单一转换点

契约里有两套约定共存：

- 一基行号：`git.blame`、`workspace.search`、`maven.diagnostics`
- **零基行号**：`java.structure`、`java.sourceDefinition`、`java.codeVision`
  （这些是编辑器偏移量）

macOS 把减一操作散在七个文件里（`AppModel.swift:980` 还是无保护的
`line - 1`，核心返回 0 会下溢成 -1）。这是移植中最容易出 off-by-one 的地方。

Windows 侧在解码边界一次性归一到内部类型，之后禁止任何裸算术：

```cpp
struct EditorPosition {           // 内部表示：零基行 + UTF-16 列
    uint64_t line = 0;
    uint64_t utf16Column = 0;

    static EditorPosition fromOneBased(uint64_t line, uint64_t col);  // 带下溢保护
    static EditorPosition fromZeroBased(uint64_t line, uint64_t col);
    uint64_t displayLine() const { return line + 1; }
};
```

UTF-16 列在 Qt 上是天然契合的 —— `QString` 本身就是 UTF-16，
对应 AppKit `NSString`/`NSRange` 的语义，不需要转换。

### 增量 UTF-8 解码必须在适配层

macOS 适配层对每个 `availableData` 块直接
`String(decoding: data, as: UTF8.self)`，多字节序列跨读取边界会被替换成
U+FFFD，且部分行原样发出。缓冲全在下游各自 ad hoc 处理。

Windows 侧把增量解码器和行/帧切分放进适配层，这比现状严格更好：

```cpp
class IncrementalUtf8Decoder {
    std::string pending_;   // 保留不完整的尾部多字节序列
public:
    std::string feed(std::span<const std::byte>);
};
```

LSP 的 `Content-Length` 帧重组同样在适配层，而不是让上层去拼 `Data` 块。

另外 `RawProcessSession` 的 stdout 与 stderr 是两个独立处理器，
**交错顺序无保证**。这一点照搬（合并会破坏 LSP 的 stderr 诊断分离），
但要在文档里写明，上层不得假设顺序。

## 三、错误映射

### 核心错误信封

`error.rs` 的 `details` 是 **`Option<String>`，一个普通字符串**，不是对象。
11 个错误码用 `snake_case`：`invalid_request`、`workspace_not_found`、
`permission_denied`、`not_supported`、`runtime_missing`、`process_start_failed`、
`process_failed`、`parse_failed`、`cancelled`、`timed_out`、`unknown`。

### macOS 侧大量吞错误，Windows 不照抄

`RustCoreBridge` 的通用路径是 `execute`，实现是
`try? executeResult(...).get()` —— 错误直接变 `nil`。
只有 `gitCommandResult` / `gitWriteResult` / `gitApplyResult` 三个用了
带错误的变体。也就是说搜索失败、文件读失败、工作区扫描失败在 UI 上
都表现为"没有结果"，用户看不到原因。

Windows 侧统一用 `expected` 风格，调用方必须显式处理：

```cpp
template <typename T>
using CoreResult = std::expected<T, CoreError>;

struct CoreError {
    ErrorCode code;                        // 强类型枚举，11 个值
    std::string message;                   // 核心给的用户可读文本
    std::optional<std::string> details;    // 平台细节，只进日志
};
```

`cancelled` 与 `timed_out` 不弹提示（前者是用户意图，后者由发起方决定重试）；
其余九个走统一的提示通道并把 `details` 写日志。

### 每适配器都要有错误通道

`DirectoryChangeSource` 现在**没有错误回调**，`start()` 失败就静默返回。
所有端口都要补上错误出口，这是审计里反复出现的同一个问题。

## 四、必须修复的两个上游 bug（Windows 侧不要复制）

### 1. `hunkID` 大小写不匹配 —— 分块暂存实际是死的

Rust 的 `hunk_id` 经 `rename_all = "camelCase"` 序列化为 **`hunkId`**，
而 `RustCoreBridge.swift:341` 声明的是 `let hunkID: String?`（大写 D）。
因为是 Optional，`Decodable` 不抛错，只是每一行的 `hunkID` 都静默为 `nil`。
后果是真实的：`DiffReviewView.swift:544` 的
`diffHunks.first(where: { $0.id == hunkID })` 永远匹配不上，
**经 Rust 路径的分块暂存功能是死的**。

Windows 侧读 `hunkId`。macOS 侧这个 bug 属于本次范围之外，
登记到缺口表，由 macOS 维护者决定修法（加 `CodingKeys` 或改名）。

### 2. 工作区 stale 分支漏清 loading 标志

见前文第一节。Windows 侧的 stale 处理走统一清理路径。

## 五、`KeyValueStore` 需要类型化

`AppSettings.swift` 用到 `Double`、`Int`、`Bool`、`stringArray`、`data`，
而 C++ 端口只有 `std::string`。现有 `win32_key_value_store` 还有
sanitize 冲突（`a/b`、`a\b`、`a:b` 都映射到 `a_b.value`）和非原子写。

设计：一键一 JSON 文件，值用 JSON 类型承载，写入走
`win32_file_system` 已经做对的原子写路径（同目录临时文件 +
`FlushFileBuffers` + `MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH)`），
键名用十六进制转义而非字符替换以避免冲突，目录用
`SHGetKnownFolderPath(FOLDERID_RoamingAppData)` 而非 `getenv("APPDATA")`。
