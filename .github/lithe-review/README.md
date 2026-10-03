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

审查固定使用 `gpt-5.6-sol` 和 `medium` reasoning effort。中转站必须支持该模型名、
流式工具调用和结构化输出。

## 审查流水线

授权召唤按以下阶段执行：

1. `prepare` 构建可信上下文、分类 PR 规模并发布占位评论。
2. `review` 在准确 head SHA 上运行一次只读 Codex 审查，直接生成最终结构化结果。
3. `publish` 无论 review 成功、失败还是超时都会更新对应 head SHA 的机器人评论。

`prepare` 从 GitHub PR files API 生成确定性文件清单。超过 100 个文件或 20,000 行
增删时进入大型变更模式，只列出最多 240 个高语义文件，并统计但不展开图片、二进制、
生成文件、锁文件和纯重命名。GitHub 对该 API 的 3,000 文件上限会在 prompt 中明确
标记，不能被模型误认为完整清单。

模型从清单和聚焦 diff 开始，只能执行有目录、glob、文件大小、列宽和输出行数限制的
搜索。审查只报告置信度至少 80、具有具体触发场景的问题；没有明确问题时直接返回
`LGTM`。review 使用只读 sandbox 和固定 head SHA，最终候选与诊断附件保留 14 天。

同一 PR 和 head SHA 的重复召唤会排队而不会互相取消；不同 head 可以独立执行。
`publish` 是独立 job，因此 review 整体 timeout 后也不会永久留下“正在审查”占位评论。

默认只有仓库所有者能够触发审查。如需指定白名单，请创建 Actions repository
variable `LITHE_ALLOWED_REVIEWERS`，值为 GitHub 用户名组成的 JSON 数组：

```json
["1lck", "maintainer"]
```

显式白名单会替代默认的仓库所有者规则。除此之外，当 PR 的目标分支精确为 `preview`
时，该 PR 的发起者也可以召唤；这项额外权限不适用于 `main`、版本化 preview 分支或
其他分支。同一 head SHA 重复召唤时会更新原评论。GitHub 只从仓库默认分支加载
`issue_comment` 工作流，因此这些文件进入默认分支后机器人才能使用新流程。

## PR Review 状态标签

`Lithe PR review status` 工作流维护两个互斥的 review 标签：

- `review:needs-review`：PR 已经可以 review，等待维护者处理。
- `review:needs-changes`：维护者已经 Request changes，等待 PR 作者修改。

非 Draft PR 创建、重新打开、标记为 Ready for review 或再次申请 review 时，会进入
`review:needs-review`。收到 `Request changes` 后切换为 `review:needs-changes`。作者只 push
新提交不会自动切回等待 review；作者再次明确申请 review 后才会切回。多人 review 时，任一
仍有效且未被再次申请的 `Request changes` 都会保留；只有所有修改请求都被新的审查取代或
撤销后，Review 通过且没有其他待处理 reviewer 时，工作流才会清理 review 标签，由维护者
按仓库规则直接合入。

生命周期事件由 `pull_request_target` 处理；`pull_request_review` 先由无写权限的
observer 采集，再由 `workflow_run` 在受信任的工作流中同步标签，以兼容 fork PR 的只读
`GITHUB_TOKEN`。同步流程通过受信任的 workflow run 元数据、GitHub API 中的 PR 和 Review
记录校验事件；当 fork PR 的 `workflow_run.pull_requests` 为空时，run 的 head SHA、分支和
head repository 仍必须与 API 当前 PR 完全匹配，避免跨 PR artifact 被错误接受。状态同步会
读取 reviewer 的最新有效审查，避免多人 Review、普通 Comment 或延迟到达的旧事件覆盖较新的
重新申请 Review。同步工作流只 checkout PR 的
base SHA 中的可信脚本，不执行 PR 分支代码；它只拥有维护 review 标签所需的 Issue 写权限，
并保留其他标签不变。由于 GitHub 只从仓库默认分支触发 `workflow_run`，该工作流合入
`preview` 后还需要同步到默认分支 `main`，fork PR 的 review 状态流转才会完整生效。
