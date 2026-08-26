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
