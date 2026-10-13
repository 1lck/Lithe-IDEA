# Agent 笔记：Windows 任务栏项目与文件标题

状态：已实现

## 先说结论

Windows 工作台把当前项目和活动文件写入原生窗口标题，任务栏预览和 Alt+Tab 因而可以区分项目。展示名称复用项目标签的名称与别名；所有打开项目中出现同名时，附加项目路径。终端、搜索和 Diff 等工具页激活时只显示项目，标题同步不改变项目切换、窗口归属或编辑器状态。

## 问题

Issue #961 中多个项目窗口在任务栏上都显示 Lithe，用户只能根据缩略图判断要切换的窗口。只改变网页的标题或应用内项目菜单，不能保证系统窗口切换器得到相同信息；只检查一个窗口的项目，也会漏掉其他窗口中的同名项目。

## 决策

参考 IntelliJ IDEA 的原生标题设计：优先显示项目名称，其后是活动文件；同名项目自动增加方括号包围的路径。依据是 JetBrains 的 `PlatformFrameTitleBuilder` 与 `ProjectFrameHelper`，不复制上游代码，也不引入模块分析或完整路径设置。

前端从已有 workspace 状态、活动分屏和 buffer（已打开的内容）提取标题上下文。项目展示名称复用 `getProjectDisplayLabel`，不建立另一份活动项目状态；标题读取不创建未初始化的 workspace store。当前项目尚未就绪时省略文件名称，切换失败后跟随现有状态回退。

底部终端不是编辑器的 pane（分屏），进入终端后编辑器仍保留原来的活动文件。因此标题来源还只读现有键盘上下文的 `terminalFocus`，终端获得焦点时清除文件名，返回编辑器时恢复；不会为标题改写终端标签或编辑器的分屏状态，选择变化也不触发额外标题同步。

搜索侧栏同样不改变活动 buffer。独立焦点观察模块读取现有 DOM（页面元素树）的 `data-external-file-drop-scope="sidebar"` 范围，并结合当前工作区 UI store 与 `getActiveSidebarView` 判断搜索是否实际获得焦点。搜索输入框获得焦点时清除文件名；返回编辑器、关闭侧栏或切换侧栏视图后恢复。搜索保持可见但焦点在编辑器时仍显示文件名；焦点事件通过微任务合并，卸载释放监听和订阅，不增加轮询，也不修改原有搜索、布局或编辑器组件。

例如项目 demo 的活动编辑器是 Application.java，标题为 `demo – Application.java – Lithe`；点击终端页后是 `demo – Lithe`。图片、PDF 和二进制查看页按文件名显示；Markdown、HTML、CSV 预览使用源文件名。工具页、虚拟编辑器和 Diff 不把内部协议地址当作文件名。

同步服务合并同一轮事件，只发送影响标题的元数据。每个窗口最多一个 IPC（前端到原生宿主的消息）在途，其间仅保留最新上下文。普通状态变化的相同成功快照不会重复发送；聚焦时重新提交，使宿主也能补偿其他窗口变化引发的标题设置失败。失败记录日志，并在后续状态变化或窗口聚焦时重试。销毁服务会释放所有订阅，不增加轮询或持久化。

请求失败时必须清空前端成功缓存，因为宿主可能已写入标题而应答失败。例如 A 成功后，B 已应用但应答失败，随后切回 A，应继续发送 A；不能凭借历史成功缓存跳过。工作区初始化状态变化也强制刷新登记快照，即使上下文文本没有变化；普通正文输入与光标移动仍不增加标题 IPC。

Tauri 宿主保存内存中的窗口展示投影，借助现有本地项目身份与归属登记确认目录属于哪个窗口。标题服务不接管项目的打开、关闭或聚焦。它汇总所有有效打开项目，包括后台标签；展示名称相同而目录不同的项目都增加路径，关闭或修改别名后重新计算相关窗口。

标题身份来自项目登记模块新增的只读查询函数：复制现有条目的进程内句柄标识及窗口、工作区归属，不重新打开目录，不查询 UNC（Windows 网络共享路径）。原有句柄映射、登记和释放函数保持不动。未完成登记的恢复标签按明确的展示路径区分，不猜测目录别名；初始化状态变化和窗口聚焦时再读取登记。新窗口初始标题在既有登记锁已持有时读取快照，不重复获取锁。该快照只服务标题展示，不建立第二份项目管理状态。

原生标题只由宿主调用 `WebviewWindow::set_title` 写入。排队更新读取最新投影，成功后才缓存结果；同值跳过，失败保留重试机会。从标题命令入口计算同一个 5 秒截止时间，覆盖登记锁等待和 UI 回调应答；每个窗口使用内部请求序号，过期、被新请求替代或窗口已销毁的回调不得修改展示投影。新窗口前端的初始欢迎态保留临时打开目标，正式上下文或打开失败再替换；窗口销毁和初始打开失败清理临时投影，不在 UI 线程等待项目归属锁。所有新状态只存在于进程内，不产生安装目录写入或新的缓存资源。

## 考虑过的备选方案

- 在 React 标题栏组件中直接调用前端 `setTitle`：组件重建会产生重复所有者，而且无法统一处理其他窗口的同名项目，因此使用生命周期受控的同步服务与单一宿主写入入口。
- 只更新 `document.title`：网页标题不是原生窗口标题的可靠同步契约，因此直接使用 Tauri 的窗口 API。
- 修改任务栏分组或定制缩略图：本需求只需要系统窗口名称，增加原生任务栏扩展会扩大兼容性和维护范围。
- 从各窗口持久化缓存猜测项目列表：可能包含已关闭窗口且不能证明目录归属，因此复用当前内存状态与原生身份登记。
- 把工具名称或上次编辑文件保留在标题中：用户明确选择工具页只显示项目，因此不增加工具名称或最近文件状态。
- 在原有 claim/release 函数中添加标题通知，或在搜索组件中注册焦点：超出本次只修改新增代码的边界，因此使用只读登记快照、初始化状态刷新和独立 DOM 焦点观察模块。
- 每次标题更新重新查询目录身份：离线共享的目录调用可能超过应答超时，因此标题路径只读取已完成的登记结果，未知项目采用路径回退。

## 后果

系统窗口切换可以直接辨认项目与活动文件，别名保持和项目菜单一致。实现仅属于 Windows 产品，不改变 macOS、共享 Rust Core、共享编辑器及应用内标题栏布局。

代价是多窗口需要同步展示投影；重名项目的完整路径可能被系统显示宽度截断。标题元数据会出现在操作系统窗口切换界面中，这是此功能的预期展示，不记录文件内容。Windows 11 的 Alt+Tab 已观察到项目与文件标题，以及长路径截断；任务栏悬停缩略图和 Windows 10 的实际外观仍需分别验收，自动化逻辑测试不能替代系统界面验证。

## 验证

Windows CI 显式运行标题上下文、来源、同步和焦点四组前端回归，每组使用独立 Bun 进程和 60 秒总期限，失败立即退出并上传逐测试 HTML/JUnit 报告。能力记录保存在 `shared/platform-feature-matrix/features/windows-taskbar-project-titles.json`；生成的矩阵视图只保留在 `.artifacts/`，不恢复旧版汇总 JSON 或 CSV。

自动化结果：29 项前端标题测试、16 项宿主标题测试通过；包含相关现有功能的前端计时测试共 64 项，项目与终端适配计时测试分别为 27 项和 37 项，Windows 宿主计时测试共 230 项，均通过。覆盖搜索焦点及工作区切换、失败应答后的 A/B/A 恢复、初始化身份刷新、登记快照复用、路径回退、锁与 UI 应答截止时间、旧请求及窗口销毁。异步测试使用可控事件、Promise 和已到期截止时间，不依赖 sleep 或网络故障。HTML、JUnit 与逐测试计时 JSON 保存在忽略的 `.artifacts/test-stability/`，不提交构建产物或测试报告。

类型检查、Rust 格式、测试稳定性和 Windows 边界检查通过。标准 Windows Release 构建通过，随后完整宿主 Cargo 测试 230 项通过。构建使用脚本支持的独立临时 JDTLS 目录，复用已校验的下载缓存，避免资源准备删除调试进程正在使用的文件；没有修改构建或验证脚本。新增标题回归测试的前端计时为 0 毫秒（Bun 报告精度），原生标题用例最长 29 毫秒，均未达到 1 秒性能警告或 15 秒失败预算。

2026-10-02 初版在 Windows 11 使用当时的 Release 可执行文件和临时样例项目，已验证无文件项目标题、文件树单击不改变标题、打开及切换文件、Markdown 源文件预览、两个同名目录同时追加路径、关闭另一窗口后自动移除路径，以及底部终端聚焦清除文件名、返回编辑器恢复文件名。系统 Alt+Tab 的缩略图标题可见，与原生标题一致。未操作原有项目文件的编辑或保存；任务栏悬停及 Windows 10 仍待验证，功能矩阵保留 `pending`。

2026-10-05 修复后使用独立临时样例和当前调试宿主，实际观察到 `manual-demo – A.txt – Lithe` → 搜索侧栏聚焦时 `manual-demo – Lithe` → 返回编辑器且侧栏保持可见时恢复文件名；再次聚焦搜索并关闭侧栏后也恢复文件名。失败应答和超时分支由可控测试验证，未声称注入真实网络故障或原生 UI 应答故障。此前 Release 的其他实机验收保留为历史结果，本次不把它们视为全部重新验收。

- `bun test src/features/window/utils/window-title-context.test.ts src/features/window/services/window-title-sync.test.ts src/features/window/services/window-title-source.test.ts src/features/window/services/window-title-focus.test.ts`（工作目录为 windows/tauri）。
- `bun run typecheck`（工作目录为 windows/tauri）。
- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml window_title`。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1`。
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`，以及 WindowsRust 计时测试，检查逐测试 HTML/JUnit 报告。
- `./scripts/verify-windows-boundaries.ps1`。
- `node scripts/verify-agent-notes.mjs`。
- `node scripts/generate-platform-feature-matrix.mjs --check`。
- `./scripts/build-windows.ps1 -Configuration Release`，然后运行 Windows 宿主的完整 Cargo 测试。
- `./scripts/verify-runtime-bundle-immutability.sh`；本机没有 zsh，原脚本未运行；已使用脚本原有的两条正则做只读扫描，未发现安装目录写入。不修改校验规则或宣称原脚本通过。
- Windows 实机：打开不同项目与不同目录的同名项目，悬停任务栏并打开 Alt+Tab；切换项目、分屏、文件及工具页；修改别名，关闭项目与窗口，检查其他窗口标题恢复。覆盖独立文件、中文名称、UNC 路径及初始化失败，验收结束清理本次启动的应用。

## 适用范围

- `windows/tauri/src/features/window/utils/window-title-context.ts`
- `windows/tauri/src/features/window/services/window-title-sync.ts`
- `windows/tauri/src/features/window/services/window-title-source.ts`
- `windows/tauri/src/features/window/services/window-title-focus.ts`
- `windows/tauri/src/features/window/hooks/use-native-window-title.ts`
- `windows/tauri/src/workbench-app.tsx`
- `windows/tauri/src-tauri/src/window_title.rs`
- `windows/tauri/src-tauri/src/main.rs`
- `windows/tauri/src-tauri/src/host.rs`
- `shared/platform-feature-matrix/features/windows-taskbar-project-titles.json`
