# Agent 笔记：macOS 全局默认字体随安装包分发

状态：已实现

## 先说结论

用户要求整个 App 默认使用 JetBrains Mono 2.304。macOS 界面的字体统一从
`LitheTheme.uiFont` 和 `uiNSFont` 获取，保留每个控件的字号和字重。
字体文件随安装包分发，用户无需自行安装；运行时只读加载。

## 问题

已有四个 JetBrains Mono 字型已是 2.304，但多数页面显式使用系统字体，
设置页另用 Inter，输出和终端另有默认字族。只修改根视图的默认字体会被
这些局部设置覆盖。内嵌编辑器还有独立的网页进程，不能依赖原生注册。

## 决策

复用共享主题入口，替换显式字体调用，不改变控件字号、字重、动作和文本颜色。
语义文字样式先读取原生字号，再使用打包字体。中文等字体不包含的字形由系统
回退渲染。IDEA SVG 的几何形状和大小保持其资源定义。

`macos/Resources/Fonts` 保存用户提供的 2.304 原始静态字型、OFL 许可和作者
信息，16 个字型覆盖各字重及斜体。构建脚本在签名前复制到 app 的 `Fonts`
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

所有 app 自有界面的默认字族一致，字体版本可核对。代价是安装包增加字型，
等宽文字会改变标签的自然宽度；Git Log 日期列因此按实际字体测量。
操作系统管理的窗口装饰与系统对话框字体仍由 macOS 决定。Windows 本次不变。

## 验证

`BundledUIFontTests` 以临时 bundle 验证 16 字型版本、注册来源、重复注册、
原生字号和字重、SwiftUI 实际字宽，以及注册前后的文件清单和 SHA-256。
同一测试覆盖网页资源 adapter 的字体请求和目录逃逸拒绝。

```bash
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter BundledUIFontTests
node scripts/test-reuse-worktree-resources.mjs
./scripts/verify-runtime-bundle-immutability.sh
./scripts/verify-agent-notes.sh
```

完整安装包由 `scripts/verify-macos-package.sh` 检查全部字型及许可信息。
按用户要求未启动预览，实际窗口的字体回退及布局仍须人工确认。

## 适用范围

- `macos/Sources/Lithe/Theme/LitheTheme.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/MacBundledFontRegistry.swift`
- `macos/Sources/Lithe/Platform/MacOS/MonacoWorkbenchEditor.swift`
- `macos/EditorFrontend`
- `macos/Resources/Fonts`
- `scripts/worktree-resources.json`
