# Agent 笔记：macOS 首期 IDE 编辑器设置导入

状态：已实现

## 先说结论

首次启动在创建欢迎页内容前只读发现本机 VS Code、Cursor 与 IntelliJ IDEA 用户配置，用户在预览中选择来源和字段，点击导入后写入 Lithe 现有编辑器设置。设置页保留重复导入入口，已有自定义偏好默认不勾选。导入按外观设置、快捷键、代码设置和编辑器偏好分组，支持已有深浅色／跟随系统落点及明确标注的参考外观；只覆盖有真实生效落点的偏好，不把自定义主题或语言服务配置复制进一个不起作用的存储区。

## 问题

外部 IDE 的配置并不等于完整的当前有效值：省略字段代表继承默认值，Profile、项目和语言配置还有自己的覆盖层；IDEA 的配色方案又可能覆盖全局字体。直接复制整个目录会带入账号、凭据、无效路径和插件状态；直接套用字段名会造成像素行高、字体缩放和软换行范围误导。

## 决策

面板按用户确认恢复 IDEA Community 的固定内容基线 640×467，不再按行数缩放。第一页为居中的来源按钮（参考 `ProductChooserPage.kt` 与 `UiUtils.kt` 的 280×40），点击后调用 `chooseSource` 进入第二页，只更新选择与预览，不写入偏好；第二页执行明确的导入动作，也可返回选择来源。`ImportSettingsController.kt` 的 ProductChooserPage → SettingChooserPage 是上游流程依据；上游另外还有进度页，Lithe 首期沿用现有忙碌状态，不宣称已经复刻其独立进度页和全部分类。手动与首次启动入口复用同一分页内容。首次启动窗口尺寸仍由既有 WindowCloseGuard / LitheWindowCoordinator 的 settingsImport 角色管理，完成后恢复欢迎页尺寸。兼容说明保留在信息提示，长路径省略，设置内容可滚动。

欢迎页底部使用同一行的设置、导入图标按钮，导入位于设置右侧；复用 16pt IDEA `settings.svg` / `download.svg` 与共享工具栏按钮命中范围；导入图标按用户确认使用向下箭头进入托盘的形状，替代容易被误认为缩小窗口的折角箭头，移除设置按钮原有 28pt 自定义包围框。导入图标保留本地化悬停提示、无障碍名称及首次检测行为；设置页仍保留文字入口。

手动导入入口复用 `LitheCenteredPopup(dialogTitle:)` 和 `LitheCommitDialogStyle`，由共享 presenter 负责原生标题栏、相对父窗口居中、无动画呈现与关闭生命周期。内容通过显式回调关闭，忙碌状态传入 `allowsDismiss`；不使用系统 `.sheet` 或重复绘制标题。`EditorSettingsImportTests` 同时检查入口源码不可退回 sheet，以及首次启动深浅色下不创建欢迎页或附属窗口、跳过后才显示欢迎页和预览不写设置。共享面板的忙碌、父窗口清理和重复打开继续由 `LitheCenteredPopupTests` 覆盖。此前手动共享面板修正的 48 项测试通过；首次启动流程调整后，导入、共享窗口和 AppSettings 共 49 项测试通过，深浅色启动阶段切换测试耗时 184ms；35 项国际化测试通过。

- 平台适配器 `MacEditorSettingsImportReader` 只读扫描 macOS Application Support 下的 Code / Code - Insiders / Cursor 用户目录与 profiles，以及 JetBrains 的 IntelliJIdea / IdeaIC 配置目录；兼容旧 Library/Preferences 目录。用户配置目录存在即可成为候选，不要求启动或仍安装对应应用；Code 系编辑器尚未生成 settings.json 时展示可选择的参考外观并标注“参考默认值”，不声称读取到了显式配置，不创建源文件。仅安装 app 但没有用户目录不作为可用配置来源；任意空目录也不推断成编辑器配置。Cursor 复用 VS Code 的 JSONC 白名单解析，独立显示产品名称与 Community 的 cursor/Cursor_20.svg 图标；自动扫描与手选标准用户/Profile 目录保持相同身份。自定义目录可手动选择；不是递归搜索整个用户目录，也不自动解压导出包。
- 来源以目录路径区分版本和 Profile。Profile 暂以目录 ID 展示，不读取可能混有账号状态的 globalStorage，不推断其继承默认配置。显式字段读取来源自身的配置，补充的外观参考值另外标注，Cursor/Profile 参考值额外标注近似，不能作为完整继承解析；项目和语言级配置不提升为全局设置。
- Foundation 原生 JSON5 读取器处理 VS Code 的 JSONC（带注释和尾逗号的 JSON）；首期接受其超集语法，不新增解析依赖。IDEA 读取 `options/editor.xml`、`options/editor-font.xml`、`options/colors.scheme.xml`、`options/laf.xml` 及最多 64 个 `colors/*.icls`，限定组件，XML 禁止外部实体并拒绝文档类型/实体声明。每文件最多 1 MiB、每来源最多 8 MiB，目录和候选数量均设上限；实际读取也有字节上限，不只检查可竞态的文件大小。
- 用户可选择字体、字号、行间距、连字和已能表达的显示偏好。字体从现有平台字体目录中选择第一个已安装候选；不下载字体、不导入字重或回退列表。VS Code 小于 8 的非零行高按倍数解释，大于等于 8 按像素解释；像素转换必须具有受支持的显式或已标注参考来源字号，应用时检查依赖，不能在保留另一个字号的同时偷换其含义。IDEA 字体缩放非 1 时跳过字号；行距标明渲染近似。
- 内置配色只对明确识别的名称映射到 Lithe 内置方案，并显式提示近似；任意主题或扩展配色不算支持导入。IDEA 选中自定义配色方案而对应文件无法读取时跳过全局字体，避免把可能被方案覆盖的 DefaultFont 当成有效值；成功解析方案时按应用字体与方案覆盖确定有效值。未知字段和敏感值不进入预览、日志或恢复记录。
- 预览默认勾选会改变 Lithe 默认值的可导入字段，当前已有自定义值则不勾选。用户可显式选择覆盖；只写入勾选项。导入前重新读取来源，以内容摘要验证其版本，再检查目标偏好基线。扫描、选择、取消和关闭均不写来源或应用偏好；欢迎页的提示已展示标志单独保存。
- 写入复用 `AppSettings` 与 `KeyValueStore`。先写入仅包含所选外观和编辑器字段的恢复记录并读取核对，再经既有 setter 更新即时生效链路，重新读取存储值核对成功后标记完成。发生部分写入失败时尝试恢复；启动时遇到未完成记录也执行恢复。无法恢复时保留记录并阻止新导入覆盖备份。此处沿用现有偏好存储的持久化保障，不宣称新增了文件系统 fsync 或跨进程事务。
- 撤销只覆盖上次导入的字段，若用户已再次修改这些值，拒绝盲目恢复。每次进入写入阶段的导入尝试替换上一份恢复记录，失败回滚成功后清除记录；仅保留单次恢复能力，不提供多步历史撤销。恢复的是先前有效值，不保证恢复缺省键的原始缺席状态；没有后台同步或自动重复覆盖。
- 生命周期和文件读写留在平台适配器；Application 功能模型通过组合根注入扫描与目录选择操作，不持有 AppModel 或调用平台 API。长任务持有独立依赖，窗口关闭不会解引用失效的非拥有引用。

正确示例：来源 `fontSize=16`、`lineHeight=24`，同时导入后 Lithe 保存字号 16、行距倍数 1.5；若用户坚持保留字号 22，则不单独导入这个像素行高。错误示例：从自定义 IDEA 方案中只读到全局 DefaultFont，就宣称已还原用户当前字体。

## 用户确认的紧凑分页布局

来源页左下固定“跳过”，右下保留“关闭”和“选择目录”。两页把“重新扫描”放到正文右下、底部分隔线上方，复用 `LitheBannerActionStyle` 的蓝色文字和悬停下划线，标签为 11pt，不引入另一套链接样式。手动打开时跳过只关闭面板；首次启动时跳过沿用既有完成回调，记录已处理并继续欢迎页。忙碌时所有出口与重扫仍禁用。

第二页顶部显示来源产品图标、名称、“用户设置”和真实目录；警告与范围说明继续放在信息提示。无设置时正文居中，只显示“暂时没有可导入的设置”和“软件名 尚未保存用户设置。”；无独立大图标或主按钮。读取失败和已有值相同分别显示各自状态，不混成无设置。存在可变更字段时保留勾选列表及确认导入，空状态不显示无效导入按钮。恢复错误和撤销入口继续保留，不因空状态隐藏。

第二页重扫只读取当前来源并替换该预览，保留其他来源及顺序，返回时仍可选择其他编辑器。没有采用全量扫描后直接选择第一个来源的方案，因为这会意外切换用户正在查看的软件；也不把单个来源结果覆盖整个候选列表。

## 上游依据

新增首次启动依据 Community revision `e12d185a335d02f3831c12f2af64130b3ace46db`：`plugins/ide-startup/importSettings/.../IdeStartupWizardImpl.kt` 在启动向导阶段检查来源；`chooser/ui/OnboardingDialog.kt` 使用无父窗口的 DialogWrapper，内容基线 640×467；`OnboardingController.kt` 管理导入、跳过和结束；`WizardPagePane.kt` 分离内容及底部操作。官方截图见 [来源选择](https://resources.jetbrains.com/help/img/idea/2026.2/ij_import_other_ide_selection.png) 和 [设置选择](https://resources.jetbrains.com/help/img/idea/2026.2/ij_import_jb_settings_selection.png)。这些是上游官方截图，不是本机运行或 Lithe 截图。

Lithe 在主场景中使用 `EditorSettingsImportStartup`，检测及导入阶段只创建启动导入内容，不挂载 RootView，也不创建欢迎页上的子窗口。导入成功或显式跳过后才挂载 RootView；未发现来源直接继续，扫描错误则保留重试/目录选择与跳过入口。关闭整个启动窗口不会提前保存完成标志，下次启动仍检测。复用同一主场景切换内容，避免新建第二个窗口生命周期或短暂显示欢迎页；不宣称复刻 IDEA 所有导入分类和插件能力。

只展示能改变当前设置的字段；相同值不再生成禁用的“关闭 → 关闭”行。来源读取失败以独立状态保留，第二页持续显示错误并可重试；成功读取但没有可支持显式字段与读取成功且值相同分别提示，不能把失败或不支持伪装为无差异。两页共用底部操作区，撤销只依赖本地恢复记录，即使来源已删除、重启后扫描为空仍可从第一页撤销；恢复失败提示也在两页显示。首次启动的导入完成标志沿用现有偏好键，只有完成/跳过或成功确认无来源时才写入，不在开页时提前标记。

- [VS Code 用户设置与作用域](https://code.visualstudio.com/docs/configure/settings)、[Profiles](https://code.visualstudio.com/docs/configure/profiles)、[默认设置参考](https://code.visualstudio.com/docs/reference/default-settings)。仅提取白名单项，不复制用户配置原文。
- [IDEA 配置目录](https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html)。自定义 idea.config.path 通过手动选择处理，不执行 JVM 或读取启动凭据。
- [VS Code 字体与行高实现](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/config/fontInfo.ts)：`MINIMUM_LINE_HEIGHT = 8`，零值自动计算，其余小于阈值的值以字号倍数解释。Lithe 采用已有行距落点，不复制 IDE 缩放状态。
- Community revision `74dbd42b7a8787b0707437cb857c68e78199f611` 的 [AppEditorFontOptions.java](https://github.com/JetBrains/intellij-community/blob/74dbd42b7a8787b0707437cb857c68e78199f611/platform/editor-ui-ex/src/com/intellij/openapi/editor/colors/impl/AppEditorFontOptions.java) 与 [EditorSettingsExternalizable.java](https://github.com/JetBrains/intellij-community/blob/74dbd42b7a8787b0707437cb857c68e78199f611/platform/ide-core-impl/src/com/intellij/openapi/editor/ex/EditorSettingsExternalizable.java)：使用 `DefaultFont`、`editor-font.xml`、`FONT_SIZE_2D`、`ARE_LINE_NUMBERS_SHOWN` 等真实存储名称。IDEA 按文件过滤的软换行不直接变成全局开启。

## 导入预览类别排版

左侧保持产品图标和名称横排，名称下只显示单行省略的配置路径，悬停展示全文。右侧参考 Community `e12d185a335d02f3831c12f2af64130b3ace46db` 的 `SettingChooserPage.kt` 和 `TransferableSetting.kt`，显示外观设置、编辑器偏好两个实际支持的类别；每行左侧是图标、名称和字段说明，唯一的复选框在最右侧，不再嵌套全选及子项复选框。类别按来源可读取的白名单字段显示，不按差异筛选；值全部相同时仍允许勾选或取消，不显示一致状态。选择包含该类别全部可用字段，实际写入仅包含差异字段，来源没有对应字段的类别不虚构。值变化与默认/近似标识移至名称、说明的悬停提示，来源警告仍可在产品名称的提示查看。

图标直接使用该 revision 的 `plugins/ide-startup/importSettings/resources/icons/` 中 colorPicker、settings、keyboard 与 configFile，保留原始几何及版权，复用 LitheIDEAIcon 模板渲染和共享复选框。没有增加尚不支持的插件、工具等导入类别，也没有修改已确认的左侧背景和排版。

类别内全部字段相同或可安全覆盖默认值时才默认勾选；存在自定义目标值或字号依赖时整个类别默认不选，防止外层未选中却仍写入隐藏字段。明确勾选类别会选择其全部可用差异，导入前的来源校验、回读、恢复及撤销保持原链路。按类别选择包含同组字号与行距，界面不再要求用户操作已经移除的逐项字号复选框。

EditorSettingsImportTests 验证复选框在类别标题右侧、实际切换类别、返回/跳过/导入/撤销，以及自定义字号与默认行距同组时均不默认选择。测试宿主截图用于深浅色布局检查，不携带正式产品图标资源，不能替代整包图标验收。

## 外观迁移的来源与边界

沿用 Issue #1634 的分阶段范围，`themePreference` 复用 AppSettings 原有深色、浅色和跟随系统持久化；不把它误写成应用配色 `colorTheme`。外观分组可以整组选中，已有自定义值初始不勾选；整组选中属于用户明确选择覆盖，仍须点击导入才写入。第二页使用共享复选框、原生忙碌反馈和简短应用数量；不创建额外窗口或假进度百分比。

- VS Code macOS 参考外观使用 Menlo 回退列表、12 号、1.5 行距、关闭连字及内置深色映射。显式值优先，非法显式值不回退成默认值。自动深浅色模式读取 preferredDark/LightColorTheme；未知主题保留 Lithe 配色。所有主题映射都标明近似，不能等同于自定义 token 颜色导入。Cursor 和 Profile 没有完整默认值/继承解析，参考项额外标为近似，不能宣称准确迁移其最终生效值。
- IDEA 默认字体受运行时影响：标准 JetBrains Runtime 使用 JetBrains Mono/13，而其他 macOS JVM 可能是 Menlo/12。因此提供的是标注近似的 JBR 参考外观，不推断用户实际 JVM；没有读取到的外观不伪装为已保存字段。未安装字体不导入，不启动或修改来源 IDE。
- `.icls` 按文件声明的方案名匹配，不用配置值构造文件路径。支持直接字体项和 `<font>` 列表；选择首个已安装字体，保留字号对应关系，不复制回退列表。`AbstractColorsScheme` 未覆盖字体时委托给应用字体；`parent_scheme` 管理配色，不能递归套用父方案字体。配色继承单独解析，循环拒绝读取，未知父方案不猜测；不将配色继承用于字体。未知方案版本、同名冲突、异常 XML 和越界链接拒绝读取；全部参与读取的文件纳入摘要，预览后任一变化都要求重扫。
- 读取不到自定义方案文件时仍跳过可能被覆盖的全局字体。读到方案后可导入字体及受支持的自定义颜色和字体样式。保留 `FONT_SCALE` 非 1 时跳过字号、缺失字体保留当前值及像素行高的字号依赖。未来字体配置版本不猜测；系统模式也不代表支持两套独立字体或任意深浅配色组合。
- 结果只统计本次实际应用与未选中的可变更字段，警告仍在信息提示中。只有成功写入并回读后才显示结果；首次启动随后继续欢迎页，手动导入保留撤销。重扫/重选清除本次结果，重启后值相同只显示“设置已一致”，不伪造每个来源的导入历史。

参考源码：VS Code revision `1306698e328e5e531f5e632301d30020aa994eff` 的 [fontInfo.ts](https://github.com/microsoft/vscode/blob/1306698e328e5e531f5e632301d30020aa994eff/src/vs/editor/common/config/fontInfo.ts)、[themeConfiguration.ts](https://github.com/microsoft/vscode/blob/1306698e328e5e531f5e632301d30020aa994eff/src/vs/workbench/services/themes/common/themeConfiguration.ts)；Community revision `c7d308d59fc7bca2652665bb1f55c4a2806ff8ce` 的 [FontPreferences.java](https://github.com/JetBrains/intellij-community/blob/c7d308d59fc7bca2652665bb1f55c4a2806ff8ce/platform/editor-ui-api/src/com/intellij/openapi/editor/colors/FontPreferences.java)、[AppFontOptions.java](https://github.com/JetBrains/intellij-community/blob/c7d308d59fc7bca2652665bb1f55c4a2806ff8ce/platform/editor-ui-ex/src/com/intellij/openapi/editor/colors/impl/AppFontOptions.java)、[AbstractColorsScheme.java](https://github.com/JetBrains/intellij-community/blob/c7d308d59fc7bca2652665bb1f55c4a2806ff8ce/platform/editor-ui-ex/src/com/intellij/openapi/editor/colors/impl/AbstractColorsScheme.java)、[LafManagerImpl.kt](https://github.com/JetBrains/intellij-community/blob/c7d308d59fc7bca2652665bb1f55c4a2806ff8ce/platform/platform-impl/src/com/intellij/ide/ui/laf/LafManagerImpl.kt)。参考默认值是兼容预设，不保证未知版本或自定义运行时的实际默认行为。

## 考虑过的备选方案

只在 settings.json 存在时列出 Code 系来源会隐藏未保存过设置的新安装；向来源写入默认文件会违反只读边界，因此列出真实用户目录，允许用户明确选择标注过的参考外观。按安装包存在就宣称有配置也无法证明来源，暂不扫描安装包或自动启动编辑器。

- 复制整份配置目录或通过外部 IDE 执行导出：会读取不必要数据、增加运行期依赖与来源写入风险，首期不采用。
- 创建第二套编辑器设置存储：现有 AppSettings 已支持持久化和实时更新，没有必要维护第二份生效真源。
- 导入所有默认值及语言覆盖：首期缺少可靠跨 IDE 优先级表达，只补齐有依据并明确标注的外观参考值，其余层级仍提示跳过。
- 新增通用迁移框架或 JSON/XML 依赖：当前只有两个来源和一组已有目标字段，使用原生解析器和小型适配器即可；没有复制上游项目、构建或语言服务模型。

## 后果

用户可以完成发现、预览、选择、导入、重新核对和撤销的闭环。首期不支持项目/语言层、Profiles 的默认继承合并、任意扩展主题包及未映射效果、按文件软换行、完整继承键位方案、语言专属缩进、格式化器与保存动作；这些在现有落点完善后再扩展，不伪装成已成功导入。恢复记录只包含 Lithe 的白名单编辑器偏好及当前键位覆盖，存在原有应用偏好存储内；无新下载物或缓存目录，发行包只读，不影响签名和 Sparkle 增量更新源字节。

## 自定义快捷键与基础缩进

复用现有键位覆盖、命令分发和导入事务。读取 VS Code/Cursor 的 `keybindings.json`，以及 IDEA `options/keymap.xml` 选中的 `keymaps/*.xml`；只映射白名单内语义一致的自定义命令，保留当前 Lithe 预设和无关覆盖。带条件、连续按键、VS Code 移除规则及重复命令规则及未映射命令不转成全局快捷键；支持已核实的 $default、Mac OS X、Mac OS X 10.5+ 内置方案及有界自定义继承；仅映射 Lithe 已有命令，不宣称完整复制全部 IDEA 动作。写入前按最终命令注册集合检查冲突，允许交换键位，冲突则整次导入不写入。源文件摘要覆盖新增文件，目标快照包含完整当前键位覆盖，复用失败恢复、重启回读和撤销保护。

基础缩进沿用全局编辑器设置的存储与 Monaco 原生桥接，增加宽度、Tab/空格及自动检测。读取 VS Code 显式全局字段和 IDEA 活跃 `codestyles` 方案的全局 `OTHER_INDENT_OPTIONS`、`AUTODETECT_INDENTS`；不把语言专属规则推广到所有文件。IDEA 独立缩进宽度与 Tab 宽度不同的情况不合并成一个值。已有文档模型在选项改变时应用，新模型创建时应用；分栏共享模型，自动检测使用文档内容，固定模式使用设置值。只更新模型选项，不转换已有文本，不清空撤销历史，不改格式化器参数。项目、语言和 EditorConfig 优先级尚未实现，不能宣称这些配置已迁移。

新增文件均为固定源码和图标资源，运行时只写原有用户设置存储，无新缓存目录或发行包写入。上游格式参考 IntelliJ Community `CodeStyleSchemesImpl` / `PersistableCodeStyleSchemes` 与官方 VS Code keybindings 文档；图标固定到 NOTICE 记录的 Community revision。

默认方案补齐：没有显式 keymap 选择时，依据 Community `DefaultKeymap.defaultKeymapName` 选择 macOS 的 `Mac OS X 10.5+`；受支持的键盘动作从固定 revision 的 XML 与 `$default` 父方案解析，保留 `MacOSDefaultKeymap` 的父级 Control/Command 交换。未知方案不回退成已知预设，重复名、循环继承拒绝读取；不支持的显式动作会遮蔽父级同名动作，避免悄悄恢复一个用户已替换的快捷键。无自定义代码设置时，依据 `CodeStyleDefaults` 与 `CodeStyleSettings` 提供宽度 4、空格、自动检测的全局参考值，使用现有默认/近似标识；未知代码方案不套默认值。外部源文件始终只读。

IDEA 自定义配色现在有独立的受校验覆盖层 `ImportedEditorTheme`：在 bounded `.icls` 快照中按方案名解析父子继承、`baseAttributes` 引用和属性整体覆盖，拒绝循环、重复名、未来版本和已映射属性的非法颜色。读取常见文字/背景/光标/选区等颜色，通用注释、字符串、数字、关键字以及部分 Java 词法和语义角色，保留粗体/斜体。Java tokenizer 保留行注释、块注释、文档注释及语言后缀，不能将行注释覆盖扩散到其他注释；语义样式保留弃用删除线。上游键名依据 Community `JavaHighlightingColors`（固定 revision e12d185a335d02f3831c12f2af64130b3ace46db），包括 `_ATTRIBUTES` 后缀。

覆盖层复用 `EditorAppearanceSettings` 的持久化、变更观察和 Monaco bridge；前端在内置配色之后应用已映射属性，字体与原生应用界面不受编辑器配色影响。导入的是一个固定深浅外观的编辑器方案，不宣称同时导入任意深浅双方案。设置页展示来源名称并允许移除；重新导入内置方案清除旧覆盖并纳入同一撤销事务。所有缓存和恢复仍在原有设置存储，无新可写 bundle 资源。

范围限制：已保存的用户覆盖可以精确应用；内置父配色仍以已有 IDEA 调色板近似映射，未映射的装饰效果、语言属性会提示跳过。VS Code 扩展主题的 include/tokenColors/semanticTokenColors、IDEA 插件专有 token 及全部语言语义规则尚未接入，不称为完整任意主题迁移。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'EditorSettingsImportTests|AppSettingsTests'`：隔离存储/临时目录验证来源只读、版本和 Profile、字段隔离、JSONC、XML 实体拒绝、单位换算、字体缺失、来源/目标冲突、持久化、部分写入失败、重启恢复及撤销保护。
- `./scripts/architecture/verify-service-boundaries.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `node scripts/i18n/generate-i18n.mjs --check`
- `node scripts/i18n/verify-app-language-localization.mjs`
- `./scripts/agent-notes/verify-agent-notes.sh`
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`

2026-10-31 本地验证：导入、AppSettings 和 Monaco 主题相关 42 项 Swift 测试通过，35 项国际化测试通过，架构边界、资源只读、测试稳定性、笔记、功能矩阵和翻译生成检查通过。完整 macOS 测试执行 4,132 项，有 4 个既有用例失败、共 12 个断言问题：GitModuleTests 的日期范围与本机时区、DiffAppearanceTests / DiffScrollSynchronizationTests / GitGraphInteractionTests 的视觉色值。独立进程只运行这 4 项、不运行新增导入测试时仍复现；尚未在未修改基线上复测，不据此宣称全量通过，也未修改这些无关测试。

本次两页布局验证：`EditorSettingsImportTests|LitheCenteredPopupTests|WindowFullScreenCapabilityGuardTests` 共 28 项通过，国际化 35 项通过。来源选择、返回和无效来源不会写入设置，确认导入后才改变目标值；原生窗口检查内容尺寸 640×467，并覆盖回到欢迎页时恢复窗口角色。测试配置生成两页深浅色截图，位于 `.artifacts/test-stability/import-layout/import-{sources,settings}-{dark,light}.png`；截图不代表已针对本机真实 IDEA 配置完成产品验收。

完整产品在不同本机版本/Profile、欢迎页和设置页的鼠标键盘操作，以及导入后多窗口与重启的视觉验收仍单独记录为待验收。自动化使用构造配置，不读取或修改开发者真实 IDE 配置。

新增回归覆盖 JSON/XML 损坏、修复后重试、无可支持字段、相同值和实际差异；原生无障碍点击验证重启后无来源时仍能撤销，且回读存储确认恢复。审查修复后运行 `EditorSettingsImportTests|AppSettingsTests|LitheCenteredPopupTests|WindowFullScreenCapabilityGuardTests`，58 项通过；国际化 35 项通过，架构边界、资源只读、笔记和功能矩阵检查通过。

Cursor/空配置发现修复后，相关测试 60 项通过，包含显式开启 `LITHE_LOCAL_IMPORT_DISCOVERY=1` 的本机只读集成检查：实际扫描器发现 VS Code（无 settings.json）和 Cursor（已有 settings.json），不启动外部编辑器、不应用或改写真实设置；普通测试运行默认跳过此检查，不依赖本机已安装软件。国际化 35 项通过。

本次确认稿布局验证：相关 Swift 测试运行 60 项，显式开启才执行的本机来源集成检查 1 项跳过；新增原生交互测试覆盖手动/启动两种场景，耗时 73ms。35 项国际化测试通过。已查看 `import-empty-dark.png` / `import-empty-light.png`，确认两行居中空状态及分隔线上方右侧链接；这些是测试宿主的英文/虚拟路径截图，测试宿主不提供产品图标 bundle，不能代替打包应用图标的视觉验收。

2026-11-01 外观迁移增量验证：按分组/外观接入、参考默认值、IDEA 方案字体、导入过程与结果、综合验收依次实现并自审。最终显式启用本机只读扫描的 69 项 Swift 测试全部通过，VS Code、Cursor、IDEA 均确认可读取；原生测试实际点击分组、导入和撤销，核对目标设置及返回流程。123 项真实 WebKit workbench 测试通过，其中全局外观测试验证已有和新分栏、字体/字号/行距、配色更新及文档/撤销历史保留；35 项国际化测试通过。审查修复了缺失可选文件的路径归一化误拒绝、默认外观一致状态文案、像素行高借参考字号换算时的来源标识，以及分组层级与自动行距显示。深浅色测试宿主截图位于 `.artifacts/test-stability/import-appearance/`，已检查布局；宿主缺少产品图标资源，不能替代打包应用图标验收。完整打包应用、多版本及完整 Profile 继承不由这些测试证明，功能矩阵保持人工验收 pending。

确认稿排版验证：导入及共享面板测试运行 31 项，30 项实际执行通过，1 项本机只读集成检查按默认条件跳过；本轮未改扫描器。原生测试检查当前值/导入值各行的横坐标对齐、两列不重叠，并继续实际点击分组选取、导入及撤销；该场景约 286ms。35 项国际化测试与架构、资源只读、笔记及功能矩阵检查通过。已检查深浅色实际测试宿主截图；图标仍需以正式产品 bundle 为准。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/MacEditorSettingsImportReader.swift`
- `macos/Sources/Lithe/Application/Features/EditorSettingsImportFeatureModel.swift`
- `macos/Sources/Lithe/Models/Settings/EditorSettingsImport.swift`
- `macos/Sources/Lithe/Models/Settings/AppSettings.swift`
- `macos/Sources/Lithe/Views/App/EditorSettingsImportView.swift`
- `macos/Tests/LitheTests/EditorSettingsImportTests.swift`

同值导入仍重新扫描并验证来源和所选目标基线，成功后反馈结果；无变化时不新建撤销记录、不写设置。已有自定义但与来源相同的字段可默认选择，不将其误当成覆盖冲突。原生回归覆盖同值类别可点击、全同值导入成功且不生成撤销记录，以及预览后目标变化被拒绝。

## VS Code 与 Cursor 默认分类补齐

缺少用户文件不能等同于缺少设置。读取器将已支持的参考缩进和编辑器显示偏好补入同一映射流程，显式值优先，非法显式值不偷偷回退默认。依据为 [VS Code 模型默认值](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/core/misc/textModelDefaults.ts) 与 [编辑器选项](https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/config/editorOptions.ts)。Cursor 与 Profile 继续标记近似，不能据此声称读取了它们的全部有效覆盖。

快捷键采用 [macOS 默认键位参考](https://code.visualstudio.com/docs/reference/default-keybindings) 中已有 Lithe 对应动作的一小组无条件命令，再合并支持的用户覆盖。条件、连续按键和移除规则不提升为全局动作；它们会遮蔽对应参考映射。未知扩展占用同一按键时也不恢复被占用的默认动作。导入仍经过全批次冲突检查，不切换用户原有预设。

已知内置配色下，支持 settings.json 的 workbench.colorCustomizations 中已映射编辑器颜色，以及 editor.tokenColorCustomizations 的通用字符串颜色（例如 comments）。复用现有 ImportedEditorTheme 校验、持久化、桥接与撤销。带透明度颜色、按主题限定的覆盖、TextMate 复杂作用域、语义规则及扩展主题包仍未解析；自动深浅切换也不能由单个覆盖对象正确表达，因此不会导入单一颜色覆盖来伪装完整还原。

验证使用隔离的 Code/Cursor 空目录，确认四类内容均存在、来源不被创建文件、显式值优先、无效字段跳过，以及默认键被用户规则遮蔽；颜色覆盖验证持久化回读和撤销。完整主题包迁移和真实打包产品的视觉验收仍不由这些检查证明。

## 缩进设置与状态显示统一

真实产品验收发现导入后 Monaco 已使用新宽度，状态栏和旧 Tab 宽度控件仍读取独立的 settings.tabWidth。删除重复控件与旧内存属性，状态栏直接观察 editorAppearance.tabSize/insertSpaces。旧持久化键仅用于新字段缺席时的一次兼容迁移，写入统一存储后再读取不会覆盖导入结果；保留旧键但不再写入，避免两个源互相同步造成撤销回弹。回归验证旧值迁移、显式新值优先、导入后重开、撤销以及手动修改。

## 打包产品验收与提交前审查补充

2026-11-01 在真实 IDEA 和 VS Code 设置界面保存测试值，再由 Lithe 扫描、导入并撤销；已观察字体、字号、行距、换行及 VS Code 通用注释颜色生效。Cursor 被登录页面阻挡，改用本机配置文件进行导入测试，不能称为 Cursor 设置界面验收。导入后退出并重启验证持久化及撤销入口；所有来源配置与 Lithe 偏好已恢复，测试实例已关闭。原始证据保留本地，不公开含个人路径的截图。

自动检测状态栏问题已补齐：Monaco 在文档模型创建和选项改变时，按文档 ID 回报 getOptions() 的 tabSize/insertSpaces。macOS 将它作为 EditorDocument 的临时运行状态，状态栏观察当前文档，不再读取全局默认值；切换文件/分栏沿用各自状态。尚未收到模型状态时不显示推测值。回报通过宿主可选能力开启，不要求其他平台处理新消息，不写入设置或建立第二份缩进来源。关闭文档的迟到通知由既有桥接边界拒绝。

此次审查覆盖读取器的有界只读扫描、白名单映射、来源/目标变更保护、恢复记录、快捷键冲突、主题应用以及两页入口。完整主题包、Profile 继承、多版本及全部快捷键的产品验收仍未完成；关联 Issue 不应因创建 PR 自动关闭。

同步 preview `50b4ebe0f` 后复验：125 项 WebKit 通过；相关 Swift 独立运行报告 98 项，97 项实际执行通过，1 项本机扫描默认跳过。完整 Swift 报告 4,271 项，仍有 Git 日期范围、Diff 颜色/标题像素和 Git Graph 背景色 4 个用例共 12 个断言失败，与此前记录一致；未在纯 preview 上独立复测，不称为全量通过或已证实基线问题。矩阵、架构、bundle 只读、笔记、翻译生成/语言及 35 项国际化检查通过。PR 保持 Draft，不据此标记阶段 5 全部完成。

自动检测状态栏修复复验：62 项 Swift 实际执行通过、1 项本机扫描跳过；125 项真实 WebKit 测试通过，覆盖模型实际缩进消息，不以此代替完整打包应用人工界面验收。架构、bundle 只读、i18n 生成/语言、笔记和矩阵检查通过。
