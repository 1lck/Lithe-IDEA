# Agent 笔记：LSP 设置摘要的取消与快照输入

状态：已实现

## 先说结论

LSP 设置页离开或切换文件快照时，页面应立即结束等待，下一份摘要直接开始计算。
旧扫描收到取消后可能还在处理最后一批文件；摘要模型继续持有它，但旧结果不能更新页面。
快照标识和文件清单必须一起捕获，避免把较新的文件清单算进较旧的缓存键。

## 问题

取消 Swift 任务是协作式操作，等待任务的 `value` 不会因为等待方被取消而立即返回。
让新扫描先等待旧扫描完成，会把旧扫描的退出延迟带到下一次切页和工作区切换。
只取消扫描、仍让页面等待其 `value`，也不能保证离页后的页面任务及时释放。

## 决策

- `LSPProjectUsageModel` 用 continuation（可由所有者主动结束的等待句柄）管理每个页面消费方。
  同请求共享一个扫描；取消一个消费方只结束它自己的等待，最后一个退出时才取消扫描。
- 请求替换和工作区重置先解除旧消费方，再取消扫描。模型保存尚未退出的任务，完成后移除；
  完成回调用唯一工作 ID 校验当前所有权，旧结果和旧取消回调都不能修改新请求。
- 后台任务只弱引用模型，模型释放时取消全部任务。生产扫描每 256 个 URL 检查取消并释放
  临时对象；取消后的批次可短暂重叠，不承诺任意忽略取消的自定义扫描器能被强制终止。
- `LanguageToolingFeatureModel` 从同一份已应用快照生成不可变输入。文件数组按写时复制语义捕获，
  任务身份只包含工作区、快照 UUID 和规范化规则，不遍历或哈希整个文件数组。
- LSP 叶子视图继续直接观察 `AppModel`。工作区通知已会经 `objectWillChange` 到达叶子；
  `affectsSettings: false` 只抑制设置根树刷新，不代表叶子收不到变化。
  不额外向 `settingsChanges` 转发文件快照，保持设置窗口的低频刷新边界。

正确做法：旧快照 A 扫描暂停时提交 B，B 直接完成；A 随后退出只清理自己的任务。
不要让 B 先 `await A.value`，也不要在 B 的任务开始时再单独读取可变的 `projectFiles`。

## 考虑过的备选方案

- 串行等待旧扫描：峰值只运行一份扫描，但不合作的旧扫描会阻塞新页面，因此不采用。
- 丢弃取消任务的句柄：新请求可以启动，但所有权和清理无法核验，因此保留到任务完成。
- 给设置根树增加快照通知：现有叶子订阅已覆盖更新，再增加通知会扩大重绘范围。

## 后果

- 页面任务的生命周期不再取决于旧扫描的退出速度，热缓存仍只保存一份摘要。
- 需要管理消费方等待和退出中的扫描两种资源；取消边界允许旧批次短暂重叠。
- 此功能只读取已有 URL 清单，不访问文件内容、不启动语言服务器、不新增磁盘缓存，
  不写发行目录，因此不改变代码签名或 Sparkle 增量更新所依赖的发行基线。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'LSPProjectUsageTests|AppModelSettingsChangesTests|WorkspaceLanguageServerPreferencesTests'`
- `./scripts/architecture/verify-service-boundaries.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- 用有界 gate 暂停并忽略旧扫描取消，验证新请求和旧消费方都能在释放 gate 前结束。
  原生挂载测试保持同一个 LSP 页面，依次应用新增、重命名和删除后的快照。
- 命令行测试没有持续的 AppKit 原生事件循环；挂载测试用单调时钟限定等待，驱动非阻塞绘制轮次，
  再检查页面任务实际生成的摘要。不能只等摘要通知，也不能依赖可选截图顺带触发绘制来通过测试。

## 适用范围

- `macos/Sources/Lithe/Application/Features/LSPProjectUsage.swift`
- `macos/Sources/Lithe/Application/Features/LanguageToolingFeatureModel.swift`
- `macos/Sources/Lithe/Views/Language/LSPControlCenterView.swift`
- `macos/Tests/LitheTests/LSPProjectUsageTests.swift`
- `macos/Tests/LitheTests/AppModelSettingsChangesTests.swift`
