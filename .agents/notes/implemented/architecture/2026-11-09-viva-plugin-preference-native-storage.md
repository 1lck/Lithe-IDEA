# Agent 笔记：Viva 插件偏好的真实来源与原生保护写入

状态：已实现

## 先说结论

插件设置的解析、继承和编辑规则仍由原来的 Rust Core 负责；Viva 只读取平台与项目中的真实文件，执行受保护的原子写入，再读回结果。Debug、Build 和 LSP 启动现在使用真实全局和项目来源，而不再把它们当成空值。Viva 的离线已安装入口和七类通用控件已经接线并通过无头交互；声明按钮的确认、执行、取消和结果已接线并通过真实进程与无头按钮回归；动态页面、完整生效状态及跨平台原生窗口仍未整体验收，宿主尚不声明完整 settings v2 能力。

## 问题

只把设置控件接到内存草稿，启动时却传空设置，会让用户选择的调试程序被忽略。直接在 Go 解码并合并设置又会复制 Core 已有的声明校验和继承规则。保存过程还必须处理来源变化、目录切换、原生权限及写入后回读失败，否则可能覆盖外部修改，或把已经提交的保存误报成可以原样重试。

## 决策

### Core 处理文档，原生层处理文件

`desktop/internal/core/plugin_settings.go` 使用 Core 的设置状态与批量编辑接口。Core 校验完整声明和整批草稿，决定读取位置与字节预算，返回有效值、来源、编辑后的完整文档及生效方式。平台层不解释 JSON 字段、不自己选择默认值；无法解码的 UTF-8 字节直接报错，避免 JSON 传输悄悄修复用户文件。

`desktop/internal/pluginsettings/` 读取平台偏好目录和捕获的工作区来源。没有设置声明时，Core 明确指示无需读取，避免无关文件阻止原本不使用设置的插件。打开页面或准备读取不创建目录，不把缺失与空白、损坏文档混为一谈。

### 保存绑定读取时的来源

`desktop/internal/configfile/` 保留私有字节基线与原生目录身份，使用 Go 的 `os.Root` 在所选根内读写。普通文件之外的目标、越界路径和来源冲突被拒绝；读取有 Core 给出的上限。发布有可取消的串行入口，同目录独占临时文件在原子替换前完成字节、取消及调用者所有权检查。

Unix 保留原生模式、所有者与扩展属性；macOS 使用系统文件复制接口保留 ACL（访问控制列表）；Windows 按打开的文件句柄保留所有者、组和安全描述符及继承保护。元数据失败时不发布，不用扩大权限来恢复。临时文件和句柄由单次调用负责清理，不写入应用包或插件安装目录。

保存结果区分“是否已经提交”和“是否成功回读”。若提交后清理或回读失败，调用者保留草稿并作废旧基线，不能直接重试旧快照。回读绑定捕获的偏好目录和工作区，即使控制器后来切换目录，也不会悄悄读另一项目。

正确做法：捕获项目 A 的来源，校验后只保存到 A，回读 A 的结果。不要用保存时最新的活动项目替换捕获的根目录；项目已切换时应由所有权检查拒绝。工具链设置页已经增加相同的项目身份检查。

### Debug 消费真实层

调试准备把原始全局层和项目层交给 Core 的启动规划。显式项目路径不存在时保留明确错误，不回退到自动发现的另一个程序。读取失败经已有日志边界记录，并显示共享本地化提示。未修改插件市场的能力准入规则，也未把原始调试夹具当作已安装插件验收。

### Build 和 LSP 复用来源与 Core 规则

工作台的 `loadPluginPreferenceSources` 为一次后台操作读取真实双层来源。Build invocation 只把实际全局层交给 Core，保持“项目不能选择本机程序”的既有契约；Core 返回非空显式路径时，原生查找失败立即终止，不继续选择其他安装。有效显式程序的父目录进入 PATH。Provider 进程收到独立的全局/项目层，参数仍由 Core 展开，工作区 URI 也由 Core 生成，避免平台手拼 Windows 路径。

语言服务在选定插件后读取它自己的来源，不能给不同插件共享一份匿名设置 map。`pluginbackend.StartRequest` 保留双层输入；Core 返回的 `workspaceConfiguration` 连同初始化选项传入原有 LSP 引擎，启动时服务器可按标准协议拉取。`LanguageSession` 捕获语言声明、清单与工作区，服务层更新时重新读取这个会话的来源，调用现有 Core 模板和更新接口；Core 决定是立即发送还是等初始化后发送。没有声明模板与尚未发送是不同结果，读取失败不能推送一份空配置。

真实协议子进程已验证同一会话先读取初值，再接收通知并读取项目覆盖值，不需要重启。保存已提交时，工作台更新已有会话的即时配置；reload 只作废所属插件的构建模型，不停止当前任务或清空其他插件的模型。仍在读取的旧模型完成后不能重新成为当前结果，只给选中实例排一次最新读取。动态页面与按钮、跨窗口全局更新及市场准入仍须接线和验收，宿主继续不声明完整 settings v2。

### 离线目录、安装身份与通用草稿

已安装目录使用 Core 的数字版本选择，不能依赖 `pluginpkg.List` 的字符串顺序。原有 `newestVersions` 来自 `f9ae0f94d`，按最后一个字符串版本取值，导致 0.9 比 0.10 新；运行消费者、工具链和设置目录现共用原有 `PluginVersion` 的数字比较。先选择最新版本，再检查启用状态，避免较新版本停用后意外启动旧版。非法目录事实以索引诊断返回，健康目录仍可显示。

目录读取不访问商店，也不读取所有偏好。Core 从验证过的清单提供名称、版本、分组和控件初值。安装注册的 ID、版本也交给 Core 校验，避免将另一个插件的清单当作当前包编辑；原生快照另捕获目录身份和清单字节，保存前拒绝升级、卸载或替换。设置页面不授予执行权限，禁用插件也可编辑偏好。Windows 的普通 `os.Stat` 会延迟加载文件 ID，不能将这种快照用于稍后的替换检查；目录身份须从已打开句柄立即读取。否则目录被改名并在原路径重建后，`SameFile` 可能重新打开新路径，把新目录误认为原目录。Windows 回归已先复现这种错误提交，修复后的目标仍是拒绝保存且不创建来源文件。

整数保留原始文本，明确保存时由 Core 解析、校验；枚举、多选、默认值、继承和重置投影也来自 Core。每个范围只有自己的 UI 草稿，没有更改时不创建覆盖，切换范围前明确保存或重新加载。浏览按钮使用 Viva 原生文件选择器，取消不改变草稿。单个后台工作者与世代隔离限制连续切换的读取，返回结果经窗口线程应用；关闭或离页取消请求。行布局仅在加载后缓存，视口之外只留聚合占位，不创建全部设置控件。

固定 Viva 的 `Box.Disabled` 不覆盖 `Field`。只读或暂时不可编辑的文本值使用上游 `components.InputSnapshot` 的 `ReadOnly`/`Disabled`，输入提供器也拒绝这些控件；不能只改变外观。原生 macOS 验收曾复现项目范围中的全局整数仍能输入，失败回归检查原生 hit 的只读属性、输入拒绝和草稿不变，修复后通过。

重启提示只在存在对应运行会话时出现，按钮点击才撤销旧原生 owner。旧会话的停止、销毁及 serve loop 结束在独立于项目的有界后台清理完成后，才允许重新规划。停用、卸载或关闭工作区撤销后续启动 token；不会中断已经开始的清理。即时发送按会话串行，淘汰旧请求；最新排队请求超时也必须提示重启，不能把已经保存的配置静默丢下。无头测试覆盖这些边界，原生真实服务重启及完整跨窗口行为仍待验收。

### 诊断文档归属复用 Core

Windows 全量回归发现，原 Go 适配器去掉 `file://` 后把 `/elsewhere/A.java` 当作相对路径，错误归入当前工作区。诊断归属现在调用 Core 的 `lsp.documentIdentity`，复用既有 workspace-edit 路径解码和 `WorkspaceScope`；URI、驱动器/UNC、大小写与边界判断不再留在 Go。词法归属不读取文件，也不授予符号链接访问权限。每次诊断事件只缓存上一次 URI 投影，避免相同事件的两次转换重复跨 C ABI，不保留跨项目缓存。

真实 Windows clangd 已正常同步、Hover 和补全，但跳转结果里的 `/C:/...` 不被原生层识别为绝对路径。Core 的 LSP location 与 workspace-edit 现在复用同一份原生路径解码，去掉盘符前的 URI 斜杠，也处理 percent 编码盘符；不在 Go 为某个服务器加例外。低层回归先证明错误路径，再验证修复，完整真实服务器结果以 Windows 验证报告为准。

### 生产装配不能只存在于测试

生产入口曾未传 `PluginKernel`，使显式测试选项中可用的整套插件流程在实际程序中没有装配。`DesktopOptions` 现在集中连接同一个原有 Core client，主程序直接使用它。启动回归通过真实安装目录、Core 设置投影和受保护来源保存验证，而不是只断言一个字段。

原生窗口还复现了从通用设置进入插件页时安装状态没有加载的问题。打开任意设置页时都会请求一次后台安装状态快照；页面从内存读取，更新后通知已安装列表刷新。无头启动夹具固定自己的主题，避免在没有原生应用主循环时查询 AppKit 系统外观；生产程序仍按用户的真实主题选择运行。

当前无头验证覆盖真实文本输入后不写文件、明确保存及回读、冲突保留重置草稿、重新加载、七种类型、非法整数文本、最新读取覆盖旧读取及安装身份变化。它不能替代 macOS/Windows 原生窗口与完整能力准入验收。

### 声明按钮复用已运行提供方，不另建通信链

设置动作仍由原 Core 解析清单：它返回确认要求、动作所属插件与安装版本、函数和空参数；没有项目或插件已停用时返回不可用状态。界面不能把自己保存的显示版本、函数名或任意参数当作调用授权。原生适配器在规划前后复查安装清单字节、已打开目录的身份与工作区；一次动作还绑定不可变的工作区发布对象，避免关闭后以同一路径重开时接受过期结果。

用户明确确认后，Core 从宿主实际拥有的客户端句柄中选择同安装版本、同工作区、已就绪且注册了该函数的会话。它复用原函数注册与请求检查，但不采用跨插件 relay 的跨工作区回退。启动计划携带经过 Core 校验的包身份；不能从可编辑的界面快照推断进程版本。新查询有候选、字符串和路径预算，只读取内存状态，不扫描文件、不启动进程、不消费事件。

已有语言服务通过自己的事件所有者附接通用操作客户端；构建提供方继续用原客户端。按钮、Build 和语言请求只有一份会话事件流，函数请求先登记关联再发送，因此同步完成也不会丢结果。没有对应提供方时按既有契约明确提示不可用，不为了寻找函数启动多个进程。关闭页面或项目时取消该次操作，使用独立的有界预算等待收尾；共享提供方仍由项目拥有，不因一次动作结束而被误停。

确认、执行、取消、完成状态均使用共享控件与 i18n。动作不隐式保存设置草稿，也不把任意插件返回 JSON 直接显示成宿主状态。例如整数仍为未保存的 7 时执行“刷新”，成功后输入仍为 7、偏好文件仍缺失；不能把动作完成当成设置保存成功。原生完整窗体验收和各平台验证只按实际报告记账，不能由无头结果替代。

### 动态页面与同一应用内的跨窗口发布

动态设置页继续复用原 settings v2 的 `page` 声明，不新增插件 RPC。Core 校验安装身份后，从已启用插件生成语言/构建系统页面，按插件和 section 返回原表单的行、按钮引用；没有设置、只有按钮也能形成页面。名字由已启用插件的语言或构建系统声明提供，没有声明时显示不透明 ID。多个贡献者使用同一个页面里的插件选择器，各自保留来源、作用域和保存入口。侧栏搜索、父节点保留与顺序由 Core 投影，平台只绘制可见行。

输入框、输入法状态和草稿按插件身份保存在当前设置窗口中，最多保留 64 个已访问表单；仅清理没有草稿、没有在途操作的表单。切页不保存也不丢弃草稿，按钮按所属 section 出现，说明使用共享 ⓘ。收到保存通知时，干净表单从实际来源刷新；脏表单保留原文、显示来源变化并禁用再次保存，用户明确放弃草稿并重新加载后才建立新基线。插件停用导致动态页消失时，插件详情页仍能找到该草稿。

每个实际工作台窗口在创建配置时注册，在关闭时注销。保存已提交后，使用独立 10 秒预算完成同一应用进程内的通知；接收队列最多 8 项，窗口关闭会解除等待。后台适配器比较实际偏好目录和工作区目录身份，Core 决定作用域、版本及启用状态是否匹配。通知只携带私有安装身份和效果，不携带设置值。接收窗口再按自己的工作区读取实际配置；全局保存不会把源窗口的项目覆盖值复制出去。UI 消费时还核对工作区发布对象，同路径关闭再打开也不会接受旧窗口生命周期的通知。

这一机制覆盖同一应用内存活的工作台窗口，不是跨进程消息服务，也不新增“打开另一个工作台窗口”的产品入口。外部编辑器修改仍依靠保存时的来源冲突检查；独立应用进程间的实时刷新不在此通知机制内。完整 settings 2 准入、语言服务状态卡及原生全流程验收仍按功能矩阵记录，不能由目录与通知测试推定完成。

## 考虑过的备选方案

在 Go 中合并设置会维护第二份规则，所以继续扩展已有 Core 接口。每次保存直接覆盖整个文件会丢失其他插件配置；Core 只修改目标声明并保留其余内容。写入后只更新内存无法证明实际来源与继承关系，必须重新读取。

把发行目录作为默认写入根会改变安装基线，因此所有来源只由平台存储或用户工作区提供。乐观字节检查不会锁住不遵守协议的外部写入者，不宣称跨进程事务锁。

## 后果

保护逻辑只在后台读取或明确保存时运行，没有空闲轮询或帧内文件 I/O。批量非法输入、取消和外部修改不会覆盖旧来源；项目层清空只删除已经为空的目标文档，不删除其他插件配置。生成的用户状态和临时文件全部排除工作树复用。

## 验证

```bash
scripts/desktop/desktop-go.sh test -p=1 -count=1 -timeout=90s ./internal/configfile ./internal/pluginsettings ./internal/core
scripts/desktop/desktop-go.sh test -p=1 -count=1 -timeout=90s ./internal/workbench -run 'TestDebugReads|TestToolchainSettings|TestBuildExecutableUsesActual|TestBuildProviderUsesCaptured'
scripts/desktop/desktop-go.sh test -p=1 -count=1 -timeout=45s ./internal/pluginservice ./internal/pluginbackend ./internal/core -run 'TestLanguageServerReads|TestSavedProjectSetting|TestLanguageServerStartPreserves|TestPluginWorkspaceConfiguration'
```

Core 和 C ABI 共享同一份 `shared/fixtures/plugins/settings-documents.json`，覆盖类型、作用范围、整批拒绝、重复键、重置、其他插件保留和原字节不变。macOS 原生测试验证真实 ACL、扩展属性及空属性；Lithe-dev 已验证完整 Windows 安全描述符保持不变。项目显式调试路径用例修复前因忽略真实来源而失败，修复后通过。平台计时与后续完整生效链路以对应运行报告为准。

## 适用范围

- `desktop/internal/configfile/`
- `desktop/internal/pluginsettings/`
- `desktop/internal/core/plugin_settings.go`
- `desktop/internal/workbench/debug_launch.go`
- `desktop/internal/workbench/build.go`
- `desktop/internal/pluginservice/settings.go`
- `desktop/internal/pluginservice/settings_editor.go`
- `desktop/internal/settingswindow/plugin_settings_model.go`
- `desktop/internal/settingswindow/plugin_settings_view.go`
- `desktop/internal/workbench/settings_plugin_effects.go`
- `desktop/internal/workbench/settings_plugin_restart.go`
- `desktop/internal/workbench/startup.go`
- `desktop/cmd/lithe/main.go`
- `desktop/internal/pluginservice/backends.go`
- `shared/contracts/rust-core-api.md`

本节点的动作入口与证据还包括 `desktop/internal/core/plugin_setting_actions.go`、
`desktop/internal/workbench/settings_plugin_actions.go`、`desktop/internal/settingswindow/plugin_settings_actions_view.go`，
以及对应 `*_test.go`。共享动作和会话选择向量分别为
`shared/fixtures/plugins/settings-actions.json` 与 `settings-function-provider.json`。
真实 Core/提供方回归覆盖确认不调用、调用复用原进程、取消终态、关闭提供方后不可用，以及显示元数据不能覆盖私有安装版本；后者先失败后修复。macOS 在本地 Core 覆盖模式下，全量消费者 2544 项通过、8 项条件跳过；该源码随后提交为 Core `737e62b`，Core 插件 57 项与会话选择 1 项通过。Windows Lithe-dev 固定该提交、Core 干净且无覆盖的全量消费者通过；完整清单和结果随节点归档。固定提交后的 macOS 复验还遇到脚本入口和测试程序自身停在系统 `_dyld_start`，因此不把这些复验记作通过。原生隔离应用两次启动后窗口读取均返回 `cgWindowNotFound`；没有把这次启动当作按钮流程验收。竞态整包遇到提供方停在系统 `_dyld_start` 的启动失败，保留失败、采样与复验报告，不声称根因已修复。

动态页面与通知的共享向量为 `shared/fixtures/plugins/settings-surfaces.json`；
桌面桥接、界面和工作台回归分别在 `desktop/internal/core/settings_surfaces_test.go`、
`desktop/internal/settingswindow/settings_surfaces_test.go` 和
`desktop/internal/workbench/settings_publication_test.go`。
