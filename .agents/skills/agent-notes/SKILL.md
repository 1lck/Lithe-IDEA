---
name: agent-notes
description: 创建、迁移、更新或审查 Lithe 的 .agents/notes 决策笔记时使用。用于把架构取舍、被否方案、验证依据和适用范围维护成中文、可检索、可校验的 Agent 笔记；不用于发布说明、普通使用教程或正式契约 schema。
---

# Agent Notes

本 Skill 负责维护 `.agents/notes/`。这里是 Lithe 架构决策、工程取舍、
被否方案和历史约束的记录位置。

## 基本原则

- 文档正文使用中文。代码路径、命令、协议字段、Rust 标识和 ABI 名称按
  真实拼写保留。
- 默认读取 `implemented/`。只有设计新方案时读取 `proposed/`，只有做类似
  选型或排查重复问题时读取 `rejected/`，默认不读取 `archived/`。
- 优先更新已有 Note。路径、类名、模块位置、默认值和验证命令变化时，
  修改持有该决策的原 Note，不新建流水账。
- 只有决策本身发生变化时才新建 Note。新决策完全取代旧决策时，新 Note
  承接仍有价值的理由，旧 Note 进入 `archived/`。
- Note 记录“为什么这样做、放弃了什么、怎么证明仍然成立”。不要复制
  API 参考、字段全集、命令手册或代码能直接表达的实现细节。
- 修改架构边界、跨平台契约、核心状态机、测试策略、构建发布流程或
  高风险平台适配器时，先检索相关 Note，再改代码。

## 路径和生命周期

路径就是状态：

```text
.agents/notes/
├── AGENTS.md
├── README.md
├── manifest.json
├── proposed/<class>/yyyy-mm-dd-topic.md
├── implemented/<class>/yyyy-mm-dd-topic.md
├── rejected/<class>/yyyy-mm-dd-topic.md
└── archived/<class>/yyyy-mm-dd-topic.md
```

四个生命周期目录都保留完整分类骨架，并各自包含局部 `AGENTS.md`。空分类
目录使用 `.gitkeep` 保持可见，方便 GitHub 和 IDE 中直接选择落点。

`class` 只使用这六类：

- `feature`：用户或模型可观察的新能力或非显然行为。
- `bug-fix`：缺陷修复、事故复盘或防止回归的约束。
- `simplification`：只删减能力、表面、依赖或复杂度。
- `architecture`：源码组织、边界、依赖方向和包拓扑。
- `process`：围绕代码的协作、验证、发布和自动化流程。
- `testing`：测试策略、测试基础设施和稳定性约束。

文件名使用首次提出日期和英文 slug，例如：

```text
2026-09-13-repository-ownership-and-sharing-boundaries.md
```

## 写作格式

已落地决策使用：

```markdown
# Agent 笔记：标题

状态：已实现

## 问题

## 决策

## 考虑过的备选方案

## 后果

## 验证

## 适用范围
```

提案使用 `状态：提议中`，并把 `## 决策` 换成 `## 提案`，把 `## 后果`
换成 `## 验收标准` 和 `## 风险`。

被否方案使用 `状态：已否决：一句话原因`，保留提案视角，并包含
`## 否决理由`。

模板在本 Skill 的 `templates/` 目录中。写完后运行：

```bash
./scripts/verify-agent-notes.sh
```

该脚本同时校验 Note 格式、路径、链接、验证命令和目录骨架；新增生命周期
或分类必须同步更新 `.agents/notes/manifest.json`、本 Skill 和校验脚本。

## 检索流程

改动前按最窄范围查找：

1. 阅读相关代码入口附近的 Note 引用。
2. 按类别查看 `implemented/<class>/`。
3. 使用关键词检索 active Notes，默认排除 `archived/`：

   ```bash
   rg --hidden --glob '!.agents/notes/archived/**' '<关键词>' .agents/notes/
   ```

4. 做新选型、重构或避免重复踩坑时再读取 `rejected/`。

不要启动时全文读取 `.agents/notes/`。这是渐进式披露系统，不是全量上下文
仓库。

## 看板与发布

看板不是第二份文档，而是由当前 `.agents/notes/` 生成的只读视图。需要本地
查看时运行：

```bash
node scripts/build-agent-notes-board.mjs --init .artifacts/agent-notes-board.html "Lithe 工程决策看板"
```

需要生成包含完整 Note 正文的静态页面时运行：

```bash
node scripts/build-agent-notes-board.mjs \
  --bundle .agents/notes .artifacts/agent-notes-board/index.html "Lithe 工程决策看板"
```

`.github/workflows/deploy-agent-notes-board.yml` 会在 `preview` 分支提交时
先校验 Note，再重新生成 Pages artifact；不要提交生成的 `index.html`。

## 代码入口绑定

只在架构承重墙或高风险入口加一行反向引用，不给普通函数加引用：

```swift
// Note: 仓库所有权与共享边界见 .agents/notes/implemented/architecture/2026-09-13-repository-ownership-and-sharing-boundaries.md
```

适合绑定的位置包括组合根、核心协议、dispatcher、状态机入口、平台边界、
共享契约入口和测试基础设施入口。迁移已有代码时，只给这些入口补索引。

## 迁移规则

- `docs/architecture/` 中的架构决策迁入 `.agents/notes/` 后，删除原副本并
  修复引用。
- 使用教程、发布说明、视觉 QA、正式 schema 和共享契约不迁入 Note。
- 长文档可以拆分；已经落地的事实进入 `implemented/`，未完成方案进入
  `proposed/`，被否但容易复犯的方案进入 `rejected/`。
- 如果一篇旧文档混合了当前事实和未完成计划，先拆生命周期，再删除旧文档。

## 收尾

提交前确认：

- Note 与代码或流程变更在同一提交中。
- `## 考虑过的备选方案` 至少包含真实备选，而不是只写“做或不做”。
- `## 后果` 同时写收益和代价。
- `## 验证` 中的脚本存在，且和本次改动相关。
- `## 适用范围` 中的路径仍存在。
- `./scripts/verify-agent-notes.sh` 通过。
