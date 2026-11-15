# Agent 笔记：插件的测试、功能矩阵和翻译只在插件仓库

状态：已实现

## 先说结论

一个具体插件的全部内容，都只放在这个插件自己的仓库里维护。这里的“全部内容”包括源码、测试（含端到端测试，即启动真实工具走完整流程的测试）、测试夹具、功能矩阵记录、界面文案翻译，以及构建时下载、生成或打包资源的说明。宿主仓库（本仓库）和 Core 仓库的代码、测试、CI、功能矩阵、i18n 词条和资源复用清单，对任何具体插件都是零依赖。

对日常开发的直接影响：

- 宿主测试要验证通用扩展点（宿主给所有插件提供的接口，例如语言服务器会话、构建 Provider、调试启动）时，只能用测试里内联的合成插件，插件 ID 写成 `dev.lithe.test.<名称>`。不读取真实插件包、插件仓库检出或构建产物，不用真实插件 ID，也不保留“没设环境变量就跳过”的插件测试。
- 宿主功能矩阵只记录宿主自己的能力，`plugin-provided` 状态已经删除。插件能力写在插件仓库自己的矩阵里。
- 插件文案用插件包里的 `l10n/<语言>.json` 和插件自己的翻译，`shared/i18n/` 不收插件词条。
- 规则正文在 `develop-lithe` Skill 第三节“插件归属与宿主零依赖”，提交前要运行其中的自查命令；代码审查按 `lithe-code-review` 的对应检查项执行。

## 问题

Java Support、Maven、Gradle、Cargo、LLDB 等插件拆到独立仓库后，宿主仓库仍然留着它们的内容。

1. **测试。** 宿主里有 13 个依赖具体插件的测试文件，共 20 个测试函数，主要是 `desktop/internal/workbench/` 下的 `java_*_e2e_test.go`、`official_cargo_test.go`、`official_plugins_e2e_test.go` 和 `debug_native_e2e_test.go`。它们通过 `LITHE_JAVA_PLUGIN_PACKAGE`、`LITHE_RAW_CARGO_PLUGIN_ARCHIVE` 这类环境变量读取插件包或插件仓库检出，没设置就跳过。CI 不设置这些变量，所以它们在 CI 里一次也不运行；本地运行时，结果又取决于开发者手里是哪个版本的插件。另外，有几个单元测试拿真实插件 ID（`io.github.lithe-idea.*`）当测试数据。
2. **功能矩阵。** `shared/platform-feature-matrix/features/` 里有 35 条只描述插件能力的条目，例如 Java 调试、Spring 索引、Gradle 导入、Cargo 构建。另有 51 条宿主条目，它们的证据或说明引用了插件测试、插件包或插件仓库。`metadata.json` 还定义了 `plugin-provided` 状态。插件发版或改能力时，宿主矩阵不会收到任何通知，这些记录必然越来越旧。
3. **资源说明。** `scripts/resources/worktree-resources.json`、`reuse-worktree-resources.mjs`、`verify-download-cache.mjs` 和 `docs/ci-builds.md` 仍然登记 JDT LS 与 JDK 下载、JFR 录制、JDT Maven settings 副本、Maven 迁移与报告等插件资源，还写着 Java 反编译补丁以及 Cargo、Go、PHP 插件的构建步骤。
4. **翻译。** 宿主词条里写进了插件专属的说法。例如构建配置权限的说明原文是“读取并修改项目的 Java、Maven 与构建选项”，但这个权限实际只控制通用的构建选项修改。

结果是：宿主的测试结果和文档跟着插件版本变化；插件想改自己的测试、矩阵或翻译时，还要回宿主仓库提 PR。这与插件独立开发、独立发布的目标相反。

## 决策

### 1. 插件专属内容只在插件仓库

只有某个具体插件存在时才有意义的内容，叫“插件专属内容”。它只放在该插件的仓库，宿主仓库和 Core 仓库都不保存副本、摘要或临时版本。“具体插件”指任何真实存在的插件，Lithe-IDEA 组织的插件和第三方插件都算。

### 2. 宿主测试只用合成插件

合成插件是测试代码内联的插件清单，只声明被测扩展点需要的字段，插件 ID 用明显虚构的 `dev.lithe.test.<名称>`。宿主测试的输入只有三种：合成插件、经 `LITHE_PLUGIN_CONTRACT_DIR` 读取的 Core 契约 fixture，以及 `desktop/internal/core/testdata/marketplace/` 里的插件市场索引快照。索引快照可以包含真实条目，但断言只能针对所有条目共同适用的规则。

正确做法（`desktop/internal/workbench/debug_tcp_test.go`）：

```go
// debugAttachManifest 内联在测试文件里，插件 ID 是 dev.lithe.test.debug-attach，
// 只声明被测的 debugAdapters 扩展点；适配器由测试二进制自己扮演。
h := debugPluginHarness(t, "dev.lithe.test.debug-attach", debugAttachManifest, true)
// 断言宿主的通用行为：经回环 TCP 附加、断点暂停、继续、停止和清理。
```

不要这样做：

```go
pkg := os.Getenv("LITHE_JAVA_PLUGIN_PACKAGE")
if pkg == "" { t.Skip("no Java plugin") }
// 安装真实 Java Support，断言 JDT LS 返回的诊断。
```

第二种写法即使被跳过，也把 Java 插件的知识留在了宿主里，而且 CI 永远不会运行它。

### 3. 真实插件的端到端验证在插件仓库

真实语言服务器、构建工具、调试器和插件界面的端到端测试，由插件仓库的测试和 CI 针对宿主或 Core 的固定版本运行。宿主修改通用扩展点、可能影响已发布的插件时，PR 作者到受影响插件的仓库运行它的测试，把结果写进宿主 PR 说明；不能把这些测试搬回宿主。

### 4. 宿主功能矩阵只记录宿主能力

宿主矩阵只记录通用扩展点、插件安装与管理、插件市场，以及宿主自带的工作台功能。`plugin-provided` 状态已从 `shared/platform-feature-matrix/metadata.json` 删除。宿主条目的证据路径和验证动作不能引用具体插件的测试、插件包或插件仓库。

### 5. 插件自己翻译，宿主资源清单只登记宿主资源

插件清单里的文案用插件包的 `l10n/<语言>.json` 翻译；插件界面和插件后端返回的文字，由插件按界面语言自己翻译。契约翻译不了某段插件文字时，在 Core 扩展插件翻译契约，不在宿主补词条。

插件构建时下载、生成、打包或打补丁的资源，在插件仓库说明来源、校验方式和复用规则。宿主的资源复用清单和 `docs/ci-builds.md` 只登记宿主自己构建产生的资源，以及宿主为所有插件统一管理的通用目录（插件安装目录、插件状态目录）。

### 6. 用自查命令和审查兜底

`develop-lithe` Skill 给出一条 `rg` 自查命令，能发现 Lithe-IDEA 组织插件的 ID 和仓库名、指向插件包的环境变量和 `plugin-provided` 状态，提交前结果必须为空。命令覆盖不了第三方插件 ID 和只在断言里描述插件行为的测试，这部分由代码审查逐项检查。`.github/pull_request_template.md` 增加了“插件归属”检查项。

## 考虑过的备选方案

- **宿主保留插件端到端测试，用环境变量开关。** 好处是改宿主扩展点时可以顺手跑真实插件。被否：CI 从不设置这些变量，测试实际不运行；本地结果取决于插件版本；插件改行为时，宿主测试也得跟着改。
- **用 Git 子模块，或在宿主 CI 下载固定版本的插件包跑端到端测试。** 能让测试在 CI 里真正运行。被否：宿主多出一组要和插件一起升级的固定版本，插件每次发版都要回宿主改版本；CI 还要多处理一类下载和缓存。
- **保留 `plugin-provided` 状态，在宿主矩阵记插件能力摘要。** 能让一张表看到所有能力。被否：插件能力变化不会通知宿主，摘要一定会过时；而且这项能力是否可用，取决于用户装没装插件、装的是哪个版本，宿主矩阵给不出可信的状态。
- **宿主 `shared/i18n/` 代插件维护词条。** 被否：插件文案的发布会和宿主发版绑在一起，第三方插件也没法走同一条路。

## 后果

收益：

- 宿主测试的结果只取决于宿主和固定的 Core 版本，不再随插件版本变化。
- 插件修改测试、功能矩阵或翻译时，不需要改宿主仓库。
- 宿主矩阵里每一条都是宿主自己能证明的状态。

代价与后续：

- 删掉的 13 个测试文件覆盖过真实插件的行为，例如 Java 运行与调试、无源码 JAR 的类导航、Cargo 构建、LLDB 调试。这些行为现在由对应插件仓库的测试负责，本次没有把测试搬过去；各插件仓库有没有覆盖，由插件维护者确认。
- 删掉的 35 条矩阵条目及其 `legacy` 基线，可以用 `git show <删除前的 commit>:shared/platform-feature-matrix/features/<id>.json` 从历史取回，供插件仓库建自己的矩阵时参考。
- 宿主改通用扩展点时，PR 作者要多做一步：到受影响的插件仓库跑测试。
- 历史 Note 里引用已删测试、矩阵条目和资源清单排除项的地方，加了删除线或注明已移出，原有上下文保留。
- 自查命令只覆盖常见写法，结果为空不代表完全合规。

## 验证

- `develop-lithe` Skill “插件归属与宿主零依赖”一节的自查命令在仓库根目录输出为空。
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`
- `node --test scripts/resources/test-reuse-worktree-resources.mjs`
- `node scripts/resources/test-verify-download-cache.mjs`
- `node scripts/i18n/generate-i18n.mjs --check`
- `node scripts/i18n/verify-app-language-localization.mjs`
- `./scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/plugininstall/... ./internal/pluginpkg/... ./internal/plugintrust/... ./internal/workbench/... ./internal/pluginservice/... ./internal/projectgen/...`
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `.agents/skills/develop-lithe/SKILL.md`
- `.agents/skills/create-lithe-plugin/SKILL.md`
- `.agents/skills/lithe-code-review/references/review-policy.md`
- `.agents/skills/write-stable-tests/SKILL.md`
- `.github/pull_request_template.md`
- `shared/platform-feature-matrix/metadata.json`
- `shared/i18n/`
- `scripts/resources/worktree-resources.json`
- `docs/ci-builds.md`
