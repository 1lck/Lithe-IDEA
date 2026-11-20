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
结束，再异步释放 Core 索引。内容匹配、掩码、大小写、整词及正则均由 Core
决定。读取预算来自“工具 → 搜索”的真实用户偏好，默认 16 MiB，可设置 1–64 MiB；
替换缺省继承搜索预算。64 MiB 是当前解码和原生 I/O 安全边界，不能宣称支持无限文件。
Core 按编辑器的自动编码识别解码，允许 ANSI escape，保留二进制控制字符检查；
CRLF 行尾的 `\r` 不算行内容。

项目搜索只列内容行，按 50 行自动续页，同一文件也可跨页。Core 根据已加载结果
返回文件分组和折叠投影；界面只渲染投影，显示“已加载”的行数和文件数，不能把
它当成完整匹配总数。项目、模块（来自已加载构建模型）、目录和自定义范围均使用
Core 解析的路径/glob 表达式；没有模块模型时不执行模块查询。包含 Git 忽略文件
是请求选项，不能绕过手动排除和结构隐藏。

交互式项目分页与全局文本搜索使用同一冷查询策略：已有全文索引时复用，否则
直接枚举文件并匹配当前页，不等所有文件建立三元组倒排表后才显示首屏。
旧侧栏在首次查询时强制构建全文索引，导致同一查询比双 Shift 明显更慢；
不要把主动预热或旧同步消费者的索引构建放回交互式分页的必经路径。
文件标题与命中行统一为24pt，文件名只在标题显示一次，命中行缩进并对齐
行列号与正文。两种搜索结果的正文高亮均使用主题的13pt界面字体，避免与文件名
切换字体；编辑器预览仍遵循编辑器自己的字体设置。
全局搜索的类别称为“类型”，包含语言服务报告的类、枚举、接口和结构体，
“符号”保持其他声明；Go 等语言不再被 Java 的“类”文案误导。

宿主在 UI 线程捕获脏文档的不可变 rope 根，在后台生成文本交给 Core。快照加入
候选并替换磁盘文本；后续页复用同一快照，编辑变化取消并重查，查询不写盘。
全局搜索“全部”合并正文来源；名称匹配增加有序片段和低分跳字母匹配，但未完整
复现 IDEA MinusculeMatcher。项目搜索取消 200 条总上限，全局搜索取消 500 条总上限，
按滚动需要追加页；失败保留已加载页并暂停，用户重试后继续。

替换先显示预览，确认才修改。磁盘预览绑定原始字节的 SHA-256，宿主重读核对后，
由 Core 解码、替换、按原编码和 BOM 编码，再原子条件写入；保留 CRLF。编辑器文档
按版本验证后执行一次可撤销修改，预览后才打开的文件跳过，避免覆盖新文档。

搜索偏好来自平台 preferences 目录的 `search.json`；打开只读，Apply/恢复默认才
条件写回并回读。外部冲突保留草稿，用户刷新后才能再次应用。无关 JSON 字段保留。
查询、分组、默认值和验证在 Core，平台只负责文件 I/O、不可变编辑快照和界面。

查询拥有项目的取消上下文和 30 秒截止时间。用户切换项目、关闭搜索面板或输入
新查询时，不发布已过期结果；搜索结果的相对路径在打开文件之前再次检查是否
越出工作区。项目关闭后异步释放 Core 索引，避免跨项目累积内存。界面只展示
失败状态并记录目录事件，不把用户的查询正文写入日志。

## 考虑过的备选方案

- 一直复用现有索引而不接文件监听，会在外部编辑后产生静默漏报，不能采用。
- 每次按键并行启动新查询会积累索引构建任务，浪费资源并可能发布旧结果；采用
  输入合并、取消和单查询串行。
- 在冷分页之前强制建立全文索引会读取所有候选两次，增加首屏延迟和常驻倒排表；
  使用现成索引或文件清单直接匹配。低命中查询仍需读完可搜索文件，不保证常数时间。
- 项目搜索继续列出文件名匹配、只是排在内容行之后：Core 先收集文件名匹配，文件名
  含查询词的文件一多就占满 200 条上限，内容行一条都不剩；IDE 的 Find in Files
  也不列文件名，查文件名用全局搜索的“文件”。被否。

## 后果

结果显示后，收到文件变化事件会自动刷新；通知存在系统固有的投递延迟。
Linux 递归监听需要为目录分别注册，超出上限时会退回手动刷新。
首屏发布后独立统计全部文件、匹配行和出现次数；只返回当前加载文件的计数明细，
避免把全项目路径传到界面。计数显示进行中/失败与重试，查询、文件和脏文档变化
立即取消旧统计，关闭项目等待统计退出再释放索引。

两个搜索入口提供包含 Git 忽略、插件生成目录和工作区内部符号链接的一次性选项。
手动排除仍优先；外部链接不自动遍历，需要单独打开工作区根。Core 检查规范目标、
祖先循环和目标排除，保留别名路径；替换按规范路径去重。原生目标事件使链接索引
重建，保存使其失效；项目树可展开内部链接，已展开别名在目标事件到达时重新读取。

类型/符号搜索按已启用清单的文件选择器发现项目语言，再启动相关语言服务，不要求
先打开文件。晚到的就绪事件只补问尚未查询的服务，保留其他服务答案；关闭面板、
换查询会取消操作和截止计时器，过期排名结果不能覆盖新结果。语言语义完全来自
标准 workspace/symbol，不维护 Core 语言解析器或第二份符号索引。类型包括 Class、
Enum、Interface、Struct，其余作为符号。界面字体统一为13pt，侧栏24pt行高与图标列对齐。

类型/符号只保留定义在项目目录内的结果，标准库、SDK 和第三方依赖不显示；用户
搜不到依赖里的名字时容易误判为语言服务没启动，所以两个页签后各放一个 ⓘ，说明
列出哪些种类、范围和对语言插件的依赖。上面的文件类选项只作用于 Core 的文件和
内容搜索，到不了语言服务结果，这两个页签因此不显示筛选按钮，避免出现无效选项。
包含依赖等非项目结果需要 Core 和桌面端一起扩展，不在当前实现范围内。

实现覆盖 #2199 的列举场景，不声称完全等价于 IDEA 所有匹配质量和外部库能力。
两端原生窗口和输入法验收仍须在目标平台完成，不能由无头截图替代。
名称匹配的宽松规则限于 Search Everywhere，通用 `rankNames` 保持原有边界匹配，
避免插件市场等现有候选列表出现额外结果。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core -run TestWorkspaceSearchUsesCoreOptionsAndRefreshesChanges`：实际 Core 搜索、过滤和增量更新。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run TestProjectSearch`：界面输入、选项、结果跳转、原生监听外部变化、索引复用、刷新和过期查询串行。
- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/workbench -run TestEverywhere`：共享排序 fixture、分页、选择打开、文本变化监听、输入法组合和过期请求。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run TestSearchPanels`：两个搜索界面共享监听并在最后一个消费者关闭时释放。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^$' -bench '^BenchmarkWorkspaceSearchIndex$' -benchtime=3x`：索引复用与重建开销。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^$' -bench '^BenchmarkEverywhereSearchIndex$' -benchtime=3x`：全局文件名分页的索引复用与重建开销。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^$' -bench '^BenchmarkWorkspaceColdContentSearch$' -benchtime=3x`：通过 `LITHE_SEARCH_BENCH_ROOT` 显式选择真实工作区，安装工作台同样的 Git 忽略策略后对比两种冷内容查询。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'TestProjectSearchReadsUnsavedTextAndAllSearchesContents|TestProjectReplacePreservesOriginalEncodingAndRejectsChangedPreview'`：脏文档/All正文及五种编码替换、外部改动保护。
- `scripts/desktop/desktop-go.sh test ./internal/settingswindow ./internal/searchprefs -run 'TestSearchPage|TestSearchPreferences'`：真实来源读写、应用、回读及冲突。
- `scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/workbench ./internal/settingswindow -run '^TestVisualSearch(Results|Preferences)$'`：明暗主题和中英文截图，需指定 `LITHE_VISUAL_OUTPUT_DIR`。
- 组件测试与无头截图不替代两端原生窗口、大型真实项目和输入法验收。

## 适用范围

- `desktop/internal/core/workspace.go`
- `desktop/internal/workbench/search.go`
- `desktop/internal/workbench/search_everywhere.go`
- `desktop/internal/editorview/view.go`
