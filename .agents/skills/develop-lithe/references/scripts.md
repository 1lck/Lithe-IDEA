# 脚本放置与分类

新增、移动或审查脚本时遵守本页。通用规则见 [Lithe 开发规范](../SKILL.md)；本页路径都相对于仓库根目录。

## 放在哪里

- 仓库级脚本（构建、打包、准备、验证、测试入口、发布、CI 辅助、诊断探针等）必须放在 `scripts/` 下的某个分类子目录中。不得放在仓库根目录、`macos/`、`windows/`、`.github/` 或临时目录，也不得直接放在 `scripts/` 根目录。
- 以下两类不属于仓库级脚本，放在所属位置，不进 `scripts/`：
  - Skill 自带的脚本放在该 Skill 的 `scripts/` 目录，例如 `.agents/skills/write-stable-tests/scripts/`。
  - 单个包自己的构建脚本放在该包内，例如 `windows/tauri/scripts/`、插件包内的 `scripts/`。
- 按脚本的作用分类，不按文件类型或创建者分类。按下表从上到下，取第一个匹配的目录：

| 目录 | 放什么 |
| --- | --- |
| `scripts/ci/common/` | 多个工作流共用的 CI 编排：变更分类、车道复用、复用校验、工作流门禁测试 |
| `scripts/ci/<工作流名>/` | 只为某一个工作流存在的脚本，目录名与工作流名对应（例如 `cancel-closed-pr-runs`、`update-repo-charts`） |
| `scripts/release/{sparkle,macos,windows,autobuild,notes}/` | 发布流水线：Sparkle 更新与验签、更新清单、AutoBuild 发布、发布说明校验 |
| `scripts/macos/{build,package,prepare,test,verify,perf,probe}/` | 只服务 macOS 产品的脚本：构建、打包、依赖与资源准备、测试入口、门禁校验、性能基线、手动探针 |
| `scripts/windows/{build,package,prepare,test,verify,perf}/` | 只服务 Windows 产品的脚本，子目录含义同上 |
| `scripts/desktop/` | 只服务 Viva 桌面端（`desktop/`，Go）的构建与运行入口：构建它链接的 Lithe-core-rust 静态库，以及带 cgo 参数运行 `desktop/` 里的 go 命令 |
| `scripts/rust-core/`、`architecture/`、`i18n/`、`logging/`、`agent-notes/`、`platform-feature-matrix/`、`plugins/`、`remote/`、`ide-mcp/`、`editor/`、`git-graph/`、`agent/`、`resources/` | 跨平台领域的脚本，目录名就是领域名 |

- 没有合适的目录时，新建一个以领域或作用命名的目录，并在同一次改动中更新上表。不得新建 `misc/`、`utils/`、`tools/` 这类不表达作用的目录。
- 例外：属于某个跨平台领域、但只在一个平台上运行的脚本，留在领域目录，文件名中带平台名，不放进 `scripts/macos/` 或 `scripts/windows/`。例如 `scripts/ide-mcp/build-windows-ide-mcp.mjs`、`scripts/ide-mcp/build-ide-mcp.sh`、`scripts/editor/package-macos-monaco.sh`。这类脚本必须在分类器和 `plan-ci-lane-reuse.mjs` 中按完整路径登记，不得依靠文件名中的平台子串匹配。
- 测试脚本与被测脚本放在同一目录，命名沿用 `test-*` 或 `*.test.*`。验收对象不是某个脚本的手动验收脚本，放在对应平台的 `test/` 目录；例如验收 Rust 代码的 `scripts/windows/test/test-windows-agent-recycle.ps1`。

## 路径引用

- 脚本引用同目录文件时，使用相对于脚本自身的位置（`$SCRIPT_DIR`、`import.meta.url`、`__dir__`、`$PSScriptRoot`），不得依赖当前工作目录。
- 跨目录引用必须写完整的 `scripts/<分类>/<名字>`。Ruby 的 `require_relative` 和 Shell 的 `source` 也要带上相对目录；只按文件名搜索会漏掉它们。

## 移动或新增后的同步清单

用 `git mv` 移动脚本以保留历史。移动或新增脚本后，必须同步以下位置：

1. `.github/workflows/` 中的 `run:` 路径、`paths` 过滤器和循环。GitHub 的 `*` 不跨 `/`，需要递归时用 `**`。
2. `scripts/ci/common/classify-ci-changes.sh` 和 `scripts/ci/common/plan-ci-lane-reuse.mjs` 的基础设施规则。分类器会先把路径转成小写，`case` 中的 `*` 可以跨 `/`。新路径必须被分类器识别；未知的 `scripts/` 路径按失败关闭处理，会触发全量 CI。改完运行：

   ```bash
   ./scripts/ci/common/test-classify-ci-changes.sh
   node --test scripts/ci/common/plan-ci-lane-reuse.test.mjs
   ```

3. 会把脚本复制到临时目录的测试夹具：保持相同的目录深度，被复制脚本通过相对路径依赖的文件也要一起复制。
4. 非脚本文件中写死的脚本路径。没有任何检查会发现这里的遗漏，必须逐个搜索确认：
   - `windows/tauri/src-tauri/tauri.conf.json` 的 `beforeDevCommand`、`beforeBuildCommand`；
   - `windows/tauri/package.json` 的 `scripts`；
   - `Plugins/marketplace/official-plugins.json` 的 `inputPaths`。`inputPaths` 中的脚本被移动后，已有发布标签的插件会被 `node scripts/plugins/official-plugin-releases.mjs check` 判定为发布输入变化，需要按发布流程决定是否升版本。
5. 工作树资源注册表 `scripts/resources/worktree-resources.json` 和 `scripts/resources/reuse-worktree-resources.mjs` 中的脚本路径。改完运行 `node --test scripts/resources/test-reuse-worktree-resources.mjs`。
6. 文档、Skill、Agent Note 和 `shared/platform-feature-matrix/` 中写明的路径。
