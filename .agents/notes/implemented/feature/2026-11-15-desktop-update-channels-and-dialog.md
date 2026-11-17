# Agent 笔记：桌面端更新渠道、可配置更新源与更新对话框

状态：已实现

## 先说结论

Viva 桌面端原本能检查、下载和安装签名更新，但发行构建从来没带上更新源，设置页只显示“此构建未配置更新源”。现在更新分成两个渠道：正式版（Stable，经过发布流程的版本）和 AutoBuild（每天从 `main` 自动构建）。每个渠道一份签名更新源（feed，列出最新版本和安装包摘要的签名文件），默认指向官方仓库 `1lck/Lithe-IDEA`，用户可以改成镜像地址。

交互照 Motty：
- 有新版本时，标题栏右上角出现绿色下载箭头。
- 点开后先显示这次更新了什么，再由用户选择“下载并安装 / 跳过此版本 / 稍后”。
- 检查到新版本后不在后台自动下载。

两个渠道共用一份设置，不再保留单独的 Dev 应用。旧版本读到不认识的配置时照常运行，但不会把它从文件里删掉，并提示一次。正式版的更新源、旁边的日志和增量补丁由 Desktop Release 发布。AutoBuild 的更新源要等 Viva 支持预发布版本号才能发布，见 [AutoBuild 更新源](../../proposed/feature/2026-11-16-desktop-autobuild-update-feed.md)。

## 问题

1. **更新不可用。** 发行构建没有注入更新渠道和公钥，`newUpdateClient` 返回 nil。用户每次都要去发布页手动下载完整安装包，增量更新的客户端代码也一直用不上（[#1913](https://github.com/1lck/Lithe-IDEA/issues/1913)）。
2. **只有一个渠道。** 用户不能在“稳定”和“每天最新”之间选择，AutoBuild 用户也无法回到正式版。
3. **跨渠道比较版本号会装错版本。** 按语义化版本（SemVer），`0.7.0-autobuild.<时间>` 小于正式版 `0.7.0`。直接比较时，AutoBuild 用户会被“更新”回更旧的正式版代码。
4. **更新提示没有内容。** Viva 的签名更新源只有 `notes_url` 链接，没有日志正文；后台检查只弹一条“有新版本”的通知，用户看不到更新了什么就要决定下载。
5. **旧版本会抹掉新版本的设置。** `desktop/internal/store/store.go` 保存时把 Go 结构体整个写回文件，旧版本不认识的字段下一次保存时就消失了。两个渠道共用设置以后，来回切换很容易触发。

## 决策

### 1. “安装渠道”与“更新渠道”分开

- **安装渠道**是打包时写入的，表示“现在装的是什么”，用户改不了。
  - `scripts/desktop/package-desktop.sh` 生成 `desktop/internal/buildinfo/package_info.go`（`lithe_package_info` 构建标签，打包结束即删除，Git 忽略），写入渠道、UTC 构建时间、commit 和更新公钥。`viva package` 不接受 `-ldflags`，所以不用 `-X`。
  - `--stable` 只由 Desktop Release 传入，`--autobuild` 只由 AutoBuild 工作流传入。两者都不传的本地包没有渠道：不检查更新，渠道选项置灰。
- **更新渠道**由用户在设置 → 更新里选，表示“以后从哪个渠道更新”，存进 `settings.json` 的 `updateChannel`；空值表示跟随安装渠道。新渠道的构建装好后，又跟随它自己的渠道。
  - 列表里此构建自己的渠道显示为“自动（正式版）”或“自动（AutoBuild）”，选它就是不保存选择、跟随构建；另一个渠道只显示名称，选中即显式切换。这样继承值和显式选择能区分（`develop-lithe`“显示实际生效值”）。
- **跨渠道从不比较两个渠道的版本号。** Viva 的 `update.Config.Current` 是“和谁比较”，不必是正在运行的版本（`desktop/internal/workbench/update_channels.go`）：

| 情况 | 行为 |
| --- | --- |
| 更新渠道等于安装渠道 | 和运行版本比较，可用增量补丁 |
| 正式版 → AutoBuild，或 AutoBuild“现在回到正式版” | 用户确认后和 `0.0.0` 比较，目标渠道的最新版本总会提供；完整下载并替换 |
| AutoBuild 等下一个正式版 | 和去掉预发布后缀的版本比较（`0.7.0-autobuild.*` → `0.7.0`），只有更高的正式版才算更新 |
| 下载或安装进行中 | 不允许切换渠道或更新源 |
| 切换完成 | 丢掉上次检查的结果和补丁重建的安装包，立即检查新渠道 |

跨渠道一律不用增量补丁：补丁只对同一渠道上一版的精确字节有效。

### 2. 更新源可配置，默认指向官方仓库

- 默认地址写在 `desktop/internal/buildinfo/update.go`，任何构建都有默认源：`https://github.com/1lck/Lithe-IDEA/releases/download/desktop-update-feed/stable.json` 和同目录的 `autobuild.json`。
- 设置页每个渠道一行更新源，默认显示为官方仓库，可改成自定义 HTTPS 地址，也可以恢复默认。只有改过的渠道才写入 `updateSources`。
- **自定义源只换下载地址，不换信任对象**：仍用内置公钥验签。镜像必须原样提供官方签名的文件；需要自己密钥的 fork 必须自己编译。
- 公钥是逗号分隔的多把：一把对应 CI 里签名的私钥，一把对应离线保存的备用私钥。任何一把内置公钥验签通过都会被接受，没有吊销机制；要让客户端不再信任某把钥，只能发布一个不再内置它的版本（见第 7 节）。

### 3. 先看日志，再决定

1. 检查时机沿用启动后 5 秒、之后每小时。后台检查发现新版本时：
   - 标题栏最右侧（可排列按钮区之后、系统窗口按钮之前）出现绿色圆环加下箭头，颜色 `RGB(22, 163, 74)`，明暗主题相同。悬停提示写出版本号。
   - 同一版本只通知一次，带“查看更新内容”按钮。不弹对话框，免得打断正在输入的人；也不自动下载。
2. 绿箭头、通知按钮和设置页“查看更新内容”都打开**更新对话框**（`desktop/internal/workbench/update_dialog.go`）：
   - 标题是版本号，副标题是当前版本、渠道和下载大小（有增量补丁时同时显示增量和完整大小）。
   - 正文是 Markdown 更新日志，限高可滚动；底部有“在 GitHub 查看完整说明”。
   - 按钮是“跳过此版本 / 稍后 / 下载并安装”。deb/rpm 管理的安装（`ErrManagedExternally`）和不可写的安装目录（`ErrNotWritable`）把主按钮换成“打开下载页面”，并说明原因。
3. **三个选择：**
   - **跳过此版本**：按渠道记入 `updateSkipped`。这个版本不再出现绿箭头和通知，更新的版本照常提示；用户主动“检查更新”时仍显示它。
   - **稍后**：关闭对话框，绿箭头保留。
   - **下载并安装**：开始下载。对话框可以关闭，绿箭头外圈变成进度环，再点可以看进度或取消。应用补丁的阶段不能取消。
4. 下载并校验完成后，主按钮变为“重启并更新”。补丁失败时改下完整包。
5. **下载断开后接着下。** 续传由 Viva fork 的 `update` 包实现，更新器只决定断开后怎么办（`desktop/internal/workbench/updates.go`）：
   - 下载存在 `Updates/<版本>/` 下，断开时保留已收到的字节。下次“下载并安装”只请求剩下的部分；服务器不支持范围请求时从头下载。已经下完并校验过的文件不再下载。
   - 连续一分钟没有收到数据就结束下载并提示失败（`appupdate.ErrInterrupted`），下载整体不限时长。
   - 只是断开的补丁下载不算补丁失败：不改下完整包，也不记“补丁不可用”，下次接着下补丁。补丁只有完整包的一小部分，改下完整包反而要下更多。
   - 开始下载一个版本时，删掉其他版本留下的下载，缓存里最多一个版本。删不掉时记 `app.background.operation_failed`（`operation: update_download_cleanup`），下载照常进行。

### 4. 更新日志放在更新源旁边（照 Motty 的顺序）

Motty 的签名更新源只带版本、安装包和补丁；验签发现新版本后，再单独取这个版本的说明，取不到就显示“没有更新说明”。日志只是展示内容，装不装由签名更新源里的安装包摘要决定，所以不签名、也不用改 Viva。

Lithe 只换日志的位置（`desktop/internal/workbench/update_notes.go`）：
- `stable.json` 旁是 `stable.notes.md`，`autobuild.json` 旁是 `autobuild.notes.md`，一起发布到 `desktop-update-feed`。镜像整目录复制即可。
- 第一行是 `<!-- lithe-update-notes version=<版本> -->`。只有版本与已验签的更新源一致时才显示正文，避免两个文件先后上传时显示错版本的日志。
- 客户端最多读 16 KB，按 UTF-8 字符边界截断。
- 正式版日志来自 `docs/releases/v<版本>.md`。

### 5. 共用设置，保留不认识的配置

- 两个渠道使用同一个应用 ID `app.lithe.viva`、同一个设置目录和同一个安装位置，切换渠道就是原地替换安装包。
- **`desktop/internal/store/` 保留不认识的配置**，所有经 `store.Save` 保存的文件都受益：
  - 读取时，按目标类型的 JSON 字段（包括嵌套对象和字符串键 map）找出两类值：当前版本没有字段的键（`Unknown`），以及字段在、但存的形状读不了的值。后者用默认值运行，原值保留。
  - 保存时先写当前结构体，再把这些值原样合并回去。当前版本自己改过或清空的字段以当前版本为准，不会被旧值“复活”。
  - 形状读不了的值不能悄悄变成默认值：`Store.Unread` 返回这次读取的解码错误，调用方照旧记日志。设置、标题栏布局记 `app.settings.decode_failed`，编辑器会话记 `editor_session_load`；日志目录和插件授权仍按读取失败处理，不读一半。
- **提示**：读到新版本写的键时，每组键只通知一次（`desktop/internal/workbench/settings_kept.go`）。
- **切换渠道时可以恢复设置**（`desktop/internal/workbench/update_snapshots.go`）：
  - 离开一个渠道前，把 `settings.json` 的原始字节存到偏好目录的 `update-snapshots/<渠道>-<版本>-<UTC 时间>.json`，只留最近 5 份。
  - 切回某个渠道时可选“保留当前设置”或“恢复上次离开该渠道时的设置”。恢复由装好的新构建在下次启动、读设置前完成，直接复制字节，只保留当前的更新相关设置。
  - 快照只写偏好目录，不写安装目录（见 [运行时只读边界](../bug-fix/2026-09-25-runtime-bundle-immutability-and-update-delta.md)）。

### 6. 发布正式版更新源（#1913）

- 用 `viva update-keygen` 生成 Ed25519 密钥。私钥是 Actions secret `VIVA_UPDATE_KEY`，只交给 Desktop Release 的 `update-feed` 任务，打包任务拿不到；公钥放在仓库变量 `LITHE_UPDATE_PUBLIC_KEYS`，打包时写进程序。私钥不进仓库。
- `scripts/ci/desktop-release/publish-update-feed.sh` 在发布页已有安装包之后运行：
  - 固定 tag `desktop-update-feed` 下放 `stable.json`、`.sig` 和 `stable.notes.md`。不用 `releases/latest`，因为 `desktop-v*` 都以 prerelease 发布。
  - 并发组 `desktop-update-feed-stable` 保证两个发布不会同时写更新源；更新源已经提供更新的版本时不动它。
  - 没有私钥时跳过，不让发布失败。
- **增量补丁照 Motty 的 `tools/mirror-release.sh`**：
  - 上一版就是当前 `stable.json` 提供的版本。逐个平台下载它的 zip 或 tar.gz，同时对照更新源里的摘要和发布页的 `.sha256`，再交给 `viva feed --patch-from <os>/<arch>=<版本>=<旧归档>`。
  - 只为上一版生成补丁，更早的版本下载完整包。对同一版本重跑会得到同一个基线。
  - 取不到或对不上的平台只发布完整包。
  - `viva feed` 只给 zip 和 tar.gz 挂补丁。Windows NSIS 安装版在客户端复用同一平台 zip 的补丁（`desktop/internal/workbench/updates.go` 的 `patchFrom`，与 Motty 的 `patchesFor` 相同）；macOS 的 dmg 不进更新源。
- `viva` 命令由 `scripts/desktop/build-viva-tool.sh` 从 `desktop/go.mod` 的 `replace` 编译，不用 `go run …/cmd/viva@<版本>`（会绕过 fork 固定）。

更新器留在 `desktop/` 的 Go 代码里。Viva 是 macOS、Windows 和 Linux 的唯一客户端，签名、比较和安装复用 Viva `update` 包，不在 Rust Core 另写一套。日志复用目录里已有的事件（`app.action.performed`、`app.notification.operation_failed`、`app.background.operation_failed`、`app.settings.decode_failed`），不需要 Core PR。

### 7. 签名私钥：丢失和泄露分开处理

Viva 客户端逐把尝试内置公钥，任何一把验签通过就接受更新源（`update/client.go` 的 `ed25519.Verify`），而且只提供比当前版本新的版本。所以拿到私钥的人不能让客户端降级，却可以签一个伪造的“新版本”。

- **配置时就准备备用钥。** 用 `viva update-keygen` 生成两对密钥：
  - 主私钥存为 `VIVA_UPDATE_KEY`。
  - 备用私钥离线保存，不放进 GitHub 的任何地方。
  - 两把公钥都写进 `LITHE_UPDATE_PUBLIC_KEYS`，从第一个签名版本起就内置。
- **私钥丢失：** 签不了新的更新源，已装的客户端检查不到新版本，但能照常使用，不存在安全风险。
  - 有备用钥时，把备用私钥换进 `VIVA_UPDATE_KEY`，再更新 `LITHE_UPDATE_PUBLIC_KEYS`：删掉丢失的那把，加一把新生成的备用公钥。然后照常发布。客户端用备用公钥验签，装上这一版后就不再信任丢失的钥。
  - 没有备用钥时，新公钥只能随新安装包送到用户手里，每个已安装的用户都要手动下载安装一次。
- **私钥泄露：** 拿到私钥的人可以签任意更新源，再通过他能控制的分发渠道送达，例如官方仓库的 Release、用户填写的自定义镜像，或者下载链路。只要客户端还内置对应的公钥，就会把伪造的版本当作正常更新提示出来。只加新公钥不会撤销旧钥。处理步骤：
  1. 把 `VIVA_UPDATE_KEY` 换成备用私钥，从 `LITHE_UPDATE_PUBLIC_KEYS` 删掉泄露的公钥，再加一把新的备用公钥。排查泄露途径，包括仓库和 Actions 权限、运行日志、secret 访问记录。
  2. 尽快发布一个用剩下那把钥签名的版本。客户端装上它以后就不再信任泄露的钥。没有备用钥时，只能用泄露的钥签这一次过渡版本，把客户端迁到新钥；这期间攻击者同样能签，所以第 3 步更要做到位。
  3. 升级到过渡版本之前，客户端一直暴露。要发布安全公告，提醒用户：
     - 从官方发布页手动升级；
     - 使用自定义更新源的用户先恢复默认源；
     - 用 Release 中的 `.sha256` 核对已安装的包。

### 正确做法

- AutoBuild 用户把更新渠道改成正式版、最新正式版是 `0.7.0` 时，提示“将在高于 0.7.0 的正式版发布时更新”，并提供“现在回到正式版”。
- 后台检查发现 `0.7.1`：出现绿箭头和一次通知，用户点开后先看到日志，再决定下载。
- 旧版本读到新版本写的 `editorPreferences.foo`：用默认行为运行，保存时把 `foo` 原样写回，并通知一次。

### 不要这样做

- 不要直接比较 `0.7.0` 和 `0.7.0-autobuild.<时间>` 来决定跨渠道更新，SemVer 会认为正式版更新。
- 不要让没人请求的检查弹出对话框，或者在后台自动下载。
- 不要让 `store.Save` 只写结构体里的字段；也不要把读不了的值当默认值却不记日志。
- 不要因为日志取不到就不提示更新：日志失败只影响正文，对话框照常显示版本、大小和按钮。
- 不要从 GitHub Releases API 读日志：未登录每小时只有 60 次请求，镜像也没有这个 API。
- 不要把私钥交给打包任务，也不要把设置快照写进 app bundle 或 Windows 安装目录。
- 不要把备用私钥也存进 GitHub。备用钥的用途是 secret 丢失或泄露后还能签名，和主钥放在一起就会一起泄露。
- 私钥泄露时，不要只往 `LITHE_UPDATE_PUBLIC_KEYS` 里加新公钥：已安装的客户端仍然信任旧公钥，必须把它从变量里删掉，并发布新版本。

## 考虑过的备选方案

### AutoBuild 使用单独的 Lithe-Dev 应用身份

已退役的 Swift 客户端曾让 AutoBuild 用独立的应用 ID，两个版本的设置天然隔离，还能同时安装。

不采用：用户要维护两个应用和两份设置，切换渠道时设置不跟着走。维护者已明确不保留 Dev 版本，设置冲突改由“保留不认识的配置”和快照恢复解决。

### 发现新版本就在后台下载，下载完再显示日志

Sparkle 等更新器常这样做，用户点“重启”就能立刻更新。

不采用：用户还没看到内容就花掉了流量，被跳过的版本也会被下载。维护者明确要求先显示更新内容，再选择下载或跳过。

### 把日志签进更新源（给 Viva fork 加 `Release.Notes`）

日志和安装包一起验签，客户端只需一次请求。

不采用：要改 fork 的格式并向上游提 PR。Motty 已经证明不签名的日志足够，能不能安装由签名更新源里的摘要决定。

### 日志直接读 GitHub Release 正文（Motty 的来源）

不需要额外发布文件。

不采用：未登录时每小时只有 60 次请求；自定义镜像拿不到；滚动的 AutoBuild release 正文是固定的下载说明。

### 每个渠道一份独立的设置文件

彻底避免新旧版本互相改写设置。

不采用：在一个渠道里调好的设置，切到另一个渠道就没有了。维护者要求共用设置。

### 一份更新源同时包含两个渠道

只维护一个文件。

不采用：Viva 的 `Feed` 一个文件只表示一个渠道并校验 `Channel` 字段；正式版和 AutoBuild 由不同工作流在不同时间发布，同时改写一个文件容易冲突。

### 补丁基线用上一个 `desktop-v*` tag

最容易找到。

不采用：用户手里装的是更新源提供过的版本，不一定是上一个 tag（某次发布可能没写更新源）。用当前 `stable.json` 提供的版本做基线，才和客户端实际持有的字节一致，并能用更新源里的摘要校验旧归档。

## 后果

- 正式版用户可以在应用内看日志、下载和安装更新，同一渠道的上一版可以走增量补丁。
- 新旧版本、两个渠道共用设置时，新版本写的配置不会被旧版本抹掉；读不了的值会进日志，问题可以排查。
- 代价：
  - 发布流程多了一个持有私钥的任务和一个滚动 tag。
    - 私钥丢失：靠离线备用钥继续签名；没有备用钥，用户只能手动重装。
    - 私钥泄露：还没升级的客户端会接受伪造的更新源，需要撤换公钥、发布新版本并发布公告（决策第 7 节）。
  - `store` 的合并逻辑比整份写回复杂，嵌套对象和类型变化的边界由 `desktop/internal/store/keep_test.go` 覆盖。
  - AutoBuild 用户在 AutoBuild 更新源发布之前仍要手动下载；客户端已按渠道检查，但当前 AutoBuild 包沿用 `viva.toml` 的版本号。

## 验证

- `cd desktop && ../scripts/desktop/desktop-go.sh test ./internal/store/... ./internal/workbench/... ./internal/logstore/... ./internal/plugintrust/... ./internal/buildinfo/...`：渠道比较、跳过、对话框、快照恢复、NSIS 复用 zip 补丁、断开的补丁下载不改下完整包、缓存只留一个版本、未知配置保留与 `Unread` 日志。
- Viva fork 的 `go test ./update/...`：断开后续传、服务器不支持范围时从头下载、无数据超时、复用已校验的文件。
- `node --test scripts/ci/desktop-release/publish-update-feed.test.mjs`：没有私钥跳过、补丁基线校验、更新源已提供更新版本时不动它、日志首行版本。
- `node --test scripts/desktop/package-desktop.test.mjs`：`--stable` / `--autobuild` 写入渠道、构建时间、commit 和公钥，打包后删除生成文件。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `desktop/internal/buildinfo/`
- `desktop/internal/store/`
- `desktop/internal/workbench/updates.go`
- `desktop/internal/workbench/update_channels.go`
- `desktop/internal/workbench/update_dialog.go`
- `desktop/internal/workbench/update_notes.go`
- `desktop/internal/workbench/update_snapshots.go`
- `desktop/internal/workbench/settings_kept.go`
- `desktop/internal/settingswindow/updates_view.go`
- `scripts/desktop/package-desktop.sh`
- `scripts/desktop/build-viva-tool.sh`
- `scripts/ci/desktop-release/`
- `scripts/ci/desktop-autobuild/`
- `.github/workflows/desktop-release.yml`
