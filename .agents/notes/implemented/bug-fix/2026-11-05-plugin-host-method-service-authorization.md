# Agent 笔记：插件宿主请求的方法与服务必须一致

状态：已实现

## 先说结论

插件宿主收到请求时，授权必须同时核对方法、方法所属服务和当前会话的授权。不能只看方法是否在授权集合中，否则内部错误地传入不一致的服务名时，原生处理器仍可能被调用。

## 问题

旧的 macOS 分发器只要发现方法名在会话授权里就继续分发，没有核对请求携带的服务名。Core 通常会先生成正确的服务名，但宿主也负责复核；当内部调用或后续接线产生不一致的请求时，宿主原有检查不能拒绝它。

## 决策

Core 的宿主方法表是方法和服务关系的真源。macOS 在分发前调用 Core 检查该关系和当前 grant；不匹配返回不可用，Core 调用失败时拒绝并记录错误。会话、工作区和资源检查仍在宿主执行。授权目录及生命周期的完整边界见 `2026-10-30-plugin-backend-workspace-context.md`。

正确做法是用已授权的编辑器方法和其真实服务一起判断；不要把同一方法标成工作区服务再只凭方法授权放行。

## 考虑过的备选方案

在 Swift 增加第二张方法到服务的表能拦截不一致请求，但新增方法时需要维护两张表，容易再次漂移，因此复用 Core 的现有方法表。

## 后果

方法和服务不一致时会在调用原生处理器之前被拒绝。每次请求需要一次本地 Core 调用，宿主只传方法、服务和授权名称，不传文档内容或凭据。

## 验证

`PluginPublicHostAPITests.aMethodCannotBeDispatchedUnderADifferentService` 在旧分发器上失败、修复后通过。`shared/fixtures/plugins/host-api-v1.json` 覆盖旧版聚合授权、独立方法授权、未知方法和服务不匹配。

## 适用范围

- ~~`macos/Sources/Lithe/Application/Features/PluginHostServiceDispatch.swift`~~（已随 #1794 移除）
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/host_api.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/host_api.rs)
- ~~`macos/Tests/LitheTests/PluginPublicHostAPITests.swift`~~（已随 #1794 移除）
