# 跨平台功能同步规则

## 先说结论

macOS 和 Windows 的功能状态以 `shared/platform-feature-matrix/features/<id>.json` 为唯一数据源，HTML、Markdown、CSV 和汇总 JSON 都是 CI 生成的阅读视图，不提交到 Git。每个功能必须同时记录两端的实现状态、验证状态、代码证据、负责人和可执行的验证方式；这样新增 macOS 功能时，PR 就会明确暴露 Windows 的实现程度和运行验证进度。

当前表是基于两端代码入口和共享契约的**初版静态盘点**，不是已经完成所有平台实机验收的最终报告。`implementationStatus` 表示已找到的实现程度，`verificationStatus` 单独记录是否完成运行验证；只有实现状态为 `implemented` 且验证状态为 `verified` 才表示已经验收。

## 为什么不只维护一张手工表

手工 Markdown 表很容易在代码改名、功能拆分或 Windows 接入后过期。机器可读清单可以被脚本检查：状态值不能写错，证据路径必须存在，功能 ID 不能重复，生成视图必须与源数据一致。JSON 适合作为源文件，因为它能稳定参与代码审查和脚本校验；Markdown 适合在仓库中阅读，CSV 适合在 Excel、Numbers 或表格工具中筛选排序。

## 开发者怎么更新

1. 新增功能时，先在 `shared/platform-feature-matrix/features/<id>.json` 增加一个稳定的 `id`；一行只描述一个可以单独验收的用户能力，不要把“Git”或“数据库”这样的总模块作为一行。
2. 填写 `area`、`group` 和 `capability` 进行导航，再为 `macos` 和 `windows` 各填 `implementationStatus`、`verificationStatus` 与 `evidence`。代码存在但没有运行时证据时保留实现状态，并将验证状态写成 `pending`；已知 Issue 或范围限制写在可选的 `notes` 字段。
3. 在 `verification` 中写出两端都能执行的验证动作；如果行为刻意只属于一个平台，将实现状态写成 `platform-specific` 并说明原因。
4. 运行 `node scripts/generate-platform-feature-matrix.mjs` 生成 `.artifacts/platform-feature-matrix/` 下的阅读视图，再运行 `./scripts/verify-platform-feature-matrix.sh` 检查能力记录和证据路径。
5. 功能 PR 必须同时包含源数据变更；不要提交生成视图；公共配置或日期变动不能代替能力更新。

## 状态边界

实现状态和验证状态是两个独立维度，完整定义以 `shared/platform-feature-matrix/metadata.json` 的 `statusDefinitions` 为准。

- **实现状态**：`implemented`、`partial`、`missing`、`platform-specific`，描述代码入口、产品接入和范围。
- **验证状态**：`verified`、`pending`、`not-applicable`，描述是否按 `verification` 完成真实运行验证。
- **已实现但待验证**：代码入口存在但没有运行证据，必须显示为 `implementationStatus: implemented` 与 `verificationStatus: pending`。

## 查看当前状态

当前能力数量、各平台缺口和待验证项都只维护在[在线矩阵](https://1lck.github.io/Lithe-IDEA/platform-feature-matrix/)及其下载视图中。本页只保留不会随功能数量变化的规则，避免手写数量和缺口列表与矩阵漂移。

## CI 接入建议

`.github/workflows/verify-platform-feature-matrix.yml` 在 PR、`preview` / `main` 推送和手动运行时校验清单、证据路径并生成阅读视图。PR 门禁比较能力 JSON 的实际内容，忽略格式、键顺序和条目顶层 `lastReviewed` 日期变化；公共配置不能满足门禁。条目是否与代码改动对应、运行证据是否充分仍由 reviewer 确认。纯重构可由 reviewer 添加 `matrix-exempt` 标签，增删标签都会重新执行门禁。

Actions 摘要提供当前版本的 HTML、Markdown、CSV、JSON 下载附件。现有 Pages 工作流在 `preview` 合并后把矩阵发布到 Agent Notes 站点的 `platform-feature-matrix/` 子目录，保持看板首页不变；页面显示提交 SHA。历史 PR 请下载对应 Actions artifact（保留 14 天），不要用在线 preview 页面作为 PR 验证结果。本地也可重新生成历史版本视图。

## 旧分支迁移

迁移前的 PR 先记录自己相对原基线在总 JSON 中的能力改动，更新到最新 `preview` 后，将这些改动逐项应用到 `features/<id>.json`。不要恢复已删除的总 JSON 或生成 CSV，也不要用旧总表覆盖最新条目。解决同一能力上的分歧后运行校验和生成命令；其他能力的数据保持最新基线。
