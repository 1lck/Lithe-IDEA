<div align="center">
  <img src="./Resources/AppIcon.png" width="112" alt="Lithe app icon">

  <h1>Lithe</h1>

  <p><strong>The IDEA-shaped core for AI-assisted development</strong></p>
  <p>Native macOS IDE · familiar workflows · a lighter memory footprint</p>
  <p><em>AI writes the code. Lithe helps you see it, run it, and review it.</em></p>

  <p>
    <a href="./README.zh-CN.md"><strong>简体中文</strong></a> ·
    <a href="#core-features">Core features</a> ·
    <a href="#product-tour">Product tour</a> ·
    <a href="#use-lithe">Use Lithe</a> ·
    <a href="#architecture">Architecture</a> ·
    <a href="#develop-lithe">Develop Lithe</a> ·
    <a href="#contact-us">Contact us</a>
  </p>

  <p>
    <a href="https://github.com/1lck/Lithe-IDEA/releases/latest"><img src="https://img.shields.io/github/v/release/1lck/Lithe-IDEA?style=for-the-badge&label=latest%20release&logo=github&logoColor=white" alt="Latest release"></a>
    <img src="https://img.shields.io/badge/platform-macOS%2014%2B-111827?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Swift-6.2%2B-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 6.2+">
  </p>
  <p>
    <img src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="SwiftUI and AppKit">
    <img src="https://img.shields.io/badge/workflow-IDEA--style-7C3AED?style=for-the-badge&logo=intellijidea&logoColor=white" alt="IDEA-style workflow">
    <a href="./LICENSE"><img src="https://img.shields.io/github/license/1lck/Lithe-IDEA?style=for-the-badge&label=license" alt="Apache License 2.0"></a>
  </p>

  <p>1122
    <a href="https://github.com/1lck/Lithe-IDEA/releases/latest"><strong>Download the latest release</strong></a> ·
    <a href="https://github.com/1lck/Lithe-IDEA">View the repository</a>
  </p>
</div>

<table align="center">
  <tr>
    <td align="center">🧭<br><strong>Familiar IDE core</strong><br>Project · Editor · Search · Diff</td>
    <td align="center">⚡<br><strong>Native and on demand</strong><br>SwiftUI/AppKit with services that start when needed</td>
    <td align="center">🤖<br><strong>AI-ready review loop</strong><br>See, run, diff, undo, and commit external changes</td>
    <td align="center">🪶<br><strong>Lighter footprint</strong><br>Keep the resident app small and focused</td>
  </tr>
</table>

<p align="center">
  <img src="./docs/visual-qa/01-java-editor-project-tree.png" width="96%" alt="Lithe Java editor and project tree">
</p>

## About Lithe

Lithe is a native macOS IDE built for AI-assisted development. It preserves the project browsing, editing, search, code navigation, Git, run, and debug workflows familiar to IntelliJ IDEA users while starting Java language services, terminals, Maven, and debug processes only when needed.

When an external AI tool changes a project, Lithe helps you locate the affected code, run the project, review the diff, and decide which changes to stage, undo, or commit.

> **A familiar IDE core with a lighter resource footprint.**

## Core features

1. Built for Spring Boot projects and Java development.
2. Maven management, breakpoint debugging, and custom run configurations.
3. Git management and side-by-side diff review.
4. Double-Shift search and `Command + Shift + F` project-wide search.
5. Code navigation and reference lookup.
6. Local snapshot history.
7. Multiple projects open within the app.
8. Multiple files open independently in the same window.
9. AI-generated commit messages with customizable formats.
10. Rich Markdown rendering consistent with Yuque syntax.
11. Local application memory usage monitoring.
12. One-command installation and updates through Homebrew.
13. One-click in-app updates and installation.
14. Ongoing bug fixes and user experience improvements.

## Product tour

<p align="center">
  <img src="./docs/assets/screenshots/search-everywhere.png" width="49%" alt="Double-Shift Search Everywhere">
  <img src="./docs/assets/screenshots/global-search.png" width="49%" alt="Command Shift F project-wide search and replace">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/git-diff-review.png" width="96%" alt="Side-by-side Git diff review">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/ai-provider-import.png" width="49%" alt="Import AI provider settings from local tools">
  <img src="./docs/assets/screenshots/ai-commit-format.png" width="49%" alt="Customize AI commit message formats">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/ai-commit-message.png" width="96%" alt="Generate commit messages with AI">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/markdown-mermaid-preview.png" width="49%" alt="Markdown Mermaid rendering and live preview">
  <img src="./docs/assets/screenshots/markdown-rich-preview.png" width="49%" alt="Rich Markdown rendering and live preview">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/memory-monitor-annotated.png" width="49%" alt="Low memory footprint and in-app memory monitoring">
  <img src="./docs/assets/screenshots/memory-monitor.png" width="49%" alt="Application memory usage details">
</p>

## Use Lithe

### MacOS

Lithe requires macOS 14 or later. Java project features require a JDK; JDK 17 or JDK 21 is recommended. Semantic navigation requires Eclipse JDT LS. Maven projects need either a project `mvnw` or a system Maven installation.

Download the latest macOS `.dmg` from [GitHub Releases](https://github.com/1lck/Lithe-IDEA/releases/latest). If a release provides architecture-specific installers, choose `arm64` for Apple silicon or `x86_64` for an Intel Mac. Open the disk image, drag `Lithe.app` into `/Applications`, and launch it.

Install Lithe with the project Homebrew tap. The tap verifies the release checksum and clears the macOS quarantine attribute after installation:

```bash
brew tap 1lck/lithe https://github.com/1lck/Lithe-IDEA.git
brew install --cask 1lck/lithe/lithe
```

Update it with:

```bash
brew update
brew upgrade --cask lithe
```

If macOS blocks an app from an unidentified developer, right-click the app and select **Open**, or go to **System Settings → Privacy & Security → Open Anyway**. Only after confirming that the app came from an official Lithe GitHub Release, you can also run:

```bash
xattr -dr com.apple.quarantine "/Applications/Lithe.app"
open "/Applications/Lithe.app"
```

Install JDT LS with Homebrew:

```bash
brew install jdtls
```

After opening a project, use **Settings → Project** to configure the project JDK, Maven, and the JDK used by Maven. Lithe also detects Java and Maven from common system locations.

### Windows

The Windows version is still in development. Building the Qt workbench requires
Windows 10/11, Visual Studio 2022/MSVC, CMake, stable Rust, and Qt 6 for MSVC
2022 64-bit. Java features and installer packaging require the corresponding
JDK, Maven, or NSIS tools.

From a **PowerShell**, run these commands from the
repository root:

```powershell
.\scripts\build-windows.ps1 -Configuration Release -BuildQt
.\windows\build-windows\Release\lithe_windows_qt.exe
```

For toolchain ranges and Windows-specific validation, see the
[Windows README](./windows/README.md).

## Architecture

```mermaid
flowchart TB
    CORE["Shared Rust Core<br/>JSON C ABI and shared contracts"]

    subgraph MACOS["macOS · Available"]
        MUI["SwiftUI / AppKit Views"] --> MAPP["AppModel · Feature models · AppServices"]
        MAPP --> MADAPTERS["Native macOS adapters"]
        MADAPTERS --> MNATIVE["FSEvents · Process · PTY · Native UI"]
    end

    MAPP --> CORE

    subgraph WINDOWS["Windows · In development"]
        WUI["Qt Widgets Workbench<br/>Foundation available"] --> WAPP["C++ application workflows<br/>To be completed"]
        WAPP --> WCLIENT["C++ CoreClient<br/>Foundation available"]
        WAPP --> WADAPTERS["Win32 adapters<br/>Foundation available"]
        WADAPTERS --> WNATIVE["Win32 · ConPTY · File watching"]
        WAPP -.-> WPARITY["Full feature parity<br/>Planned"]
        WCLIENT -.-> WPACKAGE["Rust library integration and packaging<br/>Planned"]
        WNATIVE -.-> WBUILD["Native Windows build and validation<br/>To be completed"]
        WUI -.-> WSHIP["Installer · Updates<br/>Planned"]
    end

    WCLIENT --> CORE

    classDef planned fill:#fff3cd,stroke:#d97706,stroke-width:2px,stroke-dasharray:6 4,color:#111827
    class WAPP,WPARITY,WPACKAGE,WBUILD,WSHIP planned
```

## Develop Lithe

Development requires Swift 6.2 or later. Running the complete test suite requires Xcode; basic SwiftPM builds only need Command Line Tools.

Run the development build from the repository root:

```bash
./scripts/preview.sh
```

The script builds and links Rust Core before launching the macOS app. To validate only the Swift source, run:

```bash
swift run --disable-sandbox Lithe
```

Build an app bundle:

```bash
./scripts/package-app.sh
open dist/Lithe.app
```

Before submitting a change, run:

```bash
swift test --disable-sandbox
./scripts/verify-core.sh
./scripts/verify-git-graph.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-windows-boundaries.sh
./scripts/verify-rust-core.sh
```

See [Repository layout and shared boundaries](./docs/architecture/repository-layout.md) for directory ownership, cross-platform boundaries, and sharing rules. Include your verification steps and known limitations when submitting a change.

## Project support

### ❤️ Sponsors

<table>
  <tr>
    <td width="112" align="center">
      <a href="https://shu26.cfd/">
        <img src="./docs/assets/sponsors/code-go.png" width="64" alt="Code GO">
      </a>
    </td>
    <td>
      <a href="https://shu26.cfd/"><strong>Code GO</strong></a> provides relay access to Claude models and supports the development of Lithe. Thank you to Code GO for supporting this project!
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://codezsy.com">
        <img src="./docs/assets/sponsors/codez.png" width="64" alt="CodeZ relay service">
      </a>
    </td>
    <td>
      <a href="https://codezsy.com"><strong>CodeZ</strong></a> provides relay access to GPT-family models and supports the development of Lithe. Thank you to CodeZ for supporting this project!
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://www.fastaitoken.com/">
        <img src="./docs/assets/sponsors/fastai.png" width="64" alt="FastAI">
      </a>
    </td>
    <td>
      <a href="https://www.fastaitoken.com/"><strong>FastAI</strong></a> provides access to large language models and supports the development of Lithe. Thank you to FastAI for supporting this project!
    </td>
  </tr>
</table>

### ⭐ Special thanks

<p align="center">
  <a href="https://linux.do/">
    <img src="./docs/assets/special-thanks/linux-do.png" width="78%" alt="LINUX DO">
  </a>
</p>

<p align="center">
  <strong>For all things AI, head to LINUX DO. Wishing the community ever greater success.</strong>
</p>

### Contributors

Thank you to everyone who contributes to and improves Lithe.

<a href="https://github.com/1lck/Lithe-IDEA/graphs/contributors">
  <img src="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/contributors.svg" alt="Contributors">
</a>

### License

Lithe is licensed under the [Apache License 2.0](./LICENSE).

## Star History

Each point shows the repository's cumulative Star count at `00:00` Beijing time on that date. The chart starts at zero on August 2, 2026.

<a href="https://www.star-history.com/#1lck/Lithe-IDEA&Date">
  <img alt="Star History Chart" src="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/star-history-light.svg" />
</a>

## Contact us

Join the Lithe-IDEA community group to discuss the project and share feedback, or contact the author directly.

<table align="center">
  <tr>
    <td align="center"><strong>Join the community group</strong></td>
    <td align="center"><strong>Contact the author</strong></td>
  </tr>
  <tr>
    <td align="center"><img src="./docs/assets/contact/lithe-group.png" width="320" alt="Lithe-IDEA community group QR code"></td>
    <td align="center"><img src="./docs/assets/contact/wechat.png" width="320" alt="Author WeChat QR code"></td>
  </tr>
</table>
2266