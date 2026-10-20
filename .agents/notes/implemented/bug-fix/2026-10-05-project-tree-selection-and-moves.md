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
- Windows 每次原生移动成功后，必须先调用操作开始时捕获的原工作区同步回调，
  再检查面板是否卸载或工作区是否切换。界面生命周期只能阻止后续移动，不能让已完成的
  磁盘修改跳过文档、树与目录标记同步；不把旧操作交给新工作区的回调。
- Windows 每次进入工作区都使用独立的访问标识。目录预检、原生移动或原工作区同步
  等待期间发生 A→B→A，回到相同根路径也不能恢复旧批次；尚未开始的项停止移动。
  普通重渲染不改变访问标识，仍能完成当前批次。旧操作失败时只记录错误，不能清除
  新访问中正在进行的拖动或向新界面发送旧错误提示。
- Windows 搜索首次命中和 Enter 切换命中时，同时替换焦点项、明确选择集合与范围锚点，
  避免随后复制或剪切仍操作搜索前的旧项。右键是否属于已选范围应读取明确选择集合，
  实际复制、删除等批量操作才折叠父子重复；不能用折叠后的集合判断后代是否已被选中。
- Windows 编辑器活动文件实际变化时，至多一个选项的项目树同步选择、键盘焦点与范围锚点，
  与 Swift 保持一致；明确多选保持原集合。活动文件不变时，重新渲染或选择目录不能触发同步。
  判断变化使用 `useFileExplorerSync` 从编辑器缓冲区取得的 `explorerTargetPath`，不能使用
  共享侧栏 `activePath`：目录点击会先更新后者，同步逻辑再将其恢复为编辑文件路径；
  这次往返不代表编辑器切换，也不能改变目录的选择、复制或剪切目标。
- Windows 路径比较仅对本地盘符和普通 UNC 网络路径忽略大小写；WSL、远程、POSIX
  以及 `wsl$` / `wsl.localhost` 网络别名保持大小写。选择去重与拖动预检使用同一规则，
  例如 Linux 的 `src/a.ts` 与 `src/A.ts` 都保留，Windows 同名目标仍拒绝覆盖。
- 可见树按显示层级展开成平面行列表，直接交给懒加载栈，保留压缩 Java 包的显示深度。
  不在每个目录下嵌套懒加载栈，以免滚动容器无法正确测量整棵递归子树。
- Windows 手动定位当前文件与自动跟随共用 `useFileExplorerSync` 的定位请求。
  展开、加载祖先目录后，视图根据可见行索引滚动虚拟列表，再消费请求；同一文件的
  每次点击都产生新请求，过期完成不能覆盖新请求。手动定位清除树内搜索并切回 Project，
  不依赖自动跟随开关。仅调用目录展开或选中动作不会让离屏行进入视口。

正确示例：同时选择 `src`、`src/A.java`、`README.md`，拖到 `archive`，实际只移动
`src` 与 `README.md`，后代随目录移动。不要将 `src/A.java` 再移动一次，也不要为了
目录高亮去遍历或加载未展开的后代。

## 考虑过的备选方案

- 监听侧栏活动路径来跟随编辑器：该路径同时接受目录点击，无法区分树选择与编辑器切换，
  会把刚选中的目录改回编辑文件；改为复用同步 Hook 已有的编辑器目标，不另建缓冲区选择器。
- 在树菜单单独实现搜索或直接替换文件：会绕过已有搜索状态和替换预览/确认流程，不采用。

- 仅修复高亮：无法补齐批量移动，不能满足完整操作链。
- 单个 SwiftUI URL 拖动：不能表达多个系统文件拖动项；使用系统原生会话保留互操作。
- 点击目录仍展开：把选择和大目录布局绑在同一次动作上，不采用；显式双击和右方向键可展开。
- 让方向键继续发给编辑器：树中选中了目录却操作编辑光标，违反当前操作目标，不采用。
- 完整替换为原生树控件：会扩大既有菜单、图标、定位和滚动的改动范围；本次保留 SwiftUI 行呈现。

## 后果

独立选择减少误解，目录移动不需要枚举磁盘后代，懒加载避免为屏幕外每行启动图标任务。
代价是维护一个原生输入适配器；真实拖动、上下滚动及大目录性能仍需 macOS 实机验收。
Windows 现已加入 Ctrl/Shift 可见范围多选、批量复制/剪切/删除及已选集合拖动，目录单击选择、双击/箭头展开。拖动预检重名和父子重复，底层用不覆盖发布防止同名文件丢失；逐项操作并在工作区切换后停止后续项。Windows 原生 WebView2 的拖动、焦点与大树验收仍 pending，不能用选择工具函数测试代替。
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
- Windows 定位回归：
  `cd windows/tauri && bun test src/features/file-explorer/components/file-explorer-reveal.test.tsx`；
  点击真实工具栏按钮，检查关闭自动跟随时的折叠祖先展开、离屏行呈现、重复定位、
  延迟目录加载及过期请求；自动跟随仍需滚动。真实 WebView2 验收另行完成。
- Windows 目录选择回归挂载真实 `FileExplorerPane`，连接侧栏与缓冲区 store，只替换磁盘副作用。
  编辑器保持 `README.md` 打开时选择 `src`，核对共享路径同步往返后的高亮、复制、剪切、
  键盘焦点及范围锚点；再核对实际编辑器切换的单选跟随和明确多选保留。
- Windows 选择与移动回归：通过 `test-stability-windows.ps1 -Scope Frontend` 的
  `-FrontendTestPath` 选择 `file-explorer-selection.test.tsx`、
  `use-file-explorer-drag-drop.test.tsx` 和 `tree-selection.test.ts`；验证搜索后复制/剪切、
  已选后代右键复制/删除、原生移动等待期间卸载或切换工作区，以及区分大小写与
  Windows 同名目标的预检。搜索用例隔离弹层动画，只验证真实树的搜索与选择状态；
  WSL 用例使用受控原生调用，不代表当前产品已开放 WSL 或完成真实发行包验收。
- Windows 移动生命周期回归使用受控 Promise 分别暂停目录预检、原生移动和原工作区
  同步，在每个等待点切换 A→B→A；确认不再派发后续项，已完成项仍同步原工作区。
  同时验证普通重渲染仍完成批次，以及旧移动失败不清除新拖动、也不显示过期错误。
  Windows CI 的 `Test Project tree selection, reveal, and move lifecycle` 步骤运行
  这组移动回归与选择、定位、目录标记和路径身份测试，生成逐项 HTML/JUnit 计时报告。

- 项目根、目录、文件和多选右键菜单分别验证 Find in Files / Replace in Files；
  验证编辑器选中文字预填、查找输入框聚焦和替换预览/取消/确认，搜索范围仍为整个项目。

## 适用范围

- `windows/tauri/src/features/file-explorer/components/file-explorer-tree.tsx`
- `windows/tauri/src/features/file-explorer/hooks/use-file-explorer-sync.ts`
- `windows/tauri/src/features/file-explorer/components/file-explorer-reveal.test.tsx`
- `windows/tauri/src/features/file-explorer/hooks/use-file-explorer-drag-drop.ts`
- `windows/tauri/src/features/file-explorer/hooks/use-file-explorer-context-menu.tsx`
- `windows/tauri/src/features/file-explorer/hooks/use-file-explorer-drag-drop.test.tsx`
- `windows/tauri/src/features/file-explorer/components/file-explorer-selection.test.tsx`
- `windows/tauri/src/features/sidebar/utils/tree-selection.ts`

- `macos/Sources/Lithe/Models/AppModel/AppModel+SearchModule.swift`
- `macos/Sources/Lithe/Views/Workspace/ProjectSidebarView.swift`
- `macos/Sources/Lithe/Views/Workspace/ProjectTreeSelection.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/ProjectTreeRowInteraction.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/ProjectTreeKeyboardCommands.swift`
- `macos/Sources/LitheWorkspaceModule/Application/WorkspaceFeatureModel.swift`
- `macos/Tests/LitheTests/ProjectTreeSelectionTests.swift`
- `macos/Tests/LitheTests/ProjectTreeBatchFileWorkflowTests.swift`
- `macos/Tests/LitheTests/LitheCoreLogicTests.swift`
