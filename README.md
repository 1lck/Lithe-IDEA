<div align="center">
  <img src="./Resources/AppIcon.png" width="112" alt="Lithe app icon">

  <h1>Lithe</h1>

  <p><strong>The IDEA-shaped core for AI-assisted development</strong></p>
  <p>Native macOS IDE · familiar workflows · a lighter memory footprint</p>
  <p><em>AI writes the code. Lithe helps you see it, run it, and review it.</em></p>

  <p>
    <a href="./README.zh-CN.md"><strong>简体中文</strong></a> ·
    <a href="#why-lithe">Why Lithe</a> ·
    <a href="#product-tour">Product Tour</a> ·
    <a href="#quick-start">Quick Start</a> ·
    <a href="#lithe-vs-intellij-idea">Lithe vs IDEA</a>
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

  <p>
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

## Why Lithe

Most developers do not need to learn another way to work. They need the familiar core of an IDE—project browsing, an editor, search, navigation, Git, Run, and Debug—without carrying the full resource footprint of a large IDE for every task.

Lithe is built around that idea: reproduce the core IDE workflow in a native macOS application, keep the interaction model familiar to IntelliJ IDEA users, and keep heavyweight services out of memory until they are needed.

The goal is not to build a smaller-looking editor. It is to provide a practical, lightweight alternative for the everyday IDE loop: open a project, read and edit code, search and navigate, run it, inspect the result, and review Git changes.

> **The familiar IDE core, with a lighter footprint.**

AI-assisted development is one of Lithe's most important use cases. When an external AI tool changes a project, Lithe is ready to observe the changes, navigate the affected Java code, run the project, inspect the Diff, and let people decide what to keep.

```text
Open a project
      ↓
Browse / Edit / Search / Navigate
      ↓
Run / Maven / Debug
      ↓
Review Git changes → Stage, undo, or commit
      ↓
Optional: inspect changes made by an external AI tool
```

You do not need to uninstall IntelliJ IDEA or learn a completely new interaction model. Lithe is designed to be a lighter alternative for the core daily workflow, while IDEA remains available for advanced coding and its broader ecosystem.

## Lithe vs IntelliJ IDEA

Lithe aims to replace the core everyday IDE loop with a lighter native application, not every advanced capability in IntelliJ IDEA.

| Area | IntelliJ IDEA | Lithe |
| --- | --- | --- |
| Primary role | Full Java and multi-language IDE | Lightweight IDEA-style IDE for core daily workflows |
| Deep coding | Complete completion, refactoring, plugins, and project tooling | Focused on reading and small manual corrections |
| External AI changes | Possible inside a full IDE workflow | External change detection, conflict prompts, Diff, and Local History are first-class |
| Git workflow | Broad version-control capabilities | Centered on Changes, side-by-side Diff, hunk actions, and accept/undo decisions |
| Java support | Full Java project experience | Eclipse JDT LS navigation, diagnostics, and basic Debug |
| Startup and resources | Broader IDE platform | Native SwiftUI/AppKit with Java services and processes started on demand |
| Familiarity | The established IDEA workflow | Keeps the Project, Changes, Search, Editor, and Diff habits IDEA users already know |

### Core workflows Lithe can replace

- Open a Java project, browse its files, edit a small piece of code, and save it.
- Search the project, navigate Java definitions and usages, and inspect diagnostics.
- Run Maven, Spring Boot, or a Java file and inspect the result.
- Review Git changes, then stage, undo, commit, or apply an individual hunk.
- Inspect and validate changes made by an external AI tool without changing your familiar IDE habits.

### Moments IDEA is still the better tool

Deep completion, complex refactoring, automatic imports, a broad plugin ecosystem, multi-language projects, test trees, and coverage remain IDEA strengths. Lithe is not asking you to give those up; it provides a lower-overhead alternative for the core IDE loop and makes AI-assisted changes easier to inspect.

## Performance and familiar workflow

### Native, lightweight, and on demand

Lithe is built with SwiftUI and AppKit. It does not embed Chromium or maintain a full IDE-scale resident project model:

- The Java language service starts when a Java project needs it.
- Terminal, Maven, Run, and Debug processes start when you use them.
- Search uses a lightweight disk index, while Local History stores snapshots on disk instead of keeping history text resident in memory.
- Closing a project stops file watchers, language services, terminal sessions, and Run/Debug processes.

The current physical-footprint baseline on the development machine is about **44 MB** for an idle Welcome window, **58 MB** for the Lithe process with a Java project open, and **282 MB** for the on-demand JDT LS process. That makes the observed idle Java-project total about **340 MB**; JDT LS is reported separately because it is stopped when the project closes, but it is still part of the user's real resource cost. These are development baselines, not a substitute for future stress testing across larger projects. The main Lithe process remains targeted below **150 MB**.

### No new IDE habits to learn

Lithe follows the IDEA-shaped workflow: Project, Changes, Search, Editor, Diff, Maven, Run, and Debug have corresponding entry points. Familiar actions such as `⌘F` file search, `⌘B` navigation to usages, and double-Shift Search Everywhere remain available.

The cost of switching to Lithe is not learning another IDE. It is simply opening a workbench with the same familiar concepts and a smaller memory footprint.

## Product Tour

<p align="center">
  <img src="./docs/visual-qa/00-welcome-projects.png" width="49%" alt="Welcome and recent projects">
  <img src="./docs/visual-qa/01-java-editor-project-tree.png" width="49%" alt="Java editor and project tree">
</p>

<p align="center">
  <img src="./docs/visual-qa/09-search-everywhere-results.png" width="49%" alt="Search Everywhere">
  <img src="./docs/visual-qa/13-spring-boot-usages.png" width="49%" alt="Java usages from JDT LS">
</p>

<p align="center">
  <img src="./docs/visual-qa/08-git-diff-green-state.png" width="49%" alt="Git diff review">
  <img src="./docs/visual-qa/14-spring-boot-run-configuration.png" width="49%" alt="Spring Boot run configuration">
</p>

## Features

| Workflow | What Lithe provides |
| --- | --- |
| Project browsing | Welcome Screen, recent projects, file tree, file icons, breadcrumbs, and workspace state restoration |
| Code reading | Multi-tab native editor, Java syntax highlighting, code folding, line numbers, saving, and dirty-file state |
| Java navigation | Eclipse JDT LS definitions, usages, implementations, workspace symbols, and live diagnostics |
| Search | File name, path, full-text, Search Everywhere, case/whole-word/regex matching, and project replacement |
| External changes | FSEvents monitoring, file refresh, and conflict prompts between disk and unsaved editor content |
| Git review | Changes, side-by-side Diff, Diff search, hunk staging/undo, Commit, Shelf, branches, and Git Graph |
| Build and Run | Maven roots, modules, Profiles, Lifecycle, Build Output, Current File, Spring Boot, and Maven Module configurations |
| Java Debug | Local JDWP, Maven/Spring Boot Debug, Remote JVM/Tomcat attach, breakpoints, stepping, threads, and variables |
| Productivity | Project Local History, integrated terminal, resizable tool windows, and restored split layouts |
| Updates | Checks the latest GitHub Release, verifies the matching package, and replaces the app after confirmation |
| Interface | English by default, with Simplified Chinese available from Settings |

## Quick Start

### Requirements

- macOS 14 or later
- Swift 6.2 or later
- A JDK for Java features; JDK 17 or JDK 21 is recommended
- Eclipse JDT LS for Java semantic navigation
- A project `mvnw` or a system Maven installation for Maven projects

Install JDT LS with Homebrew:

```bash
brew install jdtls
```

### Run the development build

From the project root:

```bash
./scripts/preview.sh
```

This builds and links the Rust Core before launching the macOS app. To validate
the Swift sources without linking Rust, you can also run:

```bash
swift run --disable-sandbox Lithe
```

### Build an App Bundle

```bash
./scripts/package-app.sh
open dist/Lithe.app
```

### Download a release

Download the latest macOS `.dmg` from [GitHub Releases](https://github.com/1lck/Lithe-IDEA/releases/latest). When a release provides separate installers, choose `arm64` for Apple Silicon Macs (M1 and later) or `x86_64` for Intel Macs. Open the disk image, drag `Lithe.app` to `/Applications`, and launch it. Lithe can also check for a newer release in the app, download the matching package, replace the current app, and restart automatically.

If macOS blocks an app from an unidentified developer, first try right-clicking the app and choosing **Open**. You can also use **System Settings → Privacy & Security → Open Anyway** after trying to launch it.

Only if the app came from the official Lithe GitHub Release, and macOS still blocks it, run:

```bash
xattr -dr com.apple.quarantine "/Applications/Lithe.app"
open "/Applications/Lithe.app"
```

This removes macOS's downloaded-file quarantine marker for that app. It does not install updates automatically or disable Gatekeeper system-wide.

### Check the core workflows

The repository includes UI-independent checks for the core logic:

```bash
./scripts/verify-core.sh
./scripts/verify-git-graph.sh
./scripts/verify-rust-core.sh
```

These cover Diff, file visibility, search matching, Git Graph, whitespace filtering, stash, clone, real Merge/Tag/Remote reference layouts, and the Rust Core ABI.

## Configure Java and Maven

After opening a project, use **Settings → Project** to configure:

- Project JDK
- Maven Wrapper, system Maven, or a custom Maven Home
- The JDK used by Maven

Lithe discovers installed JDKs by probing `JAVA_HOME`, macOS `java_home`, standard JDK locations, and Homebrew JDKs; Maven is discovered from a project `mvnw`, `MAVEN_HOME`, `PATH`, and standard Homebrew/system locations. The selected runtime is stored per project in local application settings, so machine-specific paths do not enter the repository. These settings are shared by Current File, Maven, Spring Boot, Maven Module, Debug, and JDT LS. A run configuration can still override the project JDK with **JDK Home**.

## Design boundaries

Lithe currently focuses on reading, running, and reviewing Java projects on macOS. It does not include:

- AI model calls, Agent sessions, or chat UI
- LSP and code intelligence for languages other than Java
- Traditional completion, automatic imports, quick fixes, or safe rename
- Test discovery, test trees, coverage, or a full test runner
- Three-way merge conflict resolution, multi-root workspaces, or a plugin marketplace

Current File uses Java source-file mode and is intended for quick single-file examples. For code that depends on other project sources, use a Maven Module or Spring Boot run configuration.

## Technical architecture

```text
SwiftUI Workbench
├── Welcome / Recent Projects
├── Project / Changes / Search
├── Editor Tabs / Diff Review
└── Run / Debug / Maven / Terminal
          ↓
AppKit NSTextView     FSEvents       System Git       JDT LS
Native text editing   File changes   Git review       Java semantics
```

Lithe uses Swift Package Manager and has no third-party Swift Package dependencies:

```text
Sources/Lithe/
├── Models/       Workspace, editor, Git, Java, and run configuration models
├── Services/     Scanning, search, Git, Maven, Java, and Local History
├── Theme/        Lithe visual tokens and icons
└── Views/        Welcome, Workbench, Editor, Diff, and tool windows
```

## Current status

Lithe is in active development. The core loop from opening a project to reading changes, running Java/Maven, reviewing a Diff, and making a Git decision is in place.

| Status | Scope |
| --- | --- |
| Available now | Welcome, project tree, editor, search, external changes, Git/Diff, Local History, terminal, Maven, and basic Run/Debug |
| Being refined | Java navigation edges, cross-file Current File execution, and large-project performance |
| Planned | Automated tests, more Java workflows, and further interaction polish |

## Project structure

```text
Lithe-IDEA/
├── Sources/Lithe/          # Current macOS SwiftUI / AppKit source
├── Sources/LitheRustCore/  # macOS C bridge for the Rust Core
├── Resources/              # macOS metadata, localization, and runtime assets
├── rust/                   # Shared Rust Core and C ABI
├── windows/                # Independent Windows implementation (planned)
├── shared/                 # Cross-platform contracts and acceptance material
├── Fixtures/               # Shared Maven / Spring Boot and Git fixtures
├── scripts/                # Build, packaging, and core check scripts
├── docs/                   # Product, architecture, release, and QA documentation
├── Package.swift           # Current macOS package
├── README.md               # English README
└── README.zh-CN.md         # Simplified Chinese README
```

The macOS and Windows applications use independent runtime implementations. See the [repository layout and sharing rules](./docs/architecture/repository-layout.md).

## Contributing

If you want to contribute:

1. Start with the feature scope and design boundaries above.
2. Run `./scripts/verify-core.sh` and `./scripts/verify-git-graph.sh`.
3. Test UI and runtime behavior in a real Java/Maven project.
4. Include the verification steps and known limitations with your change.

## License

Lithe is licensed under the [Apache License 2.0](./LICENSE).

## Contributors

Thanks to everyone who contributes to Lithe.

<a href="https://github.com/1lck/Lithe-IDEA/graphs/contributors">
  <img src="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/contributors.svg" alt="Contributors" />
</a>

## Star History

<a href="https://www.star-history.com/#1lck/Lithe-IDEA&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/star-history-dark.svg" />
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/star-history-light.svg" />
    <img alt="Star History Chart" src="https://raw.githubusercontent.com/1lck/Lithe-IDEA/chart-assets/star-history-light.svg" />
  </picture>
</a>

## Friendly Links

- [LINUX DO](https://linux.do/) — A new ideal community
