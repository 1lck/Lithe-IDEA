# Lithe PR 审查机器人配置

`Lithe PR review` 工作流只响应 PR 对话区中完全匹配 `@lithe review` 的
评论，普通 Issue 不会触发。审查会锁定 PR 的准确 head 提交，并读取完整 Git
历史、关联 Issue、PR 讨论、Review 和 CI 检查结果。

使用前，请在仓库 Actions 中配置以下 Secrets：

- `LITHE_ANTHROPIC_API_KEY`：Anthropic 或兼容中转站的 API Key。
- `LITHE_ANTHROPIC_BASE_URL`：Anthropic Messages 兼容的 Base URL。它不是
  OpenAI `/v1/responses` 地址，是否包含 `/v1` 以服务商说明为准。

还需创建 Actions 仓库变量 `LITHE_CLAUDE_MODEL`，值为服务商支持的准确 Claude
模型 ID。模型名不在工作流中硬编码，以便适配官方 Anthropic 和兼容中转站。

默认只有仓库所有者能够触发审查。如需指定白名单，请创建 Actions 仓库变量
`LITHE_ALLOWED_REVIEWERS`，值为 GitHub 用户名组成的 JSON 数组：

```json
["1lck", "maintainer"]
```

显式白名单会替代默认的仓库所有者规则。每个 PR head SHA 只保留一条机器人
评论；对同一个 head 重复召唤时会更新原评论。

每次授权召唤会先添加 👀 reaction，并创建一条“正在审查”的占位评论。准备、
模型执行和评论发布使用三个独立 job，模型 job 卡死不会阻止发布 job 更新失败
状态。Claude 通过官方 `anthropics/claude-code-action@v1` 以只读 GitHub 权限
运行，仅允许读取仓库和执行 `git` 命令。Claude execution output、最终消息和
诊断摘要会作为 artifact 保留 14 天；即使模型失败或超时，占位评论也会附上
本次 Actions 运行链接。

GitHub 只从仓库默认分支加载 `issue_comment` 工作流，因此这些文件进入默认
分支后，机器人才能正式响应评论。
