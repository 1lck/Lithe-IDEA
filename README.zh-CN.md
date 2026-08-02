<p align="center">
  <img src="./Resources/AppIcon.png" width="128" alt="Lithe 应用图标">
</p>

<h1 align="center">Lithe</h1>

<p align="center">
  <strong>一款轻量、原生、贴近 IntelliJ IDEA 核心体验的 macOS IDE</strong>
</p>

<p align="center">
  保留熟悉的 IDE 工作方式，降低内存占用。
</p>

<p align="center">
  <a href="./README.md">English</a>
</p>

<p align="center">
  <a href="#产品截图">产品截图</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#为什么需要-lithe">为什么需要 Lithe</a> ·
  <a href="#lithe-与-intellij-idea">Lithe 与 IDEA</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-111827?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.2%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.2+">
  <img src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-0A84FF?style=flat-square" alt="SwiftUI 和 AppKit">
  <img src="https://img.shields.io/badge/status-active%20development-F59E0B?style=flat-square" alt="积极开发中">
</p>

<p align="center">
  <img src="./docs/visual-qa/07-git-history-graph.png" width="92%" alt="Lithe Git 历史图">
</p>

## 为什么需要 Lithe

大多数开发者不需要重新学习一套工作方式。他们需要的是熟悉的 IDE 核心能力——项目浏览、编辑器、搜索、代码导航、Git、运行和调试——但不希望为了每一个任务都承担大型 IDE 的完整资源占用。

Lithe 就是围绕这个目标设计的：使用原生 macOS 技术实现 IDE 的核心工作流，保持 IntelliJ IDEA 用户熟悉的交互方式，并让重量级服务只在需要时启动。

我们的目标不是做一个“看起来像 IDE 的编辑器”，而是提供一个真正可用的轻量替代方案：打开项目、阅读和编辑代码、搜索和导航、运行程序、查看结果，再审查 Git 修改。

> **熟悉的 IDE 核心体验，更轻的资源占用。**

AI 辅助开发是 Lithe 最重要的使用场景之一。当外部 AI 工具修改项目后，Lithe 可以观察这些变化、定位受影响的 Java 代码、运行项目、查看 Diff，并让人决定哪些修改应该被保留。

```text
打开项目
    ↓
浏览 / 编辑 / 搜索 / 代码导航
    ↓
运行 / Maven / Debug
    ↓
审查 Git 修改 → 暂存、撤销或提交
    ↓
可选：检查外部 AI 工具产生的修改
```

你不需要卸载 IntelliJ IDEA，也不需要重新学习一套完全陌生的操作方式。Lithe 面向日常 IDE 核心工作流提供更轻量的替代方案，而 IDEA 仍然可以继续承担高级编码和更丰富的插件生态。

## Lithe 与 IntelliJ IDEA

Lithe 希望用更轻量的原生应用替代日常 IDE 核心工作流，但不试图覆盖 IntelliJ IDEA 的所有高级能力。

| 方面 | IntelliJ IDEA | Lithe |
| --- | --- | --- |
| 核心定位 | 完整的 Java / 多语言 IDE | 面向日常核心工作流的轻量 IDEA 风格 IDE |
| 深度编码 | 补全、重构、插件和大型项目能力完整 | 面向阅读和少量人工修正，不重复建设完整编码平台 |
| 外部 AI 修改 | 可以完成，但通常需要在完整 IDE 中进入审查流程 | 外部变化监听、冲突提示、Diff 和 Local History 是一等能力 |
| Git 工作流 | 覆盖广泛的版本控制能力 | 以 Changes、并排 Diff、代码块操作和接受/撤销决策为中心 |
| Java 能力 | 完整 Java 工程体验 | 复用 Eclipse JDT LS，覆盖定义、引用、诊断和基础 Debug |
| 启动与资源 | 完整 IDE 平台，能力更广 | 原生 SwiftUI/AppKit，Java 服务和运行进程按需启动 |
| 上手方式 | IDEA 用户已经熟悉 | 延续 Project、Changes、Search、Editor、Diff 等既有习惯 |

### Lithe 可以替换的核心工作流

- 打开 Java 项目、浏览文件、修改少量代码并保存。
- 搜索项目、跳转 Java 定义和引用，并查看诊断信息。
- 运行 Maven、Spring Boot 或当前 Java 文件，并查看运行结果。
- 审查 Git 修改，暂存、撤销、提交或只处理某个代码块。
- 在不改变熟悉 IDE 习惯的情况下，检查外部 AI 工具产生的修改。

### IDEA 仍然更适合哪些场景

完整代码补全、复杂重构、自动导包、丰富插件生态、多语言工程、测试树和覆盖率等深度开发场景，仍然属于 IDEA 的优势。Lithe 不要求你放弃这些能力，而是为日常 IDE 核心工作流提供更低开销的替代方案，并让 AI 修改后的代码更容易被检查。

## 性能与熟悉的工作流

### 原生、轻量、按需启动

Lithe 使用 SwiftUI 与 AppKit 构建，不内置 Chromium，也不维护一套完整 IDE 级别的常驻工程模型：

- Java 语言服务只在 Java 项目需要时启动。
- 终端、Maven、Run 和 Debug 进程只在用户触发时启动。
- 搜索使用轻量磁盘索引，Local History 使用磁盘快照，不把历史正文长期放在内存中。
- 关闭项目时停止文件监听、语言服务、终端和运行/调试进程。

当前开发机基线中，Welcome 空闲状态约占 **86 MB**；产品目标是 Welcome 低于 **150 MB**、普通项目低于 **300 MB**。这组数据是开发阶段基线，不替代后续在不同规模项目上的压力测试。

### 不需要重新学习 IDE 习惯

Lithe 的信息架构和操作路径刻意贴近 IDEA：Project、Changes、Search、Editor、Diff、Maven、Run 和 Debug 都有对应入口；常用的 `⌘F` 文件查找、`⌘B` 调用位置和双 Shift Search Everywhere 也保持在熟悉的位置。

因此，Lithe 的切换成本不是“重新学一款 IDE”，而是使用一套保留熟悉概念、但内存占用更低的工作台。

## 产品截图

<p align="center">
  <img src="./docs/visual-qa/00-welcome-projects.png" width="49%" alt="Welcome 和最近项目">
  <img src="./docs/visual-qa/01-java-editor-project-tree.png" width="49%" alt="Java 编辑器和项目树">
</p>

<p align="center">
  <img src="./docs/visual-qa/09-search-everywhere-results.png" width="49%" alt="Search Everywhere">
  <img src="./docs/visual-qa/13-spring-boot-usages.png" width="49%" alt="JDT LS Java 引用结果">
</p>

<p align="center">
  <img src="./docs/visual-qa/08-git-diff-green-state.png" width="49%" alt="Git Diff 审查">
  <img src="./docs/visual-qa/14-spring-boot-run-configuration.png" width="49%" alt="Spring Boot 运行配置">
</p>

## 功能

| 工作流 | Lithe 提供的能力 |
| --- | --- |
| 项目浏览 | Welcome Screen、最近项目、文件树、文件类型图标、路径面包屑和工作台状态恢复 |
| 代码阅读 | 多标签原生编辑器、基础 Java 高亮、代码折叠、行号、保存和未保存状态 |
| Java 导航 | 基于 Eclipse JDT LS 的定义、引用、实现、Workspace Symbol 和实时诊断 |
| 搜索 | 文件名、路径、全文搜索、Search Everywhere、大小写/整词/正则匹配和项目替换 |
| 外部变化 | FSEvents 监听、新增/删除/修改刷新，以及磁盘版本和编辑器版本冲突提示 |
| Git 审查 | Changes、并排 Diff、Diff 搜索、代码块级暂存/撤销、Commit、Shelf、分支和 Git Graph |
| 构建运行 | Maven 根项目、多模块、Profiles、Lifecycle、Build Output、Current File、Spring Boot 和 Maven Module |
| Java Debug | 本地 JDWP、Maven/Spring Boot Debug、Remote JVM/Tomcat attach、断点、单步、线程和变量查询 |
| 工作效率 | 项目级 Local History、内置终端、可拖拽工具窗口和分栏布局恢复 |
| 更新 | 检查最新 GitHub Release，并打开下载页面进行手动更新 |

## 快速开始

### 环境要求

- macOS 14 或更高版本
- Swift 6.2 或更高版本
- Java 项目功能需要 JDK；建议使用 JDK 17 或 JDK 21
- Java 语义导航需要 Eclipse JDT LS
- Maven 项目需要项目自带 `mvnw`，或系统中可用的 Maven

使用 Homebrew 安装 JDT LS：

```bash
brew install jdtls
```

### 运行开发版本

在项目根目录执行：

```bash
swift run --disable-sandbox Lithe
```

也可以使用预览脚本：

```bash
./scripts/preview.sh
```

### 构建 App Bundle

```bash
./scripts/package-app.sh
open dist/Lithe.app
```

### 下载发布版本

从 [GitHub Releases](https://github.com/1lck/Lithe-IDEA/releases/latest) 下载已发布版本。Lithe 可以检查是否有更新并打开下载页面，但当前更新方式是手动的：退出 Lithe，将新的 `Lithe.app` 替换到 `/Applications`，然后重新打开。

如果 macOS 阻止打开来自未识别开发者的 App，可以先右键点击 App 并选择 **打开**；也可以在尝试启动后进入 **系统设置 → 隐私与安全性 → 仍要打开**。

只有在确认 App 来自 Lithe 官方 GitHub Release 的情况下，如果 macOS 仍然阻止打开，可以执行：

```bash
xattr -dr com.apple.quarantine "/Applications/Lithe.app"
open "/Applications/Lithe.app"
```

这只会移除该 App 的下载隔离标记，不会自动安装更新，也不会全局关闭 Gatekeeper。

### 检查核心功能

项目提供不依赖 UI 的核心检查脚本：

```bash
./scripts/verify-core.sh
./scripts/verify-git-graph.sh
```

它们会覆盖 Diff、文件可见性、搜索匹配、Git Graph、空白过滤、stash、clone 以及真实 Merge/Tag/Remote 引用布局。

## 配置 Java 与 Maven

打开项目后，在 **Settings → Project** 中可以配置：

- Project JDK
- Maven Wrapper、系统 Maven 或自定义 Maven Home
- Maven 使用的 JDK

Lithe 会从 `JAVA_HOME`、macOS `java_home`、标准 JDK 目录以及 Homebrew JDK 目录中探测 Java；Maven 会从项目 `mvnw`、`MAVEN_HOME`、`PATH` 以及常见 Homebrew/系统目录中探测。选择结果按项目保存在本机应用设置中，不会把机器相关路径写入仓库。上述设置会被 Current File、Maven、Spring Boot、Maven Module、Debug 和 JDT LS 共享。运行配置仍然可以通过 **JDK Home** 对单次运行进行覆盖。

## 设计边界

Lithe 当前专注于 macOS 上的 Java 项目阅读、运行和 Git 审查，不包含以下能力：

- AI 模型调用、Agent 会话和聊天界面
- Java 以外语言的 LSP 和代码智能
- 传统代码补全、自动导包、快速修复和安全重命名
- 测试识别、测试树、覆盖率和完整测试运行器
- 三方冲突解决、多根工作区和插件市场

Current File 使用 Java source-file mode，适合快速运行单文件示例；依赖同项目其他源码的场景建议使用 Maven Module 或 Spring Boot 运行配置。

## 技术架构

```text
SwiftUI Workbench
├── Welcome / Recent Projects
├── Project / Changes / Search
├── Editor Tabs / Diff Review
└── Run / Debug / Maven / Terminal
          ↓
AppKit NSTextView     FSEvents       System Git       JDT LS
原生文本编辑          外部变化       Git 审查         Java 语义服务
```

项目使用 Swift Package Manager，不依赖第三方 Swift Package：

```text
Sources/Lithe/
├── Models/       工作区、编辑器、Git、Java 与运行配置模型
├── Services/     文件扫描、搜索、Git、Maven、Java、Local History
├── Theme/        Lithe 视觉令牌和图标
└── Views/        Welcome、Workbench、Editor、Diff 和工具窗口
```

## 当前状态

Lithe 目前处于积极开发阶段，已经形成从打开项目、阅读代码、观察外部变化、审查 Diff、运行 Maven/Java 到提交 Git 修改的主闭环。

| 状态 | 范围 |
| --- | --- |
| 当前可用 | Welcome、项目树、编辑器、搜索、外部变化、Git/Diff、Local History、终端、Maven、基础 Run/Debug |
| 正在完善 | Java 导航边界、Current File 跨文件运行和大项目性能 |
| 计划中 | 自动化测试、更多 Java 工作流和动态交互细节 |

## 项目结构

```text
Lithe-IDEA/
├── Sources/Lithe/          # SwiftUI / AppKit 源码
├── Resources/              # Info.plist、应用图标和 IDEA 风格资源
├── Fixtures/               # Maven / Spring Boot 示例项目和 Git 历史夹具
├── scripts/                # 构建、打包和核心检查脚本
├── docs/                   # 补充文档和示例资料
├── Package.swift
├── README.md               # English README
└── README.zh-CN.md         # 简体中文 README
```

## 参与开发

如果你想参与 Lithe，建议按下面的顺序开始：

1. 先了解上面的功能范围和设计边界。
2. 使用 `./scripts/verify-core.sh` 和 `./scripts/verify-git-graph.sh` 验证核心逻辑。
3. 在真实 Java/Maven 项目上验证 UI 和运行时行为，再提交功能改动。
4. 提交改动时说明验证方式和已知限制。

## License

Lithe 采用 [Apache License 2.0](./LICENSE) 授权。
