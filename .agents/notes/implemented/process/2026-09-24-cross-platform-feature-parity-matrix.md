# Agent 笔记：跨平台功能对齐矩阵

状态：已实现

## 先说结论

macOS 与 Windows 的功能对齐状态由 `shared/platform-feature-matrix/features/<id>.json` 分文件维护，Markdown 表格只是生成结果，不再作为第二份事实源。每个功能都必须分别记录两端的实现状态和运行验证状态；代码入口存在但没有真实跨平台验证时，保留实现程度并将验证状态标为 `pending`。

## 问题

macOS 是当前参考产品，Windows 是独立实现。两端可以共享 Rust Core 和契约，但 UI、平台适配和功能接入的提交节奏不同。仅靠 README、发布说明或目录搜索，无法回答“这个功能在另一端是否完成”，也无法发现代码已经移动后文档仍然指向旧路径的情况。

## 决策

采用“源数据 + 生成视图 + 轻量校验”的流程：

- `shared/platform-feature-matrix/features/<id>.json` 是唯一源数据，使用稳定的功能 ID，并分别保存 `macos`、`windows` 的 `implementationStatus`、`verificationStatus` 和证据路径。状态的 label、icon、description 由 `shared/platform-feature-matrix/metadata.json` 提供；已知缺口或外部 Issue 写在可选的 `notes` 字段中。
- `scripts/generate-platform-feature-matrix.mjs` 校验两套状态定义、ID 和证据路径，并在 `.artifacts/platform-feature-matrix/` 生成 HTML、Markdown、CSV 和汇总 JSON，生成物不提交到 Git。
- `scripts/verify-platform-feature-matrix.sh` 只校验源数据及证据路径，适合作为本地和 PR gate。
- `docs/development/platform-parity.md` 说明矩阵的使用规则；仓库根目录 `AGENTS.md` 只负责把贡献者引到 `develop-lithe` Skill，避免规则正文出现第二份副本。功能 PR 必须更新源数据，不得直接手改生成视图。
- `.github/workflows/verify-platform-feature-matrix.yml` 在每个 PR、`preview` / `main` 推送和手动运行时执行校验，并上传 JSON、Markdown、CSV 视图，方便在线查看和下载。
- `scripts/verify-platform-feature-matrix-change.sh` 检查平台实现路径变更是否同时更新矩阵；纯重构可通过 reviewer 添加 `matrix-exempt` label 显式豁免。
- 当前矩阵先按两端代码入口和共享契约完成初版静态盘点；实现状态不是实机验收结论，能力点的 `verificationStatus` 仍需后续跨平台验证推进。

实现状态分为 `implemented`、`partial`、`missing` 和 `platform-specific`，验证状态分为 `verified`、`pending` 和 `not-applicable`。矩阵行按“一个可单独验收的用户能力”拆分，`area` 和 `group` 只用于导航，不作为状态统计单位。只有 `implemented` 与 `verified` 同时成立才表示已经验收，避免把“有文件”误报成“跨平台可用”。

同一能力使用稳定 ID 作为文件名，生成器按文件名排序；公共复核日期描述初版盘点，不要求功能 PR 更新。PR 门禁比较能力文件的 JSON 内容，忽略格式、键顺序及顶层 `lastReviewed`；修改其他字段是否满足需求仍由 reviewer 审查。正确做法是 PHP PR 只更新对应 PHP 能力文件；不要靠改公共日期满足门禁，也不要自动选择一边来掩盖同一能力的真实分歧。

线上矩阵由现有 Pages 工作流发布到看板站点的子目录，不能独立部署第二份站点覆盖首页。PR 只上传附件、不执行公开部署。生成器转义 HTML 中来自能力记录的文本，页面不加载脚本。生成物依赖当前 checkout，工作树资源清单明确排除复用，始终在目标工作树重新校验生成。

## 考虑过的备选方案

### 总 JSON 加上提交生成文件

原方案让不同能力的 PR 共同修改全局数量和状态统计，制造无关冲突。按能力拆文件并将汇总移出 Git 后，不同能力可独立合并；同一能力发生真实分歧仍交给人工解决。

### 自动合并或机器人回写汇总

直接选一边可能丢掉状态和证据，机器人回写又会持续改变基线。因此 CI 只产生可下载视图，合并后统一发布网页，不回写源分支。


### 只维护 Markdown 表格

阅读方便，但状态值、证据路径和表格内容都依赖人工维护，代码移动后很容易产生过期链接。因此 Markdown 只作为生成视图保留。

### 只维护 CSV 或 Excel 文件

CSV 方便筛选，Excel 对非开发者更友好，但二进制 Excel 不利于 Git diff，CSV 也不适合保存结构化证据和状态约束。因此 CSV 作为自动生成的导出视图，不作为源文件；需要表格分析时打开 CSV，需要代码审查时看 JSON，需要仓库浏览时看 Markdown。

### 只用目录扫描推断功能状态

目录扫描能发现文件，但不能证明功能已接入工作台、配置已生效或运行时行为一致。矩阵保留人工确认的状态和验证动作，目录或文件路径只作为可校验的证据。

### 用一个 `status` 字段表达实现和验证

单字段会把“代码入口存在”和“运行时已经验收”混成一个结论，静态盘点很容易被渲染成绿色完成。现在用 `implementationStatus` 和 `verificationStatus` 分别表达两个问题，代价是每个平台多维护一个字段，但生成视图可以明确显示仍待验证的能力。

### 把所有差异都强行抽到 Rust Core

这会把 UI 和原生平台行为错误地塞进共享层。矩阵只记录产品行为和验证边界，不改变 `shared/contracts/`、Rust Core、macOS adapter 或 Windows Tauri 的现有所有权。

## 收益和代价

收益是 PR 中能直接看到新增缺口，证据路径失效会被脚本发现，发布前也能按 `partial` 和 `pending` 集中排查；开发者还可以用 CSV 在 Excel/Numbers 中按能力点筛选，任何 PR 的 Actions 运行都能下载对应版本的文件。代价是能力点数量会明显多于顶层功能模块，每个功能 PR 需要选择或新增准确的能力点，而且实现状态仍需要平台运行验证，不能完全自动推断。

## 后果

迁移已有 PR 时，需要把相对原基线的条目改动移到新文件，不能恢复旧总表。在线页面展示 preview 最新发布状态，PR 附件有保留期限；历史版本可在对应 checkout 重新生成。

后续 macOS 功能不会只出现在 macOS 代码和发布说明里，Windows 的缺口会在同一个 PR 中显式出现。矩阵不会阻止平台差异，也不会把平台专属能力强行抽成共享实现；它只要求差异有名称、有证据、有负责人和验证动作。

## 验证

- `node scripts/generate-platform-feature-matrix.mjs`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-platform-feature-matrix-change.sh <base> <head>`
- 修改 Agent Note 后运行 `./scripts/verify-agent-notes.sh`

## 适用范围

该矩阵适用于 macOS 与 Windows 的用户可观察功能，不替代共享契约、测试 fixture、平台构建或发布清单。平台专属能力也应记录，但标为 `platform-specific`，避免把合理差异误判为缺陷。
