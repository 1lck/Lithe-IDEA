# Agent 笔记：运行面板先展示配置，再校验内容指纹

状态：已实现

归档日期：2026-11-16

> Core 不再计算项目内容指纹（[Lithe-core-rust #77](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/77)，#1856 第 4 项）：`checkFingerprint`、`staleFingerprint`、`incompleteProjectScan` 和桌面端的 `InspectRunConfigurations` 都已删除，生成层只来自插件声明的运行入口，过期只比较 provider run 快照。当前做法见[运行配置的生成层只来自插件声明，只存在内存里](../../implemented/architecture/2026-10-29-run-configuration-detection-in-memory.md)；本文只保留历史取舍。

## 先说结论

运行面板先读取并解析配置文档，展示已有配置后再检查项目输入是否变化。内容指纹（按文件字节计算的摘要）校验仍然完整执行；校验超时会显示诊断，但不再清空已加载的配置。开发者不能用文件大小和修改时间相同来代替内容校验。

## 问题

大型项目每次打开运行面板都会扫描输入文件并计算摘要。文件访问被实时杀毒软件拖慢时，完整校验可能超过请求期限，原来的加载流程把这个错误当成配置不可读，导致整个面板为空。

## 决策

- 复用已有的 `checkFingerprint: false` 读取路径（桌面端 `desktop/internal/core/run_discovery.go` 的 `InspectRunConfigurations`），仍由 Core 校验文档版本和格式。配置解析成功后立即发布“就绪”状态，再等待完整指纹校验。
- 完整校验的诊断追加到已解析配置的诊断中；失败也作为可见诊断保留。
- 项目加载版本号和根目录共同阻止旧校验结果覆盖新项目或同一项目的新一次加载。
- 保存后的重新加载保持完整校验路径。

重新识别必须等待尚未结束的指纹请求实际结束（成功或失败均可），再扫描与生成配置。不能只增加版本号丢弃旧结果：那样旧请求仍在读取文件，会与新生成争用磁盘。等待期间已有配置保留；切换项目或更新的生成请求会使旧的排队请求失效。

正确做法：先显示可读配置，再展示“输入已修改”或“校验失败”。
不要这样做：校验超时后清空配置，或在没有读取字节的情况下声称输入未变化。指纹诊断只是新鲜度提示，不是启动许可；启动仍需重新校验。

### 指纹只覆盖生成真正读取的内容

指纹只覆盖“生成配置时真正读取的内容”：

- 普通源码文件只记录路径，参与“增加/删除文件”的判断；
- 入口所在的源码和构建文件按字节哈希；
- 由 JDT 等语言服务给出的入口，由该服务的答案判断是否变化，而不是重新扫描源码。

新增会影响生成结果的输入时，同时决定它是按路径还是按内容进入指纹。不要为了“保险”把整个源码目录重新加回内容哈希：那会让每次打开项目都读取全部源码，改一行方法体也会误报过期。

旧版本写下的生成文件用当前规则重算不出原指纹，这时提示“生成器已变化”，不会报出大量“已修改”的文件。

### 不可读目录不是已删除目录

自动发现、指纹和文件列表使用 Core 的同一遍历策略：先排除已知缓存和构建输出，再进入子目录；不能按“点开头”排除所有隐藏源码。工作区根不可读仍失败，可选子目录不可读则继续兄弟目录，并记录未知路径。重新生成保留未知路径下的旧配置及输入摘要；检查返回 `incompleteProjectScan`，不从不完整快照推断删除或新鲜度。即使后续目录可读，旧基线也要完整重新生成后才能解除诊断。

不要只在访问失败时返回空数组：这样会把访问失败写成成功的空快照。

Java 文件枚举的数量上限也必须限制后续目录访问，不能完整扫描后再截取数组。

## 考虑过的备选方案

- 持久化大小和修改时间以复用摘要：同大小文件在保留时间戳时可能发生内容变化，会漏报。
- 只提高超时：面板仍要等待扫描完成，无法解决空白等待。
- 完全取消校验：会丢失已有的过期配置提示，因此保留展示后的完整校验。
- 并行计算全部源码的哈希：读取量不变，也解决不了改方法体误报过期的问题。

## 后果

面板首屏不再依赖全量文件摘要；校验失败不会丢掉用户可用的配置。完整校验只遍历目录并读取入口源码和构建文件，成本不随源码总量增长。代价是“新增入口”这类提示要等语言服务就绪后才出现，语言服务不可用时这一项没有提示，其他输入照常检查。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core/...`：桌面端经 C ABI 调用 `runConfig.inspect` 的桥接测试（含 `checkFingerprint` 参数）。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `desktop/internal/core/run_discovery.go`
- `desktop/internal/workbench/runconfig_view.go`
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/execution/configuration.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/execution/configuration.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/run-configuration-v2.schema.json`
