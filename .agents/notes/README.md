# Lithe Agent Notes

这里是 Lithe 给 Agent 和开发者共同维护的工程决策库。它替代过去容易过期的
架构说明散文，只记录会影响后续实现判断的内容：为什么这样做、放弃了什么、
怎么证明仍然成立、适用于哪些代码路径。

## 目录

```text
.agents/notes/
├── implemented/    # 已落地，默认读取
├── proposed/       # 提案中，设计新方案时读取
├── rejected/       # 已否决，避免重复踩坑时读取
└── archived/       # 已归档，默认不读取
```

每个生命周期目录下再按类型分组：

```text
architecture/
bug-fix/
feature/
process/
simplification/
testing/
```

## 使用方式

修改代码前，不要全文读取所有 Note。推荐流程：

1. 查看相关代码入口附近是否有 `// Note:` 反向引用。
2. 按任务关键词检索 `.agents/notes/implemented/`。
3. 做新方案时再查看 `.agents/notes/proposed/`。
4. 遇到看似熟悉但可能被否过的方案时查看 `.agents/notes/rejected/`。

本地校验：

```bash
./scripts/verify-agent-notes.sh
```

本地生成看板：

```bash
node scripts/build-agent-notes-board.mjs \
  --bundle .agents/notes .artifacts/agent-notes-board/index.html "Lithe 工程决策看板"
```

看板是从 Note 生成的只读视图，不要手写或提交生成的 `index.html`。
