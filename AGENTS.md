# Lithe Agent 入口

在仓库中开始任何工作前，先加载并遵循 `.agents/skills/develop-lithe/SKILL.md` 中的 `develop-lithe` Skill。它是 AI 编码和验证规则的唯一真源，也包含 Rust Core 必须遵守的注释规范。

如果任务会创建、迁移、更新、归档或审查 Agent 笔记，或者会把架构决策内容从 `docs/` 移出，开始前还要加载 `.agents/skills/agent-notes/SKILL.md`。Agent 笔记是架构决策和工程取舍的中文真源。

如果任务会创建、修改或审查测试代码、测试基础设施，开始前还要加载 `.agents/skills/write-stable-tests/SKILL.md`。该 Skill 规定 macOS 和 Windows 测试必须遵守的有界等待、确定性时间、资源清理和单测试计时规则。

如果任务会准备、验证或发布 Lithe 稳定版，修改发布说明、版本元数据、标签或发布工作流前，还要加载 `.agents/skills/release-lithe/SKILL.md`。

如果任务涉及通过 Parallels 虚拟机来构建、运行、诊断 Windows 产品，或向 Windows 产品传输文件，开始前还要加载 `.agents/skills/debug-windows-on-parallels/SKILL.md`。

## 测试进程生命周期与清理

除非用户明确要求保留进程运行，否则本次构建、测试、调试、预览或验证启动的任何 Lithe 应用，都必须在任务或测试完成后关闭。清理所有子进程、辅助进程、临时应用实例和相关资源，然后确认没有 Lithe 进程残留，再把结果交还给用户。

重复检查时不要启动重复的 Lithe 实例，也不要让测试构建的应用留在用户的应用列表中。如果某个进程无法正常停止，必须明确报告，并在继续工作前进行有界的尽力清理。

## 特殊 UI 交互

处理可拖动分隔条、可调整面板、连续拖动、滚动或其他高频 UI 交互时，先阅读：

- `.agents/skills/develop-lithe/SKILL.md`
- `.agents/notes/implemented/architecture/2026-09-13-resizable-ui-performance-boundaries.md`

入口文件只保留这条提醒；具体决策原因、正确做法、反例和验证要求以 Agent Note 与 Skill 为准，避免三份规则长期漂移。
