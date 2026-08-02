<p align="center">
  <img src="./Resources/AppIcon.png" width="128" alt="Lithe 应用图标">
</p>

<h1 align="center">Lithe</h1>

<p align="center">
  <strong>面向 AI 编程工作流的原生 macOS 代码阅读、验证与 Git 审查工作台</strong>
</p>

<p align="center">
  让 AI 负责产出代码，让人负责看懂、验证，并决定哪些修改应该被保留。
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

AI 正在改变软件的编写方式：越来越多的代码由 AI 生成、修改和重构，而人真正需要投入时间的地方，变成了理解变化、验证结果，以及决定哪些改动值得进入项目。

IntelliJ IDEA 仍然是优秀的深度编码工作台。但当 AI 刚刚修改完一个项目时，开发者经常只需要快速浏览目录、阅读代码、定位引用、查看 Diff、运行验证，再接受或撤销改动。为了完成一次审查而启动完整 IDE，往往意味着更重的工作台、更长的等待，以及一套不必要的人工编写流程。

Lithe 就是为这个阶段设计的原生 macOS 工作台：它观察外部 AI 对同一个本地项目做的修改，把阅读、验证和 Git 决策放在同一条短路径里。

> **AI 负责产出代码，Lithe 负责让人看懂、验证，并决定是否接受。**

```text
AI 修改项目
    ↓
Lithe 自动发现变化
    ↓
浏览 / 搜索 / Java 导航
    ↓
运行 / Maven / Debug
    ↓
Diff 审查 → 暂存、撤销或提交
```

你不需要卸载 IntelliJ IDEA，也不需要重新学习一套完全陌生的操作方式。Lithe 保留 Project、Changes、Search、Editor、Diff、Run 和 Debug 等熟悉的信息架构，把 IDEA 用户已经形成的阅读和审查习惯带到 AI 原生开发流程里。

## Lithe 与 IntelliJ IDEA

Lithe 不是要在所有场景取代 IntelliJ IDEA。它要替代的是 AI 开发流程中那些“需要 IDE 的能力，但不需要完整 IDE 重量”的时刻。

| 方面 | IntelliJ IDEA | Lithe |
| --- | --- | --- |
| 核心定位 | 完整的 Java / 多语言 IDE | AI 修改后的代码阅读、验证与 Git 审查工作台 |
| 深度编码 | 补全、重构、插件和大型项目能力完整 | 面向阅读和少量人工修正，不重复建设完整编码平台 |
| 外部 AI 修改 | 可以完成，但通常需要在完整 IDE 中进入审查流程 | 外部变化监听、冲突提示、Diff 和 Local History 是一等能力 |
| Git 工作流 | 覆盖广泛的版本控制能力 | 以 Changes、并排 Diff、代码块操作和接受/撤销决策为中心 |
| Java 能力 | 完整 Java 工程体验 | 复用 Eclipse JDT LS，覆盖定义、引用、诊断和基础 Debug |
| 启动与资源 | 完整 IDE 平台，能力更广 | 原生 SwiftUI/AppKit，Java 服务和运行进程按需启动 |
| 上手方式 | IDEA 用户已经熟悉 | 延续 Project、Changes、Search、Editor、Diff 等既有习惯 |

### Lithe 可以替换 IDEA 的哪些时刻

- AI 刚刚修改完项目，需要快速知道改了什么、为什么改、有没有漏改。
- 不想启动完整 IDE，只需要浏览文件、全文搜索、跳转 Java 定义和查找引用。
- 需要对每一个 Diff 做决定：保留、撤销、暂存、提交，或只处理某个代码块。
- 需要快速运行 Maven、Spring Boot 或当前 Java 文件，并查看输出和问题。
- 需要在外部工具持续改代码时保留 Local History、冲突提示和稳定的阅读环境。

### IDEA 仍然更适合哪些场景

完整代码补全、复杂重构、自动导包、丰富插件生态、多语言工程、测试树和覆盖率等深度开发场景，仍然属于 IDEA 的优势。Lithe 的价值不是要求你放弃这些能力，而是让 AI 生成代码之后的审查环节变得更轻、更快、更集中。

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

因此，Lithe 的切换成本不是“重新学一款 IDE”，而是“在 AI 修改完成后打开一个更适合阅读和决策的工作台”。

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

Lithe 将以开源许可证发布。正式公开仓库前会补充 `LICENSE` 文件和完整的授权条款。
