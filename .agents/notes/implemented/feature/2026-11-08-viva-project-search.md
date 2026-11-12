# Agent 笔记：Viva 项目与全局搜索的索引和取消边界

状态：已实现

## 先说结论

Viva 的项目搜索侧栏调用 Rust Core 搜索本地工作区，而不是在 Go 界面里复制匹配、
正则或文件掩码规则。输入变化经过 250 毫秒合并；同一项目最多运行一个查询，
新输入会取消旧查询并在其结束后执行最新请求，迟到结果不能覆盖新查询。

## 问题

搜索索引会缓存文件列表和内容索引；如果文件在外部新增或修改，而宿主没有发送
变更，继续使用旧索引可能漏掉实际匹配。递归监听的注册、事件丢失、关闭和取消
都必须与索引更新的生命周期配合。

## 决策

首次搜索在后台注册 Viva 递归监听并使索引失效，覆盖注册前的变化；后续查询
复用 Core 索引。监听事件先交给 Core 过滤，再由 Core 增量更新；过滤后超过 512
条、原生事件丢失或待处理事件超过 4096 条时，改为失效后重建。原生监听报告
事件丢失时先重新注册，避免重建后继续使用已失效的监听。注册失败会记录日志并
提示用户，后续每次查询重建索引，用户可手动刷新。刷新按钮始终强制重建。
关闭搜索面板时释放监听，重新打开后重新注册；关闭项目时等待已在运行的搜索
结束，再异步释放 Core 索引。文件匹配、内容匹配、掩码、大小写、整词及正则
均由 Core 决定。结果列表虚拟化，最多展示 200 项，达到上限时提示缩小范围；
点击内容结果会打开文件并跳到对应行，输入法组合期间不强行移动光标。

全局搜索复用 Core 的 `workspace.searchEverywhere`，按 50 条分页并保留 Core
排序、打开文件的同分优先级与不透明游标；“全部”和“文件”查找文件名，“文本”
查找内容。结果上限为 500 条并提示缩小范围；用户可以加载下一页，重复游标或
不产生新结果的续页会停止并记录失败。弹层关闭或输入改变会取消过期请求；
输入法组合期间不截获回车、方向键和 Escape。项目搜索和全局搜索按需共享一个
递归监听，各自维护待处理事件和取消代次；最后一个消费者关闭后释放监听。

查询拥有项目的取消上下文和 30 秒截止时间。用户切换项目、关闭搜索面板或输入
新查询时，不发布已过期结果；搜索结果的相对路径在打开文件之前再次检查是否
越出工作区。项目关闭后异步释放 Core 索引，避免跨项目累积内存。界面只展示
失败状态并记录目录事件，不把用户的查询正文写入日志。

## 考虑过的备选方案

- 一直复用现有索引而不接文件监听，会在外部编辑后产生静默漏报，不能采用。
- 每次按键并行启动新查询会积累索引构建任务，浪费资源并可能发布旧结果；采用
  输入合并、取消和单查询串行。

## 后果

结果显示后，收到文件变化事件会自动刷新；通知存在系统固有的投递延迟。
2000 个小文件、三次运行的本机基准中，复用索引约 4.4 毫秒/次，重建约
132 毫秒/次；这只是受控样本，不代表大型真实工作区。Linux 递归监听需要为
目录分别注册，超出上限时会退回手动刷新。项目替换、完整原生搜索外观和
各平台实机验收尚未完成，不能把该侧栏当作旧客户端搜索能力完全迁移。
全局搜索的类、符号和操作入口尚未接入，暂时禁用；双击 Shift、预览、筛选、
匹配高亮、自动续页与完整视觉对齐仍未完成。
同样使用 2000 个小文件、三次运行的全局文件名搜索基准，复用索引约 28.2 毫秒/次，
失效重建约 47.2 毫秒/次；结果包含 Core 排序与第一页 JSON 传输，不代表真实大型
项目或界面端到端延迟。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core -run TestWorkspaceSearchUsesCoreOptionsAndRefreshesChanges`：实际 Core 搜索、过滤和增量更新。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run TestProjectSearch`：界面输入、选项、结果跳转、原生监听外部变化、索引复用、刷新和过期查询串行。
- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/workbench -run TestEverywhere`：共享排序 fixture、分页、选择打开、文本变化监听、输入法组合和过期请求。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run TestSearchPanels`：两个搜索界面共享监听并在最后一个消费者关闭时释放。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^$' -bench '^BenchmarkWorkspaceSearchIndex$' -benchtime=3x`：索引复用与重建开销。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^$' -bench '^BenchmarkEverywhereSearchIndex$' -benchtime=3x`：全局文件名分页的索引复用与重建开销。
- Windows Server 2022 上实际执行 Viva `internal/filewatch` 的交叉编译测试二进制，递归监听新建、移动、重命名、删除和事件溢出测试通过；受系统限制的监听中删除目录测试跳过。这只验证原生监听组件，尚未验证 Windows 的完整搜索界面及 Core 接线。
- 原版 macOS 搜索窗口和 Viva 无头界面已截图对照，输入框按原版组合搜索图标、清除和选项按钮；Viva 仍缺项目替换入口、结果的两行预览及其他整体布局细节，尚未逐像素验收。
- 原版 macOS 全局搜索和 Viva 无头弹层已截图对照，确认基础尺寸、背景、焦点边框和选中行；匹配高亮、预览、筛选与完整逐像素验收仍待完成。

## 适用范围

- `desktop/internal/core/workspace.go`
- `desktop/internal/workbench/search.go`
- `desktop/internal/workbench/search_everywhere.go`
- `desktop/internal/editorview/view.go`
