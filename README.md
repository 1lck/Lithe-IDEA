<div align="center">
  <img src="./Resources/AppIcon.png" width="112" alt="Lithe app icon">

  <h1>Lithe</h1>

  <p><strong>A lightweight IDE for the AI era</strong></p>
  <p>Start tools on demand · keep the workspace responsive · stay focused on the code</p>
  <p><em>AI writes the code. Lithe helps you understand it, run it, and review it.</em></p>

  <p>
    <a href="./README.zh-CN.md"><strong>简体中文</strong></a> ·
    <a href="#core-features">Core features</a> ·
    <a href="#product-tour">Product tour</a> ·
    <a href="#use-lithe">Use Lithe</a> ·
    <a href="#architecture-overview">Architecture</a> ·
    <a href="#develop-lithe">Develop Lithe</a> ·
    <a href="#contact-us">Contact us</a>
  </p>

  <p>
    <a href="https://github.com/1lck/Lithe-IDEA/releases/latest"><img src="https://img.shields.io/github/v/release/1lck/Lithe-IDEA?style=for-the-badge&label=latest%20release&logo=github&logoColor=white" alt="Latest release"></a>
    <img src="https://img.shields.io/badge/platform-macOS%2013%2B-111827?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 13+">
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
    <td align="center">🧭<br><strong>General-purpose IDE</strong><br>Project · Editor · Search · Diff</td>
    <td align="center">⚡<br><strong>Performance focused</strong><br>Services start on demand to keep workflows responsive</td>
    <td align="center">🤖<br><strong>AI-ready review loop</strong><br>See, run, diff, undo, and commit external changes</td>
    <td align="center">🪶<br><strong>Lighter footprint</strong><br>Keep the resident app small and focused</td>
  </tr>
</table>

## About Lithe

Lithe is a lightweight, general-purpose IDE built for the AI era. It brings project browsing, editing, search, code navigation, Git, run, and debug workflows together for multi-language and multi-type projects, while starting language servers, terminals, build tools, and debug processes only when needed.

When an external AI tool changes a project, Lithe helps you locate the affected code, run the project, review the diff, and decide which changes to stage, undo, or commit.

> **A lightweight IDE that starts what you need, when you need it.**

## Core features

1. Built for Spring Boot projects and Java development.
2. Maven management, breakpoint debugging, and custom run configurations.
3. Git management and side-by-side diff review.
4. Double-Shift search and `Command + Shift + F` project-wide search.
5. Process-free lightweight completion and current-file navigation, with on-demand language servers for richer completion, hover, and semantic navigation.
6. Local snapshot history.
7. Multiple projects open within the app.
8. Multiple files open independently in the same window.
9. AI-generated commit messages with customizable formats.
10. Rich Markdown rendering consistent with Yuque syntax.
11. Local application memory usage monitoring.
12. One-command installation and updates through Homebrew.
13. One-click in-app updates and installation.
14. Automatic project entry-point detection with one-click run support for Spring Boot, Java, Maven, Gradle, npm, Cargo, Go, Python, Make, Docker Compose, Procfile, and shell projects.
15. Per-language service switches so language servers can be enabled or disabled independently to match the machine's resources.
16. Multi-line editor tabs for keeping more files visible in the same workspace.
17. Database connection workspace with multiple database types, connection management, SQL history, table browsing, and database operations.
18. Ongoing bug fixes and user experience improvements.

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

<p align="center">
  <img src="./docs/assets/screenshots/project-auto-detection-run.png" width="96%" alt="Automatic project detection and one-click run configuration">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/language-services-settings.png" width="49%" alt="Per-language service settings">
  <img src="./docs/assets/screenshots/multi-line-editor-tabs.png" width="49%" alt="Multi-line editor tabs">
</p>

<p align="center">
  <img src="./docs/assets/screenshots/database-workspace-overview.png" width="49%" alt="Database connection workspace">
  <img src="./docs/assets/screenshots/database-sql-operation.png" width="49%" alt="Database SQL operation and table structure">
</p>

## Use Lithe

Lithe requires macOS 13 or later. Java project features require a JDK; JDK 17 or JDK 21 is recommended. Maven projects need either a project `mvnw` or a system Maven installation. Lightweight completion does not start an external process; when a matching language server is installed, Lithe routes the capabilities it actually advertises through the shared Rust LSP Core. See the [language tooling and LSP architecture](./docs/architecture/language-tooling.md) for provider configuration and compatibility details.

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

After opening a project, use **Settings → Project** to configure the project JDK, Maven, and the JDK used by Maven. Lithe also detects Java and Maven from common system locations.

### Database workspace and external MCP

The optional Database workspace supports MySQL, MariaDB, PostgreSQL, SQLite,
Microsoft SQL Server, MongoDB, Redis, and Nacos through an on-demand Rust helper.
The helper is not started while the database workspace is unused. SQL connections provide table CRUD, TSV batch paste,
find/replace within the current page, plus CSV, JSON, and SQL import and export.
MariaDB reuses the MySQL-compatible engine; SQL Server has a native TDS data-grid
adapter. MongoDB collections use the document grid with paging, filters, indexes,
and protected insert/update/delete operations.
Redis uses incremental `SCAN` pages instead of loading an entire keyspace, and its
first workspace supports String and Hash editing, TTL changes, key renaming, and
deletion. Nacos provides configuration search and publishing, plus service and
instance health views. Redis and Nacos writes follow the same read-only and
production-protection rules as SQL writes. SQL backups are complete by default,
without a per-table row limit. Restoring a SQL backup always requires confirmation,
verifies the backup before changing the target, and then replaces the current
database objects and data. Release bundles also include
`Contents/Helpers/lithe-db-mcp`, an independent MCP stdio adapter for external
automation. It provides database tools only; Lithe does not include an in-app
natural-language Agent conversation.

For upstream audit, `third_party/dbx` contains a source-only snapshot of
[t8y2/dbx](https://github.com/t8y2/dbx) at commit
[`996ce42e80387bba4b33a2bf1713f590ef79d476`](https://github.com/t8y2/dbx/commit/996ce42e80387bba4b33a2bf1713f590ef79d476).
It is not a Git submodule or runtime dependency and is excluded from Lithe's
release bundle; the database helper is implemented and built independently.
The eight database brand marks used by the current workspace are copied into
`Resources/DatabaseIcons` as independent application resources. Their DBX
source, Apache-2.0 license, and trademark-use notice are recorded alongside
the files, so the packaged application never resolves assets from `third_party`.

## Architecture Overview

The macOS and Windows implementations are feature-complete. The Windows build is currently in pre-release validation and has not been published yet.

<p align="center">
  <img src="./docs/assets/architecture-diagram.png" width="100%" alt="Lithe cross-platform architecture">
</p>

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
./scripts/test-macos.sh
./scripts/verify-core.sh
./scripts/verify-git-graph.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-windows-boundaries.sh
./scripts/verify-rust-core.sh
```

See [Repository layout and shared boundaries](./docs/architecture/repository-layout.md) for directory ownership, cross-platform boundaries, sharing rules, and the required Rust Core comment standard. Include your verification steps and known limitations when submitting a change.

## Project support

### ❤️ Sponsors

<table>
  <tr>
    <td width="112" align="center">
      <a href="https://www.fastaitoken.com/">
        <img src="./docs/assets/sponsors/fastai.png" width="64" alt="FastAI">
      </a>
    </td>
    <td>
      <a href="https://www.fastaitoken.com/"><strong>FastAI</strong></a> provides convenient relay access to a range of leading large language models, making it easier to connect AI capabilities to everyday development workflows. Its support helps Lithe continue improving its AI-assisted experience. Thank you to FastAI for supporting this project!
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://codezsy.com">
        <img src="./docs/assets/sponsors/codez.png" width="64" alt="CodeZ relay service">
      </a>
    </td>
    <td>
      <a href="https://codezsy.com"><strong>CodeZ</strong></a> focuses on stable relay access to GPT-family models, offering developers a straightforward way to integrate model APIs into their tools and projects. Its sponsorship contributes to the ongoing development and maintenance of Lithe. Thank you to CodeZ for supporting this project!
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://api.axis.fan/register?aff=4EZFN7322WTH">
        <img src="./docs/assets/sponsors/yuanliu-token.png" width="64" alt="Yuanliu Token">
      </a>
    </td>
    <td>
      <a href="https://api.axis.fan/register?aff=4EZFN7322WTH"><strong>Yuanliu Token</strong></a> offers relay access to multiple large language model APIs, giving developers a flexible entry point for experimenting with different models and building AI applications. Its sponsorship supports Lithe as the project expands and polishes its AI features. Thank you to Yuanliu Token for supporting this project!
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://torchai.ai">
        <img src="./docs/assets/sponsors/torchai.jpg" width="64" alt="TorchAI">
      </a>
    </td>
    <td>
      <a href="https://torchai.ai"><strong>TorchAI</strong></a> provides large language model relay services for developers who need convenient API access across coding, content, and automation scenarios. Its support helps sustain Lithe's development and exploration of practical AI-powered tools. Thank you to TorchAI for supporting this project!
    </td>
  </tr>
  <tr>
    <td width="112" align="center">
      <a href="https://shu26.cfd/">
        <img src="./docs/assets/sponsors/code-go.png" width="64" alt="Code GO">
      </a>
    </td>
    <td>
      <a href="https://shu26.cfd/"><strong>Code GO</strong></a> specializes in relay services for Claude models, helping users access capable coding and reasoning models with less setup overhead. Its support gives Lithe more room to refine model integration and developer workflows. Thank you to Code GO for supporting this project!
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
  <strong>For all things AI, head to <a href="https://linux.do">LINUX DO</a>. Wishing the community ever greater success.</strong>
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
