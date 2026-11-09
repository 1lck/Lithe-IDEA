# Agent 笔记：Viva 插件偏好的真实来源与原生保护写入

状态：已实现

## 先说结论

插件设置的解析、继承和编辑规则仍由原来的 Rust Core 负责；Viva 只读取平台与项目中的真实文件，执行受保护的原子写入，再读回结果。Debug、Build 和 LSP 启动现在使用真实全局和项目来源，而不再把它们当成空值。Viva 的离线已安装入口和七类通用控件已经接线并通过无头交互；声明按钮、动态页面、完整生效状态及跨平台原生窗口仍未验收，宿主尚不声明完整 settings v2 能力。

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
