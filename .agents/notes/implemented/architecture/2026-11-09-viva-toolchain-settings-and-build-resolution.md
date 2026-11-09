# Agent 笔记：Viva 的工具链设置与 Build/Run 解析

状态：已实现

## 先说结论

Viva 桌面端现在把插件声明的工具链接进了设置和构建执行：Core 仍是唯一决定“哪个安装生效”的地方，Go 只做声明式扫描、文件事实读取、有界版本探测和原子保存。设置页的 Build 页按插件声明的工具显示当前生效值与来源；用户选择只改草稿，明确 Save 才写 `.lithe/toolchains/local.json`，Cancel 不写。Build 命令任务、Build 模型和 Provider 应用的 `toolchain` 候选都复用同一次解析，启动时使用 Core 返回的可执行文件、导出环境和 PATH。

这一批没有接入提供方后端查询（`toolchainProviders`），也没有因此声明该能力；Windows 原生保存与相关组件已在 Lithe-dev 验证，完整 GUI 流程仍未验收。

## 问题

旧 macOS 客户端已有工具链发现与解析，但 Viva 迁移时只剩 Build 候选里的一个占位错误：遇到 `toolchain` 候选直接报“缺少工具链”，没有设置页，也没有从插件声明发现安装。若把发现和优先级写进 Go，会出现第二份工具表、按工具名分支和界面与实际启动漂移。

## 决策

### Core 决定，平台只提供事实

- `desktop/internal/core/toolchain.go` 是 Core 工具链命令的类型化桥：注册表、发现计划、候选、解析、目录 pin 和版本检查。`registry` 输入始终是原始 `{plugins:[{manifest}]}`，由 Core 重新校验清单；宿主不保留自己的工具表。
- `desktop/internal/toolchain/` 只做 Core 不能做的原生 I/O：按 `discoveryPlan` 展开 `home`、`environment`、`absolute` 根的单层 glob，跟随符号链接并排除工作区内的 home；为声明的布局、导出和 PATH 目录收集 `stat`/`realpath` 事实；只探测 Core 从 `candidates` 返回的可执行文件，以及用户已保存 pin 或显式 fixed 对应的声明布局文件。
- 探测有数量（64）、并发（4）和单次 5 秒期限；进程复用既有 `buildprocess` 的有界进程树回收。取消后不发布部分探测结果。
- 扫描不到安装、版本不满足或工具被两个插件争用时，界面显示 Core 的稳定原因，不伪造默认安装。争用工具不注册，宿主不按插件 ID 替用户选择。

### 读取真实来源，明确保存

- 设置页 Build 页显示每个工具的有效安装、版本、层级和 pin 来源；登录 Shell 的 home 候选单列显示，并说明提供方安装尚未查询。
- 选择只修改窗口草稿；Save 才把本次页面的所有变化放进**一份文档事务**，与读取时的字节基线比较，冲突时保留草稿并报错。写入先确保 `.lithe/.gitignore` 含 `/toolchains/local.json`（不改其他行），再写本地文档；任一步失败时本地文档保持原字节。因此不会出现“返回失败但工具链配置已经改掉”。`.gitignore` 的追加是幂等、无害的前置步骤，之后文档写入失败时用户重试同一草稿即可。
- 写入使用同目录临时文件、保留原权限和原子改名；每次 Core 校验后、创建目录后和改名之前都检查取消。取消发生在 ignore 写入前时不写任何文件；发生在 ignore 与文档之间时只可能留下幂等、无害的 ignore 条目，文档保持原字节；临时文件总会清理。改名完成后即完成写入，不会把已提交的改名报告成取消。
- 打开页面只读：没有项目时显示“打开项目”，有项目但没有本地文档时不创建 `.lithe`。
- 保存器把整批草稿交给 Core 的 `toolchains.editPins`，只接收完整编辑后的文档字节，不在 Go 解码和合并 pin schema。Core 只更新目标目录的显式 pin，保留 legacy 字段、其他工具与 dormant pin；重复工具、未知字段、错误路径和超额批次整批拒绝。
- Core 新增的最小编辑接口是原有 Rust Core 的增量扩展，不重写解析器或选择规则。客户端依赖精确 Core 提交并在 PR 记录依赖；`editConsumerPreferences` 仍编辑另一份 schema，不能替代目录 pin 编辑。
- 原生保存读取时捕获字节基线，Core 返回后再次核对，在同目录临时文件完成后、原子替换前再核对；外部修改时保留新文件并返回冲突。此检查是乐观并发保护，不承诺能锁住不遵守同一协议的外部写入者。

### 开发者怎么做

- 新工具只写 `toolDefinitions`：给出可执行布局、版本正则、发现位置和启动模板。不要因为它是“JDK”或“Maven”就在 Go 里加字段或分支。
- Build 需要工具时声明 `toolchain` 候选并让宿主解析；不要把目录拼成命令字符串，也不要自己探测版本。
- 设置页只展示 Core 返回的 `candidates`/`resolve` 结果；草稿选择不得直接写文件，Save 才调用 `SavePin`。

正确做法：插件声明 `homeLayouts` 与版本探测，宿主扫描、探测并把事实交 Core，Build 启动 Core 选中的可执行文件。错误做法：在 `build.go` 里判断 `toolchainID == "java"` 后改读 `JAVA_HOME`，或设置页把“自动”显示成固定路径。

### 执行与设置用同一解析入口

`desktop/internal/workbench/toolchains.go` 把启用插件清单交给 Core，Build 的 `toolchain` 候选按 Core 顺序解析；解析结果直接进入进程启动，导出变量只补消费者未显式设置的值，PATH 前置来自声明的 `pathPrepend`。Provider Run 的 `launch.executable.kind == "toolchain"` 走同一入口。设置页的检测值从不用作启动许可。

## 考虑过的备选方案

- **在 Go 里扫描目录并维护 Maven/JDK 优先规则。** 能最快让界面有内容，但会重造 Core 已校验的四层选择和工具知识，第二个工具就要再改宿主，因此不采用。
- **只做设置页，不接 Build。** 页面可展示但用户仍无法使用所选路径；无法验证“探测结果与启动目标一致”，因此先接执行。
- **声明 `toolchainProviders` 后再补查询。** 会让市场允许带后端的工具链插件安装，但本客户端无法发 `toolchains/query`，首次使用才失败；所以本批不声明该能力。
- **用文件监听做实时刷新。** 会新增常驻监听和失效规则；本批在打开页面和显式 Reload 时读取，避免未验收的 watcher 生命周期。

## 后果

收益是设置显示与 Build/Run 启动共享同一份 Core 结果，新增工具只需插件声明，不需改宿主工具表。代价是提供方查询、目录树多来源合并、手动“添加安装”和输入文件监听仍未实现；保存的 JSON 编辑规则由 Core 持有，平台仅负责有冲突检查的原生写入。

Windows 已运行真实 Core 的工具链与工作台组件测试，并以受保护的用户专属访问控制列表验证原子保存保留原权限。原生程序识别与权限发布的取舍见 `../bug-fix/2026-11-09-viva-windows-native-file-validation.md`；路径大小写的完整工作流、GUI 和发行包验收仍待补。

## 验证

```bash
./scripts/desktop/desktop-go.sh test ./internal/toolchain ./internal/pluginhost ./internal/settingswindow ./internal/pluginservice
./scripts/desktop/desktop-go.sh test ./internal/workbench
./scripts/desktop/desktop-go.sh vet ./internal/toolchain ./internal/core ./internal/settingswindow ./internal/workbench ./internal/pluginhost ./internal/pluginservice
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
node scripts/i18n/verify-app-language-localization.mjs
node scripts/i18n/generate-i18n.mjs --check
./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh
./scripts/agent-notes/verify-agent-notes.sh
```

`desktop/internal/toolchain/toolchain_test.go` 用真实 Core 和两个语义不同的虚构工具验证声明式发现、版本探测、生效环境、项目/子目录 pin、争用、保存冲突、未知顶层字段拒绝、页面批量保存；另外用可控 kernel 阻塞校验后取消，断言 `local.json` 与 `.gitignore` 字节均不变、无临时文件，并覆盖 ignore 写失败时文档不变。新增可控 kernel 在 Core 编辑期间写入外部修改，回归先失败、补齐二次基线检查后通过；Core 与 Go 桥接共同消费 `shared/fixtures/toolchain-pin-edit.json`。`settingswindow/toolchains_view_test.go` 验证草稿、显式保存和取消不写；`workbench/toolchains_test.go` 验证 Build 使用解析结果并在工具链不可用时按 Core 顺序回退。这些是组件与真实 Core 证据；Windows 相关组件也已在 Lithe-dev 逐项计时通过，不代替完整 GUI 或发行包验收。

## 适用范围

- `desktop/internal/core/toolchain.go`
- `desktop/internal/toolchain/`
- `desktop/internal/settingswindow/toolchains_view.go`
- `desktop/internal/workbench/toolchains.go`、`settings_toolchains.go`、`build.go`
- `desktop/internal/pluginservice/toolchains.go`
- `shared/platform-feature-matrix/features/plugin-injected-toolchains.json`
