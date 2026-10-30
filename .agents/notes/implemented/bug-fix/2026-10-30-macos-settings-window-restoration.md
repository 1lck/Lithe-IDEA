# Agent 笔记：系统恢复设置窗口时补齐会话绑定

状态：已实现

## 先说结论

macOS 可以直接恢复上次打开的设置窗口，不会重新执行用户点击“设置”的命令。
设置窗口必须在自己的宿主出现时补齐缺失的会话绑定，才能显示完整内容。
已有有效绑定继续属于原来的项目；关闭回调必须同时校验会话与本次打开的绑定令牌，避免旧窗口清除新窗口。

## 问题

[Issue #1599](https://github.com/1lck/Lithe-IDEA/issues/1599) 的现场是电脑重启后 Lithe 恢复出一个持续空白的窗口。
系统日志确认恢复标识为 `settings`，无障碍树只有原生窗口按钮，主线程仍正常处理事件。
在无源码修改的 preview 构建中，打开设置、退出并保留窗口、重新打开连续三轮均复现；显式再次打开设置立即恢复内容。
这三轮是应用退出与重开，不代表做了三次整机重启。

`ProjectSessionManager.settingsModel` 只在显式设置命令中绑定，进程重启后为空。
原来的 `SettingsWindowHost` 只有模型存在时才创建内容，因此系统恢复场景时连能够处理出现事件的视图都没有。

## 决策

- `SettingsWindowHost` 始终保留一个真实的容器，在出现事件中调用会话管理器准备绑定；视图求值只读取状态。
- 准备入口是幂等的：已有仍在管理器中的同一个模型时保持绑定和草稿；没有有效绑定时使用当前有效会话。
- 显式设置命令仍决定设置属于哪个项目，切换项目焦点不替换已打开设置的上下文。
- 每次新绑定生成独立令牌。关闭和释放同时检查会话 ID 与绑定令牌；只有当前绑定的释放才能清除模型和“设置已打开”状态。
- 内容视图离开时只丢弃自己的插件草稿，再请求带令牌的释放；不能先无条件修改共享会话的呈现状态。

正确做法：系统恢复空的设置场景，宿主出现后建立绑定，再绘制真实设置内容。
不要在视图 `body` 求值时绑定模型，也不要让旧内容的消失回调只凭会话 ID 清除新绑定。

本次没有增加持久化数据或运行时资源路径。绑定由进程内的会话管理器持有，窗口关闭后释放；
应用包只读，既有偏好与缓存继续由平台适配器管理，不影响代码签名或 Sparkle 增量更新基线。

## 考虑过的备选方案

- 禁止系统恢复设置窗口：能够避开空白，但丢失用户希望保留的窗口连续性，因此保留正常恢复。
- 应用初始化时总是绑定设置模型：窗口从未打开也会保留绑定，混淆真实呈现状态；只在宿主出现时准备。
- 给 `nil` 模型画一个静态提示：能解释空白，却仍要求用户手动重新打开，没有完成设置恢复。
- 关闭时仅比较模型 ID：同一模型可以多次打开设置，旧内容的回调仍可能清除新窗口，必须比较本次绑定令牌。

## 后果

用户重开应用时能够继续使用系统恢复的设置窗口，显式打开和系统恢复共享相同的绑定规则。
代价是宿主和会话管理器共同承担一个呈现生命周期入口，新增关闭或释放路径时必须传递正确的绑定令牌。
设置窗口继续允许强持有其原始项目模型；项目资源退出的清理仍按既有会话退出规则执行，不转交给窗口恢复。

## 验证

- `SettingsWindowRestorationTests` 覆盖初始无绑定、重复准备不生成新令牌、关闭后重开、失效会话替换以及同一会话的旧回调。
- 原生宿主测试挂载真实 `SettingsWindowHost`，以有两秒本地期限的无障碍边界检查实际搜索控件；同时覆盖浅色和深色，以及移除后重新挂载。
- `settingsStayBoundToOpeningSessionUntilAnotherSessionReopensThem` 继续验证跨窗口焦点切换保留显式设置归属。
- 运行 `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'SettingsWindowRestorationTests|settingsStayBoundToOpeningSessionUntilAnotherSessionReopensThem|closingDedicatedProjectRevokesHiddenPageWhileSettingsRetainsItsModel'`，检查逐项计时报告。
- 运行 `./scripts/macos/test/test-macos.sh`、`./scripts/architecture/verify-service-boundaries.sh`、`./scripts/macos/verify/verify-runtime-bundle-immutability.sh` 和 `./scripts/agent-notes/verify-agent-notes.sh`。
- 真实应用保留窗口后重开三轮，对照恢复日志、搜索输入框、取消/确认/标题栏关闭及再次打开；区分应用重开与整机重启。

## 适用范围

- `macos/Sources/Lithe/LitheApp.swift`
- `macos/Sources/Lithe/Models/Workspace/ProjectSessionManager.swift`
- `macos/Tests/LitheTests/SettingsWindowRestorationTests.swift`
- `shared/platform-feature-matrix/features/application-settings.json`
