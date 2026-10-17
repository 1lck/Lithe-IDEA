# gh 模板提交规则

此文件是 `submit-lithe-issue` 的强制提交规则。必须同时满足“正文严格符合当前
模板”和“通过真实模板入口创建”，仅把正文写得像模板不算通过。

## 读取线上模板与 gh 能力

以下为默认仓库的只读命令；目标仓库变化时替换仓库身份。`gh api` 在本流程
仅用于只读查询，不用于创建 Issue。

```bash
gh --version
gh issue create --help
gh issue view 394 --repo 1lck/Lithe-IDEA --json title,body,url
gh api repos/1lck/Lithe-IDEA --jq '{full_name,default_branch,html_url}'
gh api repos/1lck/Lithe-IDEA/contents/.github/ISSUE_TEMPLATE --jq '.[] | {name,path,sha}'
gh api repos/1lck/Lithe-IDEA/contents/.github/ISSUE_TEMPLATE/config.yml --jq '.content | @base64d'
gh api repos/1lck/Lithe-IDEA/contents/.github/ISSUE_TEMPLATE/bug_report.yml --jq '.content | @base64d'
gh api repos/1lck/Lithe-IDEA/contents/.github/ISSUE_TEMPLATE/feature_request.yml --jq '.content | @base64d'
gh label list --repo 1lck/Lithe-IDEA --limit 200 --json name,description
```

Contents API 未指定 `ref` 时读取默认分支。先列目录，再读取本次实际选用的文件；
上面的文件名只是当前仓库示例，不能假定永远不变。记录本次使用的默认分支和
模板 blob SHA；若提交前模板变化，按新模板重新检查。报错或无法读取时先处理
访问问题，不能把失败当成“没有模板”。

查询当前 `gh --template` 所使用的原生模板列表：

```bash
gh api graphql -F owner=1lck -F name=Lithe-IDEA -f query='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { issueTemplates { name title body } } }'
```

API 返回模板的 `name` 才是原生 `--template` 的选择依据。仓库中存在 YAML
文件、网页有表单，均不代表 `gh --template` 已支持该表单。还要核对返回内容
是否与选定的线上模板相符，不能把另一个可用模板当成替代入口。

## 路径一：gh 原生支持选定模板

只有原生模板列表包含本次模板，并且当前 CLI 能保留该模板选择及字段结构，
才可使用模板流程。以下命令是占位示例，不可原样执行：

```bash
gh issue create --repo 1lck/Lithe-IDEA \
  --template '从原生模板列表读取的准确 name' \
  --title '[Bug] 触发条件下的具体异常'
```

在原生交互或编辑器中按已准备的字段内容填写，保留模板结构，审阅后提交。
标题前缀来自选定模板，功能建议不能照用 `[Bug]`。需要标签时仅使用已核实的
类型、平台、模块和优先级标签；模板来源标记必须由真实模板流程产生。

没有 TTY、编辑器或可操作的模板交互时，交付草稿及具体限制。不能为了无交互
执行而退回自由正文命令，也不能把 `yes`、空答案或脚本伪装成用户完成检查。

## 路径二：gh 不支持仓库当前表单

本 Skill 创建时实测（2026-10-17，`gh 2.102.0`）：

- 仓库使用 `bug_report.yml` 与 `feature_request.yml` 两种 YAML Issue Forms，
  `blank_issues_enabled: false`。
- GitHub GraphQL `repository.issueTemplates` 返回空列表，当前 `gh` 无法从中
  选择这两种表单。不能通过反复重试 `--template` 解决。
- `gh issue create` 明确禁止 `--template` 与 `--body` 或 `--body-file` 同时使用。
  删掉 `--template` 再传完整正文会绕过原生模板流程，即使章节看起来一致也禁止。

这些是当时的能力快照，后续任务必须重新检测，不能把它当成永久限制。

在不支持时，完成查重、追问、采集、脱敏和逐字段草稿后，交付选定模板的
GitHub 官方表单入口，由用户在该表单中填写并完成提交：

- [Bug report / 问题报告](https://github.com/1lck/Lithe-IDEA/issues/new?template=bug_report.yml)
- [Feature request / 功能建议](https://github.com/1lck/Lithe-IDEA/issues/new?template=feature_request.yml)

以实际仓库 `html_url` 和模板文件名生成链接，不依赖上面的固定示例。
直接给出链接即可，不要求启用浏览器自动化。必须明确“草稿已完成，尚未提交；
当前 gh 原生模板接口没有暴露此 YAML 表单，继续提交会绕过模板”。

`gh issue create --web` 只代表打开网页；不能把它说成已通过模板校验或已提交。
将来 CLI 能原生处理选定表单时，再走路径一。

## 任何情况下都禁止的绕过方式

- 不选模板，直接执行 `gh issue create --title ... --body ...` 或 `--body-file ...`。
- 把手工拼接的模板正文、转换后的 Markdown 或 stdin 当作已完成的表单提交。
  Markdown 草稿可供审阅和逐字段填写，不能用来替代模板入口。
- 使用 `gh api` POST/GraphQL mutation、`curl`、SDK 或其他客户端直接创建 Issue。
- 手工附加 `issue-form:bug`、`issue-form:feature` 或其他来源标记，以绕过机器人
  门禁。拥有管理员权限、机器人未关闭 Issue、模板标签存在，都不能证明合规。
- 把表单内容放进网页 `body=` 参数、丢失 `template=`、选择空白 Issue，或使用
  其他模板来逃避必填、选项和检查项校验。
- 修改模板、仓库配置或门禁；省略字段、伪造日志/附件、用占位符填必填项，或
  勾选未执行的检查项。

## 成功、部分失败与权限

只有服务器返回了真实 Issue，并通过回读核验，才报告已提交。模板流程结束后：

```bash
gh issue view 123 --repo 1lck/Lithe-IDEA --json number,title,body,labels,url,state
```

核对完整字段、检查项、标签及附件链接。如果原生流程未自动补齐分派标签，且
当前账号有权限，可对已经真实通过模板创建的 Issue 用 `gh issue edit --add-label`
补上平台、模块、优先级等普通标签；不得借此补造表单来源标记。没有标签权限时
列出建议标签和限制，不能宣称标签已添加。

当前 `gh --attach` 可能在部分附件上传失败时仍创建 Issue 并返回非零状态。
其他提交后操作也可能部分失败。先检查输出中的真实 URL，再按需要用
`gh issue list --author @me --state all` 等只读命令查验，不能直接重跑创建。
只修复已有授权范围内的遗漏，无法修复时如实交付现状和缺口。

在用户完成网页表单提交并提供链接后，同样可用只读 `gh issue view` 核验。
尚未获得服务器结果时，页面打开或草稿准备成功都不是创建成功。

## 能力判断依据

以下来源用于理解此次兼容性判断；实际执行仍以当前 CLI 和仓库结果为准：

- [gh issue create 手册](https://cli.github.com/manual/gh_issue_create)
- [gh v2.102.0 的 create 实现](https://github.com/cli/cli/blob/v2.102.0/pkg/cmd/issue/create/create.go)：
  `--template` 与自由正文互斥；原生模板提交携带 `issueTemplate`。
- [gh v2.102.0 的模板查询实现](https://github.com/cli/cli/blob/v2.102.0/pkg/cmd/pr/shared/templates.go)：
  Issue 模板选择来自 GraphQL `repository.issueTemplates`。
