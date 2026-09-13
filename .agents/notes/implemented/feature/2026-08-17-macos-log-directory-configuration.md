# Agent 笔记：macOS 日志目录配置与失败回退

状态：已实现

## 先说结论

日志目录由平台层解析，默认放在用户的 macOS 日志目录，也可以由用户选择其他目录。设置一旦生效，运行中的日志 writer 和重启后的应用都必须使用同一个有效目录；目录不可用时要清除选择并回退到默认位置。

## 问题

用户需要知道 macOS 应用日志实际保存在哪里，并在磁盘空间、权限或诊断
收集场景下选择其他目录。仅在设置页保存一个路径是不够的：启动时必须
验证目录可用，运行中的日志 writer 也必须立即切换，否则界面显示的路径和
实际写入位置会分离。

## 决策

默认日志目录由 macOS 平台适配器通过系统用户 Library 目录解析为
`~/Library/Logs/Lithe`，设置页面展示解析后的真实绝对路径，不嵌入开发机
路径。`LogDirectoryProviding` 统一提供目录和 `lithe.log` 文件路径，其他
服务不重复拼接日志文件名。

`AppSettings` 保存可选的自定义目录，并把有效日志目录定义为“自定义目录
或默认目录”。用户从系统目录选择器选中目录后立即持久化，并通过已有观察
机制让 `MacApplicationLogWriter` 将后续输出写入新目录；应用重启后继续使用
该选择。字体注册和 Git 性能基线诊断等现有诊断输出复用同一个 writer。

如果启动时或运行中无法创建、打开或切换到自定义目录，应用清除自定义选择，
回退到默认目录，并让界面重新显示默认目录。这样不会把已经失效的路径继续
当作当前配置，也不会在每次启动时重复使用一个已知不可用的目录。

设置页的“恢复默认目录”只清除自定义日志目录；应用级“恢复全部默认设置”
也清除该配置，但不改变日志格式、级别、内容或其他设置。这个功能不新建
结构化日志协议、业务 sink、轮换协议、云端上传或跨平台日志契约。

## 考虑过的备选方案

- **硬编码开发机或固定用户路径**：在开发环境看似直接，但换用户、打包
  应用或测试环境后会失效，因此由系统目录 API 解析。
- **只显示默认目录，不显示当前有效目录**：自定义目录生效后用户无法判断
  日志实际落点，因此设置页同时展示默认目录和当前目录。
- **只保存路径，等下次启动再切换 writer**：会让当前会话继续写旧目录，
  因此配置变更通过观察机制立即重定向。
- **保留无法打开的自定义目录**：会造成界面撒谎和启动反复失败，因此失败
  时清除自定义值并回退。
- **在本功能中顺便重做日志协议、轮换或上传**：会把目录选择和日志产品
  设计绑在一起，扩大兼容面和隐私风险，因此保持范围收敛。

## 后果

设置页、应用启动、诊断导出和实际日志写入都使用同一条目录解析路径；
用户可以立即切换目录，重启后也能保持选择。目录不可用时会自动恢复可用
默认值，代价是用户需要重新选择一个可用目录。

日志 writer 仍然由 macOS 应用启动和设置观察机制驱动，目录配置本身不负责
日志内容治理、轮换、清理或上传。未来如果改变日志文件名、诊断导出来源
或 Windows 日志策略，需要重新检查 `LogDirectoryProviding` 与本 Note 的
范围，而不是在设置视图中复制路径规则。

## 验证

- `./scripts/test-macos.sh`
- `./scripts/verify-service-boundaries.sh`
- `macos/Tests/LitheTests/MacApplicationLogWriterTests.swift`
- `macos/Tests/LitheTests/AppLocalizationTests.swift`
- `./scripts/verify-agent-notes.sh`

测试覆盖 macOS 默认日志目录、切换目录后的后续写入、设置文案和诊断导出
使用的统一 `applicationLogFileURL`。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/Logging/MacLogDirectoryProvider.swift`
- `macos/Sources/Lithe/Platform/MacOS/Logging/MacApplicationLogWriter.swift`
- `macos/Sources/Lithe/Core/Ports/LogDirectoryProviding.swift`
- `macos/Sources/Lithe/Models/Settings/AppSettings.swift`
- `macos/Sources/Lithe/LitheApp.swift`
- `macos/Sources/Lithe/Views/App/SettingsView.swift`
- `macos/Tests/LitheTests/MacApplicationLogWriterTests.swift`
- `macos/Tests/LitheTests/AppLocalizationTests.swift`
