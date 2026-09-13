# Agent Notes 目录规则

进入 `.agents/notes/` 前必须先读取 `.agents/skills/agent-notes/SKILL.md`。
本目录只保存 Lithe 的中文 Agent 决策笔记：架构取舍、被否方案、长期约束、
验证依据和适用范围。

## 放置规则

路径表达生命周期：

- `implemented/`：已经落地、默认可信的当前决策。
- `proposed/`：尚未落地或等待确认的方案。
- `rejected/`：明确否决、但以后容易再次提出的方案。
- `archived/`：曾经有效、后来被新决策替代的历史决策。

生命周期下只使用这些分类：

- `architecture`
- `bug-fix`
- `feature`
- `process`
- `simplification`
- `testing`

Note 文件名使用首次提出日期和英文 slug：

```text
yyyy-mm-dd-topic.md
```

## 读取规则

默认只读取 `implemented/` 中与当前任务相关的 Note。只有设计新方案时读取
`proposed/`，只有排查重复方案或选型时读取 `rejected/`，默认不读取
`archived/`。

不要启动任务时全文读取本目录。先看代码入口附近的 Note 反向引用，再按
关键词检索最窄范围。

## 写入规则

- 正文必须使用中文。
- 不放 API 参考、字段全集、发布说明、普通教程、CI 日志或一次性执行计划。
- 不创建集中索引；看板由脚本生成，不是第二份文档。
- 写完运行 `./scripts/verify-agent-notes.sh`。
