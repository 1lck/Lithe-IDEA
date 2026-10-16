# Agent 笔记：调试变量的 JSON 与树形查看

状态：已实现

## 先说结论

Threads & Variables 默认用格式化 JSON 展示当前暂停栈帧的变量，标题右侧按钮切换回原来的树形视图。
JSON 是从调试适配器的字段生成的只读快照，不是对目标程序执行序列化，也不承诺等同业务接口的 JSON。
大对象、循环引用或不可用字段以 `$lithe` 标记说明，不假装已经完整读取。

## 问题

多层对象和列表需要反复展开才能找到末端值。仅复制调试器返回的 `User@123` 摘要，无法得到完整字段。
调用目标进程中的序列化库或 `toString()` 又可能执行用户代码、改变状态或卡住暂停会话。

## 决策

继续复用现有调试适配器协议（DAP）的 `variables` 请求，字段、类型和对象引用仍归上游调试器所有。
`GenericDebugFeatureModel` 提供快照入口，独立投影器负责读取、编码和限制，不改树的展开状态与分页缓存。
根变量沿用当前已加载的作用域；根列表未加载完时明确提示切树加载更多。
仅在 JSON 可见时发起读取。切回树、离开页面会取消任务；恢复运行、切换会话、栈帧或作用域后拒绝旧结果。

快照按路径上的对象引用识别循环，不将两个字段引用同一个对象误判为循环；同次快照缓存已读字段，减少重复请求。
只有子项全为连续数字索引时投影成数组，否则保留字段对象。不可展开的摘要保留为字符串，不解析 `toString()` 伪造结构。
标准字符串、布尔、空值和可准确表示的数字按 JSON 类型编码，超过精确整数范围的值保留文本，避免丢位。
重复字段名以 `#2` 等后缀保留，诊断字段也避让实际的 `$lithe` 字段。它们是查看器标记，不是业务序列化契约。

读取上限为10层、1000节点、每容器100字段、单值4096字节、最终512000字节。
总读取在10秒后不再发起新请求，每个在途请求最多3秒，所以最后一个请求可能延长到总计约13秒。
取消和超时都只结束当前快照的等待，不调用取消整个调试会话的接口，以免影响 Watches 等检查。
正确示例是“读取暂停对象字段 → 生成有限快照 → 用户复制”；不要“在目标里求值序列化表达式 → 当作无副作用读取”。

调用栈采用紧凑单行和共享13pt Regular UI字体。按用户要求接入编辑器语法配色：已知Java标签中的方法名使用functionCall角色，行号与其他词法片段复用现有DiffSyntaxHighlighter，右侧源码名仍为共享灰色。
文字颜色、图文间距、水平缩进和最低行高使用 `LitheTheme.Tree`，选中和悬停继续由 `litheSelectionRow` 负责。
线程选择器右侧的小设置按钮通过 `LitheMenu` 打开唯一的“显示源码文件名”勾选项，默认开启（用户指定，区别于IDEA默认）；开启后将已知源文件名单独放在同一行右端，使用共享次级灰色；方法/类名保持主文字色。
设置为当前视图状态，不修改适配器标签或目标程序；没有源码时保持原标签。
按钮复用已有 `expui/general/settings.svg` 及暗色变体和共享工具栏样式，Variables标题底部不绘制横线。
依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 Java专用渲染链：
`JavaStackFrame` → `JavaFramesListRenderer` → `StackFrameDescriptorImpl`；普通Java栈帧的图标为 `EmptyIcon.ICON_16`，因此不固定绘制通用 `Debugger.Frame`。
`ThreadsViewSettings.SHOW_SOURCE_NAME` 默认关闭，`calcRepresentation` 开启时同一行追加源码名称。Lithe根据用户要求改为左右两栏，区别于上游连续拼接标签；
`JavaFramesListRenderer` 对方法与类名使用同一普通文字属性，包名可用灰色斜体，递归计数及用户标记有单独样式。
Lithe当前契约没有完整语义分段或过期帧状态；只识别带有实际行号后缀的Java方法标签，未知格式保留原文字与基础词法高亮，已有过滤帧入口继续保留。
开启源文件名时，仅去掉与Java源文件去扩展名后完全相等的末尾类名标签；关闭开关则保留原标签，内部类、不同类名与未知格式不改写。复制和适配器状态仍使用完整原始标签。
这是用户指定的Lithe语法高亮与去重，不宣称为IDEA默认的普通调用栈配色。

JSON展示为逐行高亮的只读内容，对象与数组的起始行增加共享16pt箭头按钮；默认展开，点击收起为 `{ … }` 或 `[ … ]`。
折叠仅作用于当前快照的展示行，不修改原始JSON或树形展开状态；复制按钮始终复制完整快照。
父段收起后保留子段的折叠状态；快照更新时清空旧行号，避免折叠错误字段。
折叠范围只识别本投影器 `JSONEncoder.prettyPrinted` 的独立容器行，不引入任意JSON解析器；
字符串中的括号已由编码器引用或转义，不作为边界。若以后接收任意外部JSON，应改用成熟编辑器提供的折叠范围。
线程选择器不再用内部Spacer拉长按钮；箭头紧跟线程与状态，剩余标题栏宽度留给空白和右侧设置按钮，长线程名单行中间省略。

Variables与Watches由 `LitheSplitPaneView` 纵向分隔，各自独立滚动；默认Watches占剩余检查区28%，双方保留最小可用高度，拖动结束才提交当前视图高度。
Add/Edit Watch复用 `LitheCenteredPopup`，相对所属窗口居中，内容复用共享菜单表面、输入框和按钮；不再锚定“＋”按钮。
Console原生滚动容器保持透明，让已有 `litheWorkbenchSurface` 统一主题色与壁纸处理，IDEA文本配色不再覆盖固定背景。
`breakpoint` 是适配器报告的暂停原因，保留状态说明，不属于日志输出。

JSON折叠按钮按用户要求仅在对应整行hover时显示（包括折叠后的展开按钮）；保留固定16pt占位，隐藏时禁用指针命中，键盘焦点使按钮可见并保留辅助功能操作。
hover状态属于单个 `DebugJSONLineView`，离开或卸载行时清理；共享分隔条拖动期间隐藏按钮，避免高频装饰影响调整。
依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `EditorGutterComponentImpl.updateFoldingOutlineVisibility`、
`drawDirectedBox`、`drawSquareWithPlusOrMinus`：New UI用hover控制展开标记透明度，收起标记直接绘制。
Lithe遵循用户指定的“对应行hover”范围，区别于IDEA的整个gutter范围和收起标记常驻规则；本轮沿用共享控件的无额外动画切换，不移植Swing动画系统。

工具栏不再重复显示所选栈帧的源码文件与行号；调用栈行仍展示源文件名，选择栈帧仍触发原来的源码定位。

## 考虑过的备选方案

- 默认展开所有树节点：仍然依赖大量层级和滚动，也改变用户原来的树状态，因此未采用。
- 注入 Jackson/Gson 或调用目标 `toString()`：依赖目标项目与运行行为，不适合作为默认查看方式。
- 新建编辑器与高亮器：复用现有 DiffSyntaxHighlighter、代码字体和可选择文本即可满足本轮查看与复制；暂不增加编辑能力。

## 后果

默认能直接阅读多层字段，原树形编辑、监视与分页入口继续保留。代价是暂停后的首次 JSON 读取会额外请求字段。
JSON 不包括未加载的全部根变量、不保证第三方调试器的逻辑集合视图，也不自动替用户调用 getter。
超限和错误标记可能出现在对象或数组中，复制内容是调试快照，不能直接当作业务请求的完整载荷。
Windows 尚未实现该模式，功能矩阵单独标记缺失。

## 验证

`DebugJSONFoldingTests` 验证嵌套对象/数组、字符串括号、尾逗号、父子折叠状态与无匹配边界。
`DebugVariableJSONSnapshotTests` 覆盖嵌套对象、数组排序、共享引用与循环、精确整数、深度/节点/大小限制、错误、取消与超时、迟到响应及恢复运行后拒绝旧快照。
本地审查修复字段数量恰好达到上限时误报截断，以及多参数Java方法标签因逗号导致方法高亮失效；对应边界均有回归测试。
原生预览验收项包括默认 JSON、树/JSON 双向切换、按钮固定在标题栏、复制、深浅主题与已有 Watches。
深层演示适配器只用于独立构建实例，不写入生产入口或 PR；真实用户 JVM 全流程验收与演示分开记录。
不新增运行时下载、文件缓存或 bundle 写入。

## 适用范围

- `macos/Sources/LitheDebugModule/Application/DebugVariableJSONSnapshot.swift`
- `macos/Sources/LitheDebugModule/Application/GenericDebugFeatureModel.swift`
- `macos/Sources/Lithe/Views/Debug/DebugVariableJSONView.swift`
- `macos/Sources/Lithe/Views/Debug/GenericDebugView.swift`
