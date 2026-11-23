# Agent 笔记：Viva 设置属性校验与窗口退出收尾

状态：已实现

## 先说结论

分段控件用各选项声明的名称提供无障碍命中，多行输入与列表行只使用组件支持的属性。控件的名字必须交给实际创建身份的容器或控件；右键菜单沿用目标身份，普通文字、图标和留白不接收名字。窗口循环返回时，工作台直接取消仍然存在的项目并写入恢复草稿。正常关窗时的保存和确认仍在窗口循环内完成。

## 问题

[#2285](https://github.com/1lck/Lithe-IDEA/issues/2285) 在 dev 构建打开设置时触发 Viva 的属性校验。窗口循环被中断后，旧收尾还发起普通项目关闭，把文件检查结果交给已经停止的 OnWake。语言服务器因此没有收到取消，工作台一直在等它退出。

2026-11-23 的严格校验还暴露了另一类旧调用：工作台活动栏在声明右键菜单时传入 `c.Part("menu").KeyInt(i)`，菜单没有使用这个待处理的名字，后面的留白 `Spacer` 因而报错。可选组件提前返回、给文字和图标命名也会留下同样的问题。固定版本的 Viva 文本视图内部也曾给关闭的菜单命名，组织 fork 的同步 PR [#58](https://github.com/Lithe-IDEA/Lithe-viva/pull/58) 已采用上游修复，桌面端固定到包含该修复的 fork `main` 提交。

## 决策

- 外观、背景强度与通用插件分段控件以选项名称命中。运行配置多行输入继续使用框架支持的属性；原来的 `Mono` 没有参与多行输入的排版，删除它不等于实现了等宽编辑。
- 调试器列表行只在获得身份标识（ID）的绘制阶段使用悬停样式。过滤模式行与功能开关行通过 `HitWith` 声明不获取键盘焦点的分组命中，再声明悬停样式；行内按钮、开关和帮助仍各自命中，不增加 Tab 停靠点。
- `Key`、`KeyInt` 和 `Part` 设置的是下一个元素待使用的名字，共用的 `ui.C` 不会因此创建子作用域。名字放在真实容器或控件上；只有容器的 `Children` 才建立其中元素的作用域。先判断可选组件是否可见，再给其真实元素命名，避免提前返回后把名字交给下一个兄弟元素。
- `ContextMenu` 沿用目标身份，不消费新的名字；`Menu`、`MenuAt`、`ContextMenuAt`、`ModalWith` 和 `PopoverWith` 则仅在打开时创建绑定作用域并消费名字，关闭时会直接返回。调用这些可关闭的组件时，先判断打开状态，再按需命名。`Effect` 使用自己的状态与键，不消费 UI 名字。无身份的 `Text`、`Icon`、`Spacer` 等叶子直接使用当前上下文。例如 `ui.ContextMenu(c, button, items)` 是正确写法；不要写成 `ui.ContextMenu(c.Part("menu"), button, items)`，也不要给后面的留白加容器掩盖遗留名字。
- 通用插件视图用 `NodeKey` 值保存声明节点的 ID 或位置，不预先修改 UI 上下文。宿主确认 setting/tool 行可绘制、输入或选择绑定类型匹配后，才把名字交给实际行；label 无身份。这样缺失行或不可用绑定可以直接跳过，不会把自己的名字留给下一个节点。
- 远程主机详情等可选内容先判断非空，再创建具名容器；跳板路由的图标和文本保持匿名。表格的分隔线与数据行分开声明，数据行不因先绘制分隔线而丢失自己的名字。
- 正常关闭经用户确认后进入项目资源释放。窗口循环返回后直接复用资源释放，先取消各项目及其服务器，再等待后台任务。未保存的编辑内容按现有恢复存储规则落盘。
- 退出等待给插件服务器的停止期限留出余量。超过总期限后记录已有的后台失败事件。恢复草稿写入错误在后台写入点记录，提示仍通过界面队列发送。

## 考虑过的备选方案

在窗口停止后主动处理 OnWake 队列会再次运行可能打开弹窗、改动关闭后的视图或启动新任务的回调。直接释放项目资源可以将退出限定为取消任务、写恢复草稿及释放资源。

把 `VIVA_ATTR_CHECK` 设为 `warn`、给空白额外套容器、在应用侧清除待处理名字，都只会隐藏错误调用。因此保持 dev 严格校验并修改声明位置；框架内部的同类问题使用上游已经合入 fork 的修复。

## 后果

项目取消、恢复写入和进程收尾不需要等待下一帧。若后台工作无法在总期限内结束，日志会记录超时，应用继续退出。界面迁移保留原有布局、文字和动作；少量被动分组命中用于恢复原本想表达的行悬停，需要验证其不会接管行内控件。

## 验证

- 在严格 dev 属性校验下运行工作台、设置页及合成插件界面测试。`TestWorkbenchContextMenusKeepButtonIdentityAcrossRepaints` 用真实 Core 与隔离存储检查菜单打开、关闭、窗口缩放后的按钮身份稳定；覆盖深色中文和浅色英文。
- `TestDebuggersPageAppliesAndRestoresAnAdaptersFilters` 检查行悬停绘制、不进入键盘焦点顺序，以及应用、恢复默认和删除模式。视觉用例 `TestVisualWorkbenchStripeContextMenu` 与 `TestVisualSettings` 的调试器悬停场景生成当前实现的截图；调试器场景的数据明确是合成组件输入，不代表已安装插件验收。
- `TestRegionViewSkipsUnavailableNodesWithoutRenamingTheirNeighbors` 用内联合成设置验证缺失行和不匹配绑定，修复前严格校验在后续文本上报告 `Key 0`；`TestRemoteProbeWithoutDetailsKeepsFollowingTextAnonymous` 在空主机详情下复现遗留 `Part "tags"`；`TestRemoteJumpRouteRepaintsWithMultipleHosts` 在多跳路由下复现图标收到 `Key 0`。三者均在修复后通过，并覆盖重绘或后续兄弟元素。运行配置表单的未知控件与多个错误回归由 `TestRunConfigFormOptionalErrorsKeepTheirOwnIdentity` 覆盖。
- 用合成语言服务器覆盖普通项目关闭检查尚未回到窗口线程就结束窗口循环的情况，检查服务器取消、恢复草稿写入和原文件未改动。

## 适用范围

- `desktop/internal/settingswindow/`
- `desktop/internal/pluginview/render.go`
- `desktop/internal/workbench/app.go`
- `desktop/internal/workbench/editor_recovery.go`
- `desktop/internal/workbench/chrome_view.go`
- `desktop/internal/workbench/runconfig_dialog_view.go`
- `desktop/internal/workbench/remote_detail_view.go`
- `desktop/internal/workbench/remote_list.go`
- `desktop/internal/workbench/remote_import.go`
- `desktop/go.mod`
