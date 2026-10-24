# gh 模板提交规则

此文件是 `submit-lithe-issue` 的强制提交规则。无论走哪条路径，提交的正文都必须
严格符合当前模板：字段标题、顺序、下拉选项和检查项与线上表单一致，必填字段
真实填写。gh 能原生选择模板时走路径一，不能时走路径二。

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

没有 TTY、编辑器或可操作的模板交互时，按路径二的正文格式生成完整正文后用
`--body-file` 提交；不能退回不符合模板的自由正文，也不能把 `yes`、空答案或脚本
伪装成用户完成检查。

## 路径二：gh 不支持仓库当前表单，按表单字段提交正文

GitHub GraphQL `repository.issueTemplates` 只返回 Markdown 模板（`.md`），不返回
YAML Issue Forms（`.yml`/`.yaml`）。`gh` 的 `--template` 依赖这个接口，所以仓库只有
YAML 表单时，`gh` 列不出任何模板，反复重试 `--template` 也没有用。这是 gh 的已知
限制（[cli/cli#5865](https://github.com/cli/cli/issues/5865)，自 2022-06 未解决；
[cli/cli#11681](https://github.com/cli/cli/issues/11681) 维护者确认只支持 Markdown
模板），不是仓库配置错误。2026-10-24 对比 facebook/react、rust-lang/rust、golang/go
时规律一致：同目录下的 `.md` 被返回，`.yml`/`.yaml` 全部缺席。

仓库的 Issue 门禁（见 `.agents/notes/implemented/process/2026-10-01-issue-form-enforcement.md`）
接受两种表单证明：`issue-form:*` 标签，或正文包含某个表单全部必填字段的
`### 字段名`。按表单逐字段生成正文，维护者拿到的信息与网页表单相同，Bot 也会
按正文里的优先级、平台、模块和标题前缀自动打分派标签。因此原生模板不可用时，
用 `gh issue create --body-file` 提交按表单生成的正文。

### 正文格式

完全模仿 GitHub 渲染表单提交结果的格式，按选定模板 `body` 中输入字段的顺序生成：

- 每个 `input`、`textarea`、`dropdown`、`checkboxes` 字段对应一段
  `### <attributes.label>`，标题逐字复制线上模板，包括中英双语和斜杠、空格。
  `markdown` 类型的静态说明不写入正文。
- `dropdown` 只写一个模板 `options` 中逐字存在的选项；多选下拉用逗号分隔。
- `checkboxes` 逐条保留原文，写成 `- [x] <label>` 或 `- [ ] <label>`，只勾选
  真实完成的事项；必选项未完成时不能提交。
- `textarea` 带 `render` 时把内容放进对应语言的代码块。
- 必填字段必须有实质内容；可选字段缺失时按 SKILL 第 5 节写明原因，不删除标题。
- 标题使用模板 `title` 的前缀，例如 `[Bug] ` 或 `[Feature] `。

正文先写到工作区之外或 `.artifacts/` 下被 git 忽略的临时文件，提交前做第二轮
脱敏复查，再逐项对照模板 YAML 检查字段标题与选项：

```bash
gh issue create --repo 1lck/Lithe-IDEA \
  --title '[Bug] 触发条件下的具体异常' \
  --body-file .artifacts/issue-drafts/<草稿文件>.md
```

以上命令是占位示例，标题和文件路径替换成本次实际内容。不要用 `--label` 添加
`issue-form:*`；`P*`、`platform:*`、`area:*`、`bug`、`enhancement` 由 Bot 按正文
自动维护，提交后回读确认，Bot 未处理且当前账号有权限时再按下文补普通标签。

### 何时改用网页表单

以下情况交付脱敏正文和选定模板的官方表单链接，由用户在网页提交，并明确
“尚未提交”：

- 当前 `gh` 没有登录态、没有创建 Issue 权限或网络受限。
- 用户明确要求走网页表单，或需要上传 gh 无法处理的附件。

链接以仓库 `html_url` 和模板文件名生成，例如
`https://github.com/1lck/Lithe-IDEA/issues/new?template=bug_report.yml`。
`gh issue create --web` 只代表打开网页，不能说成已提交。

将来 `gh` 能原生选择 YAML 表单时，优先走路径一。

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
