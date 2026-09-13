# Agent 笔记：模块运行时的剩余抽取路线

状态：提议中

## 先说结论

这是一份逐步完成模块边界的路线图，不代表所有功能现在都已经抽取完成。后续每一步都要先证明模块有真实的所有权和独立测试价值，不能为了目录看起来整齐而制造空壳 target 或包装层。

## 问题

模块运行时、factory、manifest、资源 scope 和插件校验已经落地，但模块
边界的实现仍未全部完成。`Package.swift` 中的功能 target 虽然已经独立，
`Lithe` executable 和 `AppServices` 仍然承载一部分跨模块组合与兼容字段。
如果继续把“有独立 target”误认为“已经完成模块隔离”，后续会出现空壳
target、可执行目标反向依赖、重复的资源所有权和无法单独测试的 feature graph。

还需要明确：模块运行时抽取、功能 target 抽取和可下载原生插件不是同一件
事。不是每个功能都要变成插件，也不能为了满足目录结构而制造没有真实
所有权的包装层。

## 提案

保留已实现的 `LitheModuleAPI` 和 `LitheApplicationKernel` 作为稳定底座，
按功能所有权逐步完成以下抽取。

### 先完成可验证的 target 边界

- 每个功能 target 只依赖 `LitheModuleAPI`、`LitheCoreContracts` 和明确
  需要的工作流库，不依赖 `Lithe` executable。
- 把功能需要的值类型、端口和协议放入 `LitheCoreContracts`，不要为了
  迁移速度把 executable 类型或平台 adapter 复制进模块 target。
- 模块自己的 feature model、service graph、资源 owner 和生命周期实现
  由模块 target 持有；应用侧只保留 coordinator、投影和 re-entry 协议。
- `AppServices` 不再新增模块私有 factory、具体模块 service 或平台资源
  所有权；新的能力通过 module runtime 或共享 contract 注入。
- `MacServiceContainer` 继续是 macOS 组合根，但它只负责构造平台能力、
  注册 factory 和连接应用级 coordinator。

### 按收益选择是否插件化

- Workspace Foundation、Git、Search、Local History、Terminal、Debug、
  AI Assistance 和 Java/Maven 等能力可以继续作为内置模块。
- 只有拥有独立安装、禁用、更新或进程/连接资源生命周期收益的能力，才
  进入原生插件路径。数据库连接能力和非 Java 语言支持是当前适合的例子。
- 语言服务器、执行和测试的拆分继续遵循已有的语言工具 Note；不能因为
  想统一目录而把 LSP、Run/Test 和 Debug 合并成一个不可独立休眠的模块。
- 新插件必须同时具备静态 manifest、模块所有权、宿主协议、factory、
  禁用/休眠行为和资源清理测试；没有这些条件时保持内置实现。

### 逐步删除旧的组合字段

每迁移一个模块，按以下顺序收缩应用侧：

1. 在 `LitheCoreContracts` 中确认模块对外需要的端口和值类型。
2. 让模块 target 自己创建 feature graph，并通过 `ModuleContext` 接收
   能力、资源和 lease。
3. 让应用 coordinator 只持有能力协议和状态投影，删除 executable target
   中对应的具体 service 字段。
4. 补充禁用、按需激活、休眠、唤醒、关闭和失败回滚测试。
5. 更新边界校验，防止旧实现通过兼容字段重新回流。

## 考虑过的备选方案

### 把所有功能一次性改成下载插件

表面上可以得到统一的包结构，但会把不需要独立发布或进程资源隔离的
内置能力也引入安装、签名、版本兼容和恢复复杂度，且无法解决应用侧
contract 尚未抽取的问题。因此只按独立生命周期收益选择插件化。

### 保留所有实现，只创建更多 SwiftPM target

可以快速通过目录和 target 检查，但如果 target 继续依赖 executable 或
只 re-export 原实现，模块仍没有真实所有权，也无法单独禁用、测试和替换。
空壳 target 不算完成。

### 先重写公共 Rust JSON 命令面

这会扩大本轮改动并改变跨平台兼容面，而模块抽取本身不要求改变已有
command、DTO、错误码、取消或陈旧结果语义。因此先保持 Rust 公共命令面
不变，只有在具体功能迁移确实需要时才单独更新共享契约。

## 验收标准

- 任意模块 target 都不依赖 `Lithe` executable，也不直接依赖
  `Mac*`、AppKit、SwiftUI、Tauri 或 Rust C ABI 具体实现。
- `AppServices` 不新增模块私有 factory、具体模块 service 或模块资源
  owner；模块所需能力通过 contract 和 runtime 进入。
- 被迁移模块的 factory、manifest、contribution 和实际实例保持一致，
  禁用时不构造，休眠后没有活动资源，唤醒可以重建。
- 新插件在 Bundle 加载前通过静态 manifest、宿主兼容性和所有权校验，
  并有失败回滚、资源清理和 Safe Mode 测试。
- `./scripts/verify-module-boundaries.sh`、`./scripts/verify-service-boundaries.sh`
  和受影响模块测试通过，且已有 macOS、Rust、共享契约行为不变。
- 每完成一个模块，更新本 Note 的适用范围或将已完成部分沉淀到
  `implemented/`，不要把执行清单永久留在这里。

## 风险

- `LitheCoreContracts` 如果只复制类型而没有明确 owner，会形成新的共享
  垃圾场；每个 contract 必须有使用方和生命周期 owner。
- 兼容性的 `AppModel` re-entry 或旧 coordinator 可能继续隐式激活模块，
  需要用模块测试和边界脚本确认调用方向。
- 原生 Bundle 在同一进程内不可安全卸载，插件禁用、升级和回滚仍可能需要
  重启；不能把“模块休眠”误写成“代码已经卸载”。
- Windows 是独立实现，Windows 对齐路线由
  [`Windows React/Tauri 产品对齐完成度`](2026-09-13-windows-tauri-product-parity.md)
  单独管理，本提案不把两个平台的 target 结构强行合并。

## 适用范围

- `Package.swift`
- `macos/Sources/Lithe/Application/Composition/AppServices.swift`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/LitheCoreContracts/`
- `macos/Sources/Lithe*Module/`
- `Plugins/mac/Official/`
- `scripts/verify-module-boundaries.sh`
- `macos/Tests/LitheApplicationKernelTests/`
- 各功能模块的对应测试 target
