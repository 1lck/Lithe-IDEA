# 配置 AtomGit Release 同步

正式版在 GitHub 上传完成后，会同步到 [AtomGit 的 Lithe 仓库](https://atomgit.com/lithe_IDEA/Lithe-IDEA)。macOS 和 Windows 分别触发同步，第二次会补齐另一平台的附件。Preview 发布不参与。

只同步用户手动下载的安装包：`Lithe-<版本>-arm64.dmg`、`Lithe-<版本>-x86_64.dmg`、`Lithe-<版本>-windows-x64.exe` 和它们的 `.sha256`。Sparkle 更新包（zip、delta、appcast）、Windows 更新器及签名、`latest*.json` 和插件包不同步，应用内更新继续使用 GitHub。

## 启用同步

1. 在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 添加 Secret `ATOMGIT_TOKEN`，值为有目标仓库 Release 写入和代码推送权限的 AtomGit 令牌。AtomGit 镜像还没拉到 Tag 时，同步会用这个令牌把 GitHub 上的同一个 Tag 推过去；推送用的用户名通过令牌自动查询，一般不用另外配置。
2. 默认目标已经配置为 `lithe_IDEA/Lithe-IDEA`。只有更换目标时，才需要添加 Variables `ATOMGIT_OWNER` 和 `ATOMGIT_REPO`。只有自动查询出的用户名无法推送时，才需要添加 Variable `ATOMGIT_USER` 指定推送用户名。
3. 将同步工作流和两个发布工作流的改动合入发布所使用的分支。手动入口需要工作流先存在于 GitHub 默认分支。

没有配置令牌时，Tag 触发的正式发布会提示并跳过同步。手动发布或手动同步时缺少令牌会报错，提醒完成配置。同步失败不会撤回已发布的 GitHub Release，Homebrew 更新也不依赖同步结果。

## 补同步或重试

在 GitHub Actions 选择 **Sync AtomGit Release → Run workflow**，填写已发布的正式 Tag，例如 `v0.4.10`。无需重新构建安装包。

同步会核对两边同名 Tag 指向的提交。Tag 缺失时自动推送（不强制覆盖）；推送失败时检查令牌的推送权限、目标仓库是否允许推送，必要时用 `ATOMGIT_USER` 指定用户名。提示提交不同时，说明 AtomGit 上已有指向其他提交的同名 Tag，需要人工确认后处理，脚本不会覆盖。API 返回 401/403 时检查令牌及仓库权限。

单个附件遇到 5xx、超时或上传后校验不一致时，会间隔 30、60、120 秒重试，最多 4 次。仍然失败时可以重新运行，已经传好的附件会按 SHA-256 跳过。

同步读取 GitHub 上实际发布的标题、双语说明和全部附件。已有同名附件会比较 SHA-256；内容相同则跳过，不同则先下载验证新文件，再删除旧附件并上传。删除与上传不是原子操作，中间失败可能暂时缺少该附件，重试可补回。只处理 GitHub 当前存在的同名附件，不清理 AtomGit 上其他附件。

最新正式版会明确请求 AtomGit 的 `latest` 状态。补历史版本时省略该字段，不主动请求设为最新；AtomGit 对省略状态的默认行为仍需首次联调确认。正文中的 GitHub 下载链接和更新清单保持原样，附件镜像不会自动切换应用内更新源。

## 验证修改

```bash
node --test scripts/test-sync-atomgit-release.mjs
actionlint .github/workflows/sync-atomgit-release.yml .github/workflows/release-macos.yml .github/workflows/release-windows.yml
```

离线测试覆盖创建、更新、附件替换和跳过、失败清理、Tag 校验与推送、附件白名单、重试、分页与权限失败。真实附件上传、服务端状态默认值与令牌权限需要配置 Secret 后用一次正式版本同步确认。

API 依据：[创建 Release](https://docs.atomgit.com/docs/apis/post-api-v-5-repos-owner-repo-releases)、[更新 Release](https://docs.atomgit.com/docs/apis/patch-api-v-5-repos-owner-repo-releases-tag)、[获取附件上传地址](https://docs.atomgit.com/docs/apis/get-api-v-5-repos-owner-repo-releases-tag-upload-url)。
