# Agent 笔记：Viva 的 Java 插件准入——settings 2、输出链接、TCP 调试与 run 宿主服务

状态：已实现

## 先说结论

`pluginhost.Declared()` 现在声明 `settings` 2、`debugAdapters` 1–3 和 `outputLinkMatchers` 1；Java Support 清单经 Core 校验只剩 `projectGenerators` 1（另一条车道）。Core 仍然算规则（输出链接匹配、run 启动参数校验、调试端点与启动参数、传输截止时间），Go 只做进程、套接字、I/O 和绘制。

## 问题

Java Support 的插件清单要求宿主提供 `settings` 2、`outputLinkMatchers` 1、`debugAdapters` 3 等能力；Viva 宿主此前没有声明这些能力，Core 校验清单时会拒绝安装或启用 Java Support。要声明它们，宿主必须真的实现对应行为：输出链接、`run/start` 等运行宿主服务、经语言服务器取端口的 TCP 调试和远程 attach，同时不能把 Core 已有的规则在 Go 里重写一遍。

## 决策

- **settings 2**：动态页、作用域（global/project）、生效路由（restart/immediate/reload，nextRun 在每次运行前重读设置所以无需动作）、页面按钮此前已实现，这次核对后声明。
- **输出链接**：`pluginservice.OutputLinkSources` 读取已启用插件的 `outputLinkMatchers`；`workbench/outputlinks.go` 对屏幕上出现的行向 Core 的 `outputLinks.match` 批量询问（每批 ≤256 行、按 scope 分组），结果按行文本缓存，绘制只读缓存、没有答案的行下一帧补上。链接范围是 UTF-16 偏移，绘制时按它切分。点击：`location` 取第一个存在的候选文件，`resolve` 调插件后端函数并交给 `outputLinks.decodeResolution` 校验，再打开文件并定位。Build 输出和 Test 输出用 `run` / `test` scope，运行视图用 `run`。
- **run 宿主服务**：`pluginservice.Runs` 注册 `run/start`、`run/stop`，进程结束时发 `run/didExit`，只发给发起这次运行的那个后端会话（后端重启后不会收到没见过开始的运行的退出）。启动参数由 Core 的 `run.decodeStart` 校验，Core 拒绝映射为 `plugin.host.invalidParams`，Core 的 code/field 放在 details。`tool` 可执行文件经窗口提供的 `RunToolResolver`（与 Build、Debug 相同的工具链层）解析，`packaged` 文件经 `pluginhost.ResolveExecutable` 对已安装包校验。临时文件写在系统临时目录，运行结束删除，不写 app bundle 或安装目录。运行用现有 `buildprocess`，输出进入 Build 面板里的运行视图（切换条 + 停止/再次运行）。关闭项目停止该工作区的运行，应用退出 `StopAll`。
- **调试目标**：`run/start` 的 `debug.target` 为 `connection` 时，宿主等回环端口打开（30 秒上限，进程先退出则放弃），再让窗口附加 `configurationType` 对应的适配器；附加失败会停止运行并把原因写进运行输出。`launch` 目标暂未支持，返回 `plugin.host.unavailable`。`debug/start` 未实现。
- **tcpLanguageServer**：适配器没有自己的进程。宿主先启动插件对应语言的服务器（与编辑时相同的路径），等它就绪，用 `workspace/executeCommand` 发 `endpoint.command`（宿主自己的请求，走 Core 的语义请求，不经过插件会话策略），把整数或数字字符串的结果当作 1–65535 的回环端口，连接后与 stdio 共用同一套 `debug.createSession`、断点、launch/attach 流程。截止时间取自 `debug.transport.policy`：命令用发现期限，连接用连接期限，每次写用写期限，`initialize` 用 Core 给的初始化期限（超时后会话以“调试适配器没有及时响应”结束）。Stop、关闭项目会取消每一步并关闭连接，不终止共享的语言服务器。
- **适配器特性与默认值**：启动计划的 `debugAdapter` 描述符里的 `disabledCapabilities`、`features`、`defaults` 原样传给 `debug.createSession`，宿主不按适配器 ID 区分。
- **远程 attach**：只有 attach 的适配器在 Debug 面板显示主机/端口表单（主机为空表示本机）。`debug.adapters.startArguments` 返回的 `connection.remote` 由 Core 判定，非本机端点先显示确认条，确认只对这一次启动有效；本机端点不询问。

## 考虑过的备选方案

- 只取 `debug.transport.policy` 的数值、在 Go 里自己执行截止时间：已被否决并替换。现在语言服务器托管适配器的 TCP 流由 `debug.transport.handle` 的生命周期驱动（`workbench/debug_transport.go`）：帧先入队、同时只有一个写在途，发现/连接/写入/排空期限都是 Core 下发的定时器，每个事件带宿主捕获的 generation，过期回调被 Core 忽略；用户停止走 `finishSendingAndStop` 有界排空。代价是每次写多一次 Core 往返，换来各平台共用一套写队列和失败规则。
- 让 `run/start` 的运行进入新的 Run 工具窗口：需要新增目录项、图标与布局；先复用 Build 面板的输出区。

## 后果

- Java Support 不再因宿主能力缺失被拒绝；新增的宿主能力其他插件也能使用，不需要按插件 ID 特判。
- 输出链接、run 启动参数、调试端点与传输期限的规则只在 Core 一处，Go 端改动不会让各平台行为分叉。
- 运行输出暂时复用 Build 面板；`debug/start` 已接（`pluginservice/debug_start.go`，宿主由窗口启动该插件自己的适配器，配置覆盖适配器声明的默认参数），launch 目标没接，插件调用会收到 `plugin.host.unavailable`。

## 已知缺口

- `debug.target: launch`、launch.json 导入、`tcpPort` / `tcpAnnounced`（插件进程托管）、远程 attach 的路径映射输入。
- Build 输出区只在检测到构建系统后显示；运行视图不受影响。
- 运行视图和 Debug 表单已在 Page 迁移中改为 Viva Page（`workbench/runpanels.go`；工作台根窗口改为一个 Page 后它们是根 Page 调用的组件，见 `2026-11-10-workbench-root-page-and-viva-upgrade.md`）。

## 验证

- `desktop/internal/core/output_links_test.go`、`run_start_test.go` 重放契约 fixtures。
- `desktop/internal/pluginservice/runs_test.go`：真实 Core 校验、真实进程、停止、拒绝、端口等待与附加。
- `desktop/internal/workbench/debug_tcp_test.go`：同一个夹具 DAP 适配器经回环 TCP 运行断点、暂停、继续、停止，覆盖对端关闭、不可达端点、端点命令失败、initialize 超时、等待端点时取消、关闭项目、远程确认。
- `desktop/internal/workbench/outputlinks_test.go`：点击链接打开文件并定位，缺失文件只提示。
- 设置 `LITHE_JAVA_PLUGIN_MANIFEST` 后 `TestJavaSupportManifestOnlyLacksOtherLanesCapabilities` 只剩 `projectGenerators 1`。

## 适用范围

`desktop/internal/pluginservice/`（runs、outputlinks、languagecommand、debug）、`desktop/internal/pluginhost/`、`desktop/internal/core/`（output_links、run_start、debug_launch）、`desktop/internal/workbench/`（debug_start、runs、outputlinks、build_view）。
