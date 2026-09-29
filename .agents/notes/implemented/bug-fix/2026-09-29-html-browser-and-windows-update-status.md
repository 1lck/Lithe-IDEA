# Agent 笔记：HTML 浏览器选择与 Windows 更新状态

状态：已实现

## 先说结论

HTML 的“在浏览器中打开”必须选择系统默认网页浏览器，不能依赖 HTML
文件关联，因为用户可能把 HTML 默认交给文本编辑器。Windows 主程序更新
和语言扩展安装是独立状态；缺少语言工具导致更新失败时，必须先保留旧扩展，
不能先卸载再发现依赖不可用。

## 问题

Issue #966 同时报告更新提示和浏览器预览问题。原来的两个浏览器按钮都
调用普通文件打开接口。Windows 设置页还会在尚未检查时显示“已是最新版”，
菜单通知没有说明检查对象是主程序；扩展更新则在检查 Bun 等依赖前卸载旧扩展。

## 决策

- macOS 通过平台 UI 接口查询 HTTPS 默认处理程序，再用 AppKit（系统桌面
  UI 框架）把文件 URL 交给该程序；失败通过预览界面的弹窗显示。
- Windows 采用 `webbrowser` 1.2.4 的默认浏览器选择能力。该上游通过 Windows
  HTTP 协议关联发现浏览器，不复刻注册表查询和浏览器命令行解析。
  Tauri 宿主验证现有本地 HTML 文件后在阻塞工作线程调用它，前端显示失败提示。
- 外部浏览器读取已保存文件，内嵌预览继续读取编辑缓冲区。此操作不自动保存，
  不创建服务器、不下载资源，也不写安装目录或 app bundle，因而不改变签名
  和 Sparkle 增量更新的发行基线。
- Windows 扩展更新先复用安装器的只读依赖检查，确认必需的语言服务器已存在或可安装，
  失败时不禁用旧扩展、不删除语法缓存、不清除待更新标记。这个保护针对
  依赖失败，不承诺后续下载或激活步骤的完整事务回滚。
- 没有自动安装器不等于不能使用工具。Windows 对用户已放入 PATH（系统
  可执行文件搜索目录）的语言服务器仍执行发现，缺失时说明如何安装和重试。
  Bun 仍由用户安装；此修复没有引入托管运行时下载机制。
- “已是最新版”只在成功检查且没有更新时显示。自动检查隐藏已跳过版本时
  返回空闲状态，不将隐藏结果解释成最新版。菜单提示明确主程序与扩展独立更新。

正确做法：先检查工具，检查失败就保留已安装扩展并显示错误。
不要这样做：先清空扩展状态，再用安装失败通知代替真实的安装状态。

## 考虑过的备选方案

本地 HTTP 静态服务器能进一步支持模块脚本和自动刷新，但需要增加端口、
文件访问边界及工作区清理责任。这次修复的是浏览器选择，直接复用平台能力
可以避免引入服务器生命周期。自动下载 Bun 属于独立的运行时分发能力，需要
版本、校验、许可和资源复用规则；不能用未校验的安装脚本临时补齐。

## 后果

两端不再随 HTML 文件关联跳进编辑器。Windows 对主程序版本和语言依赖的
提示更准确，依赖检查失败不再破坏旧扩展。代价是 Windows 多一个成熟库依赖，
语言工具安装仍要求用户准备所需运行时，普通文件预览仍受浏览器 file URL 限制。

## 验证

- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/test-macos.sh`：包含 `HTMLBrowserOpenerTests`。
- `windows/tauri/src-tauri/src/html_browser.rs` 的测试验证文件 URL、输入边界和失败传播。
- Windows 前端的扩展生命周期测试验证缺失依赖时不卸载、不清状态；更新状态
  测试验证隐藏更新和请求失败不显示最新版。
- 实机验证需把 HTML 关联改为编辑器，再检查浏览器按钮；当前 Linux 环境
  不能代替 macOS AppKit 和 Windows 默认浏览器运行验证，矩阵保留待验证状态。

## 适用范围

`macos/Sources/Lithe/Platform/MacOS/UI/`、
`macos/Sources/Lithe/Views/Editor/HTMLPreviewView.swift`、
`windows/tauri/src-tauri/src/html_browser.rs`、
`windows/tauri/src-tauri/src/language_tools.rs`、
`windows/tauri/src/extensions/registry/extension-store-lifecycle.ts`、
`windows/tauri/src/features/settings/`。
