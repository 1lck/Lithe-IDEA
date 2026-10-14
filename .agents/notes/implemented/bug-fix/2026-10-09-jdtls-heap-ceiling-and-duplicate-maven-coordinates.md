# Agent 笔记：JDT LS 堆上限与重复 Maven 坐标导致的 Java 服务整体失败

状态：已实现

## 先说结论

Lithe 在两条启动路径上都用 `-Xmx1024m` 启动内置 Java 语言服务 JDT LS。JDT LS 发现
自己的最大堆不超过 1.5 GB、同时待导入的 Maven 模块超过 50 个时，会改用"分批导入"
这个省内存的分支；而这条分支在遇到坐标相同的模块时，会拿一个 `null` 工程去调用
`project.open(...)`，抛出的空指针异常会终止整个 Java 会话，用户看到的是
"Java language service failed while preparing the workspace"（#1156）。现在两条
启动路径的堆上限统一改为上游文档建议的 2 GB，多模块工程的导入留在常规分支，少数
模块的坐标冲突不再拖垮整个 Java 服务。以后不要为了省内存把这条上限调回 1.5 GB
或更低。

## 问题

复现条件（#1156 的真实工程）：一个 Maven 聚合工程下有 11 个子模块坐标完全相同
（`groupId` 和 `artifactId` 都一样），整个工作区需要导入的模块超过 50 个。

打包的 JDT LS 1.61.0 里的失败链路是：

1. `MavenProjectImporter.importToWorkspace` 发现待导入模块数大于去重后的
   `artifactId` 数量，于是把 Eclipse 工程名模板设置成 `[groupId]-[artifactId]`。
   坐标完全相同的模块因此算出同一个工程名。
2. 待导入模块超过 50 个、并且 `Runtime.maxMemory()` 不超过 1.5 GB 时，JDT LS 走
   "分批导入"分支；m2e 只为第一个同名模块建出 Eclipse 工程，其余模块返回 `null`。
3. 同一个分支把结果集合直接交给 `updateProjects`，`project.open(monitor)` 对 `null`
   调用，异常被上报成 `language/status: Error`，Lithe 的进程引擎按失败处理并终止会话。

关键是第 2 步的内存判断：它不看机器物理内存，只看 JVM 的最大堆。Lithe 自己把 `-Xmx`
固定成 1024m，所以这条带缺陷的分支对任何模块数超过 50 的工程都必然命中。上游已经补上
空值检查并会列出被跳过的 `pom.xml`（eclipse-jdtls/eclipse.jdt.ls#3893，进入上游
"End of September 2026" 里程碑），但 Lithe 现在打包的是 1.61.0，因此先把堆上限抬到
阈值以上，让导入留在常规路径。

## 决策

1. `rust/lithe-core/src/lsp/languages/jdt.rs` 新增常量
   `JDTLS_MAX_HEAP_ARGUMENT = "-Xmx2048m"`，wrapper 启动（`--jvm-arg=` 形式）和直接
   `java` 启动（裸参数形式）两条路径都改用它。
2. 这条上限仍然属于适配器拥有的参数：`is_jdt_owned_jvm_argument` 已经覆盖 `-Xms`
   和 `-Xmx`，所以目录（catalog）或外部传入的同名参数会被替换，重复适配的结果保持
   不变。需要调整堆时改这个常量，不要在平台层或插件里另加一个 `-Xmx`。
3. 新增回归用例
   `java_start_keeps_the_heap_above_the_jdtls_constrained_memory_threshold`，从两条
   启动路径的实际参数里取出 `-Xmx`，断言它严格大于 1536 MiB，防止以后为了省内存把
   上限调回会触发分批导入的区间。
4. 两端共用同一个引擎（`rust/lithe-core/src/lsp/interface/engine.rs` 的
   `start_server`），macOS 和 Windows 同时生效，平台代码不需要改。

正确做法：把堆上限当成"语言服务容量"的产品决定，集中在 `jdt.rs` 的适配层。

不要这样做：为了降低内存占用把上限降回 1.5 GB 或更低，或者让每个平台各传一份
`-Xmx`。前者会重新打开这个崩溃路径，后者会产生两个互相竞争的真源。

## 考虑过的备选方案

- **升级打包的 JDT LS 到含上游修复的版本**：否决。`download.eclipse.org/jdtls/milestones/`
  当前最新仍是 1.61.0，官方只有会滚动的 snapshot，无法按 SHA-256 固定，不符合
  `third_party/jdtls/manifest.json` 的固定版本加校验要求。上游修复进入下一个里程碑后
  再按正常流程升级。
- **在 Lithe 里解析 `pom.xml` 的 `groupId`/`artifactId`，提前报错或排除重复模块**：
  否决。父工程继承、属性占位符等细节会让 Lithe 变成第二份 Maven 工程模型，违反
  "上游拥有工程事实"的边界；而且用户真正需要的是 Java 服务可用，不是让 Lithe 复述
  上游的诊断。上游版本会自己给出明确报错。
- **只把失败文案改成更可读的提示**：否决。会话已经被 `kill_process` 终止，文案再清楚
  也无法恢复补全、跳转和运行，P0 问题依然存在。
- **直接修改 JDT LS 的 jar**：否决。不能改写已按 SHA-256 校验的上游发行物，也会破坏
  插件包签名和增量更新基线。

## 后果

- 收益：模块数超过 50 的工程不再走带缺陷的分批导入分支，少数模块的坐标冲突最多影响
  自己；JDT LS 同时拿到上游文档建议的堆，索引和编译大型工程的余量更充足。
- 代价：Java 语言服务 JVM 的堆上限从 1 GB 提到 2 GB。`-Xms` 仍是 256m，上限不是预留，
  启动开销不变，只有工程确实需要时才会增长到 2 GB；代价是大工作区可能占用更多内存。
- 残留：坐标完全相同的模块本来就无法都成为独立工程（目录名和坐标都重复），仍然只有
  一个进入 Java 模型，其余被 m2e 跳过。1.61.0 不会提示这件事，上游下一个版本会用通知
  列出被跳过的 `pom.xml`；用户需要自己修正重复坐标。

## 验证

- `./scripts/verify-rust-core-comments.sh`
- `./scripts/verify-rust-core.sh`
- `./scripts/verify-agent-notes.sh`
- 用例 `java_start_adds_runtime_memory_and_unique_data_arguments` 和
  `java_direct_start_builds_complete_shell_free_arguments_and_is_stable` 固定两条启动
  路径的完整参数列表，`java_start_keeps_the_heap_above_the_jdtls_constrained_memory_threshold`
  固定堆上限与 1.5 GB 阈值的关系。

## 适用范围

- `rust/lithe-core/src/lsp/languages/jdt.rs`
- `rust/lithe-core/src/lsp/interface/engine.rs`
- `third_party/jdtls/manifest.json`
