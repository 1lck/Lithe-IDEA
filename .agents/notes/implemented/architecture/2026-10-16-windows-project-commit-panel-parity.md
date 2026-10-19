# Agent 笔记：Windows 项目和提交面板同步边界

状态：已实现

## 先说结论

Windows 项目树区分行选择与编辑器活动文件，提交列表区分行选择与暂存包含。提交面板按当前 Swift 实现组织 Commit/Shelf 切换，草稿保留在原工作区会话。搁置记录（Shelf，保存改动后暂时清理工作区的恢复记录）必须先落盘，再清理文件；任何部分失败都保留完整记录供用户比较和恢复。

## 问题

原文件树只处理单项，目录单击把选择与展开绑定。提交列表已有 Diff 与暂存能力，但缺少 Amend 入口和集中的保存改动页签。项目历史聚合还暴露了旧存储只以相对路径区分文件的问题：两个项目的 `src/main.java` 会混入同一个时间线。

## 决策

- 提交面板以当前 `ChangesSidebarView.swift`、`GitChangelistBar.swift`、`CommitAreaView.swift`、`CommitMessageEditor.swift` 及 `LitheTheme.Commit` 为基准。未知版本截图只辅助检查，不能代替这些组件的结构和状态归属。页签使用 28px 圆角选中面、41px 标题栏；40px 操作栏先于 ChangeList，依次为刷新、丢弃选中改动、暂存当前列表、预览首项。Windows 既有比较来源和目录切换保留在紧凑菜单中。
- 默认更改列表与命名列表一视同仁，已跟踪和未跟踪文件放在同一列表分组，多仓库仍先分仓库。仓库标题使用普通树行，显示仓库名和计数，完整路径留在提示中；复选框放在图标前。新配置默认平铺，用户已有目录显示偏好继续保留；宽度不足 300px 时隐藏文件父路径。分组复选框只改该组，工具栏批量暂存只改活动列表；行选择不等于暂存。预览按钮始终打开首项的完整 Diff，不受文件行点击偏好影响。父仓库引用选项由 `GitView` 持有，在列表选择器下方显示，并传给提交审核；重试继续使用原计划的选项。
- 提交底部保留 Swift 的字体层级：列表、Amend、说明及提交按钮默认 13px，计数 12px，AI 11px；说明使用平台既有等宽编辑器字体，其他控件使用 UI 字体。Windows 延续用户字号缩放和系统字体，不把 macOS 的 Inter/JetBrains Mono 偷换成跨平台字体一致性结论。计数表达当前列表实际已暂存文件数，不能写成行选中数。
- 说明框默认和最小高度均为 50px，已有合法高度偏好不重置。常规底部约 124px；小于 300px 的可用宽度时，Amend 独占一行，AI 与计数放在下一行，底部两个提交按钮与设置保持同一行，长按钮文案可截断但保留完整无障碍名称。拖动仍每帧只写 CSS，结束时保存一次；上方保留 120px 的 ChangeList 区域加 40px 操作栏。AI 使用原始 `expui/diff/magicResolveToolbar.svg`，丢弃使用 `expui/vcs/revert.svg`，不改变其他功能的重做/撤销图标。
- 项目、提交、Stash 和 Dependencies 的树正文共用 `SidebarTreeRow` 的 `ui-text-sm`，默认 13px，并跟随界面字号设置；窗口舒适密度只调整工具栏等 chrome，不单独放大树正文。工具栏与辅助说明保留各自字号层级。刷新动作复用已有 `RefreshIcon` 对应的 IDEA `expui/general/refresh.svg`，不再借用 redo 图标；原有重做动作的图标映射不变。
- 树选择复用可见顺序工具，Shift 保持初始锚点，Ctrl 增减单项，项目树 Ctrl+A 只选择焦点项的显示同级；复选框仍只表达实际 Git 暂存状态。折叠目录不删除明确选中的后代，批量操作从已有文件库存取集合，不额外加载磁盘树。文件索引只在库存变化时建立，选择改变不重新遍历整棵树。
- 编辑器切换当前文件时，项目树的单选、键盘焦点和范围锚点一起跟随；明确多选保持原集合。只有同步 Hook 的编辑器目标实际变化才同步，不能把目录点击后共享侧栏路径恢复为编辑文件的往返当成编辑器切换。选择回归通过真实 `FileExplorerPane`、侧栏与缓冲区 store 验证，不能仅替换树的 `activePath` 属性来模拟编辑器。
- 横向宽度测量只使用实际文字宽度。窄侧栏隐藏父路径后，剩余 flex 槽仍可能占空间；文字宽度为零时不能用槽的 `scrollWidth` 替代，否则每次测量都会继续拉宽树并触发 React 更新循环。DOM 无布局的单元测试仍允许使用固定宽度替身，浏览器检查必须覆盖隐藏父路径和缩放面板。
- 项目树使用既有虚拟列表与水平宽度测量；连续拖动只更新预览 DOM 坐标，进入或离开目标行时才更新 React 状态。移动预检整个集合，父目录覆盖后代操作，重名目标拒绝；成功项立即交给原文件系统 owner 更新文档路径与目录标记。中途失败停止后续项，不回滚已成功项。
- 目录标记保存在 WebView 用户数据的工作区偏好中，只描述项目树呈现，不取代语言服务器拥有的源码根、编译输入或 classpath。目录标记使用文件系统路径身份：本地 Windows 盘符和普通 UNC 不区分大小写，POSIX、WSL 和远程路径保留大小写并隔离存储。Project/Dependencies 当前只读投影 Maven 模块 owner 的已有快照，打开和展开均不启动解析；用户明确点击“解析依赖”才调用既有 Maven 操作。通用语言插件依赖快照、归档及虚拟文档浏览仍待同步；此入口不能声明已达到 macOS 全部依赖能力。
- 项目本地历史依赖 Core 的本地文件系统查询，因此菜单只对原生本地工作区显示，`openProjectLocalHistory` 也拒绝 `wsl://` 和 `remote://` provider 路径。后续开放这些 provider 时，必须先补齐 Core 或对应 provider 的历史契约，再移除入口门控。
- Shelf 用原始 Git 补丁分别保存暂存和工作区版本，包含未跟踪与二进制文件。保存完成后再读取一次快照并比较，确认期间没有变化才逆向清理；恢复先恢复暂存，再恢复工作区，最后才删除记录。两步之间的冲突不做自动合并或回滚，完整记录继续保留。重试时，某层补丁应用失败后复用 Core 的只读逆向检查，确认该层已恢复才继续；暂存层只检查索引，避免工作区已恢复第二层时误判。检查失败或仍有真实冲突时保留记录，全部恢复后删除失败也允许再次重试。
- Core 的预览令牌绑定补丁方向、目标、真实索引和工作区内容。Git 只读命令与 `apply --check --index` 也可能刷新索引时间信息，因此检查使用一次性索引副本；真实恢复在审核状态通过后刷新索引时间缓存，再由 Git 做最终内容匹配。共享协议保持 `reverse` 默认为 false。
- Git Stash 使用不可变对象身份 `oid`；列表位置变化后按身份重新定位，避免把旧 `stash@{0}` 当成同一记录。Diff 缓存和仍在等待的读取也按同一身份区分，旧读取的自动重试不得复用新占据该位置的记录结果。原 positional reference 继续兼容旧调用方。
- Shelf 与提交、暂存和 changelist 修改互斥。写工作区前检查未保存文档；切换工作区后停止后续写入，迟到的列表与 Diff 读取不能覆盖新面板。原生存储命令只保存恢复数据，不执行 Git 写操作。
- 工作区存储按仓库保存未完成操作的独立标识，每个完成回调只能释放自己的锁。切换仓库、卸载 Shelf 子面板或切到文件侧栏导致整个 Git 面板卸载，都不提前释放仍在等待的操作；回到原仓库时仍禁止重复写入。普通 Windows 路径别名共用锁，WSL 路径保持大小写隔离。提交、暂存和更改列表修改可能跨仓库，因此任一仓库仍有未完成操作时都保持禁用。新面板观察到旧操作结束后重新加载保存记录，覆盖原生保存或删除不发送 Git 事件的情况。操作锁只控制新操作入口，不能当作外部提交忙碌状态传给当前操作的守卫，否则会取消操作自身。
- Shelf/Stash 列表与选择绑定到本次仓库会话及加载版本。切换仓库或刷新时立即隐藏旧列表，当前列表未成功加载前禁用创建、恢复和删除；加载失败可重新刷新。删除确认后再次核对会话和列表版本。离开 A 后再回到 A 也属于新会话，旧确认与恢复流程不得继续写入。
- Shelf 原生存储对普通 Windows 盘符与 UNC 保留既有小写路径哈希。WSL UNC（`wsl$`、`wsl.localhost`，包括 canonicalize 产生的 verbatim UNC）使用独立的区分大小写哈希，使 `Repo` 与 `repo` 互不读取或删除。旧 WSL 小写哈希已丢失仓库归属，原字节留在原 app data 目录，不自动迁移、展示或删除；人工恢复前必须先核对原始补丁与目标仓库。

Shelf 的工作区层必须以真实索引为基线，包含未跟踪文件，统一由 Core 在临时索引中导出。例如已提交文件执行暂存删除后仍留在磁盘，工作区层必须记录“新增该文件”，清理时先移除磁盘副本，再逆向恢复暂存删除。不能拼接以 HEAD 为基线的未跟踪补丁，否则同内容副本会丢失，重建重命名源路径也会失败。普通补丁导出的 HEAD 基线保持原语义。

Maven 面板和 Dependencies 依赖导航共用 POM 路径解析，始终包含工作区根、reactor（Maven 多模块项目）相对目录和模块相对目录。工作区内 `backend/service` 的依赖必须打开该目录的 `pom.xml`，不能漏掉 `backend` 后跳到别的项目。

正确示例：同一文件的已暂存版本是 B，磁盘版本是 C。Shelf 保存 A→B 与 B→C，清理后回到 A；恢复后索引仍为 B，磁盘仍为 C。不要只保存 A→C 后执行整仓库 reset，否则暂存边界会丢失。

## 考虑过的备选方案

- 用 `git stash` 冒充 Shelf：两种保存记录的归属和删除规则不同，采用独立记录加现有 Core 补丁能力，不复制 Git 补丁解析和应用语义。
- 先清理再保存：磁盘满或进程退出时会丢失恢复数据，否决。保存使用同目录临时文件，刷新落盘后以不覆盖移动发布；Windows 不依赖硬链接，因此支持 FAT/exFAT。
- 通过前端解析后的 Diff 重建补丁：会丢失二进制、CRLF、无末尾换行和重命名身份，否决。解析结果只供显示，写入始终使用原始补丁。
- 自动把旧全局历史复制到当前项目：旧元数据没有可靠工作区归属，无法区分同名文件。保留旧目录原字节，新的读写使用按工作区隔离的目录；不自动迁移或删除旧记录。
- 直接将旧 WSL Shelf 桶复制到当前仓库：大小写不同的仓库曾共享同一桶，无法证明其中每条记录属于当前仓库。新键加入独立命名空间，避免全小写路径继续误读旧桶；代价是旧 WSL Shelf 需要人工确认归属后恢复。

## 后果

项目与提交面板的选择、草稿和保存改动具有明确归属，部分失败仍保留恢复材料。代价是 Shelf 恢复无法自动消除并发编辑造成的冲突，用户需要比较保留的补丁与当前文件。

Shelf 存储在平台 `app_data_dir()/git-shelves/<规范化根路径哈希>`，持有者是 Windows 原生 adapter，直到用户删除或成功恢复才移除。历史存储在同一平台用户数据下的 `local-history/workspaces/<规范化根路径哈希>`，由既有历史策略管理。目录标记由工作区偏好 owner 管理；这些都是用户可变状态，不属于可跨 worktree 复用的构建资源，不注册到下载资源清单。三者不写安装目录，不影响代码签名或 Sparkle delta。

## 验证

- `bun run typecheck`（在 `windows/tauri`）
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1`
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`
- `git-saved-changes.test.tsx` 控制列表加载与删除确认的完成顺序，验证跨仓库加载失败、迟到结果、刷新失败及 A→B→A 后旧操作不能恢复或删除记录；`shelf_storage.rs` 验证 WSL 大小写隔离、旧桶保留及普通 Windows 键兼容。
- 保存改动组件测试覆盖整个 Git 父面板卸载后重挂载：A 操作完成或失败均不解锁仍在运行的 B，回到 A 后必须等待 A 的原操作结束；旧面板的原生删除结束后，新面板重新加载列表并移除旧记录。同一组件保持挂载并切换 A→B→A 时，操作归属也要按最初会话区分，原生删除结束后刷新当前列表。`git-stash-diff-api.test.ts` 控制不同 OID 占用同一位置、旧读取重试和旧 positional 调用的完成顺序，确认 Diff 结果与缓存不会串用。工作区锁测试覆盖路径别名、WSL 大小写和过期释放回调。恢复工作流测试覆盖仅暂存层已恢复、两层已恢复但删除失败、检查失败及检查期间切换工作区。项目树选择测试核对编辑器单选跟随后的高亮、复制、剪切与范围锚点，以及明确多选和未切换编辑文件时的目录选择保留。
- `cargo test --manifest-path rust/lithe-core/Cargo.toml git_diff_and_apply_round_trip_a_patch -- --test-threads=1` 核对复用的 Core 索引及工作区逆向检查，不将只读检查误作实际恢复。
- `cargo test --manifest-path rust/lithe-core/Cargo.toml git_patch_exchange -- --test-threads=1`
- Shelf 真实 Git 回归覆盖暂存删除后保留同内容或改过内容的原文件，以及暂存重命名后重建源文件；核对清理后的干净状态和恢复后的暂存内容、磁盘字节。Dependencies 组件测试双击嵌套 reactor 的根和子模块依赖，确认编辑器接收正确的 POM 路径。
- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml`
- `./scripts/build-windows.ps1 -Configuration Release`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`
- 真实 WebView2 中检查明暗主题、窄宽布局、范围多选、目录双击、重名移动、切换页签保留草稿、Shelf 两版本恢复、Stash 位置变化与冲突后的记录保留；自动化控制不可用时保持矩阵 pending。

## 适用范围

- `windows/tauri/src/features/file-explorer`
- `windows/tauri/src/features/git`
- `windows/tauri/src/features/local-history`
- `windows/tauri/src-tauri/src/shelf_storage.rs`
- `windows/tauri/src-tauri/src/file_publication.rs`
- `rust/lithe-core/src/git/patch_exchange.rs`
- `shared/contracts/rust-core-api.md`
