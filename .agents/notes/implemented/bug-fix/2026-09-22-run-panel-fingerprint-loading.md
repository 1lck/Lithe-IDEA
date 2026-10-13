# Agent 笔记：运行面板先展示配置，再校验内容指纹

状态：已实现

## 先说结论

Windows 运行面板先读取并解析配置文档，展示已有配置后再检查项目文件是否变化。
内容指纹（按文件字节计算的摘要）校验仍然完整执行；校验超时会显示诊断，但不再清空已加载的配置。
开发者不能用文件大小和修改时间相同来代替内容校验。

后续（#507）：指纹只覆盖“生成配置时真正读取的内容”。普通 Java 源码只记录路径，
入口所在的源码和构建文件仍按字节哈希；“在已有类里新增 main”这类变化改由 JDT
的入口答案判断。这样打开项目不再读取全部源码，macOS 也不再在主线程上全量扫描。

## 问题

大型项目每次打开运行面板都会扫描输入文件并计算摘要。文件访问被实时杀毒软件
拖慢时，完整校验可能超过请求期限，原来的加载流程把这个错误当成配置不可读，
导致整个面板为空。

## 决策

复用已有的 `checkFingerprint: false` 读取路径，仍由 Core 校验文档版本和格式。
Windows store 在配置解析成功后立即发布 `ready` 状态，再等待完整指纹校验。
这个等待仍属于原加载任务，不创建脱离调用者的任务，也不放宽请求超时。

完整校验的诊断追加到已解析配置的诊断中；失败也作为可见诊断保留。
项目加载版本号和根目录共同阻止旧校验结果覆盖新项目或同项目的新一次加载。
保存后的重新加载保持原有完整校验路径。

提前展示后，用户可以请求重新识别。store 按项目跟踪尚未结束的指纹请求，
重新识别先等待这些请求实际结束（成功或失败均可），再扫描与生成配置。
不能仅增加版本号丢弃旧结果：那样旧请求仍在读取文件，会与新生成争用磁盘。
等待期间已有配置保留；切换项目或更新的生成请求会使旧的排队请求失效。

正确做法：先显示可读配置，再展示“输入已修改”或“校验失败”。
不要这样做：校验超时后清空配置，或在没有读取字节的情况下声称输入未变化。
指纹诊断和此前一样只是新鲜度提示，不是启动许可；本改动不改变启动校验流程。

### 指纹只覆盖生成真正读取的内容（#507）

原先指纹对每个 `.java` 文件做内容哈希。这是入口识别还由 Core 扫描源码时留下的
做法；#781 把入口识别交给 JDT 后，生成配置只用到：

- Java 源码的**路径**：判断是否有 Java 源码、推断 Maven 模块；
- 入口所在源码的**内容**：只为 JDT 已确认的入口判断是否是 Spring Boot；
- 构建文件（`pom.xml`、wrapper、lock 文件等）的**内容**；
- JDT 给出的入口列表（不是文件）。

因此现在：

- 普通 Java 源码在 `generator.inputs` 里记为 `path`，只参与“增加/删除文件”的判断；
- 入口源码按生成结果里 Java 入口的 `source` 计算，生成和检查用同一规则，仍按
  字节哈希；
- 在已有类里新增或删除 main：平台在 JDT 就绪后把 `javaEntrypoints` 传给
  `runConfig.inspect`，Core 与已生成的入口比对，不一致时给出同一个
  `staleFingerprint` 提示。这个检查不启动 JDT，也不占用加载任务；已有重新
  生成在等 JDT 时直接跳过，因为那次生成会替换入口。
- 旧版本写下的 `generated.json` 用当前规则重算不出原指纹，这时提示“生成器已
  变化”，不会报出上千个“已修改”的文件。

正确做法：新增会影响生成结果的输入时，同时决定它是按路径还是按内容进入指纹。
不要这样做：为了“保险”把整个源码目录重新加回内容哈希；那会让每次打开项目又
读取全部源码，改一行方法体也会误报过期。

macOS 同步修正了三处主线程上的全量检查：生成后、保存配置后、新建配置后都改为
`checkFingerprint: false`。编辑 `.lithe` 不改变项目输入，已有的过期提示原样保留。

## 考虑过的备选方案

- 持久化大小和修改时间以复用摘要：同大小文件可在保留时间戳时发生内容变化，
  因而会漏报，不采用，也不增加 `inputSignatures` 契约。
- 只提高超时：面板仍要等待扫描完成，无法解决空白等待。
- 完全取消校验：会丢失已有的过期配置提示，因此保留展示后的完整校验。
- 并行计算全部源码的哈希：能缩短时间，但读取量不变，改方法体仍会误报过期，
  也解决不了 macOS 主线程上的调用，不采用。
- 只按路径记录 Java 源码、不做 JDT 比对：会漏掉“在已有类里新增 main”的过期
  提示，属于修复引入的回归，不采用。

## 后果

面板首屏不再依赖全量文件摘要；校验失败不会丢掉用户可用的配置。
#507 之后，完整校验只遍历目录并读取入口源码和构建文件，成本不再随源码总量
增长；修改方法体不再被报成“配置可能已过期”。代价是“新增 main”的提示要等
JDT 就绪后才出现，JDT 不可用时这一项没有提示（其他输入照常检查）。
升级后首次打开会提示一次“生成器已变化”。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-agent-notes.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend -FrontendTestPath src/features/run/stores/run-project-load.test.ts`
- `./scripts/verify-rust-core.sh`
- `./scripts/test-macos.sh`

回归测试控制校验完成的时机，验证提前显示、超时保留配置、过期提示以及旧结果隔离。
#507 的测试覆盖：普通源码只按路径、入口源码仍按内容、JDT 比对的新增/删除/模块前缀、
旧生成器版本的提示、Windows 等待 JDT 与切换项目取消、macOS 编辑配置不重读输入。

## 适用范围

- `windows/tauri/src/features/run/stores/run.store.ts`
- `windows/tauri/src/features/run/stores/run-project-load.test.ts`
- `windows/tauri/src/features/run/api/run-core-api.ts`
- `rust/lithe-core/src/execution/configuration.rs`
- `shared/contracts/run-configuration-v2.schema.json`
- `macos/Sources/LitheExecutionModule/Services/RunService.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+JavaEntrypoints.swift`
