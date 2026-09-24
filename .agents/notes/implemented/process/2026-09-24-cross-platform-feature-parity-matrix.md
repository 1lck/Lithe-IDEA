# Agent 笔记：跨平台功能对齐矩阵

状态：已实现

## 先说结论

macOS 与 Windows 的功能对齐状态由 `shared/platform-feature-matrix.json` 维护，Markdown 表格只是生成结果，不再作为第二份事实源。每个功能都必须记录两端状态、代码证据、负责人和验证动作；代码入口存在但没有真实跨平台验证时必须标记为 `needs-verification`。

## 问题

macOS 是当前参考产品，Windows 是独立实现。两端可以共享 Rust Core 和契约，但 UI、平台适配和功能接入的提交节奏不同。仅靠 README、发布说明或目录搜索，无法回答“这个功能在另一端是否完成”，也无法发现代码已经移动后文档仍然指向旧路径的情况。

## 决策

采用“源数据 + 生成视图 + 轻量校验”的流程：

- `shared/platform-feature-matrix.json` 是唯一源数据，使用稳定的功能 ID，并分别保存 `macos`、`windows` 状态和证据路径。
- `scripts/generate-platform-feature-matrix.mjs` 校验状态、ID 和证据路径，并生成 `docs/development/platform-parity-matrix.md` 和 `docs/development/platform-parity-matrix.csv`。
- `scripts/verify-platform-feature-matrix.sh` 重新生成后检查生成文件没有漂移，适合作为本地和 PR gate。
- `docs/development/platform-parity.md` 和仓库根目录 `AGENTS.md` 说明更新规则；功能 PR 必须更新源数据，不得直接手改生成视图。
- `.github/workflows/verify-platform-feature-matrix.yml` 在每个 PR、`main` 推送和手动运行时执行校验，并上传 JSON、Markdown、CSV 视图，方便在线查看和下载。
- 当前矩阵先按两端代码入口和共享契约完成初版静态盘点；`implemented` 不是实机验收结论，能力点的 `verification` 仍是后续跨平台验证入口。

状态分为 `implemented`、`partial`、`missing`、`needs-verification` 和 `platform-specific`。矩阵行按“一个可单独验收的用户能力”拆分，`area` 和 `group` 只用于导航，不作为状态统计单位。其中 `implemented` 只代表代码入口与产品接入存在，不替代真实运行验证；这避免把“有文件”误报成“跨平台可用”。

## 考虑过的备选方案

### 只维护 Markdown 表格

阅读方便，但状态值、证据路径和表格内容都依赖人工维护，代码移动后很容易产生过期链接。因此 Markdown 只作为生成视图保留。

### 只维护 CSV 或 Excel 文件

CSV 方便筛选，Excel 对非开发者更友好，但二进制 Excel 不利于 Git diff，CSV 也不适合保存结构化证据和状态约束。因此 CSV 作为自动生成的导出视图，不作为源文件；需要表格分析时打开 CSV，需要代码审查时看 JSON，需要仓库浏览时看 Markdown。

### 只用目录扫描推断功能状态

目录扫描能发现文件，但不能证明功能已接入工作台、配置已生效或运行时行为一致。矩阵保留人工确认的状态和验证动作，目录或文件路径只作为可校验的证据。

### 把所有差异都强行抽到 Rust Core

这会把 UI 和原生平台行为错误地塞进共享层。矩阵只记录产品行为和验证边界，不改变 `shared/contracts/`、Rust Core、macOS adapter 或 Windows Tauri 的现有所有权。

## 收益和代价

收益是 PR 中能直接看到新增缺口，证据路径失效会被脚本发现，发布前也能按 `partial` 和 `needs-verification` 集中排查；开发者还可以用 CSV 在 Excel/Numbers 中按能力点筛选，任何 PR 的 Actions 运行都能下载对应版本的文件。代价是能力点数量会明显多于顶层功能模块，每个功能 PR 需要选择或新增准确的能力点，而且“已实现”仍需要平台运行验证，不能完全自动推断。

## 后果

后续 macOS 功能不会只出现在 macOS 代码和发布说明里，Windows 的缺口会在同一个 PR 中显式出现。矩阵不会阻止平台差异，也不会把平台专属能力强行抽成共享实现；它只要求差异有名称、有证据、有负责人和验证动作。

## 验证

- `node scripts/generate-platform-feature-matrix.mjs`
- `./scripts/verify-platform-feature-matrix.sh`
- 修改 Agent Note 后运行 `./scripts/verify-agent-notes.sh`

## 适用范围

该矩阵适用于 macOS 与 Windows 的用户可观察功能，不替代共享契约、测试 fixture、平台构建或发布清单。平台专属能力也应记录，但标为 `platform-specific`，避免把合理差异误判为缺陷。
