# Agent 笔记：非维护者必须通过 Issue 表单提交

状态：已实现

## 先说结论

`blank_issues_enabled: false` 只隐藏网页上的空白 Issue 入口，挡不住 API、`gh issue create` 和第三方客户端。每个 Issue 表单都带一个 `issue-form:*` 标签。自托管的 `lithe-bot-console`（`lithe-code-review` GitHub App）在 Issue 新建或重新打开时检查：仓库 owner 和协作者（任意权限）直接放行；其他作者的 Issue 既没有表单标签、正文也不含某个表单的全部必填字段时，收到中英双语说明并以 not planned 关闭。拿不准的情况一律保留，并由每日补查重试。

2026-10-16 起这套检查、按表单内容打标签和 Issue 认领都由 Bot 处理，仓库里不再有 Issue 相关的 GitHub Actions workflow。

## 问题

#988 是一个正文为空、没有经过表单的 Issue。只检查正文是否为空不够：通过 API 随便写一句话，同样绕过了表单，表单里的平台、模块、优先级等字段都缺失，也无法自动分类。

需要一个普通用户无法伪造、只有表单才会产生的信号。

## 决策

### 用表单标签作为来源证明

Issue 表单（`.github/ISSUE_TEMPLATE/*.yml` 定义的结构化模板）顶层的 `labels:` 会在提交时自动加到 Issue 上，与提交者权限无关。REST API 创建 Issue 时，没有 push 权限的用户传入的 labels 会被 GitHub 静默丢弃；网页 URL 里的 `labels=` 参数同样要求打标签权限。所以普通用户只有通过表单才能得到 `issue-form:*` 标签。

### 标签缺失时按必填字段识别

只认标签的判定在 2026-10 实际失效过：`issue-form:bug` 标签有一段时间不存在，GitHub 会静默丢弃表单里不存在的标签，旧判定在“标签缺失”时放行，于是那段时间提交的 Issue 都没有被检查（例如 #1079、#1137）。另一次是 GitHub Actions 在账号解封期间没有正常执行，#1160 这个空白 Issue 留了下来。

因此现在用“有 `issue-form:*` 标签，或者正文包含某个表单全部必填字段的 `### 字段名`”判定为使用了表单。旧方案曾以“可以照抄结构伪造”否决按正文结构识别，这次改变取舍的理由是：门禁要保证的是维护者拿到表单要求的信息，照抄全部必填字段并填写的人已经提供了这些信息；而只认标签的方案一旦标签缺失就整体失效。必填字段清单集中在 `lithe-bot-console` 的 `src/issue-triage/rules.mjs`（`FORMS`），与本仓库模板同步维护。

### 谁可以不用表单

仓库 owner 和协作者（`GET /repos/{owner}/{repo}/collaborators/{username}` 返回 204，任意权限级别）可以直接提交 Issue。之前只放行 write 以上权限，维护者明确要求所有协作者都可以不用表单。不要用 `author_association` 判断：`OWNER` 可以直接放行，其余取值不等于协作者身份。

### 判定顺序

`gateDecision` 返回 `allow`、`close` 或 `skip`，只有 `close` 会评论并关闭：

1. 不是开放状态的 Issue、Pull Request、缺少作者信息：`skip`。
2. 作者是 Bot：`allow`。只有维护者安装的 App 或 workflow 才能以 Bot 身份建 Issue。
3. 作者是 owner：`allow`。
4. Issue 创建于 2026-10-01（规则生效）之前：`allow`，规则不追溯。
5. 触发者不是作者（维护者转移或重新打开 Issue）：`skip`。作者自己重新打开会再次检查。
6. 查询协作者身份失败：`skip`。
7. 作者是协作者：`allow`。
8. 使用了表单（标签或必填字段）：`allow`。
9. 其余情况：先评论（带 `<!-- lithe-issue-form-gate -->`，不重复评论），再以 `not_planned` 关闭。关闭前重新读取一次 Issue 并重新判定，避免 GitHub 刚补上表单标签或维护者刚处理过。

### 每日补查

Bot 每天一次检查规则生效后提交、仍然打开的 Issue，关闭漏掉的空白 Issue。被非作者（维护者）重新打开过的 Issue 视为维护者的决定，不再关闭。这一步覆盖 Bot 离线、webhook 丢失或 GitHub 出错的时间段，弥补“拿不准就保留”带来的漏关。

### 按表单内容打标签

新建或编辑 Issue 时，按表单里选的优先级、平台、模块和标题前缀增删 `P*`、`platform:*`、`area:*`、`bug`、`enhancement`。只改这些托管标签，不用 `setLabels` 整体替换，否则会抹掉 GitHub 稍后补上的 `issue-form:*` 等标签。

### 模型分诊（仅供参考）

外部提交者（非 owner、非协作者）的 Issue 在新建时调用一次模型：判断信息是否足够，不足时加 `needs-info` 并评论缺少的内容（作者编辑补充后重新判断并移除标签）；表单没选模块或选了“其他”时给出模块建议；在已打开的 Issue 里找可能的重复。模型复用 PR 审查的 API 地址和密钥，但用单独配置的模型和低思考强度（默认 `gpt-6.1-sol`、`low`），这是轻量判断任务，不需要旗舰模型的高思考强度。

Issue 内容是不可信输入。模型只能按固定 schema 输出，Bot 按白名单校验字段（模块必须是已有 `area:*`，重复 Issue 必须在候选列表里），评论内容去掉链接、@ 提及和 HTML；模型不能关闭 Issue、不能调用 GitHub 接口。关闭只由上面的确定性规则决定。模型调用失败时只跳过分诊。

### 正确做法

- 新增表单：模板 `labels:` 加 `issue-form:<类型>`，在仓库创建同名标签，并在 `lithe-bot-console` 的 `FORMS` 里登记标签、模板文件名和必填字段标题。修改必填字段的标题时同步更新 `FORMS`。
- 误关时：由维护者重新打开 Issue，Bot 不会再关闭它。

### 不要这样做

- 不要改成只检查正文是否为空，API 写一句话就能绕过。
- 不要用 `author_association` 判断协作者身份。
- 不要在标签缺失时直接放行全部 Issue，那正是 2026-10 的漏洞来源。
- 不要让模型的输出决定关闭 Issue，或把模型输出原样贴进评论。

## 考虑过的备选方案

### 只拦截空正文

实现最简单，但 API 或 CLI 写任意一句话即可绕过，而这类 Issue 同样缺少表单字段，所以没有采用。

### 只认表单标签

信号无法伪造，但标签缺失或被归档时只能整体放行，2026-10 已经因此失效一次。现在改为标签和必填字段二选一。

### 仓库级只允许协作者创建 Issue

服务端彻底限制，但普通用户将完全无法反馈问题，违背开放反馈的目标，所以没有采用。

### 继续用 GitHub Actions

`issues` 事件只在 Issue 新建、编辑时触发，次数不多；但认领命令所依赖的 `issue_comment` 无法在触发阶段区分 Issue 和 PR，每条 PR 评论都会空跑一次。仓库曾因 Actions 用量过高被判定滥用，所有 Issue 自动化因此统一迁到已经在运行的自托管 Bot，规则集中在一处维护。

## 后果

- 收益：非维护者无论从哪个入口提交，都会留下表单字段，自动分类可以生效；被关闭的作者能看到双语说明和正确入口；仓库不再为 Issue 自动化消耗 Actions。
- 代价：Issue 自动化依赖 VPS 上的 Bot。Bot 离线时新 Issue 不会被打标签或检查，恢复后由每日补查关闭漏掉的空白 Issue；标签需要作者编辑或维护者手动补上。
- 代价：GitHub App 必须订阅 `issues` 和 `issue_comment` 事件，并有 `issues: write` 权限。
- 重新评估触发条件：GitHub 提供原生的“必须使用表单”设置；新增或改名表单、修改必填字段；评论或关闭策略改变；模型分诊的误判明显影响提交者体验。

## 验证

逻辑和测试都在 `lithe-bot-console`：

```bash
npm test   # 在 lithe-bot-console 仓库中运行
./scripts/verify-agent-notes.sh
```

`test/issue-triage.test.mjs` 覆盖：标签或必填字段识别表单、空白 Issue 被评论并关闭、协作者和 owner 放行、维护者重新打开不再关闭、规则生效前的 Issue 不追溯、权限未知时保留、托管标签增删、模型输出的白名单校验和内容清理、`needs-info` 的添加与移除、模型失败时只跳过分诊、每日补查。全部使用内存中的 GitHub 和模型替身，不访问网络。

## 适用范围

- `.github/ISSUE_TEMPLATE/bug_report.yml`
- `.github/ISSUE_TEMPLATE/feature_request.yml`
- `.github/ISSUE_TEMPLATE/config.yml`
