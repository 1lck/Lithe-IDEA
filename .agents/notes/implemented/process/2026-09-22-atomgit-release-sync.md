# Agent 笔记：正式 Release 的 AtomGit 镜像

状态：已实现

## 先说结论

GitHub 继续拥有正式发布内容，AtomGit 提供相同附件的镜像。两个平台上传完成后分别调用共享同步工作流；失败可以单独重试，不重新构建安装包。启用需要配置令牌，代码和 Tag 镜像仍由独立流程负责。

## 问题

macOS 和 Windows 分别构建，并先后向同一个 Release 上传附件。如果只在 Release 创建时复制一次，另一平台的安装包可能还没出现。GitHub 内置工作流令牌产生的发布事件也不能可靠地作为另一个工作流的自动触发来源。

## 决策

两个发布工作流直接调用可复用工作流，按 Tag 串行执行。每次读取 GitHub 当前的完整附件列表，用 SHA-256（文件内容的摘要）判断已有文件是否需要替换。正确做法是 Windows 完成后再次读取附件并补齐；不要看到同名附件就假定内容没有改变。

发布前核对两站同名 Tag 的最终提交，包括带注释 Tag 指向的提交。缺失或不一致时拒绝同步，不使用 AtomGit 默认分支自动创建版本。预发布和草稿被拒绝；补历史版本不主动设置最新状态。

令牌只来自工作流 Secret，不写入文件或请求日志。附件流式传输到临时目录，每个附件处理完成或失败后都清理；请求、传输和远程 Git 操作都有截止时间。不修改正文下载链接或签名更新清单，避免引入第二套客户端更新来源。

## 考虑过的备选方案

- 仅监听 Release 创建事件：配置少，但可能缺少后上传的另一平台附件，也受内置令牌事件触发限制。
- 在两个平台各实现一份同步：容易出现状态、附件替换和凭据处理差异，因此共用同一工作流和脚本。
- 在同步时直接创建缺失 Tag：可能把版本指向默认分支的错误提交，因此要求代码镜像先完成。
- 只按文件名跳过：重跑构建会替换同名文件，必须比较内容。

## 后果

镜像失败不会撤回 GitHub Release，维护者可以用 Tag 单独重试。代价是比较附件需要额外下载，首次上传后还会回读校验；替换附件的删除与上传无法原子完成，中途失败需要重试。AtomGit 对历史版本省略状态字段的默认行为、真实上传权限与下载 URL 可访问性，仍需带令牌的首次联调确认。

## 验证

```bash
node --test scripts/test-sync-atomgit-release.mjs
actionlint .github/workflows/sync-atomgit-release.yml .github/workflows/release-macos.yml .github/workflows/release-windows.yml
./scripts/verify-agent-notes.sh
```

测试使用离线替身验证顺序、重试、失败清理、提交不一致、分页和 401 不被当作不存在，不依赖真实网络或生产凭据。

## 适用范围

- `.github/workflows/sync-atomgit-release.yml`
- `.github/workflows/release-macos.yml`
- `.github/workflows/release-windows.yml`
- `scripts/sync-atomgit-release.mjs`
- `scripts/test-sync-atomgit-release.mjs`
- `docs/releases/atomgit-sync.md`
