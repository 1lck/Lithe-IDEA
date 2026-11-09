# Agent 笔记：macOS Markdown 的离线 PlantUML 预览

状态：已实现

## 先说结论

macOS Markdown 的 `plantuml` 代码块使用官方 JavaScript 引擎离线渲染，不发送文档到服务器，
也不要求用户安装 Java 或 Graphviz。渲染使用独立、非持久的 WebKit 页面，完成后只把
被动 SVG 图片交给正文，不能把图中的 SVG 脚本或链接变成宿主页面能力。
基础时序图和类图在范围内；跨文件 include、可选标准库及主题没有开放。

## 问题

Issue #706 提出图表支持，原实现只保留 `language-plantuml` 类名，并没有执行渲染。
因此“代码块存在”不代表用户能看到图。官方现在提供 MIT 许可的 `@plantuml/core` 1.2026.9，
内置的 Smetana 是用来计算类图节点位置的布局引擎，可直接复用，不需要新写 UML 解析器。

## 决策

- 引擎来自固定 npm 归档，先验证 SHA-512，保存未修改的脚本、MIT 许可和上游声明，
  来源 revision 和提取文件 SHA-256 放在 `THIRD_PARTY_NOTICES.md`。旧版许可不同，不得替换为旧版。
- 只在遇到 PlantUML 时创建渲染 WebView，固定协议只提供模板、引擎和入口三个文件。
  不授予用户文件读取接口，网页内容安全策略（CSP，限制网页可加载哪些资源）禁止网络、
  iframe 和外部图片；上游 include/标准库加载钩子显式拒绝，不能把路径转交工作区资源解析器。
- 一次只处理一个图，源码最多 256KiB，SVG 最多 4MiB，尺寸最多 4096px，
  主线程拥有八秒期限。完成、失败、取消、替代请求和关闭预览都撤销期限、停止加载、断开委托，
  放弃该非持久 WebView。迟到回调按请求 UUID 丢弃，正文同时按 render version 丢弃旧文档结果。
- SVG 通过 `data:image/svg+xml;base64,...` 作为 `img` 显示，不赋给 `innerHTML`。
  正确做法是让浏览器按图片加载 SVG；不要因为来源是成熟上游，就把用户可影响的 SVG 当成宿主 HTML。
  图片保留原有点击放大；无法渲染时保留源码，并用共享 i18n 的本地化提示说明失败。
- `WKProcessPool` 在新 WebKit 已不提供进程隔离，因此不使用它，也不声称独立 WebView 等于独立 OS 进程。
  原生期限可以释放宿主的请求和 WebView，不能据此承诺终止共享 WebKit 进程中的任意死循环。

## 考虑过的备选方案

- 在线 PlantUML 服务器：会外发用户文档，断网不能用，不采用。
- Java 子进程或另带 Graphviz/WASM：增加体积、工具链和生命周期成本。官方内置 Smetana 已能处理
  本次验证的时序图和类图，所以不打包 Viz.js、Graphviz、主题、emoji 或额外标准库。
- 在预览正文直接加载引擎或使用隐藏 iframe：引擎需要 DOM，普通 Worker 不适用；
  iframe 与正文可能共用线程，且页面内定时器会受繁忙 JavaScript 阻塞，不把它当作有界执行保证。
- 按 PlantUML 指令名自行过滤源码：变量、预处理器和语法仍归成熟上游，安全边界放在资源白名单、
  无文件加载能力、CSP、预算和被动图片输出，不再写一套语法检查器。

## 后果

常见 PlantUML 图可以离线显示，正文不新增网络能力，现有 Mermaid、数学和普通图片流程保持。
代价是每个图建立独立渲染上下文，串行处理限制内存但大量图会依次完成；复杂或被上游不支持的图仍可能失败。
跨文件 include 失败保留原文，不静默读取磁盘；无效语法也可能由上游生成诊断图片，保持上游原始诊断。

模板、引擎和许可是 Git 输入，构建时复制后签名。运行时只有源码、回调和图片的内存状态，
不下载、不生成缓存、不写 bundle，不改变代码签名或 Sparkle 增量基线。
资源复用清单显式拒绝跨工作树复制这些生成 bundle 或运行态；Windows 产品不在本次范围内。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter MarkdownPlantUMLTests`：
  真实 WebKit 在深浅主题渲染时序图、类图，逐文件比较运行前后的打包资源 SHA-256；
  验证取消、超大输入拒绝、正文被动图片、include 拒绝时源码/本地化回退、旧结果隔离。
- `node --test scripts/macos/test/test-markdown-preview.mjs`：既有目录与刷新状态回归。
- `node --test scripts/resources/test-reuse-worktree-resources.mjs`：资源隔离与固定身份。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`。
- `node scripts/i18n/generate-i18n.mjs --check`。

组件运行验证不代替完整应用视觉验收；不以本地新编译器通过冒充 CI 固定工具链通过。

## 适用范围

- ~~`macos/Sources/Lithe/Platform/MacOS/MarkdownPlantUMLRenderer.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Platform/MacOS/MarkdownPreviewWebView.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Resources/MarkdownPreview/`~~（已随 #1794 移除）
- ~~`macos/Tests/LitheTests/MarkdownPlantUMLTests.swift`~~（已随 #1794 移除）
- `scripts/resources/worktree-resources.json`
