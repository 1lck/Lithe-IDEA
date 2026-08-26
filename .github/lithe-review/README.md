# Lithe PR 审查机器人配置

`Lithe PR review` 工作流只响应 PR 对话区中完全匹配 `@lithe review` 的
评论，普通 Issue 不会触发。审查锁定 PR 的准确 base/head，并读取完整 Git
历史、关联 Issue、PR 讨论、Review 和 CI 检查结果。

## Codex 中转站

在仓库 Actions 中配置以下 Secrets：

- `LITHE_CODEX_API_KEY`：Codex Responses API 兼容中转站的 API Key。
- `LITHE_CODEX_RESPONSES_URL`：完整的 Responses API 地址，通常以
  `/v1/responses` 结尾。服务必须接受 `Authorization: Bearer <key>`，并支持
  Codex 所需的流式响应、工具调用和结构化输出。

不要把 API Key、私人中转地址或其他凭据提交到仓库。工作流通过官方
`openai/codex-action@v1` 的安全代理把 Secret 传给中转站。

所有阶段固定使用 `gpt-5.6-sol`。planner 和最终 aggregator 使用 `xhigh`
reasoning effort，三个并行 reviewer 使用 `medium`。中转站必须支持这一模型名和
两种思考强度。

## 审查流水线

授权召唤按以下阶段执行：

1. `prepare` 构建可信上下文并发布占位评论。
2. `planner` 理解变更，为三个固定审查视角分配重点；模型失败时使用确定性默认计划。
3. `reviewers` 从正确性、架构契约、韧性安全三个视角并行审查，最大并发为 2。
4. `aggregate` 重新读取代码验证候选发现、去重并生成最终评论。
5. `publish` 更新对应 head SHA 的机器人评论。

各模型阶段都 checkout 相同的不可变 head SHA，使用只读 sandbox，并通过 JSON
Schema 交换结构化结果。planner、每个 reviewer 和 aggregator 位于独立 job，拥有
独立超时和 artifact；单个 reviewer 失败不会阻止其余结果进入最终聚合。planner、
reviewer 和聚合产物保留 14 天，便于定位中转站或模型失败。

默认只有仓库所有者能够触发审查。如需指定白名单，请创建 Actions repository
variable `LITHE_ALLOWED_REVIEWERS`，值为 GitHub 用户名组成的 JSON 数组：

```json
["1lck", "maintainer"]
```

显式白名单会替代默认规则。同一 head SHA 重复召唤时会更新原评论。GitHub 只从
仓库默认分支加载 `issue_comment` 工作流，因此这些文件进入默认分支后机器人才能
使用新流程。
