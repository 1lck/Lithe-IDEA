# Agent 笔记：Windows Agent 连接所有权与输入框草稿

状态：已实现

## 先说结论

Windows Agent 面板的一次启动只对应一个 ACP 进程，进程身份由「工作区 + Agent + 认证方式 + 自定义命令与参数」共同决定；任一项变化都必须先停掉旧进程再重连，不能继续把消息交给旧 Agent。同一时刻只允许一个启动承诺，停止操作会等待这次启动落地。断连时除了结束计时，还要清掉附着、忙碌、取消、配置等待和权限队列，否则重连会跳过会话恢复、发送被旧状态挡住。输入框草稿和附件归面板所有，设置页或历史页往返不再丢失；切换 Agent 时各自的可见会话按连接身份保留，切回后重新加载。

## 问题

第 7 期 UI 重做之后，连接生命周期按“新增功能”接上，但原来的模型只覆盖单次、串行使用，以下路径都会出问题：

- 断连只调用 `finishActiveTurn` 把计时收尾，`isAttached`、`isResponding`、`isCancelling`、`pendingConfigToken` 和 `pendingPermissions` 全部保留。重连后 `prepareConversation()` 看到旧 `isAttached=true` 就跳过恢复，下一条 prompt 直接使用未加载的会话。
- `connect()` 在 `transport.open()` 尚未返回时 `this.connection` 仍为 `null`，两次调用会各开一个进程；后完成的覆盖前一个句柄，另一个进程和事件监听留到窗口销毁。
- 连接复用只比较工作区。设置里把 Codex 换成 Claude、或把 API Key 换成订阅后，界面和历史标注已经是新 Agent，消息仍走旧连接。
- 设置页与历史页用提前返回渲染整页，`AgentComposer` 被卸载，`draft` 与 `files` 跟着丢失。
- `addFileReferences()` 放在 `setFiles` 的函数式 updater 里，React 可能在渲染阶段重放 updater，外层的 `try/catch` 接不住附件上限异常。

## 决策

- `connect()` 用一个 `connectPromise` 去重：第二个调用直接加入进行中的启动。真正的启动逻辑移入私有 `openConnection()`，`stale` 仍由停止路径设置，启动完成发现 `stale` 时自行关闭刚打开的进程。
- `stop()` 同时等待 `connection !== null` 的旧连接和进行中的启动承诺，并在等待期间占据 `closePromise`，使并发 `connect()` 得到“仍在停止”的明确错误。
- 断连清理统一在 `detachConnection()` 完成：结束计时、把未完成工具标为 `interrupted`，并把附着、加载、响应、取消、配置等待和权限队列全部清空；消息、轮次统计和 `hasCompleteHistory` 保留，因为它们属于用户可见的历史，而不是进程状态。
- 编辑区与侧栏同时请求相同连接身份时，共用同一个启动结果，两个调用者都在身份登记后得到完成通知；不同身份才取代旧请求。
- 启动与停止共用串行队列，并用请求代次丢弃已被取代的启动。旧启动已经创建进程时，必须等待关闭它后再执行新请求；不能只跳过身份登记，否则新 Agent 会复用旧进程。停止也进入同一队列，避免紧随其后的重连越过清理。
- 连接身份用 `launchKey(workspace, agentId, authentication, command, arguments)` 表示。工作区或身份变化时先 `stop()`、再 `reset()`、再重连；失败启动不写入身份，下次设置变化仍会重试。
- 切走前用 `captureSnapshot()` 保存当前可见状态，切回时 `restoreSnapshot()` 放回。恢复会清掉全部进程相关标记，`prepareConversation()` 因此走 `loadSession` 重新附着，用户看到的仍是原会话；工作区切换清空全部保留状态，避免跨项目串台。
- 发送条件包含 `pendingConfigToken == null`：会话设置还在确认时不接受新消息，界面沿用「准备中」提示。
- `draft` 与 `files` 由 `AgentPanel` 持有并提升到 `agent-surface.store`，`AgentComposer` 改为受控组件；第 11 期起工具窗口与编辑区标签共享同一份按会话保存的草稿。
- 附件校验在事件处理阶段先算出结果，成功后再写入状态；上限错误只显示提示，不改动原有草稿与附件。

## 考虑过的备选方案

- 只在 `connect()` 入口加锁，不处理 `stop()`：实现更小，但停止仍可能在其他线程启动完成前返回，进程存活时间不可控。
- 让连接跨 Agent 复用快照：能省一次重启，但会用新 Agent 的界面显示旧 Agent 的消息；逐 Agent 保留会话是第 4 期 `agent-connection-model-switching` 的范围，当前只做身份隔离。
- 让对话页常驻挂载、用 `hidden` 隐藏：改动看似更小，但面板布局、焦点和滚动的生命周期会变得不可预测。
- 保留 updater 内校验，仅把异常换成返回值：仍会在渲染阶段执行副作用，问题只是被推后。

## 后果

- 切换 Agent 或认证方式仍会重启进程，但各 Agent 的可见会话以连接身份为键保留，切回后重新加载；工作区切换会清空全部保留状态。
- `stop()` 可能比过去多等一次启动完成的耗时，换取“停止返回即无存活进程”。
- 输入状态提升到窗口级放置状态后，关闭侧栏或把对话移动到编辑区都不会清空未发送草稿；工作区切换才清空。
- 跨 Agent 模型同步仍缺，继续由功能矩阵跟踪；编辑区放置由 `2026-10-18-windows-agent-conversation-editor-placement.md` 承接。

## 验证

- `windows/tauri`: `bun run typecheck`。
- `windows/tauri/tests/agent-connection-service.test.ts` 在独立 Bun 进程验证启动中切换 Agent、认证方式、停止后立即重开；使用可控启动承诺，不依赖真实进程或计时等待。
- `src/features/agent/stores/agent-connection.model.test.ts` 新增五条确定性测试：并发启动只开一个进程、启动中停止会关闭该进程并回到 `idle`、断连清空附着/忙碌/权限状态、快照恢复保留消息但清空进程状态、恢复后的会话先 `loadSession` 而不是直接 prompt。
- CI 同款 Agent 套件（`src/features/agent`、`src/config/backend-capabilities.test.ts`、`src/i18n`、拖放路由与图标测试）通过。
- `bun run build` 成功，PHP 隔离正则 `intelephense|vendor/bin/phpunit|composer:` 在 `dist` 中零命中。

## 适用范围

Windows Tauri 前端 Agent 面板及其连接服务。macOS 的对应行为由 `AgentConversationView`/`AgentConversationModel` 自主实现，本笔记不改变其契约；共享 host 与 ACP 进程管理未改动。
