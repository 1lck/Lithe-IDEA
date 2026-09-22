# Agent 笔记：运行面板先展示配置，再校验内容指纹

状态：已实现

## 先说结论

Windows 运行面板先读取并解析配置文档，展示已有配置后再检查项目文件是否变化。
内容指纹（按文件字节计算的摘要）校验仍然完整执行；校验超时会显示诊断，但不再清空已加载的配置。
开发者不能用文件大小和修改时间相同来代替内容校验。

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

正确做法：先显示可读配置，再展示“输入已修改”或“校验失败”。
不要这样做：校验超时后清空配置，或在没有读取字节的情况下声称输入未变化。
指纹诊断和此前一样只是新鲜度提示，不是启动许可；本改动不改变启动校验流程。

## 考虑过的备选方案

- 持久化大小和修改时间以复用摘要：同大小文件可在保留时间戳时发生内容变化，
  因而会漏报，不采用，也不增加 `inputSignatures` 契约。
- 只提高超时：面板仍要等待扫描完成，无法解决空白等待。
- 完全取消校验：会丢失已有的过期配置提示，因此保留展示后的完整校验。

## 后果

面板首屏不再依赖全量文件摘要；校验失败不会丢掉用户可用的配置。
完整扫描的总成本没有减少，加载任务要等校验结束才返回，耗时超过期限仍会产生
诊断。不能据此声称大型 Windows 项目的完整校验已达到一秒以内。
macOS 的加载顺序没有变化。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-agent-notes.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend -FrontendTestPath src/features/run/stores/run-project-load.test.ts`

回归测试控制校验完成的时机，验证提前显示、超时保留配置、过期提示以及旧结果隔离。

## 适用范围

- `windows/tauri/src/features/run/stores/run.store.ts`
- `windows/tauri/src/features/run/stores/run-project-load.test.ts`
- `windows/tauri/src/features/run/api/run-core-api.ts`
- `rust/lithe-core/src/execution/configuration.rs`
