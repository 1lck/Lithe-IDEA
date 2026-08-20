# Windows 端 IDEA New UI 风格打磨方案

> 状态：已获准正式开发，2026-08-20 按“现有功能逐项效仿”口径校正。
> 参考：Windows IntelliJ IDEA 2025.2.1 是主视觉标准；Mac Lithe 截图只借鉴已经验证成熟的局部呈现；本地 `intellij-community` 提供主题与 SVG 资产。它们不是整窗克隆规范。

## 1. 目标与边界

- 只打磨 Windows React/Tauri 产品，macOS 不动。
- 中文界面优先，Dark 先完成；Light 与 English 只做不破版检查。
- 目标是让 Lithe 的主窗口明显具备 IDEA New UI 的图标语言、表面层级、密度和控件质感，同时保留 Lithe 的名称、Logo、多项目能力和已有功能入口。
- 允许调整 `windows/tauri/src/features/**/components`、对应样式以及 `windows/tauri/src/ui` 中的呈现壳和可复用原语。
- 功能、状态模型、数据流、持久化和现有交互不变；不改 `platform` 调度、Tauri 命令、`shared` 契约、Rust Core 或 macOS 实现。
- 先确认 Windows 已有真实功能，再寻找 Windows IDEA 对应 UI；没有功能就不显示按钮、占位入口或空工具窗。Mac 端仅在相同功能已有更成熟落法时作为补充参考。
- 不为图标显示新增完整 Java 解析器、持久化语义索引、sidecar 或 Project Model。IDEA Icons 可对虚拟列表中实际显示的 Java 文件及已经打开的 editor buffer 做有界浅词法识别，并从已加载且含 `pom.xml` 的标准 Maven 目录结构投影 source root/package；声明名不匹配、读取失败或结构不标准时回退通用图标。
- 优先复用现有依赖和图标漏斗。只有现有栈确实无法完成时才考虑新依赖，并单独说明必要性与体积影响。

## 2. 视觉参考与资产规则

- Windows IDEA 2025.2.1 截图用于对应功能的观感对照：工具栏层级、Project 树密度、编辑器标签、侧边工具窗、分隔线、选中态和状态栏。Mac Lithe 不决定 Windows 布局，只提供可选的产品细节。
- `intellij-community` 用于查找开源的 IDEA SVG、明暗变体和主题色。不得在运行时代码中写入本机仓库路径，也不照搬 Swing/Kotlin 实现。
- SVG 进入仓库时保留上游文件内已有的版权信息，通过现有 IDEA 资产生成器和 `icons.tsx` 漏斗接入；不用同名猜语义，方向图标要核对前进/后退、展开/收起和 `mirrored` 约定。
- IDEA Icons 作为默认文件图标主题；Material、Pierre、Symbols 等显式选择继续保留。
- 颜色、尺寸和状态值集中在主题令牌或共享 UI 原语中。业务组件不得散落 IDEA 色值和重复魔法数字。
- 主题决定颜色，结构样式决定布局。调整结构令牌时必须检查其他 bundled 主题，不能让第三方配色主题意外继承 IDEA 专属颜色。

## 3. 实施顺序

### A. 图标与 Project 树

- 补齐主工具栏、常用操作、activity rail、Project 树和编辑器标签实际用到的 IDEA SVG 映射。
- 统一 16px 图标槽、展开箭头、目录开合、文件类型、悬停与选中状态。
- 调整 Project 树的行高、缩进、文字基线、选中背景、工具窗标题和右侧操作按钮。
- 保留 Project 树层级 guide 的原有命中区与折叠行为；静止时保持透明，鼠标靠近 guide 区或键盘 `focus-visible` 位于树内时淡入，不允许为显线改变缩进几何。
- Java `class/interface/enum/@interface/record` 只在浅词法结果与文件 basename 严格一致时使用对应图标；Exception 只认显式直接继承 Java 内建异常基类。磁盘只读取虚拟列表实际挂载的行，editor tab 只消费已打开 buffer，不扫描全树；不能确认时保持 Java 通用图标。
- 标准 Maven `src/main/java`、`src/test/java`、resources roots 及合法 package 路径由已加载树中的真实 `pom.xml` 约束；Compact Folders 不得跨 source root 合并，selection、rename、watcher 和文件操作继续使用真实路径。

### B. 主题令牌与通用原语

- 继续使用已经落地的 IDEA 风格暗色色板，校准背景/表面层级、边框、分隔线、悬停、选中和焦点态。
- Project 文件区与 editor 使用同一个 `background` 主题令牌；两者之间保留 token border 与 workbench gap，主工作区顶/底外沿不额外描线；editor 与右侧 Extensions rail 直接衔接，不用双边框或空隙制造层级。
- 统一工具栏按钮、图标按钮、tabs、列表行、弹层和 resize 分隔条的高度、圆角及视觉 padding。
- 点击热区可以大于图标本身，但不能靠额外可见 padding 把界面重新撑松。
- 字体以 Windows 中文清晰度和可靠 fallback 为先，不为追求英文截图外观盲目增加字体包。

### C. 主窗口 chrome

- 主工具栏：只放真实的菜单、Project、branch、Quick Open、更新和窗口控制；不复制不存在的运行选择器或重复项目入口。
- Project tabs：这是 Lithe 的真实多项目能力；单项目隐藏，多项目保留独立紧凑行，不为了像 IDEA 强塞进主工具栏。
- Workbench：保留现有可调整大小的轻圆角面板结构；Project 与 editor 之间继续使用左右 token border 和既有 workbench gap，resize handle 留在 gap 内；主工作区顶/底外沿不绘制横线。editor 与 BottomPane 使用完整 `rounded-xl`，右上/右下与左侧采用同一半径；它们与右侧 Extensions rail 直接相邻，不画相邻边线，也不在两者之间留 gap。只收紧外缝、层级和分隔，不为追求截图拆掉成熟容器或重排业务挂载点。
- Editor tabs：统一高度、激活下划线、文件图标、关闭按钮和 hover 状态；拖拽、固定、预览、脏标记、键盘和跨窗行为不变。
- Activity rail / tool-window header：左 rail 保持现有真实路由；右侧固定预留 38px Extensions rail，并与左 rail 使用同一个 `surface` 颜色，目前只放一个能打开真实 singleton Extensions 页面的 Puzzle 按钮。未来只有存在真实 action 时才增加按钮。统一尺寸、选中反馈、标题与现有动作排列。
- Status bar：统一高度、间距、文字层级与图标，检查中文长文案和项目状态容量，避免同一状态在顶部与底部无意义重复。
- Bottom pane：关闭最后一个 terminal 后自动收起 Terminal pane；重新从 activity rail、菜单或命令面板新建时再展开且只创建一个。Run、Git Log、Debugger 与 Buffers 不受 terminal 归零影响。

## 4. 开发纪律

- 一个总 PR，按“图标与文件树 → 令牌/原语 → 顶部 chrome/tabs → rail/tool window/status bar → 集成收口”分层提交。
- 每层提交保持应用可运行；保留相关行为测试，不用大范围快照替代功能断言。
- 呈现组件继续调用现有 feature actions/stores，不从 view 直接调用 Tauri API，不新增跨层快捷通道。
- 不做无关重构、依赖升级或生成物提交；不硬编码本机项目、工具安装或截图路径。
- 若某项“更像 IDEA”的改法会改变用户行为或跨越边界，先停在现状，不在 UI 打磨中顺手重设计。
- capability 不可用或没有渲染消费者的入口必须隐藏；不得用永久 disabled 控件表达未来功能。

## 5. 验收方式

视觉验收以中文 Dark 主窗口为主，不设逐像素误差或固定截图数量。使用同一个真实项目打开文件树和若干编辑器标签，与 IDEA 参考图并排查看：

- 第一眼能识别为同一类 New UI 视觉语言，且仍然是 Lithe。
- 工具栏、Project 树、editor tabs、activity rail、tool-window header 和 status bar 的密度、层级、图标风格一致。
- 常规窗口与较窄窗口无重叠、无不可达操作、无中文截断；125% Windows 缩放下显示正常。
- Dark 为完整验收；Light、主题切换和 English 各做一次 smoke；Material、Pierre、Symbols 仍可选择。
- 人工回归项目切换/溢出、文件树展开与选中、tab 打开/关闭/重排/固定、rail 切换、pane resize、窗口拖动和状态栏显示。
- 最终效果由用户查看实机截图或运行版本后确认。

## 6. 验证矩阵

迭代时运行最小相关测试、`bun test` 和 `bun run typecheck`。总 PR 收口前在 Windows 完成：

```powershell
Set-Location windows/tauri
bun test
bun run typecheck
bun run build

Set-Location ../..
./scripts/verify-windows-boundaries.ps1
./scripts/build-windows.ps1 -Configuration Release
cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml
```

任何未实际执行的检查都必须在交付说明中明确列出，不能按通过报告。
