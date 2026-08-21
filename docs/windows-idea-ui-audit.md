# Windows UI 打磨审计

> 基线：`520f3c77 feat(windows): make IDEA icons the default file theme`。
> 日期：2026-08-20。
> 用途：记录正式打磨的基础与校正结果。Windows IDEA 2025.2.1 是对应功能的主视觉参考；Mac Lithe 仅借鉴成熟细节；不做整窗复刻。

## 1. 已完成的基础

### 默认文件图标主题

- `defaultSettings.iconTheme` 已是 `idea-icons`（`windows/tauri/src/features/settings/config/default-settings.ts`）。
- 旧 Lithe 图标主题 ID 会迁移到 `idea-icons`；旧 Material/Seti 别名按现有规则归一化（`windows/tauri/src/features/settings/lib/settings-normalization.ts`）。
- bundled 注册保留 IDEA、Material、Pierre、Symbols，不再注册旧 Lithe 图标主题（`windows/tauri/src/extensions/bundled/bundled-extension-manifests.ts`）。
- 对应默认值、迁移和 manifest 注册已有测试覆盖。
- foundation 提交时已记录通过 186 个前端测试、typecheck、production build、Windows boundary、Release build 和 69 个 Tauri Rust tests；正式打磨后的结果必须重新验证，不能沿用这组结论。

### IDEA 资产通路

- 文件图标 manifest 已包含常用扩展名、文件名、通用文件和文件夹的明暗 IDEA SVG（`windows/tauri/src/extensions/bundled/icon-themes/idea/extension.json`）。
- bundled 资产解析器已能加载 IDEA 图标主题（`windows/tauri/src/extensions/icon-themes/bundled-icon-theme-assets.ts`）。
- 通用操作图标已有生成资产表与统一 `icons.tsx` 入口，能够在明暗主题间选择 IDEA 变体，并保留 Lucide fallback（`windows/tauri/src/ui/icons/idea-assets.generated.ts`、`windows/tauri/src/ui/icons.tsx`）。
- Maven 项目图标（`pom.xml`）的生成器 source 位于 intellij-community 的 `plugins/maven/...` 目录（`idea-file-icon-mappings.json` 的 source/asset 分离机制）；本地稀疏克隆需包含该目录才能跑生成器 `--check` 复现校验。

### IDEA 风格基础色板

- `lithe-dark` 已采用 `#1e1f22` 背景、`#2b2d30` 表面、`#43454a` 边框、`#2e436e` 选中和 `#3574f0` 主色等 IDEA 风格令牌；亮色变体也已有对应层级（`windows/tauri/src/extensions/themes/builtin/lithe.json`）。
- `lithe-dark` 语法色已整体换成 New Darcula 系（橙关键字/青数字/绿字符串等），编辑器 selection `#214283`、光标 `#ced0d6`；Monaco 的行高亮与失焦选区已与选中色解耦（`monaco/theme.ts`）。
- `theme.css` 已通过语义变量向组件提供 background、surface、border、selected、primary 等颜色，后续应继续走令牌，不在组件散落 raw hex。

## 2. 当前主要差距

| 区域 | 当前状态 | 本轮动作 |
| --- | --- | --- |
| 图标一致性 | IDEA 文件主题、Java 声明节点、标准 Maven root/package 和操作资产已接入；文件树与 editor tab 共用 Java 语义，不能确认时仍回退通用图标 | 保持可见行/已打开 buffer 的浅词法与真实 `pom.xml` 约束；不按文件名猜类型，不建立全量索引 |
| Project 树 | 已有虚拟化、Compact Folders、git 状态和主题图标入口；source root 会截断 compact，package 仅改变显示名与图标；层级 guide 静止透明、靠近或键盘聚焦时显现 | 保持 row-model 投影与 guide 原命中几何；selection、rename、watcher、路径操作继续使用真实路径 |
| 主工具栏 | Project、branch、Quick Open、更新和窗口控制均有真实 action；中文紧凑菜单已禁止收缩换行 | 只调整视觉分组；不放禁用运行选择器或重复项目入口 |
| Project tabs | 完整切换/关闭/拖拽逻辑存在，单项目已隐藏 | 多项目保留独立紧凑行，避免重写状态或强塞主工具栏 |
| Workbench | `lithe-glass-island`、resize 和透明逻辑是成熟结构；Project/editor 统一使用 `background` token，并保留中间左右边线、真实 4px gutter 与 resize handle；主工作区顶/底外沿不描线；editor/BottomPane 四角使用同一半径，与右侧 rail 无 gap、无相邻双边线 | 保留轻圆角容器、内容宽度和 resize 行为，只校准 gap、分隔、圆角与表面层级 |
| Editor tabs | 交互能力较多，视觉上仍偏厚、图标与关闭态不够统一 | 只改高度、激活线、hover、图标槽和边框，完整保留 tab 行为 |
| Activity rail | 左 rail 承担真实路由；右侧恢复 38px Extensions rail，并与左 rail 共用 `surface` 颜色；唯一 Puzzle 按钮打开真实 singleton Extensions buffer，active 跟随当前 buffer | 只显示已有真实 action；预留空白不等于预造未来按钮，保持紧凑中性选中态 |
| Bottom pane | Terminal、Run、Git Log、Debugger、Buffers 共用容器；Terminal 最后一个 session 关闭时会自动收起，其他工具窗不受影响 | 只识别同 workspace 的 terminal 数量 `>0 → 0` 且当前可见 tab 为 Terminal；全局新建入口必须重新展开并仅创建一次 |
| Tool window header | 各 feature 的标题和动作排布不完全一致，Project 区的层级感不足 | 建立或复用统一 presentation 原语，不改变各 feature action |
| Status bar | 已组件化且支持排序，但文字、chip、图标和间距不在同一密度体系 | 统一度量并重点检查 zh-CN 长文案和窄窗口容量 |
| 字体与语言 | 新默认已为 Microsoft YaHei UI 13 与 `zh-CN`；仅成对迁移旧 Geist Sans 15 默认值 | 保留用户显式选择，验证中文、大字号和 Windows 125% 缩放 |

## 3. 明确不做

- 不复刻 IDEA 2025.2.1 的全部布局、交互或 Ultimate 专有功能。
- 不建立完整 Java AST、Maven/Gradle Project Model、持久化语义缓存、后台全树索引或 sidecar；仅允许有界的可见行浅词法识别和已加载标准 Maven 路径投影。
- 不修改 Tauri 命令、platform dispatcher、shared contracts、Rust Core 或 macOS。
- 不新增字体或 SVG 转换依赖来解决现有 CSS/资产通路已经能完成的问题。
- 不要求 2px 像素误差、透明叠图、固定九张证据图或五次启动统计。
- 不把本机的 `intellij-community`、示例项目或截图绝对路径写入产品代码。

## 4. 风险与护栏

- **全局令牌影响所有主题。** `theme.css` 中的结构变量可以共享，IDEA 专属颜色必须留在 Lithe 主题；每轮至少 smoke 一个非 Lithe 暗色主题和一个亮色主题。
- **UI 密度会暴露中文容量问题。** 主工具栏、Project tabs、状态栏和设置弹窗需在常规/较窄窗口及 125% 缩放下检查；树行随用户字号增长，不能为了紧凑裁字。
- **图标同名不等于同义。** 返回/前进、上下移动、展开/收起、运行/调试和关闭类资产需要逐个看 SVG；不能让 `mirrored` 再次反转已有方向。
- **presentation 重排容易误伤行为。** 项目切换、tab DnD/固定/预览、rail 路由、pane resize 和窗口拖动依赖现有组件；样式改动前后用现有测试与人工清单对照。
- **点击区不能随视觉尺寸一起缩没。** 图标可以更紧凑，交互 hitbox、键盘焦点和可访问名称必须保留。

## 5. 完成判据

- 用户认可中文 Dark 主窗口的整体质感，并认为已达到“参考 IDEA New UI 打磨后的 Lithe”，无需与 IDEA 像素一致。
- 主工具栏、Project 树、editor tabs、activity rail、tool-window header 和 status bar 形成同一套视觉语言。
- 文件图标和常用操作图标语义正确，IDEA Icons 默认生效，其他显式图标主题仍可使用。
- 中文常规/窄窗口不破版，Light、English 和第三方主题完成 smoke。
- `bun test`、typecheck、production build、Windows boundary、Release build 和 Tauri Rust tests 均通过；未执行项如实披露。
