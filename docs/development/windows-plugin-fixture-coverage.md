# Windows 插件 fixture 覆盖审计（M0）

状态：M0 交付。证据在基线 commit `1e78b59b6385fca6a881639b42048bf3bc587f4a`（#1424 合入后的 preview 起点）上逐一核对，并已同步 preview `83017afa`（插件后端能力 `8471b998`/#1470 合入后的契约状态，新增 `backend.plugin.json`）；行号为对应时点。

本文回答路线图
[Windows 插件功能对齐计划](windows-plugin-parity-plan.md) M0 的要求：`shared/contracts/plugins/v1/fixtures` 的每个文件，是否有 Core 契约验证、是否有 Windows 产品宿主的**真实接线**测试，缺什么、归哪个阶段。机器可读清单是
`scripts/plugins/plugin-fixture-coverage.json`，由
`scripts/plugins/check-plugin-fixture-coverage.mjs` 持续校验；本文是人类可读的审计快照，两者由检测器的强制单测绑定。

本文表格保留上述基线时点的审计快照；当前文件数量和接线状态以机器清单与检测器输出为准。后续新增的 Provider 执行、运行/调试/测试准备、模型消费和打包发布者信任 fixture 同样需要逐项登记；只有 Core 或 macOS 证据时，Windows 缺口仍保留。

**总原则：Core schema 校验通过不等于 Windows 产品完成。** `invalid-manifests.json` 的 154 个用例循环只证明"宿主校验路径对同一批非法输入报同一个稳定错误码"，不证明安装、启动、停用、卸载、会话回收等宿主行为已经接线。下文按此口径标注。

## 1. 基线结论（历史审计快照）

- fixtures 目录共 36 个文件（其中 signature-vectors.json 是本统一 PR 新登记的双端宿主签名向量，其余为原 35 项审计快照）：20 个合法清单（含原生 UI 3 个、项目生成 1 个、VCS 1 个，分类时单列；backend 为冻结路线图后新增）、1 个非法修改案例集、5 个金样/计划文件（command-plans、build-plans、runtime-versions、function-protocol、project-plans）、5 个市场用例、4 个项目生成模板。另有 `README.md` 与两个 schema 在契约根目录，不在 fixtures 内。
- Core 侧：35 个文件全部有至少一个 Core 测试引用（模板目录经 `plan.rs` 的 `collect_files` 生产代码递归读取，被 golden 测试间接触发）。
- Windows 侧：**3 个 wired**（有产品路径测试）、**11 个 validated-only**（仅清单验收/能力门控）、**10 个 indirect-core**（Windows 经 Core 命令消费、无直接读取）、**12 个 unwired**（Windows 零引用）。
- 最严重的真实缺口：`build-tool-path`、`build-provider-language-server`、`native-panel`、`native-form`、`native-controls`、`project-generator`、`vcs-provider`、`backend` 在 Windows 侧零引用；全部 5 个市场用例和 5 个跨平台金样在 Windows 没有直接消费测试。
- 顺带发现（只记录，不修改，归属见 §5）：`tests.rs:149` 的门控注释已过时；`lithe-plugin-docs` 的 `contract.lock.json` 落后于主仓库契约；macOS `BuildSystemToolWindowTests` 用本地 fixture 副本，共享 fixture 的改动不会反映到它。

## 2. 检测工具与运行方式

```bash
node scripts/plugins/check-plugin-fixture-coverage.mjs          # 清单 vs 目录真实枚举
node --test scripts/plugins/check-plugin-fixture-coverage.test.mjs
```

检测器只做本地只读比较，失败即退出码 1，并逐行打印问题。它强制：

| 失败类型 | 含义 |
| --- | --- |
| `unknown-fixture` | 目录里出现清单未分类的新文件（新增 fixture 忘了登记） |
| `missing-fixture` | 清单条目指向的文件已不存在（失效路径） |
| `duplicate-entry` | 同一文件被分类两次 |
| `unsorted-entry` | 清单未按路径排序（保持 diff 可审） |
| `invalid-entry` | 枚举值非法、wired 无 Windows 证据、known gap 缺阶段/说明、路径逃逸等 |
| `evidence-path` | 证据引用的仓库文件不存在（测试文件被移动/删除后证据过期） |
| `io` | 清单/目录不可读 |

单测覆盖正反例（临时目录构造，全部同步、有界、`t.after` 清理），最后一条强制真实仓库当前状态通过，并检查每个未接线条目都有合法的阶段和说明。全部 fixture 都有真实接线证据时，允许零缺口通过；**不能靠伪造 wired 状态绕过覆盖门禁**。关闭一个 gap 的唯一方式是给出真实的 Windows 测试引用。

清单里每个条目的证据字符串格式是 `<仓库相对路径>[:<行号>] <测试名>`。检测器只校验文件存在；行号是基线时点的文档，允许随后续重构漂移，但文件消失必须处理。

## 3. 覆盖状态语义

| 字段 | 值 | 含义 |
| --- | --- | --- |
| `outcome` | success / rejection / partial-support | 契约角色：成功路径 / 拒绝路径 / 合法但当前双端宿主均未完整开放的能力（build provider 两形态） |
| `windowsStatus` | wired | Windows 有产品路径测试直接使用该 fixture（扫描、安装、启动、catalog、Web 窗口、前端注册等，不止清单校验） |
| | validated-only | 仅进入 Windows 清单验收（带/不带能力门控），无产品路径测试 |
| | indirect-core | Windows 通过 Core 命令消费其内容，宿主测试不直接读取该文件 |
| | unwired | Windows 零直接引用（或仅作为 invalid-manifests 基底间接读取，单独说明） |

非 wired 的每条都带 `gapStage` 与 `gapDetail`。`gapStage` 表示**计划中该能力接入的阶段**，不是承诺日期；取值为路线图里程碑 M0–M10，或冻结路线图之后落地的新能力用的 `followup`（按计划 §6 单列后续阶段，暂无编号）。提前实现时以真实测试关闭并更新清单。

## 4. 分类明细

### 4.1 合法清单（15 个 valid-manifest；原生 UI、项目生成、VCS 三类单列见 §4.4）

| Fixture | 结果 | Core 入口（节选） | Windows 入口 | Windows 状态 / 缺口 |
| --- | --- | --- | --- | --- |
| backend.plugin.json | success | `declarative_plugins.rs:32/615` 后端计划与宿主服务（8471b998） | 无 | **unwired** → followup：冻结路线图（M0–M10）之后的新能力，macOS 宿主已声明 `backend:[1]`，Windows 接入按计划 §6 单列后续阶段 |

| Fixture | 结果 | Core 入口（节选） | Windows 入口 | Windows 状态 / 缺口 |
| --- | --- | --- | --- | --- |
| language-packaged-server | success | `declarative_plugins.rs:65` 全量验证；`:81` 归一化；`:251` API1 参数字面量；`marketplace_plugins.rs:219` 审查金样 | `tests.rs:112/162/196/258` 验收+扫描+存储+catalog；`install_tests.rs:43/118/185` 快照/staging/回滚；`launch.rs:933` 启动计划解析 | **wired** |
| hello-lithe | success | `declarative_plugins.rs:65/532/610` UI 贡献与图标归一化 | `tests.rs:112`；`web.rs:1657` 文本窗口注册；前端 `declarative-plugin-ui.test.ts:33` 三处命令位与撤销 | **wired** |
| language-system-command | success | `declarative_plugins.rs:65/106/330` 隐藏文件名、probe 不得用设置 | `tests.rs:112` 验收；`tests.rs:258` bundled catalog | validated-only → M10：systemCommand 启动（PATH 解析、`LITHE_*_PATH` 导出）无 fixture 级测试；macOS 侧也零引用 |
| language-host-integration | success | `declarative_plugins.rs:65/152/276` 集成能力归一化与审查 | `tests.rs:112` 仅验收 | validated-only → M10：jdt 集成启动计划与必需包资源无宿主测试（`launch.rs` 测试用 packaged-server），真实 JDT 包随 M10 |
| node-runtime | success | `declarative_plugins.rs:65/276/351` runtime 启动审查与设置归一化 | `tests.rs:112` 仅验收 | validated-only → M10：packagedRuntime/minimumVersion 与设置解析无 fixture 级测试（PHP 契约包端到端覆盖了 runtime node 计划展开，但不是本清单） |
| web-panel | success | `declarative_plugins.rs:65/563` 网页窗口许可与包页面 | `tests.rs:112` 仅验收（宿主已声明 `ui:[1,2]`） | validated-only → M6：本 fixture 声明的包页面没有被任何宿主测试打开；`build.*`/`functions.*` 桥按 v0 边界拒绝 |
| settings-v2 | success | `declarative_plugins.rs:901/911/958` 即时设置、分层解析、危险使用拒绝 | `tests.rs:112` 验收 + `tests.rs:128` 门控断言 | validated-only → M4：注册设置页、settingActions 与分层覆盖缺 fixture 级宿主行为测试（现有覆盖走设置编辑器与 `settings_tests`，不经本清单）。门控原因是该 fixture 同时 `requires buildSystems/buildProviders`；`tests.rs:149` 注释表述过时，见 §5 |
| build-static-file | success | `build_systems.rs:128/143/218/361/1236` 检测、golden、运行项、symlink 拒绝 | `tests.rs:112` + `:128` 门控 | validated-only → M4 |
| build-command-stdout | success | `build_systems.rs:128/143/1071` | `tests.rs:112` + `:128` | validated-only → M4 |
| build-command-output-file | success | `build_systems.rs:128/143` | `tests.rs:112` + `:128` | validated-only → M4 |
| build-host-integration | success | `build_systems.rs:128/143/482`；`build_runtime_versions.rs:15`；`project_generators.rs:92` | `tests.rs:112` + `:128` | validated-only → M4 |
| build-provider | partial-support | `declarative_plugins.rs:445`；`build_systems.rs:1115`；`marketplace_plugins.rs:219/332` | `tests.rs:112` + `:128` 门控 | validated-only → M5：自有进程 Provider 启动、litheBuild 协商、会话回收无宿主测试 |
| build-provider-language-server | partial-support | `declarative_plugins.rs:366/445`；`build_systems.rs:1460`；`marketplace_plugins.rs:219` | 仅经 `tests.rs:80` 作为 4 个非法用例基底间接读取 | **unwired** → M5：不在任何 Windows 显式清单，连"被门控拒绝"都无专属断言 |
| build-tool-path | success | `build_systems.rs:1599/1666/1719/1755` executableResolution 全部语义 | 无 | **unwired** → M4：Windows 零引用 |

### 4.2 非法修改案例、跨平台金样与函数协议（6 个）

| Fixture | 结果 | Core 入口 | Windows 入口 | Windows 状态 / 缺口 |
| --- | --- | --- | --- | --- |
| invalid-manifests.json（163 用例，13 个基底，含 backend） | rejection | `declarative_plugins.rs:133` | `tests.rs:80` 全量循环，宿主校验路径断言同码 | **wired**（校验路径一致性；宿主行为仍以各清单的 wired/validated-only 行为准） |
| command-plans.json | success | `declarative_plugins.rs:212` golden 展开 | 无；`tests.rs:433` 的 PHP 契约包端到端实测了 runPlan/testPlan 展开但不用本 golden | indirect-core → M5 |
| build-plans.json | success | `build_systems.rs:143` | 无 | indirect-core → M4 |
| runtime-versions.json | success | `declarative_plugins.rs:312` | 无（`launch.rs` 用 node/java/go 真实输出自测解析，不读本 golden） | indirect-core → M10：建议接入宿主探测路径时用本 fixture 对齐 |
| function-protocol.json | success | `plugin_function.rs:558` 起 8 组协议测试（v2 新增 hostRequests） | 无；网页桥 v0 对 `functions.*` 返回 `plugin.web.unknownMethod` | indirect-core → M6 |
| project-plans.json | success | `project_generators.rs:65` | 无 | indirect-core → M8 |

### 4.3 市场用例（5 个 marketplace/）

全部仅 Core：`marketplace_plugins.rs:100`（索引可用性）、`:131`（归一化排序）、`:147`（非法条目拒绝）、`:203`（来源 URL 解析）、`:219`（安装审查金样）、`:272`（ui 可用性需平台宿主）、`:332`（Provider 版本需宿主支持）。Windows 全部 indirect-core → M2：声明式市场宿主未接，索引消费、下载校验与来源记录均无 Windows 测试。其中 `install-reviews.json` 补充：Windows 磁盘安装链已调用 `installReview` 命令，但测试用 `language-packaged-server` 清单而非本审查金样矩阵。

### 4.4 原生 UI、项目生成与 VCS（9 个）

| Fixture | Core 入口 | Windows 入口 | Windows 状态 / 缺口 |
| --- | --- | --- | --- |
| native-panel.plugin.json | `declarative_plugins.rs:666/785` 版本归属、动作与预算 | 无 | **unwired** → M7 |
| native-form.plugin.json | `declarative_plugins.rs:721/785` 表单值/动作/网格 | 无 | **unwired** → M7 |
| native-controls.plugin.json | `declarative_plugins.rs:827` 公共控件类型/范围/按钮 | 无 | **unwired** → M7 |
| project-generator.plugin.json | `project_generators.rs:65/92/259/327/339` 表单/计划/归档/审查 | 无 | **unwired** → M8 |
| project-generator-templates/.gitattributes | 经 `plan.rs collect_files` 递归读取（字节稳定标记） | 无 | indirect-core → M8 |
| project-generator-templates/app/README.md | 同上（files 步骤模板） | 无 | indirect-core → M8 |
| project-generator-templates/app/dot-gitignore | 同上（dot 命名规避 git 忽略） | 无 | indirect-core → M8 |
| project-generator-templates/main/Main.java | 同上（条件占位符模板） | 无 | indirect-core → M8 |
| vcs-provider.plugin.json | `vcs.rs:65/94/147/196` 审查、权限、启动计划、根识别 | 无 | **unwired** → M9 |

### 4.5 冻结路线图后的独立编辑器扩展

preview 新增的编辑器动作和静态语法资源按 `followup` 登记，不纳入历史快照计数。
`grammar-assets` 分类用于插件包中的只读语法数据；它仍须提供 Core 证据，不能绕过 Windows 接线状态校验。

| Fixture | Core 入口 | Windows 状态 / 缺口 |
| --- | --- | --- |
| editor-actions.plugin.json | `declarative_plugins.rs contract_fixtures_and_official_plugins_validate` | **unwired** → followup：Windows 未声明 backend，缺权限审查、动作注册/调用与会话回收的 fixture 级产品测试 |
| language-grammar.plugin.json | `declarative_plugins.rs contract_fixtures_and_official_plugins_validate`；`plugin_editor_resources.rs` 的纯语法清单验证和语言解码 | **unwired** → followup：Windows 仅声明 `languages:[1]`；非法修改用例的间接读取不证明 `languages:2` 已接线 |
| grammars/http.monarch.json | `plugin_editor_resources.rs a_grammar_file_decodes_to_the_language_the_editor_registers` | **unwired** → followup：缺 Windows 插件资源加载、worker 注册/停用及资源只读的产品路径测试 |

## 5. 横切发现（记录，不在本 PR 修改）

1. **过时门控注释**：`windows/tauri/src-tauri/src/plugin_host/tests.rs:149` 注释称 settings-v2 被门控是因为"settings 2 与 languageServers 2 未声明"；实际 `mod.rs::host_capabilities` 已声明 `settings:[1,2]`、`languageServers:[1,2]`，真正的门控原因是该 fixture 同时 `requires buildSystems:1, buildProviders:1`。断言本身仍通过且有效，注释需在下次触碰该测试的 PR 中修正。
2. **契约同步缺口**：`Lithe-IDEA/lithe-plugin-docs` 的 `contract.lock.json`（gh 核实于 2026-10-24）固定在旧修订 `18345cc9…`，文件清单缺少后加入的 `native-panel/native-form/native-controls`、`project-generator`、`project-generator-templates/` 全目录与 `project-plans.json`。契约 README 规定契约改动必须同步该仓库；这属于 [插件契约发布](../../.agents/notes/implemented/architecture/2026-10-23-plugin-contract-publishing.md) 所有者的待办。
3. **macOS 本地副本**：`macos/Tests/LitheTests/Fixtures/BuildSystems/` 下的 `build-command-output-file`、`build-host-integration` 等是共享 fixture 的本地副本，`BuildSystemToolWindowTests` 经 `Bundle.module` 加载副本。共享 fixture 语义变更不会自动反映到这批测试，属已知重复面，不在本轮收敛。
4. **非法清单循环的边界**：Windows `invalid-manifests` 循环（154 用例）与 macOS 同名测试是契约一致性回归；它们不能替代宿主行为测试，也不能作为"Windows 已支持某能力"的证据——被门控清单（如 build 组）的全量拒绝恰恰说明能力未开放。
5. **fixtur 目录枚举现状**：Core 测试全部用 `include_str!`/显式 const 清单，Windows 测试用 `read_fixture(name)` 显式点名；唯一对 fixtures 树的运行时递归读取是 `plan.rs` 的模板收集。这就是"新增 fixture 会静默漏掉"的结构性原因，也是本检测器存在的理由。`scripts/architecture/verify-shared-contracts.sh` 的语义校验（schemaVersion、ID 前缀、拒绝码文档化等）与本检测器互补，不互相替代。
6. **过时的宿主能力描述**：`shared/contracts/plugins/v1/README.md` 能力一节（preview 上仍在 §456 附近）称 macOS 不声明 buildProviders/vcsProviders；基线与 preview 的 `PluginTypes.swift` `PluginManifest.hostCapabilities`（preview 为 `:492-504`）实际声明 `buildProviders:[1]、buildSystems:[1,2]、executableResolution:[1]、executionProviders:[1]、projectGenerators:[1]、ui:[1,2,3]、vcsProviders:[1]`（preview 另加 `backend:[1]`），Core `capabilities.rs` 的 `SUPPORTED_CAPABILITIES` 支持同一组（含 `buildSystems:2`）。功能矩阵佐证：`build-provider-refresh-and-tool` 与 `cargo-build-plugin` 记 macOS implemented/验证 pending。README 落后于代码，能力事实以 Core 与功能矩阵为准，不能以旧 README 推断安装可用性。

## 6. 维护规则

- 新增 fixture：同 PR 在 `scripts/plugins/plugin-fixture-coverage.json` 登记分类与双端证据；Windows 尚无测试时如实标 known gap（状态、阶段、说明），不得标 wired。
- 删除/重命名 fixture：同 PR 清理清单，否则 `missing-fixture` 失败。
- 移动/删除被引用的测试文件：更新证据条目，否则 `evidence-path` 失败。
- 关闭 gap：以真实 Windows 测试为证据更新 `windowsStatus`/`windowsEvidence` 并清空 gap 字段；检测器会拒绝"没有证据的 wired"。
- 统一交付：原 #1474、#1476、#1477 的改动收进同一分支与 PR；签名 fixture 和其分类同步提交。signature-vectors 类别允许 coreEvidence 为空，因为消费方是 Swift/Rust 宿主签名测试；当前按 validated-only/M1 记录，完整安装审批与失败恢复仍需生产路径验证。后续代码及覆盖登记只累积到统一 PR。
- 本文是审计快照；实时约束以清单 + 检测器为准。行号漂移不需要修本文，但证据文件消失必须处理。
