# 跨平台功能同步规则

## 先说结论

macOS 和 Windows 的功能状态以 `shared/platform-feature-matrix.json` 为唯一数据源，`docs/development/platform-parity-matrix.md` 和 `docs/development/platform-parity-matrix.csv` 都是自动生成的阅读视图。每个功能必须同时记录两端状态、代码证据、负责人和可执行的验证方式；这样新增 macOS 功能时，PR 就会明确暴露 Windows 是“已实现、部分实现、未实现，还是还没有验证”。

当前表是基于两端代码入口和共享契约的**初版静态盘点**，不是已经完成所有平台实机验收的最终报告。`implemented` 表示已找到产品接入和实现入口；真实运行结果仍需按每行的 `verification` 逐项补齐。

## 为什么不只维护一张手工表

手工 Markdown 表很容易在代码改名、功能拆分或 Windows 接入后过期。机器可读清单可以被脚本检查：状态值不能写错，证据路径必须存在，功能 ID 不能重复，生成视图必须与源数据一致。JSON 适合作为源文件，因为它能稳定参与代码审查和脚本校验；Markdown 适合在仓库中阅读，CSV 适合在 Excel、Numbers 或表格工具中筛选排序。

## 开发者怎么更新

1. 新增功能时，先在 `shared/platform-feature-matrix.json` 增加一个稳定的 `id`；一行只描述一个可以单独验收的用户能力，不要把“Git”或“数据库”这样的总模块作为一行。
2. 填写 `area`、`group` 和 `capability` 进行导航，再为 `macos` 和 `windows` 各填 `status` 与 `evidence`。代码存在但没有运行时证据时使用 `needs-verification`，不要直接写成 `implemented`。
3. 在 `verification` 中写出两端都能执行的验证动作；如果行为刻意只属于一个平台，使用 `platform-specific` 并说明原因。
4. 运行 `node scripts/generate-platform-feature-matrix.mjs` 生成 Markdown 和 CSV 表格，再运行 `./scripts/verify-platform-feature-matrix.sh` 检查证据路径和生成结果。
5. 功能 PR 必须同时包含源数据变更；不要直接编辑生成的 `docs/development/platform-parity-matrix.md` 或 `docs/development/platform-parity-matrix.csv`。

## 状态边界

- **已实现**：两端都有代码入口和产品接入，但仍应按验证方式做运行验证。
- **部分实现**：两端都有入口，但能力范围、入口、平台适配或用户体验不一致。
- **未实现**：当前没有足够的实现入口或产品接入证据。
- **待验证**：静态代码看起来存在，但必须通过真实应用、fixture 或跨平台 E2E 才能确认。
- **平台专属**：这是明确的操作系统能力，不要求另一端复制。

## 当前重点

首版矩阵显示，最需要持续关注的是：

- 当前已盘点 74 个可单独验收的能力点；后续新增能力应优先新增能力点，而不是重新增加一个笼统模块。
- Windows 的 LSP/JDTLS 真实运行验证仍应单独完成，不能只依据目录存在判断完成。
- macOS 尚无 Windows 已有的 AI 对话能力；这不是 AI 提交信息功能的缺失，两者应分开跟踪。
- macOS 的 Outline 和 Docker/Compose 当前只标为部分实现，需要确认实际入口和覆盖范围。
- macOS 尚无远程工作区和 Vim 模式，Windows 尚无 LINUX DO 社区入口。
- LINUX DO 社区入口目前只有 macOS，Windows 应明确显示为缺口，而不是让用户从“功能看起来相似”中猜测。

## CI 接入建议

`.github/workflows/verify-platform-feature-matrix.yml` 会在每个 Pull Request、`main` 分支推送和手动运行时执行 `./scripts/verify-platform-feature-matrix.sh`。它不会启动应用，只验证清单、证据路径和生成视图没有漂移；同时会在 GitHub Actions 摘要中提供 Markdown 在线查看和 CSV 下载入口，并上传包含 JSON、Markdown、CSV 的可下载 artifact。真正的运行时对齐仍由各平台测试和发布前验证负责。
