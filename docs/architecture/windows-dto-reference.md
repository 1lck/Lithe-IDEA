# Rust Core DTO 线格式参考（C++ 编解码用）

30 个命令跨 FFI 边界的完整字段清单，用于编写 C++ 结构体与 JSON 编解码器。
字段名是 Rust `rename_all = "camelCase"` 之后的**实际线上名称**。

规则说明：

- `Option<T>` 且**无** `skip_serializing_if` → 键始终存在，值可为 `null`
- `Option<T>` 且**有** `skip_serializing_if` → 值缺失时**整个键消失**
- `#[serde(default)]` → 请求里可省略

这两种可选性在 C++ 里要区别处理：前者用 `std::optional` 解码但键必须存在，
后者要先判键是否存在。

## FFI 与信封

`rust/lithe-core/include/lithe_core.h`：

```c
const char *lithe_core_version(void);
char *lithe_core_execute_json(const char *request);
int32_t lithe_core_cancel(const char *operation_id);
void lithe_core_free_string(char *value);
```

`lithe_core_version` 返回静态 `"0.1.0"`，**不要 free**。
`lithe_core_execute_json` 返回 Rust 分配的字符串，必须用
`lithe_core_free_string` 释放。请求指针为 null 时返回：

```json
{"id":null,"ok":false,"error":{"code":"invalid_request","message":"Request pointer is null"}}
```

`lithe_core_cancel` 找到活动操作返回 1，否则 0。

### 请求信封

| 字段 | 类型 | 必需 | 默认 |
| --- | --- | --- | --- |
| `id` | `string?` | 否 | null |
| `operationId` | `string?` | 否 | null，缺失时回退到 `id` |
| `timeoutMilliseconds` | `uint64?` | 否 | null |
| `command` | `string` | **是** | — |
| `payload` | any | 否 | null |

### 响应信封

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | `string \| null` | 始终存在 |
| `ok` | `bool` | 始终存在 |
| `data` | any | 为 null 时**键消失** |
| `error` | object | 为 null 时**键消失** |

`data` 是裸载荷对象，没有包装层。

### 错误对象

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `code` | string | 11 个 `snake_case` 值 |
| `message` | string | 用户可读 |
| `details` | `string?` | **普通字符串，不是对象**；缺失时键消失 |

`code` 全部取值：`invalid_request`、`workspace_not_found`、`permission_denied`、
`not_supported`、`runtime_missing`、`process_start_failed`、`process_failed`、
`parse_failed`、`cancelled`、`timed_out`、`unknown`。
未知命令返回 `not_supported`，命令名放在 `details`。

## 数值类型对照

| Rust | 出现位置 | C++ |
| --- | --- | --- |
| `u64` | `timeoutMilliseconds` | `uint64_t` |
| `i32` | `exitCode` | `int32_t`（**有符号**） |
| `i64` | `HistoryEntry.timestamp`、`GitBlameLine.authorTime` | `int64_t`（Unix 秒，有符号） |
| `usize` | 其余全部数值字段 | `uint64_t`（无符号） |

边界上**没有任何浮点字段**，也没有 `u32`。

## core.ping

请求载荷忽略。响应：`protocolVersion`（整数，当前 `1`）、`coreVersion`（string）。

## workspace.snapshot

请求 `WorkspaceSnapshotRequest`：

| 字段 | 类型 | 必需 | 默认 |
| --- | --- | --- | --- |
| `root` | string | **是** | 绝对宿主路径 |
| `hiddenDirectoryNames` | string[] | 否 | `[]` |
| `hiddenFilePatterns` | string[] | 否 | `[]` |

内置隐藏目录（与调用方值合并）：`.git`、`.build`、`.swiftpm`、`node_modules`、
`target`、`build`、`DerivedData`、`.gradle`、`.next`、`dist`、`coverage`、
`design-qa-artifacts`。内置隐藏文件模式：`.DS_Store`。
`MAX_FILE_SIZE = 2 MiB`。

响应：`root`（`WorkspaceNode`）、`files`（string[]，相对路径，`/` 分隔）。

`WorkspaceNode` 递归：`path` string、`name` string、`isDirectory` bool、
`children` `WorkspaceNode[]` —— **为 None 时键完全消失**，文件节点没有这个键，
解码时把"键缺失"当作叶子节点。

## workspace.search / workspace.searchEverywhere

共用 `SearchRequest`：

| 字段 | 类型 | 必需 | 默认 |
| --- | --- | --- | --- |
| `root` | string | **是** | — |
| `query` | string | **是** | — |
| `caseSensitive` | bool | 否 | `false` |
| `wholeWords` | bool | 否 | `false` |
| `regularExpression` | bool | 否 | `false` |
| `maxResults` | uint64 | 否 | **`200`** |
| `maxFileResults` | uint64? | 否 | null（不限） |
| `maxContentResults` | uint64? | 否 | null |
| `maxSymbolResults` | uint64? | 否 | null（仅 searchEverywhere 有意义） |
| `hiddenDirectoryNames` | string[] | 否 | `[]` |
| `hiddenFilePatterns` | string[] | 否 | `[]` |
| `fileMask` | string | 否 | `""`（逗号分隔 glob，如 `*.java, *.kt`） |

响应：`matches`（`SearchMatch[]`）。

`SearchMatch`：`kind` string、`path` string、`line` `uint64?`（**键始终存在**，
可为 null）、`preview` string、`symbolName` `string?`（**缺失时键消失**）。

`kind` 取值：`file`、`content`（来自 `workspace.search`），
外加 `type`、`symbol`（searchEverywhere 的 Java 符号扫描）。
顺序固定为 file、type、symbol、content。

## workspace.replacePreview

`ReplacementPreviewRequest`：

| 字段 | 类型 | 必需 | 默认 |
| --- | --- | --- | --- |
| `root` | string | **是** | — |
| `query` | string | **是** | — |
| `replacement` | string | **是** | — |
| `caseSensitive` | bool | 否 | `false` |
| `wholeWords` | bool | 否 | `false` |
| `regularExpression` | bool | 否 | `false` |
| `preserveCase` | bool | 否 | `false` |
| `fileMask` | string | 否 | `""` |
| `paths` | string[] | 否 | `[]` |
| `textOverrides` | object（键=相对路径） | 否 | `{}` |
| `hiddenDirectoryNames` | string[] | 否 | `[]` |
| `hiddenFilePatterns` | string[] | 否 | `[]` |

响应：`files`（`ReplacementFile[]`）。
`ReplacementFile`：`path` string、`matches`（`ReplacementMatch[]`）、
`replacementText` string（完整新文件内容）。
`ReplacementMatch`：`line` uint64、`before` string、`after` string、
`occurrenceCount` uint64。

`preserveCase` 语义：查询 `fooBar` 替换 `bazQux` 得到
`bazQux BazQux BAZQUX bazQux()`（全大写、首字母大写、其余原样）。

此命令**从不写文件**，调用方自行决定是否先记历史再 `file.write`。

## file.read / file.write

`file.read` 请求：`root`、`path`（工作区相对）均必需。
响应：`path` string、`text` string。

`file.write` 请求：`root`、`path`、`text` 三者均必需。
响应：`path` string、`bytesWritten` uint64。

路径校验（`error.rs::invalid_relative_path`）在把 `\` 归一为 `/` 之后，
拒绝空串、前导 `/`、任何 `:`、NUL、任何 `..` 分段。
符号链接逃逸返回 `permission_denied`，穿越返回 `invalid_request`。

## history.*

`history.record` 请求：

| 字段 | 类型 | 必需 | 默认 |
| --- | --- | --- | --- |
| `workspaceRoot` | string | **是** | — |
| `storageRoot` | string | **是** | — |
| `path` | string | **是** | — |
| `reason` | string | **是** | 见下 |
| `content` | string? | 否 | null → 核心自己读工作区文件 |
| `pruneExpired` | bool | 否 | 有默认 |
| `hiddenDirectoryNames` | string[] | 否 | `[]` |
| `hiddenFilePatterns` | string[] | 否 | `[]` |

`reason` 是校验过的字符串枚举，合法值：`projectBaseline`、`saved`、
`externalChange`、`beforeRename`、`beforeDelete`、`beforeBatchReplace`、
`unsavedDiscard`、`restored`。其余返回 `invalid_request`。

响应是 `HistoryEntryResponse` **或 JSON `null`** —— 快照与上一版重复、
文件被隐藏、内容超 2 MiB 时返回 `data: null` 但 `ok: true`。
**C++ 解码器必须容忍成功响应里的 `data: null`。**

`HistoryEntryResponse`：`id` string（UUID 形状）、`timestamp` **int64**（Unix 秒）、
`relativePath` string、`reason` string、`contentPath` string（相对存储根）、
`byteCount` uint64。

`history.entries` 请求：`workspaceRoot`、`storageRoot` 必需，
`path` `string?`（null = 整个工作区），两个隐藏字段默认 `[]`。
响应：`entries`（`HistoryEntryResponse[]`，最新在前）。

`history.content` 请求：`storageRoot`、`contentPath` 均必需。响应：`{"text": string}`。

`history.relocate` 请求：`storageRoot`、`sourcePath`、`destinationPath` 均必需。
响应：`{"relocated": true}`。

存储约束：每文件最多 100 条，保留 30 天，内部 `HISTORY_VERSION = 2`（不过线）。

## maven.*

`maven.scan` 请求：`root` string 必需。
响应是 `Option<...>` —— 根目录没有可读 `pom.xml` 时 **`data: null`**；
XML 格式错误返回 `parse_failed`。

`MavenScanResponse`：`groupId` `string?`（键存在，可 null）、
`artifactId` string（回退为目录名）、`version` `string?`、`packaging` string、
`modules`（`MavenModuleResponse[]`）、`profiles`（`MavenProfileResponse[]`）、
`hasWrapper` bool。

`MavenModuleResponse` 递归：`relativePath` string、`groupId` `string?`、
`artifactId` string、`version` `string?`、`packaging` string、
`modules`（嵌套同类型数组）。

`MavenProfileResponse`：`id` string、`isActiveByDefault` bool。

`maven.diagnostics` 请求：`root`、`output`（原始构建日志）均必需。
响应：`issues`（`MavenDiagnosticResponse[]`）。
`MavenDiagnosticResponse`：`path` string、`line` uint64、
`column` `uint64?`（键存在可 null）、`severity` string、`message` string。
`severity` 实际取值 `error` 与 `warning`，重复行已去重。

## java.*

`java.runConfigurations` 请求：`root` 必需，`paths` 与 `modulePaths` 默认 `[]`。
响应：`mainClasses`（`JavaMainClassResponse[]`）、
`configurations`（`JavaRunConfigurationResponse[]`）。
`JavaMainClassResponse`：`path`、`qualifiedName`、`simpleName` 均 string，
`isSpringBoot` bool。
`JavaRunConfigurationResponse`：`id` string（如 `spring:com.example.App`）、
`name` string、`kind` string、`modulePath` `string?`、`mainClass` `string?`。
`kind` 取值：`springBoot`、`mavenModule`。

`java.codeVision` 请求：`root`、`targetPath` 必需，`paths` 默认 `[]`。
响应：`hints`（`JavaCodeVisionHintResponse[]`）：
`line` uint64、`utf16Column` uint64、`symbol` string、`usageCount` uint64。

`java.className` 请求：`source`、`simpleName` 必需。响应：`className` string。

`java.sourceDefinition` 请求：`source`、`declarationName` 必需，
`memberName` `string?` 可选。
响应是 `Option<...>` —— 找不到声明时 **`data: null`**。
字段：`line` uint64、`utf16Column` uint64。**零基**（编辑器偏移量）。

`java.serverPort` 请求：`content`、`fileExtension`（如 `yml`）必需。
响应：`port` `uint64?`（键始终存在，解析不出时为 null）。

`java.structure` 请求：`source` 必需，`declarationSources` 默认 `[]`。
响应：`foldRegions`、`implementationMarkers`、`inlayHints`。
`JavaFoldRegionResponse`：`kind` string、`startLine` uint64、`endLine` uint64、
`hiddenStart` uint64、`hiddenLength` uint64。
`kind` 取值：`imports`、`comment`、`type`、`method`、`block`。
`JavaImplementationMarkerResponse`：`line`、`utf16Column`、
`implementationCount` 均 uint64，`direction` string（`down` 或 `up`）。
`JavaInlayHintResponse`：`line` uint64、`utf16Column` uint64、`label` string。

`java.structure` 与 `java.codeVision` 的行号**全部零基**。

## git.*

### git.status

请求：`root` 必需。
响应：`repositoryRoot` `string?`（可 null；工作区是仓库子目录时为绝对路径，
否则 `"."`）、`branch` `string?`（游离 HEAD 时 null）、`changes`（`GitChange[]`）。

`GitChange`：`path` string、`originalPath` `string?`（**缺失时键消失**）、
`status` string、`staged` bool、`worktree` bool、`untracked` bool。

`status` 是 **2 字符 porcelain XY 对**（如 `??`、` M`、`M `、`R `），
不是封闭枚举，按两个字符解析。推导规则：
`staged = x != ' ' && x != '?'`、`worktree = y != ' ' && y != '?'`、
`untracked = x == '?' && y == '?'`。`R`/`C` 的重命名源放在 `originalPath`。

### git.command

请求：`root` 必需，`arguments` string[] 默认 `[]`，`input` `string?`（stdin）。
响应 `GitCommandResponse`（`git.command` / `git.write` / `git.apply` 共用）：
`output` string（stdout+stderr 合并）、`exitCode` **int32 有符号**。
**进程成功启动即 `ok: true`，即使 git 退出码非零。**

### git.write

请求：`root`、`operation` 必需；其余全部可选：
`paths` string[] `[]`、`reference` `string?`、`referenceKind` `string?`、
`revision` `string?`、`name` `string?`、`message` `string?`、`remote` `string?`、
`destination` `string?`、`mode` `string?`、`includeUntracked` bool `false`、
`checkout` bool `false`、`amend` bool `false`。

`operation` 全部取值：`stage`、`unstage`、`discard`、`stageAll`、`commit`、
`cherryPick`、`revert`、`reset`、`createBranch`、`renameBranch`、`deleteBranch`、
`merge`、`rebase`、`fetch`、`pull`、`push`、`checkout`、`checkoutRevision`、
`clone`、`stashPush`、`stashApply`、`stashPop`、`stashDrop`。

`reset` 的 `mode`：`--soft`、`--mixed`、`--hard`，null 时默认 `--mixed`，
其余返回 `invalid_request`。
`checkout` 的 `referenceKind`：`local`、`remote`、`tag`。
`clone` 用 `remote` 作源、`destination` 作目标。

### git.diff

| 字段 | 类型 | 必需 | 默认 |
| --- | --- | --- | --- |
| `root` | string | **是** | — |
| `pathspecs` | string[] | **是** | 无默认，省略即反序列化失败 |
| `reference` | string? | 否 | null |
| `commit` | string? | 否 | null |
| `staged` | bool | 否 | `false` |
| `untracked` | bool | 否 | `false` |
| `contextLines` | uint64 | 否 | **`80`** |
| `ignoreAllWhitespace` | bool | 否 | `false` |

`pathspecs` 是唯一没有 `#[serde(default)]` 的数组字段。

响应：`patch` string、`rows`（`GitDiffRowResponse[]`）、
`hunks`（`GitDiffHunkResponse[]`）。

`GitDiffRowResponse`：`oldLine` `uint64?`、`newLine` `uint64?`、
`left` `string?`、`right` `string?`（**唯一会消失的键**）、`kind` string、
`hunkId` `uint64?`→实际是 `string?`（键存在可 null）。

`kind` 取值：`changed`、`removal`、`addition`、`information`、`context`。
`context` 与 `information` 两侧文本相同所以 `right` 省略，
客户端必须回退到 `left`。

`GitDiffHunkResponse`：`id` string（`hunk-0`、`hunk-1`…）、`header` string、
`patch` string。行不会按 hunk 重复，客户端按 `hunkId` 分组 `rows`。

> **注意大小写**：契约文档写的是 `hunkID`，但线上实际是 **`hunkId`**。
> macOS Swift 侧因为这个不匹配导致分块暂存功能实际失效
> （详见 [runtime-design](windows-runtime-design.md) 第四节）。C++ 侧用 `hunkId`。

### git.history

请求：`root` 必需，`reference` `string?`（null → `--all`），
`limit` uint64 默认 **`300`**，核心钳制到 `1..=5000`。
响应：`references`（`GitReferenceResponse[]`）、`commits`（`GitCommitResponse[]`）、
`hasMore` bool。

`GitReferenceResponse`：`fullName` string、`shortName` string、`kind` string、
`isCurrent` bool、`upstreamShortName` `string?`。
`kind` 取值：`local`（refs/heads/）、`remote`（refs/remotes/）、`tag`（其余）。
以 `/HEAD` 结尾的引用被过滤掉。

`GitCommitResponse`：`hash`、`shortHash` string、`parentHashes` string[]、
`authorName`、`authorEmail` string、`date` string
（**预格式化 `%Y/%m/%d %H:%M`，不是时间戳**）、`subject` string、
`decorations` string。

### 其余 git 命令

`git.commit` 请求：`root`、`commit` 必需。响应：`commit`（单个
`GitCommitResponse`，**嵌套一层**）。

`git.commitFiles` 请求：`root`、`commit` 必需。响应：`files`（`GitFileResponse[]`）。
`GitFileResponse`：`status` string（`--name-status` 字母）、`path` string。

`git.comparison` 请求：`root` 必需、`reference` **必需且非可选**
（与 `git.history` 不同）。响应：`files`（`GitFileResponse[]`）。

`git.stashes` 请求：`root` 必需。响应：`stashes`（`GitStashResponse[]`）：
`reference` string（`stash@{0}`）、`message` string、`branch` `string?`、
`date` string（ISO）。

`git.blame` 请求：`root`、`path` 必需。响应：`lines`（`GitBlameLineResponse[]`）：
`line` uint64（**一基**）、`commitHash` string、
`authorName` string（缺省 `"Unknown"`）、`authorTime` **int64** Unix 秒，
`0` 表示工作树。

`git.apply` 请求：`root`、`patch`、`mode` 均必需。
`mode` 取值：`stage`、`unstage`、`discard`。响应为 `GitCommandResponse`。

## 命令覆盖核对

`command.rs` 的 `CoreCommand::parse` 与
`shared/contracts/rust-core-api.md` 的表格**完全一致，30 个命令双向无缺口**。

## event.rs 不过线

13 行，`lib.rs` 有 re-export 但 `ffi.rs` 与 `runtime.rs` 从不构造或发送。
**C ABI 里没有事件/回调通道**，C++ 侧暂不实现。
若将来启用，形状是 `{"type": "...", "payload": {...}}`，
变体为 `workspaceLoaded`、`searchCompleted`、`gitStatusChanged`、
`fileChanged`、`operationFailed`。
