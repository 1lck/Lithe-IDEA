# Agent 笔记：最近项目跨窗口保存与远程身份

状态：已实现

## 先说结论

每次打开、固定、移除或编辑项目标签时，桌面端先取得跨进程文件锁，再读入当时磁盘上的最近列表，把这一次动作交给 Rust Core（共享规则层），最后原子写回。不同窗口可以接着修改同一份历史。远程历史用完整连接身份和远端目录来区分项目，从列表重开时先核对保存的 SSH 目标，再沿用当前连接配置、认证和工作区信任流程。

## 问题

两个窗口先读到同一份列表时，在一边固定项目后，另一边打开任意本地项目就会保存整份旧列表，导致固定状态丢失。固定项目也按打开时间排序，所以新固定的条目可能排在已有固定项目下面。远程窗口原有的连接内历史可重开文件夹，起始页无法显示这些已打开的项目。

## 决策

- 以用户当前动作作为锁内事务。比如窗口 A 固定旧项目后，窗口 B 应当重新读盘，再追加 B 打开的项目。把窗口 B 的整份内存列表当作写入基础，会覆盖 A 已确认的操作。菜单发送明确的固定或取消固定动作，旧窗口再次固定同一项目时保留已有状态。保存后通知同一配置目录的工作台，其他进程的原子替换复用配置目录观察器，窗口激活同时保留一次读取。
- Core 按固定动作排序。旧记录没有固定顺序时保留原来的相对次序。打开已固定项目只更新打开时间，并保留固定顺序和标签。乱序到达的较早事件不覆盖已有的打开时间或远程路由。搜索、标签清理和筛选由同一份 Core 规则完成。查询、标签去重和标签选择统一使用 Unicode 默认大小写折叠，显示保留用户输入的拼写。标签编辑器把打开时读到的标签一同提交，Core 在锁内拒绝覆盖已经变化的标签，原草稿留在弹窗。
- Core 从连接身份与远端绝对路径组成历史键。相同目录名出现在两台主机时有两条记录。历史保留重连接所需的定位信息，SSH 配置和秘密仍由已有连接及系统凭据存储负责。不保存本地缓存占位路径。SSH 及 SSH 上的容器记录 Core 从保存的主机、端口、账号和跳板生成的指纹。保存的 SSH 已改绑或老条目没有指纹时，要求从远程开发重新选目录。不同目标使用独立的本地工作区占位路径，打开已验证的 SSH 目标前把旧无指纹占位路径下尚未恢复的本地草稿迁移到新占位路径（不覆盖新路径已有草稿）。指纹标识保存配置，实际主机认证仍由 OpenSSH 完成。直开前确认远端路径仍为目录，容器连接失败时重试原目标。
- 首次修改时从旧 `recent-projects.json` 收录记录，写入独立的 `recent-projects-v2.json`。新版与旧版各自写入自己的文件，避免降级后丢失标签或远程身份。旧文件损坏时，首次成功写入从当前动作创建新版历史并保留旧文件。平台适配器在用户配置目录上持有文件锁。它在事务或进程结束时释放，锁文件留在同一目录供下次使用。

## 考虑过的备选方案

- 在保存前重读磁盘但不持锁。两个进程可以同时读到同一份列表，后写者仍会覆盖先写者。
- 在欢迎页直接合并每个 SSH 连接的文件夹列表。该列表没有全局打开顺序，也无法代表 WSL 和容器历史。
- 用远端路径或本地缓存路径当项目身份。远端路径可以出现在多个连接上，缓存路径则会随本地缓存位置改变。

## 后果

历史支持窗口间独立修改，并可从同一个入口固定、搜索和重开本地与远程项目。写入多了一次有界的后台锁等待和磁盘读取。旧版每连接的历史继续留在远程开发窗口，远程目录下次成功打开时进入公共历史。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'TestWelcome(MostRecentlyPinned|PinSurvives|PinFromAnOlder|ProjectTags|RemoteProject)|TestRecentProjects(Migrates|Leave)' -count=1 -timeout=90s` 覆盖排序、旧窗口写入、标签、SSH 重开和安装包原样。
- `TestWelcomeStaleTagEditorKeepsOtherWindowsSavedTags` 检查第二个窗口的草稿保留及冲突提示，`TestWelcomeSSHHistoryRejectsUnboundAndReassignedTargets` 检查旧路由在认证前被拒绝以及新旧目标的项目状态独立。
- `scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/workbench -run TestVisualWelcomeRecentProjects -count=1 -timeout=90s` 使用 `LITHE_VISUAL_OUTPUT_DIR` 采集最近项目、过滤和标签编辑截图。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh` 和 `./scripts/agent-notes/verify-agent-notes.sh` 检查存储路径门禁及 Note 格式。

## 适用范围

`desktop/internal/workbench/recent_store.go`、`desktop/internal/workbench/recent_remote.go`、`desktop/internal/workbench/welcome_tags.go` 和 Core 的 `workspace.recentProjects.reduce`。
