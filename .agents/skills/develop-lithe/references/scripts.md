# 脚本放置与分类

新增、移动或审查脚本时遵守本页。通用规则见 [Lithe 开发规范](../SKILL.md)；本页路径都相对于仓库根目录。

## 放在哪里

- 仓库级脚本（构建、打包、准备、验证、测试入口、发布、CI 辅助、诊断探针等）必须放在 `scripts/` 下的某个分类子目录中。不得放在仓库根目录、`macos/`、`windows/`、`.github/` 或临时目录，也不得直接放在 `scripts/` 根目录。
- 以下两类不属于仓库级脚本，放在所属位置，不进 `scripts/`：
  - Skill 自带的脚本放在该 Skill 的 `scripts/` 目录，例如 `.agents/skills/write-stable-tests/scripts/`。
  - 单个包自己的构建脚本放在该包内，例如插件包内的 `scripts/`。
- 按脚本的作用分类，不按文件类型或创建者分类。按下表从上到下，取第一个匹配的目录：

| 目录 | 放什么 |
| --- | --- |
| `scripts/ci/common/` | 被两个及以上工作流共用的 CI 脚本，例如 Desktop Release 与 AutoBuild 共用的打包目标、格式和发布文件清单 |
| `scripts/ci/<工作流名>/` | 只为某一个工作流存在的脚本，目录名与工作流名对应（例如 `desktop-release`、`desktop-autobuild`、`cancel-closed-pr-runs`） |
| `scripts/release/notes/` | 发布说明的生成与校验 |
| `scripts/macos/<作用子目录>/` | 只服务 macOS 上的 Lithe 产品的脚本，子目录按作用命名（现有 `package/`） |
| `scripts/desktop/perf/` | Viva 桌面端的性能基线：编辑器基准的运行、记录、对比和报告 |
| `scripts/desktop/` | 只服务 Viva 桌面端（`desktop/`，Go）的构建、打包、验证和运行入口：构建它链接的 Lithe-core-rust 静态库，以及带 cgo 参数运行 `desktop/` 里的 go 命令 |
| `scripts/install/` | 给用户运行的安装脚本，一行命令从更新源下载并安装发行版；只服务一个平台的脚本文件名带平台名（现有 `linux.sh`） |
| `scripts/agent-notes/`、`i18n/`、`platform-feature-matrix/` | 跨平台领域的脚本，目录名就是领域名 |

- 没有合适的目录时，新建一个以领域或作用命名的目录，并在同一次改动中更新上表。不得新建 `misc/`、`utils/`、`tools/` 这类不表达作用的目录。
- 例外：属于某个跨平台领域、但只在一个平台上运行的脚本，留在领域目录，文件名中带平台名，不放进 `scripts/macos/`。这类脚本必须在 `.github/workflows/` 的路径过滤器中按完整路径登记，不得依靠文件名中的平台子串匹配。
- 测试脚本与被测脚本放在同一目录，命名沿用 `test-*` 或 `*.test.*`。验收对象不是某个脚本的手动验收脚本，放在对应领域的 `test/` 目录或被测脚本旁。

## 路径引用

- 脚本引用同目录文件时，使用相对于脚本自身的位置（`$SCRIPT_DIR`、`import.meta.url`、`__dir__`、`$PSScriptRoot`），不得依赖当前工作目录。
- 跨目录引用必须写完整的 `scripts/<分类>/<名字>`。Ruby 的 `require_relative` 和 Shell 的 `source` 也要带上相对目录；只按文件名搜索会漏掉它们。

## 移动或新增后的同步清单

用 `git mv` 移动脚本以保留历史。移动或新增脚本后，必须同步以下位置：

1. `.github/workflows/` 中的 `run:` 路径、`paths` 过滤器和循环。GitHub 的 `*` 不跨 `/`，需要递归时用 `**`。
2. 会把脚本复制到临时目录的测试夹具：保持相同的目录深度，被复制脚本通过相对路径依赖的文件也要一起复制。
3. 非脚本文件中写死的脚本路径，例如 `desktop/Makefile`、各工作流文件和 `package.json`。没有任何检查会发现这里的遗漏，必须逐个搜索确认。
4. 文档、Skill、Agent Note 和 `shared/platform-feature-matrix/` 中写明的路径。
