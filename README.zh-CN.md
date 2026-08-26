<div align="center">
  <img src="./macos/Resources/AppIcon.png" width="112" alt="Lithe 应用图标">

  <h1>Lithe</h1>

  <p><strong>面向 AI 编程时代的轻量级 IDEA 替代品</strong></p>
  <p>保留 IDEA 核心工作流 · 基础内存约 300～400 MB · 工具按需启动</p>
  <p><em>让 Codex 或 Claude Code 写代码，用 Lithe 看懂、跑通、调试并审查。</em></p>

  <p>
    <a href="./README.md"><strong>English</strong></a> ·
    <a href="#核心功能">核心功能</a> ·
    <a href="#产品截图">产品截图</a> ·
    <a href="#下载与安装">下载</a> ·
    <a href="#架构概览">架构图</a> ·
    <a href="#如何开发">如何开发</a> ·
    <a href="#联系我们">联系我们</a>
  </p>

  <p>
    <a href="https://github.com/1lck/Lithe-IDEA/releases/latest"><img src="https://img.shields.io/github/v/release/1lck/Lithe-IDEA?style=for-the-badge&label=latest%20release&logo=github&logoColor=white" alt="最新版本"></a>
    <img src="https://img.shields.io/badge/platform-macOS%2013%2B-111827?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 13+">
    <img src="https://img.shields.io/badge/platform-Windows%20x64-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows x64">
  </p>
  <p>
    <img src="https://img.shields.io/badge/Java-JDK%2017%2B-E76F00?style=for-the-badge&logo=openjdk&logoColor=white" alt="JDK 17+">
    <img src="https://img.shields.io/badge/workflow-IDEA--style-7C3AED?style=for-the-badge&logo=intellijidea&logoColor=white" alt="IDEA 风格工作流">
    <img src="https://img.shields.io/badge/baseline%20memory-300--400%20MB-159957?style=for-the-badge" alt="基础内存 300 到 400 MB">
    <a href="./LICENSE"><img src="https://img.shields.io/github/license/1lck/Lithe-IDEA?style=for-the-badge&label=license" alt="Apache License 2.0"></a>
  </p>

  <p>
    <a href="https://github.com/1lck/Lithe-IDEA/releases/latest"><strong>下载最新版本</strong></a> ·
    <a href="https://github.com/1lck/Lithe-IDEA">查看 GitHub 仓库</a>
  </p>
</div>

## 为什么做 Lithe

Codex、Claude Code 等 AI 编程工具已经可以承担大量编码工作，但开发者仍然需要 IDE 来理解生成的代码、跳转符号、运行调试项目并审查每一次修改。只为完成这些工作而常驻一套占用数 GB 内存的开发环境，显得越来越沉重。

## Lithe 是什么

Lithe 是一款主要面向 Java 和 Spring Boot 开发者的轻量级 IDEA 替代品，保留项目浏览、代码编辑与导航、搜索、Maven、运行调试、Git Diff、本地历史和数据库等核心工作流。

打开普通项目后，Lithe 应用本身的基础内存占用通常约为 **300～400 MB**。语言服务器、终端、构建工具、调试器和数据库组件均按需启动；实际占用会随项目和启用的服务变化。

> **AI 负责编写代码，Lithe 负责帮你看懂、跑通并审查修改。**

## 核心功能

1. 适配 Spring Boot 项目体系，适合 Java 开发。
2. 支持 Maven 管理、断点调试和自定义启动配置。
3. 支持 Git 管理和 Diff 审查。
4. 支持双击 Shift 搜索，以及 `Command + Shift + F` 全局搜索。
5. 支持无需 LSP 的轻量补全和当前文件导航，并可按需使用语言服务器增强补全、悬浮与语义导航。
6. 支持本地快照保存。
7. 支持在应用内打开多个项目。
8. 支持在同一窗口打开多个文件，各文件相互独立。
9. 支持使用 AI 自动生成 Commit Message，并可自定义格式。
10. 支持多种 Markdown 语法渲染，与语雀一致。
11. 支持查看应用的本地内存占用情况。
12. 支持通过 Homebrew 一键安装和更新。
13. 支持在应用内一键更新并安装。
14. 自动识别 Spring Boot、Java、Maven、Gradle、npm、Cargo、Go、Python、Make、Docker Compose、Procfile 和 Shell 项目的可运行入口，并支持一键运行。
15. 支持按语言独立开关语言服务，可根据电脑配置自由启用或停用。
16. 支持类似 IDEA 的多行编辑器标签，同时展示更多打开的文件。
17. 新增数据库连接工作台，支持多种数据库类型、连接管理、SQL 历史、表浏览和数据库操作。
18. 持续修复问题并优化用户体验。

## 产品截图

<p align="center">
  <img src="./docs/assets/screenshots/search-everywhere.png" width="49%" alt="双击 Shift 全局搜索">
  <img src="./docs/assets/screenshots/global-search.png" width="49%" alt="Command Shift F 全局搜索和替换">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/git-diff-review.png" width="96%" alt="Git 双栏 Diff 审查">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/ai-provider-import.png" width="49%" alt="从本机 AI 工具导入 API 配置">
  <img src="./docs/assets/screenshots/ai-commit-format.png" width="49%" alt="自定义 AI Commit Message 格式">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/ai-commit-message.png" width="96%" alt="使用 AI 自动生成 Commit Message">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/markdown-mermaid-preview.png" width="49%" alt="Markdown Mermaid 图表渲染和实时预览">
  <img src="./docs/assets/screenshots/markdown-rich-preview.png" width="49%" alt="Markdown 多语法渲染和实时预览">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/memory-monitor-annotated.png" width="49%" alt="低内存占用和应用内存监控">
  <img src="./docs/assets/screenshots/memory-monitor.png" width="49%" alt="应用内存占用详情">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/project-auto-detection-run.png" width="96%" alt="项目自动识别和一键运行配置">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/language-services-settings.png" width="49%" alt="按语言配置语言服务">
  <img src="./docs/assets/screenshots/multi-line-editor-tabs.png" width="49%" alt="多行编辑器标签">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/database-workspace-overview.png" width="49%" alt="数据库连接工作台">
  <img src="./docs/assets/screenshots/database-sql-operation.png" width="49%" alt="数据库 SQL 操作和表结构">
</p>

## 下载与安装

- **macOS 13+：**前往 [GitHub Releases](https://github.com/1lck/Lithe-IDEA/releases/latest) 下载 `.dmg`。M 系列芯片选择 `arm64`，Intel 芯片选择 `x86_64`。
- **Windows x64：**前往 [GitHub Releases](https://github.com/1lck/Lithe-IDEA/releases/latest) 下载 Windows `.exe` 安装包。

macOS 推荐使用 Homebrew 安装和更新：

```bash
brew tap 1lck/lithe https://github.com/1lck/Lithe-IDEA.git
brew install --cask 1lck/lithe/lithe
brew upgrade --cask lithe
```

Java 功能需要 JDK 17 或更高版本。正式安装包已包含 Eclipse JDT Language Server，无需单独安装 JDTLS。

## 架构概览

macOS 是当前参考产品，Windows 是独立的 React/Tauri 实现。两端通过 Rust Core 共享确定性命令与契约，同时保持原生界面和平台能力相互独立。

```mermaid
flowchart LR
    subgraph macOS["macOS"]
        MacUI["SwiftUI / AppKit 工作台"] --> MacApp["应用模型与服务"]
        MacApp --> MacAdapters["macOS 适配器"]
    end

    subgraph Shared["共享行为"]
        Contracts["JSON 契约与 Fixtures"] --> Core["Rust lithe-core"]
    end

    subgraph Windows["Windows"]
        WinUI["React 工作台"] --> WinFeatures["TypeScript Features 与 Stores"]
        WinFeatures --> Tauri["Tauri 2 Host 与 Windows 适配器"]
    end

    MacApp -->|"JSON C ABI"| Core
    Tauri -->|"Rust crate"| Core
```

## 如何开发

开发环境需要 Swift 6.2 或更高版本。运行完整测试需要 Xcode；基础 SwiftPM 构建只需要 Command Line Tools。

在项目根目录运行开发版本：

```bash
./scripts/preview.sh
```

该脚本会构建并链接 Rust Core，然后启动 macOS 应用。只验证 Swift 源码时可以运行：

```bash
swift run --disable-sandbox Lithe
```

构建 App Bundle：

```bash
./scripts/package-app.sh
open dist/Lithe.app
```

提交改动前运行：

```bash
./scripts/test-macos.sh
./scripts/verify-core.sh
./scripts/verify-git-graph.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-windows-boundaries.sh
./scripts/verify-rust-core.sh
```

目录归属、跨平台边界、共享规则以及 Rust Core 必须遵守的注释规范见[仓库目录与共享边界](./docs/architecture/repository-layout.md)。提交功能改动时，请说明验证方式和已知限制。

## 项目支持

### ❤️ 赞助商

<table>
  <tr>
    <td width="112" align="center">
      <a href="https://www.fastaitoken.com/">
        <img src="./docs/assets/sponsors/fastai.png" width="64" alt="FastAI">
      </a>
    </td>
    <td>
      <a href="https://www.fastaitoken.com/"><strong>FastAI</strong></a> 提供多款主流大模型的便捷中转服务，让开发者可以更轻松地把 AI 能力接入日常开发流程。其支持也帮助 Lithe 持续完善 AI 辅助体验。感谢 FastAI 对本项目的支持！
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://codezsy.com">
        <img src="./docs/assets/sponsors/codez.png" width="64" alt="CodeZ 中转站">
      </a>
    </td>
    <td>
      <a href="https://codezsy.com"><strong>CodeZ</strong></a> 专注于 GPT 系列模型的稳定中转，为开发者在工具和项目中集成模型 API 提供简单直接的选择。其赞助为 Lithe 的持续开发与维护提供了助力。感谢 CodeZ 对本项目的支持！
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://api.axis.fan/register?aff=4EZFN7322WTH">
        <img src="./docs/assets/sponsors/yuanliu-token.png" width="64" alt="元流 Token">
      </a>
    </td>
    <td>
      <a href="https://api.axis.fan/register?aff=4EZFN7322WTH"><strong>元流 Token</strong></a> 提供多种大语言模型 API 的中转接入，为开发者体验不同模型、构建 AI 应用提供灵活入口。其赞助支持 Lithe 持续拓展并优化 AI 相关功能。感谢元流 Token 对本项目的支持！
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://torchai.ai">
        <img src="./docs/assets/sponsors/torchai.jpg" width="64" alt="TorchAI">
      </a>
    </td>
    <td>
      <a href="https://torchai.ai"><strong>TorchAI</strong></a> 面向开发者提供大模型中转服务，便于在编程、内容生成和自动化等不同场景中调用模型 API。其支持帮助 Lithe 保持持续开发，并探索更实用的 AI 工具体验。感谢 TorchAI 对本项目的支持！
    </td>
  </tr>
</table>

### ⭐ 特别鸣谢

<p align="center">
  <a href="https://linux.do/">
    <img src="./docs/assets/special-thanks/linux-do.png" width="78%" alt="LINUX DO">
  </a>
</p>

<p align="center">
  <strong>关于 AI 的一切，欢迎前往 <a href="https://linux.do/">LINUX DO</a>！祝社区越来越好～</strong>
</p>

### 贡献者

感谢所有参与 Lithe 开发和改进的贡献者。

<a href="https://github.com/1lck/Lithe-IDEA/graphs/contributors">
  <img src="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/contributors.svg" alt="贡献者">
</a>

### License

Lithe 采用 [Apache License 2.0](./LICENSE) 授权。

## Star History

每个日期点表示北京时间当天 `00:00` 时仓库的累计 Star 数。图表从 2026 年 8 月 2 日的 0 开始。

<a href="https://www.star-history.com/#1lck/Lithe-IDEA&Date">
  <img alt="Star History 图表" src="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/star-history-light.svg" />
</a>

## 联系我们

欢迎加入 Lithe-IDEA 交流群讨论使用体验、反馈问题，也可以直接联系作者。

<table align="center">
  <tr>
    <td align="center"><strong>加入交流群</strong></td>
    <td align="center"><strong>联系作者</strong></td>
  </tr>
  <tr>
    <td align="center"><img src="./docs/assets/contact/lithe-group.png" width="320" alt="Lithe-IDEA 交流群二维码"></td>
    <td align="center"><img src="./docs/assets/contact/wechat.png" width="320" alt="作者微信二维码"></td>
  </tr>
</table>
