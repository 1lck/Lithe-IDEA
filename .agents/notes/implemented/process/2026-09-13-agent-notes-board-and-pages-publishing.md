# Agent 笔记：Agent Notes 看板与 GitHub Pages 发布

状态：已实现

## 问题

`.agents/notes/` 已经成为 Lithe 架构决策的唯一中文来源，但只依靠目录检索不利于快速查看决策演进、被引用的核心约束和被否方案。看板如果单独维护一份内容，就会再次产生文档过期和双份事实源的问题。

## 决策

工程决策看板是由 `.agents/notes/` 编译生成的只读视图，不保存任何独立的决策正文。Node 构建脚本使用与校验器共用的
[`scripts/agent-notes-parser.mjs`](../../../../scripts/agent-notes-parser.mjs)
解析中文 Note 标题、状态、章节和相对 Markdown 引用，生成包含完整正文的单文件 HTML。

看板模板保存在
[`assets/agent-notes-board.html`](../../../../assets/agent-notes-board.html)，本地开发模式使用浏览器的 File System Access API 读取项目目录并定时重新扫描；静态发布模式把当前 Note 数据内嵌到 HTML，不依赖后端、数据库或运行时服务。

GitHub Pages 只从 `preview` 分支发布。工作流在构建前运行
`./scripts/verify-agent-notes.sh`，校验通过后执行
`scripts/build-agent-notes-board.mjs --bundle`，将完整看板上传为 Pages artifact。生成的 `index.html` 不提交到仓库，Note 仍是唯一源文件。

## 考虑过的备选方案

- **直接把参考项目完整 clone 到 Lithe**：可以快速得到页面，但会同时引入上游英文 Note 格式、独立校验规则和另一套构建入口；中文 Note 会出现标题或章节解析不一致，因此只移植看板模板和交互。
- **将生成的 `index.html` 提交到仓库并手工维护**：打开页面方便，但提交后的页面可能落后于最新 Note，也会把生成物误当成第二份文档；因此改为 Pages 构建时生成。
- **为看板增加后端 API 或数据库**：可以提供服务端搜索和推送，但当前数据量和只读需求不需要运行时基础设施；静态 HTML 更容易审查、部署和离线保存。

## 后果

- 新增或修改 Note 后，构建即可得到最新看板，搜索、时间线、分类、引用入度和详情抽屉都由当前内容计算。
- 校验器和看板共享解析模块，中文格式变化只需要更新一个解析边界。
- 本地开发可以直接授权项目目录查看变更，GitHub Pages 可以公开展示完整决策正文。
- 代价是公开看板会携带全部 Note 正文，后续若仓库可见性或内容敏感度变化，需要启用构建脚本的 `--metadata-only` 模式或调整发布权限。
- Pages 当前跟随 `preview` 分支；切换稳定发布分支时必须同步修改工作流触发条件和发布说明。

## 验证

- `./scripts/verify-agent-notes.sh`
- `node scripts/build-agent-notes-board.mjs --bundle .agents/notes .artifacts/agent-notes-board/index.html "Lithe 工程决策看板"`
- `git diff --check`

## 适用范围

- `assets/agent-notes-board.html`
- `scripts/agent-notes-parser.mjs`
- `scripts/build-agent-notes-board.mjs`
- `scripts/verify-agent-notes.mjs`
- `.agents/skills/agent-notes/SKILL.md`
- `.github/workflows/deploy-agent-notes-board.yml`
- `.agents/notes/`
