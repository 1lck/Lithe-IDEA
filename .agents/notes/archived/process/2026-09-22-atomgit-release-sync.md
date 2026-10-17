# Agent 笔记：正式 Release 的 AtomGit 镜像

状态：已实现
归档日期：2026-10-17

## 归档原因

2026-10-17 起停用 AtomGit Release 同步，删除了同步工作流、脚本、测试和配置文档，正式发布不再向 AtomGit 上传任何内容。AtomGit 上的代码镜像由 AtomGit 自己从 GitHub 拉取，不受影响。

停用前的最后一次验证（#1303 合并后手动同步 v0.6.1）：

- Tag 核对和 Release 创建都正常；
- 但从 GitHub 托管 runner 上传 336 MB 的 dmg，4 次都在 5 分钟时超时；同一个文件在国内的 Mac mini 上 55 秒就能传完（6.1 MB/s）。

改到自托管机器上跑，会把 `ATOMGIT_TOKEN` 放到会执行外部 fork PR 代码的常驻机器上，或者放到网络不稳定、还跑着其他服务的服务器上，安全隔离和维护成本都不划算。因此决定先停用，等 AtomGit 改善海外上传后再评估。

恢复时，从 #805 和 #1303 的提交中找回 `.github/workflows/sync-atomgit-release.yml`、`scripts/sync-atomgit-release.mjs`、`scripts/test-sync-atomgit-release.mjs` 和 `docs/releases/atomgit-sync.md`，重新在两个发布工作流末尾加上 `sync-atomgit` 任务，并先确认 GitHub 托管 runner 到 AtomGit 的上传速度。下文是停用前的决策记录，“适用范围”中的路径已不存在。

## 先说结论

GitHub 继续拥有正式发布内容，AtomGit 只镜像用户手动下载的安装包（两个 dmg、Windows exe 及其 `.sha256`）。两个平台上传完成后分别调用共享同步工作流；AtomGit 还没拉到 Tag 时，同步会把 GitHub 上同一个 Tag 原样推过去。大文件上传中断会自动重试几次，仍失败时可以单独重跑，不重新构建安装包。

## 问题

macOS 和 Windows 分别构建，并先后向同一个 Release 上传附件。如果只在 Release 创建时复制一次，另一平台的安装包可能还没出现。GitHub 内置工作流令牌产生的发布事件也不能可靠地作为另一个工作流的自动触发来源。

上线后（v0.5.2～v0.6.1）实际执行的 34 次同步全部失败，原因有两类：

- 29 次报 `Tag missing`。AtomGit 的代码镜像按自己的节奏拉取 Tag，发布刚完成时还没有这个 Tag，同步直接退出且不会自动重来。
- Tag 已存在的 5 次里，几 KB 的 xml/json 都能传上去，但约 300 MB 的安装包经常传到一半被断开（HTTP 502），或拖到 15 分钟超时。同样大小的 dmg 也有过 77 秒传完的情况，说明是跨境上传不稳定，不是文件被拒。

另外，AtomGit 有一个 Release 附件总量约 2 GB 的说法（官方文档未找到原文）。当时每个版本全部附件约 1.8 GB，余量很小。

## 决策

两个发布工作流直接调用可复用工作流，按 Tag 串行执行。每次读取 GitHub 当前的完整附件列表并按下文白名单过滤，用 SHA-256（文件内容的摘要）判断已有文件是否需要替换。正确做法是 Windows 完成后再次读取附件并补齐；不要看到同名附件就假定内容没有改变。

发布前核对两站同名 Tag 的最终提交，包括带注释 Tag 指向的提交。AtomGit 缺这个 Tag 时，用 `git push`（不带 `--force`）把本地检出的同名 Tag 推过去：推送前确认本地 Tag 指向 GitHub 上的同一提交，推送后重新读取远端再比对。AtomGit 上已有指向其他提交的同名 Tag 时，推送会被拒绝，同步停止；不要为了让同步通过而改成强制推送。HTTPS 推送除了令牌还要用户名：默认用同一个令牌调用 AtomGit `GET /api/v5/user` 取 `login`，不新增必填配置；仓库变量 `ATOMGIT_USER` 只作为覆盖项。Release API 本身只用令牌，这是之前不需要用户名的原因。预发布和草稿被拒绝；补历史版本不主动设置最新状态。

只同步 `Lithe-<版本>-{arm64,x86_64}.dmg`、`Lithe-<版本>-windows-x64.exe` 和它们的 `.sha256`。Sparkle 的 zip/delta/appcast、Windows 更新器和签名、`latest*.json`、插件包都不镜像：应用内更新始终走 GitHub，这些文件放到 AtomGit 上没人用，却占一半体积和上传时间。新增面向用户的安装包时，要同时更新 `mirroredAsset` 白名单和测试。

每个附件单独重试：AtomGit 侧传输超时 5 分钟，只有 5xx、超时、上传后不可见、回读摘要不一致这几类临时错误才重试，最多 4 次，间隔 30/60/120 秒。每次重试前重新读取 AtomGit 上的附件列表，上一轮其实已经传成功的文件会按摘要跳过，不会重复上传。4xx（如令牌无权限）和数据不一致直接失败，不重试。

令牌只来自工作流 Secret，不写入文件或请求日志。附件流式传输到临时目录，每个附件处理完成或失败后都清理；请求、传输和远程 Git 操作都有截止时间。不修改正文下载链接或签名更新清单，避免引入第二套客户端更新来源。

## 考虑过的备选方案

- 仅监听 Release 创建事件：配置少，但可能缺少后上传的另一平台附件，也受内置令牌事件触发限制。
- 在两个平台各实现一份同步：容易出现状态、附件替换和凭据处理差异，因此共用同一工作流和脚本。
- 通过 AtomGit API 在同步时创建缺失 Tag：可能把版本指向默认分支的错误提交，因此不用。改为 `git push` GitHub 上的同一个 Tag 对象，Tag 只能指向 GitHub 上的那个提交。
- 等待镜像拉取 Tag 后再同步：镜像间隔不受我们控制。v0.6.1 的 Tag 推到 GitHub 一个半小时后，AtomGit 仍未拉到，轮询只会拖长任务。
- 直接使用 `jiacai2050/atomgit-action`：它也会先推 Tag，但用的是 `--force`，会覆盖不一致的 Tag；它不比对已有附件，macOS 和 Windows 两次触发会重复上传；它不更新已存在 Release 的说明，也不过滤附件。这里只借鉴了“先推 Tag”这一点。
- 只按文件名跳过：重跑构建会替换同名文件，必须比较内容。

## 后果

镜像失败不会撤回 GitHub Release，维护者可以用 Tag 单独重试。代价是比较附件需要额外下载，首次上传后还会回读校验；替换附件的删除与上传无法原子完成，中途失败需要重试。同步任务要完整检出仓库历史才能推送 Tag，检出会比浅克隆慢。重试会拉长失败时的耗时，最坏情况三个大文件约 70 分钟，仍在 120 分钟任务上限内。早期部分成功的 Release 上残留的 xml/json 等附件不会被清理。AtomGit 对历史版本省略状态字段的默认行为、真实上传权限与下载 URL 可访问性，仍需带令牌的首次联调确认。

## 验证

```bash
node --test scripts/test-sync-atomgit-release.mjs
actionlint .github/workflows/sync-atomgit-release.yml .github/workflows/release-macos.yml .github/workflows/release-windows.yml
./scripts/verify-agent-notes.sh
```

测试使用离线替身验证顺序、重试、失败清理、提交不一致、分页和 401 不被当作不存在，不依赖真实网络或生产凭据。Tag 推送用本地 bare 仓库跑真实的 `git push`，覆盖正常推送、本地 Tag 不符和远端 Tag 不一致被拒三种情况。附件白名单、重试次数与间隔、重试前重新读取目标状态都有独立用例。

## 适用范围

- `.github/workflows/sync-atomgit-release.yml`
- `.github/workflows/release-macos.yml`
- `.github/workflows/release-windows.yml`
- `scripts/sync-atomgit-release.mjs`
- `scripts/test-sync-atomgit-release.mjs`
- `docs/releases/atomgit-sync.md`
