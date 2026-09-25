# 跨平台功能同步规则

## 先说结论

macOS 和 Windows 的功能状态以 `shared/platform-feature-matrix.json` 为唯一数据源，`docs/development/platform-parity-matrix.md` 和 `docs/development/platform-parity-matrix.csv` 都是自动生成的阅读视图。每个功能必须同时记录两端的实现状态、验证状态、代码证据、负责人和可执行的验证方式；这样新增 macOS 功能时，PR 就会明确暴露 Windows 的实现程度和运行验证进度。

当前表是基于两端代码入口和共享契约的**初版静态盘点**，不是已经完成所有平台实机验收的最终报告。`implementationStatus` 表示已找到的实现程度，`verificationStatus` 单独记录是否完成运行验证；只有实现状态为 `implemented` 且验证状态为 `verified` 才表示已经验收。

## 为什么不只维护一张手工表

手工 Markdown 表很容易在代码改名、功能拆分或 Windows 接入后过期。机器可读清单可以被脚本检查：状态值不能写错，证据路径必须存在，功能 ID 不能重复，生成视图必须与源数据一致。JSON 适合作为源文件，因为它能稳定参与代码审查和脚本校验；Markdown 适合在仓库中阅读，CSV 适合在 Excel、Numbers 或表格工具中筛选排序。

## 开发者怎么更新

1. 新增功能时，先在 `shared/platform-feature-matrix.json` 增加一个稳定的 `id`；一行只描述一个可以单独验收的用户能力，不要把“Git”或“数据库”这样的总模块作为一行。
2. 填写 `area`、`group` 和 `capability` 进行导航，再为 `macos` 和 `windows` 各填 `implementationStatus`、`verificationStatus` 与 `evidence`。代码存在但没有运行时证据时保留实现状态，并将验证状态写成 `pending`；已知 Issue 或范围限制写在可选的 `notes` 字段。
3. 在 `verification` 中写出两端都能执行的验证动作；如果行为刻意只属于一个平台，将实现状态写成 `platform-specific` 并说明原因。
4. 运行 `node scripts/generate-platform-feature-matrix.mjs` 生成 Markdown 和 CSV 表格，再运行 `./scripts/verify-platform-feature-matrix.sh` 检查证据路径和生成结果。
5. 功能 PR 必须同时包含源数据变更；不要直接编辑生成的 `docs/development/platform-parity-matrix.md` 或 `docs/development/platform-parity-matrix.csv`。

## 状态边界

实现状态和验证状态是两个独立维度，完整定义以 `shared/platform-feature-matrix.json` 的 `statusDefinitions` 为准。

- **实现状态**：`implemented`、`partial`、`missing`、`platform-specific`，描述代码入口、产品接入和范围。
- **验证状态**：`verified`、`pending`、`not-applicable`，描述是否按 `verification` 完成真实运行验证。
- **已实现但待验证**：代码入口存在但没有运行证据，必须显示为 `implementationStatus: implemented` 与 `verificationStatus: pending`。

## 查看当前状态

当前能力数量、各平台缺口和待验证项都只维护在自动生成的 `docs/development/platform-parity-matrix.md` 与 CSV 视图中。本页只保留不会随功能数量变化的规则，避免手写数量和缺口列表与矩阵漂移。

## CI 接入建议

`.github/workflows/verify-platform-feature-matrix.yml` 会在每个 Pull Request、`main` 分支推送和手动运行时执行 `./scripts/verify-platform-feature-matrix.sh`。它不会启动应用，只验证清单、证据路径和生成视图没有漂移；Pull Request 还会检查平台实现路径变更是否同时更新矩阵。纯重构如果确实没有用户可观察变化，reviewer 可以添加 `matrix-exempt` label 作为显式例外。Actions 摘要会提供 Markdown 在线查看和 CSV 下载入口，并上传包含 JSON、Markdown、CSV 的可下载 artifact。真正的运行时对齐仍由各平台测试和发布前验证负责。
