# Agent 笔记：非维护者必须通过 Issue 表单提交

状态：已实现

## 先说结论

`blank_issues_enabled: false` 只隐藏网页上的空白 Issue 入口，挡不住 API、`gh issue create` 和第三方客户端。现在每个 Issue 表单都带一个 `issue-form:*` 标签，`.github/workflows/lithe-issue-form-gate.yml` 在 Issue 创建或重新打开时检查：对仓库有 write、maintain 或 admin 权限的作者直接放行；其他作者没有这类标签就收到中英双语说明，Issue 被关闭。任何拿不准的情况都保留 Issue，宁可漏关，不误关。

## 问题

#988 是一个正文为空、没有经过表单的 Issue。只检查正文是否为空不够：通过 API 随便写一句话，同样绕过了表单，表单里的平台、模块、优先级等字段都缺失，`lithe-issue-priority.yml` 也无法自动分类。

需要一个普通用户无法伪造、只有表单才会产生的信号。

## 决策

### 用表单标签作为来源证明

Issue 表单（Issue Form，`.github/ISSUE_TEMPLATE/*.yml` 定义的结构化模板）顶层的 `labels:` 会在提交时自动加到 Issue 上，与提交者权限无关。REST API 创建 Issue 时，没有 push 权限的用户传入的 labels 会被 GitHub 静默丢弃；网页 URL 里的 `labels=` 参数同样要求打标签权限。所以普通用户只有通过表单才能得到 `issue-form:*` 标签。

允许的标签和对应模板集中在 `.github/lithe-issue-form/logic.mjs` 的 `ISSUE_FORMS`。新增表单时，在表单的 `labels:` 加一个 `issue-form:<类型>`，同时把它加入 `ISSUE_FORMS`，并在仓库里创建同名标签。不要只改其中一处；测试会检查每个登记的模板都声明了自己的标签。

### 判定顺序

`decideIssueFormGate` 返回 `allow`、`close` 或 `skip`，工作流只在 `close` 时评论并关闭：

1. 不是开放状态的 Issue、Pull Request、缺少作者信息：`skip`。
2. 作者是 Bot：`allow`。只有维护者安装的 App 或工作流才能以 Bot 身份建 Issue。
3. 触发者不是作者（例如维护者转移或重新打开 Issue）：`skip`。
4. 读取作者权限失败：`skip`。
5. 作者权限是 write、maintain、admin（`role_name` 或旧 `permission` 字段任一命中，后者覆盖自定义角色）：`allow`。
6. Issue 带任一允许的 `issue-form:*` 标签：`allow`。
7. 仓库里缺少任一允许的标签，或任一标签已归档：`skip`。表单无法应用不存在或已归档的标签，此时无法区分“来自表单”和“绕过表单”。
8. 其余情况：`close`，`state_reason` 为 `not_planned`。

权限以 `GET /repos/{owner}/{repo}/collaborators/{username}/permission` 为准，不以 `author_association` 为准：`COLLABORATOR` 可能只有 read 或 triage，`MEMBER` 也不代表对本仓库有写权限。工作流级 `if` 只跳过 `OWNER`、Bot 和 Pull Request，省掉一次 runner 启动，其余作者都由脚本查询真实权限。

### 标签时序

表单标签不一定和 Issue 同一时刻写入：#987 的 `bug` 标签比创建时间晚约 1 秒，事件记录的操作者是作者本人。所以工作流合并事件里的标签和重新读取的标签，并在真正关闭前再读一次 Issue、重新判定；只要此时出现表单标签，或 Issue 已被关闭，就不再处理。

### 评论与幂等

关闭前的评论带隐藏标记 `<!-- lithe-issue-form-gate -->`，重跑工作流时如果已经有机器人发的同标记评论就不再重复评论。评论只引用作者 login 和固定的模板链接，不回显 Issue 标题或正文，避免把用户输入带进机器人内容。脚本通过 `actions/github-script` 的 API 客户端读取事件数据，不把标题或正文插入 shell 或 `${{ }}` 表达式，因此不存在脚本注入面。

### 和现有 Issue 自动化的关系

- `lithe-issue-priority.yml` 在 `opened` 和 `edited` 时只增删自己管理的 `bug`、`enhancement`、`P*`、`platform:*`、`area:*`，`issue-form:*` 会被保留。它和本工作流并行运行；禁止用旧快照执行 `setLabels` 整体替换，否则会抹掉读取后 GitHub 才补上的来源标签。使用 `addLabels` 和 `removeLabel`，让非托管标签始终保留。
- `lithe-issue-claim.yml` 只处理评论事件，被关闭的 Issue 仍可由维护者重新打开后认领。
- 维护者手动创建的 Issue 不需要 `issue-form:*` 标签。

### 正确做法

- 新增表单：模板 `labels:` 加 `issue-form:<类型>`，`ISSUE_FORMS` 登记，先在仓库创建标签再合并。
- 误关时：由维护者重新打开 Issue，触发者与作者不同会跳过门禁。作者自己重新打开会再次检查，不能通过“立即关闭 → 等待门禁跳过 → 重新打开”绕过。

### 不要这样做

- 不要改成只检查正文是否为空，API 写一句话就能绕过。
- 不要用 `author_association` 判断维护者，它不等于仓库写权限。
- 不要在 `run:` 步骤里用 `${{ github.event.issue.title }}` 或正文拼 shell 命令。
- 不要在缺少或归档标签时“先关再说”，那会关闭所有正常的表单 Issue。

## 考虑过的备选方案

### 只拦截空正文

实现最简单，也能处理 #988。但 API 或 CLI 写任意一句话即可绕过，而这类 Issue 同样缺少表单字段，所以没有采用。

### 按正文里的表单标题结构识别

表单正文有固定的 `### 字段名` 结构，不需要额外标签。但普通用户可以照抄这种 Markdown 结构伪造，字段文案调整时还要同步修改判定，所以没有采用。

### 仓库级只允许协作者创建 Issue

服务端彻底限制，但普通用户将完全无法反馈问题，违背开放反馈的目标，所以没有采用。

### 缺少标签时由工作流自动创建

能让门禁“自己修好”，但工作流会因此需要隐式改仓库配置，也会在标签被维护者有意删除后悄悄恢复，所以改为缺少时放行并在日志里警告。

## 后果

- 收益：非维护者无论从哪个入口提交，都会留下完整表单字段，自动分类可以生效；被关闭的作者能看到双语说明和正确入口。
- 代价：每个非 OWNER 作者的新 Issue 都会启动一次短时 runner（作业超时 5 分钟）。普通用户从其他仓库转移进来的 Issue、维护者手动删掉 `issue-form:*` 标签的 Issue 不受门禁约束。
- 代价：如果 GitHub 改变“非 push 用户的 labels 静默丢弃”的行为，或允许 read 角色通过 URL 参数打标签，这个信号就能被伪造，需要重新评估。
- 重新评估触发条件：GitHub 提供原生的“必须使用表单”设置；新增表单或改名模板文件；评论或关闭策略改变。

## 验证

```bash
node --test --test-timeout=10000 scripts/test-lithe-issue-*.mjs
actionlint .github/workflows/lithe-issue-form-gate.yml .github/workflows/lithe-issue-priority.yml .github/workflows/verify-issue-automation.yml
./scripts/verify-agent-notes.sh
```

测试覆盖 Bug、Feature 表单放行，空白 Issue 和带正文但无表单标签的 Issue 被关闭，write、maintain、admin 与自定义角色放行，以及权限未知、标签缺失、转移等不确定情况不关闭。工作流编排测试执行实际的 github-script 脚本，以模拟 API 控制“分类读取 → GitHub 补标签 → 分类写入 → 门禁检查”的顺序，同时覆盖作者重新打开、维护者重新打开、标签归档及权限读取失败。所有测试均不访问网络、不依赖真实延时。`verify-issue-automation.yml` 在相关 PR 和 main/preview 推送时执行这些测试。

## 适用范围

- `.github/workflows/lithe-issue-form-gate.yml`
- `.github/lithe-issue-form/logic.mjs`
- `.github/ISSUE_TEMPLATE/bug_report.yml`
- `.github/ISSUE_TEMPLATE/feature_request.yml`
- `scripts/test-lithe-issue-form-gate.mjs`

- `scripts/test-lithe-issue-workflows.mjs`
- `.github/workflows/verify-issue-automation.yml`
- `.github/workflows/lithe-issue-priority.yml`
