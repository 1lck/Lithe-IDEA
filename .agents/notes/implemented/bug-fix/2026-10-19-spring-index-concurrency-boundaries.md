# Agent 笔记：Spring 索引的并发与取消边界

状态：已实现

## 先说结论

持续编辑大项目时，Windows 端以前会为每一次编辑派发一份完整的 Spring 全量索引。
一份索引还没跑完，下一份已经开始，多个请求同时占住 Tauri 的后台线程并各自读取
整个工作区，导致 CPU、线程数和私有内存一起放大。

现在只有三层边界：前端同一工作区最多一个索引在途；Core 对同一个依赖仓库的扫描
只允许一个执行者；扫描过程会检查取消和超时。切换工作区或关闭页面时会取消已经
派发的 Core 请求，不再让它跑完后再丢弃结果。

## 问题

现场报告（Issue #1155）中，主进程有 189～220 个线程、约 10 个核心的持续负载和
约 8 GiB 私有内存；采样的繁忙线程大多停在
`spring_index -> repository_metadata -> scan_repository_metadata`。

源码上的放大链路有三段：

1. `windows/tauri/src/features/spring/hooks/use-spring-index.ts` 只有 300ms
   防抖。防抖到期后直接开始扫描，不检查上一份是否结束。一次大项目索引通常远超
   300ms，所以持续输入会不断追加并发请求。effect 清理只设置 `cancelled`，
   旧请求仍会跑完。
2. Windows 的 `core_execute` 用 `spawn_blocking` 执行 Core 命令。每个并发请求
   占一个后台线程，多个请求就是多个同时扫描的线程。
3. `rust/lithe-core/src/languages/spring.rs` 的依赖仓库缓存只在扫描完成后回填。
   多个请求同时未命中或同时要求刷新时，会各自重新打开 Maven 仓库里的归档。
   扫描内部也没有取消检查，前端传入的 30/60 秒超时只能在命令前后判断。

这三段叠加后，问题不是内存泄漏，而是并发请求把同一份全量计算和结果复制了多份。

## 决策

### 前端：一次在途，合并后续触发

`use-spring-index` 用一个 `inFlight` 标记和一个 `pendingLoad` 槽位组织扫描：

- 有请求在途时，新的编辑、文件监听或 Java 就绪事件只记录一次待执行刷新，
  `refreshDependencyMetadata` 标志按“或”合并。
- 当前请求结束后，如果有待执行刷新，最多再跑一轮，使用当时最新的缓冲区内容。
- 切换工作区或卸载时设置 `cancelled`，并调用 `cancelCoreOperation` 取消已经
  派发的请求。清理先设置 `cancelled` 再取消请求，所以主动取消在 `cancelled`
  检查处直接返回，不写入失败状态。不能按错误码 `cancelled` 一律忽略：不是本 hook
  发起的取消如果也被忽略，阶段会一直停在 `loading`。

请求 ID 直接使用 Core 请求里的 `id`。`dispatcher` 已经把它注册为 operation，
现有 `core_cancel` 命令即可取消，不需要新增协议字段。

### Core：协作式取消

取消是协作式的：工作线程必须在合适的位置主动检查。Spring 索引在以下循环中
调用共享的 `cancellation::check()`：

- `spring_index` 的元数据、Java 源码和应用配置路径循环；
- `scan_repository_metadata` 的目录循环；
- `append_archive_metadata` 的每个归档；
- `append_configuration_properties`、`property_reference_index`、`bean_index`、
  `endpoint_index` 的每个源码输入。

检查粒度是“每个文件或每个归档”，不是每一行，避免在正常扫描里引入明显的原子
读取开销。取消或超时返回稳定的 `cancelled` / `timed_out` 错误码。

### Core：依赖仓库扫描 single-flight

“single-flight” 指同一份工作只让一个执行者做，其他调用者等待并复用结果。
`REPOSITORY_METADATA_CACHE` 的值从结果向量改成一个带 `Mutex + Condvar` 的槽位：

- 第一个未命中的请求成为扫描者，其他请求等待同一个结果。
- 等待者每 50ms 醒来检查一次取消，避免被取消的请求一直占着后台线程。
- 扫描者在取消、失败或异常退出时把状态标记为 `Failed` 并唤醒等待者，
  下一个请求可以重试；不会出现永久等待。
- 槽位状态带有扫描序号（从 1 开始，每次开始新扫描加一）。刷新请求到达时记下
  当前最新的扫描序号，只接受序号更大的扫描发布的快照，也就是在它到达之后才
  开始的扫描。正在进行的扫描可能在新 JAR 下载之前就已经列完目录，所以刷新
  不能复用它：刷新会等它结束，再由一个刷新请求接手新的扫描。同一次扫描期间到达
  的多个刷新共享这一次后续扫描，不会排成一串全量扫描。
- 不用“完成次数”判断：一次在刷新之前开始、在刷新之后完成的扫描也会让完成次数
  增加，刷新就会拿到旧依赖。多工作区共享同一个 `~/.m2`，或 macOS 端没有前端
  single-flight 时，这种重叠真实存在。

仓库扫描仍然在锁外执行。锁只保护槽位状态，不覆盖文件系统读取。

## 考虑过的备选方案

- **只在 Core 合并整个 `spring.index` 请求。** 不同请求携带不同的
  `textOverrides` 和路径集合，直接复用前一个请求的结果会返回过期索引。
  在 Core 里实现“丢弃旧输入、用最新输入重跑”的调度器，等于把前端的防抖和
  生命周期搬进 Core，职责不合适。
- **用全局信号量限制同时执行的扫描数。** 线程仍然被请求占住，只是从并发扫描
  变成排队扫描；超时和切换工作区时依旧不能尽快释放。前端 single-flight 能同时
  减少线程、内存和无效计算。
- **只修前端，不改 Core。** 可以把并发压到一个，但单个请求仍不能在扫描途中
  取消，两个平台也都无法复用同一依赖仓库的扫描结果。
- **给依赖仓库增加基于 mtime 的永久缓存。** 需要可靠判断 Maven 仓库变化，
  容易漏掉新下载的 JAR；本问题只需要避免并发重复扫描，不需要改变刷新语义。

## 后果

收益：

- 持续编辑时最多一个全量索引在途，外加一次合并后的补充索引，不再随输入次数增长。
- 同一 Maven 仓库在一个进程内只被并发扫描一次，等待者共享快照。
- 切换工作区、关闭页面或超时后，扫描可以很快退出，释放线程和内存。

代价与限制：

- 索引结果不是逐字实时的：一次扫描期间的多次编辑会合并到下一次刷新。这与原有
  300ms 防抖的取舍一致，只是把“多次并发扫描”换成了“一次后续扫描”。
- 刷新请求如果晚于一次已开始的扫描到达，无论那次扫描是否已经完成，都会再扫描
  一次。这是为了保证 JDT 导入完成后的依赖刷新不会复用旧快照。
- `core_cancel` 只能取消已经在 Core 注册的 operation。如果卸载恰好发生在请求已
  发出、Core 还没进入 dispatcher 的窗口里，取消会落空，该请求最多跑到 30/60 秒
  超时。窗口很小，本次不为它新增“预取消”协议。
- macOS 的 `SpringFeatureModel` 仍然只取消 Swift Task，已经进入 FFI 的扫描
  依靠 Core 的取消检查退出；本次没有把 operation ID 接到 Swift 的 bridge cancel。
- 没有实现增量索引，也没有改成只扫描 Maven 实际依赖的 JAR。这两项是后续优化，
  不影响本次并发边界的正确性。

## 验证

- `cargo test --manifest-path rust/lithe-core/Cargo.toml --lib spring`
  覆盖并发读者共享一次扫描、刷新只接受到达之后开始的扫描、扫描途中到达的刷新
  会重扫、取消等待和取消扫描。并发用例在等待者确实持有槽位之后才放行扫描者。
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/spring/hooks/use-spring-index.test.tsx`
  覆盖持续编辑只产生一次在途加一次补充刷新、卸载取消在途请求、主动取消不写失败
  状态、非本 hook 发起的取消不会停在 `loading`。
- `./scripts/verify-rust-core.sh`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-platform-feature-matrix.sh`

## 适用范围

- `rust/lithe-core/src/languages/spring.rs`
- `windows/tauri/src/features/spring/hooks/use-spring-index.ts`
- `windows/tauri/src/features/spring/hooks/use-spring-index.test.tsx`
- `windows/tauri/src/features/spring/api/spring-index-api.ts`
- `windows/tauri/src/features/spring/utils/spring-index-error.ts`
- `shared/platform-feature-matrix/features/spring-index.json`
