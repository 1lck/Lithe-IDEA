# Agent 笔记：插件 fixture 覆盖门禁

状态：已实现

## 先说结论

`shared/contracts/plugins/v1/fixtures` 的覆盖检测器（`scripts/check-plugin-fixture-coverage.mjs` + `plugin-fixture-coverage.json` + 单测）已接入 `ci-macos.yml` 的 `changes` job——该 job 在 ubuntu runner 上对每个 pull request（含 Draft）运行，不新增 workflow、不占 macOS/Windows runner。任何人新增 fixture 而不在清单登记，真实 PR 检查会以 `unknown-fixture` 失败。门禁的防伪造立场是"证据与诚实分类"，不是"永远保持 partial"：允许全部 fixture 真实 wired 后零缺口通过，但没有证据的 wired、没有阶段归属的缺口一律拒绝。

## 问题

- 覆盖清单（M0 交付）靠显式登记维护。若只在本地运行检测器，"新增 fixture 忘了登记"只会安静漏过，`unknown-fixture` 不会让任何 PR 失败，清单会重新漂移。
- 第一版真实仓库守护测试断言 `knownGaps > 0`：把 2026-10-25 当天的真实缺口数量固化成了永久约束。未来某天缺口真实补齐时这个断言必然失败，反而诱导后人删掉守护测试。
- 缺口阶段（gapStage）的注释说 M0–M10，正则却排除 M0，语义与说明不一致。

## 决策

### CI 入口复用现有 Linux lane，不旁建 workflow

`ci-macos.yml` 的 `changes` job 已有一个"scripts 测试 + JUnit/HTML 计时报告 + artifact 上传"的成熟 lane（Sparkle baseline 模式）：`node --test` 双 reporter（spec 到 stdout、junit 到 `.artifacts/test-stability/<stem>.junit.xml`），再用 `parse-junit-cases.mjs` + `writeTestReportArtifacts` 生成逐项计时的 HTML/JUnit 报告，最后由同一 job 的 upload 步骤上传整个 `.artifacts/test-stability/`。插件 fixture 门禁镜像同一模式插入三步：检测器 CLI（真正的清单 vs 目录比较）、单测（`--test-timeout=15000` 本地期限）、计时报告生成。该 job 在 ubuntu 上对所有 PR 运行（含 Draft），因此 #1476 这类新增 fixture 的 PR 在合入前就会撞上 `unknown-fixture`。

门禁与测试的接线由测试自身守护：`check-plugin-fixture-coverage.test.mjs` 里有一条 CI 接线守卫测试，读取 `ci-macos.yml` 断言两个入口（CLI 步骤、测试文件）与期限/报告参数存在——workflow 改名或移除调用时，测试先红。

### 防伪造 = 诚实分类，不是永久 partial

- 正例：一个全部 wired 且证据文件真实存在的清单，检测器必须通过且 `knownGaps = 0`（有专门单测锁住这条路）。未来覆盖补齐时门禁自然放行。
- 负例：wired 却没有 Windows 证据、known gap 缺阶段或说明、证据引用文件不存在，全部拒绝（既有单测覆盖）。
- 真实仓库守护测试只断言"清单与目录一致 + 每个非 wired 条目带合法阶段与说明"，不再断言缺口数量。

### gapStage 语义：M0–M10 全部合法

路线图 M0 的退出条件把基线问题路由进聚焦修复 PR，所以"由 M0 拥有的缺口"是合法归属；M11 及以后不存在。正则为 `^M(10|[0-9])$`，注释与实现一致，并有单测同时覆盖 M0 接受与 M11 拒绝。

### M1 交接（#1476）

`fixtures/signature-vectors.json` 在 #1476 中新增；其 PR 合入 preview 前（或同时）必须在清单登记，否则撞 `unknown-fixture`。最小登记条目（检测器已预置 `signature-vectors` 类别）：

```json
{
  "path": "signature-vectors.json",
  "category": "signature-vectors",
  "outcome": "success",
  "coreEvidence": [],
  "windowsEvidence": ["windows/tauri/src-tauri/src/plugin_host/signature.rs:663 shared_fixture_verifies_end_to_end"],
  "windowsStatus": "<按 #1476 实际证据填 wired 或 validated-only>",
  "gapStage": null,
  "gapDetail": null
}
```

该类别是唯一允许 `coreEvidence` 为空的类别：签名向量由双端宿主各自的签名测试消费（Windows `signature.rs`、macOS `PluginSignatureVectorTests.swift` 的 RFC 8032 锚点、确定性签名、内容摘要、签名文档回读四组 @Test），没有 Core 校验面；豁免只对 `signature-vectors` 生效，其他类别仍必须有 Core 侧证据（有单测锁定）。`backend.plugin.json` 已由本 PR 随 preview 同步（`83017afa`/8471b998）登记为 `unwired` + `followup`——`followup` 是为"冻结路线图（M0–M10）之后落地、按计划 §6 单列后续阶段"的新能力保留的缺口阶段，是 M 编号之外的唯一合法值。登记条目的最终行号以 #1476 合并时的代码为准。合并顺序优先 #1474（门禁）先合、#1476 随后带登记合入；若 #1476 先合，它必须自带登记条目，否则其 PR 门禁失败。

## 考虑过的备选方案

- 新建独立 `ci-fixture-coverage.yml`：多一个 workflow、多一份维护与触发面，且与"优先复用现有门禁"的仓库惯例冲突，不采用。
- 只在本地可选运行检测器：登记纪律依赖人的记忆，已知会漂移，不采用。
- 保留 `knownGaps > 0` 作为防伪造断言：把"今天有缺口"固化成"永远有缺口"，未来真实补齐反而红，防伪造应针对"没有证据的 wired"，不采用。
- 在 `verify-shared-contracts.sh`（Ruby 内联）里实现枚举比较：该脚本是契约语义校验（schema/拒绝码），把 Node 已实现的检测器复制一份 Ruby 只会分叉逻辑，不采用。

## 后果

- 收益：新增 fixture 未登记会直接打红 PR（含 Draft）；单测有 15 秒本地期限与逐项计时报告；覆盖补齐路径（全 wired）有正例保证畅通。
- 代价：`ci-macos.yml` 的 `changes` job 多两步（约几秒）；维护清单成为改 fixture 的同 PR 义务；workflow 与测试之间由守卫测试双向绑定，改 CI 入口措辞时守卫测试需要同步。

## 验证

```bash
node scripts/check-plugin-fixture-coverage.mjs
node --test --test-timeout=15000 scripts/check-plugin-fixture-coverage.test.mjs
node --test --test-reporter=junit --test-reporter-destination=.artifacts/test-stability/plugin-fixture-coverage.junit.xml scripts/check-plugin-fixture-coverage.test.mjs
./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1   # 或 .sh
node scripts/verify-agent-notes.mjs
```

CI 等效路径：`ci-macos.yml` changes job（ubuntu）的 "Check plugin fixture coverage manifest" / "Run plugin fixture coverage tests" / "Generate plugin fixture coverage timing report" 三步，artifact 随既有 upload 步骤上传。

## 适用范围

- `scripts/check-plugin-fixture-coverage.mjs`、`scripts/plugin-fixture-coverage.json`、`scripts/check-plugin-fixture-coverage.test.mjs`
- `.github/workflows/ci-macos.yml` 的 changes job 中 "plugin fixture coverage" 三步
- `docs/development/windows-plugin-fixture-coverage.md`（审计快照与维护规则）

不覆盖：M1 拥有的签名/安装信任链 Note（#1476）、共享契约 fixtures 本体、平台功能矩阵。
