# Agent 笔记：macOS 翻译文件在打包时编译

状态：已实现

## 先说结论

macOS 应用中的翻译文件使用二进制属性列表，也就是系统可以直接读取、无需重新解析整份文本的格式。
源代码中的翻译文件仍保留可读文本，正式打包、开发预览和性能测试打包都在签名前转换应用内的副本。
应用内即时切换中英文的行为保持不变。

## 问题

用户点击项目、Git、终端或问题按钮时感到约一秒的停顿。
在 macOS 26.3.1、Apple Silicon 上对 Lithe 0.4.7 的采样中，主线程大量时间用于翻译字符串表的加载和文本解析。
SwiftUI（macOS 界面框架）接收显式语言环境后，所调用的 Foundation 字符串查询路径会重复加载表；界面更新涉及多处文字时，文本解析开销被放大。

独立查询基准中，中文单次查询约从 1.29 毫秒降到 0.054 毫秒。
同一应用版本和项目的两次 25 秒操作采样中，字符串表热点样本从 4155 降到 196，文本解析热点消失。
这些是特定环境下的查询耗时和累计采样结果，不是单次点击响应时间，也不保证所有系统版本有相同收益。

## 决策

三个打包入口调用 `scripts/package-macos-localizations.sh`，复制英语、简体中文资源后，通过系统的 `plutil` 工具转换 `.strings` 和 `.stringsdict` 文件。
转换失败或缺失必要语言资源时，打包立即失败，避免交付未优化或缺少翻译的应用。
转换必须发生在代码签名前，不能修改已经签名或正在运行的应用。

正确做法是转换输出目录中的翻译副本，然后签名；不要直接转换 `macos/Resources` 中的源文件，也不要在新预览入口恢复原样复制文本的逻辑。

## 考虑过的备选方案

- 改写 `AppleLanguages` 并移除显式语言环境：可能改变运行中切换语言的行为，需要额外处理系统缓存；本次保留已有机制，以更小的打包改动解决已确认的解析热点。
- 拆分 `AppModel` 以减少界面重算：可能进一步改善交互，但涉及更多状态订阅边界，也不能单独解决每次翻译查询过慢的问题；不纳入本次修复。
- 在运行时替换系统翻译方法或建立额外缓存：会增加对系统内部行为的依赖；本次使用系统支持的资源格式即可获得明显收益。

## 后果

翻译文件无需人工维护两份，格式转换集中在一个脚本中；回归测试比较两种语言的全部词条，并检查占位符、Unicode、重复打包和失败路径。
应用仍可能重复加载二进制表，界面布局和终端启动等其他工作仍有开销。本决策不等同于消除全部卡顿。
打包多一次资源转换；以后新增打包入口时也必须调用该脚本。

CI 分类将翻译打包脚本映射到 Swift 回归测试与 macOS 双架构打包，将性能基线脚本映射到 macOS 打包，避免因路径未分类而启动 Windows、数据库和插件任务。
未知文件仍走全量验证；修改分类器或其测试本身也仍跑全量，防止分类错误隐藏回归。因此加入这条分类规则的 PR 本身仍会全量验证。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter LocalizationPackagingTests`
- `./scripts/build-macos.sh --configuration debug`
- `./scripts/preview.sh`：确认输出包的翻译文件为二进制，检查四个面板切换与中英文往返切换。
- `./scripts/verify-agent-notes.sh`
- `./scripts/test-classify-ci-changes.sh`

性能对照应固定应用可执行文件、项目、语言和操作序列，仅改变打包后的翻译格式。记录采样窗口和平台，不把样本数量当作精确点击耗时。

## 适用范围

- `scripts/package-macos-localizations.sh`
- `scripts/package-app.sh`
- `scripts/preview.sh`
- `scripts/measure-macos-performance-baseline.sh`
- `macos/Tests/LitheTests/LocalizationPackagingTests.swift`
- `macos/Resources/en.lproj/Localizable.strings`
- `macos/Resources/zh-Hans.lproj/Localizable.strings`
