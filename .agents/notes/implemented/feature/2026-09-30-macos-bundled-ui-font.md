# Agent 笔记：macOS 全局默认字体随安装包分发

状态：已实现

## 先说结论

截图核对后，用户要求界面字体与 IDEA 对齐。macOS 普通界面使用已有的 Inter，
编辑器、终端及显式等宽内容继续使用 JetBrains Mono 2.304。普通界面统一从
`LitheTheme.uiFont` 和 `uiNSFont` 获取，代码与终端使用 `editorFont`；保留控件字重，
Project 树字号对齐 IDEA 的 13pt。欢迎页应用名、导航、普通项目名和常规操作按钮按 IDEA 使用 Regular，避免局部 Medium/SemiBold 覆盖默认字重。
字体文件随安装包分发，用户无需自行安装；运行时只读加载。

## 问题

此前把所有页面统一为 JetBrains Mono 后，Project 树与 Git 列表相较 IDEA
显得更宽、更实。IDEA 普通界面使用 Inter，代码编辑器才使用 JetBrains Mono。
此前仅有 Inter 3.019 Regular/SemiBold，Medium、Bold 请求会匹配到 SemiBold；用户提供 Inter 4.1 完整发行包后，用其静态字型替换旧版，无需新增运行时下载或依赖。只修改根视图的默认字体会被
这些局部设置覆盖。内嵌编辑器还有独立的网页进程，不能依赖原生注册。

## 决策

复用共享主题入口，替换显式字体调用，不改变控件字号、字重、动作和文本颜色。
语义文字样式先读取原生字号，再使用打包字体。中文等字体不包含的字形由系统
回退渲染。IDEA SVG 的几何形状和大小保持其资源定义。

`macos/Resources/Fonts` 保存用户提供的 Inter 4.1 包中的 18 个原始静态 OTF（9 个字重及斜体，文件内部版本为 4.001）、许可，以及
JetBrains Mono 2.304 的 16 个原始静态 TTF、OFL 和作者信息。Mono 文件与用户再次提供的归档逐文件核对，16 个文件均字节一致。
普通 UI 通过明确的字型名称匹配 Regular、Medium、SemiBold、Bold 等真实字重；SwiftUI 不再对已经指定字型的字体重复调用 `.weight`。
代码和终端继续读取 Mono 字型。构建脚本在签名前复制到 app 的 `Fonts`
资源目录；CoreText（macOS 的字体管理服务）按 process 范围注册，即只对当前
进程生效，不安装到用户系统。不能因机器已经装有同名字体而跳过打包资源。

Monaco 网页通过现有只读资源 adapter 加载同一字体目录。资源 adapter 要拒绝
目录逃逸和非 TTF 请求；网页加载字体后重新测量文字宽度，避免缓存回退字体的
度量。字体文件不在运行时下载、解压或修改，不改变签名或 Sparkle 增量更新
所需的发行基线。工作树通过 Git 获取源文件，资源复用脚本拒绝从另一份产物
或已签名安装包复制字体。

## 考虑过的备选方案

- 只给根视图加字体：改动少，但不能覆盖显式 SwiftUI 字体及原生文字控件。
- 依赖用户安装字体：包更小，但版本随机器变化，也无法保证网页进程可用。
- 只保留 Regular/Bold：文件少，但 Medium、SemiBold 和轻字重会依赖合成，
  难以保留界面原有文字层次。

## 后果

普通界面使用比例字体，代码和终端使用等宽字体，字体来源均可核对。
Git Log 日期列按实际 UI 字体测量，避免换字体后宽度仍沿用编辑器字体。
操作系统管理的窗口装饰与系统对话框字体仍由 macOS 决定。Windows 本次不变。

## 验证

`BundledUIFontTests` 以临时 bundle 验证 34 个字型的注册来源、Inter/Mono 版本、重复注册、
原生 UI/代码字体分工和 Regular/Medium/SemiBold/Bold/Black 的真实字型匹配、SwiftUI/AppKit 实际字宽，以及注册前后的文件清单和 SHA-256。
同一测试覆盖网页资源 adapter 的字体请求和目录逃逸拒绝。

```bash
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter BundledUIFontTests
node scripts/test-reuse-worktree-resources.mjs
./scripts/verify-runtime-bundle-immutability.sh
./scripts/verify-agent-notes.sh
```

完整安装包由 `scripts/verify-macos-package.sh` 检查全部字型及许可信息。
本次字体注册/字重与明暗弹窗圆角渲染测试通过；按用户要求不启动预览，当前运行界面的视觉验收尚未完成。Windows 原生界面不在本次验证范围内。

## 适用范围

- `macos/Sources/Lithe/Theme/LitheTheme.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/MacBundledFontRegistry.swift`
- `macos/Sources/Lithe/Platform/MacOS/MonacoWorkbenchEditor.swift`
- `macos/EditorFrontend`
- `macos/Resources/Fonts`
- `scripts/worktree-resources.json`
