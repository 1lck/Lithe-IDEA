# Agent 笔记：项目树独立选择与批量移动

状态：已实现

## 先说结论

目录是一个独立选项，选择目录不会让它的后代一起高亮。目录名称负责选择，
箭头或目录名称双击负责展开；上下方向键移动选择，左右方向键展开、折叠或进入显示子项、返回显示父项。
拖动一个已选项时携带完整选择集合，移动目录时按整个目录处理。
macOS 使用系统多文件拖动，工作区模块继续负责实际文件操作及文档、历史和目录标记更新。

## 问题

#1050 指出目录后代继承高亮违背操作习惯，点击大目录还可能卡顿。
原选择集合只包含目录，但显示层沿父路径判断选中，因此看起来像全选。
原文件拖动只提供单个 URL，目录没有拖动入口，项目树也没有移动接收端。
普通点击同时触发展开，递归非懒加载视图会实例化全部已展开行，必须区分选择成本与展开成本。

## 决策

- 文件、目录、项目根和多选右键菜单复用已有项目范围查找与替换入口，沿用整个项目范围、
  选中文字预填和既有替换预览/确认流程；树视图只提供入口，实际查找和替换由已有功能处理。

- 行高亮和右键目标只使用明确选择集合。⌘ 点击增减单项，Shift 只在需要范围时
  读取可见行顺序，⌘A 保留焦点项同级语义。
- 文件树点击后的键盘归属由原生事件适配器维护，方向键被消费后不能继续送到编辑器；
  点击树外或后续键盘焦点改变时释放归属，搜索输入框仍处理自己的方向键与文字快捷键。
  上下移动只选择可见行，不打开文件；Shift 上下扩展范围，左右按显示层级处理压缩包，
  选择变化后滚动到焦点项。目录名称单击只选择，双击才展开或折叠。
- 原生鼠标适配器等待松开鼠标才执行普通点击；达到拖动阈值后只启动拖动，
  不先把原多选缩成单选。Control 点击交给既有右键菜单。
- AppKit（macOS 原生界面框架）一次拖动携带多个文件 URL；项目树只接收同窗口、
  同工作区的原生树拖动，避免把外部文件或其它项目误当成移动授权。
  外部接收方仍可读取文件 URL，源端只允许外部复制。
- 工作区模块复用文件操作端口，后台预检整个集合，排除父子重复、根目录、
  同名目标、越界符号链接和移入自身/后代。当前目录中的项目保持原位。
  未保存文档在历史记录前后检查，成功项立即更新打开文档，再迁移历史和目录标记。
- 文件操作期间持有批量操作标志；工作区代次变化后停止后续项，旧操作不释放新工作区的标志。
  中途失败不自动回滚已成功项，因为回滚可能覆盖期间发生的外部编辑；提示完成数量与剩余项。
- 可见树按显示层级展开成平面行列表，直接交给懒加载栈，保留压缩 Java 包的显示深度。
  不在每个目录下嵌套懒加载栈，以免滚动容器无法正确测量整棵递归子树。

正确示例：同时选择 `src`、`src/A.java`、`README.md`，拖到 `archive`，实际只移动
`src` 与 `README.md`，后代随目录移动。不要将 `src/A.java` 再移动一次，也不要为了
目录高亮去遍历或加载未展开的后代。

## 考虑过的备选方案

- 在树菜单单独实现搜索或直接替换文件：会绕过已有搜索状态和替换预览/确认流程，不采用。

- 仅修复高亮：无法补齐批量移动，不能满足完整操作链。
- 单个 SwiftUI URL 拖动：不能表达多个系统文件拖动项；使用系统原生会话保留互操作。
- 点击目录仍展开：把选择和大目录布局绑在同一次动作上，不采用；显式双击和右方向键可展开。
- 让方向键继续发给编辑器：树中选中了目录却操作编辑光标，违反当前操作目标，不采用。
- 完整替换为原生树控件：会扩大既有菜单、图标、定位和滚动的改动范围；本次保留 SwiftUI 行呈现。

## 后果

独立选择减少误解，目录移动不需要枚举磁盘后代，懒加载避免为屏幕外每行启动图标任务。
代价是维护一个原生输入适配器；真实拖动、上下滚动及大目录性能仍需 macOS 实机验收。
Windows 暂无该批量选择入口，矩阵保持缺失，不声明已同步实现。
本次不引入下载物或缓存；写入仅发生在用户工作区和既有历史、偏好存储，不修改发行资源或代码签名基线。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'ProjectTree|batchMove'`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`
- macOS 实机分别测量大目录选择、展开与滚动，验证能滚动至末尾及定位到未显示行；同时回归修饰键、右键、目录与多文件拖动。
- 点击目录名称后验证双击、上下左右与 Shift 上下、焦点项滚动；点击编辑器和搜索字段后
  验证按键归属释放。

- 项目根、目录、文件和多选右键菜单分别验证 Find in Files / Replace in Files；
  验证编辑器选中文字预填、查找输入框聚焦和替换预览/取消/确认，搜索范围仍为整个项目。

## 适用范围

- `macos/Sources/Lithe/Models/AppModel/AppModel+SearchModule.swift`
- `macos/Sources/Lithe/Views/Workspace/ProjectSidebarView.swift`
- `macos/Sources/Lithe/Views/Workspace/ProjectTreeSelection.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/ProjectTreeRowInteraction.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/ProjectTreeKeyboardCommands.swift`
- `macos/Sources/LitheWorkspaceModule/Application/WorkspaceFeatureModel.swift`
- `macos/Tests/LitheTests/ProjectTreeSelectionTests.swift`
- `macos/Tests/LitheTests/ProjectTreeBatchFileWorkflowTests.swift`
- `macos/Tests/LitheTests/LitheCoreLogicTests.swift`
